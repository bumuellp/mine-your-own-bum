//! Asynchronous `latest.log` tailer with inode-aware log rotation handling
//! and complete-line buffering.

use crate::discord::{DiscordWebhookClient, build_chat_event_payload};
use crate::log_parser::parse_minecraft_log_event;
use std::io::SeekFrom;
use std::os::unix::fs::MetadataExt;
use std::time::Duration;
use tokio::fs::File;
use tokio::io::{AsyncBufReadExt, AsyncSeekExt, BufReader};

/// Tracks file position and inode across log rotation and truncation events.
#[derive(Clone, Debug, Default)]
pub struct LogTailState {
    pub initialized: bool,
    pub inode: Option<u64>,
    pub offset: u64,
}

impl LogTailState {
    /// Updates state from current file metadata and returns the byte offset to read from,
    /// or `None` if no new bytes are available (or initial EOF seek just completed).
    pub fn next_read_offset(&mut self, inode: u64, file_len: u64) -> Option<u64> {
        if !self.initialized {
            self.initialized = true;
            self.inode = Some(inode);
            self.offset = file_len;
            return None;
        }

        if self.inode != Some(inode) || file_len < self.offset {
            // File rotated (new inode) or truncated in-place
            self.inode = Some(inode);
            self.offset = 0;
        }

        if file_len > self.offset {
            Some(self.offset)
        } else {
            None
        }
    }
}

/// Reads complete newline-terminated lines starting from `state.offset`,
/// forwarding parsed events to `client` and leaving partial trailing lines for the next poll.
pub async fn process_new_log_lines(
    log_path: &str,
    state: &mut LogTailState,
    client: &DiscordWebhookClient,
    webhook_url: &str,
) {
    let Ok(meta) = tokio::fs::metadata(log_path).await else {
        return;
    };
    let Some(start_offset) = state.next_read_offset(meta.ino(), meta.len()) else {
        return;
    };

    let Ok(mut file) = File::open(log_path).await else {
        return;
    };
    if file.seek(SeekFrom::Start(start_offset)).await.is_err() {
        return;
    }

    let mut reader = BufReader::new(file);
    let mut line = String::new();
    while let Ok(bytes_read) = reader.read_line(&mut line).await {
        if bytes_read == 0 || !line.ends_with('\n') {
            // Wait for complete newline-terminated lines before advancing offset
            break;
        }
        state.offset += bytes_read as u64;
        if let Some(event) = parse_minecraft_log_event(&line) {
            let payload = build_chat_event_payload(&event);
            let _ = client.post_json(webhook_url, &payload).await;
        }
        line.clear();
    }
}

/// Continuously tails `log_path` from EOF and forwards chat/join/leave events to `webhook_url`.
pub async fn watch_latest_log(log_path: String, client: DiscordWebhookClient, webhook_url: String) {
    if webhook_url.trim().is_empty() {
        return;
    }

    let mut state = LogTailState::default();
    loop {
        process_new_log_lines(&log_path, &mut state, &client, &webhook_url).await;
        tokio::time::sleep(Duration::from_millis(750)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_log_tail_state_detects_rotation_even_when_new_file_is_larger() {
        let mut state = LogTailState::default();
        // Initial open starts at EOF (1000)
        assert_eq!(state.next_read_offset(101, 1000), None);
        assert_eq!(state.offset, 1000);

        // Normal append
        assert_eq!(state.next_read_offset(101, 1250), Some(1000));
        state.offset = 1250;

        // Log rotated to new inode 202 and already grew to 2000 bytes (> 1250!)
        assert_eq!(state.next_read_offset(202, 2000), Some(0));
        assert_eq!(state.inode, Some(202));
        assert_eq!(state.offset, 0);

        // Same inode truncated in place
        state.offset = 500;
        assert_eq!(state.next_read_offset(202, 120), Some(0));
    }
}
