defmodule Karutte.TicketTest do
  use ExUnit.Case, async: true
  alias Karutte.Ticket

  setup do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    %{pub: pub, priv: priv}
  end

  defp mint(priv, claims) do
    b64p = claims |> :json.encode() |> IO.iodata_to_binary() |> Base.url_encode64(padding: false)
    sig = :crypto.sign(:eddsa, :none, b64p, [priv, :ed25519])
    b64p <> "." <> Base.url_encode64(sig, padding: false)
  end

  test "valid ticket verifies and returns claims", %{pub: pub, priv: priv} do
    t = mint(priv, %{"sub" => "42", "exp" => 9_999_999_999, "feeds" => ["local", "user"]})
    assert {:ok, %{sub: "42", exp: 9_999_999_999, feeds: ["local", "user"]}} = Ticket.verify(t, pub, 1000)
  end

  test "feeds defaults when omitted", %{pub: pub, priv: priv} do
    t = mint(priv, %{"sub" => "42", "exp" => 9_999_999_999})
    assert {:ok, %{feeds: ["local", "bubble", "user"]}} = Ticket.verify(t, pub, 1000)
  end

  test "expired ticket is rejected", %{pub: pub, priv: priv} do
    t = mint(priv, %{"sub" => "42", "exp" => 100})
    assert {:error, _} = Ticket.verify(t, pub, 1000)
  end

  test "tampered payload is rejected", %{pub: pub, priv: priv} do
    t = mint(priv, %{"sub" => "42", "exp" => 9_999_999_999})
    [_p, s] = String.split(t, ".")
    forged = Base.url_encode64(~s({"sub":"999","exp":9999999999}), padding: false) <> "." <> s
    assert {:error, _} = Ticket.verify(forged, pub, 1000)
  end

  test "wrong key is rejected", %{priv: priv} do
    {other_pub, _} = :crypto.generate_key(:eddsa, :ed25519)
    t = mint(priv, %{"sub" => "42", "exp" => 9_999_999_999})
    assert {:error, _} = Ticket.verify(t, other_pub, 1000)
  end

  test "garbage is rejected", %{pub: pub} do
    assert {:error, _} = Ticket.verify("not-a-token", pub, 1000)
  end
end
