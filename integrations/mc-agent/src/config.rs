//! Runtime environment configuration for `mc-agent`.

use std::env;

/// Configuration required by the HTTP API handlers.
#[derive(Clone, Debug)]
pub struct AgentConfig {
    pub rcon_host: String,
    pub rcon_port: u16,
    pub rcon_password: String,
    pub agent_secret: String,
    pub log_path: String,
    pub proc_dir: String,
    pub data_dir: String,
}

/// Top-level daemon runtime configuration parsed from environment variables.
#[derive(Clone, Debug)]
pub struct RuntimeConfig {
    pub listen_addr: String,
    pub agent: AgentConfig,
    pub chat_webhook_url: String,
    pub command_webhook_url: String,
    pub server_fqdn: String,
    pub server_ipv4: String,
    pub server_location: String,
    pub boot_marker_path: String,
}

impl RuntimeConfig {
    /// Loads configuration from process environment variables with sensible defaults.
    pub fn from_env() -> Self {
        let listen_addr = env::var("LISTEN_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".to_string());
        let rcon_host = env::var("RCON_HOST").unwrap_or_else(|_| "mc-server".to_string());
        let rcon_port = env::var("RCON_PORT")
            .ok()
            .and_then(|s| s.parse::<u16>().ok())
            .unwrap_or(25575);
        let rcon_password = env::var("RCON_PASSWORD").unwrap_or_default();
        let agent_secret = env::var("AGENT_SHARED_SECRET").unwrap_or_default();
        let log_path = env::var("LOG_PATH").unwrap_or_else(|_| "/logs/latest.log".to_string());
        let proc_dir = env::var("HOST_PROC_DIR").unwrap_or_else(|_| "/host/proc".to_string());
        let data_dir = env::var("DATA_DIR").unwrap_or_else(|_| "/data".to_string());

        let chat_webhook_url = env::var("DISCORD_CHAT_WEBHOOK_URL").unwrap_or_default();
        let command_webhook_url = env::var("DISCORD_COMMAND_WEBHOOK_URL")
            .ok()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| chat_webhook_url.clone());

        let server_fqdn = env::var("SERVER_FQDN").unwrap_or_default();
        let server_ipv4 = env::var("SERVER_IPV4").unwrap_or_default();
        let server_location = env::var("SERVER_LOCATION").unwrap_or_else(|_| "fsn1".to_string());
        let boot_marker_path = env::var("BOOT_MARKER_PATH")
            .unwrap_or_else(|_| "/tmp/mc-agent-boot-notified".to_string());

        Self {
            listen_addr,
            agent: AgentConfig {
                rcon_host,
                rcon_port,
                rcon_password,
                agent_secret,
                log_path,
                proc_dir,
                data_dir,
            },
            chat_webhook_url,
            command_webhook_url,
            server_fqdn,
            server_ipv4,
            server_location,
            boot_marker_path,
        }
    }

    /// Returns the loopback address used by `--healthcheck` probes.
    pub fn healthcheck_addr(&self) -> String {
        if let Some(port) = self.listen_addr.strip_prefix("0.0.0.0:") {
            format!("127.0.0.1:{port}")
        } else if let Some(port) = self.listen_addr.strip_prefix("[::]:") {
            format!("127.0.0.1:{port}")
        } else {
            self.listen_addr.clone()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_healthcheck_addr_normalizes_wildcard_binds() {
        let mut cfg = RuntimeConfig::from_env();
        cfg.listen_addr = "0.0.0.0:8080".to_string();
        assert_eq!(cfg.healthcheck_addr(), "127.0.0.1:8080");

        cfg.listen_addr = "[::]:9090".to_string();
        assert_eq!(cfg.healthcheck_addr(), "127.0.0.1:9090");

        cfg.listen_addr = "127.0.0.1:8081".to_string();
        assert_eq!(cfg.healthcheck_addr(), "127.0.0.1:8081");
    }
}
