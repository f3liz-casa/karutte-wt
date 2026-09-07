defmodule Karutte.Http3.Connection do
  @moduledoc """
  A GenServer that owns one HTTP/3 connection. The engine of WebTransport over HTTP/3.

  This single process is the **sole owner** of the quicer connection and takes on four jobs:

    1. The H3 handshake (three local control/qpack streams plus the SETTINGS exchange), via cow_http3_machine.
    2. Accepting Extended CONNECT (`:protocol = webtransport`), replying 200, and establishing a
       WebTransport session, starting a `Karutte.WebTransport.Session` runner for it.
    3. Routing the peer's WebTransport streams and datagrams to the runner under the normalized
       `{:quic, ...}` contract. WebTransport stream bytes (once the preface is stripped) are raw,
       not H3 frames.
    4. Lowering operation messages from the transport (`Karutte.QuicTransport.Http3`) into quicer calls.

  Concentrating ownership in one process means quicer's affine handles and the handoff race
  window are both settled in here. The race window is closed by a per-stream early-bytes
  buffer (`wt_buf`).

  cow_http3_machine speaks in numeric stream ids and quicer in handles, so both mappings are kept.
  """

  use GenServer
  require Logger

  alias Karutte.WebTransport.{Session, StreamServer}

  @transport Karutte.QuicTransport.Http3

  # msquic flags
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
    max_sessions: 16,
    max_datagram_queue: 1_000,
    sessions: %{},
    sess_qs: %{},
    draining: MapSet.new(),
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

  # A child of ConnectionSup (DynamicSupervisor). A dead connection is cleaned up, not restarted (temporary).
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Called by the acceptor after moving an accepted connection here with controlling_process. Starts with the handshake."
  def setup(pid), do: GenServer.cast(pid, :setup)

  @doc "Graceful shutdown: send H3 GOAWAY and a DRAIN capsule to every WebTransport session."
  def drain(pid), do: GenServer.cast(pid, :drain)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %__MODULE__{
       qconn: Keyword.fetch!(opts, :qconn),
       handler: Keyword.fetch!(opts, :handler),
       handler_arg: Keyword.get(opts, :handler_arg),
       max_sessions: Keyword.get(opts, :max_sessions, 16),
       max_datagram_queue: Keyword.get(opts, :max_datagram_queue, 1_000)
     }}
  end

  # Now that we own the connection: handshake first (in our own process, so handshakes run
  # concurrently and no events are lost), then bring up H3.
  @impl GenServer
  def handle_cast(:setup, s) do
    case :quicer.handshake(s.qconn) do
      {:ok, _} -> {:noreply, do_setup(s)}
      {:error, reason} -> {:stop, {:shutdown, {:handshake, reason}}, s}
    end
  end

  # Graceful shutdown: signal "no more new work" (GOAWAY) and send DRAIN to each session.
  # The actual close is done by the caller (Server.drain) after the grace period.
  def handle_cast(:drain, %{machine: nil} = s), do: {:noreply, s}

  def handle_cast(:drain, s) do
    if s.ctrl_qs, do: :quicer.send(s.ctrl_qs, goaway_frame(s))

    for {_sid, qs} <- s.sess_qs do
      :quicer.send(qs, :cow_capsule.wt_drain_session())
    end

    telem([:connection, :drain], %{sessions: map_size(s.sessions)})
    # From here on these sessions refuse new streams (in-flight ones live on).
    {:noreply, %{s | draining: MapSet.union(s.draining, MapSet.new(Map.keys(s.sessions)))}}
  end

  # The GOAWAY frame (type 0x07 + length + StreamID varint). The id marks "nothing past this
  # is processed". We pass the highest current session id + 4 (the next bidi), so in-flight
  # sessions live on and new ones are refused.
  defp goaway_frame(s) do
    last = Enum.max([0 | Map.keys(s.sessions)]) + 4
    payload = :cow_http3.encode_int(last)
    [<<0x07>>, :cow_http3.encode_int(:erlang.iolist_size(payload)), payload]
  end

  # --- Bringing up H3 ---

  defp do_setup(s) do
    {:ok, settings, machine} =
      :cow_http3_machine.init(:server, %{
        enable_connect_protocol: true,
        h3_datagram: true,
        enable_webtransport: true,
        wt_max_sessions: s.max_sessions,
        max_decode_table_size: 0,
        max_encode_table_size: 0,
        max_decode_blocked_streams: 0
      })

    # Three local unidirectional streams: control (0x00) / qpack encoder (0x02) / qpack decoder (0x03).
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

    # Keep receiving the streams the peer opens from now on.
    arm_accept(s.qconn)
    telem([:connection, :start], %{})

    s =
      %{s | machine: machine, ctrl_qs: ctrl, enc_qs: enc, dec_qs: dec}
      |> learn(ctrl, :local)
      |> learn(enc, :local)
      |> learn(dec, :local)

    # Replay quic messages that arrived before setup (the flushed backlog).
    pending = Enum.reverse(s.pending)
    s = %{s | pending: []}
    Enum.reduce(pending, s, fn msg, acc -> replay(msg, acc) end)
  end

  # --- Events from quicer ---

  # quic messages that arrive before the machine is up (before setup) are held back.
  @impl GenServer
  def handle_info({:quic, _, _, _} = msg, %{machine: nil} = s),
    do: {:noreply, %{s | pending: [msg | s.pending]}}

  def handle_info({:quic, :new_stream, qs, _props}, s) do
    arm_accept(s.qconn)
    id = sid(qs)
    dir = if Bitwise.band(id, 0x2) == 0, do: :bidi, else: :uni
    # Receive one chunk first, to read the preface / stream type. Once the type is known,
    # control streams go permanently active; WebTransport streams are demand-driven (passive
    # until the StreamServer arms them, so the QUIC window carries the backpressure).
    :quicer.setopt(qs, :active, :once)

    # Peer unidirectional streams must be registered with the machine before their type is read.
    machine =
      if dir == :uni,
        do: :cow_http3_machine.init_unidi_stream(id, :unidi_remote, s.machine),
        else: s.machine

    {:noreply, %{s | machine: machine} |> put_id(qs, id) |> put_kind(qs, :pending) |> put_dir(qs, dir)}
  end

  # Stream data or a datagram (a datagram if the third element is the connection handle).
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
  def handle_info({:quic, :send_shutdown_complete, _stream, _}, s), do: {:noreply, s}
  def handle_info({:quic, :peer_receive_aborted, _stream, _}, s), do: {:noreply, s}

  def handle_info({:quic, event, _c, _}, s)
      when event in [:transport_shutdown, :shutdown, :closed] do
    {:stop, :normal, s}
  end

  # --- Operations from the transport (Karutte.QuicTransport.Http3) ---

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

  # Datagrams are fire-and-forget (RFC 9221). The synchronous send_dgram blocks this
  # connection process until msquic reports the send state, about one RTT, which throttled a
  # 50/s voice stream to 20/s and delayed it (measured in heya). The send-state notification
  # is discarded in the clause below.
  def handle_info({:datagram, sid, data}, s) do
    :quicer.async_send_dgram(s.qconn, :erlang.iolist_to_binary(:cow_http3.datagram(sid, data)))
    {:noreply, s}
  end

  def handle_info({:quic, :dgram_send_state, _c, _}, s), do: {:noreply, s}

  # The transport's close/2: close just that WebTransport session (the QUIC connection stays up for the others).
  def handle_info({:close_session, sid, code}, s) do
    case Map.get(s.sess_qs, sid) do
      nil -> :ok
      qs -> :quicer.send(qs, :erlang.iolist_to_binary(:cow_capsule.wt_close_session(code, <<>>)))
    end

    {:noreply, close_session(s, sid)}
  end

  # Cleanup when a linked child dies. A Session runner: clean up that session. A StreamServer
  # for a server-initiated stream: reset the stream if the exit was abnormal.
  def handle_info({:EXIT, pid, reason}, s) do
    cond do
      (sid = Enum.find_value(s.sessions, fn {id, p} -> p == pid && id end)) != nil ->
        {:noreply, forget_session(s, sid)}

      (qs = Enum.find_value(s.wt_owner, fn {q, p} -> p == pid && q end)) != nil ->
        case reason do
          :normal -> :ok
          {:shutdown, _} -> :ok
          _ -> :quicer.async_shutdown_stream(qs, @shutdown_abort_send + @shutdown_abort_receive, 0)
        end

        {:noreply, drop_stream(s, qs)}

      true ->
        {:noreply, s}
    end
  end

  def handle_info(other, s) do
    Logger.debug("Http3.Connection unhandled: #{inspect(other)}")
    {:noreply, s}
  end

  @impl GenServer
  def terminate(_reason, %{qconn: qconn} = s) when qconn != nil do
    # Session runners go down with us through the link. Only the QUIC connection is closed explicitly.
    telem([:connection, :stop], %{sessions: map_size(s.sessions)})
    :quicer.async_shutdown_connection(qconn, 0, 0)
    :ok
  end

  def terminate(_reason, _s), do: :ok

  @impl GenServer
  def handle_call({:open_stream, dir, sid, opts}, _from, s) do
    flag = if dir == :uni, do: @open_uni, else: 0
    # cowlib spells direction :unidi / :bidi (ours is :uni / :bidi).
    wt_dir = if dir == :uni, do: :unidi, else: :bidi
    {:ok, qs} = :quicer.start_stream(s.qconn, %{open_flag: flag, active: true})
    :quicer.send(qs, :cow_http3.webtransport_stream_header(sid, wt_dir))

    # Server-initiated streams must also be registered with the machine before become (uni as local unidi).
    machine =
      case dir do
        :uni -> :cow_http3_machine.init_unidi_stream(sid(qs), :unidi_local, s.machine)
        :bidi -> :cow_http3_machine.init_bidi_stream(sid(qs), s.machine)
      end

    {:ok, machine} = :cow_http3_machine.become_webtransport_stream(sid(qs), sid, machine)

    s =
      %{s | machine: machine}
      |> put_id(qs, sid(qs))
      |> put_kind(qs, :wt)
      |> put_dir(qs, dir)
      |> put_wt_sess(qs, sid)

    # If a handler is given (to read a server-initiated bidi), this Connection starts the
    # StreamServer and makes it the owner. Receives flow through the existing route_wt, and
    # the handoff completes immediately with an empty buffer.
    s =
      case Keyword.get(opts, :handler) do
        nil ->
          s

        mod ->
          {:ok, pid} =
            StreamServer.start_link(
              transport: @transport,
              stream: h3s(s, qs),
              handler: mod,
              init_arg: Keyword.get(opts, :init_arg)
            )

          Kernel.send(pid, {:handoff_done, h3s(s, qs), []})
          %{s | wt_owner: Map.put(s.wt_owner, qs, pid)}
      end

    {:reply, {:ok, h3s(s, qs)}, s}
  end

  # ================= Receiving =================

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

  # A new stream of unknown type yet: look at its head and dispatch.
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
        # Internal control streams are read continuously (low volume, not subject to backpressure).
        :quicer.setopt(qs, :active, true)
        s = %{s | machine: machine} |> put_kind(qs, type) |> clear_buf(qs)
        on_stream_data(qs, rest, fin, s)

      {:ok, {:webtransport, session_id}, rest} ->
        s = start_wt_stream(s, qs, session_id, :uni)
        route_wt(s, qs, rest, fin)

      {:undefined, _rest} ->
        # An unknown unidirectional stream. Ignore it (without going as far as a reset).
        put_kind(s, qs, :ignore)

      :more ->
        set_buf(s, qs, buf)
    end
  end

  defp classify_bidi(s, qs, buf, fin) do
    case :cow_http3.parse(buf) do
      {:webtransport_stream_header, session_id, rest} ->
        # A WebTransport bidi must also be registered with the machine as bidi before become_webtransport_stream.
        machine = :cow_http3_machine.init_bidi_stream(sid(qs), s.machine)
        s = start_wt_stream(%{s | machine: machine}, qs, session_id, :bidi)
        route_wt(s, qs, rest, fin)

      _ ->
        # An H3 request stream. Register it with the machine and feed it frames.
        # Read continuously: the CONNECT and, afterwards, the session capsules.
        :quicer.setopt(qs, :active, true)
        machine = :cow_http3_machine.init_bidi_stream(sid(qs), s.machine)
        s = %{s | machine: machine} |> put_kind(qs, :request) |> clear_buf(qs)
        feed_request(s, qs, buf, fin)
    end
  end

  # The control stream: H3 frames (SETTINGS etc.) go to the machine.
  defp feed_control(s, qs, bin, fin) do
    drive_frames(s, qs, bin, fin)
  end

  # A request stream: look at HEADERS and handle CONNECT (webtransport).
  defp feed_request(s, qs, bin, fin) do
    drive_frames(s, qs, bin, fin)
  end

  # Shared by control/request: append to the buffer and feed frames to the machine in order.
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
          # Once CONNECT is accepted and this bidi has become a WebTransport session stream,
          # the bytes that follow are session capsules, not H3 frames. Feeding them to
          # machine.frame crashes cowlib (data_frame on a wt_session). Stop here and drop them.
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
        # Just in case a bidi WebTransport stream ends up here.
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

      {:ok, {:headers, headers, pseudo, _len}, instr, machine} ->
        s = %{s | machine: machine}
        s = flush_instr(s, instr)
        on_request_headers(s, qs, pseudo, headers)

      {:ok, {:data, _data}, machine} ->
        # A request body. Not used by WebTransport.
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

  # On CONNECT (webtransport), consult the handler and reply 200 or 4xx.
  defp on_request_headers(s, qs, pseudo, headers) do
    cond do
      pseudo[:method] != "CONNECT" or pseudo[:protocol] != "webtransport" ->
        # Anything but WebTransport gets a 404.
        reject(s, qs, 404)

      map_size(s.sessions) >= s.max_sessions ->
        # Session limit. Refuse with 503 (the connection itself stays up).
        Logger.info("WebTransport session limit (#{s.max_sessions}) reached, refusing CONNECT")
        reject(s, qs, 503)

      true ->
        accept_webtransport(s, qs, pseudo, headers)
    end
  end

  defp reject(s, qs, status) do
    s = respond(s, qs, status, true)
    :quicer.async_shutdown_stream(qs, @shutdown_graceful, 0)
    s
  end

  # Pick the handler for this request (a fixed module, or a routing function of conn_info),
  # then put the request to its authorize/1 gate. On :ok, reply 200 and start the session.
  # On {:reject, status}, refuse (authentication, routing).
  defp accept_webtransport(s, qs, pseudo, headers) do
    id = sid(qs)
    conn = {:h3c, self(), s.qconn, id}

    peer = peer_addr(s.qconn)

    conn_info = %{
      transport: @transport,
      conn: conn,
      path: pseudo[:path],
      authority: pseudo[:authority],
      headers: headers,
      # The QUIC peer address. Behind a transparent relay this is the real client IP; behind
      # a SNAT relay it is the relay's address. Useful for authorize/1, rate limiting, logs,
      # and telemetry correlation.
      peer: peer
    }

    with {:ok, handler, handler_arg} <- resolve_handler(s, conn_info),
         :ok <- authorize(handler, conn_info) do
      {:ok, pid} =
        Session.start_link(
          transport: @transport,
          conn: conn,
          handler: handler,
          init_arg: handler_arg,
          conn_info: conn_info
        )

      # Reply 200 while the stream is still a bidi (it becomes a wt_session right after).
      s = respond(s, qs, 200, false)
      machine = :cow_http3_machine.become_webtransport_session(id, s.machine)
      telem([:session, :open], %{session_id: id, path: pseudo[:path], peer: peer})
      # The session is up. From here the handler may open server-initiated streams.
      Kernel.send(pid, :wt_ready)

      %{s | machine: machine, sessions: Map.put(s.sessions, id, pid), sess_qs: Map.put(s.sess_qs, id, qs)}
      |> put_kind(qs, :session)
    else
      {:reject, status} ->
        telem([:session, :rejected], %{path: pseudo[:path], status: status})
        reject(s, qs, status)
    end
  end

  # `:handler` is either a module (with `:handler_arg`) or a function of conn_info returning
  # `{module, arg}` or `{:reject, status}`. The function form is how one server serves
  # several handlers by path.
  defp resolve_handler(%{handler: route}, conn_info) when is_function(route, 1) do
    case route.(conn_info) do
      {:reject, _status} = rej -> rej
      {mod, arg} -> {:ok, mod, arg}
    end
  end

  defp resolve_handler(s, _conn_info), do: {:ok, s.handler, s.handler_arg}

  defp authorize(handler, conn_info) do
    if function_exported?(handler, :authorize, 1), do: handler.authorize(conn_info), else: :ok
  end

  defp respond(s, qs, status, fin?) do
    finatom = if fin?, do: :fin, else: :nofin

    {:ok, _fin, header_block, instr, machine} =
      :cow_http3_machine.prepare_headers(sid(qs), s.machine, finatom, %{status: status}, [])

    s = flush_instr(%{s | machine: machine}, instr)
    :quicer.send(qs, :cow_http3.headers(header_block), if(fin?, do: @send_fin, else: 0))
    s
  end

  # Bytes on the qpack encoder/decoder streams.
  defp feed_qpack(s, qs, bin, fin) do
    finatom = if fin, do: :fin, else: :nofin

    case :cow_http3_machine.unidi_data(bin, finatom, sid(qs), s.machine) do
      {:ok, instr, machine} -> flush_instr(%{s | machine: machine}, instr)
      {:error, reason, machine} ->
        Logger.warning("qpack error: #{inspect(reason)}")
        %{s | machine: machine}
    end
  end

  # Write the qpack instructions the machine returns back to the matching local stream.
  defp flush_instr(s, :undefined), do: s
  defp flush_instr(s, {:decoder_instructions, data}) do
    :quicer.send(s.dec_qs, data)
    s
  end
  defp flush_instr(s, {:encoder_instructions, data}) do
    :quicer.send(s.enc_qs, data)
    s
  end

  # ================= WebTransport streams =================

  defp start_wt_stream(s, qs, session_id, dir) do
    if MapSet.member?(s.draining, session_id) do
      # A draining session refuses new streams (reset in both directions).
      :quicer.async_shutdown_stream(qs, @shutdown_abort_send + @shutdown_abort_receive, 0)
      telem([:stream, :refused], %{session_id: session_id})
      drop_stream(s, qs)
    else
      accept_wt_stream(s, qs, session_id, dir)
    end
  end

  defp accept_wt_stream(s, qs, session_id, dir) do
    {:ok, machine} = :cow_http3_machine.become_webtransport_stream(sid(qs), session_id, s.machine)

    s =
      %{s | machine: machine}
      |> put_kind(qs, :wt)
      |> put_dir(qs, dir)
      |> put_wt_sess(qs, session_id)
      |> clear_buf(qs)

    # Notify the owning session's runner of the new stream. Bytes are buffered until an owner is decided.
    case Map.get(s.sessions, session_id) do
      nil ->
        :ok

      pid ->
        Kernel.send(pid, {:quic, :new_stream, {:h3c, self(), s.qconn, session_id}, h3s(s, qs), dir})
    end

    Map.update!(s, :wt_buf, &Map.put_new(&1, qs, []))
  end

  # Raw WebTransport stream bytes: forward if there is an owner, otherwise buffer.
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

  # From control/2. Hand the early-bytes buffer over as handoff_done, then route live traffic to pid.
  defp hand_off(s, qs, pid) do
    buffered =
      s.wt_buf
      |> Map.get(qs, [])
      |> Enum.map(fn {bin, fin} -> {bin, [fin: fin]} end)

    Kernel.send(pid, {:handoff_done, h3s(s, qs), buffered})
    %{s | wt_owner: Map.put(s.wt_owner, qs, pid), wt_buf: Map.delete(s.wt_buf, qs)}
  end

  # ================= Capsules on the session stream =================

  # After CONNECT is accepted, the session stream carries the Capsule Protocol (RFC 9297).
  # We pick up CLOSE / DRAIN. The session_id is this stream's id.
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
        # A drain request from the peer. This session takes no new streams (in-flight ones live on).
        telem([:session, :drain], %{session_id: sid})
        parse_capsules(%{s | draining: MapSet.put(s.draining, sid)}, qs, sid, rest)

      {:ok, rest} ->
        # Skip unknown capsules and keep going.
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

  # Consume the "skip n more bytes" decided by an earlier capsule.
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

  # Clean up a WebTransport session. Stop the runner (its StreamServers go with it) and remove
  # the wt_session and its wt_streams from the machine. The QUIC connection is untouched.
  defp close_session(s, session_id) do
    case Map.get(s.sessions, session_id) do
      nil -> s
      pid -> if(Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)); forget_session(s, session_id)
    end
  end

  # Remove a session from the maps and the machine (the runner is assumed already stopped, or
  # stopped elsewhere). cow_http3_machine.close_webtransport_session raises on a double call,
  # so exactly once.
  defp forget_session(s, session_id) do
    if Map.has_key?(s.sessions, session_id) do
      telem([:session, :close], %{session_id: session_id})

      machine =
        if s.machine, do: :cow_http3_machine.close_webtransport_session(session_id, s.machine), else: s.machine

      %{
        s
        | machine: machine,
          sessions: Map.delete(s.sessions, session_id),
          sess_qs: Map.delete(s.sess_qs, session_id),
          draining: MapSet.delete(s.draining, session_id)
      }
    else
      s
    end
  end

  # ================= datagram =================

  # Datagrams are off-axis (RFC 9221): no flow control. Under overload, drop; never block.
  # If the session runner's mailbox is over the limit, the datagram is dropped (bounded queue → drop).
  defp on_datagram(bin, s) do
    {session_id, payload} = :cow_http3.parse_datagram(bin)

    case Map.get(s.sessions, session_id) do
      nil ->
        s

      pid ->
        if overloaded?(pid, s.max_datagram_queue) do
          telem([:datagram, :dropped], %{session_id: session_id})
        else
          Kernel.send(pid, {:quic, :datagram, {:h3c, self(), s.qconn, session_id}, payload})
        end

        s
    end
  end

  defp overloaded?(pid, max) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} -> n > max
      nil -> true
    end
  end

  defp telem(event, meta), do: :telemetry.execute([:karutte, :http3 | event], %{count: 1}, meta)

  # ================= Helpers =================

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

  # The QUIC connection's peer address ({ip, port}), or nil if unavailable.
  defp peer_addr(qconn) do
    case :quicer.peername(qconn) do
      {:ok, addr} -> addr
      _ -> nil
    end
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

  # Where a WebTransport stream message goes: its owner if any, else the runner of its session.
  defp forward(s, qs, msg) do
    pid = Map.get(s.wt_owner, qs) || Map.get(s.sessions, Map.get(s.wt_sess, qs))
    if pid, do: Kernel.send(pid, msg)
    s
  end
end
