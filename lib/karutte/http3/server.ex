defmodule Karutte.Http3.Server do
  @moduledoc """
  WebTransport over HTTP/3 のサーバ。監視ツリーひと組。

      Karutte.Http3.Server (Supervisor)
      ├── Karutte.Http3.Listener        … UDP ポートを開けっ放しにする番人
      ├── ConnectionSup (DynamicSupervisor) … 接続ごとの Connection（temporary）
      └── Karutte.Http3.Acceptor × N    … 受け付け（permanent、落ちたら再起動）

  接続一つの事故は ConnectionSup の中で閉じ、acceptor が落ちても再起動して受け付けは
  続く。リスナはツリーの寿命と一致して開閉する。`child_spec/1` を持つので、ふつうに
  自分のアプリの supervision tree に子として挿せる。

  opts:
    * `:port`        — UDP ポート（必須）
    * `:certfile`    — PEM 証明書（必須。自己署名は `Karutte.Http3.Cert.generate/2`）
    * `:keyfile`     — PEM 秘密鍵（必須）
    * `:handler`     — `Karutte.WebTransport` を満たすモジュール（必須）
    * `:handler_arg` — handler.init/2 の第一引数（既定 nil）
    * `:acceptors`   — 同時 accept 数（既定 4）
    * `:name`        — このサーバの登録名のベース（既定 `Karutte.Http3.Server`）
    * `:max_sessions`           — 1 接続あたりの WT セッション上限（既定 16）
    * `:idle_timeout_ms`        — 既定 30_000
    * `:peer_bidi_stream_count` / `:peer_unidi_stream_count` — 既定 256

  例:

      {:ok, cert} = Karutte.Http3.Cert.generate("priv/cert")
      {:ok, _} = Karutte.Http3.Server.start_link(
        port: 4433, certfile: cert.certfile, keyfile: cert.keyfile,
        handler: Karutte.Http3.Echo)
  """

  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    listener_name = Module.concat(name, "Listener")
    conn_sup = Module.concat(name, "ConnectionSup")

    config = %{
      handler: Keyword.fetch!(opts, :handler),
      handler_arg: Keyword.get(opts, :handler_arg),
      max_sessions: Keyword.get(opts, :max_sessions, 16)
    }

    n = Keyword.get(opts, :acceptors, 4)

    listener_opts =
      opts
      |> Keyword.take([:port, :certfile, :keyfile, :alpn, :idle_timeout_ms, :peer_bidi_stream_count, :peer_unidi_stream_count])
      |> Keyword.put(:name, listener_name)

    acceptors =
      for i <- 1..n do
        {Karutte.Http3.Acceptor,
         [
           id: i,
           listener: listener_name,
           conn_sup: conn_sup,
           handler: config.handler,
           handler_arg: config.handler_arg,
           max_sessions: config.max_sessions
         ]}
      end

    children =
      [
        {Karutte.Http3.Listener, listener_opts},
        {DynamicSupervisor, name: conn_sup, strategy: :one_for_one}
      ] ++ acceptors

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
