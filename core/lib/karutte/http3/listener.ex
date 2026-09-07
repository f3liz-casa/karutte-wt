defmodule Karutte.Http3.Listener do
  @moduledoc """
  A GenServer that owns one quicer listener (one UDP port).

  Its job in the supervision tree is to keep the floor open: it opens the listener in `init`
  and closes it in `terminate`. The acceptors fetch the handle from here and accept on it.
  """

  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @doc "Fetch the listener handle."
  def handle(name), do: GenServer.call(name, :handle)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    port = Keyword.fetch!(opts, :port)

    # With `:bind`, listen on that one address only (say, a WireGuard address like "10.9.0.2").
    # quicer's listen_on is `port | "IP:Port"`. Without it, all interfaces. Behind a transparent
    # relay you bind to the tunnel address so nothing answers on the public interface directly.
    listen_on =
      case Keyword.get(opts, :bind) do
        nil -> port
        ip -> String.to_charlist("#{ip}:#{port}")
      end

    # Server-initiated keepalives keep a connection alive past idle (and keep NAT / relay
    # conntrack entries warm).
    keepalive =
      case Keyword.get(opts, :keep_alive_interval_ms) do
        nil -> []
        ms -> [{:keep_alive_interval_ms, ms}]
      end

    listen_opts =
      [
        {:certfile, to_charlist(Keyword.fetch!(opts, :certfile))},
        {:keyfile, to_charlist(Keyword.fetch!(opts, :keyfile))},
        {:alpn, Keyword.get(opts, :alpn, [~c"h3"])},
        {:peer_bidi_stream_count, Keyword.get(opts, :peer_bidi_stream_count, 256)},
        {:peer_unidi_stream_count, Keyword.get(opts, :peer_unidi_stream_count, 256)},
        {:datagram_send_enabled, 1},
        {:datagram_receive_enabled, 1},
        {:idle_timeout_ms, Keyword.get(opts, :idle_timeout_ms, 30_000)}
      ] ++ keepalive

    case :quicer.listen(listen_on, listen_opts) do
      {:ok, listener} ->
        Logger.info("Karutte.Http3 listening on udp/#{port}#{if Keyword.get(opts, :bind), do: " (#{Keyword.get(opts, :bind)})", else: ""}")
        {:ok, %{listener: listener, port: port}}

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:handle, _from, s), do: {:reply, s.listener, s}

  @impl GenServer
  def terminate(_reason, %{listener: listener}) do
    :quicer.close_listener(listener)
    :ok
  end
end
