defmodule WtRelay do
  @moduledoc """
  透過 L4(WireGuard)リレーの、親切な制御面。

  relay の公開ポートに来た UDP/TCP を、src IP を保ったまま(透過)WG の向こうの origin へ
  DNAT で渡す ── その「望ましい状態」を宣言(spec)から reconcile し、telemetry を出す
  daemon。データ面(DNAT/conntrack/WG)は**カーネル**に居るので、この daemon が落ちても
  転送は止まらない。制御面は庭師で、門番ではない。

  役割:

    * `WtRelay.Spec`             … 望ましい routes を宣言から読む
    * `WtRelay.Reconciler`       … tick で spec に収束（原子適用・失敗しても落ちない）
    * `WtRelay.Kernel.Iptables`  … 所有チェーン `WT_RELAY` を丸ごと組み直す
    * `WtRelay.Observer`         … カウンタを読んで `[:wt_relay, …]` telemetry を出す

  まだ無い（正直に）: origin role(policy-route/rp_filter の宣言的管理)、wg peer 管理、
  conntrack/wg の telemetry、rollback-on-unhealthy、PromEx 配線、preserve_ip=false の SNAT。
  詳しくは README。
  """
end
