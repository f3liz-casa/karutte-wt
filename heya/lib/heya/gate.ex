defmodule Heya.Gate do
  @moduledoc """
  門。部屋は、sukhi-fedi の admin が「開く」と言ったあいだだけ入れる。
  開いた部屋の名前と期限を ETS に持ち、state/gate.json にも書く(出し直しても閉じないように)。
  """
  use GenServer

  @hours 12
  @path Path.join([Path.expand("..", __DIR__ |> Path.dirname()), "state", "gate.json"])

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def open(room, hours \\ @hours) do
    :ets.insert(__MODULE__, {room, System.system_time(:second) + hours * 3600})
    save()
  end

  def close(room) do
    :ets.delete(__MODULE__, room)
    save()
  end

  def open?(room) do
    case :ets.lookup(__MODULE__, room) do
      [{^room, until}] -> until > System.system_time(:second)
      [] -> false
    end
  end

  def until(room), do: (case :ets.lookup(__MODULE__, room) do [{^room, u}] -> u; [] -> nil end)

  def file, do: System.get_env("HEYA_GATE_FILE", @path)

  @impl true
  def init(_) do
    :ets.new(__MODULE__, [:named_table, :public, read_concurrency: true])
    load()
    {:ok, nil}
  end

  defp save do
    now = System.system_time(:second)
    rooms = for {room, until} <- :ets.tab2list(__MODULE__), until > now, into: %{}, do: {room, until}
    File.mkdir_p!(Path.dirname(file()))
    File.write!(file(), Jason.encode!(rooms))
    true
  end

  defp load do
    with {:ok, bin} <- File.read(file()), {:ok, rooms} <- Jason.decode(bin) do
      for {room, until} <- rooms, is_integer(until), do: :ets.insert(__MODULE__, {room, until})
    end
    :ok
  end
end
