defmodule Karutte.WebTransport.Session do
  @moduledoc """
  L3 セッションランナー ＝ `Karutte.WebTransport` behaviour を実際に回す GenServer。

  制御面だけを持つ（不変条件: ストリームのバイトには触れない）。床から来るのは
  `Karutte.QuicTransport` の契約メッセージ（`normalize/1` 済みの `{:quic, …}`）だけ。
  **だから床に依らない** — QUIC でも HTTP/2 でも、このランナーは同じコードで回る。
  そこが層を分けたことのごほうび。

  受け持つこと:

    * `{:quic, :new_stream, …}` → `handle_stream/3` を呼び、返ってきた処分で分岐
      - `{:handler, mod, arg}` … `StreamServer` を起こし、handoff して所有権を渡す
      - `{:inline, max}`       … `Inline` 機械でバッファし、FIN で `handle_inline_stream/3`
      - `{:reset, code}`       … 要らないので reset
    * `{:quic, :datagram, …}`  → `handle_datagram/2`（軸の外。無ければ drop）
    * `{:quic, :closed, …}`    → 寿命の終わり
    * それ以外                 → `handle_info/2`

  handoff の順序（競合窓を閉じる）は `Karutte.WebTransport.Handoff` の約束に従う:
  先着分を吸い出す → 新オーナーへ渡す → `control/2` で床の宛先を切替。
  """

  use GenServer

  alias Karutte.{Inline, WebTransport.StreamServer}

  @typep st :: %{
           transport: module(),
           conn: term(),
           mod: module(),
           state: term(),
           inline: %{optional(term()) => Inline.t()},
           owners: %{optional(term()) => pid()}
         }

  @doc """
  起こす。`opts`:
    * `:transport` — `Karutte.QuicTransport` の実装モジュール（床）
    * `:conn`      — 床の接続ハンドル
    * `:handler`   — `Karutte.WebTransport` を満たすセッションモジュール
    * `:init_arg`  — `handler.init/2` の第一引数
    * `:conn_info` — `handler.init/2` の第二引数（既定 `%{}`）
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl true
  def init(opts) do
    mod = Keyword.fetch!(opts, :handler)
    init_arg = Keyword.get(opts, :init_arg)
    conn_info = Keyword.get(opts, :conn_info, %{})

    case mod.init(init_arg, conn_info) do
      {:ok, state} ->
        {:ok,
         %{
           transport: Keyword.fetch!(opts, :transport),
           conn: Keyword.fetch!(opts, :conn),
           mod: mod,
           state: state,
           inline: %{},
           owners: %{}
         }}

      {:stop, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:quic, :new_stream, _conn, stream, dir}, s) do
    {disp, state} = s.mod.handle_stream(stream, dir, s.state)
    {:noreply, dispatch(disp, stream, %{s | state: state})}
  end

  # inline と決めたストリームのバイト（control していないのでここに届く）。
  def handle_info({:quic, :data, stream, bin, meta}, s) when is_map_key(s.inline, stream) do
    fin? = Keyword.get(meta, :fin, false)

    case Inline.feed(s.inline[stream], {bin, fin?}) do
      {:cont, machine} ->
        {:noreply, put_in(s.inline[stream], machine)}

      {:done, full} ->
        state = call_optional(s.mod, :handle_inline_stream, [stream, full, s.state], s.state)
        {:noreply, %{s | state: state, inline: Map.delete(s.inline, stream)}}

      {:overflow, _max} ->
        s.transport.shutdown(stream, {:reset, 0})
        {:noreply, %{s | inline: Map.delete(s.inline, stream)}}
    end
  end

  def handle_info({:quic, :datagram, _conn, bin}, s) do
    state = call_optional(s.mod, :handle_datagram, [bin, s.state], s.state)
    {:noreply, %{s | state: state}}
  end

  def handle_info({:quic, :closed, _conn, reason}, s) do
    {:stop, {:shutdown, reason}, s}
  end

  def handle_info(msg, s) do
    if function_exported?(s.mod, :handle_info, 2) do
      case s.mod.handle_info(msg, s.state) do
        {:ok, state} -> {:noreply, %{s | state: state}}
        {:stop, reason, state} -> {:stop, reason, %{s | state: state}}
      end
    else
      {:noreply, s}
    end
  end

  @impl true
  def terminate(reason, s) do
    if function_exported?(s.mod, :terminate, 2), do: s.mod.terminate(reason, s.state)
    :ok
  end

  # --- 処分の分岐 ---

  @spec dispatch(Karutte.WebTransport.disposition(), term(), st()) :: st()
  defp dispatch({:handler, smod, arg}, stream, s) do
    {:ok, pid} =
      StreamServer.start_link(
        transport: s.transport,
        stream: stream,
        handler: smod,
        init_arg: arg
      )

    # 競合窓を閉じる handoff は床（control/2）の責務。床ごとに先着分の在り処が違う
    # （quicer は NIF バッファ、H3 は Connection の per-stream バッファ）ので、
    # 「先着分→handoff_done→live を pid へ順に渡す」を control が引き受ける。
    :ok = s.transport.control(stream, pid)
    put_in(s.owners[stream], pid)
  end

  defp dispatch({:inline, max}, stream, s), do: put_in(s.inline[stream], Inline.new(max))

  defp dispatch({:reset, code}, stream, s) do
    s.transport.shutdown(stream, {:reset, code})
    s
  end

  # optional callback: 実装が無ければ state を素通し（datagram は drop、inline は捨てる）。
  defp call_optional(mod, fun, args, default_state) do
    if function_exported?(mod, fun, length(args)) do
      {:ok, state} = apply(mod, fun, args)
      state
    else
      default_state
    end
  end
end
