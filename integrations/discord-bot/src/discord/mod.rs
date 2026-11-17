//! Discord webhook handling, channel routing, tiered ACL, and interaction dispatch.

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

fn ephemeral_response(msg: &str) -> Result<Response> {
    Response::from_json(&json!({
        "type": 4,
        "data": {
            "content": msg,
            "flags": 64
        }
    }))
}

fn optional_var(env: &Env, name: &str) -> String {
    env.var(name)
        .map(|v| v.to_string().trim().to_string())
        .unwrap_or_default()
}

/// Enforces `#mc-commands` vs `#mc-chat` channel separation when channel IDs are configured.
pub fn check_channel_restriction(
    command: &str,
    channel_id: Option<&str>,
    command_channel_id: &str,
    chat_channel_id: &str,
) -> Option<String> {
    let cmd_ch = command_channel_id.trim();
    let chat_ch = chat_channel_id.trim();

    if command == "mc-say" {
        if !chat_ch.is_empty() && channel_id != Some(chat_ch) {
            return Some(format!("💬 Please use `/mc-say` in <#{chat_ch}>."));
        }
        return None;
    }

    if !cmd_ch.is_empty() && channel_id != Some(cmd_ch) {
        return Some(format!("⚙️ Please use server commands in <#{cmd_ch}>."));
    }

    None
}

/// Evaluates tiered ACL rules:
/// - Public guild commands (`mc-status`, `mc-players`, `mc-top`, `mc-say`): allowed for any guild member.
/// - Lifecycle commands (`mc-start`, `mc-stop`, `mc-backup`): allowed if `ALLOWED_USER_IDS` is empty, otherwise restricted.
/// - High-privilege admin commands (`mc-whitelist`, `mc-restart`, `mc-logs`, `mc-cmd`): fail closed if `ALLOWED_USER_IDS` is empty.
pub fn is_command_authorized(command: &str, allowed_ids_raw: Option<&str>, user_id: &str) -> bool {
    match command {
        "mc-status" | "mc-players" | "mc-top" | "mc-say" => true,
        "mc-whitelist" | "mc-restart" | "mc-logs" | "mc-cmd" => {
            let Some(raw) = allowed_ids_raw else {
                return false;
            };
            let has_any = raw
                .split([',', '\n'])
                .map(|s| {
                    s.trim().trim_matches(|c: char| {
                        matches!(c, '[' | ']' | '"' | '\'' | '\n' | '\r' | ' ' | '\t')
                    })
                })
                .any(|s| !s.is_empty());
            has_any && is_user_authorized(raw, user_id)
        }
        _ => match allowed_ids_raw {
            Some(raw) => is_user_authorized(raw, user_id),
            None => true,
        },
    }
}

/// Main entrypoint for processing incoming Discord webhook interactions.
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
        let command_channel_id = optional_var(&env, "COMMAND_CHANNEL_ID");
        let chat_channel_id = optional_var(&env, "CHAT_CHANNEL_ID");

        if let Some(redirect_msg) = check_channel_restriction(
            &command_name,
            interaction.channel_id.as_deref(),
            &command_channel_id,
            &chat_channel_id,
        ) {
            return ephemeral_response(&redirect_msg);
        }

        let allowed_ids = env.secret("ALLOWED_USER_IDS").ok().map(|s| s.to_string());
        let user_id = interaction.user_id().unwrap_or_default();
        if !is_command_authorized(&command_name, allowed_ids.as_deref(), user_id) {
            return ephemeral_response("⛔ You do not have permission to run this command.");
        }

        let caller_name = interaction.caller_display_name();
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
            command_channel_id,
            caller_name,
            command_data: interaction.data,
        };

        let agent_fetcher = env.service("MC_AGENT").ok();
        let agent_secret = env
            .secret("AGENT_SHARED_SECRET")
            .map(|s| s.to_string())
            .unwrap_or_default();

        // Respond immediately with deferred acknowledgment (type: 5) to satisfy Discord's < 3s SLA
        ctx.wait_until(async move {
            execute_command(&command_name, &cmd_ctx, agent_fetcher, agent_secret).await;
        });

        return Response::from_json(&json!({ "type": 5 }));
    }

    Response::error("Unknown interaction type", 400)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_channel_restriction_separates_commands_and_chat() {
        // /mc-say must be in chat_channel_id when configured
        assert!(
            check_channel_restriction("mc-say", Some("111"), "111", "222")
                .unwrap()
                .contains("<#222>")
        );
        assert!(check_channel_restriction("mc-say", Some("222"), "111", "222").is_none());

        // Operational commands must be in command_channel_id when configured
        assert!(
            check_channel_restriction("mc-players", Some("222"), "111", "222")
                .unwrap()
                .contains("<#111>")
        );
        assert!(check_channel_restriction("mc-players", Some("111"), "111", "222").is_none());

        // No restriction when unconfigured
        assert!(check_channel_restriction("mc-say", Some("999"), "", "").is_none());
        assert!(check_channel_restriction("mc-top", Some("999"), "", "").is_none());
    }

    #[test]
    fn test_tiered_acl_enforcement() {
        // Public commands open to any guild member even when allowed_user_ids is populated
        assert!(is_command_authorized("mc-status", Some("111"), "999"));
        assert!(is_command_authorized("mc-players", Some("111"), "999"));
        assert!(is_command_authorized("mc-top", Some("111"), "999"));
        assert!(is_command_authorized("mc-say", Some("111"), "999"));

        // Lifecycle commands open when empty, restricted when configured
        assert!(is_command_authorized("mc-start", Some(""), "999"));
        assert!(!is_command_authorized("mc-start", Some("111"), "999"));
        assert!(is_command_authorized("mc-start", Some("111"), "111"));

        // High-privilege commands fail closed when ALLOWED_USER_IDS is empty/missing
        assert!(!is_command_authorized("mc-cmd", None, "111"));
        assert!(!is_command_authorized("mc-cmd", Some("[]"), "111"));
        assert!(!is_command_authorized("mc-logs", Some(""), "111"));
        assert!(!is_command_authorized("mc-whitelist", Some("111"), "999"));
        assert!(is_command_authorized("mc-whitelist", Some("111"), "111"));
        assert!(is_command_authorized("mc-restart", Some("111"), "111"));
    }
}
