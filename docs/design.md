# karutte — 設計

karutte 本体（WebTransport サーバ）の設計。なぜ今まで無かったか、層モデル、背圧の三軸、
確かめてあること、正直なほつれ。front page は [`../README.md`](../README.md)。

## なぜ「Plug の中の WebTransport」が今まで無いのか

三つの理由が同時に効いている。

1. **床（QUIC）が無い。** WebTransport は HTTP/3 → QUIC → UDP の上にいる。Plug の
   サーバ（Bandit / Cowboy）は TCP 止まり。BEAM 上の QUIC は emqx の `quicer`
   （msquic の NIF）があるがまだ Preview。Bandit 作者は「OTP 自身が QUIC を持つべき」
   という立場で、自分のサーバに密結合で抱えるのを避けている。
2. **抽象がねじれる。** `Plug.Conn` は request → response の一本の矢。WebSocket は
   `upgrade_adapter` で矢から逃げる一例。WebTransport は一本の CONNECT が多数の
   ストリーム＋データグラムを生むので、`Conn →（多重化するセッション）` という、
   さらに遠い形。「WebSocket における WebSock」に当たる合意された抽象がまだ無い。
3. **既存解が横にそれている。** requiem / wtransport-elixir はどちらも Rust の QUIC
   スタックを Rustler で丸ごと抱えた並行スタックで、Plug/Bandit と統合していない。
   (1)(2) を解いたのではなく迂回した。

つまり屋根（上の抽象）は `upgrade_adapter` と WebSock の形でもう転がっていて、
無いのは床だけだった。このリポジトリは屋根の形を先に確かめ、それから床（quicer + cowlib）を
接いで、ブラウザまで通した。requiem のように並行スタックを丸抱えするのでなく、runner 抽象を
表に残したまま。

## 見立て

WebTransport セッションの状態空間は、きれいに積に分かれる:

```
Session  ×  (Stream)*  ×  Datagram-port
（制御面）   （ストリームたち）  （軸の外）
```

三つは失敗も順序も独立。だから設計もこの積を、そのままプロセスの積に写す。

behaviour（spec）と、それを回す実体（runner）を分けてある。

| 層 | spec（behaviour） | runner（実体） | 役 |
|----|------|------|----|
| L4 Stream | `Karutte.WebTransport.Stream` | `…Stream.StreamServer`※ | データ面。1 ストリーム = 1 プロセス。WebSock + demand + half-close |
| L3 Session | `Karutte.WebTransport` | `Karutte.WebTransport.Session` | 制御面**だけ**。accept / handoff / datagram / 寿命。バイトには触れない |
| L2 縫い目 | — | `Karutte.WebTransportAdapter` | Plug `upgrade_adapter(:webtransport, …)` の脱出口（WebSock と対称） |
| L1 QUIC | `Karutte.QuicTransport` | `…Http3` / `…Quicer` / `…Http2` | 差し替え口（behaviour）。床を裏に隠す |

※ runner は `Karutte.WebTransport.StreamServer`。

L1 の床（差し替え口の三つの実装）:

- `Karutte.QuicTransport.Http3` — **本物の床（動く）**。WebTransport over HTTP/3。quicer（QUIC）の
  上に cowlib（H3/QPACK）を載せ、`Karutte.Http3.Server` / `Karutte.Http3.Connection` が
  リスナと接続を回す。ブラウザが実際に使う道。
- `Karutte.QuicTransport.Quicer` — 素の QUIC への薄い委譲＋メッセージ正規化（Http3 の部品）。
- `Karutte.QuicTransport.Http2` — TCP の床。WebTransport over HTTP/2（draft-ietf-webtrans-http2）。
  ブラウザ非対応のフォールバック（Elixir↔Elixir 用）。

runner（L2/L3/L4）は `normalize/1` 済みの `{:quic, …}` 契約だけを見る ＝ **床に依らない**。
だから Session / StreamServer は HTTP/3 でも HTTP/2 でも同じコードで回る。

HTTP/3 サーバ機構（`Karutte.Http3.*`）— 監視ツリーひと組:

      Karutte.Http3.Server (Supervisor)        … child_spec/1 を持つ。自分のアプリに挿せる
      ├── Karutte.Http3.Listener               … UDP ポートを開けっ放しにする番人
      ├── ConnectionSup (DynamicSupervisor)    … 接続ごとの Connection（temporary）
      └── Karutte.Http3.Acceptor × N           … 受け付け（permanent、落ちたら再起動）

- `Karutte.Http3.Connection` — 接続ごとの GenServer。quicer の唯一の所有者として cow_http3_machine で
  H3/QPACK/Extended CONNECT を捌き、WT ストリーム/datagram を runner へ振る。複数 WT セッション・
  セッション capsule（CLOSE/DRAIN）対応。terminate で接続を閉じる。
- `Karutte.Http3.Cert` — 自己署名 ECDSA 証明書＋`serverCertificateHashes` 用の SHA-256。
- `Karutte.Http3.Echo` — いちばん素朴な WebTransport ハンドラの例（受けたものを返す）。

本番の効く所を入れてある:

- **耐障害**: 接続一つの事故は ConnectionSup の中で閉じ、acceptor が落ちても再起動して受け付けは続く。
  さらに **ストリームハンドラのクラッシュはそのストリームだけ reset**（Session が exit を trap して隔離）
  ＝一つの壊れたストリームでセッション全体を道連れにしない。
- **背圧（AXIS 2）**: WT ストリームを active:once で受けて以後は StreamServer の demand で QUIC の窓を
  動かす（垂れ流さない）。**datagram（軸の外）は有界 drop**（RFC 9221 どおり、runner のメールボックスが
  `max_datagram_queue` を超えたら落とす。ブロックしない）。
- **上限**: `max_sessions`（1 接続あたり WT セッション）、`max_connections`（同時接続。超過は静かに断る）。
- **認証・ルーティング**: CONNECT の `:path` / `:authority` / ヘッダ / `:peer`（QUIC peer アドレス）を
  `conn_info` でハンドラに渡す。任意の `authorize/1` 門番で `:ok` / `{:reject, status}` を返せる
  （path やトークン・IP で受理/拒否）。受理のときだけ 200、拒否は指定 status で断る。
- **wt-relay 連携（透過 L4 リレー裏で動く）**: `:bind`（WG アドレスだけで待つ）、`:keep_alive_interval_ms`
  （relay の conntrack 温存）、`conn_info.peer`（透過モードでは実クライアント IP）。詳細は
  [`wt-relay-integration.md`](wt-relay-integration.md)。
- **server push / server 発ストリーム**: セッションが立つと handler に `:wt_ready` が届く。そこで
  `transport.open_stream(conn, :uni)` で単方向 push、`open_stream(conn, :bidi, handler: Mod, init_arg: a)`
  で **双方向ストリーム**（L4 runner 付きで読み書き）を server から開ける。
- **並行性**: handshake は acceptor でなく **Connection（所有者）自身**が回す ＝ 接続ごとに並行、
  かつ「accept と所有権移譲の隙にクライアントの早いストリームが落ちる」窓も無い。
- **観測**: `[:karutte, :http3, …]` の telemetry イベント（connection start/stop/drain, session open/close/rejected,
  datagram dropped, connection rejected, stream refused）。
- **graceful shutdown**: `Karutte.Http3.Server.drain(name, grace_ms)` で、acceptor を止め（新規を受けない）、
  各接続に H3 GOAWAY ＋各 WT セッションへ DRAIN capsule を配り、猶予のあとツリーごと停止。
  ローリング再起動でクライアントを穏やかに移す。**ドレイン中のセッションは新規ストリームを reset で断る**
  （server 発の drain / peer からの inbound DRAIN capsule、どちらでも）。進行中のストリームは生かす。

補助:

- `Karutte.WebTransport.Handoff` — 所有権を手渡すときの順序の約束（競合窓を閉じる）
- `Karutte.Inline` — 短命ストリームを一塊で渡すための組み立て機械（メモリの蓋）
- `Karutte.Varint` / `Karutte.Capsule` — ワイヤの土台（RFC 9000 §16 / RFC 9297）。HTTP/2 の床が使う。

### エッジとして駆動する — イベントバスを WebTransport へ（応用）

`Karutte.Http3.Echo` の代わりに、外のイベントを WT へ流すハンドラを差せる。付属の例:

- `Karutte.Ticket` — 入場チケットの検証。別サーバが Ed25519 で署名した短命トークンを、karutte が
  **公開鍵だけでローカル検証**する（接続ごとに問い合わせない＝暗号の直後に安く弾ける）。
- `Karutte.Bridge` — WebTransport ハンドラの例。`authorize/1` で `?ticket=` を検札 → **feed ごとに
  NATS を購読し、1 feed = 1 uni ストリーム**で流す。騒がしい feed が静かな feed を待たせない
  （ストリーム独立の flow control）。

fedi サーバ（sukhi）の live タイムラインを、Cloudflare の裏／使い捨ての最前線から配るための応用。
経路（透過 L4 リレー・実 IP 保存・秘匿・flood 対策）は [`wt-relay-integration.md`](wt-relay-integration.md)
と [`../wt-relay/`](../wt-relay/) に。

## 背圧は三軸で、重ならない

QUIC のフロー制御は三つあって、それぞれ別の場所に、同じ語彙を共有せずに収まる。
ここが設計のいちばんの肝。

| 軸 | 居場所 | demand 旋 | 面 |
|----|-------|----------|----|
| MAX_STREAMS（生成） | `WebTransport.handle_stream/3` が処分を返す速さ | 無し | 制御面 |
| MAX_STREAM_DATA（転送） | `WebTransport.Stream` の `demand`（各 ret に付く） | **ここだけ** | データ面 |
| MAX_DATA（接続全体） | transport が和から創発（API に現れない） | 無し | — |
| datagram（軸の外） | `handle_datagram/2`。フロー制御なし＝drop、ブロックしない | 無し | 制御面 |

`active:` は四つの面のうち `Stream` 一箇所にしか出てこない。生成は「返す速さ」で、
転送は「demand」で、接続全体は「つまみ無し」で、datagram は「設定された drop」で。
混ざりようがない。

## 確かめてあること

`mix test` が緑（69 passed）。**実 QUIC で end-to-end が通っている**:

- `test/http3_loopback_test.exs` — 最小 Elixir クライアント↔ H3 WebTransport サーバを実 quicer で繋ぐ:
  - connect → H3 SETTINGS → Extended CONNECT(webtransport) → 200 → WT 双方向ストリーム echo → datagram echo
  - 一つの H3 接続に**独立した二つの WT セッション**（session_id で振り分け）
  - **CLOSE_WEBTRANSPORT_SESSION capsule** でそのセッションだけ畳まれ、runner の terminate が走る

  - **一接続の事故はサーバ全体を倒さない**（Connection を kill しても新しい接続は通る）
  - **datagram の過負荷は drop**（遅いハンドラに flood して telemetry で drop を観測）
  - **telemetry イベント**（セッション open が飛ぶ）
  - **ストリームハンドラのクラッシュ隔離**（`l2_test.exs`: handle_in が raise → そのストリームだけ reset、セッションは生存）
  - **graceful drain**（`Server.drain` でセッションに DRAIN capsule が届く）
  - **DRAIN 後の新規ストリーム拒否**（peer から DRAIN → 以後の WT ストリームは reset される）
  - **authorize/1 での認証**（path が "/ok" は 200、それ以外は 403）
  - **大きなペイロード（64KB）が多フレーム跨ぎで整合したまま往復**
  - **demand 駆動（active: :once）でも 32KB が取りこぼしなく往復**（背圧ループの volume 検証）
  - **server push**（handler が `:wt_ready` で server 発 uni ストリームを開き、クライアントに届く）
  - **server 発 bidi ストリーム**（handler が echo runner 付きで開き、client が書くと echo が返る）
  - **多接続同時 echo**（8 接続並行）／ **一接続で多ストリーム同時 echo**（20 本を handle 別に demux）

そして **本物のブラウザ（Chrome 149）でも確認済み**: 自己署名証明書を `serverCertificateHashes`
でピン留めして `new WebTransport("https://localhost:4433/")`、双方向ストリーム echo（"hi"→"hi"）と
datagram echo（"ping"→"ping"）が通った。サーバは一連のやり取りを通して落ちない。

以下は純粋断片の verify:

- `test/inline_test.exs` — 組み立て・境界・早期 overflow が漏れなく閉じている
- `test/handoff_test.exs` — handoff の約束で順序と損失が守られること、
  約束を破ると先着データが取り残されること（＝この約束が要る理由）
- `test/varint_test.exs` / `test/capsule_test.exs` — ワイヤの土台が往復し、足りなければ `:more`
- `test/quicer_normalize_test.exs` — L1 の「メッセージの面」（quicer ネイティブ → 契約）
- `test/http2_test.exs` — HTTP/2 の床: 前置き・stream・datagram カプセルが往復、demand が H2 の窓へ
- `test/transport_parity_test.exs` — 二つの床が同じ behaviour を満たし、同じ `{:quic, …}` 契約を作る
- `test/l2_test.exs` — runner が床に依らず L3/L4 を回す（偽の床で end-to-end）:
  new_stream → handoff → echo、demand が床へ、FIN で半閉じ、inline の組み立てと overflow reset、
  reset 処分、datagram の制御面分配
- `test/ticket_test.exs` — Ed25519 入場チケットの検証（正当は通し、期限切れ・改竄・別鍵は弾く）
- `test/bridge_test.exs` — feed→subject の割り当てと、NATS event をその feed の stream へ流す配線

behaviour 群はコンパイルが通り、跨りの型（`QuicTransport.stream()` 等）も解決する。

## まだやっていないこと（正直に）

- **CONNECT 以外のリクエストは 404**（WebTransport 専用）。
- **L2 の Plug 縫い目（`Karutte.WebTransportAdapter`）は別経路。** これは Bandit に WebTransport を
  載せる将来用の形で、いまの HTTP/3 サーバ（`Karutte.Http3.*`）は Bandit を介さず quicer に直に立つ。
- **HTTP/2 の床はブラウザ非対応のフォールバック。** datagram は擬似（信頼・順序つき）になる。
