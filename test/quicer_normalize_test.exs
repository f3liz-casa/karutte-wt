defmodule Karutte.QuicTransport.QuicerNormalizeTest do
  use ExUnit.Case, async: true

  alias Karutte.QuicTransport.Quicer

  # ここで verify するのは L1 の「メッセージの面」だけ。命令の面（quicer 委譲）は
  # 実 NIF が要るので別（玩具と本物の境目）。

  test "ストリームデータ: flags の FIN ビットを fin: に畳む" do
    s = make_ref()
    assert {:quic, :data, ^s, "abc", fin: false} =
             Quicer.normalize({:quic, "abc", s, %{flags: 0}})

    assert {:quic, :data, ^s, "abc", fin: true} =
             Quicer.normalize({:quic, "abc", s, %{flags: 0x1}})
  end

  test "peer_send_shutdown は空データの FIN" do
    s = make_ref()
    assert {:quic, :data, ^s, <<>>, fin: true} =
             Quicer.normalize({:quic, :peer_send_shutdown, s, undefined()})
  end

  test "peer_send_aborted は reset（code 付き）" do
    s = make_ref()
    assert {:quic, :reset, ^s, 42} = Quicer.normalize({:quic, :peer_send_aborted, s, 42})
  end

  test "passive は AXIS 2 の窓停止合図" do
    s = make_ref()
    assert {:quic, :passive, ^s} = Quicer.normalize({:quic, :passive, s, undefined()})
  end

  test "new_stream: flags の uni ビットで方向を読む" do
    s = make_ref()
    assert {:quic, :new_stream, nil, ^s, :bidi} =
             Quicer.normalize({:quic, :new_stream, s, %{flags: 0}})

    assert {:quic, :new_stream, nil, ^s, :uni} =
             Quicer.normalize({:quic, :new_stream, s, %{flags: 0x1}})
  end

  test "datagram は軸の外として素通し" do
    c = make_ref()
    assert {:quic, :datagram, ^c, "d"} = Quicer.normalize({:quic, :dgram, c, "d"})
  end

  test "接続の閉じは reason 付きで畳む" do
    c = make_ref()
    assert {:quic, :closed, ^c, :normal} = Quicer.normalize({:quic, :shutdown, c, :normal})
  end

  test "知らないかたちは落とさず {:unknown, _} で素通し（Preview の揺れ）" do
    assert {:unknown, {:quic, :weird, 1, 2}} = Quicer.normalize({:quic, :weird, 1, 2})
  end

  defp undefined, do: :undefined
end
