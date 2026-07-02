import Config

# テストでは daemon(Reconciler/Observer)を起こさない。カーネルを触る所は
# Cmd を差し替えて単体で確かめる。
config :wt_relay, :enabled, false
