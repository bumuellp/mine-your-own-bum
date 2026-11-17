//! Source RCON TCP client, `/tellraw` builder, and `list` output parser.

use serde::{Deserialize, Serialize};
use serde_json::json;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::time::timeout;

const SERVERDATA_AUTH: i32 = 3;
const SERVERDATA_EXECCOMMAND: i32 = 2;
const RCON_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlayerListResponse {
    pub online: u32,
    pub max: u32,
    pub players: Vec<String>,
}

/// Reusable Source RCON client targeting a single Minecraft server endpoint.
#[derive(Clone, Debug)]
pub struct RconClient {
    host: String,
    port: u16,
    password: String,
}

impl RconClient {
    pub fn new(host: String, port: u16, password: String) -> Self {
        Self {
            host,
            port,
            password,
        }
    }

    pub async fn execute(&self, command: &str) -> Result<String, String> {
        execute_rcon_command(&self.host, self.port, &self.password, command).await
    }
}

/// Encodes a Source RCON packet into little-endian framing.
pub fn encode_rcon_packet(request_id: i32, packet_type: i32, body: &str) -> Vec<u8> {
    let body_bytes = body.as_bytes();
    let length = 4 + 4 + body_bytes.len() as i32 + 2;
    let mut buf = Vec::with_capacity(4 + length as usize);
    buf.extend_from_slice(&length.to_le_bytes());
    buf.extend_from_slice(&request_id.to_le_bytes());
    buf.extend_from_slice(&packet_type.to_le_bytes());
    buf.extend_from_slice(body_bytes);
    buf.extend_from_slice(&[0u8, 0u8]);
    buf
}

/// Reads a single Source RCON response packet from a stream.
async fn read_rcon_packet(stream: &mut TcpStream) -> Result<(i32, i32, String), String> {
    let mut len_buf = [0u8; 4];
    stream
        .read_exact(&mut len_buf)
        .await
        .map_err(|e| format!("failed to read RCON packet length: {e}"))?;
    let length = i32::from_le_bytes(len_buf);
    if !(10..=65536).contains(&length) {
        return Err(format!("invalid RCON packet length: {length}"));
    }

    let mut payload = vec![0u8; length as usize];
    stream
        .read_exact(&mut payload)
        .await
        .map_err(|e| format!("failed to read RCON packet body: {e}"))?;

    let req_id = i32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]);
    let pkt_type = i32::from_le_bytes([payload[4], payload[5], payload[6], payload[7]]);
    let body_end = (length as usize).saturating_sub(2);
    let body = String::from_utf8_lossy(&payload[8..body_end]).into_owned();
    Ok((req_id, pkt_type, body))
}

/// Connects to `host:port`, authenticates with `password`, and executes `command`.
pub async fn execute_rcon_command(
    host: &str,
    port: u16,
    password: &str,
    command: &str,
) -> Result<String, String> {
    let fut = async {
        let addr = format!("{host}:{port}");
        let mut stream = TcpStream::connect(&addr)
            .await
            .map_err(|e| format!("failed to connect to RCON at {addr}: {e}"))?;

        let auth_pkt = encode_rcon_packet(1, SERVERDATA_AUTH, password);
        stream
            .write_all(&auth_pkt)
            .await
            .map_err(|e| format!("failed to send RCON auth packet: {e}"))?;

        let (auth_id, _pkt_type, _body) = read_rcon_packet(&mut stream).await?;
        if auth_id == -1 {
            return Err("RCON authentication failed (invalid password)".to_string());
        }
        // Some Minecraft RCON implementations send an empty RESPONSE_VALUE before AUTH_RESPONSE
        if auth_id != 1 {
            let (second_id, _, _) = read_rcon_packet(&mut stream).await?;
            if second_id == -1 {
                return Err("RCON authentication failed (invalid password)".to_string());
            }
        }

        let cmd_pkt = encode_rcon_packet(2, SERVERDATA_EXECCOMMAND, command);
        stream
            .write_all(&cmd_pkt)
            .await
            .map_err(|e| format!("failed to send RCON command: {e}"))?;

        let (_resp_id, _resp_type, body) = read_rcon_packet(&mut stream).await?;
        Ok(body.trim().to_string())
    };

    timeout(RCON_TIMEOUT, fut)
        .await
        .map_err(|_| "RCON operation timed out".to_string())?
}

/// Parses standard Minecraft `list` RCON output across Vanilla, Fabric, NeoForge, and Paper.
/// Example: `"There are 2 of a max of 20 players online: Steve, .BedrockAlex"`
pub fn parse_player_list(raw: &str) -> PlayerListResponse {
    let cleaned = raw.trim();
    let mut online = 0u32;
    let mut max = 20u32;
    let mut players = Vec::new();

    let numbers: Vec<u32> = cleaned
        .split(|c: char| !c.is_ascii_digit())
        .filter(|s| !s.is_empty())
        .filter_map(|s| s.parse::<u32>().ok())
        .collect();

    if let Some(&first) = numbers.first() {
        online = first;
    }
    if let Some(&second) = numbers.get(1) {
        max = second;
    }

    if let Some((_, list_part)) = cleaned.split_once(':') {
        for name in list_part.split(',') {
            let trimmed = name.trim();
            if !trimmed.is_empty() && online > 0 {
                players.push(trimmed.to_string());
            }
        }
    }

    PlayerListResponse {
        online,
        max,
        players,
    }
}

/// Validates a Minecraft Java or Floodgate Bedrock username (`^[A-Za-z0-9_.]{1,32}$`).
pub fn is_valid_player_name(name: &str) -> bool {
    let trimmed = name.trim();
    !trimmed.is_empty()
        && trimmed.len() <= 32
        && trimmed
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.')
}

/// Builds a safe `/tellraw @a` command broadcasting a Discord chat message in-game.
pub fn build_tellraw_command(sender: &str, message: &str) -> String {
    let clean_sender: String = sender
        .chars()
        .filter(|c| !c.is_control())
        .take(32)
        .collect();
    let clean_msg: String = message
        .chars()
        .filter(|c| !c.is_control())
        .take(256)
        .collect();

    let payload = json!([
        "",
        {"text": "[Discord] ", "color": "blue", "bold": true},
        {"text": format!("<{clean_sender}> "), "color": "aqua"},
        {"text": clean_msg, "color": "white"}
    ]);

    format!("tellraw @a {payload}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_rcon_packet() {
        let pkt = encode_rcon_packet(1, 2, "list");
        assert_eq!(&pkt[0..4], &14i32.to_le_bytes());
        assert_eq!(&pkt[4..8], &1i32.to_le_bytes());
        assert_eq!(&pkt[8..12], &2i32.to_le_bytes());
        assert_eq!(&pkt[12..16], b"list");
        assert_eq!(&pkt[16..18], &[0u8, 0u8]);
    }

    #[test]
    fn test_parse_player_list_variants() {
        let out = "There are 2 of a max of 20 players online: Steve, .BedrockAlex";
        assert_eq!(
            parse_player_list(out),
            PlayerListResponse {
                online: 2,
                max: 20,
                players: vec!["Steve".to_string(), ".BedrockAlex".to_string()],
            }
        );

        let empty = "There are 0 of a max of 50 players online:";
        assert_eq!(
            parse_player_list(empty),
            PlayerListResponse {
                online: 0,
                max: 50,
                players: vec![],
            }
        );

        assert_eq!(
            parse_player_list("unexpected"),
            PlayerListResponse {
                online: 0,
                max: 20,
                players: vec![],
            }
        );
    }

    #[test]
    fn test_is_valid_player_name() {
        assert!(is_valid_player_name("Steve"));
        assert!(is_valid_player_name(".BedrockAlex"));
        assert!(is_valid_player_name("Player_1"));
        assert!(!is_valid_player_name(""));
        assert!(!is_valid_player_name("bad name; stop"));
        assert!(!is_valid_player_name("a".repeat(33).as_str()));
    }

    #[test]
    fn test_build_tellraw_command_escapes_json() {
        let cmd = build_tellraw_command("Steve", "Hello \"world\"\n/op me");
        assert!(cmd.starts_with("tellraw @a "));
        assert!(cmd.contains("\\\"world\\\""));
        assert!(!cmd.contains('\n'));
    }
}
