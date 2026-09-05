defmodule Karutte.Capsule do
  @moduledoc """
  The Capsule Protocol (RFC 9297). Pure.

  A capsule is a triple:

      Capsule Type   (varint)
      Capsule Length (varint, byte length of Value)
      Capsule Value  (Length bytes)

  This exists for datagrams on the HTTP/2 fallback. On HTTP/3, datagrams go out unreliably
  through the QUIC DATAGRAM extension (RFC 9221). HTTP/2 has no datagrams, so WebTransport
  over HTTP/2 wraps each one in a **DATAGRAM capsule** and sends it reliably over the CONNECT
  stream. Not fast, not unreliable, so the semantics are thinner. But it works.

  Source: <https://datatracker.ietf.org/doc/rfc9297/>
  """

  alias Karutte.Varint

  # DATAGRAM capsule (RFC 9297 / IANA HTTP Capsule Types).
  @datagram 0x00
  def datagram_type, do: @datagram

  @doc "Encode one capsule."
  @spec encode(non_neg_integer(), binary()) :: binary()
  def encode(type, value) when is_integer(type) and type >= 0 and is_binary(value) do
    Varint.encode(type) <> Varint.encode(byte_size(value)) <> value
  end

  @doc """
  Read one capsule from the front.

  Returns `{:ok, type, value, rest}`, or `:more` if the Value is not all there yet. Varints
  cannot be malformed, so here too the only failure is "not enough".
  """
  @spec decode(binary()) :: {:ok, non_neg_integer(), binary(), binary()} | :more
  def decode(bin) when is_binary(bin) do
    with {:ok, type, after_type} <- Varint.decode(bin),
         {:ok, len, after_len} <- Varint.decode(after_type),
         <<value::binary-size(^len), rest::binary>> <- after_len do
      {:ok, type, value, rest}
    else
      _ -> :more
    end
  end
end
