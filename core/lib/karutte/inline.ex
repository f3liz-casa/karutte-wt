defmodule Karutte.Inline do
  @moduledoc """
  The assembler for `{:inline, max}` streams. Pure functions.

  Accumulate until FIN; reset as soon as `max` is exceeded. This is the boundary that lets a
  stream be delivered whole rather than byte by byte, and it is the memory lid on the one
  hole (`inline`) that `Karutte.WebTransport` opens in the control plane. Overflow is
  detected on chunk arrival, without waiting for FIN, so the buffer stops before it swells.
  """

  @type t :: {acc :: iodata(), size :: non_neg_integer(), max :: pos_integer()}

  @spec new(pos_integer()) :: t()
  def new(max) when is_integer(max) and max > 0, do: {[], 0, max}

  @doc "Feed one chunk, `{bin, fin?}`."
  @spec feed(t(), {binary(), boolean()}) ::
          {:cont, t()} | {:done, binary()} | {:overflow, pos_integer()}
  def feed({acc, size, max}, {bin, fin?}) do
    nsize = size + byte_size(bin)

    cond do
      nsize > max -> {:overflow, max}
      fin? -> {:done, IO.iodata_to_binary([acc, bin])}
      true -> {:cont, {[acc, bin], nsize, max}}
    end
  end

  @doc "Helper: run a list of chunks through to the end."
  @spec drive(pos_integer(), [{binary(), boolean()}]) ::
          {:done, binary()} | {:overflow, pos_integer()} | {:cont, t()}
  def drive(max, chunks) do
    Enum.reduce_while(chunks, new(max), fn chunk, st ->
      case feed(st, chunk) do
        {:cont, st2} -> {:cont, st2}
        terminal -> {:halt, terminal}
      end
    end)
  end
end
