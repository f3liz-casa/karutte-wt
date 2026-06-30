defmodule Karutte.WebTransport.HandoffTest do
  use ExUnit.Case, async: true

  alias Karutte.WebTransport.Handoff

  # {:obs, bin} を n 個集める
  defp collect(n), do: collect(n, [])
  defp collect(0, acc), do: Enum.reverse(acc)

  defp collect(n, acc) do
    receive do
      {:obs, bin} -> collect(n - 1, [bin | acc])
    after
      500 -> Enum.reverse(acc)
    end
  end

  test "handoff: 先着分を再生してから live、順序も損失もなし" do
    test = self()
    stream = make_ref()

    # 新オーナー: handoff を待ち、buffered を先に再生、その後 live を読む
    new_owner =
      spawn(fn ->
        {:ok, buffered} = Handoff.wait(stream)
        Enum.each(buffered, fn {bin, _meta} -> send(test, {:obs, bin}) end)

        for _ <- 1..2 do
          receive do
            {:quic, :data, ^stream, bin, _meta} -> send(test, {:obs, bin})
          end
        end
      end)

    # 競合窓: handoff の前に "A" が古いオーナー（=このテストプロセス）へ届いている
    send(self(), {:quic, :data, stream, "A", fin: false})

    :ok = Handoff.complete(stream, new_owner)

    # control/2 が宛先を新オーナーへ切替えた想定で live を直送
    send(new_owner, {:quic, :data, stream, "B", fin: false})
    send(new_owner, {:quic, :data, stream, "C", fin: true})

    assert collect(3) == ["A", "B", "C"]
  end

  test "約束を破ると（待たない/吸わない）先着の \"A\" は古いオーナーに取り残される" do
    test = self()
    stream = make_ref()

    # 素朴オーナー: 待たずにいきなり live を 2 つ読む
    naive =
      spawn(fn ->
        for _ <- 1..2 do
          receive do
            {:quic, :data, ^stream, bin, _meta} -> send(test, {:obs, bin})
          end
        end
      end)

    # "A" は古いオーナー（このプロセス）へ。素朴オーナーは触れられない
    send(self(), {:quic, :data, stream, "A", fin: false})
    send(naive, {:quic, :data, stream, "B", fin: false})
    send(naive, {:quic, :data, stream, "C", fin: true})

    # 観測されるのは B,C だけ（"A" は欠ける）
    assert collect(2) == ["B", "C"]
    # そして "A" はこのプロセスのメールボックスに取り残されている
    assert_received {:quic, :data, ^stream, "A", _}
  end
end
