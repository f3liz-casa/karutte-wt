defmodule WtRelay.CmdStubCounters do
  @moduledoc "counters 用の床。どのテーブルの -nvxL にも 1 ルール分のサンプルを返す。"
  @behaviour WtRelay.Kernel.Cmd

  @sample "Chain WT_RELAY (1 references)\n 5 320 RETURN udp -- * * 0.0.0.0/0 0.0.0.0/0 udp dpt:443\n"

  @impl true
  def run("iptables", ["-t", _table, "-nvxL", "WT_RELAY"]), do: {:ok, @sample}
  def run(_cmd, _args), do: {:ok, ""}
end
