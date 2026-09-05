import Config

# 望ましい状態（routes）。ここを変えて置くだけで daemon が収束する（= 宣言的）。
# karutte を x64 に直載せしたので、転送(dnat)ではなく **observe**（udp/443 を L4 で数えるだけ）。
# raw=毎パケット量 / mangle=新規フローレート で、暗号の手前から flood を見る。
config :wt_relay, :routes, [
  %{name: "karutte-wt", proto: :udp, listen_port: 443, mode: :observe}
]

config :wt_relay, :reconciler, interval_ms: 10_000, dry_run: false
config :wt_relay, :observer, interval_ms: 5_000

# relay の箱でだけ true。dev/test では daemon を起こさない（iptables を触らせない）。
config :wt_relay, :enabled, true

if config_env() == :test, do: import_config("test.exs")
