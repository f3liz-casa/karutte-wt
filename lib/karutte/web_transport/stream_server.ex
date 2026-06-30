defmodule Karutte.WebTransport.StreamServer do
  @moduledoc """
  L4 ストリームランナー ＝ `Karutte.WebTransport.Stream` behaviour を回す GenServer。
  1 ストリーム = 1 プロセス（affine な床のハンドルの唯一の所有者）。

  これも床に依らない。契約メッセージ（`{:quic, :data, …}`）を受けて `handle_in/2` /
  `handle_fin/1` を呼び、返ってきた `ret` を床の命令へ翻訳する:

      {:ok, state, demand}        → set_active(demand)
      {:push, data, state, demand} → send(data); set_active(demand)
      {:push_fin, data, state}     → send(data, fin: true)
      {:close_write, state}        → shutdown(:write)
      {:reset, code, state}        → shutdown({:reset, code}); 終了
      {:stop, reason, state}       → 終了

  `demand`（`active:`）だけが per-stream の窓つまみ ＝ AXIS 2（MAX_STREAM_DATA）。
  ここにしか出てこない。

  ## handoff の順序

  `init` で `start_link` がブロックするので、その中で handoff を待つとセッションと
  デッドロックする（セッションは `start_link` が返ってから `complete/2` を呼ぶ）。
  だから `init` は `mod.init/2` で初期 state と初期 demand を作るだけにして、
  **active 化はしない**。handoff の待ち・先着分の再生・active 化は `handle_continue`
  に逃がす。これで「吸い出す → 渡す → 再生 → active 化」の一直線が守られる。
  """

  use GenServer

  alias Karutte.WebTransport.Handoff

  @typep st :: %{
           transport: module(),
           stream: term(),
           mod: module(),
           state: term(),
           demand: keyword()
         }

  @doc """
  起こす。`opts`:
    * `:transport` — 床のモジュール
    * `:stream`    — 床のストリームハンドル
    * `:handler`   — `Karutte.WebTransport.Stream` を満たすモジュール
    * `:init_arg`  — `handler.init/2` の第二引数
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    transport = Keyword.fetch!(opts, :transport)
    stream = Keyword.fetch!(opts, :stream)
    mod = Keyword.fetch!(opts, :handler)
    init_arg = Keyword.get(opts, :init_arg)

    s = %{transport: transport, stream: stream, mod: mod, state: nil, demand: []}
    # init の ret から state と初期 demand を取るが、active 化は handoff 後まで待つ。
    {s, action} = absorb(mod.init(stream, init_arg), s, _activate? = false)

    case action do
      :cont -> {:ok, s, {:continue, :handoff}}
      {:stop, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:handoff, s) do
    case Handoff.wait(s.stream) do
      {:ok, buffered} ->
        # 先着分を順序のまま handle_in に流す（active 化はまだ）。終端なら止まる。
        result =
          Enum.reduce_while(buffered, {s, :cont}, fn {bin, meta}, {acc, :cont} ->
            case feed(bin, meta, acc, false) do
              {acc2, :cont} -> {:cont, {acc2, :cont}}
              stop -> {:halt, stop}
            end
          end)

        case result do
          # ここで初めて active 化（init と先着再生で決まった demand を床へ渡す）。
          {s, :cont} ->
            activate(s)
            {:noreply, s}

          {s, {:stop, reason}} ->
            {:stop, reason, s}
        end

      {:error, :handoff_timeout} ->
        {:stop, :handoff_timeout, s}
    end
  end

  @impl true
  def handle_info({:quic, :data, stream, bin, meta}, %{stream: stream} = s) do
    case feed(bin, meta, s, true) do
      {s, :cont} -> {:noreply, s}
      {s, {:stop, reason}} -> {:stop, reason, s}
    end
  end

  def handle_info({:quic, :reset, stream, code}, %{stream: stream} = s) do
    {:stop, {:shutdown, {:reset, code}}, s}
  end

  def handle_info({:quic, :closed, stream, reason}, %{stream: stream} = s) do
    {:stop, {:shutdown, reason}, s}
  end

  def handle_info(msg, s) do
    if function_exported?(s.mod, :handle_info, 2) do
      drive(s.mod.handle_info(msg, s.state), s, true)
    else
      {:noreply, s}
    end
  end

  @impl true
  def terminate(reason, s) do
    if function_exported?(s.mod, :terminate, 2), do: s.mod.terminate(reason, s.state)
    :ok
  end

  # data（と meta の FIN）を handle_in → handle_fin に流し、ret を翻訳する。
  # 終端アクションは握り潰さず後段へ通す。activate? が true のときだけ demand を
  # 床へ即反映（handoff 中は false で貯める）。
  defp feed(bin, meta, s, activate?) do
    step1 =
      if bin == <<>>,
        do: {s, :cont},
        else: absorb(s.mod.handle_in(bin, s.state), s, activate?)

    fin? = Keyword.get(meta, :fin, false)

    case step1 do
      {s, :cont} when fin? ->
        if function_exported?(s.mod, :handle_fin, 1),
          do: absorb(s.mod.handle_fin(s.state), s, activate?),
          else: {s, :cont}

      other ->
        other
    end
  end

  # GenServer の戻り値が要る経路（handle_info）向けの薄い包み。
  defp drive(ret, s, activate?) do
    case absorb(ret, s, activate?) do
      {s, :cont} -> {:noreply, s}
      {s, {:stop, reason}} -> {:stop, reason, s}
    end
  end

  # ret を解釈して副作用を出し、state/demand を更新。返り: {state, :cont | {:stop, reason}}。
  @spec absorb(Karutte.WebTransport.Stream.ret(), st(), boolean()) :: {st(), :cont | {:stop, term()}}
  defp absorb({:ok, state, demand}, s, activate?),
    do: {set_demand(%{s | state: state}, demand, activate?), :cont}

  defp absorb({:push, data, state, demand}, s, activate?) do
    s.transport.send(s.stream, data)
    {set_demand(%{s | state: state}, demand, activate?), :cont}
  end

  defp absorb({:push_fin, data, state}, s, _activate?) do
    s.transport.send(s.stream, data, fin: true)
    {%{s | state: state}, :cont}
  end

  defp absorb({:close_write, state}, s, _activate?) do
    s.transport.shutdown(s.stream, :write)
    {%{s | state: state}, :cont}
  end

  defp absorb({:reset, code, state}, s, _activate?) do
    s.transport.shutdown(s.stream, {:reset, code})
    {%{s | state: state}, {:stop, {:shutdown, {:reset, code}}}}
  end

  defp absorb({:stop, reason, state}, s, _activate?), do: {%{s | state: state}, {:stop, reason}}

  # demand を貯める（handoff 中）か、即床へ反映するか。
  defp set_demand(s, demand, true) do
    activate(%{s | demand: demand})
    %{s | demand: demand}
  end

  defp set_demand(s, demand, false), do: %{s | demand: demand}

  defp activate(%{demand: demand} = s) do
    case Keyword.fetch(demand, :active) do
      {:ok, active} -> s.transport.set_active(s.stream, active)
      :error -> :ok
    end
  end
end
