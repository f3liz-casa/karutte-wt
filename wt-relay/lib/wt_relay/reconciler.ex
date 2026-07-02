defmodule WtRelay.Reconciler do
  @moduledoc """
  庭師。tick ごとに spec を読み、望ましい WT_RELAY を組み、実状態とズレていれば
  最小限に直す。適用は原子的（Iptables.render → restore）。

  親切さ: 適用に失敗しても daemon は落とさない。ログと telemetry を出して last-known を
  保ち、次 tick で再試行する。`dry_run: true` のときは差分を出すだけで適用しない。

  ここが落ちても WT_RELAY チェーン（＝データ面）はカーネルに残るので、転送は止まらない。
  """
  use GenServer
  require Logger
  alias WtRelay.{Spec, Kernel.Iptables}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "手で一回収束させる（設定を変えた直後など）。"
  def reconcile_now, do: GenServer.cast(__MODULE__, :reconcile_now)

  @impl true
  def init(opts) do
    state = %{
      interval: Keyword.get(opts, :interval_ms, 10_000),
      dry_run: Keyword.get(opts, :dry_run, false),
      last: nil
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_info(:reconcile, state), do: {:noreply, schedule(reconcile(state))}

  @impl true
  def handle_cast(:reconcile_now, state), do: {:noreply, reconcile(state)}

  defp reconcile(state) do
    routes = Spec.routes()
    desired = Iptables.render(routes)
    meta = %{routes: length(routes)}

    cond do
      desired == state.last ->
        :telemetry.execute([:wt_relay, :reconcile, :noop], meta, %{})
        state

      state.dry_run ->
        Logger.info("[wt_relay] dry_run: would apply #{length(routes)} route(s)")
        :telemetry.execute([:wt_relay, :reconcile, :dry_run], meta, %{})
        state

      true ->
        apply_desired(state, routes, desired, meta)
    end
  end

  defp apply_desired(state, routes, desired, meta) do
    case Iptables.apply(routes) do
      :ok ->
        Logger.info("[wt_relay] applied #{length(routes)} route(s)")
        :telemetry.execute([:wt_relay, :reconcile, :applied], meta, %{})
        %{state | last: desired}

      {:error, {code, out}} ->
        # 落とさない。last は据え置き＝次 tick で再試行。カーネルの旧ルールは生きたまま。
        Logger.error("[wt_relay] apply failed (#{code}): #{String.trim(out)}")
        :telemetry.execute([:wt_relay, :reconcile, :failed], %{code: code}, %{output: out})
        state
    end
  end

  defp schedule(state) do
    Process.send_after(self(), :reconcile, state.interval)
    state
  end
end
