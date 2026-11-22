//! Discord webhook handling, channel routing, tiered ACL, and interaction dispatch.

pub mod client;
pub mod commands;
pub mod format;
pub mod models;

pub use client::update_deferred_response;
pub use commands::{
    AccessTier, ChannelScope, CommandContext, CommandSpec, SlashCommand, execute_command,
};
pub use format::{
    format_already_running_message, format_blocked_action, format_mods_hint, format_mods_message,
    format_status_message,
};
pub use models::Interaction;

use crate::auth::{is_user_authorized, verify_signature};
use crate::types::ModConfig;
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

/// Enforces `#mc-commands` vs `#mc-chat` channel separation based on `SlashCommand::channel_scope()`.
pub fn check_channel_restriction(
    command: SlashCommand,
    channel_id: Option<&str>,
    command_channel_id: &str,
    chat_channel_id: &str,
) -> Option<String> {
    let cmd_ch = command_channel_id.trim();
    let chat_ch = chat_channel_id.trim();

    match command.channel_scope() {
        ChannelScope::Chat => {
            if !chat_ch.is_empty() && channel_id != Some(chat_ch) {
                return Some(format!(
                    "💬 Please use `/{}` in <#{chat_ch}>.",
                    command.as_str()
                ));
            }
            None
        }
        ChannelScope::Commands => {
            if !cmd_ch.is_empty() && channel_id != Some(cmd_ch) {
                return Some(format!("⚙️ Please use server commands in <#{cmd_ch}>."));
            }
            None
        }
    }
}

/// Evaluates tiered ACL rules directly from `SlashCommand::access_tier()`:
/// - `AccessTier::Public`: allowed for any guild member.
/// - `AccessTier::Lifecycle`: allowed if `ALLOWED_USER_IDS` is empty, otherwise restricted.
/// - `AccessTier::AdminFailClosed`: fails closed if `ALLOWED_USER_IDS` is empty.
pub fn is_command_authorized(
    command: SlashCommand,
    allowed_ids_raw: Option<&str>,
    user_id: &str,
) -> bool {
    match command.access_tier() {
        AccessTier::Public => true,
        AccessTier::AdminFailClosed => {
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
        AccessTier::Lifecycle => match allowed_ids_raw {
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
        let raw_name = interaction.command_name().unwrap_or_default();
        let Some(command) = SlashCommand::parse(raw_name) else {
            return ephemeral_response("⚠️ Unknown slash command.");
        };

        let command_channel_id = optional_var(&env, "COMMAND_CHANNEL_ID");
        let chat_channel_id = optional_var(&env, "CHAT_CHANNEL_ID");

        if let Some(redirect_msg) = check_channel_restriction(
            command,
            interaction.channel_id.as_deref(),
            &command_channel_id,
            &chat_channel_id,
        ) {
            return ephemeral_response(&redirect_msg);
        }

        let allowed_ids = env.secret("ALLOWED_USER_IDS").ok().map(|s| s.to_string());
        let user_id = interaction.user_id().unwrap_or_default();
        if !is_command_authorized(command, allowed_ids.as_deref(), user_id) {
            return ephemeral_response("⛔ You do not have permission to run this command.");
        }

        let caller_name = interaction.caller_display_name();
        let mod_config = ModConfig {
            server_type: optional_var(&env, "MC_SERVER_TYPE"),
            modloader: optional_var(&env, "MC_MODLOADER"),
            mc_version: optional_var(&env, "MC_VERSION"),
            modrinth_modpack: optional_var(&env, "MC_MODRINTH_MODPACK"),
            client_required_mods: optional_var(&env, "MC_CLIENT_REQUIRED_MODS"),
            client_optional_mods: optional_var(&env, "MC_CLIENT_OPTIONAL_MODS"),
            server_only_mods: optional_var(&env, "MC_SERVER_ONLY_MODS"),
            curseforge_projects: optional_var(&env, "MC_CURSEFORGE_PROJECTS"),
        };
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
            mod_config,
            command_data: interaction.data,
        };

        let agent_fetcher = env.service("MC_AGENT").ok();
        let agent_secret = env
            .secret("AGENT_SHARED_SECRET")
            .map(|s| s.to_string())
            .unwrap_or_default();

        // Respond immediately with deferred acknowledgment (type: 5) to satisfy Discord's < 3s SLA
        ctx.wait_until(async move {
            execute_command(command, &cmd_ctx, agent_fetcher, agent_secret).await;
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
            check_channel_restriction(SlashCommand::Say, Some("111"), "111", "222")
                .unwrap()
                .contains("<#222>")
        );
        assert!(check_channel_restriction(SlashCommand::Say, Some("222"), "111", "222").is_none());

        // Operational commands must be in command_channel_id when configured
        assert!(
            check_channel_restriction(SlashCommand::Players, Some("222"), "111", "222")
                .unwrap()
                .contains("<#111>")
        );
        assert!(
            check_channel_restriction(SlashCommand::Players, Some("111"), "111", "222").is_none()
        );

        // No restriction when unconfigured
        assert!(check_channel_restriction(SlashCommand::Say, Some("999"), "", "").is_none());
        assert!(check_channel_restriction(SlashCommand::Top, Some("999"), "", "").is_none());
    }

    #[test]
    fn test_tiered_acl_enforcement() {
        // Public commands open to any guild member even when allowed_user_ids is populated
        assert!(is_command_authorized(
            SlashCommand::Status,
            Some("111"),
            "999"
        ));
        assert!(is_command_authorized(
            SlashCommand::Mods,
            Some("111"),
            "999"
        ));
        assert!(is_command_authorized(
            SlashCommand::Players,
            Some("111"),
            "999"
        ));
        assert!(is_command_authorized(SlashCommand::Top, Some("111"), "999"));
        assert!(is_command_authorized(SlashCommand::Say, Some("111"), "999"));

        // Lifecycle commands open when empty, restricted when configured
        assert!(is_command_authorized(SlashCommand::Start, Some(""), "999"));
        assert!(!is_command_authorized(
            SlashCommand::Start,
            Some("111"),
            "999"
        ));
        assert!(is_command_authorized(
            SlashCommand::Start,
            Some("111"),
            "111"
        ));

        // High-privilege commands fail closed when ALLOWED_USER_IDS is empty/missing
        assert!(!is_command_authorized(SlashCommand::Cmd, None, "111"));
        assert!(!is_command_authorized(SlashCommand::Cmd, Some("[]"), "111"));
        assert!(!is_command_authorized(SlashCommand::Logs, Some(""), "111"));
        assert!(!is_command_authorized(
            SlashCommand::Whitelist,
            Some("111"),
            "999"
        ));
        assert!(is_command_authorized(
            SlashCommand::Whitelist,
            Some("111"),
            "111"
        ));
        assert!(is_command_authorized(
            SlashCommand::Restart,
            Some("111"),
            "111"
        ));
    }
}
