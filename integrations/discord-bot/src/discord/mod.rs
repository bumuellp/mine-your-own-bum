//! Discord webhook handling, interaction routing, and response updating

pub mod client;
pub mod commands;
pub mod format;
pub mod models;

pub use client::update_deferred_response;
pub use commands::{CommandContext, execute_command};
pub use format::{format_already_running_message, format_blocked_action, format_status_message};
pub use models::Interaction;

use crate::auth::{is_user_authorized, verify_signature};
use serde_json::json;
use worker::{Context, Env, Request, Response, Result};

/// Main entrypoint for processing incoming Discord webhook interactions
pub async fn handle_interaction(mut req: Request, env: Env, ctx: Context) -> Result<Response> {
    let headers = req.headers();
    let signature = match headers.get("X-Signature-Ed25519")? {
        Some(s) => s,
        None => return Response::error("Missing signature header", 401),
    };
    let timestamp = match headers.get("X-Signature-Timestamp")? {
        Some(t) => t,
        None => return Response::error("Missing timestamp header", 401),
    };

    let body = req.bytes().await?;
    let public_key = env.secret("DISCORD_PUBLIC_KEY")?.to_string();

    if !verify_signature(&public_key, &signature, &timestamp, &body) {
        return Response::error("Invalid request signature", 401);
    }

    let interaction: Interaction = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(_) => return Response::error("Invalid JSON body", 400),
    };

    // Discord PING verification (type: 1) -> responds with PONG (type: 1)
    if interaction.interaction_type == 1 {
        return Response::from_json(&json!({ "type": 1 }));
    }

    // Discord APPLICATION_COMMAND (type: 2)
    if interaction.interaction_type == 2 {
        let command_name = interaction.command_name().unwrap_or_default().to_string();

        // Optional ACL check: verify if invoking user is authorized
        if let Ok(allowed_ids_var) = env.secret("ALLOWED_USER_IDS") {
            let user_id = interaction.user_id().unwrap_or_default();
            if !is_user_authorized(&allowed_ids_var.to_string(), user_id) {
                return Response::from_json(&json!({
                    "type": 4,
                    "data": {
                        "content": "⛔ You do not have permission to manage this Minecraft server.",
                        "flags": 64 // Ephemeral message (only caller can see)
                    }
                }));
            }
        }

        let cmd_ctx = CommandContext {
            owner: env.var("GITHUB_OWNER")?.to_string(),
            repo: env.var("GITHUB_REPO")?.to_string(),
            fqdn: env.var("SERVER_FQDN")?.to_string(),
            pat: env.secret("GITHUB_PAT")?.to_string(),
            app_id: env.secret("DISCORD_APPLICATION_ID")?.to_string(),
            token: interaction.token.unwrap_or_default(),
            server_location: env
                .var("SERVER_LOCATION")
                .map(|v| v.to_string())
                .unwrap_or_else(|_| "fsn1".to_string()),
        };

        // All operational commands respond immediately with deferred acknowledgment (type: 5)
        // to strictly meet Discord's < 3.0s SLA while background ping and dispatch run.
        ctx.wait_until(async move {
            execute_command(&command_name, &cmd_ctx).await;
        });

        // Immediate deferred acknowledgment (< 3s SLA)
        return Response::from_json(&json!({ "type": 5 }));
    }

    Response::error("Unknown interaction type", 400)
}
