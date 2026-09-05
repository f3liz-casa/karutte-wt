defmodule Karutte.QuicTransport.Http2 do
  @moduledoc """
  The other L1: WebTransport over HTTP/2 (draft-ietf-webtrans-http2, on TCP).

  This is the real reward for separating the layers. The **same behaviour**,
  `Karutte.QuicTransport`, is satisfied by both QUIC (`Quicer`) and HTTP/2. The layers above
  (Session, Stream) run literally the same code without knowing which floor they stand on.
  It is the version that works on TCP today, without waiting for QUIC.

  ## How the three axes map onto H2: what survives, what thins out

      QUIC                        Where it lives on HTTP/2                  Result
      ────────────────────────────────────────────────────────────────────────────
      MAX_STREAMS (creation)      SETTINGS_MAX_CONCURRENT_STREAMS            survives
      MAX_STREAM_DATA (transfer)  per-stream WINDOW_UPDATE                   survives
      MAX_DATA (connection)       connection-level WINDOW_UPDATE             survives
      datagram (off-axis)         DATAGRAM capsule (RFC 9297), reliable      thins out

  Stream backpressure (AXIS 1/2) carries over as is, because H2 has separate windows for it.
  Only datagrams thin out. H2 has none, so they ride as capsules on the CONNECT stream: a
  **reliable, ordered pseudo-datagram**. The unreliable best-effort nature is lost. Correct,
  but semantically thinner. A fallback.

  Head-of-line blocking also returns (it is TCP). That is a property of the floor and has
  nothing to do with the shape of the layers above.

  ## sink: where L2 plugs in the H2 writer

  There is no seam (L2) to an H2 server (Bandit) yet, so the imperative side escapes to a
  **sink (a pid)**. It is the same dependency inversion as `Quicer` hiding quicer behind the
  interface. In tests the sink is `self()`, so outgoing frames can be asserted. When L2 is
  written, the sink becomes the real H2 connection process.

  On the receiving side, `normalize/1` folds the events an H2 demultiplexer emits into the
  **same `{:quic, ...}` contract** as `Quicer`. That the two normalizers produce the same
  shape is the proof that the upper layers are transport-independent. `test/http2_test.exs`
  checks the round trip and the shape.

  Sources: <https://datatracker.ietf.org/doc/html/draft-ietf-webtrans-http2> /
  RFC 9297 (Capsules)
  """

  @behaviour Karutte.QuicTransport

  alias Karutte.{Capsule, Varint}

  @typedoc """
  One session on H2. `session_id` is the CONNECT stream's id (in the draft, this id is the
  preface that ties a WebTransport stream to its session).
  """
  @type t :: %__MODULE__{sink: pid(), session_id: non_neg_integer()}
  defstruct [:sink, :session_id]

  @doc "For tests and L2: build a conn from a sink and a session id."
  @spec new(pid(), non_neg_integer()) :: t()
  def new(sink, session_id) when is_pid(sink) and is_integer(session_id) do
    %__MODULE__{sink: sink, session_id: session_id}
  end

  # --- Framing (pure; the session preface on WT/H2 streams) ---

  @doc """
  The session preface at the head of a WebTransport stream.

  In draft-ietf-webtrans-http2, an H2 stream is tied to a WebTransport session by prefixing
  it with the session id (the CONNECT stream id) as a varint. Direction (uni/bidi) is told
  apart by the H2 frame type, so it is not in the bytes (it travels separately in the
  `open_stream` sink event).
  """
  @spec stream_preface(non_neg_integer()) :: binary()
  def stream_preface(session_id), do: Varint.encode(session_id)

  @doc "Read the preface at the head of a stream. `{:ok, session_id, rest}` or `:more`."
  @spec parse_preface(binary()) :: {:ok, non_neg_integer(), binary()} | :more
  def parse_preface(bin), do: Varint.decode(bin)

  # --- Imperative face (emits framed events to the sink) ---

  @impl true
  def open_stream(%__MODULE__{} = conn, dir, opts \\ []) do
    # On H2, stream id allocation belongs to the H2 layer (L2). Here it is passed in.
    id = Keyword.fetch!(opts, :id)
    emit(conn, {:h2_open, id, dir, stream_preface(conn.session_id)})
    {:ok, {conn, id}}
  end

  @impl true
  def control({%__MODULE__{} = conn, id}, pid) do
    # No affine NIF handle to transfer as on QUIC. On H2 routing is by stream id, so control
    # is a registration: "deliver receives for this id to pid".
    emit(conn, {:h2_control, id, pid})
    :ok
  end

  @impl true
  def set_active({%__MODULE__{} = conn, id}, active) do
    # AXIS 2 survives as H2's per-stream WINDOW_UPDATE.
    emit(conn, {:h2_window, id, active})
    :ok
  end

  @impl true
  def send({%__MODULE__{} = conn, id}, data, opts \\ []) do
    fin = Keyword.get(opts, :fin, false)
    # A DATA frame. fin is END_STREAM.
    emit(conn, {:h2_out, id, data, fin})
    :ok
  end

  @impl true
  def shutdown({%__MODULE__{} = conn, id}, :write) do
    # Half-closing the write side = END_STREAM with an empty payload.
    emit(conn, {:h2_out, id, <<>>, true})
    :ok
  end

  def shutdown({%__MODULE__{} = conn, id}, {:reset, code}) do
    emit(conn, {:h2_reset, id, code})
    :ok
  end

  def shutdown({%__MODULE__{} = conn, id}, {:stop_sending, code}) do
    # H2 has no one-directional STOP_SENDING, only RST_STREAM. Fold into a reset of both
    # directions (half-close granularity thins out).
    emit(conn, {:h2_reset, id, code})
    :ok
  end

  @impl true
  def send_datagram(%__MODULE__{} = conn, data) do
    # Datagrams become DATAGRAM capsules, delivered reliably on the CONNECT stream (emulated).
    capsule = Capsule.encode(Capsule.datagram_type(), data)
    emit(conn, {:h2_out, conn.session_id, capsule, false})
    :ok
  end

  @impl true
  def close(%__MODULE__{} = conn, code) do
    emit(conn, {:h2_goaway, code})
    :ok
  end

  defp emit(%__MODULE__{sink: sink}, event), do: Kernel.send(sink, event)

  # --- Message face (pure; produces the same contract as Quicer.normalize) ---

  @doc """
  Translate an H2 demultiplexer event into the `Karutte.QuicTransport` contract.

  The point is to produce the same `{:quic, ...}` as `Quicer.normalize/1` (so the upper
  layers stay transport-independent). DATAGRAM capsules are unwrapped here back into
  `{:quic, :datagram, ...}`. Capsules of unknown type pass through as
  `{:quic, :capsule, conn, type, value}`.
  """
  @spec normalize(term()) ::
          Karutte.QuicTransport.stream_msg()
          | Karutte.QuicTransport.conn_msg()
          | {:quic, :capsule, term(), non_neg_integer(), binary()}
          | {:unknown, term()}

  def normalize({:h2, :data, stream, bin, fin?}) when is_binary(bin) and is_boolean(fin?),
    do: {:quic, :data, stream, bin, fin: fin?}

  def normalize({:h2, :new_stream, conn, stream, dir}) when dir in [:bidi, :uni],
    do: {:quic, :new_stream, conn, stream, dir}

  def normalize({:h2, :reset, stream, code}), do: {:quic, :reset, stream, code}
  def normalize({:h2, :closed, stream, reason}), do: {:quic, :closed, stream, reason}
  def normalize({:h2, :goaway, conn, reason}), do: {:quic, :closed, conn, reason}

  # A capsule on the CONNECT stream. Only DATAGRAM is turned back into a datagram.
  def normalize({:h2, :capsule, conn, bin}) when is_binary(bin) do
    case Capsule.decode(bin) do
      {:ok, type, value, _rest} ->
        if type == Capsule.datagram_type() do
          {:quic, :datagram, conn, value}
        else
          {:quic, :capsule, conn, type, value}
        end

      :more ->
        {:unknown, {:partial_capsule, bin}}
    end
  end

  def normalize(msg), do: {:unknown, msg}
end
