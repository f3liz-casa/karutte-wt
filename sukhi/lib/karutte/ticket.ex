defmodule Karutte.Ticket do
  @moduledoc """
  WebTransport の入場チケット。**sukhi が署名し、karutte がローカルで検証する**。

  接続ごとに sukhi へ問い合わせない＝暗号の直後に安く弾ける＝flood に強い。sukhi は
  既に持っている Ed25519（OIP）で署名し、karutte は公開鍵だけを持って検証する。

  形（JWT 風、依存を足さない素の実装）:

      token = base64url(payload_json) <> "." <> base64url(ed25519_sig)

  `payload_json` は `{"sub": user_id, "exp": unix_seconds, "feeds": ["local","bubble","user"]}`。
  署名対象は **署名入力 = base64url(payload_json) の ASCII バイト**（曖昧さを避ける）。

  検証は署名と `exp`（期限）だけ見る。karutte は sukhi のユーザー DB を持たないので、
  「誰か」は sub、購読してよい feed は feeds、が sukhi の言い分そのまま。
  """

  @type claims :: %{sub: String.t(), exp: integer(), feeds: [String.t()]}

  @doc """
  トークンを検証。`pubkey` は sukhi の Ed25519 公開鍵（生 32 バイト）。
  `now`（unix 秒）を過ぎた exp は弾く。
  """
  @spec verify(binary(), binary(), integer()) :: {:ok, claims()} | {:error, atom()}
  def verify(token, pubkey, now) when is_binary(token) do
    with [b64_payload, b64_sig] <- String.split(token, ".", parts: 2),
         {:ok, sig} <- b64(b64_sig),
         true <- :crypto.verify(:eddsa, :none, b64_payload, sig, [pubkey, :ed25519]),
         {:ok, payload_json} <- b64(b64_payload),
         {:ok, %{"sub" => sub, "exp" => exp} = m} <- json(payload_json),
         true <- is_integer(exp) and exp > now do
      {:ok, %{sub: to_string(sub), exp: exp, feeds: Map.get(m, "feeds", ["local", "bubble", "user"])}}
    else
      false -> {:error, :bad_signature_or_expired}
      {:error, _} = e -> e
      _ -> {:error, :malformed}
    end
  end

  defp b64(s) do
    case Base.url_decode64(s, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :bad_base64}
    end
  end

  defp json(bin) do
    case :json.decode(bin) do
      m when is_map(m) -> {:ok, m}
      _ -> {:error, :bad_json}
    end
  rescue
    _ -> {:error, :bad_json}
  end
end
