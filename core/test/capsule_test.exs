defmodule Karutte.CapsuleTest do
  use ExUnit.Case, async: true

  alias Karutte.Capsule

  test "往復: type と value が戻り、後続のバイトも残る" do
    bin = Capsule.encode(0x00, "hello") <> "tail"
    assert {:ok, 0x00, "hello", "tail"} = Capsule.decode(bin)
  end

  test "DATAGRAM カプセル（type 0x00）を往復できる" do
    bin = Capsule.encode(Capsule.datagram_type(), "ping")
    assert {:ok, type, "ping", ""} = Capsule.decode(bin)
    assert type == Capsule.datagram_type()
  end

  test "空の value も運べる" do
    assert {:ok, 0x01, "", ""} = Capsule.decode(Capsule.encode(0x01, ""))
  end

  test "Value まで揃っていなければ :more" do
    full = Capsule.encode(0x00, "hello")
    # 末尾 1 バイト欠け
    short = binary_part(full, 0, byte_size(full) - 1)
    assert Capsule.decode(short) == :more
  end
end
