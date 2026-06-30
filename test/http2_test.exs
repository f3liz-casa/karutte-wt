defmodule Karutte.QuicTransport.Http2Test do
  use ExUnit.Case, async: true

  alias Karutte.QuicTransport.Http2

  # sink に self() を置いて、出ていくフレームを観測する。

  setup do
    %{conn: Http2.new(self(), 4)}
  end

  test "前置きの往復: session id が読み戻せる", %{conn: conn} do
    preface = Http2.stream_preface(conn.session_id)
    assert {:ok, 4, "payload"} = Http2.parse_preface(preface <> "payload")
  end

  test "open_stream は方向と session 前置きを sink へ出す", %{conn: conn} do
    assert {:ok, {^conn, 7}} = Http2.open_stream(conn, :uni, id: 7)
    assert_received {:h2_open, 7, :uni, preface}
    assert {:ok, 4, ""} = Http2.parse_preface(preface)
  end

  test "send は DATA フレーム、fin は END_STREAM", %{conn: conn} do
    {:ok, stream} = Http2.open_stream(conn, :bidi, id: 9)
    assert_received {:h2_open, 9, :bidi, _}

    :ok = Http2.send(stream, "hi", fin: true)
    assert_received {:h2_out, 9, "hi", true}
  end

  test "ストリーム往復: send したものが normalize で契約として戻る", %{conn: conn} do
    {:ok, stream} = Http2.open_stream(conn, :bidi, id: 9)
    assert_received {:h2_open, 9, :bidi, _}

    Http2.send(stream, "hi", fin: true)
    assert_received {:h2_out, 9, "hi", true}

    # H2 デマルチプレクサが同じバイトを向こうから受けた、として normalize へ
    assert {:quic, :data, 9, "hi", fin: true} =
             Http2.normalize({:h2, :data, 9, "hi", true})
  end

  test "datagram 往復: カプセルに包んで出し、normalize で datagram に戻る", %{conn: conn} do
    :ok = Http2.send_datagram(conn, "ping")
    # CONNECT ストリーム（session id = 4）の上にカプセルとして出る
    assert_received {:h2_out, 4, capsule, false}

    # 向こうから来たカプセルを normalize すると datagram に戻る（信頼配送の擬似 datagram）
    assert {:quic, :datagram, :sess, "ping"} =
             Http2.normalize({:h2, :capsule, :sess, capsule})
  end

  test "set_active は AXIS 2 として H2 の窓に写る", %{conn: conn} do
    {:ok, stream} = Http2.open_stream(conn, :bidi, id: 9)
    assert_received {:h2_open, 9, :bidi, _}

    :ok = Http2.set_active(stream, 3)
    assert_received {:h2_window, 9, 3}
  end

  test "stop_sending は H2 では reset へ畳む（半閉じ粒度は痩せる）", %{conn: conn} do
    {:ok, stream} = Http2.open_stream(conn, :bidi, id: 9)
    assert_received {:h2_open, 9, :bidi, _}

    :ok = Http2.shutdown(stream, {:stop_sending, 5})
    assert_received {:h2_reset, 9, 5}
  end
end
