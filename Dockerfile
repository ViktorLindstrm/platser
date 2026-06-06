# ---- Build Stage ----
ARG ELIXIR_VERSION=1.20.0-rc.3
ARG OTP_VERSION=28.0
ARG DEBIAN_VERSION=bookworm-20260316-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && \
    apt-get install -y build-essential git curl nodejs npm && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY assets assets
COPY priv priv
COPY lib lib
RUN cd assets && npm ci
RUN mix compile
RUN mix assets.deploy


COPY config/runtime.exs config/

RUN mix release


# ---- Runtime Stage ----
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

RUN chown nobody /app

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/platser ./

COPY --chown=nobody:root bin/docker-entrypoint.sh ./bin/

RUN chmod +x ./bin/docker-entrypoint.sh

USER nobody

ENV PHX_SERVER=true

EXPOSE 4000

ENTRYPOINT ["./bin/docker-entrypoint.sh"]
