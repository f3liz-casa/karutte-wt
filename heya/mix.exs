defmodule Heya.MixProject do
  use Mix.Project

  def project do
    [app: :heya, version: "0.1.0", elixir: "~> 1.17", start_permanent: Mix.env() == :prod, deps: deps(),
     # 箱では karutte:v1 の deps/_build を使い回す(msquic を焼き直さない)
     deps_path: System.get_env("HEYA_DEPS_PATH", "deps"),
     build_path: System.get_env("HEYA_BUILD_PATH", "_build")]
  end

  def application do
    [extra_applications: [:logger, :inets, :ssl], mod: {Heya.Application, []}]
  end

  defp deps do
    [
      # 部屋の床。WebTransport over HTTP/3 は karutte-core が全部持っている(モノレポの隣)
      # override: sukhi も同じ karutte_wt を(別の相対 path で)指すので、heya の指定を勝たせる
      {:karutte_wt, path: System.get_env("KARUTTE_PATH", "../core"), override: true},
      # sukhi の橋(Karutte.Bridge / Ticket)。gnat もここから来る
      {:karutte_sukhi, path: System.get_env("KARUTTE_SUKHI_PATH", "../sukhi")},
      # ページ(/<部屋>)を返すだけの HTTP
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:websock_adapter, "~> 0.5"},
      {:jason, "~> 1.4"}
    ]
  end
end
