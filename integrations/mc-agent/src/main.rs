//! Entrypoint for the `mc-agent` sidecar daemon.

use mc_agent::api::route_request;
use mc_agent::config::RuntimeConfig;
use mc_agent::discord::{DiscordWebhookClient, notify_boot_ready_once};
use mc_agent::http::{probe_health, serve};
use mc_agent::log_watcher::watch_latest_log;
use mc_agent::rcon::RconClient;
use std::env;
use std::sync::Arc;
use std::time::Duration;
use tokio::net::TcpListener;

#[tokio::main]
async fn main() {
    let runtime = RuntimeConfig::from_env();

    if env::args().any(|a| a == "--healthcheck") {
        let check_addr = runtime.healthcheck_addr();
        if let Err(e) = probe_health(&check_addr).await {
            eprintln!("Healthcheck failed: {e}");
            std::process::exit(1);
        }
        return;
    }

    let discord_client = DiscordWebhookClient::new();

    if !runtime.command_webhook_url.trim().is_empty() {
        let client = discord_client.clone();
        let marker = runtime.boot_marker_path.clone();
        let webhook = runtime.command_webhook_url.clone();
        let fqdn = runtime.server_fqdn.clone();
        let ipv4 = runtime.server_ipv4.clone();
        let loc = runtime.server_location.clone();
        let rcon = RconClient::new(
            runtime.agent.rcon_host.clone(),
            runtime.agent.rcon_port,
            runtime.agent.rcon_password.clone(),
        );
        tokio::spawn(async move {
            // Poll RCON readiness (up to 15m) so mc-agent and cloudflared can start
            // immediately on VM boot while only firing the "ONLINE & Ready" webhook
            // once Minecraft finishes loading mods and accepts RCON connections.
            for _ in 0..180 {
                if rcon.execute("list").await.is_ok() {
                    notify_boot_ready_once(&client, &marker, &webhook, &fqdn, &ipv4, &loc).await;
                    break;
                }
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
        });
    }

    if !runtime.chat_webhook_url.trim().is_empty() {
        let client = discord_client.clone();
        let log_path = runtime.agent.log_path.clone();
        let webhook = runtime.chat_webhook_url.clone();
        tokio::spawn(async move {
            watch_latest_log(log_path, client, webhook).await;
        });
    }

    let listener = TcpListener::bind(&runtime.listen_addr)
        .await
        .expect("Failed to bind mc-agent TCP listener");
    println!("mc-agent listening on {}", runtime.listen_addr);

    let agent_cfg = Arc::new(runtime.agent);
    serve(listener, move |req| {
        let cfg = Arc::clone(&agent_cfg);
        async move { route_request(&req, &cfg).await }
    })
    .await;
}
