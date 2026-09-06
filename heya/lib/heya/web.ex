defmodule Heya.Web do
  @moduledoc """
  ページ。`/<部屋>` は、門が開いていればページ、閉じていれば「まだ開いていない」。
  admin は `/auth?room=` から sukhi でログインして、「開く」を押せる。
  """
  use Plug.Router
  alias Heya.{Auth, Gate}

  plug Plug.Parsers, parsers: [:urlencoded]
  plug :match
  plug :dispatch

  get "/" do
    page = :heya |> :code.priv_dir() |> to_string() |> Path.join("index.html") |> File.read!()
    conn |> put_resp_content_type("text/html") |> send_resp(200, page)
  end

  # OAuth の callback は登録した名前(HEYA_HOST)でしか受けない。別の名前で来たら、その名前に送り直す
  defp canonical(conn) do
    case System.get_env("HEYA_HOST") do
      nil -> conn
      host when host == conn.host -> conn
      host -> conn |> redirect("https://#{host}#{conn.request_path}#{qs(conn)}") |> halt()
    end
  end
  defp qs(%{query_string: ""}), do: ""
  defp qs(%{query_string: q}), do: "?" <> q

  get "/auth" do
    conn = canonical(conn)
    if conn.halted, do: conn, else: auth(conn)
  end

  defp auth(conn) do
    room = conn.params["room"] || ""
    state = Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false) <> "." <> room
    conn
    |> put_resp_cookie("heya_state", state, max_age: 600, http_only: true, secure: secure?(conn))
    |> redirect(Auth.authorize_url(callback(conn), state))
  end

  get "/auth/callback" do
    conn = fetch_cookies(conn)
    state = conn.params["state"] || ""
    cond do
      state == "" or conn.cookies["heya_state"] != state ->
        send_resp(conn, 400, "state が合わない。もう一度 /auth から。")
      true ->
        room = state |> String.split(".", parts: 2) |> List.last()
        case Auth.who(conn.params["code"] || "", callback(conn)) do
          {:ok, acct} ->
            conn
            |> put_resp_cookie(Auth.cookie(), Auth.sign(acct), max_age: 86_400, http_only: true, secure: secure?(conn))
            |> delete_resp_cookie("heya_state")
            |> redirect("/" <> room)
          {:error, :not_admin} -> send_resp(conn, 403, "admin ではないので、部屋は開けない。入るのは、開いた部屋なら誰でも。")
          {:error, e} -> send_resp(conn, 502, "sukhi と話せなかった: " <> inspect(e))
        end
    end
  end

  # koe の口。合言葉は Authorization: Bearer か ?token=
  get "/koe/:room" do
    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> t] -> t
        _ -> conn.params["token"]
      end
    if Heya.KoeSocket.allowed?(token) do
      who = (conn.params["name"] || "シロ") |> String.slice(0, 40)
      WebSockAdapter.upgrade(conn, Heya.KoeSocket, %{room: room, who: who}, timeout: 3_600_000)   # 黙っている koe を切らない(koe は 30 秒ごとに ping も打つ)
    else
      send_resp(conn, 403, "合言葉がちがう")
    end
  end

  post "/:room/open" do
    with {:ok, acct} <- admin(conn) do
      Gate.open(room)
      require Logger
      Logger.info("heya: #{acct} が #{room} を開いた")
      redirect(conn, "/" <> room)
    else
      _ -> send_resp(conn, 403, "admin だけ")
    end
  end

  post "/:room/close" do
    with {:ok, _} <- admin(conn) do
      Gate.close(room)
      redirect(conn, "/" <> room)
    else
      _ -> send_resp(conn, 403, "admin だけ")
    end
  end

  get "/:room" do
    admin = (case admin(conn) do {:ok, a} -> a; _ -> nil end)
    page =
      if Gate.open?(room) do
        :heya |> :code.priv_dir() |> to_string() |> Path.join("page.html") |> File.read!()
        |> String.replace("{{ROOM}}", room)
        |> String.replace("{{WT_URL}}", wt_url(conn))
        |> String.replace("{{HASH}}", Heya.Cert.hash() || "")
        |> String.replace("{{ADMIN}}", if(admin, do: close_form(room, admin), else: ""))
      else
        closed(room, admin)
      end
    conn |> put_resp_content_type("text/html") |> send_resp(200, page)
  end

  match _, do: send_resp(conn, 404, "no")

  # --- 中

  defp admin(conn) do
    conn = fetch_cookies(conn)
    Auth.verify(conn.cookies[Auth.cookie()])
  end

  defp closed(room, nil) do
    ~s"""
    <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>#{esc(room)} · heya</title><body style="font:16px system-ui;max-width:32rem;margin:3rem auto;padding:0 1rem;color:#333">
    <h1 style="font-weight:normal;font-size:1.2rem">#{esc(room)}</h1>
    <p>この部屋は、まだ開いていません。</p>
    <p><a href="/auth?room=#{URI.encode(room)}">sukhi の admin でログインして開く</a></p>
    """
  end

  defp closed(room, acct) do
    ~s"""
    <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>#{esc(room)} · heya</title><body style="font:16px system-ui;max-width:32rem;margin:3rem auto;padding:0 1rem;color:#333">
    <h1 style="font-weight:normal;font-size:1.2rem">#{esc(room)}</h1>
    <p>#{esc(acct)} さん。この部屋は閉じています。</p>
    <form method="post" action="/#{URI.encode(room)}/open"><button style="font:inherit;padding:.5rem 1rem">この部屋を 12 時間開く</button></form>
    """
  end

  defp close_form(room, acct) do
    ~s"""
    <p style="color:#888">#{esc(acct)}(admin) <form method="post" action="/#{URI.encode(room)}/close" style="display:inline"><button style="font:inherit">閉じる</button></form></p>
    """
  end

  defp esc(s), do: Plug.HTML.html_escape(s)
  defp redirect(conn, to), do: conn |> put_resp_header("location", to) |> send_resp(302, "")
  defp secure?(conn), do: conn.scheme == :https
  defp callback(conn), do: "#{conn.scheme}://#{conn.host}#{port_part(conn)}/auth/callback"
  defp port_part(%{scheme: :https, port: 443}), do: ""
  defp port_part(%{scheme: :http, port: 80}), do: ""
  defp port_part(%{port: p}), do: ":#{p}"

  # 同じ host の HEYA_WT_PORT(既定 4433)。本番は 443
  defp wt_url(conn), do: "https://#{conn.host}:#{System.get_env("HEYA_WT_PORT", "4433")}"
end
