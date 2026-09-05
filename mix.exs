defmodule Karutte.MixProject do
  use Mix.Project

  def project do
    [
      app: :karutte_wt,
      version: "0.0.1",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "karutte-core",
      source_url: "https://github.com/f3liz-casa/karutte-core",
      docs: [
        main: "readme",
        extras: ["README.md", "docs/design.md", "docs/research-notes.md", "docs/references.md"],
        groups_for_modules: [
          Server: [Karutte.Http3.Server, Karutte.Http3.Cert, Karutte.Http3.Echo, Karutte.Http3.Echo.Stream],
          Behaviours: [Karutte.WebTransport, Karutte.WebTransport.Stream, Karutte.QuicTransport],
          Runners: [Karutte.WebTransport.Session, Karutte.WebTransport.StreamServer, Karutte.WebTransport.Handoff],
          Transports: [Karutte.QuicTransport.Http3, Karutte.QuicTransport.Quicer, Karutte.QuicTransport.Http2],
          Wire: [Karutte.Varint, Karutte.Capsule, Karutte.Inline],
          Internals: [Karutte.Http3.Connection, Karutte.Http3.Listener, Karutte.Http3.Acceptor, Karutte.WebTransportAdapter]
        ]
      ],
      description:
        "WebTransport over HTTP/3 for Elixir, on quicer and cowlib. Layered behaviours, one process per stream, works with real browsers."
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # The real L1 (msquic NIF). Building it needs a cmake / ninja / OpenSSL toolchain.
      {:quicer, "~> 0.1"},
      # The heavy parts of HTTP/3 and QPACK (frame parsing, Huffman, static tables) are left
      # to cowlib. karutte only writes the WebTransport-specific parts (Extended CONNECT,
      # WT framing, datagrams, runner wiring).
      {:cowlib, "~> 2.17"},
      # Observability (connection / session / datagram-drop events).
      {:telemetry, "~> 1.2"},
      # The L2 seam: to ride Plug.Conn.upgrade_adapter/3 (the same escape hatch WebSock uses).
      {:plug, "~> 1.16"},
      # Docs only.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
