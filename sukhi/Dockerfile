# A container for karutte-sukhi. Build from the monorepo root so ../core is in the context:
#   docker build -f sukhi/Dockerfile -t karutte-sukhi .
# quicer (msquic) is built from source, so cmake / build-essential / perl (openssl) are needed.
FROM hexpm/elixir:1.17.3-erlang-27.1.2-ubuntu-jammy-20260509

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     build-essential cmake ninja-build perl git openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

# core first: its mix.exs is what the path dep resolves to.
WORKDIR /app/core
COPY core/mix.exs core/mix.lock ./
COPY core/lib lib

WORKDIR /app/sukhi
COPY sukhi/mix.exs sukhi/mix.lock ./
RUN mix deps.get

COPY sukhi/lib lib
COPY sukhi/test test
# The quicer NIF (msquic + quictls) is built here. This is the slow step.
# run.exs is copied afterwards, so changing only run.exs does not rebuild msquic.
RUN mix compile
COPY sukhi/run.exs ./

# With WT_TICKET_PUBKEY set this runs the Bridge; without it, the echo server.
CMD ["sh", "-c", "mix run --no-halt run.exs"]
