# WT edge 設計メモ — 透過 L4 リレー＋実 IP 保存＋秘匿

karutte-wt の WebTransport を、Cloudflare で秘匿された origin(ARM) に通すための「貧者の
Spectrum」の設計記録。会話で詰めた決定とトレードオフを、後で拾えるように残す。関連:
`../README.md`（この relay）、karutte 本体は `../../README.md`。

## 0. 目的とトポロジ

karutte(WT/QUIC over HTTP/3) の origin を CF の裏に隠したまま、ブラウザからの UDP/443 を
通す。CF は WT を origin へ運ばず、Spectrum(UDP) は Enterprise。だから **使い捨て VPS(x64)
を前段の L4 リレーにして、WireGuard で origin(ARM) に流す**。

```
Client(C) ──UDP/443──▶ Relay=x64(公開IP <relay-public-ip>) ──WireGuard──▶ Origin=ARM(karutte)
                        wg0=10.9.0.1                        wg0=10.9.0.2:443
```

- 晒れるのは使い捨て x64 の IP。origin(ARM) の IP は WG の裏。
- x64 は watch-mjw を退役させて空けた箱（OCI Always Free の x64 micro、1 OCPU/1GB）。
  ※ 実 IP / SSH ユーザー・鍵 / secret は**この repo に書かない**（IP 秘匿が目的なのに履歴に焼くと本末転倒）。
  具体値は infra 側の gitignore された設定に置く。

### 公開名と証明書の所有が割れる(透過 L4 の帰結)

普通の L7 リバースプロキシは「プロキシがホスト名も証明書も持つ」。透過 L4 は TLS を終端
しない(終端＝QUIC スタック＝レベル1、避ける)ので、所有が分かれる:

| もの | 持ち主 | 理由 |
|------|--------|------|
| DNS `wt.f3liz.casa` A → `<relay-public-ip>` | **relay** | 公開の顔。origin IP を DNS に出さない。DNS-only(グレー、CF は QUIC を運ばない) |
| ホスト名の処理 | どちらもしない | relay は UDP/443 を L4 素通し(SNI は暗号化＋ハッシュピンで判定不要) |
| TLS/QUIC 証明書 | **origin(karutte)** | 透過なので karutte が終端。karutte が鍵を持ち提示(自己署名・`serverCertificateHashes`・ホスト名検証なし) |
| アプリ URL 内の名前 | `wt.f3liz.casa` | 出すなら公開名。origin IP は書かない |

→ `wt.f3liz.casa` の DNS は **relay(infra)側**の設定。karutte(origin) が要るのは「証明書＋
`10.9.0.2` で listen」だけ。karutte は自分の公開 IP を持たない。

## 1. 核の原則 — データ面はカーネル、制御面は庭師

パケット転送は **カーネル**(iptables DNAT / conntrack / WireGuard)。userspace を通らない。
だから制御 daemon(wt-relay, BEAM)が落ちても `WT_RELAY` チェーンは残り、relay は流し続ける。
制御面は「門番」でなく「庭師」＝ルールを整え観測するだけ。最前線の 1 コア箱に常駐 daemon を
置いても安全なのはこの分業のおかげ。**この一線(データ面をカーネルに保つ)を破らない**限り、
上にいくら機能を積んでも前線は太らない。

言語が Elixir なのはこの理由: 「BEAM は重い」は誤り(watch-mjw が 1GB 箱で CPU4% を実証、
かつデータ面は userspace 非経由)。daemon の親切な制御(OTP supervision)＋telemetry、そして
karutte と同言語で relay↔origin を一枚の制御面に束ねられる。

## 2. 実 IP 保存 vs 秘匿 — モードの選択

### 案A: 透過(SNAT しない)
relay は **dst だけ DNAT**(→origin WG IP)、**src は書き換えない**。origin は wg0 で実
クライアント src を受ける。karutte の socket に実 IP が乗る。返りは conntrack が自動 un-DNAT。

要る手当て(origin 側):
- `rp_filter` を loose(2)。strict だと wg0 に来る「src=公開クライアント IP」を落とす
  (逆経路が eth0 なので)。効き値は `max(all, iface)` なので **all も 2** に。
- WG は `Table = off`＋policy-route。既定ルートを wg0 に化けさせない(origin の通常内向を守る)。
  返り(src=10.9.0.2)を `ip rule from 10.9.0.2 lookup <t>` → `default dev wg0`。
- origin の peer AllowedIPs = `0.0.0.0/0`(任意クライアント src をトンネルから受けるため)。

漏洩面(透過の弱点): origin が**クライアント宛に出す**ので、はぐれパケットが origin IP を漏らす。
- **ICMP エラー(PTB/unreachable)** が eth0 から出ると漏れる。src ベース rule では拾えない。
  → **connmark で flow ごと縛る**: `-t mangle -A PREROUTING -i wg0 -j CONNMARK --set-mark 0x1`
  / `-t mangle -A OUTPUT -j CONNMARK --restore-mark` / `ip rule fwmark 0x1 lookup <t>`。
  これで RELATED な ICMP も wg0 経由に。
- **直接スキャン確定**を防ぐ: origin の UDP/443 を **eth0 で drop、wg0 でだけ許可**。スキャナは
  沈黙しか得ない。WG 51820 は開くが WG は非ピアに無応答なので確認材料にならない。

### 案SNAT: relay が src をリレー WG IP に書き換える
origin は **クライアント IP を一度も知らず、クライアント宛に一度も出さない**。→ **原理的に
origin IP を漏らせない**(宛先にクライアントが登場しない)。ICMP も preferred_address も無効化。
代償: origin で実クライアント IP が取れない(→ §3 で回収)。

### モード無関係に必須(QUIC 固有)
- **`preferred_address` を OFF**。QUIC サーバは「この別アドレスに移って」を自分から広告できる。
  origin 実アドレスが載ると**完全バイパス＋露出**。msquic 既定 OFF のはず、明示設定しないこと。
- **中立な自己署名証明書**(CN/SAN に origin 名/IP を入れない。`Karutte.Http3.Cert` は CN=localhost)。
  `serverCertificateHashes` はハッシュピンなので中身は漏れない。アプリ URL は全部 `wt.f3liz.casa`。

### 決定
**秘匿最優先なら SNAT モード＋relay 側で防御/ログ**(origin はクライアントを知らない＝漏らせない)。
透過は「origin アプリに実 IP をどうしても渡したい」ときに、上の穴(connmark/eth0-drop)を全部
塞いで採る。**まず透過で "漏らさない透過" を一度組んで tcpdump で eth0 に origin 発が出ない
のを目視** → その後 §3 の attribution へ、が学びの多い順序。

## 3. Flow attribution — SNAT のまま実クライアント IP を origin に渡す

SNAT モードの無漏洩性を保ったまま実 IP を得る。**IP をデータ経路でなく制御経路で運ぶ**。
relay は「flow-ID → client IP」を制御面(relay↔origin の distributed Erlang over WG)で push、
origin は表引きで帰属。origin は依然クライアント宛に出さない＝漏らせない。

### キー: relay の SNAT 送信元ポート
relay の conntrack が既に `(client) ↔ (relay-WG:port)` を持つ。origin から見えるのは
`relay-WG:port` だけなので、**キーは src-port**。netfilter は返り tuple を一意に保つので、
**同一 dst(origin:443) 内で port は同時刻一意**(衝突しない)。

honest な穴:
1. **複数 route**: port 単独は不足(dst が違えば port 重複可)。→ キーは **(dst-port, src-port)**。
2. **時間方向の再利用**(本命): flow 終了→port 解放→別クライアントに再利用。origin の表が stale
   だと **誤帰属**。→ DESTROY 即 push＋短 UDP conntrack timeout で緩和。完全には消えない。
3. **~64k 天井**: destination 毎のポート空間が同時接続上限。超過は新規 drop(衝突でなく枯渇)。
4. **first-packet race**: マッピングがデータより遅れる。→ 後追い帰属(ログなら十分)。
5. state/DDoS: 全パケットに表を作ると増幅。→ **relay の Retry/rate-cap を通った正規 flow だけ**
   push(防御を relay に置く効果がここでも効く)。

### 再利用の穴を潰す: DCID 照合は **relay 側**(2026-07-02 訂正)

当初「origin が届いたパケットの DCID を port エントリと照合して stale を弾く」と書いたが、
**quicer は origin で接続の生 DCID を読む getopt を持たない**(2026-07-02、quicer 0.4.3 を
ソース＋実測で確認。出すのは `cid_prefix`=設定側 と `dest_cid_update_count`=カウンタのみ。
詳細 `../../docs/wt-relay-integration.md §9`)。**だから origin 側 DCID 照合は素の quicer
では組めない**。正しい形:

- **origin 側は port だけで引く**(peername = `relay-WG:src-port`)。DCID に触れない。origin から
  見たキーは **(dst-port, src-port)**。
- **DCID の曖昧性除去は relay 側**。relay が eBPF で wire から DCID を読み、conntrack イベント時に
  `(dst-port, src-port, dcid)` を一意化してから **解決済みの client IP を push**。port 再利用は relay
  側で「別 DCID＝別 flow」として捌かれ、relay が port→ip を更新する。origin は port を引くだけで常に
  relay の最新解決を得る。**staleness を弾く責務は relay(push を新鮮に保つ＋DESTROY で無効化)に移る**。
- origin で DCID を直に使いたいなら **quicer にパッチ**(接続 DCID の getopt 追加)が要る。
- **まず port-only ＋短 conntrack timeout / epoch** から。DCID(eBPF)は port 再利用の窓が実際に
  問題化してから足す(そのとき relay の L4 Retry/rate-cap 防御も同じ eBPF で兼用して元を取る)。

### QUIC を relay がどこまで読むか(段階)
- レベル1(重い): 接続追跡・ローテ追従・可変長 CID・frame 解析＝QUIC スタック。避ける。
- レベル2(port 読みと同程度): 「先頭＋固定 N バイトを DCID として掴む」。状態機械なし。
- port-only は **payload を読まない**(conntrack がタダでくれる)。DCID は payload なので、
  DCID 照合は relay をレベル2に上げる(port-only より一段重い)。読むのは制御面のみ
  (データ面はカーネルのまま)。eBPF(XDP/tc、in-kernel、非 proxy) or first-packet sniff で。

### 可変長 DCID を単純パースできるか(QUIC 仕様)
- **Long header(ハンドシェイク)**: DCID Length が明示(1 byte、RFC 9000 §17.2)。任意長を読める。
- **Short header(1-RTT の大半)**: DCID 長がワイヤに無い(§17.3、意図的な opacity)。純ステートレスでは
  任意長を復元できない。**サーバ協力が要る**。
- 逃げ道: **QUIC-LB**(`draft-ietf-quic-load-balancers`)＝サーバが CID に長さ/routing を自己
  エンコード。ただし draft は **v21 まで成熟したが expired/非RFC**。**閉じたペア(relay も karutte も
  自分のもの)では draft ステータスは無関係**——自分で決めた CID エンコードを両端で凍結すればよい。

### msquic/quicer が既に持っていた(2026-07-01 確認)
- **quicer は LoadBalancingMode を露出**: アプリ env `lb_mode`(`quicer_nif.erl:200`
  `application:get_env(quicer, lb_mode, 0)` → `load_balacing_mode` → global settings
  `QUIC_PARAM_GLOBAL_LOAD_BALACING_MODE`)。値: `DISABLED=0 / SERVER_ID_IP=1 /
  SERVER_ID_FIXED=2 / IFIP_AS_SERVER_ID=100`。C 側は `lb_mode > 3` ならその値を
  **FixedServerID** として扱う(`quicer_nif.c:1275-1325`)。
- **CID prefix も露出**: `QUIC_PARAM_REGISTRATION_CID_PREFIX`(`quicer_nif.c:191`)。
- **明示的 CID 長設定は無し**。msquic の生成 CID 長は決定的、LB モードで構造既知。**相対的に
  Server ID(byte 1-4)は単一 origin では識別に使わない**——per-connection 指紋は full DCID(nonce 部)。
  LB モードが買うのは「決定的で読める CID 長・構造」。
- **結論**: 可変長 → **固定長 CID で単純パース**は、**quicer をいじらず** `application:set_env(quicer,
  lb_mode, …)`(＋必要なら cid_prefix)で成立。有効化は低リスク(CID を構造化するだけ、QUIC 動作不変、
  クライアントには依然 opaque)。**残り確認は実 CID を一個キャプチャ**して長さ/構造を目視するだけ
  (quicer の制約でなく確認作業)。

## 4. 決定のまとめ

- 秘匿は **SNAT モード＋relay 側防御** が最強かつ単純(origin はクライアントを知らない)。透過は
  穴を全部塞ぐ覚悟のとき。
- attribution は **まず port(peername)-only で始める**(relay を純 conntrack に保つ。origin は
  DCID を読めないので必然)。**DCID の曖昧性除去は窓が実際に問題化してから relay 側の eBPF で**足す
  (origin では quicer 制約で不可、要れば quicer パッチ)。その eBPF は L4 Retry/rate-cap 防御も
  兼ねるので元が取れる。`lb_mode`(§3.5)は relay が CID を読める形にするための設定で、**origin 側の
  DCID 読み取りを可能にするものではない**。
- 防御(QUIC Retry / ハンドシェイク rate-cap / クールタイム)は **relay 側**(実 IP がタダで見える、
  暗号の前で刈れる)。fallback は SSE(CF 保護の床、[[sukhi-fedi-webtransport]] の二層と合流)。
- 制御面は **Elixir daemon(wt-relay)**。所有チェーン `WT_RELAY` を `iptables-restore` で原子
  差し替え、失敗しても落ちない。telemetry は `[:wt_relay, …]` → PromEx で karutte と一枚に。

## 5. 未解決 / 次の一手(karutte を relay に繋ぐ段でやる)

1. `infra/` に relay/origin 分岐の**冪等セットアップスクリプト**(WG・iptables・sysctl・
   policy-route)。まず SNAT or 透過で素通しを一度通し、**tcpdump で eth0 に origin 発が出ない**
   のを確認。
2. wt-relay の **origin role**(connmark/eth0-drop/rp_filter/policy-route を宣言的に)。
3. **実 CID キャプチャ**(karutte で `lb_mode` 有効化 → tcpdump/loopback で DCID の長さ・構造確認)。
4. wt-relay の **flow-attribution**(relay: conntrack `-E` の NEW/DESTROY を BEAM Port で読み、
   `(dst-port, src-port) → client_ip` を push。dcid は relay 内部の曖昧性除去用 / origin: port で
   表引き `client_of(peer)`)。粒度・epoch・DCID(relay 側)の採否はここで。
5. **eBPF**(必要になったら): L4 Retry/rate-cap 防御＋DCID 抽出を兼ねる。
6. **PromEx 配線**で karutte の telemetry と統合、relay↔origin を一枚で観測。
7. OCI セキュリティリスト(UDP 443 / 51820)、CID の `preferred_address` OFF 確認。

## 参照

- RFC 9000 §17.2(long header, DCID Length 明示) / §17.3(short header, 長さ暗黙) / §5.1(CID opacity)
- draft-ietf-quic-load-balancers(v21, expired/非RFC): https://datatracker.ietf.org/doc/draft-ietf-quic-load-balancers/
- MsQuic Deployment(LoadBalancingMode / Server ID in CID): https://github.com/microsoft/msquic/blob/main/docs/Deployment.md
- quicer: `deps/quicer/src/quicer_nif.erl:200`, `c_src/quicer_nif.c:1275-1325`, `include/quicer.hrl:143-147`
- 関連メモ: karutte-wt、sukhi-fedi-webtransport、watch-mjw-arm-migration
