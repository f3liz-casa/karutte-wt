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
      # L1 の本物の床（msquic NIF）。ビルドに cmake / ninja / OpenSSL のツールチェーンが要る。
      {:quicer, "~> 0.1"},
      # HTTP/3 と QPACK の重い所（フレーム解析・Huffman・静的表）は cowlib に任せる。
      # karutte-wt 側は WebTransport 固有の部分（Extended CONNECT / WT framing / datagram /
      # runner 配線）だけを書く。
      {:cowlib, "~> 2.17"},
      # L2 の縫い目。Plug.Conn.upgrade_adapter/3（WebSock と同じ脱出口）に乗るため。
      {:plug, "~> 1.16"}
    ]
  end
end
