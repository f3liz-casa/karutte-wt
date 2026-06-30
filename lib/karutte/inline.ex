defmodule Karutte.Inline do
  @moduledoc """
  `{:inline, max}` ストリームの組み立て機械。純粋関数。

  FIN まで貯め、max を超えたら即 reset（per-byte ではなく一塊で渡すための境界）。
  これが `Karutte.WebTransport` の制御面に開けた穴（inline）の、メモリの蓋。
  超過は FIN を待たずチャンク到着時点で出る（膨らむ前に止める）。
  """

  @type t :: {acc :: iodata(), size :: non_neg_integer(), max :: pos_integer()}

  @spec new(pos_integer()) :: t()
  def new(max) when is_integer(max) and max > 0, do: {[], 0, max}

  @doc "一つのチャンク {bin, fin?} を食わせる。"
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

  @doc "チャンク列を最後まで流す補助。"
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
