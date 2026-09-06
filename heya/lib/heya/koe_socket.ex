defmodule Heya.KoeSocket do
  @moduledoc """
  koe の口(遠くから)。`wss://<heya>/koe/<部屋>?name=<名前>` に、合言葉(HEYA_KOE_TOKEN)を持って来る。
  枠は TCP の口と同じ: こちらへは声(PCM)の binary、あちらへは `<<id, pcm>>` と `<<0, json>>`。
  """
  @behaviour WebSock
  require Logger

  @impl true
  def init(%{room: room, who: who}) do
    {:ok, id, roster} = Heya.Room.join(room, who)
    Logger.info("heya: #{who} が #{room} に入った(#{id}、ws)")
    {:push, {:binary, <<0::8, Jason.encode!(%{you: id, members: roster})::binary>>}, %{room: room, id: id}}
  end

  @impl true
  def handle_in({pcm, [opcode: :binary]}, st) do
    Heya.Room.frame(st.room, st.id, pcm)
    {:ok, st}
  end
  def handle_in(_, st), do: {:ok, st}

  @impl true
  def handle_info({:heya, bin}, st), do: {:push, {:binary, bin}, st}
  def handle_info(_, st), do: {:ok, st}

  @impl true
  def terminate(_reason, st), do: Heya.Room.leave(st.room, st.id)

  @doc "合言葉が合うか。無設定なら誰も通さない。"
  def allowed?(token) do
    want = System.get_env("HEYA_KOE_TOKEN", "")
    want != "" and is_binary(token) and Plug.Crypto.secure_compare(token, want)
  end
end
