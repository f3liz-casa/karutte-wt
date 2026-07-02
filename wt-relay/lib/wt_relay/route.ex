defmodule WtRelay.Route do
  @moduledoc """
  一本の L4 の宣言。二つのモードがある。

  * `mode: :dnat`（origin 必須）── relay の公開ポートに来たものを origin(WG の向こう)へ
    DNAT で渡す転送ルート。`preserve_ip: true`（既定）は SNAT を*足さない*＝origin が
    実クライアント IP を素で見る（透過 A）。

  * `mode: :observe`（origin 不要）── 転送せず、**L4 で数えるだけ**の庭師ルート。
    データ面には立たない（`-j RETURN` で素通し）。二層で見る:
      - **raw PREROUTING**（毎パケット、conntrack より前）＝ ハンドシェイクにならず
        捨てられた spoof も含む生の UDP 洪水量。
      - **mangle PREROUTING ＋ conntrack NEW**（フロー初回だけ）＝ 新規接続レート。
    暗号の手前で見えるので、QUIC の統計に映らない flood を数えられる。

  karutte を同じ箱に直載せしたので今は observe を使う。dnat は relay 転送に戻すとき用に残す。
  """
  @enforce_keys [:name, :proto, :listen_port]
  defstruct [:name, :proto, :listen_port, :origin, mode: :dnat, preserve_ip: true]

  @type mode :: :dnat | :observe

  @type t :: %__MODULE__{
          name: String.t(),
          proto: :udp | :tcp,
          listen_port: 1..65_535,
          # dnat のときだけ使う。"10.9.0.2:443" — WG の向こうの origin。observe では nil。
          origin: String.t() | nil,
          mode: mode(),
          preserve_ip: boolean()
        }
end
