defmodule Karutte.VarintTest do
  use ExUnit.Case, async: true

  alias Karutte.Varint

  test "級の境目を最短でエンコードする" do
    assert byte_size(Varint.encode(0)) == 1
    assert byte_size(Varint.encode(63)) == 1
    assert byte_size(Varint.encode(64)) == 2
    assert byte_size(Varint.encode(16_383)) == 2
    assert byte_size(Varint.encode(16_384)) == 4
    assert byte_size(Varint.encode(1_073_741_823)) == 4
    assert byte_size(Varint.encode(1_073_741_824)) == 8
  end

  test "往復: エンコードしてデコードすると元に戻り、余りも残る" do
    for v <- [0, 1, 63, 64, 16_383, 16_384, 1_073_741_823, 1_073_741_824, 4_611_686_018_427_387_903] do
      assert {:ok, ^v, "rest"} = Varint.decode(Varint.encode(v) <> "rest")
    end
  end

  test "RFC 9000 §16 の例（0x25 → 37）" do
    assert {:ok, 37, ""} = Varint.decode(<<0x25>>)
  end

  test "バイトが足りなければ :more（壊れた varint は無い）" do
    assert Varint.decode(<<>>) == :more
    # 2 バイト級の先頭だけ来て続きが無い
    assert Varint.decode(<<0b01::2, 0::6>>) == :more
  end
end
