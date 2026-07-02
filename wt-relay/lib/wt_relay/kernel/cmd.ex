defmodule WtRelay.Kernel.Cmd do
  @moduledoc """
  外の世界(iptables / wg / ip)を叩く縫い目。テストで差し替えられるよう behaviour に
  してある（karutte-wt の L1 差し替え口と同じ発想）。実物は `System.cmd` に委譲。
  """
  @callback run(binary(), [binary()]) :: {:ok, binary()} | {:error, {integer(), binary()}}

  @doc "使う実装。既定は本物。テストは `:wt_relay, :cmd` で差し替える。"
  def impl, do: Application.get_env(:wt_relay, :cmd, __MODULE__.System)

  defmodule System do
    @moduledoc "本物の床。stderr も拾って exit code で成否を返す。"
    @behaviour WtRelay.Kernel.Cmd

    @impl true
    def run(cmd, args) do
      case Elixir.System.cmd(cmd, args, stderr_to_stdout: true) do
        {out, 0} -> {:ok, out}
        {out, code} -> {:error, {code, out}}
      end
    end
  end
end
