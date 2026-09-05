defmodule Karutte.WebTransportAdapter do
  @moduledoc """
  L2, the Plug seam: the escape hatch that upgrades a request into a WebTransport session.

  Same direction as `WebSockAdapter.upgrade/4`. Inside an ordinary Plug router:

      conn
      |> Karutte.WebTransportAdapter.upgrade(MySession, init_arg, opts)

  This lowers to `Plug.Conn.upgrade_adapter(conn, :webtransport, {MySession, init_arg, opts})`
  and rides the same promise WebSocket does: at the end of `call/2`, the server (Bandit) swaps
  the handler. Plug itself is untouched.

  ## Still waiting for a floor (honestly)

  Bandit interprets the `:websocket` escape hatch, but nothing in Bandit interprets
  `:webtransport` yet (no HTTP/3, and no Extended CONNECT to WebTransport over HTTP/2). So
  `upgrade/4` only puts **the right shape of the roof** in place. For a session to actually
  start, either Bandit needs to support it, or a transport of your own (an implementation of
  `Karutte.QuicTransport`) has to pick up the `upgrade_adapter` target and start a
  `Karutte.WebTransport.Session`. What is verified is the runner underneath, driven by its
  message contract. Today's real server, `Karutte.Http3.Server`, does not go through this seam.

  ## Extended CONNECT

  A WebTransport session is opened by the client's Extended CONNECT (`:method = CONNECT`,
  `:protocol = webtransport`; RFC 9220 / 8441 / draft-webtrans). Where a server surfaces the
  `:protocol` pseudo-header on `Plug.Conn` is implementation-specific, so
  `extended_connect?/2` takes the protocol as an argument, passed in by whichever server
  filled it.
  """

  @doc """
  Upgrade this request into a WebTransport session.

  `session_mod` implements the `Karutte.WebTransport` behaviour and `init_arg` is passed to
  its `init/2`. `opts` selects things like the transport (for example `transport: ...`).
  """
  @spec upgrade(Plug.Conn.t(), module(), term(), keyword()) :: Plug.Conn.t()
  def upgrade(conn, session_mod, init_arg, opts \\ []) do
    Plug.Conn.upgrade_adapter(conn, :webtransport, {session_mod, init_arg, opts})
  end

  @doc """
  Is this an Extended CONNECT for WebTransport? Pass the protocol the server filled in.
  """
  @spec extended_connect?(Plug.Conn.t(), String.t() | nil) :: boolean()
  def extended_connect?(%Plug.Conn{method: "CONNECT"}, "webtransport"), do: true
  def extended_connect?(%Plug.Conn{}, _protocol), do: false
end
