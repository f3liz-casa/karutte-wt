defmodule Karutte.WebTransport.Handoff do
  @moduledoc """
  ストリーム所有権の手渡しの、順序の約束。

  `{:quic, :new_stream}` を受けた瞬間、そのストリームのバイトはまだ
  古いオーナー（セッション=接続 owner）のメールボックスに届きうる。
  新オーナーがいきなり live を読み始めると、その隙間に来たデータは
  古いオーナーに残されて **消える**。

  約束はひとつ:

      古いオーナー: 先着分を吸い出す → 新オーナーへ渡す（complete/2）
      新オーナー:   handoff_done を受けるまで live に触れない（wait/2）→ 先に再生

  これで無損失・無順序狂いになる。`test/handoff_test.exs` が両側を確かめる。
  """

  alias Karutte.QuicTransport

  @doc """
  古いオーナー側。自分のメールボックスに先着している当該ストリームの
  data を順序のまま吸い出し、新オーナーへ `{:handoff_done, stream, buffered}` で渡す。
  この後 `QuicTransport.control/2` で transport の宛先を新オーナーへ切り替える想定。
  """
  @spec complete(QuicTransport.stream(), pid()) :: :ok
  def complete(stream, new_owner) do
    buffered = drain(stream, [])
    send(new_owner, {:handoff_done, stream, buffered})
    :ok
  end

  @doc """
  新オーナー側。`handoff_done` を待ち、再生すべき先着分を返す。
  これを受け取るまで live のストリームメッセージに触れてはいけない。
  """
  @spec wait(QuicTransport.stream(), timeout()) ::
          {:ok, [{binary(), keyword()}]} | {:error, :handoff_timeout}
  def wait(stream, timeout \\ 5_000) do
    receive do
      {:handoff_done, ^stream, buffered} -> {:ok, buffered}
    after
      timeout -> {:error, :handoff_timeout}
    end
  end

  # 既にメールボックスにある {:quic, :data, stream, bin, meta} だけを順序のまま集める
  defp drain(stream, acc) do
    receive do
      {:quic, :data, ^stream, bin, meta} -> drain(stream, [{bin, meta} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
