defmodule Karutte.BridgeTest do
  use ExUnit.Case, async: false
  alias Karutte.Bridge

  defmodule FakeTransport do
    def open_stream(_conn, :uni), do: {:ok, make_ref()}

    def send(stream, iodata) do
      if pid = Application.get_env(:karutte_wt, :test_pid),
        do: Kernel.send(pid, {:sent, stream, IO.iodata_to_binary(iodata)})

      :ok
    end
  end

  setup do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    Application.put_env(:karutte_wt, :ticket_pubkey, pub)
    Application.put_env(:karutte_wt, :test_pid, self())

    on_exit(fn ->
      Application.delete_env(:karutte_wt, :ticket_pubkey)
      Application.delete_env(:karutte_wt, :test_pid)
    end)

    %{priv: priv}
  end

  defp path(priv, claims) do
    b64p = claims |> :json.encode() |> IO.iodata_to_binary() |> Base.url_encode64(padding: false)
    sig = :crypto.sign(:eddsa, :none, b64p, [priv, :ed25519])
    "/wt?ticket=" <> b64p <> "." <> Base.url_encode64(sig, padding: false)
  end

  test "subject_for maps feeds to subjects" do
    assert Bridge.subject_for("local", "42") == "stream.local"
    assert Bridge.subject_for("bubble", "42") == "stream.bubble"
    assert Bridge.subject_for("user", "42") == "stream.user.42"
    assert Bridge.subject_for("nope", "42") == nil
  end

  test "authorize accepts a valid ticket, rejects junk", %{priv: priv} do
    assert Bridge.authorize(%{path: path(priv, %{"sub" => "42", "exp" => 9_999_999_999})}) == :ok
    assert {:reject, 401} = Bridge.authorize(%{path: "/wt?ticket=garbage"})
    assert {:reject, 401} = Bridge.authorize(%{path: "/wt"})
  end

  test "init stores claims from the ticket", %{priv: priv} do
    ci = %{
      path: path(priv, %{"sub" => "7", "exp" => 9_999_999_999, "feeds" => ["local", "user"]}),
      transport: FakeTransport,
      conn: :c
    }

    assert {:ok, st} = Bridge.init(nil, ci)
    assert st.claims.sub == "7"
    assert st.claims.feeds == ["local", "user"]
  end

  test "init stops on an unauthorized ticket" do
    assert {:stop, {:unauthorized, _}} = Bridge.init(nil, %{path: "/wt?ticket=nope", transport: FakeTransport, conn: :c})
  end

  test "a NATS message is written to its feed's stream" do
    st = %{transport: FakeTransport, streams: %{"stream.local" => :s_local}}
    assert {:ok, ^st} = Bridge.handle_info({:msg, %{topic: "stream.local", body: ~s({"id":1})}}, st)
    assert_received {:sent, :s_local, ~s({"id":1}\n)}
  end

  test "a NATS message for an unknown subject is ignored" do
    st = %{transport: FakeTransport, streams: %{}}
    assert {:ok, ^st} = Bridge.handle_info({:msg, %{topic: "stream.x", body: "z"}}, st)
    refute_received {:sent, _, _}
  end
end
