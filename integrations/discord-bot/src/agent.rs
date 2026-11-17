//! Cloudflare Workers VPC client for communicating with the `mc-agent` sidecar.

use serde::Deserialize;
use serde_json::Value;
use worker::{Fetcher, Headers, Method, Request, RequestInit};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AgentError {
    NotConfigured,
    Offline,
    Unauthorized,
    BadRequest(String),
    HttpError(u16, String),
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct AgentPlayers {
    pub online: u32,
    pub max: u32,
    pub players: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct AgentSystem {
    pub load_1m: f64,
    pub load_5m: f64,
    pub load_15m: f64,
    pub mem_used_mb: u64,
    pub mem_total_mb: u64,
    pub disk_used_gb: f64,
    pub disk_total_gb: f64,
    pub uptime_seconds: u64,
    pub online_players: u32,
    pub max_players: u32,
    #[serde(default)]
    pub players: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
struct AgentLogs {
    lines: String,
}

#[derive(Clone, Debug, Deserialize)]
struct AgentOutput {
    output: String,
}

#[derive(Clone, Debug, Deserialize)]
struct AgentErrorBody {
    error: String,
}

/// Executes an authenticated HTTP request against `mc-agent` via the `MC_AGENT` Workers VPC binding.
async fn agent_request(
    fetcher: Option<&Fetcher>,
    secret: &str,
    method: Method,
    path: &str,
    body: Option<Value>,
) -> Result<String, AgentError> {
    let fetcher = fetcher.ok_or(AgentError::NotConfigured)?;
    if secret.trim().is_empty() {
        return Err(AgentError::NotConfigured);
    }

    let headers = Headers::new();
    let _ = headers.set("X-Agent-Secret", secret.trim());
    let mut init = RequestInit {
        method,
        headers,
        ..Default::default()
    };

    if let Some(payload) = body {
        let _ = init.headers.set("Content-Type", "application/json");
        init.body = Some(payload.to_string().into());
    }

    let url = format!("http://mc-agent:8080{path}");
    let req = Request::new_with_init(&url, &init)
        .map_err(|e| AgentError::HttpError(500, e.to_string()))?;
    let mut resp = fetcher
        .fetch_request(req)
        .await
        .map_err(|_| AgentError::Offline)?;
    let status = resp.status_code();
    let text = resp.text().await.unwrap_or_default();

    match status {
        200..=299 => Ok(text),
        401 | 403 => Err(AgentError::Unauthorized),
        400 => {
            let msg = serde_json::from_str::<AgentErrorBody>(&text)
                .map(|b| b.error)
                .unwrap_or(text);
            Err(AgentError::BadRequest(msg))
        }
        502 | 503 | 504 | 530 => Err(AgentError::Offline),
        _ => Err(AgentError::HttpError(status, text)),
    }
}

pub async fn fetch_players(
    fetcher: Option<&Fetcher>,
    secret: &str,
) -> Result<AgentPlayers, AgentError> {
    let text = agent_request(fetcher, secret, Method::Get, "/api/players", None).await?;
    serde_json::from_str(&text).map_err(|e| AgentError::HttpError(502, e.to_string()))
}

pub async fn fetch_system(
    fetcher: Option<&Fetcher>,
    secret: &str,
) -> Result<AgentSystem, AgentError> {
    let text = agent_request(fetcher, secret, Method::Get, "/api/system", None).await?;
    serde_json::from_str(&text).map_err(|e| AgentError::HttpError(502, e.to_string()))
}

pub async fn fetch_logs(
    fetcher: Option<&Fetcher>,
    secret: &str,
    lines: u32,
) -> Result<String, AgentError> {
    let clamped = lines.clamp(1, 80);
    let text = agent_request(
        fetcher,
        secret,
        Method::Get,
        &format!("/api/logs?lines={clamped}"),
        None,
    )
    .await?;
    let parsed: AgentLogs =
        serde_json::from_str(&text).map_err(|e| AgentError::HttpError(502, e.to_string()))?;
    Ok(parsed.lines)
}

pub async fn post_say(
    fetcher: Option<&Fetcher>,
    secret: &str,
    sender: &str,
    message: &str,
) -> Result<(), AgentError> {
    agent_request(
        fetcher,
        secret,
        Method::Post,
        "/api/say",
        Some(serde_json::json!({ "sender": sender, "message": message })),
    )
    .await?;
    Ok(())
}

pub async fn post_whitelist(
    fetcher: Option<&Fetcher>,
    secret: &str,
    action: &str,
    player: Option<&str>,
) -> Result<String, AgentError> {
    let text = agent_request(
        fetcher,
        secret,
        Method::Post,
        "/api/whitelist",
        Some(serde_json::json!({ "action": action, "player": player.unwrap_or("") })),
    )
    .await?;
    let parsed: AgentOutput =
        serde_json::from_str(&text).map_err(|e| AgentError::HttpError(502, e.to_string()))?;
    Ok(parsed.output)
}

pub async fn post_backup(fetcher: Option<&Fetcher>, secret: &str) -> Result<String, AgentError> {
    let text = agent_request(fetcher, secret, Method::Post, "/api/backup", None).await?;
    let parsed: AgentOutput =
        serde_json::from_str(&text).map_err(|e| AgentError::HttpError(502, e.to_string()))?;
    Ok(parsed.output)
}

pub async fn post_restart(fetcher: Option<&Fetcher>, secret: &str) -> Result<String, AgentError> {
    let text = agent_request(fetcher, secret, Method::Post, "/api/restart", None).await?;
    let parsed: AgentOutput =
        serde_json::from_str(&text).map_err(|e| AgentError::HttpError(502, e.to_string()))?;
    Ok(parsed.output)
}

pub async fn post_rcon(
    fetcher: Option<&Fetcher>,
    secret: &str,
    command: &str,
) -> Result<String, AgentError> {
    let text = agent_request(
        fetcher,
        secret,
        Method::Post,
        "/api/rcon",
        Some(serde_json::json!({ "command": command })),
    )
    .await?;
    let parsed: AgentOutput =
        serde_json::from_str(&text).map_err(|e| AgentError::HttpError(502, e.to_string()))?;
    Ok(parsed.output)
}
