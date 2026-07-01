# 終了通知つき Echo（capsule close の検証用）。session が閉じると terminate が test pid へ報せる。
defmodule Karutte.Http3.NotifyEcho do
  @behaviour Karutte.WebTransport

  @impl true
  def init(test_pid, conn_info),
    do: {:ok, %{test: test_pid, transport: conn_info.transport, conn: conn_info.conn}}

  @impl true
  def handle_stream(_stream, _dir, s), do: {{:handler, Karutte.Http3.Echo.Stream, nil}, s}

  @impl true
  def handle_datagram(bin, s) do
    s.transport.send_datagram(s.conn, bin)
    {:ok, s}
  end

  @impl true
  def terminate(reason, s) do
    Kernel.send(s.test, {:session_terminated, reason})
    :ok
  end
end

# datagram をわざと遅く捌く（有界 drop の検証用）。
defmodule Karutte.Http3.SlowDatagram do
  @behaviour Karutte.WebTransport
  @impl true
  def init(_arg, ci), do: {:ok, ci}
  @impl true
  def handle_stream(_s, _d, st), do: {{:handler, Karutte.Http3.Echo.Stream, nil}, st}
  @impl true
  def handle_datagram(_bin, st) do
    Process.sleep(40)
    {:ok, st}
  end
end

defmodule Karutte.Http3.LoopbackTest do
  use ExUnit.Case

  # 実 QUIC の上で、最小 Elixir クライアントが H3 WebTransport サーバと喋れることを確かめる。
  # クライアントは cow_http3 / cow_qpack / cow_capsule を直叩き。quicer NIF が要る（ビルド済み）。

  @moduletag :quic
  @recv_timeout 5_000

  setup_all do
    tmp = Path.join(System.tmp_dir!(), "karutte_h3_#{System.unique_integer([:positive])}")
    {:ok, cert} = Karutte.Http3.Cert.generate(tmp)
    port = 14_433

    start_supervised!(
      {Karutte.Http3.Server,
       port: port,
       certfile: cert.certfile,
       keyfile: cert.keyfile,
       handler: Karutte.Http3.Echo,
       acceptors: 1,
       name: Karutte.Http3.Server.EchoT}
    )

    on_exit(fn -> File.rm_rf(tmp) end)
    %{port: port}
  end

  test "WebTransport over HTTP/3: CONNECT 200, bidi echo, datagram echo", %{port: port} do
    conn = connect(port)
    {session_id, _req} = open_session(conn)

    assert "hi" == wt_bidi_echo(conn, session_id, "hi")

    :quicer.send_dgram(conn, :erlang.iolist_to_binary(:cow_http3.datagram(session_id, "ping")))
    assert "ping" == recv_datagram(conn, session_id)

    :quicer.shutdown_connection(conn)
  end

  test "一つの H3 接続に独立した二つの WT セッション", %{port: port} do
    conn = connect(port)
    {sid_a, _} = open_session(conn)
    {sid_b, _} = open_session(conn)

    assert sid_a != sid_b
    assert "aa" == wt_bidi_echo(conn, sid_a, "aa")
    assert "bb" == wt_bidi_echo(conn, sid_b, "bb")

    :quicer.shutdown_connection(conn)
  end

  test "一接続の事故はサーバ全体を倒さず、受け付けは続く", %{port: port} do
    conn1 = connect(port)
    {sid1, _} = open_session(conn1)
    assert "x" == wt_bidi_echo(conn1, sid1, "x")

    # 動いている Connection を一つ強制終了（事故を模す）。
    children = DynamicSupervisor.which_children(Karutte.Http3.Server.EchoT.ConnectionSup)
    assert [{_, cpid, _, _} | _] = children
    Process.exit(cpid, :kill)

    # acceptor は生きているので、新しい接続はまだ通る。
    conn2 = connect(port)
    {sid2, _} = open_session(conn2)
    assert "y" == wt_bidi_echo(conn2, sid2, "y")

    :quicer.shutdown_connection(conn1)
    :quicer.shutdown_connection(conn2)
  end

  test "CLOSE capsule でそのセッションだけ畳まれ、runner の terminate が走る" do
    tmp = Path.join(System.tmp_dir!(), "karutte_h3c_#{System.unique_integer([:positive])}")
    {:ok, cert} = Karutte.Http3.Cert.generate(tmp)
    port = 14_434

    start_supervised!(
      {Karutte.Http3.Server,
       port: port,
       certfile: cert.certfile,
       keyfile: cert.keyfile,
       handler: Karutte.Http3.NotifyEcho,
       handler_arg: self(),
       acceptors: 1,
       name: Karutte.Http3.Server.CloseT}
    )

    on_exit(fn -> File.rm_rf(tmp) end)

    conn = connect(port)
    {session_id, req} = open_session(conn)
    assert "hi" == wt_bidi_echo(conn, session_id, "hi")

    # セッションストリーム上に CLOSE_WEBTRANSPORT_SESSION capsule + FIN。
    :quicer.send(req, :erlang.iolist_to_binary(:cow_capsule.wt_close_session(0, <<>>)), 0x4)

    assert_receive {:session_terminated, _reason}, @recv_timeout
    :quicer.shutdown_connection(conn)
  end

  test "telemetry: セッション open のイベントが飛ぶ", %{port: port} do
    ref = attach_telemetry([:session, :open])
    conn = connect(port)
    open_session(conn)
    assert_receive {:telem, ^ref, _measure, %{session_id: _}}, @recv_timeout
    :quicer.shutdown_connection(conn)
  end

  test "datagram の過負荷は drop する（有界キュー、telemetry で観測）" do
    tmp = Path.join(System.tmp_dir!(), "karutte_h3d_#{System.unique_integer([:positive])}")
    {:ok, cert} = Karutte.Http3.Cert.generate(tmp)
    port = 14_435

    start_supervised!(
      {Karutte.Http3.Server,
       port: port,
       certfile: cert.certfile,
       keyfile: cert.keyfile,
       handler: Karutte.Http3.SlowDatagram,
       acceptors: 1,
       max_datagram_queue: 2,
       name: Karutte.Http3.Server.DropT}
    )

    on_exit(fn -> File.rm_rf(tmp) end)

    ref = attach_telemetry([:datagram, :dropped])
    conn = connect(port)
    {sid, _} = open_session(conn)

    # 遅いハンドラ（40ms/件）に一気に流し込む → メールボックスが上限を超えて drop。
    for _ <- 1..40 do
      :quicer.send_dgram(conn, :erlang.iolist_to_binary(:cow_http3.datagram(sid, "d")))
    end

    assert_receive {:telem, ^ref, _measure, %{session_id: _}}, @recv_timeout
    :quicer.shutdown_connection(conn)
  end

  test "graceful drain: セッションに DRAIN capsule が届く" do
    tmp = Path.join(System.tmp_dir!(), "karutte_h3g_#{System.unique_integer([:positive])}")
    {:ok, cert} = Karutte.Http3.Cert.generate(tmp)
    port = 14_436

    start_supervised!(
      {Karutte.Http3.Server,
       port: port,
       certfile: cert.certfile,
       keyfile: cert.keyfile,
       handler: Karutte.Http3.Echo,
       acceptors: 1,
       name: Karutte.Http3.Server.DrainT}
    )

    on_exit(fn -> File.rm_rf(tmp) end)

    conn = connect(port)
    {_sid, req} = open_session(conn)

    # 別プロセスで graceful drain（猶予中に DRAIN が届くはず）。
    spawn(fn -> Karutte.Http3.Server.drain(Karutte.Http3.Server.DrainT, 800) end)

    assert :wt_drain_session == recv_capsule(req)
  end

  test "peer からの DRAIN 後は、そのセッションの新規ストリームが reset される" do
    tmp = Path.join(System.tmp_dir!(), "karutte_h3e_#{System.unique_integer([:positive])}")
    {:ok, cert} = Karutte.Http3.Cert.generate(tmp)
    port = 14_437

    start_supervised!(
      {Karutte.Http3.Server,
       port: port,
       certfile: cert.certfile,
       keyfile: cert.keyfile,
       handler: Karutte.Http3.Echo,
       acceptors: 1,
       name: Karutte.Http3.Server.DrainEnforceT}
    )

    on_exit(fn -> File.rm_rf(tmp) end)

    conn = connect(port)
    {sid, req} = open_session(conn)

    # DRAIN の前は echo が通る。
    assert "ok" == wt_bidi_echo(conn, sid, "ok")

    # クライアントから DRAIN を送る → サーバはこのセッションを draining に。
    :quicer.send(req, :cow_capsule.wt_drain_session())
    Process.sleep(200)

    # 以後の新規 WT ストリームは reset される（echo されない）。
    {:ok, wt} = :quicer.start_stream(conn, %{open_flag: 0, active: true})
    :quicer.send(wt, [:cow_http3.webtransport_stream_header(sid, :bidi), "no"])

    assert_receive {:quic, kind, ^wt, _}
                   when kind in [:peer_send_aborted, :peer_receive_aborted, :stream_closed],
                   @recv_timeout

    :quicer.shutdown_connection(conn)
  end

  # ================= クライアント・ヘルパ =================

  defp recv_capsule(stream, buf \\ <<>>) do
    case :cow_capsule.parse(buf) do
      {:ok, cap, _rest} when is_atom(cap) or is_tuple(cap) ->
        cap

      {:ok, rest} when is_binary(rest) ->
        recv_capsule(stream, rest)

      _ ->
        receive do
          {:quic, bin, ^stream, _} when is_binary(bin) -> recv_capsule(stream, buf <> bin)
          {:quic, _o, _, _} -> recv_capsule(stream, buf)
        after
          @recv_timeout -> flunk("DRAIN capsule を受け取れなかった")
        end
    end
  end

  defp attach_telemetry(event) do
    ref = make_ref()
    id = {__MODULE__, ref}
    test = self()

    :telemetry.attach(
      id,
      [:karutte, :http3 | event],
      fn _e, measure, meta, _ -> Kernel.send(test, {:telem, ref, measure, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    ref
  end

  # 接続して H3 を立ち上げる（control/encoder/decoder + SETTINGS）。conn を返す。
  defp connect(port) do
    {:ok, conn} =
      :quicer.connect(
        ~c"localhost",
        port,
        [
          {:alpn, [~c"h3"]},
          {:verify, :none},
          {:peer_unidi_stream_count, 256},
          {:peer_bidi_stream_count, 256},
          {:datagram_send_enabled, 1},
          {:datagram_receive_enabled, 1}
        ],
        @recv_timeout
      )

    {:ok, ctrl} = :quicer.start_stream(conn, %{open_flag: 1, active: true})
    {:ok, enc} = :quicer.start_stream(conn, %{open_flag: 1, active: true})
    {:ok, dec} = :quicer.start_stream(conn, %{open_flag: 1, active: true})
    settings = :cow_http3.settings(%{enable_connect_protocol: true, h3_datagram: true})
    :quicer.send(ctrl, [<<0>>, settings])
    :quicer.send(enc, <<2>>)
    :quicer.send(dec, <<3>>)
    conn
  end

  # Extended CONNECT(webtransport) を一本立てて 200 を受ける。{session_id, req_stream} を返す。
  defp open_session(conn) do
    {:ok, req} = :quicer.start_stream(conn, %{open_flag: 0, active: true})
    {:ok, session_id} = :quicer.get_stream_id(req)

    headers = [
      {":method", "CONNECT"},
      {":scheme", "https"},
      {":authority", "localhost"},
      {":path", "/"},
      {":protocol", "webtransport"}
    ]

    {:ok, block, _ins, _enc} =
      :cow_qpack.encode_field_section(headers, session_id, :cow_qpack.init(:encoder, 0, 0))

    :quicer.send(req, :cow_http3.headers(block))

    status = recv_response_status(req, session_id)
    assert status == "200" or status == 200
    {session_id, req}
  end

  # WT 双方向ストリームを開いて msg を送り、echo を受ける。
  defp wt_bidi_echo(conn, session_id, msg) do
    {:ok, wt} = :quicer.start_stream(conn, %{open_flag: 0, active: true})
    :quicer.send(wt, [:cow_http3.webtransport_stream_header(session_id, :bidi), msg])
    recv_raw(wt, byte_size(msg))
  end

  defp recv_response_status(req, session_id, buf \\ <<>>) do
    case :cow_http3.parse(buf) do
      {:ok, {:headers, block}, _rest} ->
        {:ok, headers, _ins, _dec} =
          :cow_qpack.decode_field_section(block, session_id, :cow_qpack.init(:decoder, 0, 0))

        Enum.find_value(headers, fn
          {":status", v} -> v
          _ -> false
        end)

      _ ->
        receive do
          {:quic, bin, ^req, _} when is_binary(bin) -> recv_response_status(req, session_id, buf <> bin)
          {:quic, :new_stream, s, _} -> (:quicer.setopt(s, :active, true); recv_response_status(req, session_id, buf))
          {:quic, _o, _, _} -> recv_response_status(req, session_id, buf)
        after
          @recv_timeout -> flunk("200 を受け取れなかった (buf=#{inspect(buf)})")
        end
    end
  end

  defp recv_raw(wt, want, acc \\ "") do
    if byte_size(acc) >= want do
      acc
    else
      receive do
        {:quic, bin, ^wt, _} when is_binary(bin) -> recv_raw(wt, want, acc <> bin)
        {:quic, :new_stream, s, _} -> (:quicer.setopt(s, :active, true); recv_raw(wt, want, acc))
        {:quic, _o, _, _} -> recv_raw(wt, want, acc)
      after
        @recv_timeout -> flunk("WT echo を受け取れなかった (acc=#{inspect(acc)})")
      end
    end
  end

  defp recv_datagram(conn, session_id) do
    receive do
      {:quic, bin, ^conn, _} when is_binary(bin) ->
        case :cow_http3.parse_datagram(bin) do
          {^session_id, payload} -> payload
          _ -> recv_datagram(conn, session_id)
        end

      {:quic, :new_stream, s, _} -> (:quicer.setopt(s, :active, true); recv_datagram(conn, session_id))
      {:quic, _o, _, _} -> recv_datagram(conn, session_id)
    after
      @recv_timeout -> flunk("datagram echo を受け取れなかった")
    end
  end
end
