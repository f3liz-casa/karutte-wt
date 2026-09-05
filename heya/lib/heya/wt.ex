defmodule Heya.WT do
  @moduledoc """
  ブラウザの口。karutte の WebTransport ハンドラ。二つの顔を持つ:
    * `/wt…`     → sukhi の live タイムライン橋(`Karutte.Bridge`)にそのまま委ねる(いままでの karutte の仕事)
    * `/<部屋>`  → 部屋。門が開いているときだけ。datagram が声(640 バイトの PCM)。
  部屋から `{:heya, bin}` が来たら、そのまま datagram で返す。
  """
  @behaviour Karutte.WebTransport
  require Logger
  alias Karutte.Bridge

  defp bridge?(path), do: is_binary(path) and String.starts_with?(path, "/wt")

  @impl true
  def authorize(%{path: path} = ci) when is_binary(path) do
    cond do
      bridge?(path) -> Bridge.authorize(ci)
      true ->
        case parse(path) do
          {:ok, room, _} -> if Heya.Gate.open?(room), do: :ok, else: {:reject, 403}
          :error -> {:reject, 404}
        end
    end
  end
  def authorize(_), do: {:reject, 404}

  @impl true
  def init(arg, ci) do
    if bridge?(ci[:path]) do
      case Bridge.init(arg, ci) do
        {:ok, st} -> {:ok, {:bridge, st}}
        other -> other
      end
    else
      {:ok, room, name} = parse(ci[:path])
      {:ok, %{transport: ci.transport, conn: ci.conn, room: room, who: name, id: nil}}
    end
  end

  # セッションが立ってから入る(それより前は datagram を送れない)
  @impl true
  def handle_info(msg, {:bridge, st}), do: wrap(Bridge.handle_info(msg, st))
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
  def handle_datagram(bin, {:bridge, st}), do: (if function_exported?(Bridge, :handle_datagram, 2), do: wrap(apply(Bridge, :handle_datagram, [bin, st])), else: {:ok, {:bridge, st}})
  def handle_datagram(_pcm, %{id: nil} = s), do: {:ok, s}
  def handle_datagram(pcm, s) do
    Heya.Room.frame(s.room, s.id, pcm)
    {:ok, s}
  end

  # 部屋ではストリームは使わない(声は全部 datagram)
  @impl true
  def handle_stream(stream, dir, {:bridge, st}), do: (case Bridge.handle_stream(stream, dir, st) do {d, st2} -> {d, {:bridge, st2}} end)
  def handle_stream(_stream, _dir, s), do: {{:reset, 0}, s}

  @impl true
  def handle_inline_stream(stream, bin, {:bridge, st}), do: (if function_exported?(Bridge, :handle_inline_stream, 3), do: wrap(apply(Bridge, :handle_inline_stream, [stream, bin, st])), else: {:ok, {:bridge, st}})
  def handle_inline_stream(_stream, _bin, s), do: {:ok, s}

  @impl true
  def terminate(reason, {:bridge, st}), do: Bridge.terminate(reason, st)
  def terminate(_reason, %{id: id, room: room}) when is_integer(id), do: Heya.Room.leave(room, id)
  def terminate(_reason, _s), do: :ok

  defp wrap({:ok, st}), do: {:ok, {:bridge, st}}
  defp wrap({:stop, r, st}), do: {:stop, r, {:bridge, st}}

  @doc "`/<部屋>?name=<名前>` を読む。名前が無ければ「だれか」。"
  def parse(nil), do: :error
  def parse(path) do
    uri = URI.parse(path)
    room = String.trim(uri.path || "", "/")
    name = (URI.decode_query(uri.query || "") |> Map.get("name") || "だれか") |> String.slice(0, 40)
    if room == "" or String.length(room) > 80 or String.contains?(room, "/"), do: :error, else: {:ok, room, name}
  end
end
