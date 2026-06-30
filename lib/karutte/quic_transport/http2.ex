defmodule Karutte.QuicTransport.Http2 do
  @moduledoc """
  L1 のもう一つの実装 ＝ WebTransport over HTTP/2（draft-ietf-webtrans-http2, TCP）。

  これが層を分けたことの本当のごほうび。`Karutte.QuicTransport` という **同じ
  behaviour** を、QUIC（`Quicer`）と HTTP/2 の二つが満たす。上層（Session /
  Stream）はどちらの床の上かを知らないまま、文字どおり同じコードで回る。
  QUIC を待たずに、TCP の上で今日動く版。

  ## 三軸は H2 へどう写るか — survive するもの、痩せるもの

      QUIC                     HTTP/2 での居場所                       具合
      ─────────────────────────────────────────────────────────────────────
      MAX_STREAMS（生成）      SETTINGS_MAX_CONCURRENT_STREAMS         survive
      MAX_STREAM_DATA（転送）  H2 ストリーム別 WINDOW_UPDATE           survive
      MAX_DATA（接続）         H2 接続レベル WINDOW_UPDATE             survive
      datagram（軸の外）       DATAGRAM カプセル（RFC 9297）で信頼配送  痩せる

  ストリームの背圧（AXIS 1/2）は H2 にも別々の窓があるので、そのまま渡る。
  痩せるのは datagram だけ — H2 には datagram が無いので、CONNECT ストリーム
  上のカプセルで運ぶ＝**信頼・順序つきの擬似 datagram**。不確実 best-effort
  という性質は失われる（正しいが意味論は痩せるフォールバック）。

  HoL ブロッキングも戻る（TCP なので）。これは床の選択そのもので、上層の
  かたちとは無関係。

  ## sink — L2 が差し込む H2 書き手の場所

  まだ H2 サーバ（Bandit）との縫い目（L2）が無いので、ここでは命令の出口を
  **sink（pid）** に逃がしてある。`Quicer` が quicer を差し替え口の裏に隠すのと
  同じ向きの依存性逆転で、テストでは sink に `self()` を置いて出ていくフレームを
  確かめられる。L2 を書くときは sink を本物の H2 接続プロセスに差し替える。

  受信側は `normalize/1` が H2 デマルチプレクサの吐くイベントを、`Quicer` と
  **同じ `{:quic, …}` 契約** へ畳む。二つの normalize が同じかたちを作ることが、
  上層が床に依らない証拠。`test/http2_test.exs` が往復と同形を押さえる。

  出典: <https://datatracker.ietf.org/doc/html/draft-ietf-webtrans-http2> /
  RFC 9297（Capsule）
  """

  @behaviour Karutte.QuicTransport

  alias Karutte.{Capsule, Varint}

  @typedoc """
  H2 上のセッション一つ。`session_id` は CONNECT ストリームの id（draft では
  この id が WebTransport ストリームを session に紐づける前置き）。
  """
  @type t :: %__MODULE__{sink: pid(), session_id: non_neg_integer()}
  defstruct [:sink, :session_id]

  @doc "テスト / L2 用。sink と session id から conn を作る。"
  @spec new(pid(), non_neg_integer()) :: t()
  def new(sink, session_id) when is_pid(sink) and is_integer(session_id) do
    %__MODULE__{sink: sink, session_id: session_id}
  end

  # --- フレーミング（純粋。WT/H2 ストリームの session 前置き） ---

  @doc """
  WebTransport ストリームの先頭に付く session 前置き。

  draft-ietf-webtrans-http2 では、H2 ストリームを WebTransport の session に
  紐づけるために session id（CONNECT ストリーム id）を varint で前置きする。
  方向（uni/bidi）は H2 のフレーム種別で区別されるので、バイト列には乗らない
  （`open_stream` の sink イベントで別に渡す）。
  """
  @spec stream_preface(non_neg_integer()) :: binary()
  def stream_preface(session_id), do: Varint.encode(session_id)

  @doc "ストリーム先頭の前置きを読む。`{:ok, session_id, rest}` か `:more`。"
  @spec parse_preface(binary()) :: {:ok, non_neg_integer(), binary()} | :more
  def parse_preface(bin), do: Varint.decode(bin)

  # --- 命令の面（sink へ framed イベントを出す） ---

  @impl true
  def open_stream(%__MODULE__{} = conn, dir, opts \\ []) do
    # H2 ではストリーム id の採番は H2 層（L2）の仕事。ここでは渡してもらう。
    id = Keyword.fetch!(opts, :id)
    emit(conn, {:h2_open, id, dir, stream_preface(conn.session_id)})
    {:ok, {conn, id}}
  end

  @impl true
  def control({%__MODULE__{} = conn, id}, pid) do
    # QUIC のような affine な NIF ハンドルの移譲は無い。H2 ではストリーム id で
    # 経路を引くだけなので、control は「この id の受信を pid へ流す」登録になる。
    emit(conn, {:h2_control, id, pid})
    :ok
  end

  @impl true
  def set_active({%__MODULE__{} = conn, id}, active) do
    # AXIS 2 は H2 のストリーム別 WINDOW_UPDATE として survive する。
    emit(conn, {:h2_window, id, active})
    :ok
  end

  @impl true
  def send({%__MODULE__{} = conn, id}, data, opts \\ []) do
    fin = Keyword.get(opts, :fin, false)
    # DATA フレーム。fin は END_STREAM。
    emit(conn, {:h2_out, id, data, fin})
    :ok
  end

  @impl true
  def shutdown({%__MODULE__{} = conn, id}, :write) do
    # 書き側半閉じ = 空ペイロードの END_STREAM。
    emit(conn, {:h2_out, id, <<>>, true})
    :ok
  end

  def shutdown({%__MODULE__{} = conn, id}, {:reset, code}) do
    emit(conn, {:h2_reset, id, code})
    :ok
  end

  def shutdown({%__MODULE__{} = conn, id}, {:stop_sending, code}) do
    # H2 には片方向の STOP_SENDING が無く RST_STREAM しか無い。両方向リセットへ畳む
    # （半閉じの粒度は痩せる）。
    emit(conn, {:h2_reset, id, code})
    :ok
  end

  @impl true
  def send_datagram(%__MODULE__{} = conn, data) do
    # datagram は DATAGRAM カプセルにして CONNECT ストリーム上を信頼配送（擬似化）。
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

  # --- メッセージの面（純粋。Quicer.normalize と同じ契約を作る） ---

  @doc """
  H2 デマルチプレクサのイベントを `Karutte.QuicTransport` の契約へ翻訳する。

  `Quicer.normalize/1` と同じ `{:quic, …}` を作るのが肝（上層が床に依らない）。
  DATAGRAM カプセルはここで解いて `{:quic, :datagram, …}` に戻す。知らない型の
  カプセルは `{:quic, :capsule, conn, type, value}` で素通し。
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

  # CONNECT ストリーム上のカプセル。DATAGRAM だけ datagram に戻す。
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
