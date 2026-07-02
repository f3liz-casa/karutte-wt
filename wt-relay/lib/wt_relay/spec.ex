defmodule WtRelay.Spec do
  @moduledoc """
  望ましい状態（routes）を宣言から読む。Reconciler は毎 tick これを読み直すので、
  設定を変えて置くだけで daemon が収束する（= 宣言的）。

  当面はアプリ設定 `:wt_relay, :routes` から。将来 JSON/TOML ファイルや制御 API に
  差し替えられるよう、読み口をここ一箇所に閉じてある。
  """
  alias WtRelay.Route

  @spec routes() :: [Route.t()]
  def routes do
    Application.get_env(:wt_relay, :routes, [])
    |> Enum.map(&to_route/1)
  end

  defp to_route(%Route{} = r), do: r
  defp to_route(m) when is_map(m), do: struct!(Route, m)
end
