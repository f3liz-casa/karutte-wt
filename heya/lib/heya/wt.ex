defmodule Heya.WT do
  @moduledoc """
  ブラウザの口。karutte の WebTransport ハンドラ。部屋のことだけ。
  `/<部屋>?name=<名前>` で入る。門が開いているときだけ。datagram が声(640 バイトの PCM)。
  部屋から `{:heya, bin}` が来たら、そのまま datagram で返す。

  `/wt…`(sukhi の橋)はここには来ない。`Heya.Application` が path で `Karutte.Bridge` に振り分けている。
  """
  @behaviour Karutte.WebTransport
  require Logger

  @impl true
  def authorize(%{path: path}) when is_binary(path) do
    case parse(path) do
      {:ok, room, _} -> if Heya.Gate.open?(room), do: :ok, else: {:reject, 403}
      :error -> {:reject, 404}
    end
  end
  def authorize(_), do: {:reject, 404}

  @impl true
  def init(_arg, ci) do
    {:ok, room, name} = parse(ci[:path])
    {:ok, %{transport: ci.transport, conn: ci.conn, room: room, who: name, id: nil}}
  end

  # セッションが立ってから入る(それより前は datagram を送れない)
  @impl true
  def handle_info(:wt_ready, s) do
    {:ok, id, roster} = Heya.Room.join(s.room, s.who)
    s.transport.send_datagram(s.conn, <<0::8, Jason.encode!(%{you: id, members: roster})::binary>>)
    Logger.info("heya: #{s.who} が #{s.room} に入った(#{id})")
    {:ok, %{s | id: id}}
  end
  def handle_info({:heya, bin}, s) do
    s.transport.send_datagram(s.conn, bin)
    {:ok, s}
  end
  def handle_info(_msg, s), do: {:ok, s}

  @impl true
  def handle_datagram(_pcm, %{id: nil} = s), do: {:ok, s}
  def handle_datagram(pcm, s) do
    Heya.Room.frame(s.room, s.id, pcm)
    {:ok, s}
  end

  # 部屋ではストリームは使わない(声は全部 datagram)
  @impl true
  def handle_stream(_stream, _dir, s), do: {{:reset, 0}, s}

  @impl true
  def terminate(_reason, %{id: id, room: room}) when is_integer(id), do: Heya.Room.leave(room, id)
  def terminate(_reason, _s), do: :ok

  @doc "`/<部屋>?name=<名前>` を読む。名前が無ければ「だれか」。"
  def parse(nil), do: :error
  def parse(path) do
    uri = URI.parse(path)
    room = String.trim(uri.path || "", "/")
    name = (URI.decode_query(uri.query || "") |> Map.get("name") || "だれか") |> String.slice(0, 40)
    if room == "" or String.length(room) > 80 or String.contains?(room, "/"), do: :error, else: {:ok, room, name}
  end
end
