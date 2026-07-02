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
      # telemetry イベント。
      {:telemetry, "~> 1.2"},
      # snapshot を NATS(`wt_relay.telemetry`)へ push して sukhi の admin に見せる用
      # （sukhi と同じ Gnat）。NATS 未設定なら接続しない＝観測は NATS 非依存のまま。
      {:gnat, "~> 1.9"}
    ]
  end
end
