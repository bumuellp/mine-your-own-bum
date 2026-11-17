# syntax=docker/dockerfile:1
FROM rust:1.99-alpine3.21 AS builder
WORKDIR /build
RUN apk add --no-cache musl-dev cmake

# 1. Dependency caching layer using dummy sources.
# Passing --target separates host proc-macro compilation from static target linking.
COPY Cargo.toml Cargo.lock ./
RUN TARGET="$(rustc -vV | awk '/^host:/ {print $2}')" && \
    mkdir -p src && \
    echo "pub fn _dummy() {}" > src/lib.rs && \
    echo "fn main() {}" > src/main.rs && \
    RUSTFLAGS="-C target-feature=+crt-static" cargo build --release --locked --target "$TARGET" && \
    rm -rf src \
      "target/$TARGET/release/.fingerprint/mc-agent-"* \
      "target/$TARGET/release/deps/mc_agent"* \
      "target/$TARGET/release/deps/libmc_agent"* \
      "target/$TARGET/release/mc-agent"*

# 2. Build actual mc-agent binary statically linked against musl
COPY src ./src
RUN TARGET="$(rustc -vV | awk '/^host:/ {print $2}')" && \
    RUSTFLAGS="-C target-feature=+crt-static" cargo build --release --locked --target "$TARGET" && \
    cp "target/$TARGET/release/mc-agent" /build/mc-agent

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /build/mc-agent /mc-agent
USER 65532:65532
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/mc-agent", "--healthcheck"]
ENTRYPOINT ["/mc-agent"]
