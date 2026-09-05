# wt-relay daemon(制御面)のイメージ。データ面はカーネルなので、これが落ちても転送は続く。
# 走らせ方: --network host --cap-add NET_ADMIN（ホストの netfilter を触るため）。
# runtime は builder と同じ ubuntu-jammy に合わせる（ERTS の共有ライブラリ整合）。
FROM hexpm/elixir:1.17.3-erlang-27.1.2-ubuntu-jammy-20260509 AS build

ENV MIX_ENV=prod
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

COPY config config
COPY lib lib
RUN mix deps.compile && mix compile && mix release

FROM ubuntu:22.04
# iptables は nf_tables バックエンド（ホスト Ubuntu 22.04 と一致）。ERTS 実行に要る系ライブラリも。
RUN apt-get update \
  && apt-get install -y --no-install-recommends iptables libncurses6 libstdc++6 libssl3 locales \
  && rm -rf /var/lib/apt/lists/*
ENV LANG=C.UTF-8
WORKDIR /app
COPY --from=build /app/_build/prod/rel/wt_relay ./
CMD ["bin/wt_relay", "start"]
