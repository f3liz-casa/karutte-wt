defmodule Karutte.Http3.Acceptor do
  @moduledoc """
  接続を受け付ける worker。`accept` でブロックして待ち、来たら handshake して、
  接続用の `DynamicSupervisor` の下に `Karutte.Http3.Connection` を起こして所有権を移す。

  exit を trap しないので、監視ツリーの shutdown では accept の receive ごと素直に殺される。
  permanent なので落ちても再起動して受け付けを続ける。
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

  @impl true
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

  @impl true
  def handle_continue(:accept, s) do
    with {:ok, conn} <- :quicer.accept(s.listener, [], :infinity),
         {:ok, conn} <- :quicer.handshake(conn) do
      spawn_connection(conn, s)
    else
      {:error, reason} -> Logger.debug("accept/handshake 失敗: #{inspect(reason)}")
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
        # 同時接続の上限。静かに断る（接続を閉じる）。
        :telemetry.execute([:karutte, :http3, :connection, :rejected], %{count: 1}, %{reason: :max_children})
        :quicer.async_shutdown_connection(conn, 0, 0)

      {:error, reason} ->
        Logger.warning("Connection 起動失敗: #{inspect(reason)}")
        :quicer.async_shutdown_connection(conn, 0, 0)
    end
  end
end
