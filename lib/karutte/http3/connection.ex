defmodule Karutte.Http3.Connection do
  @moduledoc """
  HTTP/3 接続を一つ持つ GenServer。WebTransport over HTTP/3 のエンジン。

  この一プロセスが quicer 接続の**唯一の所有者**で、四つを引き受ける:

    1. H3 ハンドシェイク（ローカル control/qpack 3 本 + SETTINGS 交換）を cow_http3_machine で。
    2. Extended CONNECT（`:protocol = webtransport`）を受けて 200 を返し、WT セッションを確立。
       そのセッションのために `Karutte.WebTransport.Session` runner を起こす。
    3. peer の WT ストリーム / datagram を、正規化した `{:quic, …}` 契約で runner へ振る。
       WT ストリームのバイトは（preface を剥がしたあと）H3 フレームでなく生。
    4. 床（`Karutte.QuicTransport.Http3`）からの命令メッセージを quicer 呼び出しに落とす。

  所有を一プロセスに集めることで、quicer ハンドルの affine 性も handoff の競合窓も、
  この中だけで閉じる。competing window は WT ストリームごとの先着バッファ（`wt_buf`）で。

  cow_http3_machine は数値 stream id で、quicer はハンドルで話すので、両方の対応表を持つ。
  """

  use GenServer
  require Logger

  alias Karutte.WebTransport.Session

  @transport Karutte.QuicTransport.Http3

  # msquic フラグ
  @open_uni 1
  @send_fin 0x4
  @shutdown_graceful 1
  @shutdown_abort_send 2
  @shutdown_abort_receive 4

  defstruct [
    :qconn,
    :machine,
    :handler,
    :handler_arg,
    :ctrl_qs,
    :enc_qs,
    :dec_qs,
    sessions: %{},
    sess_qs: %{},
    ids: %{},
    kinds: %{},
    bufs: %{},
    wt_buf: %{},
    wt_owner: %{},
    wt_dir: %{},
    wt_sess: %{},
    skip: %{},
    pending: []
  ]

  @doc "acceptor から呼ぶ。qconn の所有を移してから setup/0 を送ること。"
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "link せずに起こす（一接続の事故をサーバ全体に波及させないため acceptor はこちら）。"
  def start(opts), do: GenServer.start(__MODULE__, opts)

  @doc "controlling_process で所有を移したあと、acceptor がこれを呼んで H3 を立ち上げる。"
  def setup(pid), do: GenServer.cast(pid, :setup)

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       qconn: Keyword.fetch!(opts, :qconn),
       handler: Keyword.fetch!(opts, :handler),
       handler_arg: Keyword.get(opts, :handler_arg)
     }}
  end

  # --- H3 立ち上げ（所有を得たあと） ---

  @impl true
  def handle_cast(:setup, s) do
    {:ok, settings, machine} =
      :cow_http3_machine.init(:server, %{
        enable_connect_protocol: true,
        h3_datagram: true,
        enable_webtransport: true,
        wt_max_sessions: 16,
        max_decode_table_size: 0,
        max_encode_table_size: 0,
        max_decode_blocked_streams: 0
      })

    # ローカルの単方向 3 本: control(0x00) / qpack encoder(0x02) / qpack decoder(0x03)。
    {:ok, ctrl} = open_local_unidi(s.qconn)
    {:ok, enc} = open_local_unidi(s.qconn)
    {:ok, dec} = open_local_unidi(s.qconn)
    :quicer.send(ctrl, [<<0>>, settings])
    :quicer.send(enc, <<2>>)
    :quicer.send(dec, <<3>>)

    machine =
      :cow_http3_machine.init_unidi_local_streams(
        sid(ctrl),
        sid(enc),
        sid(dec),
        machine
      )

    # 以後 peer が開くストリームを受け取り続ける。
    arm_accept(s.qconn)

    s =
      %{s | machine: machine, ctrl_qs: ctrl, enc_qs: enc, dec_qs: dec}
      |> learn(ctrl, :local)
      |> learn(enc, :local)
      |> learn(dec, :local)

    # setup より先に届いていた quic メッセージ（controlling_process のフラッシュ）を再生。
    pending = Enum.reverse(s.pending)
    s = %{s | pending: []}
    {:noreply, Enum.reduce(pending, s, fn msg, acc -> replay(msg, acc) end)}
  end

  # --- quicer からのイベント ---

  # machine が立つ前（setup 前）に来た quic メッセージは貯めておく。
  @impl true
  def handle_info({:quic, _, _, _} = msg, %{machine: nil} = s),
    do: {:noreply, %{s | pending: [msg | s.pending]}}

  def handle_info({:quic, :new_stream, qs, _props}, s) do
    arm_accept(s.qconn)
    id = sid(qs)
    dir = if Bitwise.band(id, 0x2) == 0, do: :bidi, else: :uni
    :quicer.setopt(qs, :active, true)

    # 単方向 peer ストリームは型を読む前に machine へ登録が要る。
    machine =
      if dir == :uni,
        do: :cow_http3_machine.init_unidi_stream(id, :unidi_remote, s.machine),
        else: s.machine

    {:noreply, %{s | machine: machine} |> put_id(qs, id) |> put_kind(qs, :pending) |> put_dir(qs, dir)}
  end

  # ストリームデータ or datagram（3 番目が接続ハンドルなら datagram）。
  def handle_info({:quic, bin, handle, meta}, s) when is_binary(bin) do
    cond do
      handle == s.qconn -> {:noreply, on_datagram(bin, s)}
      true -> {:noreply, on_stream_data(handle, bin, fin?(meta), s)}
    end
  end

  def handle_info({:quic, :peer_send_shutdown, qs, _}, s),
    do: {:noreply, on_stream_data(qs, <<>>, true, s)}

  def handle_info({:quic, :peer_send_aborted, qs, code}, s) do
    forward(s, qs, {:quic, :reset, h3s(s, qs), code})
    {:noreply, s}
  end

  def handle_info({:quic, :stream_closed, qs, _}, s) do
    forward(s, qs, {:quic, :closed, h3s(s, qs), :stream_closed})
    {:noreply, drop_stream(s, qs)}
  end

  def handle_info({:quic, :dgram_state_changed, _c, _}, s), do: {:noreply, s}
  def handle_info({:quic, :connected, _c, _}, s), do: {:noreply, s}
  def handle_info({:quic, :streams_available, _c, _}, s), do: {:noreply, s}
  def handle_info({:quic, :send_complete, _stream, _}, s), do: {:noreply, s}
  def handle_info({:quic, :peer_receive_aborted, _stream, _}, s), do: {:noreply, s}

  def handle_info({:quic, event, _c, _}, s)
      when event in [:transport_shutdown, :shutdown, :closed] do
    {:stop, :normal, s}
  end

  # --- 床（Karutte.QuicTransport.Http3）からの命令 ---

  def handle_info({:set_owner, qs, pid}, s), do: {:noreply, hand_off(s, qs, pid)}

  def handle_info({:stream_set_active, qs, active}, s) do
    :quicer.setopt(qs, :active, active)
    {:noreply, s}
  end

  def handle_info({:stream_send, qs, data, fin?}, s) do
    flags = if fin?, do: @send_fin, else: 0
    :quicer.send(qs, data, flags)
    {:noreply, s}
  end

  def handle_info({:stream_shutdown, qs, how}, s) do
    {flag, code} = shutdown_flag(how)
    :quicer.async_shutdown_stream(qs, flag, code)
    {:noreply, s}
  end

  def handle_info({:datagram, sid, data}, s) do
    :quicer.send_dgram(s.qconn, :erlang.iolist_to_binary(:cow_http3.datagram(sid, data)))
    {:noreply, s}
  end

  # 床の close/2 ＝ その WT セッションだけ閉じる（QUIC 接続は他セッションのため生かす）。
  def handle_info({:close_session, sid, code}, s) do
    case Map.get(s.sess_qs, sid) do
      nil -> :ok
      qs -> :quicer.send(qs, :erlang.iolist_to_binary(:cow_capsule.wt_close_session(code, <<>>)))
    end

    {:noreply, close_session(s, sid)}
  end

  def handle_info(other, s) do
    Logger.debug("Http3.Connection 未処理: #{inspect(other)}")
    {:noreply, s}
  end

  @impl true
  def handle_call({:open_stream, dir, sid}, _from, s) do
    flag = if dir == :uni, do: @open_uni, else: 0
    {:ok, qs} = :quicer.start_stream(s.qconn, %{open_flag: flag, active: true})
    :quicer.send(qs, :cow_http3.webtransport_stream_header(sid, dir))
    {:ok, machine} = :cow_http3_machine.become_webtransport_stream(sid(qs), sid, s.machine)

    s =
      %{s | machine: machine}
      |> put_id(qs, sid(qs))
      |> put_kind(qs, :wt)
      |> put_dir(qs, dir)
      |> put_wt_sess(qs, sid)

    {:reply, {:ok, h3s(s, qs)}, s}
  end

  # ================= 受信の中身 =================

  defp on_stream_data(qs, bin, fin, s) do
    case Map.get(s.kinds, qs) do
      :wt -> route_wt(s, qs, bin, fin)
      :pending -> classify(s, qs, bin, fin)
      :control -> feed_control(s, qs, bin, fin)
      :request -> feed_request(s, qs, bin, fin)
      :session -> feed_session(s, qs, bin, fin)
      kind when kind in [:encoder, :decoder] -> feed_qpack(s, qs, bin, fin)
      _ -> s
    end
  end

  # まだ種別不明の新ストリーム: 先頭を見て振り分ける。
  defp classify(s, qs, bin, fin) do
    buf = Map.get(s.bufs, qs, <<>>) <> bin

    case Map.get(s.wt_dir, qs) do
      :uni -> classify_unidi(s, qs, buf, fin)
      :bidi -> classify_bidi(s, qs, buf, fin)
    end
  end

  defp classify_unidi(s, qs, buf, fin) do
    case :cow_http3.parse_unidi_stream_header(buf) do
      {:ok, type, rest} when type in [:control, :encoder, :decoder] ->
        {:ok, machine} = :cow_http3_machine.set_unidi_remote_stream_type(sid(qs), type, s.machine)
        s = %{s | machine: machine} |> put_kind(qs, type) |> clear_buf(qs)
        on_stream_data(qs, rest, fin, s)

      {:ok, {:webtransport, session_id}, rest} ->
        s = start_wt_stream(s, qs, session_id, :uni)
        route_wt(s, qs, rest, fin)

      {:undefined, _rest} ->
        # 知らない単方向ストリーム。捨てる（reset まではしない）。
        put_kind(s, qs, :ignore)

      :more ->
        set_buf(s, qs, buf)
    end
  end

  defp classify_bidi(s, qs, buf, fin) do
    case :cow_http3.parse(buf) do
      {:webtransport_stream_header, session_id, rest} ->
        # WT bidi も become_webtransport_stream の前に bidi として machine 登録が要る。
        machine = :cow_http3_machine.init_bidi_stream(sid(qs), s.machine)
        s = start_wt_stream(%{s | machine: machine}, qs, session_id, :bidi)
        route_wt(s, qs, rest, fin)

      _ ->
        # H3 リクエストストリーム。machine に登録してフレームを食わせる。
        machine = :cow_http3_machine.init_bidi_stream(sid(qs), s.machine)
        s = %{s | machine: machine} |> put_kind(qs, :request) |> clear_buf(qs)
        feed_request(s, qs, buf, fin)
    end
  end

  # 制御ストリーム: H3 フレーム（SETTINGS 等）を machine へ。
  defp feed_control(s, qs, bin, fin) do
    drive_frames(s, qs, bin, fin)
  end

  # リクエストストリーム: HEADERS を見て CONNECT(webtransport) を捌く。
  defp feed_request(s, qs, bin, fin) do
    drive_frames(s, qs, bin, fin)
  end

  # control/request 共通: バッファに足してフレームを順に machine へ。
  defp drive_frames(s, qs, bin, fin) do
    buf = Map.get(s.bufs, qs, <<>>) <> bin
    do_frames(s, qs, buf, fin)
  end

  defp do_frames(s, qs, buf, fin) do
    case :cow_http3.parse(buf) do
      {:ok, frame, rest} ->
        last? = fin and rest == <<>>
        prev = Map.get(s.kinds, qs)
        s = apply_frame(s, qs, frame, last?)

        cond do
          # CONNECT が通ってこの bidi が WT セッションストリームになったら、以後の
          # バイトは H3 フレームでなくセッションの capsule。machine.frame に食わせると
          # cowlib が落ちる（wt_session に data_frame）。ここで止めて捨てる。
          prev == :request and Map.get(s.kinds, qs) == :session ->
            clear_buf(s, qs)

          rest == <<>> ->
            clear_buf(s, qs)

          true ->
            do_frames(s, qs, rest, fin)
        end

      {:more, _partial, _missing} ->
        set_buf(s, qs, buf)

      more when more == :more ->
        set_buf(s, qs, buf)

      {:ignore, rest} ->
        do_frames(s, qs, rest, fin)

      {:webtransport_stream_header, session_id, rest} ->
        # 念のため（bidi WT がここに来たら）。
        s = start_wt_stream(put_kind(s, qs, :wt), qs, session_id, :bidi)
        route_wt(clear_buf(s, qs), qs, rest, fin)

      {:connection_error, reason, _} ->
        Logger.warning("H3 connection_error: #{inspect(reason)}")
        :quicer.shutdown_connection(s.qconn)
        s
    end
  end

  defp apply_frame(s, qs, frame, fin?) do
    finatom = if fin?, do: :fin, else: :nofin

    case :cow_http3_machine.frame(frame, finatom, sid(qs), s.machine) do
      {:ok, machine} ->
        %{s | machine: machine}

      {:ok, {:headers, _headers, pseudo, _len}, instr, machine} ->
        s = %{s | machine: machine}
        s = flush_instr(s, instr)
        on_request_headers(s, qs, pseudo)

      {:ok, {:data, _data}, machine} ->
        # リクエストボディ。WT には使わない。
        %{s | machine: machine}

      {:ok, _other, machine} ->
        %{s | machine: machine}

      {:ok, _other, instr, machine} ->
        flush_instr(%{s | machine: machine}, instr)

      {:error, reason, machine} ->
        Logger.warning("H3 frame error: #{inspect(reason)}")
        %{s | machine: machine}

      {:error, reason, _instr, machine} ->
        Logger.warning("H3 stream error: #{inspect(reason)}")
        %{s | machine: machine}
    end
  end

  # CONNECT(webtransport) を受けたら 200 を返し、セッションを確立。
  defp on_request_headers(s, qs, pseudo) do
    if pseudo[:method] == "CONNECT" and pseudo[:protocol] == "webtransport" do
      accept_webtransport(s, qs)
    else
      # WT 以外は今は 404 で締める（軽い実装）。
      respond(s, qs, 404, true)
      :quicer.async_shutdown_stream(qs, @shutdown_graceful, 0)
      s
    end
  end

  defp accept_webtransport(s, qs) do
    id = sid(qs)
    s = respond(s, qs, 200, false)
    machine = :cow_http3_machine.become_webtransport_session(id, s.machine)
    conn = {:h3c, self(), s.qconn, id}

    {:ok, pid} =
      Session.start_link(
        transport: @transport,
        conn: conn,
        handler: s.handler,
        init_arg: s.handler_arg,
        conn_info: %{transport: @transport, conn: conn}
      )

    %{s | machine: machine, sessions: Map.put(s.sessions, id, pid), sess_qs: Map.put(s.sess_qs, id, qs)}
    |> put_kind(qs, :session)
  end

  defp respond(s, qs, status, fin?) do
    finatom = if fin?, do: :fin, else: :nofin

    {:ok, _fin, header_block, instr, machine} =
      :cow_http3_machine.prepare_headers(sid(qs), s.machine, finatom, %{status: status}, [])

    s = flush_instr(%{s | machine: machine}, instr)
    :quicer.send(qs, :cow_http3.headers(header_block), if(fin?, do: @send_fin, else: 0))
    s
  end

  # qpack encoder/decoder ストリームのバイト。
  defp feed_qpack(s, qs, bin, fin) do
    finatom = if fin, do: :fin, else: :nofin

    case :cow_http3_machine.unidi_data(bin, finatom, sid(qs), s.machine) do
      {:ok, instr, machine} -> flush_instr(%{s | machine: machine}, instr)
      {:error, reason, machine} ->
        Logger.warning("qpack error: #{inspect(reason)}")
        %{s | machine: machine}
    end
  end

  # machine が返す qpack 命令を、対応するローカルストリームへ書き戻す。
  defp flush_instr(s, :undefined), do: s
  defp flush_instr(s, {:decoder_instructions, data}) do
    :quicer.send(s.dec_qs, data)
    s
  end
  defp flush_instr(s, {:encoder_instructions, data}) do
    :quicer.send(s.enc_qs, data)
    s
  end

  # ================= WebTransport ストリーム =================

  defp start_wt_stream(s, qs, session_id, dir) do
    {:ok, machine} = :cow_http3_machine.become_webtransport_stream(sid(qs), session_id, s.machine)

    s =
      %{s | machine: machine}
      |> put_kind(qs, :wt)
      |> put_dir(qs, dir)
      |> put_wt_sess(qs, session_id)
      |> clear_buf(qs)

    # 属する WT セッションの runner へ new_stream を通知。所有が決まるまでバイトはバッファ。
    case Map.get(s.sessions, session_id) do
      nil ->
        :ok

      pid ->
        Kernel.send(pid, {:quic, :new_stream, {:h3c, self(), s.qconn, session_id}, h3s(s, qs), dir})
    end

    Map.update!(s, :wt_buf, &Map.put_new(&1, qs, []))
  end

  # WT ストリームの生バイト: 所有者がいれば転送、いなければバッファ。
  defp route_wt(s, _qs, <<>>, false), do: s

  defp route_wt(s, qs, bin, fin) do
    case Map.get(s.wt_owner, qs) do
      nil ->
        Map.update!(s, :wt_buf, fn b ->
          Map.update(b, qs, [{bin, fin}], &(&1 ++ [{bin, fin}]))
        end)

      pid ->
        Kernel.send(pid, {:quic, :data, h3s(s, qs), bin, fin: fin})
        s
    end
  end

  # control/2 由来。先着バッファを handoff_done で渡し、以後 live を pid へ。
  defp hand_off(s, qs, pid) do
    buffered =
      s.wt_buf
      |> Map.get(qs, [])
      |> Enum.map(fn {bin, fin} -> {bin, [fin: fin]} end)

    Kernel.send(pid, {:handoff_done, h3s(s, qs), buffered})
    %{s | wt_owner: Map.put(s.wt_owner, qs, pid), wt_buf: Map.delete(s.wt_buf, qs)}
  end

  # ================= セッションストリームの capsule =================

  # CONNECT が通った後、セッションストリームは Capsule Protocol を運ぶ（RFC 9297）。
  # CLOSE / DRAIN を拾う。session_id はこのストリーム id そのもの。
  defp feed_session(s, qs, bin, fin) do
    sid = sid(qs)
    {bin, s} = apply_skip(s, qs, bin)
    buf = Map.get(s.bufs, qs, <<>>) <> bin
    s = parse_capsules(s, qs, sid, buf)
    if fin, do: close_session(s, sid), else: s
  end

  defp parse_capsules(s, qs, sid, buf) do
    case :cow_capsule.parse(buf) do
      {:ok, {:wt_close_session, _code, _msg}, _rest} ->
        close_session(clear_buf(s, qs), sid)

      {:ok, :wt_drain_session, rest} ->
        # ドレイン要求。今は記録だけ（新規ストリームを止める本格対応は後）。
        Logger.debug("WT drain session #{sid}")
        parse_capsules(s, qs, sid, rest)

      {:ok, rest} ->
        # 知らない capsule は飛ばして続ける。
        parse_capsules(s, qs, sid, rest)

      {:skip, n} ->
        %{s | skip: Map.put(s.skip, qs, n)} |> clear_buf(qs)

      :more ->
        set_buf(s, qs, buf)

      :error ->
        Logger.debug("capsule parse error on session #{sid}")
        clear_buf(s, qs)
    end
  end

  # 前の capsule で「あと n バイト読み飛ばす」と決めていた分を消費。
  defp apply_skip(s, qs, bin) do
    case Map.get(s.skip, qs, 0) do
      0 ->
        {bin, s}

      n when n >= byte_size(bin) ->
        {<<>>, %{s | skip: Map.put(s.skip, qs, n - byte_size(bin))}}

      n ->
        <<_::binary-size(^n), rest::binary>> = bin
        {rest, %{s | skip: Map.delete(s.skip, qs)}}
    end
  end

  # WT セッションを掃除する。runner を止め（紐づく StreamServer も連れて落ちる）、
  # machine から wt_session と配下の wt_stream を消す。QUIC 接続は触らない。
  defp close_session(s, session_id) do
    case Map.get(s.sessions, session_id) do
      nil ->
        s

      pid ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
        machine = :cow_http3_machine.close_webtransport_session(session_id, s.machine)

        %{
          s
          | machine: machine,
            sessions: Map.delete(s.sessions, session_id),
            sess_qs: Map.delete(s.sess_qs, session_id)
        }
    end
  end

  # ================= datagram =================

  defp on_datagram(bin, s) do
    {session_id, payload} = :cow_http3.parse_datagram(bin)

    case Map.get(s.sessions, session_id) do
      nil -> :ok
      pid -> Kernel.send(pid, {:quic, :datagram, {:h3c, self(), s.qconn, session_id}, payload})
    end

    s
  end

  # ================= 小道具 =================

  defp replay(msg, s) do
    {:noreply, s2} = handle_info(msg, s)
    s2
  end

  defp open_local_unidi(qconn), do: :quicer.start_stream(qconn, %{open_flag: @open_uni, active: true})

  defp arm_accept(qconn), do: :quicer.async_accept_stream(qconn, [{:active, true}])

  defp sid(qs) do
    {:ok, id} = :quicer.get_stream_id(qs)
    id
  end

  defp h3s(_s, qs), do: {:h3s, self(), qs}

  defp fin?(meta) when is_map(meta), do: Bitwise.band(Map.get(meta, :flags, 0), 0x1) != 0
  defp fin?(_), do: false

  defp shutdown_flag(:write), do: {@shutdown_graceful, 0}
  defp shutdown_flag({:reset, code}), do: {@shutdown_abort_send, code}
  defp shutdown_flag({:stop_sending, code}), do: {@shutdown_abort_receive, code}

  defp learn(s, qs, :local), do: put_id(s, qs, sid(qs))
  defp put_id(s, qs, id), do: %{s | ids: Map.put(s.ids, qs, id)}
  defp put_kind(s, qs, kind), do: %{s | kinds: Map.put(s.kinds, qs, kind)}
  defp put_dir(s, qs, dir), do: %{s | wt_dir: Map.put(s.wt_dir, qs, dir)}
  defp put_wt_sess(s, qs, sid), do: %{s | wt_sess: Map.put(s.wt_sess, qs, sid)}
  defp set_buf(s, qs, buf), do: %{s | bufs: Map.put(s.bufs, qs, buf)}
  defp clear_buf(s, qs), do: %{s | bufs: Map.delete(s.bufs, qs)}

  defp drop_stream(s, qs) do
    %{
      s
      | ids: Map.delete(s.ids, qs),
        kinds: Map.delete(s.kinds, qs),
        bufs: Map.delete(s.bufs, qs),
        wt_buf: Map.delete(s.wt_buf, qs),
        wt_owner: Map.delete(s.wt_owner, qs),
        wt_dir: Map.delete(s.wt_dir, qs),
        wt_sess: Map.delete(s.wt_sess, qs),
        skip: Map.delete(s.skip, qs)
    }
  end

  # WT ストリームの宛先: 所有者がいればそこへ、いなければ属するセッションの runner へ。
  defp forward(s, qs, msg) do
    pid = Map.get(s.wt_owner, qs) || Map.get(s.sessions, Map.get(s.wt_sess, qs))
    if pid, do: Kernel.send(pid, msg)
    s
  end
end
