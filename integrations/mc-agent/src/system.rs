//! Host telemetry (`/proc` + `statvfs`) and log tailing with IPv4 redaction.

use serde::{Deserialize, Serialize};
use std::ffi::CString;
use std::path::Path;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct SystemStats {
    pub load_1m: f64,
    pub load_5m: f64,
    pub load_15m: f64,
    pub mem_used_mb: u64,
    pub mem_total_mb: u64,
    pub disk_used_gb: f64,
    pub disk_total_gb: f64,
    pub uptime_seconds: u64,
}

/// Parses `/proc/loadavg` content into `(load_1m, load_5m, load_15m)`.
pub fn parse_loadavg(content: &str) -> (f64, f64, f64) {
    let mut parts = content.split_whitespace();
    let l1 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0.0);
    let l5 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0.0);
    let l15 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0.0);
    (l1, l5, l15)
}

/// Parses `/proc/meminfo` content into `(mem_used_mb, mem_total_mb)`.
pub fn parse_meminfo(content: &str) -> (u64, u64) {
    let mut total_kb = 0u64;
    let mut avail_kb = 0u64;

    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("MemTotal:") {
            total_kb = rest
                .split_whitespace()
                .next()
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
        } else if let Some(rest) = line.strip_prefix("MemAvailable:") {
            avail_kb = rest
                .split_whitespace()
                .next()
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
        }
    }

    let total_mb = total_kb / 1024;
    let used_mb = total_kb.saturating_sub(avail_kb) / 1024;
    (used_mb, total_mb)
}

/// Parses `/proc/uptime` content into `uptime_seconds`.
pub fn parse_uptime(content: &str) -> u64 {
    content
        .split_whitespace()
        .next()
        .and_then(|s| s.split('.').next())
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}

/// Queries filesystem capacity for `path` using `libc::statvfs`, returning `(used_gb, total_gb)`.
pub fn query_disk_usage(path: &str) -> (f64, f64) {
    let Ok(c_path) = CString::new(path) else {
        return (0.0, 0.0);
    };
    unsafe {
        let mut stat: libc::statvfs = std::mem::zeroed();
        if libc::statvfs(c_path.as_ptr(), &mut stat) != 0 {
            return (0.0, 0.0);
        }
        let frsize = if stat.f_frsize > 0 {
            stat.f_frsize as f64
        } else {
            stat.f_bsize as f64
        };
        let total_bytes = (stat.f_blocks as f64) * frsize;
        let avail_bytes = (stat.f_bavail as f64) * frsize;
        let used_bytes = (total_bytes - avail_bytes).max(0.0);
        let gb = 1024.0 * 1024.0 * 1024.0;
        let used_gb = ((used_bytes / gb) * 100.0).round() / 100.0;
        let total_gb = ((total_bytes / gb) * 100.0).round() / 100.0;
        (used_gb, total_gb)
    }
}

/// Collects system telemetry from `proc_dir` (e.g. `/host/proc` or `/proc`) and `data_dir` (`/data`).
pub async fn collect_system_stats(proc_dir: &str, data_dir: &str) -> SystemStats {
    let base = if Path::new(proc_dir).exists() {
        proc_dir
    } else {
        "/proc"
    };

    let loadavg_raw = tokio::fs::read_to_string(format!("{base}/loadavg"))
        .await
        .unwrap_or_default();
    let meminfo_raw = tokio::fs::read_to_string(format!("{base}/meminfo"))
        .await
        .unwrap_or_default();
    let uptime_raw = tokio::fs::read_to_string(format!("{base}/uptime"))
        .await
        .unwrap_or_default();

    let (load_1m, load_5m, load_15m) = parse_loadavg(&loadavg_raw);
    let (mem_used_mb, mem_total_mb) = parse_meminfo(&meminfo_raw);
    let uptime_seconds = parse_uptime(&uptime_raw);
    let (disk_used_gb, disk_total_gb) = query_disk_usage(data_dir);

    SystemStats {
        load_1m,
        load_5m,
        load_15m,
        mem_used_mb,
        mem_total_mb,
        disk_used_gb,
        disk_total_gb,
        uptime_seconds,
    }
}

/// Strips ANSI escape sequences and redacts IPv4 addresses from a log line.
pub fn sanitize_log_line(line: &str) -> String {
    // 1. Strip ANSI escape sequences: ESC [ ... letter
    let mut no_ansi = String::with_capacity(line.len());
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' && chars.peek() == Some(&'[') {
            chars.next();
            while let Some(&nc) = chars.peek() {
                chars.next();
                if nc.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            no_ansi.push(c);
        }
    }

    // 2. Redact IPv4 addresses (e.g. 142.132.10.20 or /142.132.10.20:54321)
    redact_ipv4(&no_ansi)
}

fn is_ipv4_token(token: &str) -> bool {
    let ip_part = token.split(':').next().unwrap_or(token);
    let octets: Vec<&str> = ip_part.split('.').collect();
    if octets.len() != 4 {
        return false;
    }
    octets.iter().all(|o| o.parse::<u8>().is_ok())
}

fn redact_ipv4(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut i = 0;
    let bytes = input.as_bytes();

    while i < bytes.len() {
        if bytes[i].is_ascii_digit() {
            let start = i;
            while i < bytes.len()
                && (bytes[i].is_ascii_digit() || bytes[i] == b'.' || bytes[i] == b':')
            {
                i += 1;
            }
            let candidate = &input[start..i];
            let trimmed = candidate.trim_end_matches(['.', ':']);
            let trailing = &candidate[trimmed.len()..];
            if is_ipv4_token(trimmed) {
                out.push_str("[REDACTED_IP]");
                out.push_str(trailing);
            } else {
                out.push_str(candidate);
            }
        } else {
            let ch = input[i..].chars().next().unwrap();
            out.push(ch);
            i += ch.len_utf8();
        }
    }

    out
}

/// Reads the last `lines` (clamped to `1..=80`) from `log_path`, sanitizing each line.
pub async fn tail_log_file(log_path: &str, requested_lines: usize) -> Result<String, String> {
    let count = requested_lines.clamp(1, 80);
    let content = tokio::fs::read_to_string(log_path)
        .await
        .map_err(|e| format!("failed to read log file {log_path}: {e}"))?;

    let all_lines: Vec<&str> = content.lines().collect();
    let start = all_lines.len().saturating_sub(count);
    let sanitized: Vec<String> = all_lines[start..]
        .iter()
        .map(|l| sanitize_log_line(l))
        .collect();

    Ok(sanitized.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_loadavg_meminfo_uptime() {
        assert_eq!(
            parse_loadavg("0.42 0.31 0.19 1/245 1234\n"),
            (0.42, 0.31, 0.19)
        );
        let mem = "MemTotal:        8192000 kB\nMemFree:         1024000 kB\nMemAvailable:    2048000 kB\n";
        assert_eq!(parse_meminfo(mem), (6000, 8000));
        assert_eq!(parse_uptime("3661.42 7200.00\n"), 3661);
    }

    #[test]
    fn test_sanitize_log_line_strips_ansi_and_redacts_ip() {
        let raw = "\x1b[32m[12:00:00] [Server thread/INFO]: Steve[/203.0.113.50:54321] logged in with entity id 12\x1b[0m";
        let clean = sanitize_log_line(raw);
        assert_eq!(
            clean,
            "[12:00:00] [Server thread/INFO]: Steve[/[REDACTED_IP]] logged in with entity id 12"
        );
    }

    #[test]
    fn test_sanitize_log_line_preserves_version_numbers() {
        let raw = "[12:00:00] [Server thread/INFO]: Starting minecraft server version 1.21.1";
        assert_eq!(sanitize_log_line(raw), raw);
    }

    #[test]
    fn test_sanitize_log_line_ipv4_corner_cases() {
        assert_eq!(
            sanitize_log_line("Player connected from 192.168.1.42:25565."),
            "Player connected from [REDACTED_IP]."
        );
        // 5-octet OIDs and >255 octets are not valid IPv4 addresses
        assert_eq!(sanitize_log_line("OID 1.2.3.4.5"), "OID 1.2.3.4.5");
        assert_eq!(sanitize_log_line("Invalid 999.1.2.3"), "Invalid 999.1.2.3");
    }
}
