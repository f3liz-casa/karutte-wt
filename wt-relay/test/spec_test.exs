defmodule WtRelay.SpecTest do
  use ExUnit.Case, async: false
  alias WtRelay.{Route, Spec}

  test "設定の map / %Route{} 両方を Route に正規化する" do
    Application.put_env(:wt_relay, :routes, [
      %{name: "a", proto: :udp, listen_port: 443, origin: "10.9.0.2:443"},
      %Route{name: "b", proto: :tcp, listen_port: 8443, origin: "10.9.0.2:8443", preserve_ip: false}
    ])

    on_exit(fn -> Application.delete_env(:wt_relay, :routes) end)

    assert [%Route{name: "a", preserve_ip: true}, %Route{name: "b", preserve_ip: false}] =
             Spec.routes()
  end
end
