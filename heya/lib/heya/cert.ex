defmodule Heya.Cert do
  @moduledoc "証明書。本物(HEYA_CERTFILE/KEYFILE)があればそれ、無ければ karutte の自己署名(13 日、ブラウザに hash を渡す)。"

  def files do
    case {System.get_env("HEYA_CERTFILE"), System.get_env("HEYA_KEYFILE")} do
      {c, k} when is_binary(c) and is_binary(k) ->
        :persistent_term.put({__MODULE__, :hash}, nil)
        {c, k}

      _ ->
        dir = Path.join(:code.priv_dir(:heya) |> to_string(), "cert")
        {:ok, cert} = Karutte.Http3.Cert.generate(dir)
        :persistent_term.put({__MODULE__, :hash}, cert.sha256_b64)
        {cert.certfile, cert.keyfile}
    end
  end

  @doc "自己署名なら sha256(base64)、本物なら nil。ページに埋める。"
  def hash, do: :persistent_term.get({__MODULE__, :hash}, nil)
end
