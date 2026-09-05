defmodule Karutte.Http3.Echo do
  @moduledoc """
  The example: the simplest possible WebTransport handler. Whatever arrives is sent back.

  It has two faces:

    * `Karutte.WebTransport` (this module): the session's control plane. Every stream the
      peer opens is handed to `Echo.Stream`; datagrams are bounced straight back.
    * `Karutte.Http3.Echo.Stream` (nested below): the stream's data plane. Bytes are pushed
      back as they arrive, and on FIN the write side is closed too.

  Bouncing a datagram needs somewhere to send it from. The behaviour's `handle_datagram/2`
  cannot send through its return value (datagrams are off-axis and have no push), so the
  transport and connection handle are taken from `conn_info` in `init/2`, kept in state, and
  used from there.
  """

  @behaviour Karutte.WebTransport

  @impl true
  def init(_arg, conn_info) do
    # conn_info carries the transport and the connection handle.
    # Both are needed to bounce datagrams.
    {:ok, %{transport: conn_info.transport, conn: conn_info.conn}}
  end

  @impl true
  def handle_stream(_stream, _dir, state) do
    # Every stream gets its own long-lived echo owner.
    {{:handler, __MODULE__.Stream, nil}, state}
  end

  @impl true
  def handle_datagram(bin, state) do
    state.transport.send_datagram(state.conn, bin)
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  defmodule Stream do
    @moduledoc "The echo data plane. Returns each byte it receives; closes the write side on FIN."

    @behaviour Karutte.WebTransport.Stream

    @impl true
    def init(_stream, _arg), do: {:ok, %{}, active: true}

    @impl true
    def handle_in(bin, state), do: {:push, bin, state, active: true}

    @impl true
    def handle_fin(state), do: {:close_write, state}

    @impl true
    def terminate(_reason, _state), do: :ok
  end
end
