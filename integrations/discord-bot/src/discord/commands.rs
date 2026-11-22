//! Discord slash command handlers for Minecraft server control and sidecar agent operations.

use super::client::update_deferred_response;
use super::format::{
    format_agent_error, format_already_running_message, format_blocked_action, format_logs_message,
    format_mods_hint, format_mods_message, format_players_message, format_rcon_output,
    format_status_initializing_message, format_status_message, format_system_message,
};
use super::models::{CommandData, option_str_from};
use crate::agent::{
    AgentError, AgentPlayers, AgentSystem, fetch_logs, fetch_players, fetch_system, post_backup,
    post_rcon, post_restart, post_say, post_whitelist,
};
use crate::github::{dispatch_workflow, get_active_workflow};
use crate::minecraft::{clean_ip, ping_minecraft_server, resolve_ip_doh};
use crate::types::{ActiveWorkflow, ModConfig, PingResult};
use worker::Fetcher;

/// Channel routing scope for a Discord slash command.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChannelScope {
    /// Operational commands restricted to `COMMAND_CHANNEL_ID` (`#mc-commands`).
    Commands,
    /// In-game chat commands restricted to `CHAT_CHANNEL_ID` (`#mc-chat`).
    Chat,
}

/// Authorization tier for a Discord slash command.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AccessTier {
    /// Accessible to any guild member in the allowed channel.
    Public,
    /// Restricted to `ALLOWED_USER_IDS` when configured; open when `ALLOWED_USER_IDS` is empty.
    Lifecycle,
    /// Fail-closed: requires `ALLOWED_USER_IDS` to be non-empty and contain the caller's ID.
    AdminFailClosed,
}

/// Unified metadata record for a registered Discord slash command.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CommandSpec {
    pub command: SlashCommand,
    pub name: &'static str,
    pub channel_scope: ChannelScope,
    pub access_tier: AccessTier,
}

/// Single-source-of-truth macro generating the `SlashCommand` enum, its `CommandSpec` table,
/// parser, metadata accessors, and handler dispatch from one declarative table.
macro_rules! define_slash_commands {
    ($( ($variant:ident, $name:literal, $scope:ident, $tier:ident, $handler:ident) ),+ $(,)?) => {
        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub enum SlashCommand {
            $( $variant, )+
        }

        impl SlashCommand {
            /// Static registry of all slash command specifications.
            pub const ALL: &'static [CommandSpec] = &[
                $(
                    CommandSpec {
                        command: Self::$variant,
                        name: $name,
                        channel_scope: ChannelScope::$scope,
                        access_tier: AccessTier::$tier,
                    },
                )+
            ];

            /// Returns the complete `CommandSpec` data structure for this command.
            pub const fn spec(self) -> CommandSpec {
                match self {
                    $(
                        Self::$variant => CommandSpec {
                            command: Self::$variant,
                            name: $name,
                            channel_scope: ChannelScope::$scope,
                            access_tier: AccessTier::$tier,
                        },
                    )+
                }
            }

            /// Parses a Discord slash command name at the webhook boundary using `Self::ALL`.
            pub fn parse(name: &str) -> Option<Self> {
                Self::ALL
                    .iter()
                    .find(|spec| spec.name == name)
                    .map(|spec| spec.command)
            }

            /// Canonical Discord slash command string.
            pub const fn as_str(self) -> &'static str {
                self.spec().name
            }

            /// Channel routing scope for this command.
            pub const fn channel_scope(self) -> ChannelScope {
                self.spec().channel_scope
            }

            /// ACL permission tier for this command.
            pub const fn access_tier(self) -> AccessTier {
                self.spec().access_tier
            }
        }

        async fn execute_command_with<B: CommandBackend>(
            command: SlashCommand,
            ctx: &CommandContext,
            backend: &B,
        ) {
            match command {
                $( SlashCommand::$variant => $handler(ctx, backend).await, )+
            }
        }
    };
}

define_slash_commands! {
    (Status,    "mc-status",    Commands, Public,          handle_status_with),
    (Mods,      "mc-mods",      Commands, Public,          handle_mods_with),
    (Start,     "mc-start",     Commands, Lifecycle,       handle_start_with),
    (Stop,      "mc-stop",      Commands, Lifecycle,       handle_stop_with),
    (Players,   "mc-players",   Commands, Public,          handle_players_with),
    (Top,       "mc-top",       Commands, Public,          handle_top_with),
    (Logs,      "mc-logs",      Commands, AdminFailClosed, handle_logs_with),
    (Say,       "mc-say",       Chat,     Public,          handle_say_with),
    (Whitelist, "mc-whitelist", Commands, AdminFailClosed, handle_whitelist_with),
    (Backup,    "mc-backup",    Commands, Lifecycle,       handle_backup_with),
    (Restart,   "mc-restart",   Commands, AdminFailClosed, handle_restart_with),
    (Cmd,       "mc-cmd",       Commands, AdminFailClosed, handle_cmd_with),
}

/// Execution context passed to slash command handlers.
#[derive(Clone, Debug)]
pub struct CommandContext {
    pub owner: String,
    pub repo: String,
    pub fqdn: String,
    pub pat: String,
    pub app_id: String,
    pub token: String,
    pub server_location: String,
    pub command_channel_id: String,
    pub caller_name: String,
    pub mod_config: ModConfig,
    pub command_data: Option<CommandData>,
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
    async fn agent_players(&self) -> Result<AgentPlayers, AgentError>;
    async fn agent_system(&self) -> Result<AgentSystem, AgentError>;
    async fn agent_logs(&self, lines: u32) -> Result<String, AgentError>;
    async fn agent_say(&self, sender: &str, message: &str) -> Result<(), AgentError>;
    async fn agent_whitelist(
        &self,
        action: &str,
        player: Option<&str>,
    ) -> Result<String, AgentError>;
    async fn agent_backup(&self) -> Result<String, AgentError>;
    async fn agent_restart(&self) -> Result<String, AgentError>;
    async fn agent_rcon(&self, command: &str) -> Result<String, AgentError>;
    async fn respond(&self, app_id: &str, token: &str, content: &str);
}

struct RealBackend {
    fetcher: Option<Fetcher>,
    agent_secret: String,
}

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

    async fn agent_players(&self) -> Result<AgentPlayers, AgentError> {
        fetch_players(self.fetcher.as_ref(), &self.agent_secret).await
    }

    async fn agent_system(&self) -> Result<AgentSystem, AgentError> {
        fetch_system(self.fetcher.as_ref(), &self.agent_secret).await
    }

    async fn agent_logs(&self, lines: u32) -> Result<String, AgentError> {
        fetch_logs(self.fetcher.as_ref(), &self.agent_secret, lines).await
    }

    async fn agent_say(&self, sender: &str, message: &str) -> Result<(), AgentError> {
        post_say(self.fetcher.as_ref(), &self.agent_secret, sender, message).await
    }

    async fn agent_whitelist(
        &self,
        action: &str,
        player: Option<&str>,
    ) -> Result<String, AgentError> {
        post_whitelist(self.fetcher.as_ref(), &self.agent_secret, action, player).await
    }

    async fn agent_backup(&self) -> Result<String, AgentError> {
        post_backup(self.fetcher.as_ref(), &self.agent_secret).await
    }

    async fn agent_restart(&self) -> Result<String, AgentError> {
        post_restart(self.fetcher.as_ref(), &self.agent_secret).await
    }

    async fn agent_rcon(&self, command: &str) -> Result<String, AgentError> {
        post_rcon(self.fetcher.as_ref(), &self.agent_secret, command).await
    }

    async fn respond(&self, app_id: &str, token: &str, content: &str) {
        update_deferred_response(app_id, token, content).await;
    }
}

/// Route and execute the requested slash command using the Cloudflare Workers VPC binding.
pub async fn execute_command(
    command: SlashCommand,
    ctx: &CommandContext,
    fetcher: Option<Fetcher>,
    agent_secret: String,
) {
    let backend = RealBackend {
        fetcher,
        agent_secret,
    };
    execute_command_with(command, ctx, &backend).await;
}

async fn handle_mods_with<B: CommandBackend>(ctx: &CommandContext, backend: &B) {
    let msg = format_mods_message(&ctx.mod_config);
    backend.respond(&ctx.app_id, &ctx.token, &msg).await;
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

async fn handle_status_with<B: CommandBackend>(ctx: &CommandContext, backend: &B) {
    let (ping_result, active_workflow) = futures_util::future::join(
        backend.ping(&ctx.fqdn, 25565),
        backend.active_workflow(&ctx.owner, &ctx.repo, &ctx.pat),
    )
    .await;

    if active_workflow.is_none()
        && !ping_result.is_online
        && let Ok(sys) = backend.agent_system().await
    {
        let msg = format_status_initializing_message(&ctx.fqdn, &sys);
        backend.respond(&ctx.app_id, &ctx.token, &msg).await;
        return;
    }

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

async fn handle_start_with<B: CommandBackend>(ctx: &CommandContext, backend: &B) {
    if let Some(active) = backend
        .active_workflow(&ctx.owner, &ctx.repo, &ctx.pat)
        .await
    {
        let msg = format_blocked_action(active, true);
        backend.respond(&ctx.app_id, &ctx.token, &msg).await;
        return;
    }

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
            let mod_hint = format_mods_hint(&ctx.mod_config);
            backend
                .respond(
                    &ctx.app_id,
                    &ctx.token,
                    &format!(
                        "🚀 **Starting Minecraft Server!**\n\
                         Ephemeral node provisioning on Hetzner Cloud (`{}`).\n\
                         Connect in ~90s at `{}`.{mod_hint}",
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

async fn handle_stop_with<B: CommandBackend>(ctx: &CommandContext, backend: &B) {
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

async fn handle_players_with<B: CommandBackend>(ctx: &CommandContext, backend: &B) {
    let msg = match backend.agent_players().await {
        Ok(players) => format_players_message(&players),
        Err(e) => format_agent_error(&e, &ctx.command_channel_id),
    };
    backend.respond(&ctx.app_id, &ctx.token, &msg).await;
}

async fn handle_top_with<B: CommandBackend>(ctx: &CommandContext, backend: &B) {
    let msg = match backend.agent_system().await {
        Ok(sys) => format_system_message(&sys),
        Err(e) => format_agent_error(&e, &ctx.command_channel_id),
    };
    backend.respond(&ctx.app_id, &ctx.token, &msg).await;
}

async fn handle_logs_with<B: CommandBackend>(ctx: &CommandContext, backend: &B) {
    let lines = ctx
        .command_data
        .as_ref()
        .and_then(|d| d.option_i64("lines"))
        .map(|n| n.clamp(1, 80) as u32)
        .unwrap_or(40);

    let msg = match backend.agent_logs(lines).await {
        Ok(logs) => format_logs_message(&logs),
        Err(e) => format_agent_error(&e, &ctx.command_channel_id),
    };
    backend.respond(&ctx.app_id, &ctx.token, &msg).await;
}

async fn handle_say_with<B: CommandBackend>(ctx: &CommandContext, backend: &B) {
    let raw_msg = ctx
        .command_data
        .as_ref()
        .and_then(|d| d.option_str("message"))
        .map(str::trim)
        .unwrap_or_default();

    if raw_msg.is_empty() {
        backend
            .respond(
                &ctx.app_id,
                &ctx.token,
                "⚠️ Please provide a non-empty message.",
            )
            .await;
        return;
    }

    let msg = match backend.agent_say(&ctx.caller_name, raw_msg).await {
        Ok(()) => format!("💬 **{}:** {}", ctx.caller_name, raw_msg),
        Err(e) => format_agent_error(&e, &ctx.command_channel_id),
    };
    backend.respond(&ctx.app_id, &ctx.token, &msg).await;
}

async fn handle_whitelist_with<B: CommandBackend>(ctx: &CommandContext, backend: &B) {
    let Some((action, opts)) = ctx.command_data.as_ref().and_then(|d| d.subcommand()) else {
        backend
            .respond(
                &ctx.app_id,
                &ctx.token,
                "⚠️ Usage: `/mc-whitelist <add|remove|list>`",
            )
            .await;
        return;
    };

    let player = option_str_from(opts, "player");
    let msg = match backend.agent_whitelist(action, player).await {
        Ok(out) => format_rcon_output(&format!("📋 **Whitelist (`{action}`):**"), &out),
        Err(e) => format_agent_error(&e, &ctx.command_channel_id),
    };
    backend.respond(&ctx.app_id, &ctx.token, &msg).await;
}

async fn handle_backup_with<B: CommandBackend>(ctx: &CommandContext, backend: &B) {
    let msg = match backend.agent_backup().await {
        Ok(out) => format_rcon_output("💾 **World Save / Flush:**", &out),
        Err(e) => format_agent_error(&e, &ctx.command_channel_id),
    };
    backend.respond(&ctx.app_id, &ctx.token, &msg).await;
}

async fn handle_restart_with<B: CommandBackend>(ctx: &CommandContext, backend: &B) {
    let msg = match backend.agent_restart().await {
        Ok(out) => format_rcon_output("🔄 **Minecraft JVM Restart:**", &out),
        Err(e) => format_agent_error(&e, &ctx.command_channel_id),
    };
    backend.respond(&ctx.app_id, &ctx.token, &msg).await;
}

async fn handle_cmd_with<B: CommandBackend>(ctx: &CommandContext, backend: &B) {
    let cmd = ctx
        .command_data
        .as_ref()
        .and_then(|d| d.option_str("command"))
        .map(str::trim)
        .unwrap_or_default();

    if cmd.is_empty() {
        backend
            .respond(
                &ctx.app_id,
                &ctx.token,
                "⚠️ Please provide a command to execute.",
            )
            .await;
        return;
    }

    let msg = match backend.agent_rcon(cmd).await {
        Ok(out) => format_rcon_output(&format!("⌨️ **RCON (`{cmd}`):**"), &out),
        Err(e) => format_agent_error(&e, &ctx.command_channel_id),
    };
    backend.respond(&ctx.app_id, &ctx.token, &msg).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::discord::models::CommandOption;
    use std::cell::RefCell;

    struct MockBackend {
        ping_result: PingResult,
        doh_ip: Option<String>,
        active_workflow: Option<ActiveWorkflow>,
        dispatch_result: Result<(), String>,
        players_result: Result<AgentPlayers, AgentError>,
        system_result: Result<AgentSystem, AgentError>,
        logs_result: Result<String, AgentError>,
        say_result: Result<(), AgentError>,
        whitelist_result: Result<String, AgentError>,
        backup_result: Result<String, AgentError>,
        restart_result: Result<String, AgentError>,
        rcon_result: Result<String, AgentError>,
        dispatched_workflows: RefCell<Vec<String>>,
        say_calls: RefCell<Vec<(String, String)>>,
        rcon_calls: RefCell<Vec<String>>,
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
                players_result: Ok(AgentPlayers {
                    online: 1,
                    max: 20,
                    players: vec!["Steve".to_string()],
                }),
                system_result: Ok(AgentSystem {
                    load_1m: 0.25,
                    load_5m: 0.20,
                    load_15m: 0.15,
                    mem_used_mb: 4000,
                    mem_total_mb: 8000,
                    disk_used_gb: 3.2,
                    disk_total_gb: 15.0,
                    uptime_seconds: 1200,
                    online_players: 1,
                    max_players: 20,
                    players: vec!["Steve".to_string()],
                }),
                logs_result: Ok("[12:00:00] [Server thread/INFO]: Done!".to_string()),
                say_result: Ok(()),
                whitelist_result: Ok("Added Steve to the whitelist".to_string()),
                backup_result: Ok("Saved the game".to_string()),
                restart_result: Ok("Stopping the server".to_string()),
                rcon_result: Ok("There are 1 of a max of 20 players online: Steve".to_string()),
                dispatched_workflows: RefCell::new(Vec::new()),
                say_calls: RefCell::new(Vec::new()),
                rcon_calls: RefCell::new(Vec::new()),
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

        async fn agent_players(&self) -> Result<AgentPlayers, AgentError> {
            self.players_result.clone()
        }

        async fn agent_system(&self) -> Result<AgentSystem, AgentError> {
            self.system_result.clone()
        }

        async fn agent_logs(&self, _lines: u32) -> Result<String, AgentError> {
            self.logs_result.clone()
        }

        async fn agent_say(&self, sender: &str, message: &str) -> Result<(), AgentError> {
            self.say_calls
                .borrow_mut()
                .push((sender.to_string(), message.to_string()));
            self.say_result.clone()
        }

        async fn agent_whitelist(
            &self,
            _action: &str,
            _player: Option<&str>,
        ) -> Result<String, AgentError> {
            self.whitelist_result.clone()
        }

        async fn agent_backup(&self) -> Result<String, AgentError> {
            self.backup_result.clone()
        }

        async fn agent_restart(&self) -> Result<String, AgentError> {
            self.restart_result.clone()
        }

        async fn agent_rcon(&self, command: &str) -> Result<String, AgentError> {
            self.rcon_calls.borrow_mut().push(command.to_string());
            self.rcon_result.clone()
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
            command_channel_id: "100200300".to_string(),
            caller_name: "Steve".to_string(),
            mod_config: ModConfig::default(),
            command_data: None,
        }
    }

    #[test]
    fn test_mc_mods_command_and_start_hint_for_vanilla_and_modpack() {
        let mut ctx = test_ctx();
        let backend = MockBackend::new();

        // 1. Default / Server-only + Optional mods -> no client mods required to join, but lists optional & server-only
        ctx.mod_config = ModConfig {
            server_type: "FABRIC".to_string(),
            modloader: "fabric".to_string(),
            mc_version: "26.3".to_string(),
            modrinth_modpack: String::new(),
            client_required_mods: String::new(),
            client_optional_mods: "fabric-api,lithium,ferrite-core".to_string(),
            server_only_mods: "geyser:beta,floodgate:beta,easyauth".to_string(),
            curseforge_projects: String::new(),
        };
        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Mods,
            &ctx,
            &backend,
        ))
        .unwrap();
        let fabric_reply = backend.responses.borrow().last().unwrap().clone();
        assert!(fabric_reply.contains("No client mods required to join"));
        assert!(fabric_reply.contains("Optional Client Mods"));
        assert!(fabric_reply.contains("https://modrinth.com/mod/lithium"));
        assert!(fabric_reply.contains("https://fabricmc.net/use/installer/"));
        assert!(fabric_reply.contains("Server-Only Mods"));
        assert!(fabric_reply.contains("`geyser:beta`"));

        // 2. Modpack + required client mods + server-only neologin
        ctx.mod_config = ModConfig {
            server_type: "MODRINTH".to_string(),
            modloader: "neoforge".to_string(),
            mc_version: "1.21.1".to_string(),
            modrinth_modpack: "create-combined:beta".to_string(),
            client_required_mods: "mekanism,ae2,pipez:beta".to_string(),
            client_optional_mods: String::new(),
            server_only_mods: "neologin".to_string(),
            curseforge_projects: "projecte".to_string(),
        };
        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Mods,
            &ctx,
            &backend,
        ))
        .unwrap();
        let mods_reply = backend.responses.borrow().last().unwrap().clone();
        assert!(mods_reply.contains("https://neoforged.net/"));
        assert!(mods_reply.contains("https://modrinth.com/modpack/create-combined"));
        assert!(mods_reply.contains("https://modrinth.com/mod/mekanism"));
        assert!(mods_reply.contains("https://www.curseforge.com/minecraft/mc-mods/projecte"));
        assert!(mods_reply.contains("Server-Only Mods (No Client Install Needed):** `neologin`"));

        // 3. /mc-start includes concise /mc-mods hint when client mods are required
        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Start,
            &ctx,
            &backend,
        ))
        .unwrap();
        let start_reply = backend.responses.borrow().last().unwrap().clone();
        assert!(start_reply.contains("create-combined:beta"));
        assert!(start_reply.contains("/mc-mods"));
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

        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Status,
            &ctx,
            &backend,
        ))
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

        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Start,
            &ctx,
            &backend,
        ))
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

        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Start,
            &ctx,
            &backend,
        ))
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

        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Start,
            &ctx,
            &backend,
        ))
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

        let mut online_backend = MockBackend::new();
        online_backend.ping_result = PingResult {
            is_online: true,
            ip: None,
        };
        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Stop,
            &ctx,
            &online_backend,
        ))
        .unwrap();
        assert_eq!(
            *online_backend.dispatched_workflows.borrow(),
            vec!["server-stop.yml".to_string()]
        );
        assert!(online_backend.responses.borrow()[0].contains("Stopping Minecraft Server"));

        let offline_backend = MockBackend::new();
        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Stop,
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
    fn test_agent_commands_players_top_logs_say_whitelist_backup_restart_cmd() {
        let mut ctx = test_ctx();
        let backend = MockBackend::new();

        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Players,
            &ctx,
            &backend,
        ))
        .unwrap();
        assert!(
            backend
                .responses
                .borrow()
                .last()
                .unwrap()
                .contains("`Steve`")
        );

        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Top,
            &ctx,
            &backend,
        ))
        .unwrap();
        assert!(
            backend
                .responses
                .borrow()
                .last()
                .unwrap()
                .contains("4000 MB")
        );

        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Logs,
            &ctx,
            &backend,
        ))
        .unwrap();
        assert!(backend.responses.borrow().last().unwrap().contains("Done!"));

        ctx.command_data = Some(CommandData {
            name: "mc-say".to_string(),
            options: vec![CommandOption {
                name: "message".to_string(),
                option_type: 3,
                value: Some(serde_json::json!("Hello miners!")),
                options: vec![],
            }],
        });
        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Say,
            &ctx,
            &backend,
        ))
        .unwrap();
        assert_eq!(
            *backend.say_calls.borrow(),
            vec![("Steve".to_string(), "Hello miners!".to_string())]
        );

        ctx.command_data = Some(CommandData {
            name: "mc-whitelist".to_string(),
            options: vec![CommandOption {
                name: "add".to_string(),
                option_type: 1,
                value: None,
                options: vec![CommandOption {
                    name: "player".to_string(),
                    option_type: 3,
                    value: Some(serde_json::json!("Alex")),
                    options: vec![],
                }],
            }],
        });
        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Whitelist,
            &ctx,
            &backend,
        ))
        .unwrap();
        assert!(
            backend
                .responses
                .borrow()
                .last()
                .unwrap()
                .contains("Added Steve")
        );

        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Backup,
            &ctx,
            &backend,
        ))
        .unwrap();
        assert!(
            backend
                .responses
                .borrow()
                .last()
                .unwrap()
                .contains("Saved the game")
        );

        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Restart,
            &ctx,
            &backend,
        ))
        .unwrap();
        assert!(
            backend
                .responses
                .borrow()
                .last()
                .unwrap()
                .contains("Stopping the server")
        );

        ctx.command_data = Some(CommandData {
            name: "mc-cmd".to_string(),
            options: vec![CommandOption {
                name: "command".to_string(),
                option_type: 3,
                value: Some(serde_json::json!("time set day")),
                options: vec![],
            }],
        });
        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Cmd,
            &ctx,
            &backend,
        ))
        .unwrap();
        assert_eq!(
            *backend.rcon_calls.borrow(),
            vec!["time set day".to_string()]
        );
    }

    #[test]
    fn test_agent_offline_graceful_response() {
        let ctx = test_ctx();
        let mut backend = MockBackend::new();
        backend.players_result = Err(AgentError::Offline);

        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Players,
            &ctx,
            &backend,
        ))
        .unwrap();
        let msg = backend.responses.borrow()[0].clone();
        assert!(msg.contains("currently offline"));
        assert!(msg.contains("<#100200300>"));
    }

    #[test]
    fn test_agent_starting_and_status_initializing_responses() {
        let ctx = test_ctx();
        let mut backend = MockBackend::new();
        backend.players_result = Err(AgentError::ServerStarting(
            "RCON connection refused".to_string(),
        ));

        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Players,
            &ctx,
            &backend,
        ))
        .unwrap();
        let players_msg = backend.responses.borrow()[0].clone();
        assert!(players_msg.contains("VM & Sidecar Agent are ONLINE"));
        assert!(players_msg.contains("/mc-logs"));

        // When Minecraft port is closed and no workflow is running, but mc-agent responds,
        // /mc-status should report INITIALIZING / RECOVERING instead of OFFLINE.
        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Status,
            &ctx,
            &backend,
        ))
        .unwrap();
        let status_msg = backend.responses.borrow()[1].clone();
        assert!(status_msg.contains("INITIALIZING / RECOVERING"));
        assert!(status_msg.contains("4000 MB / 8000 MB"));

        // When mc-agent is also offline, /mc-status reports OFFLINE.
        backend.system_result = Err(AgentError::Offline);
        futures_util::FutureExt::now_or_never(execute_command_with(
            SlashCommand::Status,
            &ctx,
            &backend,
        ))
        .unwrap();
        let offline_msg = backend.responses.borrow()[2].clone();
        assert!(offline_msg.contains("OFFLINE"));
    }

    #[test]
    fn test_slash_command_parse_rejects_unknown_and_roundtrips() {
        assert_eq!(SlashCommand::parse("unknown-cmd"), None);
        for cmd in [
            SlashCommand::Status,
            SlashCommand::Mods,
            SlashCommand::Start,
            SlashCommand::Stop,
            SlashCommand::Players,
            SlashCommand::Top,
            SlashCommand::Logs,
            SlashCommand::Say,
            SlashCommand::Whitelist,
            SlashCommand::Backup,
            SlashCommand::Restart,
            SlashCommand::Cmd,
        ] {
            assert_eq!(SlashCommand::parse(cmd.as_str()), Some(cmd));
        }
    }
}
