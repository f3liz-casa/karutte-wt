defmodule Heya.Application do
  @moduledoc """
  部屋(heya)。Zulip の通話リンク `<jitsi_server_url>/<部屋名>` で開く、音だけの部屋。

    ブラウザ ── WebTransport datagram(karutte) ──┐
    koe     ── 素の TCP(127.0.0.1:7333)        ──┤── Heya.Room(fan-out、自分の声は返さない)
    ページ  ── Bandit(:4000、/<部屋>)            ┘

  枠は一つ: `<<from::8, pcm::binary>>`。from=0 は制御(JSON)、1〜250 は参加者。
  pcm は 16kHz mono Int16 LE、20ms(320 サンプル=640 バイト)ずつ。
  """
  use Application

  @impl true
  def start(_type, _args) do
    wt_port = env_int("HEYA_WT_PORT", 4433)
    {certfile, keyfile} = Heya.Cert.files()

    # sukhi の橋(karutte のいままでの仕事)。鍵があるときだけ NATS に繋ぐ(run.exs と同じ)
    bridge =
      case System.get_env("WT_TICKET_PUBKEY") do
        k when is_binary(k) ->
          Application.put_env(:karutte_sukhi, :ticket_pubkey, Base.decode64!(k))
          Application.put_env(:karutte_sukhi, :gnat, :gnat)
          host = System.get_env("NATS_HOST", "10.9.0.2") |> String.to_charlist()
          port = env_int("NATS_PORT", 4222)
          [%{id: :gnat, start: {Gnat.ConnectionSupervisor, :start_link, [%{name: :gnat, connection_settings: [%{host: host, port: port}]}]}}]
        _ -> []
      end

    http =
      case {System.get_env("HEYA_CERTFILE"), System.get_env("HEYA_KEYFILE")} do
        {c, k} when is_binary(c) and is_binary(k) -> [scheme: :https, certfile: c, keyfile: k]
        _ -> [scheme: :http]
      end

    children = bridge ++ [
      {Registry, keys: :unique, name: Heya.Registry},
      Heya.Gate,
      {DynamicSupervisor, name: Heya.Rooms, strategy: :one_for_one},
      {Karutte.Http3.Server,
       port: wt_port, certfile: certfile, keyfile: keyfile, handler: &route/1,
       max_sessions: 16, acceptors: 2, keep_alive_interval_ms: 15_000},
      {Heya.Tcp, port: env_int("HEYA_TCP_PORT", 7333)},
      {Bandit, [plug: Heya.Web, port: env_int("HEYA_HTTP_PORT", 4000)] ++ http}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Heya.Supervisor)
  end

  @doc "一つの port で二つの顔。`/wt…` は sukhi の橋(karutte のいままでの仕事)、それ以外は部屋。"
  def route(%{path: "/wt" <> _}), do: {Karutte.Bridge, nil}
  def route(_), do: {Heya.WT, nil}

  defp env_int(k, d), do: (System.get_env(k) || Integer.to_string(d)) |> String.to_integer()
end
