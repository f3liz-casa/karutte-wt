# A small entry point that starts the karutte echo server.
# The listen address and the flood-related limits are taken from environment variables,
# so they can be tuned without a rebuild.
env = fn k, d -> System.get_env(k, d) |> String.to_integer() end

port = env.("WT_PORT", "4433")
bind = System.get_env("WT_BIND")

# In production, pass a public-CA (Let's Encrypt) cert/key through the environment. Without
# them, fall back to a self-signed certificate (13 days, for serverCertificateHashes), which
# is meant for local checks and spikes.
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

opts =
  [
    port: port,
    certfile: certfile,
    keyfile: keyfile,
    handler: Karutte.Http3.Echo,
    keep_alive_interval_ms: 15_000,
    # Tighter than the defaults, with floods in mind (a small box on the front line). Override via env.
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
