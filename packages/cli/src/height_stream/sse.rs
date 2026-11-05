//! HyperSync's `/height/sse` stream.

use std::sync::OnceLock;

use super::driver::{Connection, Report, Reports, Transport};
use super::machine::DownReason;

/// The server pings every 5s, so 15s is a safe margin before treating the
/// connection as dead.
const STALE_TIMEOUT: u32 = 15_000;
/// What a refusal's body can add to its status, in a log line.
const MAX_REFUSAL_BODY: usize = 1_000;

pub struct Sse {
    url: String,
    api_token: String,
    user_agent: String,
}

impl Sse {
    pub fn new(hypersync_url: &str, api_token: String, user_agent: String) -> Self {
        Sse {
            url: format!("{}/height/sse", hypersync_url.trim_end_matches('/')),
            api_token,
            user_agent,
        }
    }
}

impl Transport for Sse {
    fn stale_timeout(&self) -> u32 {
        STALE_TIMEOUT
    }

    fn connect(&self, generation: u32, reports: Reports) -> Result<Connection, String> {
        let url = reqwest::Url::parse(&self.url).map_err(|err| format!("Invalid URL: {err}"))?;
        let request = client()
            .get(url)
            .bearer_auth(&self.api_token)
            .header(reqwest::header::USER_AGENT, &self.user_agent)
            .header(reqwest::header::ACCEPT, "text/event-stream");
        Ok(Connection::spawn(move |closed| async move {
            tokio::select! {
                _ = closed => {}
                () = stream(request, generation, &reports) => {}
            }
        }))
    }
}

/// Without the environment's proxy: the stream has always gone to HyperSync
/// directly.
fn client() -> &'static reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .no_proxy()
            .build()
            .expect("a client with no proxy and default TLS builds")
    })
}

async fn stream(request: reqwest::RequestBuilder, generation: u32, reports: &Reports) {
    let report = |report| {
        let _ = reports.send((generation, report));
    };
    let mut response = match request.send().await {
        Ok(response) => response,
        Err(err) => {
            return report(Report::Failure(
                DownReason::TransportError,
                Some(err.to_string()),
            ))
        }
    };
    let status = response.status();
    if status != reqwest::StatusCode::OK {
        // The status alone can't tell an operator which of a provider's many
        // refusals this was, so its message travels with it.
        let body = response.text().await.unwrap_or_default();
        let detail = match body.trim() {
            "" => format!("Non-200 status code ({})", status.as_u16()),
            body => body.chars().take(MAX_REFUSAL_BODY).collect(),
        };
        return report(Report::Failure(
            DownReason::Http(status.as_u16()),
            Some(detail),
        ));
    }
    report(Report::Connected);
    let mut events = EventParser::default();
    loop {
        match response.chunk().await {
            Ok(Some(chunk)) => {
                for event in events.feed(&chunk) {
                    match event.name.as_str() {
                        "ping" => report(Report::KeepAlive),
                        "height" => report(match event.data.trim().parse() {
                            Ok(height) => Report::Height(height),
                            Err(_) => Report::Unreadable(event.data),
                        }),
                        _ => {}
                    }
                }
            }
            // The stream ended without an HTTP error, which is how a load
            // balancer rotating connections shows up.
            Ok(None) => return report(Report::Failure(DownReason::Closed, None)),
            Err(err) => {
                return report(Report::Failure(
                    DownReason::TransportError,
                    Some(err.to_string()),
                ))
            }
        }
    }
}

#[derive(Debug, PartialEq)]
struct Event {
    name: String,
    data: String,
}

/// The event-stream format's framing: `field: value` lines, a blank line
/// dispatching what came before it. Chunks split anywhere, so a partial line is
/// kept for the next one.
#[derive(Default)]
struct EventParser {
    line: Vec<u8>,
    name: Option<String>,
    data: Option<String>,
}

impl EventParser {
    fn feed(&mut self, chunk: &[u8]) -> Vec<Event> {
        let mut events = Vec::new();
        for &byte in chunk {
            if byte != b'\n' {
                self.line.push(byte);
                continue;
            }
            let mut line = std::mem::take(&mut self.line);
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            let line = String::from_utf8_lossy(&line);
            if line.is_empty() {
                if let Some(data) = self.data.take() {
                    events.push(Event {
                        name: self.name.take().unwrap_or_else(|| "message".into()),
                        data,
                    });
                }
                self.name = None;
                continue;
            }
            if line.starts_with(':') {
                continue;
            }
            let (field, value) = match line.split_once(':') {
                Some((field, value)) => (field, value.strip_prefix(' ').unwrap_or(value)),
                None => (line.as_ref(), ""),
            };
            match field {
                "event" => self.name = Some(value.to_string()),
                "data" => match &mut self.data {
                    Some(data) => {
                        data.push('\n');
                        data.push_str(value);
                    }
                    None => self.data = Some(value.to_string()),
                },
                _ => {}
            }
        }
        events
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(name: &str, data: &str) -> Event {
        Event {
            name: name.into(),
            data: data.into(),
        }
    }

    #[test]
    fn reads_events_split_across_chunks() {
        let mut parser = EventParser::default();
        let mut events = parser.feed(b"event: height\nda");
        events.extend(parser.feed(b"ta: 105\n\nevent: ping\ndata:\n\n: comment\n"));
        events.extend(parser.feed(b"event: height\r\ndata: not-a-number\r\n\r\n"));
        assert_eq!(
            events,
            vec![
                event("height", "105"),
                event("ping", ""),
                event("height", "not-a-number")
            ]
        );
    }

    #[test]
    fn dispatches_nothing_for_an_event_without_data() {
        let mut parser = EventParser::default();
        assert_eq!(parser.feed(b"event: height\n\n"), vec![]);
    }
}
