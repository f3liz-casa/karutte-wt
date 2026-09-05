defmodule WtRelay.Kernel.Iptables do
  @moduledoc """
  自分専用のチェーン `WT_RELAY` を、要るテーブルごとに*所有*する。reconcile は毎回
  そのチェーンを spec から丸ごと組み直す ＝ 状態は常に spec と一致（orphan が残らない。
  kube-proxy や docker が自分のチェーンを持つのと同じ発想）。

  route のモードでテーブルが決まる:

    * `:dnat`    → **nat** に DNAT ルート（転送）。
    * `:observe` → **raw** に毎パケット count（`-j RETURN` で素通し）＋
                   **mangle** に conntrack NEW の新規フロー count。数えるだけ。

  適用は `iptables-restore -n` で**テーブルごと原子的に差し替え**る（`-F`→`-A` の逐次適用が
  作る「一瞬の窓」を避ける）。PREROUTING からの jump だけは restore と別に一度張る
  （noflush restore で PREROUTING に足すと毎回二重になる）。

  データ面（dnat のとき）はこのチェーン＝カーネルに居る。observe は数えるだけなので、
  どちらにせよこの module は「望ましいルール集合の維持」だけを担い、パケットの通り道そのもの
  には立たない。
  """
  alias WtRelay.{Route, Kernel.Cmd}

  @chain "WT_RELAY"

  # observe の二層と、dnat の一層。restore ではこの順で並べる（並び順は無関係だが安定に）。
  @tables ["raw", "mangle", "nat"]

  @doc """
  あるテーブルの WT_RELAY に入る行。純粋関数。空でも（route が無くても）呼べる＝その場合 []。
  全テーブルを常に管理する（空でも flush する）ので、mode 切替で古い行が orphan にならない。
  """
  @spec lines_for([Route.t()], String.t()) :: [String.t()]
  def lines_for(routes, "nat"), do: for(r <- routes, r.mode == :dnat, do: dnat_line(r))
  def lines_for(routes, "raw"), do: for(r <- routes, r.mode == :observe, do: observe_line(r, :raw))

  def lines_for(routes, "mangle"),
    do: for(r <- routes, r.mode == :observe, do: observe_line(r, :mangle))

  # 転送。preserve_ip=true は SNAT を足さない＝素の src が origin まで届く（透過）。
  defp dnat_line(%Route{proto: proto, listen_port: port, origin: origin}),
    do: "-A #{@chain} -p #{proto} --dport #{port} -j DNAT --to-destination #{origin}"

  # 毎パケット（raw、conntrack より前）。RETURN で素通し＝数えるだけ。
  defp observe_line(%Route{proto: proto, listen_port: port}, :raw),
    do: "-A #{@chain} -p #{proto} --dport #{port} -j RETURN"

  # 新規フローだけ（mangle、conntrack NEW）。フロー初回の 1 パケットで 1 ＝接続レート。
  defp observe_line(%Route{proto: proto, listen_port: port}, :mangle),
    do: "-A #{@chain} -p #{proto} --dport #{port} -m conntrack --ctstate NEW -j RETURN"

  @doc """
  `iptables-restore -n` に食わせる本文（要るテーブルの塊を連結）。各テーブルで `WT_RELAY`
  を flush して埋め直す（他チェーンには触れない）。純粋関数。
  """
  @spec render([Route.t()]) :: String.t()
  def render(routes) do
    for table <- @tables, into: "" do
      lines = lines_for(routes, table)
      Enum.join(["*#{table}", ":#{@chain} - [0:0]"] ++ lines ++ ["COMMIT", ""], "\n")
    end
  end

  @doc "spec を原子的に適用（全テーブルの WT_RELAY を丸ごと差し替え＝空でも flush）。"
  @spec apply([Route.t()], module()) :: :ok | {:error, {integer(), binary()}}
  def apply(routes, cmd \\ Cmd.impl()) do
    Enum.each(@tables, &ensure_chain(cmd, &1))

    with :ok <- ensure_jumps(cmd, @tables) do
      path = Path.join(System.tmp_dir!(), "wt_relay_#{:erlang.unique_integer([:positive])}.rules")
      File.write!(path, render(routes))

      try do
        cmd.run("iptables-restore", ["-n", path]) |> ok()
      after
        File.rm(path)
      end
    end
  end

  @doc "各テーブルの PREROUTING → WT_RELAY の jump を一度だけ張る（冪等）。"
  @spec ensure_jumps(module(), [String.t()]) :: :ok | {:error, {integer(), binary()}}
  def ensure_jumps(cmd \\ Cmd.impl(), tables) do
    Enum.reduce_while(tables, :ok, fn table, _acc ->
      case ensure_jump(cmd, table) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp ensure_jump(cmd, table) do
    case cmd.run("iptables", ["-t", table, "-C", "PREROUTING", "-j", @chain]) do
      {:ok, _} -> :ok
      {:error, _} -> cmd.run("iptables", ["-t", table, "-A", "PREROUTING", "-j", @chain]) |> ok()
    end
  end

  @doc """
  各テーブルの WT_RELAY のカウンタを読む。observe なら raw=毎パケット / mangle=新規フロー。
  行に `table` と `metric`（:packets | :new_flows | :dnat）を付けて返す。
  """
  @spec counters(module()) :: {:ok, [map()]} | {:error, {integer(), binary()}}
  def counters(cmd \\ Cmd.impl()) do
    rows =
      for table <- @tables,
          {:ok, out} <- [cmd.run("iptables", ["-t", table, "-nvxL", @chain])],
          row <- parse_counters(out) do
        Map.put(row, :table, table) |> Map.put(:metric, metric_for(table, row))
      end

    {:ok, rows}
  end

  defp metric_for("raw", _), do: :packets
  defp metric_for("mangle", _), do: :new_flows
  defp metric_for("nat", _), do: :dnat

  @doc "`iptables -nvxL` の出力を、pkts/bytes が読める行だけ拾って解析。純粋関数。"
  @spec parse_counters(binary()) :: [map()]
  def parse_counters(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_line/1)
  end

  # 一度だけチェーンを作る（無いと -C / restore が空振る）。既存なら黙って戻る。
  defp ensure_chain(cmd, table), do: cmd.run("iptables", ["-t", table, "-N", @chain])

  # target 非依存。先頭 2 トークンが整数（pkts bytes）なら 1 ルール行とみなす。
  defp parse_line(line) do
    case String.split(line) do
      [pkts, bytes | rest] ->
        with {p, ""} <- Integer.parse(pkts), {b, ""} <- Integer.parse(bytes) do
          [%{pkts: p, bytes: b, dport: token(rest, "dpt:"), to: token(rest, "to:")}]
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp token(tokens, prefix) do
    Enum.find_value(tokens, fn t ->
      if String.starts_with?(t, prefix), do: String.replace_prefix(t, prefix, "")
    end)
  end

  defp ok({:ok, _}), do: :ok
  defp ok({:error, _} = e), do: e
end
