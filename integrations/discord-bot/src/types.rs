//! Shared domain types for the Minecraft Discord bot

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActiveWorkflow {
    Start,
    Stop,
}

/// Ping result containing connectivity status and the resolved remote IP address if available
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PingResult {
    pub is_online: bool,
    pub ip: Option<String>,
}
