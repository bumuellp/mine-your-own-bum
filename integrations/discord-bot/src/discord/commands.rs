//! Discord slash command handlers for Minecraft server control

use super::client::update_deferred_response;
use super::format::{format_already_running_message, format_blocked_action, format_status_message};
use crate::github::{dispatch_workflow, get_active_workflow};
use crate::minecraft::{clean_ip, ping_minecraft_server, resolve_ip_doh};
use crate::types::{ActiveWorkflow, PingResult};

/// Execution context passed to slash command handlers
#[derive(Clone, Debug)]
pub struct CommandContext {
    pub owner: String,
    pub repo: String,
    pub fqdn: String,
    pub pat: String,
    pub app_id: String,
    pub token: String,
    pub server_location: String,
}

#[allow(async_fn_in_trait)]
trait CommandBackend {
    async fn ping(&self, fqdn: &str, port: u16) -> PingResult;
    async fn resolve_doh(&self, fqdn: &str) -> Option<String>;
    async fn active_workflow(&self, owner: &str, repo: &str, pat: &str) -> Option<ActiveWorkflow>;
    async fn dispatch(
        &self,
        owner: &str,
        repo: &str,
        pat: &str,
        workflow_filename: &str,
    ) -> Result<(), String>;
    async fn respond(&self, app_id: &str, token: &str, content: &str);
}

struct RealBackend;

impl CommandBackend for RealBackend {
    async fn ping(&self, fqdn: &str, port: u16) -> PingResult {
        ping_minecraft_server(fqdn, port).await
    }

    async fn resolve_doh(&self, fqdn: &str) -> Option<String> {
        resolve_ip_doh(fqdn).await
    }

    async fn active_workflow(&self, owner: &str, repo: &str, pat: &str) -> Option<ActiveWorkflow> {
        get_active_workflow(owner, repo, pat).await
    }

    async fn dispatch(
        &self,
        owner: &str,
        repo: &str,
        pat: &str,
        workflow_filename: &str,
    ) -> Result<(), String> {
        dispatch_workflow(owner, repo, pat, workflow_filename).await
    }

    async fn respond(&self, app_id: &str, token: &str, content: &str) {
        update_deferred_response(app_id, token, content).await;
    }
}

/// Route and execute the requested slash command
pub async fn execute_command(command: &str, ctx: &CommandContext) {
    execute_command_with(command, ctx, &RealBackend).await;
}

async fn execute_command_with<B: CommandBackend>(command: &str, ctx: &CommandContext, backend: &B) {
    match command {
        "mc-status" => handle_status_with(ctx, backend).await,
        "mc-start" => handle_start_with(ctx, backend).await,
        "mc-stop" => handle_stop_with(ctx, backend).await,
        _ => {}
    }
}

async fn resolve_direct_ip<B: CommandBackend>(
    ping_result: &PingResult,
    fqdn: &str,
    backend: &B,
) -> Option<String> {
    if !ping_result.is_online {
        return None;
    }
    match ping_result.ip.as_deref().and_then(clean_ip) {
        Some(ip) => Some(ip.to_string()),
        None => backend.resolve_doh(fqdn).await,
    }
    .filter(|ip| ip != fqdn)
}

/// Handle `/mc-status`: ping TCP port 25565 and check ongoing GitHub Actions workflows
pub async fn handle_status(ctx: &CommandContext) {
    handle_status_with(ctx, &RealBackend).await;
}

async fn handle_status_with<B: CommandBackend>(ctx: &CommandContext, backend: &B) {
    let (ping_result, active_workflow) = futures_util::future::join(
        backend.ping(&ctx.fqdn, 25565),
        backend.active_workflow(&ctx.owner, &ctx.repo, &ctx.pat),
    )
    .await;

    let direct_ip = resolve_direct_ip(&ping_result, &ctx.fqdn, backend).await;

    let msg = format_status_message(
        active_workflow,
        ping_result.is_online,
        &ctx.fqdn,
        direct_ip.as_deref(),
        &ctx.server_location,
    );
    backend.respond(&ctx.app_id, &ctx.token, &msg).await;
}

/// Handle `/mc-start`: verify no active conflict, check if already online, dispatch workflow
pub async fn handle_start(ctx: &CommandContext) {
    handle_start_with(ctx, &RealBackend).await;
}

async fn handle_start_with<B: CommandBackend>(ctx: &CommandContext, backend: &B) {
    // Guard 1: Concurrency check on active workflow
    if let Some(active) = backend
        .active_workflow(&ctx.owner, &ctx.repo, &ctx.pat)
        .await
    {
        let msg = format_blocked_action(active, true);
        backend.respond(&ctx.app_id, &ctx.token, &msg).await;
        return;
    }

    // Guard 2: Direct FQDN TCP ping to check if already online
    let ping_result = backend.ping(&ctx.fqdn, 25565).await;
    if ping_result.is_online {
        let direct_ip = resolve_direct_ip(&ping_result, &ctx.fqdn, backend).await;
        let msg = format_already_running_message(&ctx.fqdn, direct_ip.as_deref());
        backend.respond(&ctx.app_id, &ctx.token, &msg).await;
        return;
    }

    match backend
        .dispatch(&ctx.owner, &ctx.repo, &ctx.pat, "server-start.yml")
        .await
    {
        Ok(_) => {
            backend
                .respond(
                    &ctx.app_id,
                    &ctx.token,
                    &format!(
                        "🚀 **Starting Minecraft Server!**\n\
                         Ephemeral node provisioning on Hetzner Cloud (`{}`).\n\
                         Connect in ~90s at `{}`.",
                        ctx.server_location, ctx.fqdn
                    ),
                )
                .await;
        }
        Err(e) => {
            backend
                .respond(
                    &ctx.app_id,
                    &ctx.token,
                    &format!("❌ **Failed to dispatch server-start workflow:** {e}"),
                )
                .await;
        }
    }
}

/// Handle `/mc-stop`: verify no conflicting start workflow, dispatch graceful shutdown workflow
pub async fn handle_stop(ctx: &CommandContext) {
    handle_stop_with(ctx, &RealBackend).await;
}

async fn handle_stop_with<B: CommandBackend>(ctx: &CommandContext, backend: &B) {
    // Guard: Concurrency check on active workflow
    let (active, ping_result) = futures_util::future::join(
        backend.active_workflow(&ctx.owner, &ctx.repo, &ctx.pat),
        backend.ping(&ctx.fqdn, 25565),
    )
    .await;
    if let Some(active_wf) = active {
        let msg = format_blocked_action(active_wf, false);
        backend.respond(&ctx.app_id, &ctx.token, &msg).await;
        return;
    }

    match backend
        .dispatch(&ctx.owner, &ctx.repo, &ctx.pat, "server-stop.yml")
        .await
    {
        Ok(_) => {
            let status_note = if ping_result.is_online {
                "🛑 **Stopping Minecraft Server...**\n\
                Flushing chunks, taking world backup, and terminating ephemeral VM."
            } else {
                "🛑 **Server port is already offline.**\n\
                Dispatched teardown workflow to ensure no orphaned cloud resources remain."
            };
            backend.respond(&ctx.app_id, &ctx.token, status_note).await;
        }
        Err(e) => {
            backend
                .respond(
                    &ctx.app_id,
                    &ctx.token,
                    &format!("❌ **Failed to dispatch server-stop workflow:** {e}"),
                )
                .await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    struct MockBackend {
        ping_result: PingResult,
        doh_ip: Option<String>,
        active_workflow: Option<ActiveWorkflow>,
        dispatch_result: Result<(), String>,
        dispatched_workflows: RefCell<Vec<String>>,
        responses: RefCell<Vec<String>>,
    }

    impl MockBackend {
        fn new() -> Self {
            Self {
                ping_result: PingResult {
                    is_online: false,
                    ip: None,
                },
                doh_ip: None,
                active_workflow: None,
                dispatch_result: Ok(()),
                dispatched_workflows: RefCell::new(Vec::new()),
                responses: RefCell::new(Vec::new()),
            }
        }
    }

    impl CommandBackend for MockBackend {
        async fn ping(&self, _fqdn: &str, _port: u16) -> PingResult {
            self.ping_result.clone()
        }

        async fn resolve_doh(&self, _fqdn: &str) -> Option<String> {
            self.doh_ip.clone()
        }

        async fn active_workflow(
            &self,
            _owner: &str,
            _repo: &str,
            _pat: &str,
        ) -> Option<ActiveWorkflow> {
            self.active_workflow
        }

        async fn dispatch(
            &self,
            _owner: &str,
            _repo: &str,
            _pat: &str,
            workflow_filename: &str,
        ) -> Result<(), String> {
            self.dispatched_workflows
                .borrow_mut()
                .push(workflow_filename.to_string());
            self.dispatch_result.clone()
        }

        async fn respond(&self, _app_id: &str, _token: &str, content: &str) {
            self.responses.borrow_mut().push(content.to_string());
        }
    }

    fn test_ctx() -> CommandContext {
        CommandContext {
            owner: "example-owner".to_string(),
            repo: "example-repo".to_string(),
            fqdn: "mc.example.com".to_string(),
            pat: "ghp_test".to_string(),
            app_id: "app_123".to_string(),
            token: "tok_456".to_string(),
            server_location: "nbg1".to_string(),
        }
    }

    #[test]
    fn test_status_online_falls_back_to_doh_when_socket_ip_missing() {
        let ctx = test_ctx();
        let mut backend = MockBackend::new();
        backend.ping_result = PingResult {
            is_online: true,
            ip: None,
        };
        backend.doh_ip = Some("142.132.1.2".to_string());

        futures_util::FutureExt::now_or_never(execute_command_with("mc-status", &ctx, &backend))
            .unwrap();

        let responses = backend.responses.borrow();
        assert_eq!(responses.len(), 1);
        assert!(responses[0].contains("ONLINE"));
        assert!(responses[0].contains("142.132.1.2"));
    }

    #[test]
    fn test_start_blocked_when_workflow_active() {
        let ctx = test_ctx();
        let mut backend = MockBackend::new();
        backend.active_workflow = Some(ActiveWorkflow::Stop);

        futures_util::FutureExt::now_or_never(execute_command_with("mc-start", &ctx, &backend))
            .unwrap();

        assert!(backend.dispatched_workflows.borrow().is_empty());
        let responses = backend.responses.borrow();
        assert_eq!(responses.len(), 1);
        assert!(responses[0].contains("Action blocked"));
    }

    #[test]
    fn test_start_skips_dispatch_when_already_online() {
        let ctx = test_ctx();
        let mut backend = MockBackend::new();
        backend.ping_result = PingResult {
            is_online: true,
            ip: Some("142.132.1.2:25565".to_string()),
        };

        futures_util::FutureExt::now_or_never(execute_command_with("mc-start", &ctx, &backend))
            .unwrap();

        assert!(backend.dispatched_workflows.borrow().is_empty());
        let responses = backend.responses.borrow();
        assert_eq!(responses.len(), 1);
        assert!(responses[0].contains("already running"));
        assert!(responses[0].contains("142.132.1.2"));
    }

    #[test]
    fn test_start_dispatches_workflow_and_uses_configured_location() {
        let ctx = test_ctx();
        let backend = MockBackend::new();

        futures_util::FutureExt::now_or_never(execute_command_with("mc-start", &ctx, &backend))
            .unwrap();

        assert_eq!(
            *backend.dispatched_workflows.borrow(),
            vec!["server-start.yml".to_string()]
        );
        let responses = backend.responses.borrow();
        assert_eq!(responses.len(), 1);
        assert!(responses[0].contains("Starting Minecraft Server"));
        assert!(responses[0].contains("`nbg1`"));
    }

    #[test]
    fn test_stop_dispatches_and_reports_online_vs_offline_note() {
        let ctx = test_ctx();

        // Case 1: Server is online
        let mut online_backend = MockBackend::new();
        online_backend.ping_result = PingResult {
            is_online: true,
            ip: None,
        };
        futures_util::FutureExt::now_or_never(execute_command_with(
            "mc-stop",
            &ctx,
            &online_backend,
        ))
        .unwrap();
        assert_eq!(
            *online_backend.dispatched_workflows.borrow(),
            vec!["server-stop.yml".to_string()]
        );
        assert!(online_backend.responses.borrow()[0].contains("Stopping Minecraft Server"));

        // Case 2: Server port is already offline (still dispatches teardown for orphan cleanup)
        let offline_backend = MockBackend::new();
        futures_util::FutureExt::now_or_never(execute_command_with(
            "mc-stop",
            &ctx,
            &offline_backend,
        ))
        .unwrap();
        assert_eq!(
            *offline_backend.dispatched_workflows.borrow(),
            vec!["server-stop.yml".to_string()]
        );
        assert!(offline_backend.responses.borrow()[0].contains("Server port is already offline"));
    }

    #[test]
    fn test_unknown_command_is_ignored() {
        let ctx = test_ctx();
        let backend = MockBackend::new();

        futures_util::FutureExt::now_or_never(execute_command_with("unknown-cmd", &ctx, &backend))
            .unwrap();

        assert!(backend.dispatched_workflows.borrow().is_empty());
        assert!(backend.responses.borrow().is_empty());
    }
}
