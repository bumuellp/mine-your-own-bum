//! Cloudflare Worker in Rust: Discord Slash Command Handler for Minecraft Server Management
//!
//! Handles:
//! - Discord Ed25519 signature verification
//! - Discord Ping/Pong validation handshake
//! - Sub-3s SLA compliance via deferred response (`type: 5`)
//! - Direct TCP healthcheck (port 25565) to verify real-time Minecraft server status
//! - Concurrency check on GitHub Actions API before dispatching
//! - GitHub Actions workflow dispatch for `server-start.yml` and `server-stop.yml`

pub mod agent;
pub mod auth;
pub mod discord;
pub mod github;
pub mod minecraft;
pub mod types;

use worker::*;

#[event(fetch)]
async fn main(req: Request, env: Env, ctx: Context) -> Result<Response> {
    if req.method() != Method::Post {
        return Response::error("Method not allowed", 405);
    }

    discord::handle_interaction(req, env, ctx).await
}
