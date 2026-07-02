defmodule WtRelay.Kernel.IptablesTest do
  use ExUnit.Case, async: true
  alias WtRelay.{Route, Kernel.Iptables}

  @dnat %Route{name: "wt", proto: :udp, listen_port: 443, origin: "10.9.0.2:443", mode: :dnat}
  @observe %Route{name: "wt", proto: :udp, listen_port: 443, mode: :observe}

  test "render(dnat) は nat の WT_RELAY を DNAT で埋める" do
    out = Iptables.render([@dnat])
    assert out =~ "*nat"
    assert out =~ "-A WT_RELAY -p udp --dport 443 -j DNAT --to-destination 10.9.0.2:443"
    # 使わないテーブルも常に flush する（orphan を残さない）
    assert out =~ "*raw"
    assert out =~ "*mangle"
    assert String.ends_with?(out, "COMMIT\n")
  end

  test "render(observe) は raw=毎パケット / mangle=新規フロー を数え、nat は空" do
    out = Iptables.render([@observe])
    assert out =~ "*raw\n:WT_RELAY - [0:0]\n-A WT_RELAY -p udp --dport 443 -j RETURN"
    assert out =~ "-A WT_RELAY -p udp --dport 443 -m conntrack --ctstate NEW -j RETURN"
    # observe は転送しない＝ nat には DNAT が無い
    refute out =~ "DNAT"
  end

  test "render は空 spec でも全テーブルのチェーンを空に保つ（宣言的・orphan 無し）" do
    out = Iptables.render([])
    assert out =~ "*raw\n:WT_RELAY - [0:0]"
    assert out =~ "*mangle\n:WT_RELAY - [0:0]"
    assert out =~ "*nat\n:WT_RELAY - [0:0]"
    refute out =~ "DNAT"
    refute out =~ "RETURN"
  end

  test "apply は全テーブルのチェーン確保 → jump → restore を原子適用する" do
    Application.put_env(:wt_relay, :test_pid, self())
    on_exit(fn -> Application.delete_env(:wt_relay, :test_pid) end)

    assert :ok = Iptables.apply([@observe], WtRelay.CmdStub)

    for table <- ["raw", "mangle", "nat"] do
      assert_received {:cmd, "iptables", ["-t", ^table, "-N", "WT_RELAY"]}
      assert_received {:cmd, "iptables", ["-t", ^table, "-C", "PREROUTING", "-j", "WT_RELAY"]}
    end

    assert_received {:cmd, "iptables-restore", ["-n", path]}
    refute File.exists?(path), "temp rules ファイルは適用後に片付ける"
  end

  test "parse_counters は target 非依存で pkts/bytes を拾い、dpt/to を取る" do
    dnat = "    12  840 DNAT   udp -- * * 0.0.0.0/0 0.0.0.0/0 udp dpt:443 to:10.9.0.2:443"
    ret = "    99 7000 RETURN udp -- * * 0.0.0.0/0 0.0.0.0/0 udp dpt:443"
    assert [%{pkts: 12, bytes: 840, dport: "443", to: "10.9.0.2:443"}] = Iptables.parse_counters(dnat)
    assert [%{pkts: 99, bytes: 7000, dport: "443", to: nil}] = Iptables.parse_counters(ret)
  end

  test "counters は各テーブルを読み、raw→:packets / mangle→:new_flows / nat→:dnat と付ける" do
    assert {:ok, rows} = Iptables.counters(WtRelay.CmdStubCounters)
    by = Map.new(rows, &{&1.table, &1.metric})
    assert by["raw"] == :packets
    assert by["mangle"] == :new_flows
    assert by["nat"] == :dnat
  end
end
