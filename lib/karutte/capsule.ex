defmodule Karutte.Capsule do
  @moduledoc """
  Capsule Protocol（RFC 9297）。純粋。

  カプセルは三つ組:

      Capsule Type   (varint)
      Capsule Length (varint = Value のバイト長)
      Capsule Value  (Length バイト)

  これが要るのは HTTP/2 フォールバックの datagram のため。
  HTTP/3 では QUIC の DATAGRAM 拡張（RFC 9221）で不確実に送れるが、
  HTTP/2 には datagram が無い。だから WebTransport over HTTP/2 は
  datagram を **DATAGRAM カプセル** に包んで CONNECT ストリームの上を
  信頼配送で流す。速くはないし不確実でもない＝意味論は痩せるが、動く。

  出典: <https://datatracker.ietf.org/doc/rfc9297/>
  """

  alias Karutte.Varint

  # DATAGRAM カプセル（RFC 9297 / IANA HTTP Capsule Types）。
  @datagram 0x00
  def datagram_type, do: @datagram

  @doc "一つのカプセルをエンコードする。"
  @spec encode(non_neg_integer(), binary()) :: binary()
  def encode(type, value) when is_integer(type) and type >= 0 and is_binary(value) do
    Varint.encode(type) <> Varint.encode(byte_size(value)) <> value
  end

  @doc """
  先頭のカプセルを一つ読む。

  `{:ok, type, value, rest}` か、Value まで揃っていなければ `:more`。
  varint は壊れないので、ここでも失敗は「足りない」だけ。
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
