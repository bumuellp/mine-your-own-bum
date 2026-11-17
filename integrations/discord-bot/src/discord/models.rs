//! Strongly typed data models for Discord interaction payloads

use serde::Deserialize;

#[derive(Clone, Debug, Deserialize)]
pub struct Interaction {
    #[serde(rename = "type")]
    pub interaction_type: u8,
    #[serde(default)]
    pub token: Option<String>,
    #[serde(default)]
    pub data: Option<CommandData>,
    #[serde(default)]
    pub member: Option<Member>,
    #[serde(default)]
    pub user: Option<User>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct CommandData {
    pub name: String,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Member {
    pub user: Option<User>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct User {
    pub id: String,
}

impl Interaction {
    /// Extract user ID from either guild member object or direct message user object
    pub fn user_id(&self) -> Option<&str> {
        self.member
            .as_ref()
            .and_then(|m| m.user.as_ref())
            .map(|u| u.id.as_str())
            .or_else(|| self.user.as_ref().map(|u| u.id.as_str()))
    }

    /// Extract command name if this is an application command
    pub fn command_name(&self) -> Option<&str> {
        self.data.as_ref().map(|d| d.name.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_deserialize_ping_interaction() {
        let json = r#"{"type": 1}"#;
        let interaction: Interaction = serde_json::from_str(json).unwrap();
        assert_eq!(interaction.interaction_type, 1);
        assert!(interaction.user_id().is_none());
        assert!(interaction.command_name().is_none());
    }

    #[test]
    fn test_deserialize_command_guild_interaction() {
        let json = r#"{
            "type": 2,
            "token": "secret_token_123",
            "data": { "name": "mc-status" },
            "member": {
                "user": { "id": "111222333" }
            }
        }"#;
        let interaction: Interaction = serde_json::from_str(json).unwrap();
        assert_eq!(interaction.interaction_type, 2);
        assert_eq!(interaction.token.as_deref(), Some("secret_token_123"));
        assert_eq!(interaction.command_name(), Some("mc-status"));
        assert_eq!(interaction.user_id(), Some("111222333"));
    }

    #[test]
    fn test_deserialize_command_dm_interaction() {
        let json = r#"{
            "type": 2,
            "token": "dm_token_456",
            "data": { "name": "mc-start" },
            "user": { "id": "444555666" }
        }"#;
        let interaction: Interaction = serde_json::from_str(json).unwrap();
        assert_eq!(interaction.interaction_type, 2);
        assert_eq!(interaction.command_name(), Some("mc-start"));
        assert_eq!(interaction.user_id(), Some("444555666"));
    }
}
