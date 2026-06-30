defmodule Karutte.Http3.Server do
  @moduledoc """
  WebTransport over HTTP/3 のリスナ。quicer の上に薄く乗るだけ。

  `start_link/1` で UDP ポートを開き、acceptor を回す。接続が来るたびに
  `Karutte.Http3.Connection` を起こして所有を移し、H3 を立ち上げる。

  opts:
    * `:port`        — UDP ポート（必須）
    * `:certfile`    — PEM 証明書（必須。自己署名は `Karutte.Http3.Cert.generate/2`）
    * `:keyfile`     — PEM 秘密鍵（必須）
    * `:handler`     — `Karutte.WebTransport` を満たすモジュール（必須）
    * `:handler_arg` — handler.init/2 の第一引数（既定 nil）
    * `:acceptors`   — 同時 accept 数（既定 2）
    * `:alpn`        — 既定 ['h3']

  例:

      {:ok, cert} = Karutte.Http3.Cert.generate("priv/cert")
      {:ok, _} = Karutte.Http3.Server.start_link(
        port: 4433, certfile: cert.certfile, keyfile: cert.keyfile,
        handler: Karutte.Http3.Echo)
  """

  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl true
  def init(opts) do
    Application.ensure_all_started(:quicer)
    port = Keyword.fetch!(opts, :port)

    listen_opts = [
      # quicer は Erlang なのでパスは charlist で渡す（binary だと :quic_tls）。
      {:certfile, to_charlist(Keyword.fetch!(opts, :certfile))},
      {:keyfile, to_charlist(Keyword.fetch!(opts, :keyfile))},
      {:alpn, Keyword.get(opts, :alpn, [~c"h3"])},
      {:peer_bidi_stream_count, 256},
      {:peer_unidi_stream_count, 256},
      {:datagram_send_enabled, 1},
      {:datagram_receive_enabled, 1},
      {:idle_timeout_ms, 30_000}
    ]

    case :quicer.listen(port, listen_opts) do
      {:ok, listener} ->
        config = %{
          handler: Keyword.fetch!(opts, :handler),
          handler_arg: Keyword.get(opts, :handler_arg)
        }

        n = Keyword.get(opts, :acceptors, 2)
        for _ <- 1..n, do: spawn_acceptor(listener, config)
        Logger.info("Karutte.Http3.Server listening on udp/#{port}")
        {:ok, %{listener: listener, config: config}}

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{listener: listener}) do
    :quicer.close_listener(listener)
    :ok
  end

  defp spawn_acceptor(listener, config) do
    parent = self()
    spawn_link(fn -> accept_loop(listener, config, parent) end)
  end

  defp accept_loop(listener, config, parent) do
    case :quicer.accept(listener, [], :infinity) do
      {:ok, conn} ->
        case :quicer.handshake(conn) do
          {:ok, conn} ->
            {:ok, pid} =
              Karutte.Http3.Connection.start(
                qconn: conn,
                handler: config.handler,
                handler_arg: config.handler_arg
              )

            :quicer.controlling_process(conn, pid)
            Karutte.Http3.Connection.setup(pid)

          {:error, reason} ->
            Logger.debug("handshake 失敗: #{inspect(reason)}")
        end

        accept_loop(listener, config, parent)

      {:error, reason} ->
        Logger.debug("accept 失敗: #{inspect(reason)}")
        accept_loop(listener, config, parent)
    end
  end
end
