defmodule Karutte.WebTransport do
  @moduledoc """
  L3 セッション behaviour ＝ 制御面だけ。
  accept / handoff の処分 / datagram の分配 / 寿命 を捌く。
  不変条件: **ストリームのバイトには絶対に触れない**（触れたら HoL が復活する）。

  Plug の縫い目（参考、別モジュールにはしない）:

      # ふつうの Plug router の中で:
      conn
      |> WebTransportAdapter.upgrade(MySession, init_arg, opts)
      # => Plug.Conn.upgrade_adapter(conn, :webtransport, {MySession, init_arg, opts})
      # WebSockAdapter.upgrade/4 と対称。Plug 自体は変えない。
  """

  alias Karutte.QuicTransport

  @type state :: term()

  @typedoc """
  peer が開いたストリームの処分。
  - {:handler, mod, arg} … 長命: owner プロセスを立てて Stream を回す
  - {:inline, max}      … 短命: FIN まで L3 が ≤max でバッファし一塊で渡す（太った datagram 扱い）
  - {:reset, code}      … 要らない
  """
  @type disposition ::
          {:handler, module(), term()}
          | {:inline, max_bytes :: pos_integer()}
          | {:reset, QuicTransport.code()}

  @doc """
  任意。CONNECT を受けるか諮る。セッションを起こす前に呼ばれる。

  `conn_info` には `:path` / `:authority` / `:headers`（Extended CONNECT の中身）が入る。
  `:ok` で受け（200）、`{:reject, status}` で断る（その status を返してストリームを閉じる）。
  認証・ルーティングの門番。実装が無ければ常に受ける。
  """
  @callback authorize(conn_info :: map()) :: :ok | {:reject, 100..599}

  @callback init(session :: term(), conn_info :: map()) :: {:ok, state} | {:stop, term()}

  @doc """
  AXIS 1 — MAX_STREAMS（生成の背圧）。
  ストリーム数の窓は **この callback が処分を返す速さ** でしか進まない。
  ここに active/demand のつまみは無い（生成と転送は別軸）。
  """
  @callback handle_stream(QuicTransport.stream(), QuicTransport.dir(), state) ::
              {disposition, state}

  @doc "{:inline, max} を選んだストリームが FIN まで揃ったとき、一塊で届く。L3 が組み立て、上限で reset 済み。"
  @callback handle_inline_stream(QuicTransport.stream(), binary(), state) :: {:ok, state}

  @doc """
  OFF-AXIS — datagram にフロー制御は無い（RFC 9221）。
  方針は drop であってブロックではない。背圧つまみを置かない＝ストリームの demand と混ざらない。
  落とす/落とさないは有界キューの **設定** であって、ここの返り値ではない。
  """
  @callback handle_datagram(binary(), state) :: {:ok, state}

  @callback handle_info(term(), state) :: {:ok, state} | {:stop, term(), state}

  @callback terminate(reason :: term(), state) :: term()

  @optional_callbacks authorize: 1,
                      handle_inline_stream: 3,
                      handle_datagram: 2,
                      handle_info: 2,
                      terminate: 2
end
