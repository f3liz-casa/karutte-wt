defmodule Karutte.Http3.Acceptor do
  @moduledoc """
  A worker that accepts connections. It blocks in `accept`, and when a connection arrives it
  starts a `Karutte.Http3.Connection` under the connection `DynamicSupervisor` and hands
  ownership over.

  It does not trap exits, so on supervisor shutdown it is simply killed, blocking receive and
  all. It is `permanent`, so if it crashes it restarts and keeps accepting.
  """

  use GenServer
  require Logger

  alias Karutte.Http3.{Connection, Listener}

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    state = %{
      listener: Listener.handle(Keyword.fetch!(opts, :listener)),
      conn_sup: Keyword.fetch!(opts, :conn_sup),
      handler: Keyword.fetch!(opts, :handler),
      handler_arg: Keyword.get(opts, :handler_arg),
      max_sessions: Keyword.get(opts, :max_sessions, 16),
      max_datagram_queue: Keyword.get(opts, :max_datagram_queue, 1_000)
    }

    {:ok, state, {:continue, :accept}}
  end

  @impl GenServer
  def handle_continue(:accept, s) do
    # Hand ownership to the Connection immediately after accept. The handshake happens on the
    # Connection side. If the acceptor did it, a client's early stream events could land in the
    # acceptor's mailbox in the gap between handshake and handoff and be lost, and handshakes
    # would serialize on the acceptor. With the owner (Connection) doing the handshake, both
    # problems go away.
    case :quicer.accept(s.listener, [], :infinity) do
      {:ok, conn} -> spawn_connection(conn, s)
      {:error, reason} -> Logger.debug("accept failed: #{inspect(reason)}")
    end

    {:noreply, s, {:continue, :accept}}
  end

  defp spawn_connection(conn, s) do
    child =
      {Connection,
       [
         qconn: conn,
         handler: s.handler,
         handler_arg: s.handler_arg,
         max_sessions: s.max_sessions,
         max_datagram_queue: s.max_datagram_queue
       ]}

    case DynamicSupervisor.start_child(s.conn_sup, child) do
      {:ok, pid} ->
        :quicer.controlling_process(conn, pid)
        Connection.setup(pid)

      {:error, :max_children} ->
        # Connection limit reached. Refuse quietly by closing the connection.
        :telemetry.execute([:karutte, :http3, :connection, :rejected], %{count: 1}, %{reason: :max_children})
        :quicer.async_shutdown_connection(conn, 0, 0)

      {:error, reason} ->
        Logger.warning("failed to start Connection: #{inspect(reason)}")
        :quicer.async_shutdown_connection(conn, 0, 0)
    end
  end
end
