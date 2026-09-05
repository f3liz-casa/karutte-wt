defmodule Karutte.Http3.Server do
  @moduledoc """
  The WebTransport over HTTP/3 server. One supervision tree.

      Karutte.Http3.Server (Supervisor)
      ├── Karutte.Http3.Listener            … keeps the UDP port open
      ├── ConnectionSup (DynamicSupervisor) … one Connection per QUIC connection (temporary)
      └── Karutte.Http3.Acceptor × N        … accept loop (permanent, restarted on crash)

  A failure in one connection stays inside ConnectionSup. If an acceptor dies it restarts and
  accepting continues. The listener opens and closes with the tree. `child_spec/1` is
  provided, so this drops into your own application's supervision tree as a child.

  ## Options

    * `:port`        — UDP port (required)
    * `:certfile`    — PEM certificate (required; for self-signed see `Karutte.Http3.Cert.generate/2`)
    * `:keyfile`     — PEM private key (required)
    * `:handler`     — a module implementing `Karutte.WebTransport` (required)
    * `:handler_arg` — first argument to `handler.init/2` (default `nil`)
    * `:acceptors`   — number of concurrent acceptors (default 4)
    * `:name`        — base registered name for this server (default `Karutte.Http3.Server`)
    * `:max_sessions`           — WebTransport sessions per connection (default 16)
    * `:max_connections`        — concurrent connections (default 10_000; new ones are refused beyond it)
    * `:max_datagram_queue`     — datagrams queued per session (default 1_000; dropped beyond it)
    * `:idle_timeout_ms`        — default 30_000
    * `:peer_bidi_stream_count` / `:peer_unidi_stream_count` — default 256
    * `:bind`                   — address to listen on (for example `"10.9.0.2"`; all interfaces if omitted).
                                  Useful behind a transparent relay, to listen on the tunnel only.
    * `:keep_alive_interval_ms` — interval for server-initiated QUIC keepalives (keeps NAT / relay conntrack warm)

  ## Telemetry

  `[:karutte, :http3, :connection, :start | :stop | :rejected]`,
  `[:karutte, :http3, :session, :open | :close | :rejected]`,
  `[:karutte, :http3, :datagram, :dropped]`.

  ## Example

      {:ok, cert} = Karutte.Http3.Cert.generate("priv/cert")
      {:ok, _} = Karutte.Http3.Server.start_link(
        port: 4433, certfile: cert.certfile, keyfile: cert.keyfile,
        handler: Karutte.Http3.Echo)
  """

  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Graceful shutdown, for rolling restarts.

    1. Stop the acceptors so no new connections are taken.
    2. Send GOAWAY on every live connection and DRAIN to every WebTransport session, so clients migrate.
    3. Wait `grace_ms`.
    4. Stop the whole tree.

  This blocks. Call it from another process, or from a deploy script.
  """
  @spec drain(atom(), non_neg_integer()) :: :ok
  def drain(name \\ __MODULE__, grace_ms \\ 5_000) do
    for {id, pid, _, _} <- Supervisor.which_children(name),
        match?({Karutte.Http3.Acceptor, _}, id),
        is_pid(pid) do
      Supervisor.terminate_child(name, id)
    end

    conn_sup = Module.concat(name, "ConnectionSup")

    for {_, pid, _, _} <- DynamicSupervisor.which_children(conn_sup), is_pid(pid) do
      Karutte.Http3.Connection.drain(pid)
    end

    Process.sleep(grace_ms)
    Supervisor.stop(name)
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    listener_name = Module.concat(name, "Listener")
    conn_sup = Module.concat(name, "ConnectionSup")

    config = %{
      handler: Keyword.fetch!(opts, :handler),
      handler_arg: Keyword.get(opts, :handler_arg),
      max_sessions: Keyword.get(opts, :max_sessions, 16),
      max_datagram_queue: Keyword.get(opts, :max_datagram_queue, 1_000)
    }

    n = Keyword.get(opts, :acceptors, 4)

    listener_opts =
      opts
      |> Keyword.take([
        :port,
        :certfile,
        :keyfile,
        :alpn,
        :idle_timeout_ms,
        :peer_bidi_stream_count,
        :peer_unidi_stream_count,
        :bind,
        :keep_alive_interval_ms
      ])
      |> Keyword.put(:name, listener_name)

    acceptors =
      for i <- 1..n do
        {Karutte.Http3.Acceptor,
         [
           id: i,
           listener: listener_name,
           conn_sup: conn_sup,
           handler: config.handler,
           handler_arg: config.handler_arg,
           max_sessions: config.max_sessions,
           max_datagram_queue: config.max_datagram_queue
         ]}
      end

    children =
      [
        {Karutte.Http3.Listener, listener_opts},
        {DynamicSupervisor,
         name: conn_sup,
         strategy: :one_for_one,
         max_children: Keyword.get(opts, :max_connections, 10_000)}
      ] ++ acceptors

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
