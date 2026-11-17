//! GitHub Actions API client and workflow runs parsing

use crate::types::ActiveWorkflow;
use serde::Deserialize;
use serde_json::json;
use worker::{Fetch, Headers, Method, Request, RequestInit, console_error};

#[derive(Clone, Debug, Deserialize)]
pub struct WorkflowRunsResponse {
    #[serde(default)]
    pub workflow_runs: Vec<WorkflowRun>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct WorkflowRun {
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub name: Option<String>,
}

/// Parse active workflow from a WorkflowRunsResponse.
/// Resilient to GitHub returning paths with ref qualifiers (e.g. `.github/workflows/server-start.yml@main`)
/// or matching by workflow run name.
pub fn parse_active_workflow(response: &WorkflowRunsResponse) -> Option<ActiveWorkflow> {
    for run in &response.workflow_runs {
        let clean_path = run.path.split('@').next().unwrap_or(&run.path);
        if clean_path.ends_with("server-start.yml")
            || run.name.as_deref() == Some("Start Minecraft Server")
        {
            return Some(ActiveWorkflow::Start);
        } else if clean_path.ends_with("server-stop.yml")
            || run.name.as_deref() == Some("Stop Minecraft Server")
        {
            return Some(ActiveWorkflow::Stop);
        }
    }
    None
}

/// Pinned GitHub REST API version from repository root `.github-api-version`
pub const GITHUB_API_VERSION: &str = include_str!("../../../.github-api-version");

/// Construct standard GitHub API request headers
pub fn github_headers(pat: &str) -> Headers {
    let headers = Headers::new();
    let _ = headers.set("User-Agent", "Minecraft-Discord-Bot");
    let _ = headers.set("Authorization", &format!("Bearer {pat}"));
    let _ = headers.set("Accept", "application/vnd.github+json");
    let _ = headers.set("X-GitHub-Api-Version", GITHUB_API_VERSION.trim());
    headers
}

/// Query GitHub Actions API for workflow runs with a specific status filter.
/// Fetches the 30 most recent runs (GitHub Actions default order is `created_at desc`).
pub async fn check_runs_for_status(
    owner: &str,
    repo: &str,
    pat: &str,
    status: &str,
) -> Option<ActiveWorkflow> {
    let url = format!(
        "https://api.github.com/repos/{owner}/{repo}/actions/runs?status={status}&per_page=30"
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

    parse_active_workflow(&runs_data)
}

/// Check if server-start or server-stop workflow is currently running or queued
pub async fn get_active_workflow(owner: &str, repo: &str, pat: &str) -> Option<ActiveWorkflow> {
    let (in_progress, queued) = futures_util::future::join(
        check_runs_for_status(owner, repo, pat, "in_progress"),
        check_runs_for_status(owner, repo, pat, "queued"),
    )
    .await;
    in_progress.or(queued)
}

/// Dispatch a workflow run via GitHub Actions repository API
pub async fn dispatch_workflow(
    owner: &str,
    repo: &str,
    pat: &str,
    workflow_filename: &str,
) -> Result<(), String> {
    let url = format!(
        "https://api.github.com/repos/{owner}/{repo}/actions/workflows/{workflow_filename}/dispatches"
    );

    let headers = github_headers(pat);
    let _ = headers.set("Content-Type", "application/json");

    let payload = json!({ "ref": "main" }).to_string();

    let init = RequestInit {
        method: Method::Post,
        headers,
        body: Some(worker::wasm_bindgen::JsValue::from_str(&payload)),
        ..Default::default()
    };

    let req = Request::new_with_init(&url, &init).map_err(|e| e.to_string())?;
    let resp = Fetch::Request(req)
        .send()
        .await
        .map_err(|e| e.to_string())?;

    if (200..=299).contains(&resp.status_code()) {
        Ok(())
    } else {
        Err(format!("GitHub API error (HTTP {})", resp.status_code()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_active_workflow_start() {
        let json_data = r#"{
            "total_count": 1,
            "workflow_runs": [
                {
                    "id": 123456,
                    "name": "Start Minecraft Server",
                    "path": ".github/workflows/server-start.yml"
                }
            ]
        }"#;

        let response: WorkflowRunsResponse = serde_json::from_str(json_data).unwrap();
        assert_eq!(
            parse_active_workflow(&response),
            Some(ActiveWorkflow::Start)
        );
    }

    #[test]
    fn test_parse_active_workflow_with_ref_suffix() {
        let json_data = r#"{
            "total_count": 2,
            "workflow_runs": [
                {
                    "id": 123456,
                    "name": "Start Minecraft Server",
                    "path": ".github/workflows/server-start.yml@main"
                },
                {
                    "id": 789012,
                    "name": "Stop Minecraft Server",
                    "path": ".github/workflows/server-stop.yml@refs/heads/main"
                }
            ]
        }"#;

        let response: WorkflowRunsResponse = serde_json::from_str(json_data).unwrap();
        assert_eq!(
            parse_active_workflow(&response),
            Some(ActiveWorkflow::Start)
        );
    }

    #[test]
    fn test_parse_active_workflow_name_fallback() {
        let json_data = r#"{
            "total_count": 1,
            "workflow_runs": [
                {
                    "id": 789012,
                    "name": "Stop Minecraft Server",
                    "path": ""
                }
            ]
        }"#;

        let response: WorkflowRunsResponse = serde_json::from_str(json_data).unwrap();
        assert_eq!(parse_active_workflow(&response), Some(ActiveWorkflow::Stop));
    }

    #[test]
    fn test_parse_active_workflow_stop() {
        let json_data = r#"{
            "total_count": 1,
            "workflow_runs": [
                {
                    "id": 789012,
                    "name": "Stop Minecraft Server",
                    "path": ".github/workflows/server-stop.yml"
                }
            ]
        }"#;

        let response: WorkflowRunsResponse = serde_json::from_str(json_data).unwrap();
        assert_eq!(parse_active_workflow(&response), Some(ActiveWorkflow::Stop));
    }

    #[test]
    fn test_parse_active_workflow_other_workflows() {
        let json_data = r#"{
            "total_count": 2,
            "workflow_runs": [
                {
                    "id": 111,
                    "name": "CI",
                    "path": ".github/workflows/ci.yml"
                },
                {
                    "id": 222,
                    "name": "Deploy Discord Bot",
                    "path": ".github/workflows/deploy-discord-bot.yml"
                }
            ]
        }"#;

        let response: WorkflowRunsResponse = serde_json::from_str(json_data).unwrap();
        assert_eq!(parse_active_workflow(&response), None);
    }

    #[test]
    fn test_parse_active_workflow_empty() {
        let json_data = r#"{ "workflow_runs": [] }"#;
        let response: WorkflowRunsResponse = serde_json::from_str(json_data).unwrap();
        assert_eq!(parse_active_workflow(&response), None);

        let json_empty = r#"{}"#;
        let response_empty: WorkflowRunsResponse = serde_json::from_str(json_empty).unwrap();
        assert_eq!(parse_active_workflow(&response_empty), None);
    }
}
