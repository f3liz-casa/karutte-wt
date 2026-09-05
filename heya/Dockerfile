# heya を karutte:v1 の上に載せる。quicer(msquic)の焼き直しを避けるため、
# karutte の deps/_build をそのまま使い、heya は /app/lib を差し替えたうえで別プロジェクトとして乗る。
FROM karutte:v1
WORKDIR /app
# karutte 本体(lib)は手元の最新に差し替える(msquic には触れない)
COPY karutte/lib /app/lib
COPY karutte/mix.exs karutte/mix.lock /app/
# sukhi(Bridge / Ticket)も隣に置く。heya は ../sukhi ではなく KARUTTE_SUKHI_PATH で見る
WORKDIR /sukhi
COPY sukhi/mix.exs sukhi/mix.lock ./
COPY sukhi/lib lib
WORKDIR /heya
COPY heya/mix.exs ./
# lock は karutte のものから始める(同じ版の deps を使い回す)。足りない分だけ deps.get が足す
COPY karutte/mix.lock ./mix.lock
# karutte:v1 は dev で焼かれて dev で走っている。同じ _build/dev を使い回すので、こちらも dev
ENV MIX_ENV=dev HEYA_DEPS_PATH=/app/deps HEYA_BUILD_PATH=/app/_build KARUTTE_PATH=/app KARUTTE_SUKHI_PATH=/sukhi
RUN mix deps.get
COPY heya/lib lib
COPY heya/priv priv
RUN mix compile
CMD ["mix", "run", "--no-halt"]
