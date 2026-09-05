defmodule Karutte.WebTransport do
  @moduledoc """
  L3, the session behaviour. Control plane only.

  It handles accept, the disposition of each new stream, datagram delivery, and the session's
  lifetime. One invariant: **it never touches stream bytes**. The moment it does, head-of-line
  blocking is back.

  The Plug seam, for reference (kept in `Karutte.WebTransportAdapter`):

      # inside an ordinary Plug router:
      conn
      |> WebTransportAdapter.upgrade(MySession, init_arg, opts)
      # => Plug.Conn.upgrade_adapter(conn, :webtransport, {MySession, init_arg, opts})
      # mirrors WebSockAdapter.upgrade/4; Plug itself is untouched.
  """

  alias Karutte.QuicTransport

  @type state :: term()

  @typedoc """
  What to do with a stream the peer opened.

  - `{:handler, mod, arg}`: long-lived. Start an owner process that runs `mod` as a `Karutte.WebTransport.Stream`.
  - `{:inline, max}`: short-lived. L3 buffers it up to `max` bytes until FIN and delivers it whole (think "a fat datagram").
  - `{:reset, code}`: not wanted.
  """
  @type disposition ::
          {:handler, module(), term()}
          | {:inline, max_bytes :: pos_integer()}
          | {:reset, QuicTransport.code()}

  @doc """
  Optional. Decide whether to accept the CONNECT. Called before the session process exists.

  `conn_info` carries `:path`, `:authority`, `:headers` (the Extended CONNECT request) and
  `:peer`. Return `:ok` to accept (200) or `{:reject, status}` to refuse with that status and
  close the stream. This is the gate for authentication and routing. Without an implementation,
  everything is accepted.
  """
  @callback authorize(conn_info :: map()) :: :ok | {:reject, 100..599}

  @callback init(session :: term(), conn_info :: map()) :: {:ok, state} | {:stop, term()}

  @doc """
  AXIS 1, MAX_STREAMS (backpressure on stream creation).

  The stream-count window only advances as fast as **this callback returns a disposition**.
  There is no active/demand knob here: creation and transfer are separate axes.
  """
  @callback handle_stream(QuicTransport.stream(), QuicTransport.dir(), state) ::
              {disposition, state}

  @doc """
  A stream that was dispositioned `{:inline, max}` arrives here whole once its FIN is in.
  L3 assembled it and has already reset anything over the limit.
  """
  @callback handle_inline_stream(QuicTransport.stream(), binary(), state) :: {:ok, state}

  @doc """
  OFF-AXIS. Datagrams have no flow control (RFC 9221).

  The policy is drop, not block. There is no backpressure knob here, so it can never get
  tangled with stream demand. Whether datagrams are dropped is a **setting** on the bounded
  queue, not a return value from this callback.
  """
  @callback handle_datagram(binary(), state) :: {:ok, state}

  @doc """
  Optional. Ordinary messages sent to the session process.

  `:wt_ready` arrives right after the session is established. From then on the handler may
  open **server-initiated streams** with `transport.open_stream(conn, :uni)` (`conn` is in the
  `conn_info` given to `init/2`). Before that, during `init/2`, the session is not yet up and
  streams cannot be opened.
  """
  @callback handle_info(term(), state) :: {:ok, state} | {:stop, term(), state}

  @callback terminate(reason :: term(), state) :: term()

  @optional_callbacks authorize: 1,
                      handle_inline_stream: 3,
                      handle_datagram: 2,
                      handle_info: 2,
                      terminate: 2
end
