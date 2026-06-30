defmodule Karutte.MixProject do
  use Mix.Project

  def project do
    [
      app: :karutte_wt,
      version: "0.0.1",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "karutte-wt",
      description:
        "A layered behaviour sketch for WebTransport on the BEAM, with verified fragments."
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # まだ依存ゼロ。L1 を quicer に接ぐとき :quicer がここに入る。
  defp deps, do: []
end
