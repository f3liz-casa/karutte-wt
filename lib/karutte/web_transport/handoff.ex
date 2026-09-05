defmodule Karutte.WebTransport.Handoff do
  @moduledoc """
  The ordering promise for handing a stream from one owner to another.

  The moment `{:quic, :new_stream}` is received, bytes for that stream can still land in the
  old owner's mailbox (the session, or the connection owner). If the new owner starts reading
  live traffic straight away, anything that arrived in that gap stays with the old owner and
  is **lost**.

  One promise fixes it:

      old owner: drain what already arrived → hand it to the new owner (complete/2)
      new owner: touch nothing live until handoff_done arrives (wait/2) → replay that first

  No loss, no reordering. `test/handoff_test.exs` checks both sides.
  """

  alias Karutte.QuicTransport

  @doc """
  Old-owner side. Drain, in order, the data for this stream that already sits in our mailbox
  and hand it to the new owner as `{:handoff_done, stream, buffered}`. Afterwards the caller
  is expected to point the transport at the new owner with `QuicTransport.control/2`.
  """
  @spec complete(QuicTransport.stream(), pid()) :: :ok
  def complete(stream, new_owner) do
    buffered = drain(stream, [])
    send(new_owner, {:handoff_done, stream, buffered})
    :ok
  end

  @doc """
  New-owner side. Wait for `handoff_done` and return the buffered chunks to replay. Until this
  returns, live stream messages must not be touched.
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

  # Collect, in order, only the {:quic, :data, stream, bin, meta} messages already in the mailbox.
  defp drain(stream, acc) do
    receive do
      {:quic, :data, ^stream, bin, meta} -> drain(stream, [{bin, meta} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
