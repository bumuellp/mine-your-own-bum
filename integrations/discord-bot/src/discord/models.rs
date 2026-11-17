//! Pure data models and option extraction helpers for Discord interaction payloads.

use serde::Deserialize;
use serde_json::Value;

#[derive(Clone, Debug, Deserialize)]
pub struct Interaction {
    #[serde(rename = "type")]
    pub interaction_type: u8,
    #[serde(default)]
    pub token: Option<String>,
    #[serde(default)]
    pub channel_id: Option<String>,
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
    #[serde(default)]
    pub options: Vec<CommandOption>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct CommandOption {
    pub name: String,
    #[serde(rename = "type")]
    pub option_type: u8,
    #[serde(default)]
    pub value: Option<Value>,
    #[serde(default)]
    pub options: Vec<CommandOption>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Member {
    #[serde(default)]
    pub nick: Option<String>,
    pub user: Option<User>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct User {
    pub id: String,
    #[serde(default)]
    pub username: Option<String>,
    #[serde(default)]
    pub global_name: Option<String>,
}

impl CommandData {
    /// Extracts the active subcommand name and its nested options (Discord option type `1`).
    pub fn subcommand(&self) -> Option<(&str, &[CommandOption])> {
        self.options
            .iter()
            .find(|opt| opt.option_type == 1)
            .map(|opt| (opt.name.as_str(), opt.options.as_slice()))
    }

    /// Extracts a string option value by name from top-level options.
    pub fn option_str(&self, name: &str) -> Option<&str> {
        option_str_from(&self.options, name)
    }

    /// Extracts an integer option value by name from top-level options.
    pub fn option_i64(&self, name: &str) -> Option<i64> {
        self.options
            .iter()
            .find(|opt| opt.name == name)
            .and_then(|opt| opt.value.as_ref())
            .and_then(Value::as_i64)
    }
}

/// Extracts a string option value by name from an option slice.
pub fn option_str_from<'a>(options: &'a [CommandOption], name: &str) -> Option<&'a str> {
    options
        .iter()
        .find(|opt| opt.name == name)
        .and_then(|opt| opt.value.as_ref())
        .and_then(Value::as_str)
}

impl Interaction {
    /// Extract user ID from either guild member object or direct message user object.
    pub fn user_id(&self) -> Option<&str> {
        self.member
            .as_ref()
            .and_then(|m| m.user.as_ref())
            .map(|u| u.id.as_str())
            .or_else(|| self.user.as_ref().map(|u| u.id.as_str()))
    }

    /// Extract command name if this is an application command.
    pub fn command_name(&self) -> Option<&str> {
        self.data.as_ref().map(|d| d.name.as_str())
    }

    /// Extract caller display name (`member.nick` -> `global_name` -> `username`).
    pub fn caller_display_name(&self) -> String {
        if let Some(member) = &self.member {
            if let Some(nick) = member
                .nick
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                return nick.to_string();
            }
            if let Some(user) = &member.user
                && let Some(name) = user_display_name(user)
            {
                return name;
            }
        }
        if let Some(user) = &self.user
            && let Some(name) = user_display_name(user)
        {
            return name;
        }
        "DiscordUser".to_string()
    }
}

fn user_display_name(user: &User) -> Option<String> {
    user.global_name
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .or_else(|| {
            user.username
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
        })
        .map(String::from)
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
    fn test_deserialize_command_guild_interaction_with_nick_and_channel() {
        let json = r#"{
            "type": 2,
            "token": "secret_token_123",
            "channel_id": "999888777",
            "data": {
                "name": "mc-say",
                "options": [
                    { "name": "message", "type": 3, "value": "Hello server!" }
                ]
            },
            "member": {
                "nick": "ServerNick",
                "user": { "id": "111222333", "username": "steve", "global_name": "Steve" }
            }
        }"#;
        let interaction: Interaction = serde_json::from_str(json).unwrap();
        assert_eq!(interaction.interaction_type, 2);
        assert_eq!(interaction.channel_id.as_deref(), Some("999888777"));
        assert_eq!(interaction.command_name(), Some("mc-say"));
        assert_eq!(interaction.user_id(), Some("111222333"));
        assert_eq!(interaction.caller_display_name(), "ServerNick");
        assert_eq!(
            interaction.data.as_ref().unwrap().option_str("message"),
            Some("Hello server!")
        );
    }

    #[test]
    fn test_deserialize_subcommand_whitelist_and_integer_logs() {
        let wl_json = r#"{
            "type": 2,
            "data": {
                "name": "mc-whitelist",
                "options": [{
                    "name": "add",
                    "type": 1,
                    "options": [{ "name": "player", "type": 3, "value": "Alex" }]
                }]
            },
            "user": { "id": "444555666", "global_name": "AlexGlobal" }
        }"#;
        let wl: Interaction = serde_json::from_str(wl_json).unwrap();
        assert_eq!(wl.caller_display_name(), "AlexGlobal");
        let (sub, opts) = wl.data.as_ref().unwrap().subcommand().unwrap();
        assert_eq!(sub, "add");
        assert_eq!(option_str_from(opts, "player"), Some("Alex"));

        let logs_json = r#"{
            "type": 2,
            "data": {
                "name": "mc-logs",
                "options": [{ "name": "lines", "type": 4, "value": 50 }]
            }
        }"#;
        let logs: Interaction = serde_json::from_str(logs_json).unwrap();
        assert_eq!(logs.data.as_ref().unwrap().option_i64("lines"), Some(50));
    }
}
