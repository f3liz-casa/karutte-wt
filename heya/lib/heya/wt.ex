defmodule Heya.WT do
  @moduledoc """
  ブラウザの口。karutte の WebTransport ハンドラ。部屋のことだけ。
  `/<部屋>?name=<名前>` で入る。門が開いているときか、koe の合言葉(?token=)があるとき。datagram が声。

  `/wt…`(sukhi の橋)はここには来ない。`Heya.Application` が path で `Karutte.Bridge` に振り分けている。
  部屋から `{:heya, bin}` が来たら、そのまま datagram で返す。
  """
  @behaviour Karutte.WebTransport
  require Logger
  @impl true
  def authorize(%{path: path}) when is_binary(path) do
    # 門が開いているか、koe の合言葉(?token=)を持っているか
    case parse(path) do
      {:ok, room, _} -> if Heya.Gate.open?(room) or koe?(path), do: :ok, else: {:reject, 403}
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
    r = s.transport.send_datagram(s.conn, bin)
    s = count(s, r)
    {:ok, s}
  end

  # 出口で数える(HEYA_DEBUG=1)。datagram の送りが失敗しているなら、ここに出る
  defp count(s, r) do
    if System.get_env("HEYA_DEBUG") == "1" do
      c = Map.get(s, :count, %{ok: 0, err: 0, t: System.monotonic_time(:millisecond), errs: []})
      c = if r == :ok, do: %{c | ok: c.ok + 1}, else: %{c | err: c.err + 1, errs: Enum.take([r | c.errs], 3)}
      now = System.monotonic_time(:millisecond)
      c = if now - c.t >= 3000 do
        Logger.info("heya/wt #{s.who}: 3秒で datagram ok=#{c.ok} err=#{c.err} #{inspect(c.errs)}")
        %{ok: 0, err: 0, t: now, errs: []}
      else c end
      Map.put(s, :count, c)
    else s end
  end
  def handle_info(_msg, s), do: {:ok, s}

  @impl true
  def handle_datagram(_pcm, %{id: nil} = s), do: {:ok, s}
  def handle_datagram(pcm, s) do
    Heya.Room.frame(s.room, s.id, pcm)
    {:ok, count_in(s)}
  end

  # 入口でも数える(HEYA_DEBUG=1)。ブラウザ→箱の datagram が 50/s 来ているか
  defp count_in(s) do
    if System.get_env("HEYA_DEBUG") == "1" do
      c = Map.get(s, :count_in, %{n: 0, t: System.monotonic_time(:millisecond)})
      c = %{c | n: c.n + 1}
      now = System.monotonic_time(:millisecond)
      c = if now - c.t >= 3000 do
        Logger.info("heya/wt #{s.who}: 3秒で受けた datagram #{c.n}")
        %{n: 0, t: now}
      else c end
      Map.put(s, :count_in, c)
    else s end
  end

  # 部屋ではストリームは使わない(声は全部 datagram)
  @impl true
  def handle_stream(_stream, _dir, s), do: {{:reset, 0}, s}

  @impl true
  def handle_inline_stream(_stream, _bin, s), do: {:ok, s}

  @impl true
  def terminate(_reason, %{id: id, room: room}) when is_integer(id), do: Heya.Room.leave(room, id)
  def terminate(_reason, _s), do: :ok

  # koe は WebSocket でも WebTransport でも同じ合言葉で入る(HEYA_KOE_TOKEN)
  defp koe?(path), do: URI.parse(path).query |> then(&URI.decode_query(&1 || "")) |> Map.get("token") |> Heya.KoeSocket.allowed?()

  @doc "`/<部屋>?name=<名前>` を読む。名前が無ければ「だれか」。"
  def parse(nil), do: :error
  def parse(path) do
    uri = URI.parse(path)
    room = String.trim(uri.path || "", "/")
    name = (URI.decode_query(uri.query || "") |> Map.get("name") || "だれか") |> String.slice(0, 40)
    if room == "" or String.length(room) > 80 or String.contains?(room, "/"), do: :error, else: {:ok, room, name}
  end
end
