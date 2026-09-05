defmodule Heya.Gate do
  @moduledoc """
  門。部屋は、sukhi-fedi の admin が「開く」と言ったあいだだけ入れる。
  開いた部屋の名前と期限を ETS に持つだけ(再起動で閉じる。それでいい)。
  """
  use GenServer

  @hours 12

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def open(room, hours \\ @hours), do: :ets.insert(__MODULE__, {room, System.system_time(:second) + hours * 3600})
  def close(room), do: :ets.delete(__MODULE__, room)

  def open?(room) do
    case :ets.lookup(__MODULE__, room) do
      [{^room, until}] -> until > System.system_time(:second)
      [] -> false
    end
  end

  def until(room), do: (case :ets.lookup(__MODULE__, room) do [{^room, u}] -> u; [] -> nil end)

  @impl true
  def init(_), do: (:ets.new(__MODULE__, [:named_table, :public, read_concurrency: true]); {:ok, nil})
end
