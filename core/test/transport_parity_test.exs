defmodule Karutte.QuicTransport.ParityTest do
  use ExUnit.Case, async: true

  # 層を分けたことの「ごほうび」そのものを押さえる:
  # 二つの床が同じ behaviour を満たし、同じ {:quic, …} 契約を作ること。

  alias Karutte.QuicTransport
  alias Karutte.QuicTransport.{Http2, Quicer}

  test "両実装が QuicTransport の callback を全部宣言している" do
    required = QuicTransport.behaviour_info(:callbacks) |> MapSet.new()

    for mod <- [Quicer, Http2] do
      exported = mod.__info__(:functions) |> MapSet.new()
      missing = MapSet.difference(required, exported)
      assert MapSet.size(missing) == 0, "#{inspect(mod)} に未実装: #{inspect(MapSet.to_list(missing))}"
    end
  end

  test "二つの normalize が、同じ床の上の出来事を同じ契約に畳む" do
    # ストリームデータ + FIN。ネイティブのかたちは床ごとに違うが、出てくる契約は同じ。
    s = make_ref()
    quic = Quicer.normalize({:quic, "hi", s, %{flags: 0x1}})
    h2 = Http2.normalize({:h2, :data, s, "hi", true})

    assert quic == {:quic, :data, s, "hi", fin: true}
    assert quic == h2
  end
end
