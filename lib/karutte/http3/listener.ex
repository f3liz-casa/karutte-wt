defmodule Karutte.Http3.Listener do
  @moduledoc """
  quicer のリスナ（UDP ポート）を一つ所有する GenServer。

  監視ツリーの中で「床を開けっ放しにする番人」。init で開き、terminate で閉じる。
  acceptor たちはここからハンドルをもらって accept する。
  """

  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @doc "リスナのハンドルを取り出す。"
  def handle(name), do: GenServer.call(name, :handle)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    port = Keyword.fetch!(opts, :port)

    listen_opts = [
      {:certfile, to_charlist(Keyword.fetch!(opts, :certfile))},
      {:keyfile, to_charlist(Keyword.fetch!(opts, :keyfile))},
      {:alpn, Keyword.get(opts, :alpn, [~c"h3"])},
      {:peer_bidi_stream_count, Keyword.get(opts, :peer_bidi_stream_count, 256)},
      {:peer_unidi_stream_count, Keyword.get(opts, :peer_unidi_stream_count, 256)},
      {:datagram_send_enabled, 1},
      {:datagram_receive_enabled, 1},
      {:idle_timeout_ms, Keyword.get(opts, :idle_timeout_ms, 30_000)}
    ]

    case :quicer.listen(port, listen_opts) do
      {:ok, listener} ->
        Logger.info("Karutte.Http3 listening on udp/#{port}")
        {:ok, %{listener: listener, port: port}}

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl true
  def handle_call(:handle, _from, s), do: {:reply, s.listener, s}

  @impl true
  def terminate(_reason, %{listener: listener}) do
    :quicer.close_listener(listener)
    :ok
  end
end
