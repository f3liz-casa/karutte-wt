defmodule KarutteSukhi.MixProject do
  use Mix.Project

  def project do
    [
      app: :karutte_sukhi,
      version: "0.0.1",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "karutte-sukhi",
      description:
        "sukhi の live タイムラインを WebTransport で配る karutte の応用（Ticket + NATS Bridge）。"
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # The WebTransport server itself. Lives next door in the monorepo.
      {:karutte_wt, path: "../core"},
      # sukhi の出す event を受ける NATS クライアント（sukhi と同じ Gnat）。
      {:gnat, "~> 1.9"}
    ]
  end
end
