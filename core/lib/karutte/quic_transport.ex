defmodule Karutte.QuicTransport do
  @moduledoc """
  L1, the swappable transport interface (dependency inversion). The only layer that moves.

  Concrete transports (`Karutte.QuicTransport.Quicer`, `Karutte.QuicTransport.Http3`,
  `Karutte.QuicTransport.Http2`) implement this behaviour. The layers above (Session, Stream)
  know nothing about what is underneath.

  A stream handle is an affine resource: exactly one controlling process. So the basic
  operation is `control/2`, which moves ownership to a single pid.
  """

  @type conn :: term()
  @type stream :: term()
  @type dir :: :bidi | :uni
  @type code :: non_neg_integer()
  @type error :: {:error, term()}

  # --- Imperative side (called by L3/L4) ---

  @doc "Open a stream from the server side."
  @callback open_stream(conn, dir, keyword()) :: {:ok, stream} | error

  @doc """
  Hand ownership of this stream to `pid` (the mechanism behind handoff).

  The ordering promise: deliver whatever arrived early (bytes still buffered with the old
  owner) to `pid` as `{:handoff_done, stream, buffered}`, then route all later live traffic
  to `pid` under the `{:quic, :data, ...}` contract. Where the early bytes live differs per
  transport (quicer keeps them in the NIF buffer, H3 in the Connection's per-stream buffer),
  and absorbing that difference is what `control/2` is for. The new owner must not touch
  live traffic until `handoff_done` arrives (`Karutte.WebTransport.Handoff.wait/2`).
  """
  @callback control(stream, pid) :: :ok | error

  @doc """
  The AXIS 2 knob: how many more messages to deliver before going passive again.
  Going passive means QUIC_STATUS_PENDING underneath, which means the MAX_STREAM_DATA window
  stops growing.
  """
  @callback set_active(stream, :once | non_neg_integer() | boolean()) :: :ok | error

  @callback send(stream, iodata(), fin: boolean()) :: :ok | error

  @doc "FIN (half-close the write side) / RESET_STREAM / STOP_SENDING."
  @callback shutdown(stream, :write | {:reset, code} | {:stop_sending, code}) :: :ok | error

  @doc "Send a datagram. No flow control, so it may be dropped on the sending side. Best effort."
  @callback send_datagram(conn, iodata()) :: :ok | error

  @callback close(conn, code) :: :ok

  # --- Message contract (what lands in the owning process's mailbox) ---

  @type stream_msg ::
          {:quic, :data, stream, binary(), [fin: boolean()]}
          | {:quic, :passive, stream}
          | {:quic, :closed, stream, reason :: term()}
          | {:quic, :reset, stream, code}

  @typedoc "Control plane (received only by the connection owner). No data flows through here."
  @type conn_msg ::
          {:quic, :new_stream, conn, stream, dir}
          | {:quic, :datagram, conn, binary()}
          | {:quic, :closed, conn, reason :: term()}
end
