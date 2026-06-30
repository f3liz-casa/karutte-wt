defmodule Karutte.Http3.Cert do
  @moduledoc """
  WebTransport 用の自己署名証明書を作る小道具。

  ブラウザは WebTransport で `serverCertificateHashes` を使うと、CA 無しの自己署名でも
  繋げる。ただし条件がある（Chrome）:

    * ECDSA（P-256）であること
    * 有効期間が **14 日以内**であること
    * その DER の SHA-256 を、繋ぐ側が `serverCertificateHashes` に渡してピン留めする

  ここでは openssl にそれを作らせて、cert.pem / key.pem と、ブラウザに渡す SHA-256
  （base64 と hex）を返すだけ。prod で「ちゃんとした CA 証明書」を使うなら、この道具では
  なく certfile/keyfile を直接 `Karutte.Http3.Server` に渡せばよい。
  """

  @doc """
  `dir` に cert.pem / key.pem を生成し、`%{certfile, keyfile, sha256_b64, sha256_hex}`
  を返す。`:days` は既定 13（14 日上限の内側）。
  """
  @spec generate(Path.t(), keyword()) ::
          {:ok, %{certfile: Path.t(), keyfile: Path.t(), sha256_b64: String.t(), sha256_hex: String.t()}}
          | {:error, term()}
  def generate(dir, opts \\ []) do
    days = Keyword.get(opts, :days, 13)
    cn = Keyword.get(opts, :cn, "localhost")
    keyfile = Path.join(dir, "key.pem")
    certfile = Path.join(dir, "cert.pem")
    File.mkdir_p!(dir)

    # 鍵は PKCS#8（"BEGIN PRIVATE KEY"）で。msquic/quictls はこの形を読む
    # （SEC1 "EC PRIVATE KEY" だと TLS 初期化で弾かれることがある）。
    with {_, 0} <-
           System.cmd(
             "openssl",
             [
               "req", "-x509", "-newkey", "ec",
               "-pkeyopt", "ec_paramgen_curve:prime256v1",
               "-nodes",
               "-keyout", keyfile,
               "-out", certfile,
               "-days", Integer.to_string(days),
               "-subj", "/CN=#{cn}",
               "-addext", "subjectAltName=DNS:#{cn}"
             ],
             stderr_to_stdout: true
           ),
         {:ok, der} <- der_of(certfile) do
      hash = :crypto.hash(:sha256, der)

      {:ok,
       %{
         certfile: certfile,
         keyfile: keyfile,
         sha256_b64: Base.encode64(hash),
         sha256_hex: Base.encode16(hash, case: :lower)
       }}
    else
      {out, code} when is_integer(code) -> {:error, {:openssl, code, out}}
      {:error, _} = err -> err
    end
  end

  defp der_of(certfile) do
    case System.cmd("openssl", ["x509", "-in", certfile, "-outform", "der"], stderr_to_stdout: false) do
      {der, 0} -> {:ok, der}
      {out, code} -> {:error, {:openssl_der, code, out}}
    end
  end
end
