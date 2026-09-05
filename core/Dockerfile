# A container for karutte-core. quicer builds msquic from source, so it needs
# cmake / build-essential / perl (openssl). Single stage, kept simple.
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
# The quicer NIF (msquic + quictls) is built here. This is the slow step.
# run.exs is copied afterwards, so changing only run.exs does not rebuild msquic.
RUN mix compile
COPY run.exs ./

# Start the echo server. WT_BIND / WT_PORT change where it listens.
CMD ["sh", "-c", "mix run --no-halt run.exs"]
