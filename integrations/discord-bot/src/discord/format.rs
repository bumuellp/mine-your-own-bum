//! Pure markdown message formatters for Discord slash command responses

use crate::agent::{AgentError, AgentPlayers, AgentSystem};
use crate::types::{ActiveWorkflow, ModConfig};

const DISCORD_SAFE_MSG_LIMIT: usize = 1900;

/// Formats a concise 1-line client mod reminder for `/mc-start` when client mods are required.
pub fn format_mods_hint(cfg: &ModConfig) -> String {
    if !cfg.requires_client_mods() {
        return String::new();
    }
    let extra_count = cfg.required_modrinth_mods().len() + cfg.client_curseforge_mods().len();
    let mp = cfg.modrinth_modpack.trim();
    let summary = match (!mp.is_empty(), extra_count) {
        (true, 0) => format!("`{mp}`"),
        (true, n) => format!("`{mp}` (+{n} extra mods)"),
        (false, n) => format!("{n} required mods"),
    };
    format!(
        "\n📦 **Client Mods Required:** {summary} — run `/mc-mods` for download links & launcher slugs."
    )
}

/// Formats the full `/mc-mods` response with loader, version, clickable Modrinth/CurseForge URLs, optional/server mods, and launcher slugs.
pub fn format_mods_message(cfg: &ModConfig) -> String {
    let loader = if cfg.server_type.trim().is_empty() {
        "FABRIC"
    } else {
        cfg.server_type.trim()
    };
    let ver = if cfg.mc_version.trim().is_empty() {
        "LATEST"
    } else {
        cfg.mc_version.trim()
    };

    let mut out = format!(
        "📦 **Client Setup & Mods (`/mc-mods`)**\n\
         • **Server Type / Loader:** `{loader}` (Minecraft `{ver}`)\n"
    );

    let mut slugs_for_copy = Vec::new();
    if !cfg.requires_client_mods() {
        out.push_str(&format!(
            "✅ **No client mods required to join!** You can connect directly using a standard Vanilla Minecraft `{ver}` client.\n"
        ));
    } else {
        let mp = cfg.modrinth_modpack.trim();
        if !mp.is_empty() {
            let mp_slug = mp.split(':').next().unwrap_or(mp).trim();
            out.push_str(&format!(
                "• **Base Modpack (Modrinth — Required):** [{mp_slug}](<https://modrinth.com/modpack/{mp_slug}>) (`{mp}`)\n"
            ));
            slugs_for_copy.push(mp.to_string());
        }

        let mr_mods = cfg.required_modrinth_mods();
        if !mr_mods.is_empty() {
            out.push_str("\n**Required Modrinth Mods (Must Install to Join):**\n");
            for m in &mr_mods {
                let slug = m.split(':').next().unwrap_or(m).trim();
                out.push_str(&format!(
                    "• [{slug}](<https://modrinth.com/mod/{slug}>) (`{m}`)\n"
                ));
                slugs_for_copy.push(m.clone());
            }
        }

        let cf_mods = cfg.client_curseforge_mods();
        if !cf_mods.is_empty() {
            out.push_str("\n**Required CurseForge Mods (Must Install to Join):**\n");
            for c in &cf_mods {
                let slug = c.split(':').next().unwrap_or(c).trim();
                out.push_str(&format!(
                    "• [{slug}](<https://www.curseforge.com/minecraft/mc-mods/{slug}>) (`{c}`)\n"
                ));
                slugs_for_copy.push(format!("curseforge:{c}"));
            }
        }
    }

    let opt_mods = cfg.optional_modrinth_mods();
    if !opt_mods.is_empty() {
        out.push_str(
            "\n**✨ Optional Client Mods (Supported on Client, Not Required to Join):**\n",
        );
        for m in &opt_mods {
            let slug = m.split(':').next().unwrap_or(m).trim();
            out.push_str(&format!(
                "• [{slug}](<https://modrinth.com/mod/{slug}>) (`{m}`)\n"
            ));
        }
    }

    let srv_mods = cfg.server_modrinth_mods();
    if !srv_mods.is_empty() {
        let names = srv_mods
            .iter()
            .map(|m| format!("`{m}`"))
            .collect::<Vec<_>>()
            .join(", ");
        out.push_str(&format!(
            "\n**🖥️ Server-Only Mods (No Client Install Needed):** {names}\n"
        ));
    }

    if !slugs_for_copy.is_empty() {
        out.push_str(&format!(
            "\n**Required Launcher Slugs (`Minecraft {ver}`):**\n```text\n{}\n```",
            slugs_for_copy.join("\n")
        ));
    }

    out.trim_end().to_string()
}

/// Format real-time server status response markdown for `/mc-status`
pub fn format_status_message(
    active_workflow: Option<ActiveWorkflow>,
    is_online: bool,
    fqdn: &str,
    direct_ip: Option<&str>,
    server_location: &str,
) -> String {
    match (active_workflow, is_online) {
        (Some(ActiveWorkflow::Start), _) => format!(
            "⏳ **Minecraft Server is STARTING / PROVISIONING...**\n\
             ⚙️ Ephemeral VM provisioning on Hetzner Cloud (`{server_location}`).\n\
             🌐 **Target Address:** `{fqdn}`\n\
             ⏱️ Please wait a moment while the server boots (~90s)."
        ),
        (Some(ActiveWorkflow::Stop), _) => format!(
            "🛑 **Minecraft Server is SHUTTING DOWN...**\n\
             ⚙️ Saving world chunks, creating cloud backup, and terminating ephemeral VM.\n\
             🌐 **Address:** `{fqdn}`\n\
             ⏱️ Server will be offline shortly."
        ),
        (None, true) => {
            let ip_details = match direct_ip {
                Some(addr) => format!(
                    "\n🖥️ **Direct IP:** `{addr}`\n\
                     🎮 **Ports:** Java `25565`, Bedrock `19132`\n\
                     💡 *In case of DNS cache issues use direct connect:* `{addr}`"
                ),
                None => "\n🎮 **Ports:** Java `25565`, Bedrock `19132`".to_string(),
            };
            format!(
                "🟢 **Minecraft Server is ONLINE!**\n\
                 🌐 **Address:** `{fqdn}`{ip_details}\n\
                 ✨ Ready to join!"
            )
        }
        (None, false) => format!(
            "🔴 **Minecraft Server is OFFLINE**\n\
             🌐 **Address:** `{fqdn}`\n\
             💤 The compute node is terminated to eliminate idle hosting costs.\n\
             👉 Use `/mc-start` to boot the server (~90s)."
        ),
    }
}

/// Format response when `/mc-start` is called but the server is already online
pub fn format_already_running_message(fqdn: &str, direct_ip: Option<&str>) -> String {
    let ip_details = match direct_ip {
        Some(addr) => format!(
            "\n🖥️ **Direct IP:** `{addr}`\n💡 *In case of DNS cache issues use direct connect:* `{addr}`"
        ),
        None => String::new(),
    };
    format!(
        "🟢 **Server is already running!**\nReachable at `{fqdn}` (Java: 25565, Bedrock: 19132).{ip_details}\n\
        No new node needs to be booted."
    )
}

/// Format warning when a conflicting workflow is in progress
pub fn format_blocked_action(active: ActiveWorkflow, requested_start: bool) -> String {
    let desc = match (active, requested_start) {
        (ActiveWorkflow::Start, true) => "A server startup is already in progress.",
        (ActiveWorkflow::Stop, true) => {
            "Server shutdown is currently in progress. Please wait until it completes before starting again."
        }
        (ActiveWorkflow::Start, false) => {
            "Server startup is currently in progress. Please wait until it finishes booting before stopping."
        }
        (ActiveWorkflow::Stop, false) => "A server shutdown is already in progress.",
    };
    format!("⚠️ **Action blocked:** {desc}")
}

/// Format `/mc-players` output.
pub fn format_players_message(resp: &AgentPlayers) -> String {
    if resp.online == 0 || resp.players.is_empty() {
        format!(
            "👥 **Players Online:** `0 / {}`\n*No players are currently connected.*",
            resp.max
        )
    } else {
        let list = resp
            .players
            .iter()
            .map(|p| format!("• `{p}`"))
            .collect::<Vec<_>>()
            .join("\n");
        format!(
            "👥 **Players Online:** `{} / {}`\n{list}",
            resp.online, resp.max
        )
    }
}

/// Format `/mc-top` host telemetry and player summary.
pub fn format_system_message(stats: &AgentSystem) -> String {
    let hours = stats.uptime_seconds / 3600;
    let mins = (stats.uptime_seconds % 3600) / 60;
    let player_summary = if stats.players.is_empty() {
        "none".to_string()
    } else {
        stats.players.join(", ")
    };

    format!(
        "📊 **Server Telemetry (`/mc-top`)**\n\
         • **CPU Load (1m / 5m / 15m):** `{:.2} / {:.2} / {:.2}`\n\
         • **Host RAM:** `{} MB / {} MB`\n\
         • **World Volume (`/mnt/mc-data`):** `{:.2} GB / {:.2} GB`\n\
         • **Host Uptime:** `{}h {}m`\n\
         • **Players (`{}/{}`):** `{}`",
        stats.load_1m,
        stats.load_5m,
        stats.load_15m,
        stats.mem_used_mb,
        stats.mem_total_mb,
        stats.disk_used_gb,
        stats.disk_total_gb,
        hours,
        mins,
        stats.online_players,
        stats.max_players,
        player_summary
    )
}

/// Truncates `text` to the trailing `max_chars` characters if it exceeds Discord's message limit.
fn tail_chars(text: &str, max_chars: usize) -> String {
    let count = text.chars().count();
    if count <= max_chars {
        text.to_string()
    } else {
        let skip = count - max_chars;
        format!(
            "…(truncated)\n{}",
            text.chars().skip(skip).collect::<String>()
        )
    }
}

/// Format `/mc-logs` output safely within Discord's 2000-character message limit.
pub fn format_logs_message(lines: &str) -> String {
    let trimmed = lines.trim();
    if trimmed.is_empty() {
        return "📜 **Server Logs:** *(no log lines available)*".to_string();
    }
    let body = tail_chars(trimmed, DISCORD_SAFE_MSG_LIMIT - 64);
    format!("📜 **Latest Server Logs:**\n```log\n{body}\n```")
}

/// Format RCON command or whitelist output safely within Discord's 2000-character message limit.
pub fn format_rcon_output(title: &str, output: &str) -> String {
    let trimmed = output.trim();
    if trimmed.is_empty() {
        format!("{title}\n*(no output)*")
    } else {
        let body = tail_chars(trimmed, DISCORD_SAFE_MSG_LIMIT - 80);
        format!("{title}\n```\n{body}\n```")
    }
}

/// Format an `AgentError` into a user-friendly Discord response.
pub fn format_agent_error(err: &AgentError, command_channel_id: &str) -> String {
    match err {
        AgentError::NotConfigured => {
            "⚠️ **Sidecar agent not configured.** Ensure the `MC_AGENT` Workers VPC binding and `AGENT_SHARED_SECRET` are deployed.".to_string()
        }
        AgentError::Offline => {
            let start_hint = if command_channel_id.trim().is_empty() {
                "Run `/mc-start` to boot it.".to_string()
            } else {
                format!("Run `/mc-start` in <#{command_channel_id}> to boot it.")
            };
            format!("⚫ **Server is currently offline.** {start_hint}")
        }
        AgentError::Unauthorized => {
            "🔒 **Agent authentication failed:** `AGENT_SHARED_SECRET` does not match `mc-agent`.".to_string()
        }
        AgentError::BadRequest(msg) => format!("⚠️ **Invalid request:** {msg}"),
        AgentError::HttpError(code, msg) => {
            format!("❌ **Agent error (HTTP {code}):** {}", tail_chars(msg, 300))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_FQDN: &str = "mc.example.com";
    const TEST_IP: &str = "142.132.1.2";

    #[test]
    fn test_format_status_message_online_with_ip() {
        let msg = format_status_message(None, true, TEST_FQDN, Some(TEST_IP), "fsn1");
        assert!(msg.contains(TEST_FQDN));
        assert!(msg.contains(TEST_IP));
        assert!(msg.contains("25565"));
        assert!(msg.contains("19132"));
    }

    #[test]
    fn test_format_status_message_online_without_ip() {
        let msg = format_status_message(None, true, TEST_FQDN, None, "fsn1");
        assert!(msg.contains(TEST_FQDN));
        assert!(msg.contains("25565"));
        assert!(msg.contains("19132"));
        assert!(!msg.contains(TEST_IP));
        assert!(!msg.contains("Direct IP"));
    }

    #[test]
    fn test_format_status_message_starting() {
        let msg =
            format_status_message(Some(ActiveWorkflow::Start), false, TEST_FQDN, None, "fsn1");
        assert!(msg.contains(TEST_FQDN));
        assert!(msg.to_uppercase().contains("STARTING"));
    }

    #[test]
    fn test_format_status_message_stopping() {
        let msg = format_status_message(Some(ActiveWorkflow::Stop), true, TEST_FQDN, None, "fsn1");
        assert!(msg.contains(TEST_FQDN));
        assert!(msg.to_uppercase().contains("SHUTTING DOWN"));
    }

    #[test]
    fn test_format_status_message_offline() {
        let msg = format_status_message(None, false, TEST_FQDN, None, "fsn1");
        assert!(msg.contains(TEST_FQDN));
        assert!(msg.contains("/mc-start"));
        assert!(msg.to_uppercase().contains("OFFLINE"));
    }

    #[test]
    fn test_format_already_running_message_with_ip() {
        let msg = format_already_running_message(TEST_FQDN, Some(TEST_IP));
        assert!(msg.contains(TEST_FQDN));
        assert!(msg.contains(TEST_IP));
        assert!(msg.contains("25565"));
    }

    #[test]
    fn test_format_already_running_message_without_ip() {
        let msg = format_already_running_message(TEST_FQDN, None);
        assert!(msg.contains(TEST_FQDN));
        assert!(msg.contains("25565"));
        assert!(!msg.contains(TEST_IP));
    }

    #[test]
    fn test_format_blocked_action_variants() {
        let msg_start_blocked = format_blocked_action(ActiveWorkflow::Start, true);
        assert!(msg_start_blocked.contains("startup"));

        let msg_start_during_stop = format_blocked_action(ActiveWorkflow::Stop, true);
        assert!(msg_start_during_stop.contains("shutdown"));

        let msg_stop_during_start = format_blocked_action(ActiveWorkflow::Start, false);
        assert!(msg_stop_during_start.contains("startup"));

        let msg_stop_during_stop = format_blocked_action(ActiveWorkflow::Stop, false);
        assert!(msg_stop_during_stop.contains("shutdown"));
    }

    #[test]
    fn test_format_players_and_system_and_logs() {
        let players_msg = format_players_message(&AgentPlayers {
            online: 2,
            max: 20,
            players: vec!["Steve".to_string(), ".BedrockAlex".to_string()],
        });
        assert!(players_msg.contains("2 / 20"));
        assert!(players_msg.contains("`Steve`"));

        let sys_msg = format_system_message(&AgentSystem {
            load_1m: 0.45,
            load_5m: 0.30,
            load_15m: 0.25,
            mem_used_mb: 5120,
            mem_total_mb: 8192,
            disk_used_gb: 4.5,
            disk_total_gb: 15.0,
            uptime_seconds: 3720,
            online_players: 1,
            max_players: 20,
            players: vec!["Steve".to_string()],
        });
        assert!(sys_msg.contains("0.45 / 0.30 / 0.25"));
        assert!(sys_msg.contains("5120 MB / 8192 MB"));
        assert!(sys_msg.contains("1h 2m"));

        let long_logs = "x".repeat(3000);
        let logs_msg = format_logs_message(&long_logs);
        assert!(logs_msg.len() <= 2000);
        assert!(logs_msg.contains("…(truncated)"));

        let offline_msg = format_agent_error(&AgentError::Offline, "123456");
        assert!(offline_msg.contains("<#123456>"));
    }
}
