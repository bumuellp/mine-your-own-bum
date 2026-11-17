//! Pure HTTP/1.1 transport layer, framing, server accept loop, and self-healthcheck probe.

use serde_json::{Value, json};
use std::collections::HashMap;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::time::timeout;

const MAX_REQUEST_BYTES: usize = 16 * 1024;
const READ_TIMEOUT: Duration = Duration::from_secs(10);
const HEALTHCHECK_TIMEOUT: Duration = Duration::from_secs(3);

/// Parsed HTTP/1.1 request passed to application handlers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HttpRequest {
    pub method: String,
    pub path: String,
    pub query: String,
    pub headers: HashMap<String, String>,
    pub body: String,
}

impl HttpRequest {
    /// Performs a case-insensitive header lookup.
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .get(&name.to_ascii_lowercase())
            .map(String::as_str)
    }
}

/// Structured HTTP/1.1 JSON response returned by application handlers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HttpResponse {
    pub status_code: u16,
    pub status_text: &'static str,
    pub body: Value,
}

impl HttpResponse {
    pub fn json(status_code: u16, status_text: &'static str, body: Value) -> Self {
        Self {
            status_code,
            status_text,
            body,
        }
    }

    pub fn ok(body: Value) -> Self {
        Self::json(200, "OK", body)
    }

    pub fn bad_request(msg: &str) -> Self {
        Self::json(400, "Bad Request", json!({ "error": msg }))
    }

    pub fn unauthorized(msg: &str) -> Self {
        Self::json(401, "Unauthorized", json!({ "error": msg }))
    }

    pub fn not_found(msg: &str) -> Self {
        Self::json(404, "Not Found", json!({ "error": msg }))
    }

    pub fn payload_too_large(msg: &str) -> Self {
        Self::json(413, "Payload Too Large", json!({ "error": msg }))
    }

    pub fn internal_error(msg: &str) -> Self {
        Self::json(500, "Internal Server Error", json!({ "error": msg }))
    }

    pub fn bad_gateway(msg: &str) -> Self {
        Self::json(502, "Bad Gateway", json!({ "error": msg }))
    }
}

enum ReadStatus {
    Complete(Vec<u8>),
    TooLarge,
    Malformed,
}

fn find_header_end(buf: &[u8]) -> Option<(usize, usize)> {
    if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
        return Some((pos, pos + 4));
    }
    if let Some(pos) = buf.windows(2).position(|w| w == b"\n\n") {
        return Some((pos, pos + 2));
    }
    None
}

fn parse_content_length_from_bytes(header_bytes: &[u8]) -> usize {
    let header_str = String::from_utf8_lossy(header_bytes);
    header_str
        .lines()
        .find_map(|line| {
            let (k, v) = line.split_once(':')?;
            if k.trim().eq_ignore_ascii_case("content-length") {
                v.trim().parse::<usize>().ok()
            } else {
                None
            }
        })
        .unwrap_or(0)
}

/// Parses raw HTTP/1.1 request bytes into an `HttpRequest`.
pub fn parse_http_request(raw: &[u8]) -> Option<HttpRequest> {
    let (header_end, body_start) = find_header_end(raw)?;
    let header_part = std::str::from_utf8(&raw[..header_end]).ok()?;
    let mut lines = header_part.lines();
    let request_line = lines.next()?.trim();
    let mut parts = request_line.split_whitespace();
    let method = parts.next()?.to_ascii_uppercase();
    let full_target = parts.next()?;

    let (path, query) = match full_target.split_once('?') {
        Some((p, q)) => (p.to_string(), q.to_string()),
        None => (full_target.to_string(), String::new()),
    };

    let mut headers = HashMap::new();
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }

    let body = String::from_utf8_lossy(&raw[body_start..]).into_owned();

    Some(HttpRequest {
        method,
        path,
        query,
        headers,
        body,
    })
}

/// Serializes an `HttpResponse` into HTTP/1.1 wire bytes with `Connection: close`.
pub fn format_http_response(resp: &HttpResponse) -> Vec<u8> {
    let body_str = serde_json::to_string(&resp.body).unwrap_or_else(|_| "{}".to_string());
    let header = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        resp.status_code,
        resp.status_text,
        body_str.len()
    );
    let mut out = header.into_bytes();
    out.extend_from_slice(body_str.as_bytes());
    out
}

async fn read_http_request(stream: &mut TcpStream) -> ReadStatus {
    let mut buf = Vec::with_capacity(2048);
    let mut chunk = [0u8; 2048];

    loop {
        match stream.read(&mut chunk).await {
            Ok(0) => {
                return if buf.is_empty() {
                    ReadStatus::Malformed
                } else {
                    ReadStatus::Complete(buf)
                };
            }
            Ok(n) => {
                if buf.len() + n > MAX_REQUEST_BYTES {
                    return ReadStatus::TooLarge;
                }
                buf.extend_from_slice(&chunk[..n]);

                if let Some((header_end, body_start)) = find_header_end(&buf) {
                    let expected_len = parse_content_length_from_bytes(&buf[..header_end]);
                    if body_start + expected_len > MAX_REQUEST_BYTES {
                        return ReadStatus::TooLarge;
                    }
                    if buf.len() - body_start >= expected_len {
                        buf.truncate(body_start + expected_len);
                        return ReadStatus::Complete(buf);
                    }
                }
            }
            Err(_) => return ReadStatus::Malformed,
        }
    }
}

/// Handles a single TCP connection, delegating parsed requests to `handler`.
pub async fn handle_connection<F, Fut>(mut stream: TcpStream, handler: Arc<F>)
where
    F: Fn(HttpRequest) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = HttpResponse> + Send,
{
    let response = match timeout(READ_TIMEOUT, read_http_request(&mut stream)).await {
        Ok(ReadStatus::Complete(raw)) => match parse_http_request(&raw) {
            Some(req) => handler(req).await,
            None => HttpResponse::bad_request("Malformed HTTP request"),
        },
        Ok(ReadStatus::TooLarge) => {
            HttpResponse::payload_too_large("Request exceeds 16 KiB size limit")
        }
        Ok(ReadStatus::Malformed) | Err(_) => {
            HttpResponse::bad_request("Request timed out or invalid")
        }
    };

    let response_bytes = format_http_response(&response);
    let _ = stream.write_all(&response_bytes).await;
    let _ = stream.shutdown().await;
}

/// Runs the HTTP/1.1 accept loop on `listener`, dispatching requests to `handler`.
pub async fn serve<F, Fut>(listener: TcpListener, handler: F)
where
    F: Fn(HttpRequest) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = HttpResponse> + Send + 'static,
{
    let shared_handler = Arc::new(handler);
    loop {
        if let Ok((stream, _peer)) = listener.accept().await {
            let h = Arc::clone(&shared_handler);
            tokio::spawn(async move {
                handle_connection(stream, h).await;
            });
        }
    }
}

/// Probes the local HTTP `/healthz` endpoint for container `--healthcheck` invocations.
pub async fn probe_health(addr: &str) -> Result<(), String> {
    let fut = async {
        let mut stream = TcpStream::connect(addr)
            .await
            .map_err(|e| format!("connect failed: {e}"))?;
        stream
            .write_all(b"GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            .await
            .map_err(|e| format!("write failed: {e}"))?;
        let mut resp = String::new();
        stream
            .read_to_string(&mut resp)
            .await
            .map_err(|e| format!("read failed: {e}"))?;
        if resp.starts_with("HTTP/1.1 200") {
            Ok(())
        } else {
            Err(format!("unhealthy response: {resp}"))
        }
    };

    timeout(HEALTHCHECK_TIMEOUT, fut)
        .await
        .map_err(|_| "healthcheck timed out".to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_http_request_handles_headers_and_utf8_body() {
        let raw = b"POST /api/say?debug=1 HTTP/1.1\r\nHost: localhost:8080\r\nx-agent-secret: sec123\r\n\r\n{\"sender\":\"Steve\",\"message\":\"\xF0\x9F\x98\x80\"}";
        let req = parse_http_request(raw).expect("valid HTTP request");
        assert_eq!(req.method, "POST");
        assert_eq!(req.path, "/api/say");
        assert_eq!(req.query, "debug=1");
        assert_eq!(req.header("X-Agent-Secret"), Some("sec123"));
        assert!(req.body.contains('😀'));
    }

    #[test]
    fn test_format_http_response_sets_exact_content_length() {
        let resp = HttpResponse::ok(json!({"msg": "hällo"}));
        let bytes = format_http_response(&resp);
        let text = String::from_utf8(bytes).unwrap();
        let (headers, body) = text.split_once("\r\n\r\n").unwrap();
        assert!(headers.starts_with("HTTP/1.1 200 OK"));
        assert!(headers.contains(&format!("Content-Length: {}", body.len())));
    }

    #[tokio::test]
    async fn test_probe_health_against_ephemeral_listener() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap().to_string();

        tokio::spawn(async move {
            serve(listener, |_req| async {
                HttpResponse::ok(json!({"status": "ok"}))
            })
            .await;
        });

        assert!(probe_health(&addr).await.is_ok());
    }
}
