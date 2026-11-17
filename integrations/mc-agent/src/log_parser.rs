//! Loader-agnostic parser for Minecraft `latest.log` lines
//! (Vanilla, Fabric, NeoForge/Forge, and Paper/Purpur/Spigot).

use crate::rcon::is_valid_player_name;
use crate::system::sanitize_log_line;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LogEvent {
    Chat { player: String, message: String },
    Join { player: String },
    Leave { player: String },
}

/// Strips leading `[...]` bracket headers (timestamp, thread, and NeoForge/Forge logger tags)
/// followed by `: `, returning only the core log message payload.
pub fn strip_log_prefix(line: &str) -> Option<&str> {
    let mut rest = line.trim();
    if !rest.starts_with('[') {
        return None;
    }

    // Consume one or more `[...]` segments separated by whitespace
    while rest.starts_with('[') {
        let close_idx = rest.find(']')?;
        rest = rest[close_idx + 1..].trim_start();
        if let Some(after_colon) = rest.strip_prefix(':') {
            return Some(after_colon.trim_start());
        }
    }

    None
}

/// Parses a single Minecraft server log line into a `LogEvent` (Chat, Join, or Leave).
pub fn parse_minecraft_log_event(raw_line: &str) -> Option<LogEvent> {
    // Support Vanilla/Fabric/NeoForge (`.../INFO]`) and Paper/Spigot (`[HH:MM:SS INFO]:`)
    if !raw_line.contains("/INFO]") && !raw_line.contains(" INFO]") {
        return None;
    }

    let clean = sanitize_log_line(raw_line);
    let payload = strip_log_prefix(&clean)?;
    let payload = payload
        .strip_prefix("[Not Secure] ")
        .unwrap_or(payload)
        .trim();

    // 1. Chat message: `<Player> message`
    if let Some(after_lt) = payload.strip_prefix('<')
        && let Some((player, msg)) = after_lt.split_once('>')
    {
        let player = player.trim();
        let message = msg.trim();
        if is_valid_player_name(player) && !message.is_empty() {
            return Some(LogEvent::Chat {
                player: player.to_string(),
                message: message.to_string(),
            });
        }
    }

    // 2. Join event: `<Player> joined the game`
    if let Some(player_part) = payload.strip_suffix(" joined the game") {
        let player = player_part.trim();
        if is_valid_player_name(player) {
            return Some(LogEvent::Join {
                player: player.to_string(),
            });
        }
    }

    // 3. Leave event: `<Player> left the game`
    if let Some(player_part) = payload.strip_suffix(" left the game") {
        let player = player_part.trim();
        if is_valid_player_name(player) {
            return Some(LogEvent::Leave {
                player: player.to_string(),
            });
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_vanilla_and_fabric_log_lines() {
        let chat = "[14:22:01] [Server thread/INFO]: <Steve> Building the AE2 controller!";
        assert_eq!(
            parse_minecraft_log_event(chat),
            Some(LogEvent::Chat {
                player: "Steve".to_string(),
                message: "Building the AE2 controller!".to_string()
            })
        );

        let insecure_chat =
            "[14:22:02] [Async Chat Thread - #1/INFO]: [Not Secure] <.BedrockAlex> Hi from client!";
        assert_eq!(
            parse_minecraft_log_event(insecure_chat),
            Some(LogEvent::Chat {
                player: ".BedrockAlex".to_string(),
                message: "Hi from client!".to_string()
            })
        );

        let join = "[14:22:05] [Server thread/INFO]: Steve joined the game";
        assert_eq!(
            parse_minecraft_log_event(join),
            Some(LogEvent::Join {
                player: "Steve".to_string()
            })
        );

        let leave = "[14:25:00] [Server thread/INFO]: Steve left the game";
        assert_eq!(
            parse_minecraft_log_event(leave),
            Some(LogEvent::Leave {
                player: "Steve".to_string()
            })
        );
    }

    #[test]
    fn test_parse_neoforge_and_paper_log_lines() {
        let neoforge_chat = "[14:22:01] [Server thread/INFO] [minecraft/MinecraftServer]: [Not Secure] <Steve> Create contraption online: 12:30";
        assert_eq!(
            parse_minecraft_log_event(neoforge_chat),
            Some(LogEvent::Chat {
                player: "Steve".to_string(),
                message: "Create contraption online: 12:30".to_string()
            })
        );

        let paper_chat = "[14:22:01 INFO]: <Steve> 1 < 2 > 0";
        assert_eq!(
            parse_minecraft_log_event(paper_chat),
            Some(LogEvent::Chat {
                player: "Steve".to_string(),
                message: "1 < 2 > 0".to_string()
            })
        );
    }

    #[test]
    fn test_ignores_non_info_and_spoofed_system_lines() {
        assert_eq!(
            parse_minecraft_log_event("[14:22:01] [Server thread/WARN]: <Steve> warning"),
            None
        );
        assert_eq!(
            parse_minecraft_log_event("[14:22:01] [Server thread/INFO]: <bad name> hi"),
            None
        );
        assert_eq!(
            parse_minecraft_log_event("[14:22:01] [Server thread/INFO]: <Steve>   "),
            None
        );
    }
}
