# L2 のランナー（Session / StreamServer）が、床に依らず L3/L4 callback を回すことを
# end-to-end で押さえる。床は観測用の偽 transport に差し替える（命令を観測 pid へ転送する
# だけ）。契約メッセージ {:quic, …} を手で注入して駆動する。
#
# 支援モジュールはトップレベルに置く（テスト内にネストすると名前解決がずれるため）。

# --- 偽の床: Karutte.QuicTransport を満たし、命令を handle 内の観測 pid へ流す ---
defmodule L2RecordingTransport do
  @behaviour Karutte.QuicTransport

  @impl true
  def open_stream(_conn, _dir, _opts \\ []), do: {:error, :not_used_in_test}

  @impl true
  def control({:s, obs, _} = s, pid) do
    # control が handoff の責務を負う契約: 先着分(ここでは無し)を handoff_done で渡す。
    # テストは control 後に live を pid へ直接注入する。
    Kernel.send(pid, {:handoff_done, s, []})
    notify(obs, {:control, s, pid})
  end

  @impl true
  def set_active({:s, obs, _} = s, active), do: notify(obs, {:set_active, s, active})

  @impl true
  def send({:s, obs, _} = s, data, opts \\ []),
    do: notify(obs, {:sent, s, IO.iodata_to_binary(data), opts})

  @impl true
  def shutdown({:s, obs, _} = s, how), do: notify(obs, {:shutdown, s, how})

  @impl true
  def send_datagram({:c, obs}, data), do: notify(obs, {:datagram_out, data})

  @impl true
  def close({:c, obs}, code), do: notify(obs, {:close, code})

  defp notify(obs, msg) do
    Kernel.send(obs, msg)
    :ok
  end
end

# --- L4: handle_in で必ずクラッシュする（隔離の検証用） ---
defmodule L2CrashStream do
  @behaviour Karutte.WebTransport.Stream
  @impl true
  def init(_stream, _arg), do: {:ok, %{}, active: true}
  @impl true
  def handle_in(_bin, _state), do: raise("boom")
end

# --- L3: どのストリームも L2CrashStream に手渡す ---
defmodule L2CrashSession do
  @behaviour Karutte.WebTransport
  @impl true
  def init(obs, _info), do: {:ok, obs}
  @impl true
  def handle_stream(_stream, _dir, obs), do: {{:handler, L2CrashStream, nil}, obs}
end

# --- L4: 受けたバイトをそのまま echo、FIN で書き側を閉じる ---
defmodule L2EchoStream do
  @behaviour Karutte.WebTransport.Stream

  @impl true
  def init(_stream, _obs), do: {:ok, %{}, active: :once}

  @impl true
  def handle_in(bin, state), do: {:push, bin, state, active: :once}

  @impl true
  def handle_fin(state), do: {:close_write, state}
end

# --- L3: どのストリームも L2EchoStream に手渡す。datagram は観測 pid へ ---
defmodule L2EchoSession do
  @behaviour Karutte.WebTransport

  @impl true
  def init(obs, _info), do: {:ok, obs}

  @impl true
  def handle_stream(_stream, _dir, obs), do: {{:handler, L2EchoStream, obs}, obs}

  @impl true
  def handle_datagram(bin, obs) do
    Kernel.send(obs, {:session_datagram, bin})
    {:ok, obs}
  end
end

# --- L3: 全部 inline で受けて、揃った塊を観測 pid へ ---
defmodule L2InlineSession do
  @behaviour Karutte.WebTransport

  @impl true
  def init(obs, _info), do: {:ok, obs}

  @impl true
  def handle_stream(_stream, _dir, obs), do: {{:inline, 8}, obs}

  @impl true
  def handle_inline_stream(_stream, full, obs) do
    Kernel.send(obs, {:inline_done, full})
    {:ok, obs}
  end
end

# --- L3: 要らないストリームは reset ---
defmodule L2RejectSession do
  @behaviour Karutte.WebTransport
  @impl true
  def init(obs, _info), do: {:ok, obs}
  @impl true
  def handle_stream(_stream, _dir, obs), do: {{:reset, 7}, obs}
end

defmodule Karutte.L2Test do
  use ExUnit.Case, async: true

  alias Karutte.WebTransport.{Session, StreamServer}

  defp start_session(handler) do
    obs = self()
    conn = {:c, obs}

    {:ok, sess} =
      Session.start_link(
        transport: L2RecordingTransport,
        conn: conn,
        handler: handler,
        init_arg: obs
      )

    {sess, obs}
  end

  test "handler 処分: new_stream → handoff → StreamServer が echo を流し、demand が床へ、FIN で半閉じ" do
    {sess, obs} = start_session(L2EchoSession)
    stream = {:s, obs, 1}

    Kernel.send(sess, {:quic, :new_stream, {:c, obs}, stream, :bidi})

    # handoff の宛先（StreamServer の pid）を control 経由で知る
    assert_receive {:control, ^stream, pid}
    assert is_pid(pid)
    # init の demand が（handoff 後に）床の窓へ反映される ＝ AXIS 2
    assert_receive {:set_active, ^stream, :once}

    # 床が control 後に live を pid へ直送した、として注入
    Kernel.send(pid, {:quic, :data, stream, "hi", fin: false})
    assert_receive {:sent, ^stream, "hi", _opts}
    # handle_in の返した demand も床へ
    assert_receive {:set_active, ^stream, :once}

    # FIN（空データ + fin）で handle_fin → close_write
    Kernel.send(pid, {:quic, :data, stream, "", fin: true})
    assert_receive {:shutdown, ^stream, :write}
  end

  test "inline 処分: FIN まで貯めて一塊で handle_inline_stream に届く" do
    {sess, obs} = start_session(L2InlineSession)
    stream = {:s, obs, 2}

    Kernel.send(sess, {:quic, :new_stream, {:c, obs}, stream, :uni})
    Kernel.send(sess, {:quic, :data, stream, "he", fin: false})
    Kernel.send(sess, {:quic, :data, stream, "llo", fin: true})

    assert_receive {:inline_done, "hello"}
  end

  test "inline 処分: max 超過は FIN を待たず reset" do
    {sess, obs} = start_session(L2InlineSession)
    stream = {:s, obs, 3}

    Kernel.send(sess, {:quic, :new_stream, {:c, obs}, stream, :uni})
    Kernel.send(sess, {:quic, :data, stream, "123456789", fin: false})

    assert_receive {:shutdown, ^stream, {:reset, 0}}
    refute_received {:inline_done, _}
  end

  test "reset 処分: 要らないストリームはそのまま reset" do
    {sess, obs} = start_session(L2RejectSession)
    stream = {:s, obs, 4}

    Kernel.send(sess, {:quic, :new_stream, {:c, obs}, stream, :bidi})
    assert_receive {:shutdown, ^stream, {:reset, 7}}
  end

  test "ストリームハンドラのクラッシュはそのストリームだけ reset、セッションは生きる" do
    {sess, obs} = start_session(L2CrashSession)
    stream = {:s, obs, 1}

    Kernel.send(sess, {:quic, :new_stream, {:c, obs}, stream, :bidi})
    assert_receive {:control, ^stream, pid}

    # live data → handle_in が raise → StreamServer crash → Session がそのストリームを reset
    Kernel.send(pid, {:quic, :data, stream, "x", fin: false})
    assert_receive {:shutdown, ^stream, {:reset, 0}}

    # セッションは生きていて、別のストリームをまだ受けられる
    stream2 = {:s, obs, 5}
    Kernel.send(sess, {:quic, :new_stream, {:c, obs}, stream2, :bidi})
    assert_receive {:control, ^stream2, _pid2}
    assert Process.alive?(sess)
  end

  test "datagram は制御面の handle_datagram へ（軸の外）" do
    {sess, obs} = start_session(L2EchoSession)
    Kernel.send(sess, {:quic, :datagram, {:c, obs}, "ping"})
    assert_receive {:session_datagram, "ping"}
  end

  test "StreamServer 単体: handoff 完了後に init の demand で active 化（active 化は最後）" do
    obs = self()
    stream = {:s, obs, 9}

    {:ok, pid} =
      StreamServer.start_link(
        transport: L2RecordingTransport,
        stream: stream,
        handler: L2EchoStream,
        init_arg: obs
      )

    # 手渡し（competing window を閉じる約束。先着分の検証は handoff_test.exs）
    :ok = Karutte.WebTransport.Handoff.complete(stream, pid)

    # handoff 完了後に init の demand で active 化される（active 化は最後）
    assert_receive {:set_active, ^stream, :once}
  end
end
