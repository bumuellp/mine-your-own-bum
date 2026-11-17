//! Pure markdown message formatters for Discord slash command responses

use crate::types::ActiveWorkflow;

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
}
