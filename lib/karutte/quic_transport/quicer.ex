defmodule Karutte.QuicTransport.Quicer do
  @moduledoc """
  A concrete L1: emqx's `quicer` (the msquic NIF). Raw QUIC, no HTTP/3.

  Implements `Karutte.QuicTransport`. The layers above (Session, Stream) do not know this
  module exists; it sits behind the swappable interface.

  It has two faces:

    * **The imperative face** (`open_stream` / `control` / `set_active` / `send` / ...):
      thin delegation to quicer's functions.
    * **The message face** (`normalize/1`): translates the native tuples quicer drops into the
      owner's mailbox into the behaviour's `{:quic, ...}` contract. This is the heart of the
      translation, and it is pure. `test/quicer_normalize_test.exs` pins it down.

  ## Honest loose ends

  quicer is a **Preview** release and the shape of its native messages moves between versions.
  So `normalize/1` folds only the tuples it knows and passes everything else through as
  `{:unknown, msg}` rather than dropping it. The imperative face has not been driven against
  the real NIF through this module (the HTTP/3 server drives quicer from
  `Karutte.Http3.Connection` instead). Only `normalize/1` is verified here.

  ## The active/passive → PENDING chain

  `set_active(stream, :once | n | false)` lowers to quicer's `setopt(:active, ...)`. When
  active runs out and the stream goes passive, the NIF sets `is_recv_pending`, returns
  `QUIC_STATUS_PENDING` to msquic, and stops further receive callbacks. Once stopped, the
  MAX_STREAM_DATA window stops growing and the sender blocks. That is AXIS 2, in the flesh.

  Sources: <https://hexdocs.pm/quicer/messages_to_owner.html> /
  <https://github.com/microsoft/msquic/blob/main/docs/Streams.md>
  """

  @behaviour Karutte.QuicTransport

  import Bitwise, only: [band: 2]

  # --- msquic flags (constants that matter once wired; source: the msquic API headers) ---
  @recv_flag_fin 0x1
  @stream_open_flag_unidirectional 0x1
  @send_flag_fin 0x2
  @stream_shutdown_graceful 0x1
  @stream_shutdown_abort_send 0x2
  @stream_shutdown_abort_receive 0x4

  # --- Imperative face ---

  @impl true
  def open_stream(conn, dir, opts \\ []) do
    flags = if dir == :uni, do: @stream_open_flag_unidirectional, else: 0
    call(:start_stream, [conn, Keyword.put(opts, :open_flag, flags)])
  end

  @impl true
  def control(stream, pid), do: call(:controlling_process, [stream, pid])

  @impl true
  def set_active(stream, active), do: call(:setopt, [stream, :active, active])

  @impl true
  def send(stream, data, opts \\ []) do
    flags = if Keyword.get(opts, :fin, false), do: @send_flag_fin, else: 0
    call(:send, [stream, data, flags])
  end

  @impl true
  def shutdown(stream, :write),
    do: call(:async_shutdown_stream, [stream, @stream_shutdown_graceful, 0])

  def shutdown(stream, {:reset, code}),
    do: call(:async_shutdown_stream, [stream, @stream_shutdown_abort_send, code])

  def shutdown(stream, {:stop_sending, code}),
    do: call(:async_shutdown_stream, [stream, @stream_shutdown_abort_receive, code])

  @impl true
  def send_datagram(conn, data), do: call(:send_dgram, [conn, data])

  @impl true
  def close(conn, code) do
    call(:async_shutdown_connection, [conn, 0, code])
    :ok
  end

  # quicer is loaded lazily. If it is missing, fail here, plainly, with a hint.
  defp call(fun, args) when is_atom(fun) and is_list(args) do
    unless Code.ensure_loaded?(:quicer) do
      raise """
      Karutte.QuicTransport.Quicer needs :quicer (the msquic NIF).
      Add {:quicer, "~> 0.1"} to mix.exs and run mix deps.get.
      """
    end

    apply(:quicer, fun, args)
  end

  # --- Message face (pure; the verified part) ---

  @doc """
  Translate a native quicer message into the `Karutte.QuicTransport` contract.

  Unknown shapes pass through as `{:unknown, msg}`, so Preview-version drift is never
  silently dropped.
  """
  @spec normalize(term()) ::
          Karutte.QuicTransport.stream_msg()
          | Karutte.QuicTransport.conn_msg()
          | {:unknown, term()}

  # Stream data: {quic, Bin, Stream, Props}. FIN is a flag bit in Props.
  def normalize({:quic, bin, stream, props}) when is_binary(bin) and is_map(props) do
    {:quic, :data, stream, bin, fin: fin?(props)}
  end

  # The peer half-closed its write side (FIN only, no data).
  def normalize({:quic, :peer_send_shutdown, stream, _}),
    do: {:quic, :data, stream, <<>>, fin: true}

  # The peer's RESET_STREAM.
  def normalize({:quic, :peer_send_aborted, stream, code}),
    do: {:quic, :reset, stream, code}

  # Active ran out and the stream went passive (the AXIS 2 window has stopped).
  def normalize({:quic, :passive, stream, _}), do: {:quic, :passive, stream}

  # The stream closed.
  def normalize({:quic, :stream_closed, stream, reason}),
    do: {:quic, :closed, stream, reason}

  # To the connection owner: the peer opened a new stream. dir is a flag bit.
  def normalize({:quic, :new_stream, stream, props}) when is_map(props) do
    dir = if band(Map.get(props, :flags, 0), @stream_open_flag_unidirectional) != 0, do: :uni, else: :bidi
    {:quic, :new_stream, conn_of(props), stream, dir}
  end

  # To the connection owner: a datagram arrived (no flow control; off-axis).
  def normalize({:quic, :dgram, conn, bin}) when is_binary(bin),
    do: {:quic, :datagram, conn, bin}

  # The connection closed / the transport went down.
  def normalize({:quic, :shutdown, conn, reason}), do: {:quic, :closed, conn, reason}
  def normalize({:quic, :closed, conn, reason}), do: {:quic, :closed, conn, reason}
  def normalize({:quic, :transport_shutdown, conn, reason}),
    do: {:quic, :closed, conn, reason}

  def normalize(msg), do: {:unknown, msg}

  defp fin?(props), do: band(Map.get(props, :flags, 0), @recv_flag_fin) != 0
  # Some versions do not include conn in the new_stream Props. nil if absent (L2 fills it in).
  defp conn_of(props), do: Map.get(props, :conn)
end
