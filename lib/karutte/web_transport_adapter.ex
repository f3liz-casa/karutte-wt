defmodule Karutte.WebTransportAdapter do
  @moduledoc """
  L2 の縫い目 ＝ Plug の中で WebTransport セッションへ昇格する脱出口。

  `WebSockAdapter.upgrade/4` とまったく同じ向き。ふつうの Plug router の中で:

      conn
      |> Karutte.WebTransportAdapter.upgrade(MySession, init_arg, opts)

  これは `Plug.Conn.upgrade_adapter(conn, :webtransport, {MySession, init_arg, opts})`
  に落ちる。`call/2` の終わりにサーバ（Bandit）が handler を切り替える、という
  WebSocket と同じ約束に乗る。Plug 自体には触らない。

  ## まだ床待ちのところ（正直に）

  WebSocket は Bandit がこの `:websocket` 脱出口を解釈するが、`:webtransport` を
  解釈する仕組みは Bandit にまだ無い（HTTP/3 は未実装、HTTP/2 の Extended CONNECT →
  WebTransport も未対応）。だから `upgrade/4` は **屋根の正しい形**を置くだけで、
  実際にセッションが起きるには Bandit 側の対応か、自前の床（`Karutte.QuicTransport`
  の実装）が `upgrade_adapter` の宛先を拾って `Karutte.WebTransport.Session` を
  起こす配線が要る。verified なのは下のランナー（契約駆動）の方。

  ## Extended CONNECT

  WebTransport セッションはクライアントの Extended CONNECT で開く
  （`:method = CONNECT`, `:protocol = webtransport`、RFC 9220 / 8441 / draft-webtrans）。
  `:protocol` 擬似ヘッダを `Plug.Conn` のどこで surface するかはサーバ実装に依るので、
  `extended_connect?/2` は protocol を引数で受け取る（サーバが詰めたものを渡す）形にした。
  """

  @doc """
  この request を WebTransport セッションへ昇格させる。

  `session_mod` は `Karutte.WebTransport` behaviour を満たすモジュール。
  `init_arg` がその `init/2` に渡る。`opts` は床の選択など（例: `transport: …`）。
  """
  @spec upgrade(Plug.Conn.t(), module(), term(), keyword()) :: Plug.Conn.t()
  def upgrade(conn, session_mod, init_arg, opts \\ []) do
    Plug.Conn.upgrade_adapter(conn, :webtransport, {session_mod, init_arg, opts})
  end

  @doc """
  Extended CONNECT（WebTransport）かどうか。protocol はサーバが詰めたものを渡す。
  """
  @spec extended_connect?(Plug.Conn.t(), String.t() | nil) :: boolean()
  def extended_connect?(%Plug.Conn{method: "CONNECT"}, "webtransport"), do: true
  def extended_connect?(%Plug.Conn{}, _protocol), do: false
end
