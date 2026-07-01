defmodule Karutte.QuicTransport.Http3 do
  @moduledoc """
  L1 の床、本物の三つ目 ＝ WebTransport over HTTP/3（quicer + cowlib）。

  `Karutte.QuicTransport` behaviour を満たす。`Quicer`（素の QUIC）/ `Http2`（TCP）と
  同じ顔。上層（Session / StreamServer runner）はこの床の上でも同じコードで回る。

  ## 形

  この床は **薄いプロキシ**で、実体は `Karutte.Http3.Connection`（QUIC 接続を一つ持つ
  GenServer）。Connection が quicer の唯一の所有者になり、cow_http3_machine で H3 を
  捌き、WT ストリーム/datagram を runner へ振る。だから床の命令は Connection への
  メッセージに落ちる:

      conn    = {:h3c, conn_pid, qconn, session_id}
      stream  = {:h3s, conn_pid, qstream}

  所有が一プロセスに集まることで、quicer のハンドルの affine 性も、handoff の競合窓も、
  Connection の中だけで閉じる（cross-process の quicer 所有権の綾を避ける）。
  """

  @behaviour Karutte.QuicTransport

  @type conn :: {:h3c, pid(), term(), non_neg_integer()}
  @type stream :: {:h3s, pid(), term()}

  @impl true
  def open_stream({:h3c, conn_pid, _qconn, sid}, dir, opts \\ []) do
    GenServer.call(conn_pid, {:open_stream, dir, sid, opts})
  end

  @impl true
  def control({:h3s, conn_pid, qs}, pid) do
    Kernel.send(conn_pid, {:set_owner, qs, pid})
    :ok
  end

  @impl true
  def set_active({:h3s, conn_pid, qs}, active) do
    Kernel.send(conn_pid, {:stream_set_active, qs, active})
    :ok
  end

  @impl true
  def send({:h3s, conn_pid, qs}, data, opts \\ []) do
    Kernel.send(conn_pid, {:stream_send, qs, data, Keyword.get(opts, :fin, false)})
    :ok
  end

  @impl true
  def shutdown({:h3s, conn_pid, qs}, how) do
    Kernel.send(conn_pid, {:stream_shutdown, qs, how})
    :ok
  end

  @impl true
  def send_datagram({:h3c, conn_pid, _qconn, sid}, data) do
    Kernel.send(conn_pid, {:datagram, sid, data})
    :ok
  end

  @impl true
  def close({:h3c, conn_pid, _qconn, sid}, code) do
    Kernel.send(conn_pid, {:close_session, sid, code})
    :ok
  end
end
