//! HTTP/1.1 framing for the crate's mock servers.
//!
//! Both of them — the HyperSync one and the ClickHouse one — need the same two
//! things off a socket: read one request, write one response. Everything they do
//! between those is what actually differs, so only the framing lives here.

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

pub struct Request {
    /// The request line and headers verbatim, for a test that asserts on what
    /// was sent rather than on what it meant.
    #[cfg_attr(not(test), allow(dead_code))]
    pub head: String,
    pub method: String,
    /// The request target, query string included.
    pub path: String,
    pub body: Vec<u8>,
}

/// Reads one request off `stream`. Whatever arrived past it stays in `buffered`
/// for the next call, since a pooled connection carries many. `None` when the
/// peer closed instead of sending another.
pub async fn read_request(
    stream: &mut TcpStream,
    buffered: &mut Vec<u8>,
) -> std::io::Result<Option<Request>> {
    loop {
        if let Some((consumed, request)) = parse(buffered) {
            buffered.drain(..consumed);
            return Ok(Some(request));
        }
        let mut chunk = [0u8; 8192];
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            return Ok(None);
        }
        buffered.extend_from_slice(&chunk[..read]);
    }
}

/// One request and the bytes it spans, or `None` while the buffer still holds
/// less than a whole one.
fn parse(buffer: &[u8]) -> Option<(usize, Request)> {
    let head_end = buffer.windows(4).position(|window| window == b"\r\n\r\n")?;
    let head = String::from_utf8_lossy(&buffer[..head_end]).to_string();
    let mut lines = head.split("\r\n");
    let mut request_line = lines.next().unwrap_or_default().split_whitespace();
    let method = request_line.next().unwrap_or_default().to_string();
    let path = request_line.next().unwrap_or_default().to_string();

    let content_length = lines
        .filter_map(|line| line.split_once(':'))
        .find(|(name, _)| name.trim().eq_ignore_ascii_case("content-length"))
        .and_then(|(_, value)| value.trim().parse::<usize>().ok())
        .unwrap_or(0);

    let total = head_end + 4 + content_length;
    if buffer.len() < total {
        return None;
    }
    Some((
        total,
        Request {
            head,
            method,
            path,
            body: buffer[head_end + 4..total].to_vec(),
        },
    ))
}

pub async fn write_response(
    stream: &mut TcpStream,
    status: u16,
    headers: &[(&str, &str)],
    body: &[u8],
) -> std::io::Result<()> {
    let mut head = format!(
        "HTTP/1.1 {status} {}\r\nContent-Length: {}\r\n",
        // Only the code is ever read back; the phrase keeps the line well-formed.
        if status == 200 { "OK" } else { "Error" },
        body.len()
    );
    for (name, value) in headers {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(body).await?;
    stream.flush().await
}
