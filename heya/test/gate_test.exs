defmodule Heya.GateTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn

  setup do
    System.put_env("HEYA_SECRET", "test-secret-test-secret-test-secret")
    System.put_env("HEYA_OAUTH_CLIENT_ID", "x"); System.put_env("HEYA_OAUTH_CLIENT_SECRET", "y")
    :ok
  end

  test "門: 開けると入れて、閉じると入れない、期限が切れても入れない" do
    refute Heya.Gate.open?("g1")
    Heya.Gate.open("g1"); assert Heya.Gate.open?("g1")
    Heya.Gate.close("g1"); refute Heya.Gate.open?("g1")
    Heya.Gate.open("g2", 0); refute Heya.Gate.open?("g2")
  end

  test "WT の門番: 閉じた部屋は 403、開いた部屋は入れる" do
    assert {:reject, 403} = Heya.WT.authorize(%{path: "/g3?name=a"})
    Heya.Gate.open("g3")
    assert :ok = Heya.WT.authorize(%{path: "/g3?name=a"})
    assert {:reject, 404} = Heya.WT.authorize(%{path: "/"})
  end

  test "振り分け: /wt は橋(Karutte.Bridge)、それ以外は部屋(Heya.WT)" do
    assert {Karutte.Bridge, nil} = Heya.Application.route(%{path: "/wt?ticket=nope"})
    assert {Heya.WT, nil} = Heya.Application.route(%{path: "/g3?name=a"})
    # 橋の門番はそのまま効く(にせのチケットは 401)
    assert {:reject, 401} = Karutte.Bridge.authorize(%{path: "/wt?ticket=nope"})
  end

  test "ページ: 閉じていればログインの案内、cookie が admin なら「開く」、開けば部屋" do
    conn = conn(:get, "/g4") |> Heya.Web.call([])
    assert conn.status == 200 and conn.resp_body =~ "まだ開いていません"
    # admin の cookie
    conn = conn(:get, "/g4") |> put_req_cookie("heya_admin", Heya.Auth.sign("nyanrus")) |> Heya.Web.call([])
    assert conn.resp_body =~ "この部屋を 12 時間開く"
    # にせの cookie は効かない
    conn = conn(:get, "/g4") |> put_req_cookie("heya_admin", "garbage") |> Heya.Web.call([])
    refute conn.resp_body =~ "12 時間"
    # 開く(admin だけ)
    conn = conn(:post, "/g4/open") |> Heya.Web.call([])
    assert conn.status == 403
    conn = conn(:post, "/g4/open") |> put_req_cookie("heya_admin", Heya.Auth.sign("nyanrus")) |> Heya.Web.call([])
    assert conn.status == 302 and Heya.Gate.open?("g4")
    conn = conn(:get, "/g4") |> Heya.Web.call([])
    assert conn.resp_body =~ "WebTransport" and conn.resp_body =~ "g4"
  end

  test "auth: state cookie が無い callback は断る、/auth は sukhi へ飛ばす" do
    conn = conn(:get, "/auth?room=g5") |> Heya.Web.call([])
    assert conn.status == 302
    assert get_resp_header(conn, "location") |> hd() =~ "sukhi.f3liz.casa/oauth/authorize"
    assert get_resp_header(conn, "location") |> hd() =~ "scope=read%3Aaccounts"
    conn = conn(:get, "/auth/callback?code=c&state=zz.g5") |> Heya.Web.call([])
    assert conn.status == 400
  end
end
