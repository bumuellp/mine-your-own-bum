# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
FROM --platform=$BUILDPLATFORM tonistiigi/xx:1.10.0@sha256:40fe21f44bb8cddf1eb1226db190d0a984118f62ee02a91b77d99448d28264a6 AS xx

FROM --platform=$BUILDPLATFORM rust:1.100-alpine3.21@sha256:9ebb58cb22e0b1d959d5cb58de06e8e45b67760c80eaccaf8b7bbc4dfc6c1be9 AS builder
ARG TARGETPLATFORM
COPY --from=xx / /
RUN apk add --no-cache clang lld && \
    xx-apk add --no-cache musl-dev gcc

WORKDIR /build
ENV XX_RUSTFLAGS="-C target-feature=+crt-static"

# 1. Dependency caching layer using dummy sources (native host speed via xx, no QEMU).
COPY Cargo.toml Cargo.lock ./
RUN xx-cargo --setup-target-triple && \
    TARGET="$(xx-cargo --print-target-triple)" && \
    mkdir -p src && \
    echo "pub fn _dummy() {}" > src/lib.rs && \
    echo "fn main() {}" > src/main.rs && \
    xx-cargo build --release --locked && \
    rm -rf src \
      "target/$TARGET/release/.fingerprint/mc-agent-"* \
      "target/$TARGET/release/deps/mc_agent"* \
      "target/$TARGET/release/deps/libmc_agent"* \
      "target/$TARGET/release/mc-agent"*

# 2. Build actual mc-agent binary statically linked against musl
COPY src ./src
RUN TARGET="$(xx-cargo --print-target-triple)" && \
    xx-cargo build --release --locked && \
    cp "target/$TARGET/release/mc-agent" /build/mc-agent

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=builder /build/mc-agent /mc-agent
USER 65532:65532
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/mc-agent", "--healthcheck"]
ENTRYPOINT ["/mc-agent"]
