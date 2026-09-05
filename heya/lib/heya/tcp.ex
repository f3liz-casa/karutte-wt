defmodule Heya.Tcp do
  @moduledoc """
  koe の口。QUIC を持たない子のための、素の TCP(127.0.0.1 だけ)。
  枠は 2 バイト長さ前置き(`packet: 2`)。最初の一枠は `JOIN <部屋> <名前>`、あとは声(PCM)。
  こちらからは `<<id, pcm>>` と `<<0, json>>` を同じ枠で返す。
  """
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    {:ok, lsock} = :gen_tcp.listen(port, [:binary, packet: 2, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    Logger.info("heya: koe の口 127.0.0.1:#{port}")
    for _ <- 1..2, do: spawn_link(fn -> accept(lsock) end)
    {:ok, %{lsock: lsock}}
  end

  defp accept(lsock) do
    {:ok, sock} = :gen_tcp.accept(lsock)
    pid = spawn(fn -> serve(sock) end)
    :gen_tcp.controlling_process(sock, pid)
    send(pid, :go)
    accept(lsock)
  end

  defp serve(sock) do
    receive do: (:go -> :ok)
    with {:ok, "JOIN " <> rest} <- :gen_tcp.recv(sock, 0, 10_000),
         [room, who] <- String.split(rest, " ", parts: 2) do
      {:ok, id, roster} = Heya.Room.join(room, who)
      :gen_tcp.send(sock, <<0::8, Jason.encode!(%{you: id, members: roster})::binary>>)
      :inet.setopts(sock, active: true)
      Logger.info("heya: #{who} が #{room} に入った(#{id}、tcp)")
      loop(sock, room, id)
    else
      _ -> :gen_tcp.close(sock)
    end
  end

  defp loop(sock, room, id) do
    receive do
      {:tcp, ^sock, pcm} -> Heya.Room.frame(room, id, pcm); loop(sock, room, id)
      {:heya, bin} -> :gen_tcp.send(sock, bin); loop(sock, room, id)
      {:tcp_closed, ^sock} -> Heya.Room.leave(room, id)
      {:tcp_error, ^sock, _} -> Heya.Room.leave(room, id)
    end
  end
end
