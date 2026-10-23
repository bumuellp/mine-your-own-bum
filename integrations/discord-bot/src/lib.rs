//! Cloudflare Worker in Rust: Discord Slash Command Handler for Minecraft Server Management
//!
//! Handles:
//! - Discord Ed25519 signature verification
//! - Discord Ping/Pong validation handshake
//! - Sub-3s SLA compliance via deferred response (`type: 5`)
//! - Direct TCP healthcheck (port 25565) to verify real-time Minecraft server status
//! - Concurrency check on GitHub Actions API before dispatching
//! - GitHub Actions workflow dispatch for `server-start.yml` and `server-stop.yml`

use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::Deserialize;
use serde_json::json;
use std::time::Duration;
use worker::*;

#[derive(Deserialize)]
struct WorkflowRunsResponse {
    #[serde(default)]
    workflow_runs: Vec<WorkflowRun>,
}

#[derive(Deserialize)]
struct WorkflowRun {
    path: String,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ActiveWorkflow {
    Start,
    Stop,
}

/// Verify Discord Ed25519 signature
fn verify_signature(
    public_key_hex: &str,
    signature_hex: &str,
    timestamp: &str,
    body: &[u8],
) -> bool {
    let Ok(pub_key_bytes) = hex::decode(public_key_hex) else {
        return false;
    };
    let Ok(pub_key_arr): std::result::Result<[u8; 32], _> = pub_key_bytes.try_into() else {
        return false;
    };
    let Ok(verifying_key) = VerifyingKey::from_bytes(&pub_key_arr) else {
        return false;
    };

    let Ok(sig_bytes) = hex::decode(signature_hex) else {
        return false;
    };
    let Ok(sig_arr): std::result::Result<[u8; 64], _> = sig_bytes.try_into() else {
        return false;
    };
    let signature = Signature::from_bytes(&sig_arr);

    let mut message = timestamp.as_bytes().to_vec();
    message.extend_from_slice(body);

    verifying_key.verify(&message, &signature).is_ok()
}

/// Attempts a TCP connection to the Minecraft server on port 25565
/// with a 2.5-second timeout to check if the server is online.
async fn ping_minecraft_server(hostname: &str, port: u16) -> bool {
    let mut socket = match Socket::builder().connect(hostname, port) {
        Ok(s) => s,
        Err(_) => return false,
    };

    let is_connected = {
        let opened = socket.opened();
        let timeout = Delay::from(Duration::from_millis(2500));
        futures_util::pin_mut!(opened, timeout);

        matches!(
            futures_util::future::select(opened, timeout).await,
            futures_util::future::Either::Left((Ok(_), _))
        )
    };

    let _ = socket.close().await;
    is_connected
}

/// Construct standard GitHub API request headers
fn github_headers(pat: &str) -> Headers {
    let headers = Headers::new();
    let _ = headers.set("User-Agent", "Minecraft-Discord-Bot");
    let _ = headers.set("Authorization", &format!("Bearer {pat}"));
    let _ = headers.set("Accept", "application/vnd.github+json");
    let _ = headers.set("X-GitHub-Api-Version", "2022-11-28");
    headers
}

/// Query GitHub Actions API for workflow runs with a specific status filter
async fn check_runs_for_status(
    owner: &str,
    repo: &str,
    pat: &str,
    status: &str,
) -> Option<ActiveWorkflow> {
    let url = format!(
        "https://api.github.com/repos/{owner}/{repo}/actions/runs?status={status}&per_page=10"
    );

    let headers = github_headers(pat);

    let init = RequestInit {
        method: Method::Get,
        headers,
        ..Default::default()
    };

    let req = match Request::new_with_init(&url, &init) {
        Ok(r) => r,
        Err(e) => {
            console_error!("Failed to create GitHub runs request: {e}");
            return None;
        }
    };

    let mut resp = match Fetch::Request(req).send().await {
        Ok(r) if r.status_code() == 200 => r,
        Ok(r) => {
            console_error!("GitHub runs query returned HTTP status {}", r.status_code());
            return None;
        }
        Err(e) => {
            console_error!("GitHub runs query network failure: {e}");
            return None;
        }
    };

    let runs_data: WorkflowRunsResponse = match resp.json().await {
        Ok(data) => data,
        Err(e) => {
            console_error!("Failed to parse GitHub runs JSON response: {e}");
            return None;
        }
    };

    for run in runs_data.workflow_runs {
        if run.path.ends_with("server-start.yml") {
            return Some(ActiveWorkflow::Start);
        } else if run.path.ends_with("server-stop.yml") {
            return Some(ActiveWorkflow::Stop);
        }
    }

    None
}

/// Check if server-start or server-stop workflow is currently running or queued
async fn get_active_workflow(owner: &str, repo: &str, pat: &str) -> Option<ActiveWorkflow> {
    if let Some(wf) = check_runs_for_status(owner, repo, pat, "in_progress").await {
        return Some(wf);
    }
    check_runs_for_status(owner, repo, pat, "queued").await
}

/// Dispatch a workflow run via GitHub Actions repository API
async fn dispatch_workflow(
    owner: &str,
    repo: &str,
    pat: &str,
    workflow_filename: &str,
) -> std::result::Result<(), String> {
    let url = format!(
        "https://api.github.com/repos/{owner}/{repo}/actions/workflows/{workflow_filename}/dispatches"
    );

    let headers = github_headers(pat);
    let _ = headers.set("Content-Type", "application/json");

    let payload = json!({ "ref": "main" }).to_string();

    let init = RequestInit {
        method: Method::Post,
        headers,
        body: Some(wasm_bindgen::JsValue::from_str(&payload)),
        ..Default::default()
    };

    let req = Request::new_with_init(&url, &init).map_err(|e| e.to_string())?;
    let resp = Fetch::Request(req)
        .send()
        .await
        .map_err(|e| e.to_string())?;

    if resp.status_code() == 204 {
        Ok(())
    } else {
        Err(format!("GitHub API error (HTTP {})", resp.status_code()))
    }
}

/// Edit Discord's original deferred message
async fn update_deferred_response(app_id: &str, token: &str, message: &str) {
    let url = format!("https://discord.com/api/v10/webhooks/{app_id}/{token}/messages/@original");
    let headers = Headers::new();
    let _ = headers.set("Content-Type", "application/json");

    let payload = json!({ "content": message }).to_string();

    let init = RequestInit {
        method: Method::Patch,
        headers,
        body: Some(wasm_bindgen::JsValue::from_str(&payload)),
        ..Default::default()
    };

    match Request::new_with_init(&url, &init) {
        Ok(req) => match Fetch::Request(req).send().await {
            Ok(resp) if resp.status_code() >= 400 => {
                console_error!(
                    "Discord PATCH @original webhook returned HTTP status {}",
                    resp.status_code()
                );
            }
            Err(e) => {
                console_error!("Discord PATCH @original webhook network failure: {e}");
            }
            _ => {}
        },
        Err(e) => {
            console_error!("Failed to create Discord webhook request: {e}");
        }
    }
}

#[event(fetch)]
async fn main(mut req: Request, env: Env, ctx: Context) -> Result<Response> {
    if req.method() != Method::Post {
        return Response::error("Method not allowed", 405);
    }

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

    let interaction: serde_json::Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(_) => return Response::error("Invalid JSON body", 400),
    };

    let interaction_type = interaction
        .get("type")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);

    // Discord PING verification (type: 1) -> responds with PONG (type: 1)
    if interaction_type == 1 {
        return Response::from_json(&json!({ "type": 1 }));
    }

    // Discord APPLICATION_COMMAND (type: 2)
    if interaction_type == 2 {
        let data = interaction.get("data");
        let command_name = data
            .and_then(|d| d.get("name"))
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();

        // Optional ACL check: verify if invoking user is authorized
        if let Ok(allowed_ids_var) = env.secret("ALLOWED_USER_IDS") {
            let allowed_ids_str = allowed_ids_var.to_string();
            let allowed_ids: Vec<&str> = allowed_ids_str
                .split(',')
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .collect();

            if !allowed_ids.is_empty() {
                let user_id = interaction
                    .get("member")
                    .and_then(|m| m.get("user"))
                    .or_else(|| interaction.get("user"))
                    .and_then(|u| u.get("id"))
                    .and_then(|id| id.as_str())
                    .unwrap_or_default();

                if !allowed_ids.contains(&user_id) {
                    return Response::from_json(&json!({
                        "type": 4,
                        "data": {
                            "content": "⛔ You do not have permission to manage this Minecraft server.",
                            "flags": 64 // Ephemeral message (only caller can see)
                        }
                    }));
                }
            }
        }

        let owner = env.var("GITHUB_OWNER")?.to_string();
        let repo = env.var("GITHUB_REPO")?.to_string();
        let fqdn = env.var("SERVER_FQDN")?.to_string();
        let pat = env.secret("GITHUB_PAT")?.to_string();
        let app_id = env.secret("DISCORD_APPLICATION_ID")?.to_string();

        let token = interaction
            .get("token")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();

        // All operational commands respond immediately with deferred acknowledgment (type: 5)
        // to strictly meet Discord's < 3.0s SLA while background ping and dispatch run.
        ctx.wait_until(async move {
            if command_name == "mc-status" {
                let is_online = ping_minecraft_server(&fqdn, 25565).await;
                let active_workflow = get_active_workflow(&owner, &repo, &pat).await;

                let msg = match (active_workflow, is_online) {
                    (Some(ActiveWorkflow::Start), _) => format!(
                        "⏳ **Minecraft Server is STARTING / PROVISIONING...**\n\
                         ⚙️ Ephemeral VM provisioning on Hetzner Cloud (`fsn1`).\n\
                         🌐 **Target Address:** `{fqdn}`\n\
                         ⏱️ Please wait a moment while the server boots (~90s)."
                    ),
                    (Some(ActiveWorkflow::Stop), _) => format!(
                        "🛑 **Minecraft Server is SHUTTING DOWN...**\n\
                         ⚙️ Saving world chunks, creating cloud backup, and terminating ephemeral VM.\n\
                         🌐 **Address:** `{fqdn}`\n\
                         ⏱️ Server will be offline shortly."
                    ),
                    (None, true) => format!(
                        "🟢 **Minecraft Server is ONLINE!**\n\
                         🌐 **Address:** `{fqdn}`\n\
                         🎮 **Ports:** Java `25565`, Bedrock `19132`\n\
                         ✨ Ready to join!"
                    ),
                    (None, false) => format!(
                        "🔴 **Minecraft Server is OFFLINE**\n\
                         🌐 **Address:** `{fqdn}`\n\
                         💤 The compute node is terminated to eliminate idle hosting costs.\n\
                         👉 Use `/mc-start` to boot the server (~90s)."
                    ),
                };
                update_deferred_response(&app_id, &token, &msg).await;
                return;
            }

            if command_name == "mc-start" {
                // Guard 1: Concurrency check on active workflow
                if let Some(active) = get_active_workflow(&owner, &repo, &pat).await {
                    let desc = match active {
                        ActiveWorkflow::Start => "A server startup is already in progress.",
                        ActiveWorkflow::Stop => "Server shutdown is currently in progress. Please wait until it completes before starting again.",
                    };
                    update_deferred_response(
                        &app_id,
                        &token,
                        &format!("⚠️ **Action blocked:** {desc}")
                    ).await;
                    return;
                }

                // Guard 2: Direct FQDN TCP ping to check if already online
                if ping_minecraft_server(&fqdn, 25565).await {
                    update_deferred_response(
                        &app_id,
                        &token,
                        &format!("🟢 **Server is already running!**\nReachable at `{fqdn}` (Java: 25565, Bedrock: 19132). No new node needs to be booted.")
                    ).await;
                    return;
                }

                match dispatch_workflow(&owner, &repo, &pat, "server-start.yml").await {
                    Ok(_) => {
                        update_deferred_response(
                            &app_id,
                            &token,
                            &format!("🚀 **Starting Minecraft Server!**\nEphemeral node provisioning in Falkenstein (`fsn1`).\nConnect in ~90s at `{fqdn}`.")
                        ).await;
                    }
                    Err(e) => {
                        update_deferred_response(
                            &app_id,
                            &token,
                            &format!("❌ **Failed to dispatch server-start workflow:** {e}")
                        ).await;
                    }
                }
                return;
            }

            if command_name == "mc-stop" {
                // Guard: Concurrency check on active workflow
                if let Some(active) = get_active_workflow(&owner, &repo, &pat).await {
                    let desc = match active {
                        ActiveWorkflow::Start => "Server startup is currently in progress. Please wait until it finishes booting before stopping.",
                        ActiveWorkflow::Stop => "A server shutdown is already in progress.",
                    };
                    update_deferred_response(
                        &app_id,
                        &token,
                        &format!("⚠️ **Action blocked:** {desc}")
                    ).await;
                    return;
                }

                match dispatch_workflow(&owner, &repo, &pat, "server-stop.yml").await {
                    Ok(_) => {
                        update_deferred_response(
                            &app_id,
                            &token,
                            "🛑 **Stopping Minecraft Server...**\nFlushing chunks, taking world backup, and terminating ephemeral VM."
                        ).await;
                    }
                    Err(e) => {
                        update_deferred_response(
                            &app_id,
                            &token,
                            &format!("❌ **Failed to dispatch server-stop workflow:** {e}")
                        ).await;
                    }
                }
            }
        });

        // Immediate deferred acknowledgment (< 3s SLA)
        return Response::from_json(&json!({ "type": 5 }));
    }

    Response::error("Unknown interaction type", 400)
}
