defmodule Karutte.Varint do
  @moduledoc """
  QUIC の可変長整数（RFC 9000 §16）。純粋。

  先頭バイトの上位 2 ビットが長さの級を決める:

      00 → 1 バイト（6 ビット値、0..63）
      01 → 2 バイト（14 ビット）
      10 → 4 バイト（30 ビット）
      11 → 8 バイト（62 ビット）

  なぜここに居るか。HTTP/3 でも HTTP/2 でも、WebTransport のワイヤは
  この varint を土台にする — session id（CONNECT ストリームの id）も、
  Capsule の type/length（RFC 9297）も、みんなこれで前置きされる。
  だから二つのバインディングが分かれる前の、共有の床。

  出典: <https://datatracker.ietf.org/doc/html/rfc9000#section-16>
  """

  @max 4_611_686_018_427_387_903

  @doc "非負整数を最短の級でエンコードする。"
  @spec encode(non_neg_integer()) :: binary()
  def encode(v) when is_integer(v) and v >= 0 and v <= 63, do: <<0::2, v::6>>
  def encode(v) when is_integer(v) and v <= 16_383, do: <<1::2, v::14>>
  def encode(v) when is_integer(v) and v <= 1_073_741_823, do: <<2::2, v::30>>
  def encode(v) when is_integer(v) and v <= @max, do: <<3::2, v::62>>

  @doc """
  先頭の varint を一つ読む。`{:ok, value, rest}` か、まだバイトが足りなければ `:more`。

  varint は壊れようがない（級が決まれば必要なバイト数も決まる）ので、失敗は
  「足りない」だけ。`:error` は無い。
  """
  @spec decode(binary()) :: {:ok, non_neg_integer(), binary()} | :more
  def decode(<<0::2, v::6, rest::binary>>), do: {:ok, v, rest}
  def decode(<<1::2, v::14, rest::binary>>), do: {:ok, v, rest}
  def decode(<<2::2, v::30, rest::binary>>), do: {:ok, v, rest}
  def decode(<<3::2, v::62, rest::binary>>), do: {:ok, v, rest}
  def decode(_), do: :more
end
