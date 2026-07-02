defmodule WtRelay.Observer do
  @moduledoc """
  見張り。tick ごとにカーネルから実測を読み、telemetry として出す。「管理してる感」の
  実体はここ。二層で flood を見る:

    * `[:wt_relay, :route, :counters]` — route × テーブル別の pkts/bytes。
      meta の `metric` が `:packets`（raw＝毎パケット量）/ `:new_flows`（mangle＝新規接続レート）
      / `:dnat`（nat＝転送）を区別する。この二つの比（packets / new_flows）が
      「なりすまし洪水 vs 正規接続」の指標になる。
    * `[:wt_relay, :conntrack, :count]` — conntrack の同時フロー総数（テーブル枯渇＝flood 時の
      実メモリ圧の gauge）。

  レート（毎秒）は下流（PromEx / sukhi admin）が差分で出す。ここは素の値を出すだけ。

  NATS(:gnat)が繋がっていれば、毎 tick その素の値を **snapshot として `wt_relay.telemetry`
  に publish** する。sukhi 側がそれを受けて admin に「一緒に」出す。NATS 未設定なら publish は
  no-op ＝観測は NATS 非依存のまま。

  TODO（同じ形で足せる）: wg の handshake 齢と tx/rx、実 IP 保存の健全性サンプル。
  """
  use GenServer
  alias WtRelay.Kernel.Iptables

  @conntrack_count "/proc/sys/net/netfilter/nf_conntrack_count"
  @telemetry_subject "wt_relay.telemetry"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    {:ok, schedule(%{interval: Keyword.get(opts, :interval_ms, 5_000)})}
  end

  @impl true
  def handle_info(:observe, state) do
    # counters は best-effort（あるテーブルの読みが失敗してもその行が欠けるだけ）。
    {:ok, rows} = Iptables.counters()
    Enum.each(rows, &emit/1)
    conntrack = read_conntrack()
    if conntrack, do: :telemetry.execute([:wt_relay, :conntrack, :count], %{count: conntrack}, %{})
    publish_snapshot(rows, conntrack)
    {:noreply, schedule(state)}
  end

  defp emit(row) do
    :telemetry.execute(
      [:wt_relay, :route, :counters],
      %{pkts: row.pkts, bytes: row.bytes},
      %{table: row.table, metric: row.metric, dport: row.dport, to: row.to}
    )
  end

  defp read_conntrack do
    with {:ok, raw} <- File.read(@conntrack_count),
         {n, _} <- Integer.parse(String.trim(raw)) do
      n
    else
      _ -> nil
    end
  end

  # NATS(:gnat)へ snapshot を投げる。:gnat 未起動（NATS 未設定）や NATS 断は無視。
  defp publish_snapshot(rows, conntrack) do
    snapshot = %{
      "ts" => System.system_time(:second),
      "conntrack" => conntrack,
      "routes" =>
        Enum.map(rows, fn r ->
          %{
            "table" => r.table,
            "metric" => to_string(r.metric),
            "dport" => r.dport,
            "pkts" => r.pkts,
            "bytes" => r.bytes
          }
        end)
    }

    Gnat.pub(:gnat, @telemetry_subject, IO.iodata_to_binary(:json.encode(snapshot)))
  rescue
    _ -> :ok
  end

  defp schedule(state) do
    Process.send_after(self(), :observe, state.interval)
    state
  end
end
