# mc-agent Sidecar Daemon

A minimal, static Rust (`musl` + `distroless/nonroot`) sidecar container running alongside the Minecraft server on the isolated `mc-net` Docker network. Connected privately to the Cloudflare Worker via `cloudflared` and **Cloudflare Workers VPC** (`MC_AGENT` service binding) with **zero public ports exposed**.

## Capabilities

- **RCON Management API** (`/api/players`, `/api/whitelist/*`, `/api/backup`, `/api/restart`, `/api/cmd`, `/api/say`): Executes Minecraft RCON commands using `serde_json`-escaped `tellraw` for chat messages and strict username validation.
- **Host & World Telemetry** (`/api/top`): Reads `/proc/loadavg`, `/proc/meminfo`, `/proc/uptime`, world `/data` disk usage (`statvfs`), and live player counts.
- **Sanitized Log Tailing** (`/api/logs?lines=N`): Tails `/data/logs/latest.log`, strips ANSI sequences, and redacts IPv4 addresses while preserving version numbers.
- **Loader-Agnostic Live Chat Bridge**: Parses Vanilla, Fabric, NeoForge, and Paper `latest.log` lines for player chat, join, and leave events and posts them asynchronously to `DISCORD_CHAT_WEBHOOK_URL` (`allowed_mentions: { "parse": [] }`).
- **One-Time Boot Notification**: Posts a rich "Minecraft Server is ONLINE & Ready!" embed to `DISCORD_COMMAND_WEBHOOK_URL` once startup completes (with exponential backoff retry and `/tmp/mc-agent-boot-notified` idempotency marker).

## Authentication & Security

- `GET /healthz` is unauthenticated for Docker container healthchecks.
- All `/api/*` endpoints require `Authorization: Bearer <AGENT_SHARED_SECRET>` verified using constant-time byte comparison.
- Container runs as UID/GID `65532:65532` (`gcr.io/distroless/static-debian12:nonroot`).
- Outbound HTTPS webhook delivery uses `rustls` + `ring` (zero OpenSSL or AWS-LC C dependencies).

## Multi-Arch Docker Build

Built natively for `linux/amd64` and `linux/arm64` via `tonistiigi/xx` (`--platform=$BUILDPLATFORM`) so both architectures compile at native host speed without QEMU emulation:

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t mc-agent:local integrations/mc-agent
```

Unit tests & linting:

```bash
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```
