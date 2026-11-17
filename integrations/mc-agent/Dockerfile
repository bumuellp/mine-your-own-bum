# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM tonistiigi/xx:1.6.1 AS xx

FROM --platform=$BUILDPLATFORM rust:1.99-alpine3.21 AS builder
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

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /build/mc-agent /mc-agent
USER 65532:65532
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/mc-agent", "--healthcheck"]
ENTRYPOINT ["/mc-agent"]
