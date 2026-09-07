defmodule Karutte.QuicTransport.Http3 do
  @moduledoc """
  The third real L1 transport: WebTransport over HTTP/3 (quicer + cowlib).

  Implements `Karutte.QuicTransport`, with the same face as `Quicer` (raw QUIC) and `Http2`
  (TCP). The layers above (Session, the StreamServer runner) run unchanged on top of it.

  ## Shape

  This transport is a **thin proxy**. The substance is `Karutte.Http3.Connection`, a GenServer
  that owns one QUIC connection. The Connection is quicer's sole owner, drives HTTP/3 through
  `cow_http3_machine`, and routes WebTransport streams and datagrams to the runner. So every
  transport operation lowers to a message to the Connection:

      conn    = {:h3c, conn_pid, qconn, session_id}
      stream  = {:h3s, conn_pid, qstream}

  Keeping ownership in one process means quicer's affine handles and the handoff race window
  are both settled inside the Connection, with no cross-process quicer ownership to untangle.
  """

  @behaviour Karutte.QuicTransport

  @type conn :: {:h3c, pid(), term(), non_neg_integer()}
  @type stream :: {:h3s, pid(), term()}

  @impl Karutte.QuicTransport
  def open_stream({:h3c, conn_pid, _qconn, sid}, dir, opts \\ []) do
    GenServer.call(conn_pid, {:open_stream, dir, sid, opts})
  end

  @impl Karutte.QuicTransport
  def control({:h3s, conn_pid, qs}, pid) do
    Kernel.send(conn_pid, {:set_owner, qs, pid})
    :ok
  end

  @impl Karutte.QuicTransport
  def set_active({:h3s, conn_pid, qs}, active) do
    Kernel.send(conn_pid, {:stream_set_active, qs, active})
    :ok
  end

  @impl Karutte.QuicTransport
  def send({:h3s, conn_pid, qs}, data, opts \\ []) do
    Kernel.send(conn_pid, {:stream_send, qs, data, Keyword.get(opts, :fin, false)})
    :ok
  end

  @impl Karutte.QuicTransport
  def shutdown({:h3s, conn_pid, qs}, how) do
    Kernel.send(conn_pid, {:stream_shutdown, qs, how})
    :ok
  end

  @impl Karutte.QuicTransport
  def send_datagram({:h3c, conn_pid, _qconn, sid}, data) do
    Kernel.send(conn_pid, {:datagram, sid, data})
    :ok
  end

  @impl Karutte.QuicTransport
  def close({:h3c, conn_pid, _qconn, sid}, code) do
    Kernel.send(conn_pid, {:close_session, sid, code})
    :ok
  end
end
