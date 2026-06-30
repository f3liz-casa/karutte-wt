defmodule Karutte.WebTransport.Stream do
  @moduledoc """
  L4 ストリーム behaviour ＝ データ面。1 ストリーム = 1 プロセスがこれを回す。
  WebSock とほぼ同型。違いは二つだけ:

    1. demand 旋（WebSocket は常時 active で TCP が下で隠すが、ここは見える）
    2. half-close（FIN は方向ごと。WebSocket には無い）
  """

  alias Karutte.QuicTransport

  @type state :: term()

  @typedoc "AXIS 2 — MAX_STREAM_DATA。返すたびに付く。ここだけが per-stream の窓つまみ。"
  @type demand :: [active: :once | non_neg_integer() | boolean()]

  @type ret ::
          {:ok, state, demand}
          | {:push, iodata(), state, demand}
          | {:push_fin, iodata(), state}
          | {:close_write, state}
          | {:reset, QuicTransport.code(), state}
          | {:stop, reason :: term(), state}

  @callback init(QuicTransport.stream(), init_arg :: term()) :: ret

  @doc "peer からのバイト。ここで返す demand が、相手に返すフロー制御クレジットそのもの。"
  @callback handle_in(binary(), state) :: ret

  @doc "peer が書き側を半閉じした（FIN を見た）。こちらはまだ書ける。"
  @callback handle_fin(state) :: ret

  @callback handle_info(term(), state) :: ret

  @callback terminate(reason :: term(), state) :: term()

  @optional_callbacks handle_fin: 1, handle_info: 2, terminate: 2
end
