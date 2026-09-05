defmodule Karutte.Varint do
  @moduledoc """
  QUIC variable-length integers (RFC 9000 §16). Pure.

  The top two bits of the first byte pick the length class:

      00 → 1 byte  (6-bit value, 0..63)
      01 → 2 bytes (14 bits)
      10 → 4 bytes (30 bits)
      11 → 8 bytes (62 bits)

  Why it lives here: on both HTTP/3 and HTTP/2, the WebTransport wire format is built on this
  varint. The session id (the CONNECT stream's id) and the type/length of every Capsule
  (RFC 9297) are all prefixed with it. So it is the shared floor beneath both bindings.

  Source: <https://datatracker.ietf.org/doc/html/rfc9000#section-16>
  """

  @max 4_611_686_018_427_387_903

  @doc "Encode a non-negative integer in the shortest class that fits."
  @spec encode(non_neg_integer()) :: binary()
  def encode(v) when is_integer(v) and v >= 0 and v <= 63, do: <<0::2, v::6>>
  def encode(v) when is_integer(v) and v <= 16_383, do: <<1::2, v::14>>
  def encode(v) when is_integer(v) and v <= 1_073_741_823, do: <<2::2, v::30>>
  def encode(v) when is_integer(v) and v <= @max, do: <<3::2, v::62>>

  @doc """
  Read one varint from the front. Returns `{:ok, value, rest}`, or `:more` if there are not
  enough bytes yet.

  A varint cannot be malformed (once the class is known, so is the byte count), so the only
  failure is "not enough". There is no `:error`.
  """
  @spec decode(binary()) :: {:ok, non_neg_integer(), binary()} | :more
  def decode(<<0::2, v::6, rest::binary>>), do: {:ok, v, rest}
  def decode(<<1::2, v::14, rest::binary>>), do: {:ok, v, rest}
  def decode(<<2::2, v::30, rest::binary>>), do: {:ok, v, rest}
  def decode(<<3::2, v::62, rest::binary>>), do: {:ok, v, rest}
  def decode(_), do: :more
end
