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

  defp deps do
    [
      # L1 の本物の床（msquic NIF）。ビルドに cmake / OpenSSL などのツールチェーンが要る。
      # prod 限定にしてある: test/dev は NIF を踏まず緑のまま回せる（Quicer モジュールは
      # apply/3 + Code.ensure_loaded? ガードで quicer 不在でもコンパイルできる）。本物に
      # 接ぐときは MIX_ENV=prod でビルド（要 cmake）。
      {:quicer, "~> 0.1", only: :prod},
      # L2 の縫い目。Plug.Conn.upgrade_adapter/3（WebSock と同じ脱出口）に乗るため。
      {:plug, "~> 1.16"}
    ]
  end
end
