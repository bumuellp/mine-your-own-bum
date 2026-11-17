//! Minecraft server TCP healthchecking, IP extraction, and DNS over HTTPS (DoH) fallback

use crate::types::PingResult;
use serde::Deserialize;
use std::net::IpAddr;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use worker::{Delay, Fetch, Headers, Method, Request, RequestInit, Socket};

#[derive(Clone, Debug, Deserialize)]
pub struct DohAnswer {
    #[serde(rename = "type")]
    pub record_type: u16,
    pub data: String,
}

#[derive(Clone, Debug, Deserialize)]
pub struct DohResponse {
    #[serde(default)]
    #[serde(rename = "Answer")]
    pub answer: Vec<DohAnswer>,
}

/// Helper to encode a VarInt into a byte buffer according to Minecraft protocol spec
pub fn write_varint(mut val: i32, buf: &mut Vec<u8>) {
    loop {
        if (val as u32 & !0x7F) == 0 {
            buf.push(val as u8);
            return;
        }
        buf.push((val as u8 & 0x7F) | 0x80);
        val = ((val as u32) >> 7) as i32;
    }
}

/// Helper to decode a VarInt from a byte buffer. Returns (value, bytes_consumed).
pub fn read_varint(buf: &[u8]) -> Option<(i32, usize)> {
    let mut num_read = 0;
    let mut result = 0i32;
    for &byte in buf {
        let value = (byte & 0x7F) as i32;
        result |= value << (7 * num_read);
        num_read += 1;
        if num_read > 5 {
            return None;
        }
        if (byte & 0x80) == 0 {
            return Some((result, num_read));
        }
    }
    None
}

/// Build standard Minecraft Server List Ping (SLP) Handshake packet (State 1: Status)
pub fn build_slp_handshake(hostname: &str, port: u16) -> Vec<u8> {
    let mut payload = Vec::new();
    // Packet ID: 0x00
    write_varint(0, &mut payload);
    // Protocol version: 47 (1.8+, standard ping version accepted by modern servers)
    write_varint(47, &mut payload);
    // Server address (hostname)
    write_varint(hostname.len() as i32, &mut payload);
    payload.extend_from_slice(hostname.as_bytes());
    // Server port (unsigned short, big-endian)
    payload.extend_from_slice(&port.to_be_bytes());
    // Next state: 1 (status)
    write_varint(1, &mut payload);

    let mut packet = Vec::new();
    write_varint(payload.len() as i32, &mut packet);
    packet.extend(payload);
    packet
}

/// Build standard Minecraft Server List Ping (SLP) Status Request packet
pub fn build_slp_request() -> Vec<u8> {
    // Packet Length: 1, Packet ID: 0x00
    vec![0x01, 0x00]
}

/// Validate that response bytes match Minecraft Server List Ping response format
pub fn is_valid_slp_response(buf: &[u8]) -> bool {
    let Some((_packet_len, offset1)) = read_varint(buf) else {
        return false;
    };
    if offset1 >= buf.len() {
        return false;
    }
    let Some((packet_id, offset2)) = read_varint(&buf[offset1..]) else {
        return false;
    };
    if packet_id != 0 {
        return false;
    }
    let next_offset = offset1 + offset2;
    if next_offset >= buf.len() {
        return false;
    }
    let Some((json_len, offset3)) = read_varint(&buf[next_offset..]) else {
        return false;
    };
    if json_len <= 0 {
        return false;
    }
    let payload_offset = next_offset + offset3;
    if payload_offset < buf.len() {
        buf[payload_offset] == b'{'
    } else {
        true
    }
}

/// Helper to extract clean IP address from socket remote address.
/// Returns `Some(&str)` if and only if the extracted string is a valid IPv4 or IPv6 address.
/// Returns `None` if the input is a domain name, empty, or an invalid IP address.
pub fn clean_ip(raw: &str) -> Option<&str> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }

    let candidate = if let Some(stripped) = trimmed.strip_prefix('[') {
        if let Some(end) = stripped.find(']') {
            &stripped[..end]
        } else {
            trimmed
        }
    } else if trimmed.matches(':').count() == 1 {
        if let Some((host_or_ip, _port)) = trimmed.split_once(':') {
            host_or_ip
        } else {
            trimmed
        }
    } else {
        trimmed
    };

    if candidate.parse::<IpAddr>().is_ok() {
        Some(candidate)
    } else {
        None
    }
}

/// Parse IPv4 A record address from a DoH response
pub fn extract_a_record(response: &DohResponse) -> Option<String> {
    response
        .answer
        .iter()
        .find(|a| a.record_type == 1) // 1 = A record
        .and_then(|a| clean_ip(&a.data).map(String::from))
}

/// Fallback DNS resolution using Cloudflare DNS over HTTPS (DoH)
pub async fn resolve_ip_doh(hostname: &str) -> Option<String> {
    let url = format!("https://cloudflare-dns.com/dns-query?name={hostname}&type=A");
    let headers = Headers::new();
    let _ = headers.set("Accept", "application/dns-json");

    let init = RequestInit {
        method: Method::Get,
        headers,
        ..Default::default()
    };

    let req = Request::new_with_init(&url, &init).ok()?;
    let mut resp = Fetch::Request(req).send().await.ok()?;
    if resp.status_code() != 200 {
        return None;
    }

    let doh: DohResponse = resp.json().await.ok()?;
    extract_a_record(&doh)
}

/// Attempts a TCP connection and Minecraft Server List Ping (SLP) on port 25565
/// to verify that the Minecraft engine is fully operational and responsive.
/// Returns whether the server is online and the remote IP address if available.
pub async fn ping_minecraft_server(hostname: &str, port: u16) -> PingResult {
    let mut socket = match Socket::builder().connect(hostname, port) {
        Ok(s) => s,
        Err(_) => {
            return PingResult {
                is_online: false,
                ip: None,
            };
        }
    };

    let (is_connected, ip) = {
        let opened = socket.opened();
        let timeout = Delay::from(Duration::from_millis(2500));
        futures_util::pin_mut!(opened, timeout);

        match futures_util::future::select(opened, timeout).await {
            futures_util::future::Either::Left((Ok(info), _)) => {
                let cleaned = info
                    .remote_address
                    .as_deref()
                    .and_then(clean_ip)
                    .map(String::from);
                (true, cleaned)
            }
            _ => (false, None),
        }
    };

    if !is_connected {
        let _ = socket.close().await;
        return PingResult {
            is_online: false,
            ip: None,
        };
    }

    // Send Server List Ping (SLP) handshake + request to verify the Minecraft game server
    // is truly active and responding, preventing false positives from container proxy ports.
    let is_online = {
        let check_slp = async {
            let handshake = build_slp_handshake(hostname, port);
            let request = build_slp_request();

            if socket.write_all(&handshake).await.is_err() {
                return false;
            }
            if socket.write_all(&request).await.is_err() {
                return false;
            }

            let mut buf = [0u8; 512];
            match socket.read(&mut buf).await {
                Ok(n) if n > 0 => is_valid_slp_response(&buf[..n]),
                _ => false,
            }
        };

        let slp_timeout = Delay::from(Duration::from_millis(2500));
        futures_util::pin_mut!(check_slp, slp_timeout);

        match futures_util::future::select(check_slp, slp_timeout).await {
            futures_util::future::Either::Left((responsive, _)) => responsive,
            _ => false,
        }
    };

    let _ = socket.close().await;
    PingResult { is_online, ip }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_clean_ip() {
        // Valid IPv4
        assert_eq!(clean_ip("142.132.1.2"), Some("142.132.1.2"));
        assert_eq!(clean_ip("142.132.1.2:25565"), Some("142.132.1.2"));
        assert_eq!(clean_ip("  142.132.1.2  "), Some("142.132.1.2"));

        // Valid IPv6
        assert_eq!(
            clean_ip("[2a01:4f8:1c1c::1]:25565"),
            Some("2a01:4f8:1c1c::1")
        );
        assert_eq!(clean_ip("[2a01:4f8:1c1c::1]"), Some("2a01:4f8:1c1c::1"));
        assert_eq!(clean_ip("2a01:4f8:1c1c::1"), Some("2a01:4f8:1c1c::1"));

        // Hostnames must return None
        assert_eq!(clean_ip("mc.example.com"), None);
        assert_eq!(clean_ip("mc.example.com:25565"), None);
        assert_eq!(clean_ip("example.com"), None);

        // Invalid or empty strings
        assert_eq!(clean_ip(""), None);
        assert_eq!(clean_ip("   "), None);
        assert_eq!(clean_ip("999.999.999.999"), None);
        assert_eq!(clean_ip("invalid:ip:format:here"), None);
    }

    #[test]
    fn test_extract_a_record_found() {
        let json_data = r#"{
            "Status": 0,
            "Answer": [
                {
                    "name": "mc.example.com",
                    "type": 28,
                    "TTL": 60,
                    "data": "2a01:4f8:1c1c::1"
                },
                {
                    "name": "mc.example.com",
                    "type": 1,
                    "TTL": 60,
                    "data": "142.132.1.2"
                }
            ]
        }"#;

        let response: DohResponse = serde_json::from_str(json_data).unwrap();
        assert_eq!(extract_a_record(&response), Some("142.132.1.2".to_string()));
    }

    #[test]
    fn test_extract_a_record_empty() {
        let json_data = r#"{ "Status": 3, "Answer": [] }"#;
        let response: DohResponse = serde_json::from_str(json_data).unwrap();
        assert_eq!(extract_a_record(&response), None);

        let json_no_answer = r#"{ "Status": 0 }"#;
        let response_no_answer: DohResponse = serde_json::from_str(json_no_answer).unwrap();
        assert_eq!(extract_a_record(&response_no_answer), None);
    }

    #[test]
    fn test_varint_roundtrip() {
        let test_cases = [0, 1, 47, 127, 128, 255, 25565, 2097151];
        for val in test_cases {
            let mut buf = Vec::new();
            write_varint(val, &mut buf);
            let (decoded, len) = read_varint(&buf).expect("should decode varint");
            assert_eq!(decoded, val);
            assert_eq!(len, buf.len());
        }
    }

    #[test]
    fn test_slp_handshake_and_request_structure() {
        let handshake = build_slp_handshake("mc.example.com", 25565);
        assert!(!handshake.is_empty());

        let (packet_len, offset) = read_varint(&handshake).expect("valid length varint");
        assert_eq!(packet_len as usize, handshake.len() - offset);

        let request = build_slp_request();
        assert_eq!(request, vec![0x01, 0x00]);
    }

    #[test]
    fn test_is_valid_slp_response() {
        // Construct valid SLP response:
        // [packet_length: VarInt][packet_id: 0x00 VarInt][json_len: VarInt][json_payload]
        let json_str =
            r#"{"description":"Mine Your Own Bum","version":{"name":"1.21","protocol":765}}"#;
        let mut inner = Vec::new();
        write_varint(0, &mut inner); // packet ID 0
        write_varint(json_str.len() as i32, &mut inner);
        inner.extend_from_slice(json_str.as_bytes());

        let mut full_packet = Vec::new();
        write_varint(inner.len() as i32, &mut full_packet);
        full_packet.extend(inner);

        assert!(is_valid_slp_response(&full_packet));

        // Invalid: empty or junk
        assert!(!is_valid_slp_response(&[]));
        assert!(!is_valid_slp_response(&[0x05, 0x01, 0x02, 0x03])); // packet_id != 0
        assert!(!is_valid_slp_response(b"HTTP/1.1 200 OK\r\n"));
    }
}
