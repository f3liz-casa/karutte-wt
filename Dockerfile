# karutte-wt を走らせる箱。quicer(msquic) をソースからビルドするので、
# cmake / build-essential / perl(openssl) が要る。単一ステージ（origin の spike なので素直に）。
FROM hexpm/elixir:1.17.3-erlang-27.1.2-ubuntu-jammy-20260509

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     build-essential cmake ninja-build perl git openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get

COPY lib lib
COPY test test
# quicer の NIF（msquic + quictls）をここでビルド。時間がかかる所。
# run.exs はこの後に COPY ＝ run.exs だけ変えても msquic の再ビルドにならない。
RUN mix compile
COPY run.exs ./

# 既定は echo サーバを上げる。WT_BIND / WT_PORT で listen 先を差し替え。
CMD ["sh", "-c", "mix run --no-halt run.exs"]
