defmodule WtRelay.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:wt_relay, :enabled, true) do
        # NATS が設定されていれば、その接続(:gnat)を先に立てる ＝ Observer が
        # snapshot を publish できる。未設定なら接続せず、Observer の publish は no-op。
        nats_children() ++
          [
            {WtRelay.Reconciler, Application.get_env(:wt_relay, :reconciler, [])},
            {WtRelay.Observer, Application.get_env(:wt_relay, :observer, [])}
          ]
      else
        # dev/test では daemon を起こさない（カーネルを触らせない）。
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: WtRelay.Supervisor)
  end

  # `WT_RELAY_NATS_HOST` があれば sukhi と同型の自動再接続つき接続を :gnat で。
  defp nats_children do
    case System.get_env("WT_RELAY_NATS_HOST") do
      host when is_binary(host) and host != "" ->
        port = String.to_integer(System.get_env("WT_RELAY_NATS_PORT", "4222"))

        [
          {Gnat.ConnectionSupervisor,
           %{name: :gnat, connection_settings: [%{host: String.to_charlist(host), port: port}]}}
        ]

      _ ->
        []
    end
  end
end
