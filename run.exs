# karutte の echo origin を上げる小さな起点。
# listen 先と flood 向けの上限を環境変数で締められるようにしてある（再ビルド不要で調整可）。
env = fn k, d -> System.get_env(k, d) |> String.to_integer() end

port = env.("WT_PORT", "4433")
bind = System.get_env("WT_BIND")

# 本番は公開 CA(Let's Encrypt)の cert/key を env で渡す。無ければ自己署名
# （serverCertificateHashes 用、13 日）にフォールバック＝ローカル検証や spike 向け。
{certfile, keyfile} =
  case {System.get_env("WT_CERTFILE"), System.get_env("WT_KEYFILE")} do
    {c, k} when is_binary(c) and is_binary(k) ->
      IO.puts("cert: public CA (#{c})")
      {c, k}

    _ ->
      {:ok, cert} = Karutte.Http3.Cert.generate("/app/priv/cert")
      IO.puts("cert: self-signed, sha256(b64) #{cert.sha256_b64}")
      {cert.certfile, cert.keyfile}
  end

# handler の選択: WT_TICKET_PUBKEY があれば **Bridge 稼働**（sukhi の NATS を消費して
# WebTransport へ橋渡し）、無ければ echo（ローカル検証・spike）。
handler =
  case System.get_env("WT_TICKET_PUBKEY") do
    k when is_binary(k) ->
      Application.put_env(:karutte_wt, :ticket_pubkey, Base.decode64!(k))
      Application.put_env(:karutte_wt, :gnat, :gnat)
      nats_host = System.get_env("NATS_HOST", "10.9.0.2")
      nats_port = String.to_integer(System.get_env("NATS_PORT", "4222"))
      # sukhi と同型の自動再接続つき接続を :gnat で。
      {:ok, _} =
        Gnat.ConnectionSupervisor.start_link(%{
          name: :gnat,
          connection_settings: [%{host: String.to_charlist(nats_host), port: nats_port}]
        })

      IO.puts("mode: bridge (NATS #{nats_host}:#{nats_port})")
      Karutte.Bridge

    _ ->
      IO.puts("mode: echo")
      Karutte.Http3.Echo
  end

opts =
  [
    port: port,
    certfile: certfile,
    keyfile: keyfile,
    handler: handler,
    keep_alive_interval_ms: 15_000,
    # flood 向けに既定より締める（x64 は小さい箱・最前線）。env で上書き可。
    max_connections: env.("WT_MAX_CONNECTIONS", "2000"),
    max_sessions: env.("WT_MAX_SESSIONS", "8"),
    max_datagram_queue: env.("WT_MAX_DATAGRAM_QUEUE", "256"),
    peer_bidi_stream_count: env.("WT_PEER_BIDI", "64"),
    peer_unidi_stream_count: env.("WT_PEER_UNIDI", "64"),
    idle_timeout_ms: env.("WT_IDLE_MS", "30000")
  ]
  |> then(fn o -> if bind, do: Keyword.put(o, :bind, bind), else: o end)

{:ok, _} = Karutte.Http3.Server.start_link(opts)

IO.puts(
  "karutte up on #{bind || "0.0.0.0"}:#{port} " <>
    "(max_conn=#{opts[:max_connections]} max_sess=#{opts[:max_sessions]} " <>
    "dgram_q=#{opts[:max_datagram_queue]} keepalive 15s)"
)
