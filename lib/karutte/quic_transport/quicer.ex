defmodule Karutte.QuicTransport.Quicer do
  @moduledoc """
  L1 の具体実装 ＝ emqx の `quicer`（msquic の NIF）に接ぐ。本物の床。

  `Karutte.QuicTransport` behaviour を満たす。上層（Session/Stream）はこの
  モジュールの存在を知らない。差し替え口の裏。

  二つの面でできている:

    * **命令の面**（`open_stream` / `control` / `set_active` / `send` / …）—
      quicer の関数へ薄く委譲するだけ。
    * **メッセージの面**（`normalize/1`）— quicer がオーナーのメールボックスへ
      投げるネイティブなタプルを、behaviour の `{:quic, …}` 契約へ翻訳する。
      ここが翻訳の要で、純粋。`test/quicer_normalize_test.exs` が押さえる。

  ## 正直なほつれ

  quicer は **Preview** で、ネイティブなメッセージのかたちはバージョンで揺れる。
  だから `normalize/1` は知っているタプルだけ畳んで、知らないものは
  `{:unknown, msg}` で素通しする（落とさない）。命令の面はまだ実 NIF に
  当てて走らせていない＝玩具と本物の境目。`normalize/1` だけが verified。

  ## active/passive → PENDING の鎖

  `set_active(stream, :once | n | false)` は quicer の `setopt(:active, …)` に落ちる。
  active が尽きて passive に戻ると、NIF は `is_recv_pending` を立て、msquic へ
  `QUIC_STATUS_PENDING` を返して以後の receive callback を止める。止まれば
  MAX_STREAM_DATA の窓が伸びず、送り手がブロックされる。これが AXIS 2 の実体。

  出典: <https://hexdocs.pm/quicer/messages_to_owner.html> /
  <https://github.com/microsoft/msquic/blob/main/docs/Streams.md>
  """

  @behaviour Karutte.QuicTransport

  import Bitwise, only: [band: 2]

  # --- msquic のフラグ（接いだときに効く定数。出典は msquic の API ヘッダ） ---
  @recv_flag_fin 0x1
  @stream_open_flag_unidirectional 0x1
  @send_flag_fin 0x2
  @stream_shutdown_graceful 0x1
  @stream_shutdown_abort_send 0x2
  @stream_shutdown_abort_receive 0x4

  # --- 命令の面 ---

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

  # quicer は optional。接ぐまではこの一点で正直に止まる（リポジトリは依存ゼロで緑のまま）。
  defp call(fun, args) when is_atom(fun) and is_list(args) do
    unless Code.ensure_loaded?(:quicer) do
      raise """
      Karutte.QuicTransport.Quicer は :quicer（msquic NIF）を要ります。
      mix.exs に {:quicer, "~> 0.1"} を足して mix deps.get してください。
      """
    end

    apply(:quicer, fun, args)
  end

  # --- メッセージの面（純粋。ここだけ verified） ---

  @doc """
  quicer のネイティブメッセージを `Karutte.QuicTransport` の契約へ翻訳する。

  知らないかたちは `{:unknown, msg}` で素通し（Preview の揺れに落とされない）。
  """
  @spec normalize(term()) ::
          Karutte.QuicTransport.stream_msg()
          | Karutte.QuicTransport.conn_msg()
          | {:unknown, term()}

  # ストリームデータ: {quic, Bin, Stream, Props}。FIN は Props の flags ビット。
  def normalize({:quic, bin, stream, props}) when is_binary(bin) and is_map(props) do
    {:quic, :data, stream, bin, fin: fin?(props)}
  end

  # peer の書き側半閉じ（FIN だけ、データ無し）。
  def normalize({:quic, :peer_send_shutdown, stream, _}),
    do: {:quic, :data, stream, <<>>, fin: true}

  # peer の RESET_STREAM。
  def normalize({:quic, :peer_send_aborted, stream, code}),
    do: {:quic, :reset, stream, code}

  # active が尽きて passive に戻った（AXIS 2 の窓が止まる合図）。
  def normalize({:quic, :passive, stream, _}), do: {:quic, :passive, stream}

  # ストリームが閉じた。
  def normalize({:quic, :stream_closed, stream, reason}),
    do: {:quic, :closed, stream, reason}

  # 接続オーナーへ: peer が開いた新ストリーム。dir は flags のビット。
  def normalize({:quic, :new_stream, stream, props}) when is_map(props) do
    dir = if band(Map.get(props, :flags, 0), @stream_open_flag_unidirectional) != 0, do: :uni, else: :bidi
    {:quic, :new_stream, conn_of(props), stream, dir}
  end

  # 接続オーナーへ: datagram 着（フロー制御なし＝軸の外）。
  def normalize({:quic, :dgram, conn, bin}) when is_binary(bin),
    do: {:quic, :datagram, conn, bin}

  # 接続が閉じた / transport が落ちた。
  def normalize({:quic, :shutdown, conn, reason}), do: {:quic, :closed, conn, reason}
  def normalize({:quic, :closed, conn, reason}), do: {:quic, :closed, conn, reason}
  def normalize({:quic, :transport_shutdown, conn, reason}),
    do: {:quic, :closed, conn, reason}

  def normalize(msg), do: {:unknown, msg}

  defp fin?(props), do: band(Map.get(props, :flags, 0), @recv_flag_fin) != 0
  # new_stream の Props に conn が同梱されないバージョンもある。無ければ nil（L2 が補う）。
  defp conn_of(props), do: Map.get(props, :conn)
end
