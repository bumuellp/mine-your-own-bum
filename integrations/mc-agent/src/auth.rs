//! Constant-time shared secret authentication for `mc-agent` HTTP endpoints.

/// Verifies `provided` against `expected` in constant time.
/// Fails closed (`false`) if `expected` is empty or whitespace-only.
pub fn verify_secret(expected: &str, provided: &str) -> bool {
    let expected_trimmed = expected.trim();
    let provided_trimmed = provided.trim();

    if expected_trimmed.is_empty() {
        return false;
    }

    let a = expected_trimmed.as_bytes();
    let b = provided_trimmed.as_bytes();

    // Keep full usize length difference (never truncate to u8, which wraps at 256 bytes)
    let len_diff = a.len() ^ b.len();
    let mut byte_diff = 0u8;
    let max_len = a.len().max(b.len());

    for i in 0..max_len {
        let byte_a = a.get(i).copied().unwrap_or(0);
        let byte_b = b.get(i).copied().unwrap_or(0);
        byte_diff |= byte_a ^ byte_b;
    }

    len_diff == 0 && byte_diff == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_verify_secret_matches() {
        let secret = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        assert!(verify_secret(secret, secret));
        assert!(verify_secret(secret, &format!("  {secret}\r\n")));
    }

    #[test]
    fn test_verify_secret_rejects_mismatch_and_empty() {
        let secret = "0123456789abcdef0123456789abcdef";
        assert!(!verify_secret(secret, "0123456789abcdef0123456789abcdee"));
        assert!(!verify_secret(secret, "short"));
        assert!(!verify_secret(secret, ""));
        assert!(!verify_secret("", ""));
        assert!(!verify_secret("   ", "   "));
    }

    #[test]
    fn test_verify_secret_rejects_256_byte_nul_padded_extension() {
        let secret = "0123456789abcdef0123456789abcdef";
        let mut padded = String::from(secret);
        padded.push_str(&"\0".repeat(256));
        assert!(!verify_secret(secret, &padded));
    }
}
