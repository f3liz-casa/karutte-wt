defmodule Karutte.InlineTest do
  use ExUnit.Case, async: true

  alias Karutte.Inline

  test "FIN まで揃えば一塊で返す" do
    assert Inline.drive(10, [{"he", false}, {"llo", true}]) == {:done, "hello"}
  end

  test "max を超えたら FIN を待たず即 overflow" do
    assert Inline.drive(8, [{"12345", false}, {"6789AB", false}]) == {:overflow, 8}
  end

  test "境界ちょうど（size == max）は通す" do
    assert Inline.drive(5, [{"hello", true}]) == {:done, "hello"}
  end

  test "1 チャンクで超過しても止まる" do
    assert Inline.drive(4, [{"hello", true}]) == {:overflow, 4}
  end

  test "途中で溢れたら、その後の FIN は見に行かない" do
    assert Inline.drive(3, [{"ab", false}, {"cd", false}, {"e", true}]) == {:overflow, 3}
  end
end
