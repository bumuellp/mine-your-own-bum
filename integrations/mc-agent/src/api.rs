//! Domain API router and endpoint handlers for `mc-agent`.

use crate::auth::verify_secret;
use crate::config::AgentConfig;
use crate::http::{HttpRequest, HttpResponse};
use crate::rcon::{RconClient, build_tellraw_command, is_valid_player_name, parse_player_list};
use crate::system::{collect_system_stats, tail_log_file};
use serde::Deserialize;
use serde_json::json;

#[derive(Deserialize)]
struct SayRequest {
    #[serde(default)]
    sender: String,
    message: String,
}

#[derive(Deserialize)]
struct WhitelistRequest {
    action: String,
    #[serde(default)]
    player: String,
}

#[derive(Deserialize)]
struct RconRequest {
    command: String,
}

/// Extracts `lines=N` query parameter, defaulting to `40` and clamping to `1..=80`.
pub fn parse_lines_query(query: &str) -> usize {
    for pair in query.split('&') {
        if let Some((k, v)) = pair.split_once('=')
            && k == "lines"
            && let Ok(n) = v.parse::<usize>()
        {
            return n.clamp(1, 80);
        }
    }
    40
}

async fn execute_rcon_or_502(
    rcon: &RconClient,
    command: &str,
    default_output: &str,
) -> HttpResponse {
    match rcon.execute(command).await {
        Ok(output) => HttpResponse::ok(json!({
            "output": if output.is_empty() {
                default_output.to_string()
            } else {
                output
            }
        })),
        Err(e) => HttpResponse::bad_gateway(&e),
    }
}

async fn handle_players(rcon: &RconClient) -> HttpResponse {
    match rcon.execute("list").await {
        Ok(out) => {
            let parsed = parse_player_list(&out);
            HttpResponse::ok(serde_json::to_value(parsed).unwrap_or_default())
        }
        Err(e) => HttpResponse::bad_gateway(&e),
    }
}

async fn handle_system(cfg: &AgentConfig, rcon: &RconClient) -> HttpResponse {
    let stats = collect_system_stats(&cfg.proc_dir, &cfg.data_dir).await;
    let players = rcon
        .execute("list")
        .await
        .ok()
        .map(|out| parse_player_list(&out));

    HttpResponse::ok(json!({
        "load_1m": stats.load_1m,
        "load_5m": stats.load_5m,
        "load_15m": stats.load_15m,
        "mem_used_mb": stats.mem_used_mb,
        "mem_total_mb": stats.mem_total_mb,
        "disk_used_gb": stats.disk_used_gb,
        "disk_total_gb": stats.disk_total_gb,
        "uptime_seconds": stats.uptime_seconds,
        "online_players": players.as_ref().map(|p| p.online).unwrap_or(0),
        "max_players": players.as_ref().map(|p| p.max).unwrap_or(20),
        "players": players.map(|p| p.players).unwrap_or_default(),
    }))
}

async fn handle_logs(cfg: &AgentConfig, query: &str) -> HttpResponse {
    let lines = parse_lines_query(query);
    match tail_log_file(&cfg.log_path, lines).await {
        Ok(log_text) => HttpResponse::ok(json!({ "lines": log_text })),
        Err(e) => HttpResponse::internal_error(&e),
    }
}

async fn handle_say(rcon: &RconClient, body: &str) -> HttpResponse {
    let Ok(payload) = serde_json::from_str::<SayRequest>(body) else {
        return HttpResponse::bad_request("Invalid JSON body for /api/say");
    };
    if payload.message.trim().is_empty() {
        return HttpResponse::bad_request("Message must not be empty");
    }
    let sender = if payload.sender.trim().is_empty() {
        "Discord"
    } else {
        payload.sender.trim()
    };
    let cmd = build_tellraw_command(sender, &payload.message);
    match rcon.execute(&cmd).await {
        Ok(_) => HttpResponse::ok(json!({ "ok": true })),
        Err(e) => HttpResponse::bad_gateway(&e),
    }
}

async fn handle_whitelist(rcon: &RconClient, body: &str) -> HttpResponse {
    let Ok(payload) = serde_json::from_str::<WhitelistRequest>(body) else {
        return HttpResponse::bad_request("Invalid JSON body for /api/whitelist");
    };
    let action = payload.action.trim().to_ascii_lowercase();
    let rcon_cmd = match action.as_str() {
        "list" => "whitelist list".to_string(),
        "add" | "remove" => {
            if !is_valid_player_name(&payload.player) {
                return HttpResponse::bad_request("Invalid player name format");
            }
            format!("whitelist {action} {}", payload.player.trim())
        }
        _ => {
            return HttpResponse::bad_request(
                "Unsupported whitelist action (use add, remove, or list)",
            );
        }
    };
    execute_rcon_or_502(rcon, &rcon_cmd, "").await
}

async fn handle_backup(rcon: &RconClient) -> HttpResponse {
    match rcon.execute("save-all flush").await {
        Ok(output) => {
            let _ = rcon
                .execute("say [Server] World saved and flushed to disk.")
                .await;
            HttpResponse::ok(json!({
                "output": if output.is_empty() {
                    "World saved and chunks flushed to disk.".to_string()
                } else {
                    output
                }
            }))
        }
        Err(e) => HttpResponse::bad_gateway(&e),
    }
}

async fn handle_restart(rcon: &RconClient) -> HttpResponse {
    let _ = rcon
        .execute("say [Server] Restarting Minecraft JVM in 3 seconds...")
        .await;
    let _ = rcon.execute("save-all flush").await;
    execute_rcon_or_502(
        rcon,
        "stop",
        "Graceful JVM stop initiated; Docker will restart mc-server.",
    )
    .await
}

async fn handle_rcon(rcon: &RconClient, body: &str) -> HttpResponse {
    let Ok(payload) = serde_json::from_str::<RconRequest>(body) else {
        return HttpResponse::bad_request("Invalid JSON body for /api/rcon");
    };
    let cmd = payload.command.trim();
    if cmd.is_empty() || cmd.len() > 512 {
        return HttpResponse::bad_request("Command must be between 1 and 512 characters");
    }
    execute_rcon_or_502(rcon, cmd, "").await
}

/// Authenticates and routes an `HttpRequest` to the matching `mc-agent` domain handler.
pub async fn route_request(req: &HttpRequest, cfg: &AgentConfig) -> HttpResponse {
    if req.method == "GET" && req.path == "/healthz" {
        return HttpResponse::ok(json!({ "status": "ok" }));
    }

    let provided_secret = req.header("X-Agent-Secret").unwrap_or("");
    if !verify_secret(&cfg.agent_secret, provided_secret) {
        return HttpResponse::unauthorized("Unauthorized: invalid or missing X-Agent-Secret");
    }

    let rcon = RconClient::new(
        cfg.rcon_host.clone(),
        cfg.rcon_port,
        cfg.rcon_password.clone(),
    );

    match (req.method.as_str(), req.path.as_str()) {
        ("GET", "/api/players") => handle_players(&rcon).await,
        ("GET", "/api/system") => handle_system(cfg, &rcon).await,
        ("GET", "/api/logs") => handle_logs(cfg, &req.query).await,
        ("POST", "/api/say") => handle_say(&rcon, &req.body).await,
        ("POST", "/api/whitelist") => handle_whitelist(&rcon, &req.body).await,
        ("POST", "/api/backup") => handle_backup(&rcon).await,
        ("POST", "/api/restart") => handle_restart(&rcon).await,
        ("POST", "/api/rcon") => handle_rcon(&rcon, &req.body).await,
        _ => HttpResponse::not_found("Endpoint not found"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn test_config() -> AgentConfig {
        AgentConfig {
            rcon_host: "127.0.0.1".to_string(),
            rcon_port: 25575,
            rcon_password: "test-rcon-password".to_string(),
            agent_secret: "super-secret-agent-token-12345".to_string(),
            log_path: "/nonexistent/latest.log".to_string(),
            proc_dir: "/proc".to_string(),
            data_dir: "/tmp".to_string(),
        }
    }

    fn make_req(method: &str, path: &str, query: &str, secret: &str, body: &str) -> HttpRequest {
        let mut headers = HashMap::new();
        if !secret.is_empty() {
            headers.insert("x-agent-secret".to_string(), secret.to_string());
        }
        HttpRequest {
            method: method.to_string(),
            path: path.to_string(),
            query: query.to_string(),
            headers,
            body: body.to_string(),
        }
    }

    #[test]
    fn test_parse_lines_query_bounds_and_defaults() {
        assert_eq!(parse_lines_query("lines=25"), 25);
        assert_eq!(parse_lines_query("foo=1&lines=15&bar=2"), 15);
        assert_eq!(parse_lines_query("lines=0"), 1);
        assert_eq!(parse_lines_query("lines=999"), 80);
        assert_eq!(parse_lines_query("lines=abc"), 40);
        assert_eq!(parse_lines_query(""), 40);
    }

    #[tokio::test]
    async fn test_route_healthz_is_public_and_api_requires_secret() {
        let cfg = test_config();

        let health_resp = route_request(&make_req("GET", "/healthz", "", "", ""), &cfg).await;
        assert_eq!(health_resp.status_code, 200);
        assert_eq!(health_resp.body["status"], "ok");

        let unauth_resp = route_request(
            &make_req("GET", "/api/players", "", "wrong-secret", ""),
            &cfg,
        )
        .await;
        assert_eq!(unauth_resp.status_code, 401);
    }

    #[tokio::test]
    async fn test_route_whitelist_and_say_and_rcon_validation() {
        let cfg = test_config();

        let bad_wl = make_req(
            "POST",
            "/api/whitelist",
            "",
            &cfg.agent_secret,
            r#"{"action":"add","player":"bad player; stop"}"#,
        );
        let resp = route_request(&bad_wl, &cfg).await;
        assert_eq!(resp.status_code, 400);
        assert!(
            resp.body["error"]
                .as_str()
                .unwrap()
                .contains("Invalid player")
        );

        let empty_say = make_req(
            "POST",
            "/api/say",
            "",
            &cfg.agent_secret,
            r#"{"sender":"Steve","message":"   "}"#,
        );
        assert_eq!(route_request(&empty_say, &cfg).await.status_code, 400);

        let empty_rcon = make_req(
            "POST",
            "/api/rcon",
            "",
            &cfg.agent_secret,
            r#"{"command":"   "}"#,
        );
        assert_eq!(route_request(&empty_rcon, &cfg).await.status_code, 400);
    }
}
