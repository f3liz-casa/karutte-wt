defmodule WtRelay.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:wt_relay, :enabled, true) do
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
end
