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

# セッションが立ったら server 発の単方向ストリームを開いて push する（server push の検証用）。
defmodule Karutte.Http3.Pusher do
  @behaviour Karutte.WebTransport
  @impl true
  def init(_arg, ci), do: {:ok, ci}
  @impl true
  def handle_stream(_s, _d, st), do: {{:reset, 0}, st}
  @impl true
  def handle_info(:wt_ready, st) do
    {:ok, stream} = st.transport.open_stream(st.conn, :uni)
    st.transport.send(stream, "server-push", fin: true)
    {:ok, st}
  end

  def handle_info(_msg, st), do: {:ok, st}
end

# セッションが立ったら server 発の双方向ストリームを echo runner 付きで開く（server bidi の検証用）。
defmodule Karutte.Http3.BidiPusher do
  @behaviour Karutte.WebTransport
  @impl true
  def init(_arg, ci), do: {:ok, ci}
  @impl true
  def handle_stream(_s, _d, st), do: {{:reset, 0}, st}
  @impl true
  def handle_info(:wt_ready, st) do
    {:ok, _stream} = st.transport.open_stream(st.conn, :bidi, handler: Karutte.Http3.Echo.Stream)
    {:ok, st}
  end

  def handle_info(_msg, st), do: {:ok, st}
end

# demand を一度に一束（active: :once）にする echo。背圧ループ（再 arm）を volume 下で試す用。
defmodule Karutte.Http3.DemandEcho do
  @behaviour Karutte.WebTransport
  @impl true
  def init(_arg, ci), do: {:ok, ci}
  @impl true
  def handle_stream(_s, _d, st), do: {{:handler, __MODULE__.Stream, nil}, st}

  defmodule Stream do
    @behaviour Karutte.WebTransport.Stream
    @impl true
    def init(_stream, _arg), do: {:ok, %{}, active: :once}
    @impl true
    def handle_in(bin, st), do: {:push, bin, st, active: :once}
    @impl true
    def handle_fin(st), do: {:close_write, st}
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

# authorize/1 で path が "/ok" の CONNECT だけ受ける門番（認証の検証用）。
defmodule Karutte.Http3.PathAuth do
  @behaviour Karutte.WebTransport
  @impl true
  def authorize(ci), do: if(ci.path == "/ok", do: :ok, else: {:reject, 403})
  @impl true
  def init(_arg, ci), do: {:ok, ci}
  @impl true
  def handle_stream(_s, _d, st), do: {{:handler, Karutte.Http3.Echo.Stream, nil}, st}
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

  test "大きなペイロードもストリームで正しく往復する（多フレーム跨ぎ）", %{port: port} do
    conn = connect(port)
    {sid, _} = open_session(conn)

    payload = :crypto.strong_rand_bytes(64 * 1024)
    {:ok, wt} = :quicer.start_stream(conn, %{open_flag: 0, active: true})
    :quicer.send(wt, [:cow_http3.webtransport_stream_header(sid, :bidi), payload])

    got = recv_raw(wt, byte_size(payload))
    assert byte_size(got) == byte_size(payload)
    assert got == payload

    :quicer.shutdown_connection(conn)
  end

  test "demand 駆動（active: :once）でも大きなペイロードが取りこぼしなく往復する" do
    tmp = Path.join(System.tmp_dir!(), "karutte_h3dm_#{System.unique_integer([:positive])}")
    {:ok, cert} = Karutte.Http3.Cert.generate(tmp)
    port = 14_439

    start_supervised!(
      {Karutte.Http3.Server,
       port: port,
       certfile: cert.certfile,
       keyfile: cert.keyfile,
       handler: Karutte.Http3.DemandEcho,
       acceptors: 1,
       name: Karutte.Http3.Server.DemandT}
    )

    on_exit(fn -> File.rm_rf(tmp) end)

    conn = connect(port)
    {sid, _} = open_session(conn)

    payload = :crypto.strong_rand_bytes(32 * 1024)
    {:ok, wt} = :quicer.start_stream(conn, %{open_flag: 0, active: true})
    :quicer.send(wt, [:cow_http3.webtransport_stream_header(sid, :bidi), payload])

    assert payload == recv_raw(wt, byte_size(payload))
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

  test "ハンドラは authorize/1 で path ごとに CONNECT を受理/拒否できる（認証）" do
    tmp = Path.join(System.tmp_dir!(), "karutte_h3a_#{System.unique_integer([:positive])}")
    {:ok, cert} = Karutte.Http3.Cert.generate(tmp)
    port = 14_438

    start_supervised!(
      {Karutte.Http3.Server,
       port: port,
       certfile: cert.certfile,
       keyfile: cert.keyfile,
       handler: Karutte.Http3.PathAuth,
       acceptors: 1,
       name: Karutte.Http3.Server.AuthT}
    )

    on_exit(fn -> File.rm_rf(tmp) end)

    conn = connect(port)
    assert "200" == request_status(conn, "/ok")
    assert "403" == request_status(conn, "/nope")
    :quicer.shutdown_connection(conn)
  end

  test "多数の接続が同時に echo できる（acceptor プール／ConnectionSup）" do
    tmp = Path.join(System.tmp_dir!(), "karutte_h3cc_#{System.unique_integer([:positive])}")
    {:ok, cert} = Karutte.Http3.Cert.generate(tmp)
    port = 14_441

    start_supervised!(
      {Karutte.Http3.Server,
       port: port,
       certfile: cert.certfile,
       keyfile: cert.keyfile,
       handler: Karutte.Http3.Echo,
       acceptors: 8,
       name: Karutte.Http3.Server.ConcT}
    )

    on_exit(fn -> File.rm_rf(tmp) end)

    n = 8

    results =
      1..n
      |> Task.async_stream(
        fn i ->
          conn = connect(port)
          {sid, _} = open_session(conn)
          msg = "conn-#{i}"
          got = wt_bidi_echo(conn, sid, msg)
          :quicer.shutdown_connection(conn)
          {msg, got}
        end,
        max_concurrency: n,
        timeout: 20_000
      )
      |> Enum.map(fn {:ok, v} -> v end)

    assert length(results) == n
    assert Enum.all?(results, fn {msg, got} -> msg == got end)
  end

  test "一接続で多数のストリームが同時に echo できる", %{port: port} do
    conn = connect(port)
    {sid, _} = open_session(conn)

    pending =
      for i <- 1..20, into: %{} do
        {:ok, wt} = :quicer.start_stream(conn, %{open_flag: 0, active: true})
        msg = "stream-#{i}"
        :quicer.send(wt, [:cow_http3.webtransport_stream_header(sid, :bidi), msg])
        {wt, {msg, byte_size(msg), <<>>}}
      end

    got = collect_echoes(pending)
    assert Enum.all?(got, fn {msg, acc} -> msg == acc end)
    assert map_size(got) == 20

    :quicer.shutdown_connection(conn)
  end

  test "server push: ハンドラが server 発の単方向ストリームを開いてクライアントに届く" do
    tmp = Path.join(System.tmp_dir!(), "karutte_h3p_#{System.unique_integer([:positive])}")
    {:ok, cert} = Karutte.Http3.Cert.generate(tmp)
    port = 14_440

    start_supervised!(
      {Karutte.Http3.Server,
       port: port,
       certfile: cert.certfile,
       keyfile: cert.keyfile,
       handler: Karutte.Http3.Pusher,
       acceptors: 1,
       name: Karutte.Http3.Server.PushT}
    )

    on_exit(fn -> File.rm_rf(tmp) end)

    conn = connect(port)
    {sid, _req} = open_session(conn)

    # ハンドラは :wt_ready で server 発 uni ストリームを開き "server-push" を送る。
    assert "server-push" == collect_wt_uni(sid, byte_size("server-push"))
    :quicer.shutdown_connection(conn)
  end

  test "server 発の双方向ストリームを client が読み書きできる（echo runner 付き）" do
    tmp = Path.join(System.tmp_dir!(), "karutte_h3b_#{System.unique_integer([:positive])}")
    {:ok, cert} = Karutte.Http3.Cert.generate(tmp)
    port = 14_442

    start_supervised!(
      {Karutte.Http3.Server,
       port: port,
       certfile: cert.certfile,
       keyfile: cert.keyfile,
       handler: Karutte.Http3.BidiPusher,
       acceptors: 1,
       name: Karutte.Http3.Server.BidiPushT}
    )

    on_exit(fn -> File.rm_rf(tmp) end)

    conn = connect(port)
    {sid, _} = open_session(conn)

    # server が開いた bidi ストリームを受け取り、書いて echo を受ける。
    wt = recv_server_bidi(sid)
    :quicer.send(wt, "hey")
    assert "hey" == recv_raw(wt, 3)

    :quicer.shutdown_connection(conn)
  end

  # ================= クライアント・ヘルパ =================

  # server 発の bidi WT ストリームを待ち、preface を剥がして handle を返す。
  defp recv_server_bidi(sid) do
    receive do
      {:quic, :new_stream, s, _} ->
        :quicer.setopt(s, :active, true)
        strip_bidi_preface(s, sid, <<>>)

      {:quic, _o, _, _} ->
        recv_server_bidi(sid)
    after
      @recv_timeout -> flunk("server 発 bidi 来ず")
    end
  end

  defp strip_bidi_preface(s, sid, buf) do
    case :cow_http3.parse(buf) do
      {:webtransport_stream_header, ^sid, _rest} ->
        s

      _ ->
        receive do
          {:quic, bin, ^s, _} when is_binary(bin) -> strip_bidi_preface(s, sid, buf <> bin)
        after
          @recv_timeout -> flunk("bidi preface 来ず")
        end
    end
  end

  # 複数ストリームの echo を handle 別に demux して集める。
  # pending: %{wt => {msg, want, acc}} → 全部 want バイト揃ったら %{msg => acc} を返す。
  defp collect_echoes(pending) do
    if Enum.all?(pending, fn {_wt, {_msg, want, acc}} -> byte_size(acc) >= want end) do
      Map.new(pending, fn {_wt, {msg, _want, acc}} -> {msg, acc} end)
    else
      receive do
        {:quic, bin, wt, _} when is_binary(bin) and is_map_key(pending, wt) ->
          {msg, want, acc} = pending[wt]
          collect_echoes(Map.put(pending, wt, {msg, want, acc <> bin}))

        {:quic, _o, _, _} ->
          collect_echoes(pending)
      after
        @recv_timeout -> flunk("multi-stream echo 未達")
      end
    end
  end

  # server 発の単方向 WT ストリーム（0x54, sid）を探して payload を want バイト集める。
  # サーバの control/qpack unidi ストリームは種別で弾く。
  defp collect_wt_uni(sid, want, streams \\ %{}, payload \\ nil) do
    if payload && byte_size(payload) >= want do
      payload
    else
      receive do
        {:quic, :new_stream, s, _} ->
          :quicer.setopt(s, :active, true)
          collect_wt_uni(sid, want, Map.put_new(streams, s, {:unknown, <<>>}), payload)

        {:quic, bin, s, _} when is_binary(bin) ->
          {streams, payload} = feed_uni(sid, s, bin, streams, payload)
          collect_wt_uni(sid, want, streams, payload)

        {:quic, _o, _, _} ->
          collect_wt_uni(sid, want, streams, payload)
      after
        @recv_timeout -> flunk("server push (WT uni) 来ず (payload=#{inspect(payload)})")
      end
    end
  end

  defp feed_uni(sid, s, bin, streams, payload) do
    case Map.get(streams, s, {:unknown, <<>>}) do
      {:wt, _} ->
        {streams, (payload || <<>>) <> bin}

      :other ->
        {streams, payload}

      {:unknown, buf} ->
        buf = buf <> bin

        case :cow_http3.parse_unidi_stream_header(buf) do
          {:ok, {:webtransport, ^sid}, rest} -> {Map.put(streams, s, {:wt, true}), (payload || <<>>) <> rest}
          {:ok, _t, _} -> {Map.put(streams, s, :other), payload}
          {:undefined, _} -> {Map.put(streams, s, :other), payload}
          :more -> {Map.put(streams, s, {:unknown, buf}), payload}
        end
    end
  end

  # CONNECT を path 指定で送り、:status を返す（受理/拒否の確認用）。
  defp request_status(conn, path) do
    {:ok, req} = :quicer.start_stream(conn, %{open_flag: 0, active: true})
    {:ok, sid} = :quicer.get_stream_id(req)

    headers = [
      {":method", "CONNECT"},
      {":scheme", "https"},
      {":authority", "localhost"},
      {":path", path},
      {":protocol", "webtransport"}
    ]

    {:ok, block, _ins, _enc} =
      :cow_qpack.encode_field_section(headers, sid, :cow_qpack.init(:encoder, 0, 0))

    :quicer.send(req, :cow_http3.headers(block))
    recv_response_status(req, sid)
  end

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
  # 一気に多数繋ぐと msquic の accept backlog が瞬間的に溢れて connection_refused に
  # なりうるので、過渡的エラーは軽くリトライする（本物のクライアントもそうする）。
  defp connect(port, tries \\ 5) do
    conn = do_quic_connect(port, tries)

    {:ok, ctrl} = :quicer.start_stream(conn, %{open_flag: 1, active: true})
    {:ok, enc} = :quicer.start_stream(conn, %{open_flag: 1, active: true})
    {:ok, dec} = :quicer.start_stream(conn, %{open_flag: 1, active: true})
    settings = :cow_http3.settings(%{enable_connect_protocol: true, h3_datagram: true})
    :quicer.send(ctrl, [<<0>>, settings])
    :quicer.send(enc, <<2>>)
    :quicer.send(dec, <<3>>)
    conn
  end

  defp do_quic_connect(port, tries) do
    opts = [
      {:alpn, [~c"h3"]},
      {:verify, :none},
      {:peer_unidi_stream_count, 256},
      {:peer_bidi_stream_count, 256},
      {:datagram_send_enabled, 1},
      {:datagram_receive_enabled, 1}
    ]

    case :quicer.connect(~c"localhost", port, opts, @recv_timeout) do
      {:ok, conn} ->
        conn

      {:error, _, _} when tries > 1 ->
        Process.sleep(50)
        do_quic_connect(port, tries - 1)

      {:error, reason, info} ->
        flunk("connect 失敗: #{inspect({reason, info})}")
    end
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
