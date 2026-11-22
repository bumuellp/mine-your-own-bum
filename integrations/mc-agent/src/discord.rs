//! Discord Webhook payload formatting and pure-Rust HTTPS delivery.

use crate::log_parser::LogEvent;
use reqwest::Client;
use serde_json::{Value, json};
use std::path::Path;
use std::time::Duration;

const DISCORD_MAX_CONTENT_LEN: usize = 2000;

fn truncate_chars(input: &str, max_chars: usize) -> String {
    input.chars().take(max_chars).collect()
}

/// Builds the Discord Webhook JSON payload for a `LogEvent`, enforcing `allowed_mentions: {"parse": []}`.
pub fn build_chat_event_payload(event: &LogEvent) -> Value {
    match event {
        LogEvent::Chat { player, message } => {
            let trimmed = player.trim_start_matches('.');
            let avatar_player = if trimmed.is_empty() {
                "MHF_Steve"
            } else {
                trimmed
            };
            json!({
                "username": truncate_chars(player, 80),
                "avatar_url": format!("https://mc-heads.net/avatar/{avatar_player}/64"),
                "content": truncate_chars(message, DISCORD_MAX_CONTENT_LEN),
                "allowed_mentions": { "parse": [] }
            })
        }
        LogEvent::Join { player } => {
            json!({
                "content": format!("🟢 **{player}** joined the server."),
                "allowed_mentions": { "parse": [] }
            })
        }
        LogEvent::Leave { player } => {
            json!({
                "content": format!("🔴 **{player}** left the server."),
                "allowed_mentions": { "parse": [] }
            })
        }
    }
}

/// Builds the rich "Server Online & Ready" Discord webhook embed payload.
pub fn build_boot_ready_payload(server_fqdn: &str, server_ipv4: &str, location: &str) -> Value {
    let modpack = std::env::var("MC_MODRINTH_MODPACK").unwrap_or_default();
    build_boot_ready_payload_with_modpack(server_fqdn, server_ipv4, location, &modpack)
}

/// Builds the rich "Server Online & Ready" Discord webhook embed payload with optional modpack hint.
pub fn build_boot_ready_payload_with_modpack(
    server_fqdn: &str,
    server_ipv4: &str,
    location: &str,
    modrinth_modpack: &str,
) -> Value {
    let ip_display = if server_ipv4.trim().is_empty() {
        "N/A"
    } else {
        server_ipv4.trim()
    };
    let domain_display = if server_fqdn.trim().is_empty() {
        ip_display
    } else {
        server_fqdn.trim()
    };
    let loc_display = if location.trim().is_empty() {
        "fsn1"
    } else {
        location.trim()
    };

    let mut fields = vec![
        json!({
            "name": "🌐 Domain / Server Address",
            "value": format!("`{domain_display}`"),
            "inline": true
        }),
        json!({
            "name": "🖥️ Direct IP (Bypass DNS Cache)",
            "value": format!("`{ip_display}:25565`"),
            "inline": true
        }),
        json!({
            "name": "📍 Location",
            "value": format!("`{loc_display}`"),
            "inline": true
        }),
    ];

    let mp = modrinth_modpack.trim();
    if !mp.is_empty() {
        fields.push(json!({
            "name": "📦 Client Modpack Required",
            "value": format!("`{mp}` — Run `/mc-mods` in Discord for download links & required mods."),
            "inline": false
        }));
    }

    json!({
        "embeds": [{
            "title": "🟢 Minecraft Server is ONLINE & Ready!",
            "description": "All mods and world chunks are initialized. You can connect now!",
            "color": 3066993,
            "fields": fields
        }],
        "allowed_mentions": { "parse": [] }
    })
}

/// Lightweight reusable HTTPS client for Discord Webhooks (no `curl` subprocess needed).
#[derive(Clone)]
pub struct DiscordWebhookClient {
    client: Client,
}

impl Default for DiscordWebhookClient {
    fn default() -> Self {
        Self::new()
    }
}

impl DiscordWebhookClient {
    pub fn new() -> Self {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
            .expect("Failed to initialize reqwest HTTPS client");
        Self { client }
    }

    pub async fn post_json(&self, webhook_url: &str, payload: &Value) -> Result<(), String> {
        let url = webhook_url.trim();
        if url.is_empty() {
            return Ok(());
        }

        let resp = self
            .client
            .post(url)
            .json(payload)
            .send()
            .await
            .map_err(|e| format!("webhook request failed: {e}"))?;

        if !resp.status().is_success() {
            return Err(format!("webhook returned HTTP {}", resp.status()));
        }

        Ok(())
    }
}

/// Sends the one-time boot readiness notification with exponential backoff retries.
pub async fn notify_boot_ready_once(
    client: &DiscordWebhookClient,
    marker_path: &str,
    webhook_url: &str,
    server_fqdn: &str,
    server_ipv4: &str,
    location: &str,
) {
    if webhook_url.trim().is_empty() || Path::new(marker_path).exists() {
        return;
    }

    let payload = build_boot_ready_payload(server_fqdn, server_ipv4, location);
    let mut delay_secs = 2u64;

    for attempt in 1..=5 {
        match client.post_json(webhook_url, &payload).await {
            Ok(()) => {
                let _ = tokio::fs::write(marker_path, b"ok\n").await;
                return;
            }
            Err(e) => {
                eprintln!("Boot notification attempt {attempt}/5 failed: {e}");
                if attempt < 5 {
                    tokio::time::sleep(Duration::from_secs(delay_secs)).await;
                    delay_secs *= 2;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_webhook_payload_blocks_everyone_mentions_and_truncates() {
        let ev = LogEvent::Chat {
            player: "Steve".to_string(),
            message: format!("Hello @everyone {}", "a".repeat(2500)),
        };
        let payload = build_chat_event_payload(&ev);
        assert_eq!(payload["username"], "Steve");
        assert_eq!(
            payload["avatar_url"],
            "https://mc-heads.net/avatar/Steve/64"
        );
        assert_eq!(payload["allowed_mentions"]["parse"], json!([]));
        assert_eq!(payload["content"].as_str().unwrap().chars().count(), 2000);
    }

    #[test]
    fn test_boot_ready_payload_fallbacks() {
        let payload = build_boot_ready_payload("", "", "");
        let fields = payload["embeds"][0]["fields"].as_array().unwrap();
        assert_eq!(fields[0]["value"], "`N/A`");
        assert_eq!(fields[1]["value"], "`N/A:25565`");
        assert_eq!(fields[2]["value"], "`fsn1`");
    }

    #[test]
    fn test_discord_webhook_client_initializes_with_ring_provider() {
        let _client = DiscordWebhookClient::new();
    }
}
