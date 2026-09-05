defmodule Karutte.WebTransport.Stream do
  @moduledoc """
  L4, the stream behaviour. Data plane. One stream = one process running this.

  It is almost the same shape as WebSock. Only two things differ:

    1. Demand is visible. WebSocket is always active and TCP hides the window underneath;
       here the window is yours.
    2. Half-close. FIN is per direction, which WebSocket does not have.
  """

  alias Karutte.QuicTransport

  @type state :: term()

  @typedoc """
  AXIS 2, MAX_STREAM_DATA. Attached to every return. This is the only per-stream window knob.
  """
  @type demand :: [active: :once | non_neg_integer() | boolean()]

  @type ret ::
          {:ok, state, demand}
          | {:push, iodata(), state, demand}
          | {:push_fin, iodata(), state}
          | {:close_write, state}
          | {:reset, QuicTransport.code(), state}
          | {:stop, reason :: term(), state}

  @callback init(QuicTransport.stream(), init_arg :: term()) :: ret

  @doc """
  Bytes from the peer. The demand you return here is, literally, the flow-control credit
  handed back to them.
  """
  @callback handle_in(binary(), state) :: ret

  @doc "The peer half-closed its write side (we saw FIN). We can still write."
  @callback handle_fin(state) :: ret

  @callback handle_info(term(), state) :: ret

  @callback terminate(reason :: term(), state) :: term()

  @optional_callbacks handle_fin: 1, handle_info: 2, terminate: 2
end
