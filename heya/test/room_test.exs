defmodule Heya.RoomTest do
  use ExUnit.Case

  test "自分の声は自分に戻らず、ほかの人には届く" do
    {:ok, a, roster} = Heya.Room.join("t1", "a")
    assert roster == [%{id: a, name: "a"}]
    b_pid = spawn(fn -> receive do: (:never -> :ok) end)
    {:ok, b, roster} = Heya.Room.join("t1", "b", b_pid)
    assert length(roster) == 2
    # a には b が入った知らせ
    assert_receive {:heya, <<0, json::binary>>}
    assert Jason.decode!(json)["join"]["id"] == b
    Heya.Room.frame("t1", a, <<1, 2, 3>>)
    refute_receive {:heya, <<^a, 1, 2, 3>>}, 50
    Heya.Room.frame("t1", b, <<9, 9>>)
    assert_receive {:heya, <<^b, 9, 9>>}
  end

  test "落ちた人は消え、だれも居なくなれば部屋も消える" do
    {:ok, _a, _} = Heya.Room.join("t2", "a")
    p = spawn(fn -> receive do: (:never -> :ok) end)
    {:ok, b, _} = Heya.Room.join("t2", "b", p)
    assert_receive {:heya, <<0, _::binary>>}
    Process.exit(p, :kill)
    assert_receive {:heya, <<0, json::binary>>}
    assert Jason.decode!(json)["leave"] == b
    [{room, _}] = Registry.lookup(Heya.Registry, "t2")
    ref = Process.monitor(room)
    Heya.Room.leave("t2", 1)
    assert_receive {:DOWN, ^ref, _, _, _}
  end

  test "tcp の口: JOIN して、声が相手にだけ届く" do
    port = 7333
    open = fn name ->
      {:ok, s} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: 2, active: false])
      :ok = :gen_tcp.send(s, "JOIN t3 " <> name)
      {:ok, <<0, json::binary>>} = :gen_tcp.recv(s, 0, 1000)
      {s, Jason.decode!(json)["you"]}
    end
    {sa, ia} = open.("koe")
    {sb, ib} = open.("hito")
    {:ok, <<0, _::binary>>} = :gen_tcp.recv(sa, 0, 1000)      # b が入った知らせ
    :ok = :gen_tcp.send(sa, <<7, 7, 7>>)
    assert {:ok, <<^ia, 7, 7, 7>>} = :gen_tcp.recv(sb, 0, 1000)
    assert {:error, :timeout} = :gen_tcp.recv(sa, 0, 100)
    :ok = :gen_tcp.send(sb, <<1>>)
    assert {:ok, <<^ib, 1>>} = :gen_tcp.recv(sa, 0, 1000)
    :gen_tcp.close(sa); :gen_tcp.close(sb)
  end

  test "背圧: 溜まっている人には声を落とし、制御は落とさない" do
    {:ok, a, _} = Heya.Room.join("t4", "a")
    slow = spawn(fn -> receive do: (:never -> :ok) end)
    {:ok, _b, _} = Heya.Room.join("t4", "b", slow)
    assert_receive {:heya, <<0, _::binary>>}
    # slow のメールボックスを一秒ぶん超えて埋める
    for _ <- 1..60, do: send(slow, :junk)
    Heya.Room.frame("t4", a, <<5>>)
    Process.sleep(20)
    {:messages, msgs} = Process.info(slow, :messages)
    refute {:heya, <<a, 5>>} in msgs
    # 制御(leave)は届く
    Heya.Room.leave("t4", a)
    Process.sleep(20)
    {:messages, msgs} = Process.info(slow, :messages)
    assert Enum.any?(msgs, &match?({:heya, <<0, _::binary>>}, &1))
    Process.exit(slow, :kill)
  end

  test "path の読みかた" do
    assert {:ok, "asobi", "ひなた"} = Heya.WT.parse("/asobi?name=%E3%81%B2%E3%81%AA%E3%81%9F")
    assert {:ok, "asobi", "だれか"} = Heya.WT.parse("/asobi")
    assert :error = Heya.WT.parse("/")
    assert :error = Heya.WT.parse(nil)
  end
end
