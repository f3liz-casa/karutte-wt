# 事実と出典のカード

`research-notes.md` の推論が寄りかかっている、確かめた事実と出典。
推論（なぜそうするか）はあちら、ここは事実（何がそうなのか）だけ。

## QUIC / WebTransport プロトコル

### WebTransport over HTTP/3 (draft-ietf-webtrans-http3, v15 / 2026-03)

- セッションはクライアントの **Extended CONNECT** で開く。その CONNECT ストリームの
  stream ID が、接続内のセッションを一意に識別する。
- 確立後は HTTP は使われない。QUIC ストリームは先頭の数バイトでセッションに紐づき、
  残りがアプリのペイロード。
- 単方向ストリーム・双方向ストリーム・データグラムを、同じ HTTP/3 接続内で多重化。
- 出典: <https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/>

### WebTransport over HTTP/2 (draft-ietf-webtrans-http2)

- TCP ベース。QUIC 無しで動くが、HoL ブロッキングが戻り、datagram は擬似化される。
- 出典: <https://datatracker.ietf.org/doc/html/draft-ietf-webtrans-http2>

### RFC 9297 — HTTP Datagrams and the Capsule Protocol

- HTTP 接続内で多重化された（場合により不確実な）データグラムを運ぶ取り決め。
  HTTP/3 では QUIC DATAGRAM 拡張で不確実に送れる。WebTransport はこの capsule を使う。
- 出典: <https://datatracker.ietf.org/doc/rfc9297/>

### RFC 9221 — An Unreliable Datagram Extension to QUIC

- **QUIC datagram はフロー制御されない。** 受信側が処理しきれなければ落としてよい（MAY be dropped）。
  不確実・無順序。フロー制御を省いた理由は実務的（フレーム内容をメモリに保持できないかもしれない。
  でも不確実フレームはプロトコル違反なしに落とせるので許される）。
- ストリームは対照的に MAX_STREAM_DATA でストリーム別にフロー制御され、背圧をかけられる。
  クレジットを使い切った送り手は STREAM_DATA_BLOCKED を送ってブロック状態を示す。
- 出典: <https://datatracker.ietf.org/doc/html/rfc9221>

## quicer（emqx/quic — msquic の Erlang NIF）

- 構成: NIF Interface Layer ↔ C Implementation Layer ↔ MsQuic + TLS(OpenSSL)。状態は **Preview**。
  Rust 書き換えの議論もある（msquic は Rust binding を持つが production grade ではない）。

### 新ストリームと所有権の手渡し

- peer がストリームを開くと、イベントは **まず connection owner に届く**。owner が扱い方を決める。
  accept されず passive のままだと「orphaned」ストリームになり、既定では connection owner が所有者になる。
- `controlling_process/2`: Connection / Stream の controlling process を設定。ストリームでは、
  handoff 失敗時は旧 owner へ、成功時は新 owner へ signal buffer を flush する。
- `handoff_stream/2`（旧 owner が手渡す）＋ `wait_for_handoff/2`（新 owner が完了を待つ）。
  signal `{handoff_done, Stream, PostHandoff}` が新 owner に届く。**新 owner はこれを受けるまで
  ストリームデータを扱ってはいけない**（順序保証のため）。
- 出典: <https://hexdocs.pm/quicer/messages_to_owner.html> /
  <https://deepwiki.com/emqx/quic/2.2-event-handling> / <https://hexdocs.pm/quicer/quicer.html>

### 受信の背圧（passive + PENDING）

- passive モードでは受信データはバッファされ、アプリが `quicer:recv/2` で引く。データがあるとき
  NIF は `is_recv_pending` を立て、**msquic へ `QUIC_STATUS_PENDING` を返して以後の receive callback を止める**。
  これが背圧の実体（アプリが消費するまで窓が伸びない）。
- 対応する msquic 側: STREAM receive イベントのハンドラは SUCCESS / CONTINUE / PENDING を返す。
  PENDING（非同期処理）では QUIC_BUFFER 配列をコピーする必要がある。
- 出典: <https://github.com/microsoft/msquic/blob/main/docs/Streams.md> /
  <https://microsoft.github.io/msquic/msquicdocs/docs/api/QUIC_STREAM_EVENT.html>

## Plug / Bandit / WebSock（屋根の側）

### Bandit

- HTTP/1.x・HTTP/2・WebSocket を HTTP/HTTPS（TCP）で。**HTTP/3 は未実装。**
  土台は Thousand Island（TCP アクセプタ・プール）。
- Mat Trudel の方針: HTTP/3 を書きたいが、まず **OTP 自身が QUIC を持つべき**で、Bandit は
  その上に H3 を載せる。HTTP/3 には QUIC、QUIC には UDP スタックを first principles から要する。
- 出典: <https://github.com/mtrudel/bandit> /
  <https://smartlogic.io/podcast/elixir-wizards/s10-e06-elixir-phoenix-web-transports/>

### WebSock（抽象）と upgrade 経路

- WebSock は WebSocket の汎用抽象（Plug が HTTP の汎用抽象であるのと同じ関係）。
  callback: `init/1` `handle_in/2` `handle_control/2`（ping/pong, サーバが自動 pong）
  `handle_info/2` `terminate/2`。state は `term()`。返り: `{:push, msgs, state}` /
  `{:ok, state}` / `{:stop, reason, state}` ほか。frame は `{opcode, iodata|nil}`。
  **アプリから見えるフロー制御は無い**（TCP が下で隠す）。
- upgrade: `WebSockAdapter.upgrade/4` → `Plug.Conn.upgrade_adapter/3` で「この request の最後に
  ソケットをプロトコル X へ」を Bandit に伝える。`call/2` 終了時に `Bandit.DelegatingHandler` が
  handler を切り替える。**WebTransport はこの脱出口の二つ目の実例**（X=webtransport）として乗る。
- 出典: <https://websock.hexdocs.pm/0.5.3/WebSock.html> /
  <https://hexdocs.pm/bandit/WebSocket_README.md.html>

### 既存の WebTransport ライブラリ（並行スタック）

- **requiem**（xflagstudio）: Rustler 経由で cloudflare/quiche の **WebTransport 対応フォーク** を抱える。
  callback `init/2` `handle_stream/4` `handle_dgram/3` ほか。experimental。Plug 非統合。
  <https://github.com/xflagstudio/requiem>
- **wtransport-elixir**: Rust の wtransport crate を Rustler binding。Plug 非統合。
  <https://github.com/bugnano/wtransport-elixir>
