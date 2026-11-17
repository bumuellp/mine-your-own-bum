//! Entrypoint for the `mc-agent` sidecar daemon.

use mc_agent::api::route_request;
use mc_agent::config::RuntimeConfig;
use mc_agent::discord::{DiscordWebhookClient, notify_boot_ready_once};
use mc_agent::http::{probe_health, serve};
use mc_agent::log_watcher::watch_latest_log;
use std::env;
use std::sync::Arc;
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
        tokio::spawn(async move {
            notify_boot_ready_once(&client, &marker, &webhook, &fqdn, &ipv4, &loc).await;
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
