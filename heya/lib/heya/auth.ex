defmodule Heya.Auth do
  @moduledoc """
  sukhi-fedi の admin かどうか。Mastodon 互換の OAuth で一度ログインしてもらい、
  `verify_credentials` の `role.name == "admin"` を見る。通ったら署名つき cookie を一日。
  """
  @sukhi System.get_env("HEYA_SUKHI", "https://sukhi.f3liz.casa")
  @cookie "heya_admin"
  @day 86_400

  def sukhi, do: @sukhi
  def cookie, do: @cookie
  defp client_id, do: System.fetch_env!("HEYA_OAUTH_CLIENT_ID")
  defp client_secret, do: System.fetch_env!("HEYA_OAUTH_CLIENT_SECRET")
  defp secret, do: System.fetch_env!("HEYA_SECRET")

  def authorize_url(redirect_uri, state) do
    q = URI.encode_query(%{client_id: client_id(), redirect_uri: redirect_uri, response_type: "code", scope: "read:accounts", state: state})
    @sukhi <> "/oauth/authorize?" <> q
  end

  @doc "code をトークンに替えて、だれかを訊く。admin なら {:ok, acct}。"
  def who(code, redirect_uri) do
    with {:ok, %{"access_token" => token}} <- post_json(@sukhi <> "/oauth/token", %{
           grant_type: "authorization_code", code: code, client_id: client_id(),
           client_secret: client_secret(), redirect_uri: redirect_uri}),
         {:ok, me} <- get_json(@sukhi <> "/api/v1/accounts/verify_credentials", token) do
      if get_in(me, ["role", "name"]) == "admin", do: {:ok, me["acct"] || me["username"]}, else: {:error, :not_admin}
    end
  end

  def sign(acct), do: Plug.Crypto.sign(secret(), @cookie, acct)
  def verify(nil), do: :error
  def verify(token), do: (case Plug.Crypto.verify(secret(), @cookie, token, max_age: @day) do {:ok, a} -> {:ok, a}; _ -> :error end)

  # --- 小さな HTTP(依存を増やさない。:httpc で足りる)
  defp post_json(url, body) do
    req = {String.to_charlist(url), [], ~c"application/json", Jason.encode!(body)}
    :httpc.request(:post, req, [ssl: ssl(), timeout: 10_000], []) |> reply()
  end

  defp get_json(url, token) do
    req = {String.to_charlist(url), [{~c"authorization", String.to_charlist("Bearer " <> token)}]}
    :httpc.request(:get, req, [ssl: ssl(), timeout: 10_000], []) |> reply()
  end

  defp reply({:ok, {{_, 200, _}, _, body}}), do: {:ok, Jason.decode!(to_string(body))}
  defp reply({:ok, {{_, status, _}, _, body}}), do: {:error, {status, to_string(body) |> String.slice(0, 200)}}
  defp reply({:error, e}), do: {:error, e}

  defp ssl, do: [verify: :verify_peer, cacerts: :public_key.cacerts_get(), depth: 3, customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]]
end
