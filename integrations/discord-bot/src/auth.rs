//! Authentication and access control (Discord Ed25519 signature & user ACL)

use ed25519_dalek::{Signature, Verifier, VerifyingKey};

/// Verify Discord Ed25519 signature
pub fn verify_signature(
    public_key_hex: &str,
    signature_hex: &str,
    timestamp: &str,
    body: &[u8],
) -> bool {
    let Ok(pub_key_bytes) = hex::decode(public_key_hex) else {
        return false;
    };
    let Ok(pub_key_arr): Result<[u8; 32], _> = pub_key_bytes.try_into() else {
        return false;
    };
    let Ok(verifying_key) = VerifyingKey::from_bytes(&pub_key_arr) else {
        return false;
    };

    let Ok(sig_bytes) = hex::decode(signature_hex) else {
        return false;
    };
    let Ok(sig_arr): Result<[u8; 64], _> = sig_bytes.try_into() else {
        return false;
    };
    let signature = Signature::from_bytes(&sig_arr);

    let mut message = timestamp.as_bytes().to_vec();
    message.extend_from_slice(body);

    verifying_key.verify(&message, &signature).is_ok()
}

/// Check if a user ID is authorized under the given allowed IDs configuration.
///
/// If `allowed_ids_raw` is empty or only whitespace, access is open to all users (`true`).
/// If configured, `user_id` must match one of the comma-separated IDs.
pub fn is_user_authorized(allowed_ids_raw: &str, user_id: &str) -> bool {
    let uid = user_id.trim();
    if uid.is_empty() {
        return false;
    }

    fn clean_token(s: &str) -> &str {
        s.trim()
            .trim_matches(|c: char| matches!(c, '[' | ']' | '"' | '\'' | '\n' | '\r' | ' ' | '\t'))
    }

    let allowed: Vec<&str> = allowed_ids_raw
        .split([',', '\n'])
        .map(clean_token)
        .filter(|s| !s.is_empty())
        .collect();

    if allowed.is_empty() {
        return true;
    }

    allowed.contains(&uid)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    /// Test helper to generate a deterministic Ed25519 keypair and valid signature
    fn create_test_signature(timestamp: &str, body: &[u8]) -> (String, String) {
        let seed = [42u8; 32];
        let signing_key = SigningKey::from_bytes(&seed);
        let verifying_key = signing_key.verifying_key();
        let public_key_hex = hex::encode(verifying_key.as_bytes());

        let mut message = timestamp.as_bytes().to_vec();
        message.extend_from_slice(body);
        let signature = signing_key.sign(&message);
        let signature_hex = hex::encode(signature.to_bytes());

        (public_key_hex, signature_hex)
    }

    #[test]
    fn test_is_user_authorized_empty_allows_all() {
        assert!(is_user_authorized("", "123456789"));
        assert!(is_user_authorized("   ", "123456789"));
    }

    #[test]
    fn test_is_user_authorized_single_id() {
        assert!(is_user_authorized("123456789", "123456789"));
        assert!(!is_user_authorized("123456789", "987654321"));
    }

    #[test]
    fn test_is_user_authorized_multiple_ids_with_whitespace() {
        let config = "  111111 , 222222,  333333  , ";
        assert!(is_user_authorized(config, "111111"));
        assert!(is_user_authorized(config, "222222"));
        assert!(is_user_authorized(config, "333333"));
        assert!(!is_user_authorized(config, "444444"));
        assert!(!is_user_authorized(config, ""));
    }

    #[test]
    fn test_verify_signature_valid() {
        let timestamp = "1729828374";
        let body = b"{\"type\": 1}";
        let (pub_hex, sig_hex) = create_test_signature(timestamp, body);

        assert!(verify_signature(&pub_hex, &sig_hex, timestamp, body));
    }

    #[test]
    fn test_verify_signature_tampered_body() {
        let timestamp = "1729828374";
        let (pub_hex, sig_hex) = create_test_signature(timestamp, b"{\"type\": 1}");

        assert!(!verify_signature(
            &pub_hex,
            &sig_hex,
            timestamp,
            b"{\"type\": 2}"
        ));
    }

    #[test]
    fn test_verify_signature_tampered_timestamp() {
        let timestamp = "1729828374";
        let body = b"{\"type\": 1}";
        let (pub_hex, sig_hex) = create_test_signature(timestamp, body);

        assert!(!verify_signature(&pub_hex, &sig_hex, "9999999999", body));
    }

    #[test]
    fn test_verify_signature_invalid_hex() {
        assert!(!verify_signature("not-a-hex", "not-a-hex", "123", b"body"));
        assert!(!verify_signature("1234", "5678", "123", b"body"));
    }

    #[test]
    fn test_is_user_authorized_json_array_format() {
        let config = r#"["111111111111111111", "222222222222222222"]"#;
        assert!(is_user_authorized(config, "111111111111111111"));
        assert!(is_user_authorized(config, "222222222222222222"));
        assert!(!is_user_authorized(config, "999999999999999999"));
    }

    #[test]
    fn test_is_user_authorized_rejects_empty_user_id() {
        assert!(!is_user_authorized("", ""));
        assert!(!is_user_authorized("   ", "   "));
    }
}
