defmodule Heya.Room do
  @moduledoc """
  部屋ひとつ。だれが居るかと、声の配りかただけ。バイトの中身は見ない。

  参加者は pid で居る。声が来たら、送った本人以外の pid に `{:heya, <<id, pcm>>}` を送る。
  自分の声が自分に戻らないのが、この部屋のいちばん大事なところ(エコーの消し合いが要らない)。
  """
  use GenServer

  defstruct name: nil, members: %{}, next: 1

  # --- 外から

  def ensure(name) do
    case Registry.lookup(Heya.Registry, name) do
      [{pid, _}] -> {:ok, pid}
      [] ->
        case DynamicSupervisor.start_child(Heya.Rooms, {__MODULE__, name}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
        end
    end
  end

  @doc "入る。返るのは自分の id と、いま居る人。"
  def join(name, who, pid \\ self()) do
    {:ok, room} = ensure(name)
    GenServer.call(room, {:join, who, pid})
  end

  def leave(name, id), do: with({:ok, room} <- lookup(name), do: GenServer.cast(room, {:leave, id}))

  @doc "声。本人以外に配る。"
  def frame(name, id, pcm), do: with({:ok, room} <- lookup(name), do: GenServer.cast(room, {:frame, id, pcm}))

  def members(name), do: with({:ok, room} <- lookup(name), do: GenServer.call(room, :members))

  defp lookup(name) do
    case Registry.lookup(Heya.Registry, name) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :no_room}
    end
  end

  # --- 中

  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: {:via, Registry, {Heya.Registry, name}})
  def child_spec(name), do: %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [name]}, restart: :transient}

  @impl true
  def init(name), do: {:ok, %__MODULE__{name: name}}

  @impl true
  def handle_call({:join, who, pid}, _from, s) do
    id = s.next
    Process.monitor(pid)
    members = Map.put(s.members, id, %{name: who, pid: pid})
    tell(members, id, control(%{join: %{id: id, name: who}}))
    roster = for {i, m} <- members, do: %{id: i, name: m.name}
    {:reply, {:ok, id, roster}, %{s | members: members, next: next_id(s.next, members)}}
  end

  def handle_call(:members, _from, s), do: {:reply, for({i, m} <- s.members, do: %{id: i, name: m.name}), s}

  @impl true
  def handle_cast({:frame, id, pcm}, s) do
    tell(s.members, id, <<id::8, pcm::binary>>)
    {:noreply, s}
  end

  def handle_cast({:leave, id}, s), do: after_drop(drop(s, id))

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, s) do
    case Enum.find(s.members, fn {_, m} -> m.pid == pid end) do
      {id, _} -> after_drop(drop(s, id))
      nil -> {:noreply, s}
    end
  end

  defp drop(s, id) do
    members = Map.delete(s.members, id)
    tell(members, id, control(%{leave: id}))
    %{s | members: members}
  end

  # だれも居なくなったら部屋も消える
  defp after_drop(%{members: m} = s) when map_size(m) == 0, do: {:stop, :normal, s}
  defp after_drop(s), do: {:noreply, s}

  defp tell(members, from, bin), do: for({i, m} <- members, i != from, do: send(m.pid, {:heya, bin}))
  defp control(map), do: <<0::8, Jason.encode!(map)::binary>>
  defp next_id(n, members), do: Enum.find((n + 1)..250, fn i -> not Map.has_key?(members, i) end) || 1
end
