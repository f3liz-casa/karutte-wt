defmodule Karutte.Http3.Echo do
  @moduledoc """
  例 ＝ いちばん素朴な WebTransport ハンドラ。受けたものを、そのまま返す。

  二つの面を持つ:

    * `Karutte.WebTransport`（このモジュール）… セッションの制御面。
      peer が開いたストリームは `Echo.Stream` に任せ、datagram は折り返す。
    * `Karutte.Http3.Echo.Stream`（下のネスト）… ストリームのデータ面。
      届いたバイトをそのまま push し、FIN を見たら書き側も閉じる。

  datagram を折り返すには「送る口」が要る。behaviour の `handle_datagram/2` は
  返り値で送れない（軸の外で push を持たない）ので、`init/2` の `conn_info` から
  床と接続ハンドルを受け取って state にしまっておき、そこから送り返す。
  """

  @behaviour Karutte.WebTransport

  @impl true
  def init(_arg, conn_info) do
    # conn_info に床（transport）と接続ハンドル（conn）が入っている前提。
    # datagram の折り返しはこの二つが要る。
    {:ok, %{transport: conn_info.transport, conn: conn_info.conn}}
  end

  @impl true
  def handle_stream(_stream, _dir, state) do
    # どのストリームも echo に任せる（長命オーナーを立てる）。
    {{:handler, __MODULE__.Stream, nil}, state}
  end

  @impl true
  def handle_datagram(bin, state) do
    state.transport.send_datagram(state.conn, bin)
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  defmodule Stream do
    @moduledoc "echo のデータ面。届いたバイトを返し、FIN で書き側を閉じる。"

    @behaviour Karutte.WebTransport.Stream

    @impl true
    def init(_stream, _arg), do: {:ok, %{}, active: true}

    @impl true
    def handle_in(bin, state), do: {:push, bin, state, active: true}

    @impl true
    def handle_fin(state), do: {:close_write, state}

    @impl true
    def terminate(_reason, _state), do: :ok
  end
end
