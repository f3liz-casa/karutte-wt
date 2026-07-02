defmodule WtRelay.MixProject do
  use Mix.Project

  def project do
    [
      app: :wt_relay,
      version: "0.0.1",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "wt-relay",
      description:
        "A gentle control plane for a transparent L4 (WireGuard) relay. It reconciles kernel " <>
          "netfilter/wg state to a declared spec and emits telemetry — while the data plane stays " <>
          "in the kernel, so the daemon can die and traffic keeps flowing."
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {WtRelay.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # telemetry イベントだけ。PromEx への配線は origin(karutte) と束ねる段で足す。
      {:telemetry, "~> 1.2"}
    ]
  end
end
