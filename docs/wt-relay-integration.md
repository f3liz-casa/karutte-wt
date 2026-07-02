# karutte-wt ↔ wt-relay 連携メモ（karutte 側）

wt-relay（透過 L4 リレー＝貧者の Spectrum）に karutte-wt の origin を繋ぐときの、
**karutte 側で何を出す・変える・足すか**の研究。relay 側の設計（トポロジ・透過/SNAT・
実 IP 秘匿・flow attribution・QUIC-LB）は `../wt-relay/docs/edge-design.md` にあるので、
ここはその相方（origin 視点）。まだ実装前の段。

## 0. 前提（relay 側で決まっていること）

```
Client ──UDP/443──▶ Relay(公開IP) ──WireGuard──▶ Origin=karutte(wg0 10.9.0.2:443)
```

- データ面は**カーネル**（iptables DNAT / conntrack / WG）。karutte は WG の裏にいる
  ただの QUIC origin。relay の制御 daemon が落ちても転送は続く。
- 二つのモード:
  - **透過(A)**: relay は dst だけ DNAT、src はそのまま。**karutte が実クライアント IP を素で見る**。
  - **SNAT**: relay が src を relay の WG IP に書き換える。karutte はクライアント IP を知らない
    （＝origin IP を漏らせない、秘匿最強）。実 IP は制御面の attribution で回収（§3）。

karutte が公開 IP を持たない・ホスト名を処理しない・TLS を relay が終端しない、は relay 側の帰結。
karutte が要るのは「中立な証明書 ＋ WG アドレスで listen」だけ、が出発点。

## 1. まず素通しで動くために（透過・SNAT 共通）

quicer/karutte の実装で確認した、最小の手当て:

1. **WG アドレスで listen する。** quicer の `listen_on` は `port | "IP:Port"` を取れる
   （`quicer_types.hrl` `listen_on() :: inet:port_number() | string()`）。今の
   `Karutte.Http3.Server` は port 整数だけを `Karutte.Http3.Listener` に渡している。
   → Server/Listener に **bind アドレス（`"10.9.0.2:443"`）** を渡せる小追加。
   これで karutte は wg0 だけで待ち、eth0 直叩きには応えない（スキャンに沈黙、の app 側担保。
   カーネル側の eth0-drop と二重に効く）。

2. **中立な証明書。** `Karutte.Http3.Cert` は既に CN=localhost（origin 名/IP を含まない）。
   `serverCertificateHashes` でハッシュピンなので中身は漏れない。変更不要。
   本物の CA 証明書を使うなら `wt.f3liz.casa` 向けを直接渡す（CN は hash ピン時は無関係）。

3. **`preferred_address` を広告しない（確認済み §9）。** これが広告されると origin 実アドレスが
   載って完全バイパス＋露出になる。**quicer には設定する口が無い**（include/src/c_src 全走査で
   ゼロ）ので、karutte が誤って広告する経路が存在しない＝実質 OFF 確定。手当ては不要。

4. **アプリが返す URL に origin IP を書かない。** handler が URL を返すなら公開名
   `wt.f3liz.casa` だけ。これは実装規約（authorize/handler で守る）。

## 2. 実クライアント IP を handler へ（karutte 側のいちばんの肝）

karutte は今 `conn_info` に `path/authority/headers` を渡すが **peer アドレスを渡していない**。
`quicer:peername(conn)`（`remote_address` getopt）で取れるので、`accept_webtransport` で
`conn_info` に `:peer`（`{ip, port}`）を足す。

- **透過(A)モード**: これが**実クライアント IP**。handler の `authorize/1`（IP allow/deny）、
  レート制限、ログにそのまま使える。透過モードの一番のごほうび。
- **SNAT モード**: これは relay の WG:src-port。§3 の attribution で実 IP に解決する。

telemetry の `[:karutte, :http3, :session, :open]` meta にも `peer` を足すと、relay の
per-flow と突合できる（§6）。小追加、relay 非依存でも有益。

## 3. flow attribution の karutte 側（SNAT モードのときだけ）

SNAT の無漏洩を保ったまま実 IP を得る。IP をデータ経路でなく**制御経路**で運ぶ（edge-design.md §3）。
relay が `(dst-port, src-port[, dcid]) → client_ip` を push、karutte は表引き。

karutte 側に要るもの:

- **受け皿**: relay↔origin の distributed Erlang over WG（両端 BEAM）。karutte に小さな
  `Attribution`（ETS 表 + `client_of(peer_addr[, dcid])`）を置く。§2 の `peer`（= relay WG:src-port）
  がキーの索引。
- **DCID 照合は origin 側では組めない（確認済み §9）。** quicer は接続の生 DCID を返す getopt を
  持たない（`cid_prefix`＝設定側、`dest_cid_update_count`＝カウンタのみ）。だから
  「origin が届いたパケットの DCID を照合して帰属」は素の quicer では不可。
  → **origin 側の帰属は port（peer addr = relay WG:src-port）で引く**。port 再利用の曖昧性を
  詰めるなら **relay 側**（eBPF で wire から DCID を読み、`(dst-port,src-port,dcid)→ip` を
  relay の表で一意化してから push）に寄せる。origin は relay が解決済みの ip を受けるだけ。
  DCID を origin で使いたいなら quicer にパッチ（CID getopt 追加）が要る。
  → まず **port-only ＋短 conntrack timeout / epoch** から。edge-design.md の順序と揃う。
- **honest**: 透過(A)なら attribution は**丸ごと不要**（karutte が実 IP を直接見る §2）。
  秘匿最優先で SNAT を採るときだけ、この配線を足す。

## 4. conntrack timeout と QUIC keepalive の整合（見落としやすい）

relay の UDP conntrack エントリが QUIC の idle より先に消えると、DNAT マッピングが失われ、
以後のパケットが原路不明になる（Linux 既定 `nf_conntrack_udp_timeout` ~30s / stream ~120s）。

- karutte の `idle_timeout_ms` は 30s。無通信が続くと危うい。
- 手当て: **karutte 側で QUIC keepalive を張る**（**確認済み §9**）。`keep_alive_interval_ms` は
  listen_opt で、accept した接続に継承され、実際に接続を idle_timeout 超で生かす（実測: 有り＝生存 /
  無し＝idle で切断）。server 発 keepalive は origin→client 方向に流れ、relay で un-DNAT されて
  conntrack を**両方向で温存**する（conntrack は片方向のパケットで更新される）。
  → Server に `keep_alive_interval_ms`（例 15s、conntrack timeout の半分以下）option を足す。
  これは relay 非依存でも NAT 越え一般に効く。
- 代替: relay 側で conntrack UDP timeout を延ばす（infra 設定）。karutte keepalive のほうが自足的。

## 5. デプロイ協調（blue-green と drain）

karutte の `Server.drain`（GOAWAY ＋ 各セッションへ DRAIN capsule）と relay の route 切替の噛み合わせ:

- **blue-green**: 新 karutte を**別の WG addr:port**で上げ、relay の Spec を新 origin に向けて
  `reconcile_now`（原子 `iptables-restore` で DNAT 差し替え）。以後の**新規接続は新 origin** へ。
  既存の UDP flow は conntrack が旧 DNAT を保持するので**旧へ流れ続ける**（timeout / 明示終了まで）。
  その間に旧 karutte を `drain` して穏やかに終わらせる。→ karutte 側の追加手当ては不要（drain は既存）。
- **同 addr:port の単純再起動**: conntrack は生きたまま新プロセスが同ポートで listen。既存接続の
  QUIC 状態は新プロセスに無いので**接続はリセット**される（未知 DCID に Stateless Reset か無視）。
  穏やかにやりたいなら blue-green（別ポート）が要る。
- 運用の口: relay の Spec 切替＋`reconcile_now`。将来は制御 API（§7）に。

## 6. telemetry を一枚に

`[:karutte, :http3, …]`（session/stream/datagram/connection）と `[:wt_relay, …]`
（reconcile / route counters）を同じ PromEx に束ねる（両端 BEAM の利点）。

- 相関キー: karutte の `session:open` meta に `peer`（§2）を載せる ↔ relay の per-route counters
  / attribution push。per-flow の突合は **src-port（+ dcid）**。
- relay↔origin が distributed Erlang で繋がっていれば、片方の node で両方の telemetry を集約できる。

## 7. MTU（QUIC over WireGuard）

- client→relay は素の path（QUIC PMTUD、~1500）。relay→origin は WG 被せ（overhead ~60–80B）。
  DNAT はサイズ不変なので、client の大きめ packet が relay→origin の WG で MTU 超過し PTB(ICMP) が出る。
  → edge-design.md の **connmark で RELATED な ICMP を wg0 に戻す**前提が要る（relay/infra 側）。
- karutte 側: QUIC は 1200B 最小＋PMTUD で自律。特別な手当ては不要（初期 MTU を欲張らない＝msquic 既定）。
  主戦場は relay/WG の MTU 設定。

## 8. まとめ — karutte に足す小さな配線（優先順）

| # | 足すもの | 効果 | 規模 | 透過(A) | SNAT |
|---|----------|------|------|--------|------|
| 1 | `listen_on` に bind アドレス（WG だけで listen） | eth0 直叩きに応えない | 小 | 要 | 要 |
| 2 | `conn_info.peer`（`quicer:peername`）＋ telemetry meta | 実 IP を認証/制限/ログ/相関へ | 小 | **実 IP** | relay WG IP（§3 で解決） |
| 3 | `keep_alive_interval_ms` option | conntrack を温存（原路維持） | 小 | 有益 | 有益 |
| 4 | `lb_mode`/`cid_prefix` option ＋ attribution 受け表 | SNAT で実 IP 回収 | 中 | 不要 | 要（まず port-only） |

- **透過(A)** を採るなら **1〜3 だけ**で「実 IP が見えて WG 裏で安全に listen する karutte」が成立。
- **秘匿最優先(SNAT)** なら 4 を足す（まず port-only 帰属、DCID は窓が問題化してから）。
- どれも quicer/cowlib はいじらず、`Karutte.Http3.Server` の option ＋ `conn_info` ＋ 小モジュールで済む。
  データ面はカーネル・relay 側にあるので、karutte は「行儀のよい origin」であるだけでよい。

### 実装状況（2026-07-02）

- **1〜3 は実装＋テスト済み**（透過モードの karutte 側は揃った）:
  - `:bind` option（`Karutte.Http3.Server` / `Listener`）— `sockname` で 127.0.0.1 バインドを検証。
  - `conn_info.peer`（`quicer:peername`）＋ `[:session, :open]` telemetry meta に `peer`。
  - `:keep_alive_interval_ms` option — idle_timeout 超えでも接続生存をループバックで検証。
  - `mix test` 57 passed（ランダム順で安定）。
- **4（SNAT attribution）は未着手**。relay を立てる段で port-only から。origin 側 DCID 照合は
  quicer の制約（§9 #1）で不可なので relay/eBPF 側に寄せる。

## 9. 確認結果（2026-07-02、quicer 0.4.3 をソース＋実測）

- **#3 `preferred_address`: 口が無い＝安全（確定）。** quicer の include/src/c_src 全体に
  `preferred_address` の設定 API が一切無い。karutte が誤って広告する経路が存在しない
  ＝**実質 OFF 確定**。手当て不要（「明示的に入れない」も自動的に守られる）。
- **#2 `keep_alive_interval_ms`: listen_opt で有効・accept 接続に継承・実効（確定）。**
  型上 `?QUIC_SETTINGS_OPTS` ⊂ `listen_opts()`。実測（`idle_timeout_ms=2000` の listener に
  `keep_alive_interval_ms=500` を付け、client を 4 秒アイドル）: **keepalive 有り＝接続生存 /
  無し＝2s で切断**。→ server 発 keepalive が accept 接続に効き、conntrack 温存の土台になる（§4）。
- **#1 接続 DCID の getopt: 無い（確定）。origin 側 DCID 照合は素の quicer では不可。**
  quicer が出すのは `cid_prefix`（**設定**側、生成 CID に prefix を付ける）と
  `dest_cid_update_count`（**カウンタ**）だけ。接続の生 DCID を読む口は無い。
  → §3 の「origin がパケットの DCID を照合」は**そのままでは組めない**。attribution は
  **origin 側は port（peer addr = relay WG:src-port）で引く**のが現実解。DCID の曖昧性除去を
  やるなら **relay 側**（eBPF で wire から DCID を読む）に寄せ、origin は relay が解決した
  結果を受けるだけにする。または quicer にパッチ（CID を出す getopt 追加）。まず **port-only
  ＋短 conntrack timeout / epoch** で始める、が確定した結論。
- **#4 透過(A) で実 src が socket に乗るか: ここでは未検証（relay/WG 実機が要る）。**
  relay の `rp_filter=2`・connmark・policy-route を入れた上で、origin で `tcpdump`＋
  `quicer:peername/1` の突合が要る。実機を立てる段で確認する（edge-design.md §5-1）。

### 付随して分かったこと（`?QUIC_SETTINGS_OPTS` に居る、listen_opts で渡せる）

- `maximum_mtu` / `minimum_mtu`: §7 の WG 経路 MTU に効く。relay→origin の WG で頭打ちなら
  origin 側で `maximum_mtu` を絞れる（QUIC PMTUD 任せに加えて明示上限）。
- `migration_enabled`: QUIC の接続移行を切れる。conntrack/relay の安定を優先するなら検討材料。
- `load_balancing_mode`: per-configuration にも居る（edge-design.md は global env 版を採用）。

## 参照

- `../wt-relay/docs/edge-design.md`（relay 側の全体設計）、`../wt-relay/lib/wt_relay/{route,reconciler,kernel/iptables}.ex`
- quicer: `deps/quicer/src/quicer.erl`（`listen/2` listen_on、`peername/1`、`keep_alive_interval_ms`）
- 本 repo README（`Karutte.Http3.Server` の option、`conn_info`、`authorize/1`）
