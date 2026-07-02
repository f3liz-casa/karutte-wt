defmodule Karutte.Bridge do
  @moduledoc """
  sukhi の event を WebTransport に橋渡しするハンドラ。**feed = NATS subject = WT uni-stream**。

  一本の WT 接続に feed ごとの独立したストリームを開く（RFC の multi-stream）。騒がしい feed
  （ローカル）が静かな feed（通知）を頭で止めない＝独立 flow control。sukhi が subject に一回
  publish すれば、共有 feed（local/bubble）は全接続へ安く配れる。

  流れ:
    1. `authorize/1` — path の `?ticket=` を Ed25519 で検証（[[Karutte.Ticket]]）。暗号の直後に安く弾く。
    2. `init/2`      — 再検証して claims（sub, feeds）を得る。
    3. `:wt_ready`   — feed ごとに NATS を sub し、uni-stream を開く。
    4. NATS `{:msg,…}`— 該当 feed のストリームへそのまま書く（バイトには L3 は触れない）。

  設定（app env）:
    * `:ticket_pubkey` — sukhi の Ed25519 公開鍵（生 32 バイト）
    * `:gnat`          — Gnat 接続の登録名（例 `:gnat`）
  """
  @behaviour Karutte.WebTransport
  require Logger
  alias Karutte.Ticket

  @impl true
  def authorize(conn_info) do
    case verify(conn_info[:path]) do
      {:ok, _claims} -> :ok
      {:error, _} -> {:reject, 401}
    end
  end

  @impl true
  def init(_arg, conn_info) do
    case verify(conn_info[:path]) do
      {:ok, claims} ->
        {:ok,
         %{
           transport: conn_info.transport,
           conn: conn_info.conn,
           claims: claims,
           gnat: Application.get_env(:karutte_wt, :gnat, :gnat),
           streams: %{}
         }}

      {:error, reason} ->
        {:stop, {:unauthorized, reason}}
    end
  end

  # セッション確立後に、feed ごとに sub＋uni-stream を開く。
  @impl true
  def handle_info(:wt_ready, state) do
    streams =
      for feed <- state.claims.feeds, subject = subject_for(feed, state.claims.sub), into: %{} do
        {:ok, _sub} = Gnat.sub(state.gnat, self(), subject)
        {:ok, stream} = state.transport.open_stream(state.conn, :uni)
        {subject, stream}
      end

    {:ok, %{state | streams: streams}}
  end

  # NATS からの event を、その feed のストリームへ流す（1 event = 1 フレーム、改行区切り JSON）。
  def handle_info({:msg, %{topic: subject, body: body}}, state) do
    case state.streams[subject] do
      nil -> {:ok, state}
      stream -> state.transport.send(stream, [body, "\n"]) && {:ok, state}
    end
  end

  def handle_info(_msg, state), do: {:ok, state}

  # client 発ストリームは受けない（server push 専用の橋）。
  @impl true
  def handle_stream(_stream, _dir, state), do: {{:reset, 0}, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  @doc "feed 名 → NATS subject。共有 feed は全員同じ、user だけ本人の sub 付き。"
  @spec subject_for(String.t(), String.t()) :: String.t() | nil
  def subject_for("local", _sub), do: "stream.local"
  def subject_for("bubble", _sub), do: "stream.bubble"
  def subject_for("user", sub), do: "stream.user." <> sub
  def subject_for(_unknown, _sub), do: nil

  defp verify(path) when is_binary(path) do
    with %{"ticket" => token} <- query(path),
         pubkey when is_binary(pubkey) <- Application.get_env(:karutte_wt, :ticket_pubkey) do
      Ticket.verify(token, pubkey, System.system_time(:second))
    else
      nil -> {:error, :no_ticket_pubkey}
      _ -> {:error, :no_ticket}
    end
  end

  defp verify(_), do: {:error, :no_path}

  defp query(path) do
    case String.split(path, "?", parts: 2) do
      [_, q] -> URI.decode_query(q)
      _ -> %{}
    end
  end
end
