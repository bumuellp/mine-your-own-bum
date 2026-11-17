//! Discord REST API client for updating deferred interaction messages

use serde_json::json;
use worker::{Fetch, Headers, Method, Request, RequestInit, console_error};

/// Edit Discord's original deferred message via webhook PATCH
pub async fn update_deferred_response(app_id: &str, token: &str, message: &str) {
    let url = format!("https://discord.com/api/v10/webhooks/{app_id}/{token}/messages/@original");
    let headers = Headers::new();
    let _ = headers.set("Content-Type", "application/json");

    let payload = json!({ "content": message }).to_string();

    let init = RequestInit {
        method: Method::Patch,
        headers,
        body: Some(worker::wasm_bindgen::JsValue::from_str(&payload)),
        ..Default::default()
    };

    match Request::new_with_init(&url, &init) {
        Ok(req) => match Fetch::Request(req).send().await {
            Ok(resp) if resp.status_code() >= 400 => {
                console_error!(
                    "Discord PATCH @original webhook returned HTTP status {}",
                    resp.status_code()
                );
            }
            Err(e) => {
                console_error!("Discord PATCH @original webhook network failure: {e}");
            }
            _ => {}
        },
        Err(e) => {
            console_error!("Failed to create Discord webhook request: {e}");
        }
    }
}
