defmodule Karutte.Http3.LoopbackTest do
  use ExUnit.Case

  # 実 QUIC の上で、最小 Elixir クライアントが Echo サーバと喋れることを確かめる。
  # connect → H3 SETTINGS → Extended CONNECT(webtransport) → 200 → WT bidi echo → datagram echo。
  #
  # クライアントは cow_http3 / cow_qpack を直叩き（サーバ側のように machine 全部は回さない）。
  # quicer NIF が要るので test 環境で動く（ビルド済み）。

  @moduletag :quic

  @port 14_433
  @recv_timeout 5_000

  setup_all do
    tmp = Path.join(System.tmp_dir!(), "karutte_h3_#{System.unique_integer([:positive])}")
    {:ok, cert} = Karutte.Http3.Cert.generate(tmp)

    {:ok, srv} =
      Karutte.Http3.Server.start_link(
        port: @port,
        certfile: cert.certfile,
        keyfile: cert.keyfile,
        handler: Karutte.Http3.Echo,
        acceptors: 1
      )

    on_exit(fn ->
      if Process.alive?(srv), do: Process.exit(srv, :normal)
      File.rm_rf(tmp)
    end)

    :ok
  end

  test "WebTransport over HTTP/3: CONNECT 200, bidi echo, datagram echo" do
    {:ok, conn} =
      :quicer.connect(
        ~c"localhost",
        @port,
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

    # --- クライアント H3: ローカル control/encoder/decoder + SETTINGS ---
    {:ok, ctrl} = :quicer.start_stream(conn, %{open_flag: 1, active: true})
    {:ok, enc} = :quicer.start_stream(conn, %{open_flag: 1, active: true})
    {:ok, dec} = :quicer.start_stream(conn, %{open_flag: 1, active: true})
    settings = :cow_http3.settings(%{enable_connect_protocol: true, h3_datagram: true})
    :quicer.send(ctrl, [<<0>>, settings])
    :quicer.send(enc, <<2>>)
    :quicer.send(dec, <<3>>)

    qpack_enc = :cow_qpack.init(:encoder, 0, 0)
    qpack_dec = :cow_qpack.init(:decoder, 0, 0)

    # --- Extended CONNECT(webtransport) を request bidi stream で ---
    {:ok, req} = :quicer.start_stream(conn, %{open_flag: 0, active: true})
    {:ok, session_id} = :quicer.get_stream_id(req)

    headers = [
      {":method", "CONNECT"},
      {":scheme", "https"},
      {":authority", "localhost"},
      {":path", "/"},
      {":protocol", "webtransport"}
    ]

    {:ok, block, _ins, _qpack_enc} = :cow_qpack.encode_field_section(headers, session_id, qpack_enc)
    :quicer.send(req, :cow_http3.headers(block))

    # --- 200 を受ける ---
    {status, _qpack_dec} = recv_response_status(req, session_id, qpack_dec)
    assert status == "200" or status == 200

    # --- WT bidi stream に "hi" を送って echo を受ける ---
    {:ok, wt} = :quicer.start_stream(conn, %{open_flag: 0, active: true})
    :quicer.send(wt, [:cow_http3.webtransport_stream_header(session_id, :bidi), "hi"])
    assert "hi" == recv_raw(wt, "")

    # --- datagram "ping" を送って echo を受ける ---
    :quicer.send_dgram(conn, :erlang.iolist_to_binary(:cow_http3.datagram(session_id, "ping")))
    assert "ping" == recv_datagram(conn, session_id)

    :quicer.shutdown_connection(conn)
  end

  # request stream の HEADERS フレームを拾って :status を読む。
  defp recv_response_status(req, session_id, qpack_dec, buf \\ <<>>) do
    case :cow_http3.parse(buf) do
      {:ok, {:headers, block}, _rest} ->
        {:ok, headers, _ins, qpack_dec} = :cow_qpack.decode_field_section(block, session_id, qpack_dec)
        {status_of(headers), qpack_dec}

      _ ->
        receive do
          {:quic, bin, ^req, _} when is_binary(bin) ->
            recv_response_status(req, session_id, qpack_dec, buf <> bin)

          {:quic, :new_stream, s, _} ->
            :quicer.setopt(s, :active, true)
            recv_response_status(req, session_id, qpack_dec, buf)

          {:quic, _other, _, _} ->
            recv_response_status(req, session_id, qpack_dec, buf)
        after
          @recv_timeout -> flunk("200 を受け取れなかった (buf=#{inspect(buf)})")
        end
    end
  end

  defp status_of(headers) do
    Enum.find_value(headers, fn
      {":status", v} -> v
      _ -> false
    end)
  end

  # WT ストリームの生バイト（preface 無し。echo された "hi"）。
  defp recv_raw(wt, acc) do
    if byte_size(acc) >= 2 do
      acc
    else
      receive do
        {:quic, bin, ^wt, _} when is_binary(bin) -> recv_raw(wt, acc <> bin)
        {:quic, :new_stream, s, _} ->
          :quicer.setopt(s, :active, true)
          recv_raw(wt, acc)
        {:quic, _other, _, _} -> recv_raw(wt, acc)
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

      {:quic, :new_stream, s, _} ->
        :quicer.setopt(s, :active, true)
        recv_datagram(conn, session_id)

      {:quic, _other, _, _} ->
        recv_datagram(conn, session_id)
    after
      @recv_timeout -> flunk("datagram echo を受け取れなかった")
    end
  end
end
