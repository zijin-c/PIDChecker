# syntax=docker/dockerfile:1
# PID Checker headless server (pkc) for Linux. Listens on 8675.
#
#   docker compose up -d --build
#   docker compose logs pidchecker | grep -A1 "API key"     # first-run keys
#
# Legacy (Win7 / Office 2010) keys need Windows' pidgenx.dll and are not supported here.

FROM rust:1-bookworm AS build
WORKDIR /src
RUN apt-get update \
 && apt-get install -y --no-install-recommends pkg-config libssl-dev \
 && rm -rf /var/lib/apt/lists/*
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --release --locked --no-default-features --bin pkc \
 && install -D -m 0755 target/release/pkc /out/pkc

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libssl3 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 10001 pidchecker \
 && useradd --system --uid 10001 --gid pidchecker --home-dir /var/lib/pidchecker --no-create-home --shell /usr/sbin/nologin pidchecker \
 && install -d -m 0750 -o pidchecker -g pidchecker /var/lib/pidchecker
COPY --from=build /out/pkc /opt/pidchecker/pkc
COPY --from=build /src/data /opt/pidchecker/data
COPY --chmod=0755 deploy/docker-entrypoint.sh /usr/local/bin/pidchecker-entrypoint

ENV PORT=8675 \
    PUBLIC_CHECK=false \
    ONLINE_CHECK=true \
    TRUST_PROXY_HEADERS=false \
    RUST_LOG=info

USER pidchecker
WORKDIR /var/lib/pidchecker
VOLUME ["/var/lib/pidchecker"]
EXPOSE 8675
STOPSIGNAL SIGINT
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["/opt/pidchecker/pkc", "-c", "/var/lib/pidchecker/config.toml", "--log-level", "error", "status"]
ENTRYPOINT ["/usr/local/bin/pidchecker-entrypoint"]
CMD ["serve"]
