defmodule WtRelay.CmdStub do
  @moduledoc "テスト用の床。呼ばれたコマンドをテストプロセスへ送り、既定は成功を返す。"
  @behaviour WtRelay.Kernel.Cmd

  @impl true
  def run(cmd, args) do
    if pid = Application.get_env(:wt_relay, :test_pid), do: send(pid, {:cmd, cmd, args})
    # 既定は成功（空出力）。ensure_jump の -C も成功扱い＝「jump は既にある」とみなす。
    {:ok, ""}
  end
end
