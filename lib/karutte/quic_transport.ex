defmodule Karutte.QuicTransport do
  @moduledoc """
  L1 の差し替え口（依存性逆転）。揺れている床はここだけ。

  具体実装（将来の `Karutte.QuicTransport.Quicer` など）がこの behaviour を満たす。
  上層（Session/Stream）は中身を知らない。

  ストリームハンドルは affine リソース＝controlling process はちょうど一つ。
  だから `control/2` で所有を一つの pid に移すのが基本操作。
  """

  @type conn :: term()
  @type stream :: term()
  @type dir :: :bidi | :uni
  @type code :: non_neg_integer()
  @type error :: {:error, term()}

  # --- 命令的な面（L3/L4 が呼ぶ） ---

  @doc "サーバ起点でストリームを開く"
  @callback open_stream(conn, dir, keyword()) :: {:ok, stream} | error

  @doc "このストリームの以後のイベントを pid へ手渡す（handoff の実体）"
  @callback control(stream, pid) :: :ok | error

  @doc """
  AXIS 2 のつまみ。あと何メッセージ届けたら passive に戻すか。
  passive に戻る＝下で QUIC_STATUS_PENDING＝MAX_STREAM_DATA の窓が伸びない。
  """
  @callback set_active(stream, :once | non_neg_integer() | boolean()) :: :ok | error

  @callback send(stream, iodata(), fin: boolean()) :: :ok | error

  @doc "FIN（書き側半閉じ）/ RESET_STREAM / STOP_SENDING"
  @callback shutdown(stream, :write | {:reset, code} | {:stop_sending, code}) :: :ok | error

  @doc "datagram 送信。フロー制御なし＝送り手側で落ちうる。best-effort。"
  @callback send_datagram(conn, iodata()) :: :ok | error

  @callback close(conn, code) :: :ok

  # --- メッセージ契約（所有プロセスのメールボックスに届く形） ---

  @type stream_msg ::
          {:quic, :data, stream, binary(), [fin: boolean()]}
          | {:quic, :passive, stream}
          | {:quic, :closed, stream, reason :: term()}
          | {:quic, :reset, stream, code}

  @typedoc "制御面（接続 owner だけが受ける）。data は流れてこない。"
  @type conn_msg ::
          {:quic, :new_stream, conn, stream, dir}
          | {:quic, :datagram, conn, binary()}
          | {:quic, :closed, conn, reason :: term()}
end
