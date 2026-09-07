defmodule Heya.Room do
  @moduledoc """
  部屋ひとつ。だれが居るかと、声の配りかただけ。バイトの中身は見ない。

  参加者は pid で居る。声が来たら、送った本人以外の pid に `{:heya, <<id, pcm>>}` を送る。
  自分の声が自分に戻らないのが、この部屋のいちばん大事なところ(エコーの消し合いが要らない)。

  背圧: 受け手のメールボックスに声が溜まりすぎていたら(遅い回線・止まった koe)、その人の分は
  落とす。声は best-effort で、遅れて届く一秒前の声に意味は無い。制御(join/leave/名簿)は落とさない。
  """
  use GenServer

  # 受け手の未処理メッセージがこれを超えたら、その人には声を送らない(50 枠 = 一秒ぶん)。
  @max_backlog 50

  defstruct name: nil, members: %{}, next: 1, count: %{}

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

  @impl GenServer
  def init(name) do
    Process.send_after(self(), :roster, 3_000)
    {:ok, %__MODULE__{name: name}}
  end

  @impl GenServer
  def handle_call({:join, who, pid}, _from, s) do
    id = s.next
    Process.monitor(pid)
    members = Map.put(s.members, id, %{name: who, pid: pid})
    tell(members, id, control(%{join: %{id: id, name: who}}))
    roster = for {i, m} <- members, do: %{id: i, name: m.name}
    {:reply, {:ok, id, roster}, %{s | members: members, next: next_id(s.next, members)}}
  end

  def handle_call(:members, _from, s), do: {:reply, for({i, m} <- s.members, do: %{id: i, name: m.name}), s}

  @impl GenServer
  def handle_cast({:frame, id, pcm}, s) do
    tell(s.members, id, <<id::8, pcm::binary>>, &ready?/1)
    {:noreply, %{s | count: Map.update(s.count, id, 1, &(&1 + 1))}}
  end

  def handle_cast({:leave, id}, s), do: after_drop(drop(s, id))

  # 名簿は datagram で運ぶので落ちることがある。数秒おきに配り直す(小さいので気にならない)
  @impl GenServer
  def handle_info(:roster, s) do
    roster = for {i, m} <- s.members, do: %{id: i, name: m.name}
    for {i, m} <- s.members, do: send(m.pid, {:heya, control(%{you: i, members: roster})})
    Process.send_after(self(), :roster, 3_000)
    if System.get_env("HEYA_DEBUG") == "1" and map_size(s.count) > 0 do
      require Logger
      Logger.info("heya/room #{s.name} 3秒で受けた枠: " <> Enum.map_join(s.count, " ", fn {i, n} -> "#{Map.get(s.members, i, %{name: "?"}).name}=#{n}" end))
    end
    {:noreply, %{s | count: %{}}}
  end

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

  defp tell(members, from, bin, ok? \\ fn _ -> true end),
    do: for({i, m} <- members, i != from, ok?.(m.pid), do: send(m.pid, {:heya, bin}))

  defp ready?(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} -> n <= @max_backlog
      nil -> false
    end
  end
  defp control(map), do: <<0::8, Jason.encode!(map)::binary>>
  defp next_id(n, members), do: Enum.find((n + 1)..250, fn i -> not Map.has_key?(members, i) end) || 1
end
