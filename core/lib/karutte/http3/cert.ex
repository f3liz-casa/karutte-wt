defmodule Karutte.Http3.Cert do
  @moduledoc """
  A small tool for making self-signed certificates that browsers accept for WebTransport.

  With `serverCertificateHashes`, a browser will connect to a self-signed certificate with no
  CA involved. There are conditions (Chrome's):

    * ECDSA (P-256)
    * valid for **14 days or less**
    * the connecting side pins the SHA-256 of the DER in `serverCertificateHashes`

  This module has openssl produce exactly that and returns cert.pem / key.pem plus the
  SHA-256 to hand to the browser (base64 and hex). For production with a real CA
  certificate, skip this and pass certfile/keyfile straight to `Karutte.Http3.Server`.
  """

  @doc """
  Write cert.pem / key.pem into `dir` and return
  `%{certfile, keyfile, sha256_b64, sha256_hex}`. `:days` defaults to 13 (inside the 14-day
  limit). `:cn` defaults to `"localhost"`.
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

    # The key is written as PKCS#8 ("BEGIN PRIVATE KEY"), which msquic/quictls reads.
    # SEC1 ("EC PRIVATE KEY") can be rejected during TLS initialisation.
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
