//! A node's `newHeads` subscription over WebSocket.

use std::sync::{Arc, OnceLock};

use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use tokio_tungstenite::{
    tungstenite::{self, Message},
    Connector,
};

use super::driver::{Connection, Report, Reports, Transport};
use super::machine::DownReason;

/// newHeads carries no keep-alive, so this has to tolerate slow chains rather
/// than the seconds an SSE ping allows.
const STALE_TIMEOUT: u32 = 60_000;

/// The id of the one request this stream ever sends, which is what tells a
/// response meant for it apart from one about anything else sharing the socket.
const SUBSCRIBE_ID: &str = "1";
const SUBSCRIBE: &str =
    r#"{"jsonrpc":"2.0","id":1,"method":"eth_subscribe","params":["newHeads"]}"#;

pub struct Ws {
    url: String,
}

impl Ws {
    pub fn new(url: String) -> Self {
        Ws { url }
    }
}

impl Transport for Ws {
    fn stale_timeout(&self) -> u32 {
        STALE_TIMEOUT
    }

    fn connect(&self, generation: u32, reports: Reports) -> Result<Connection, String> {
        let url = url::Url::parse(&self.url).map_err(|err| format!("Invalid URL: {err}"))?;
        Ok(Connection::spawn(move |closed| async move {
            tokio::select! {
                _ = closed => {}
                () = stream(url, generation, &reports) => {}
            }
        }))
    }
}

async fn stream(url: url::Url, generation: u32, reports: &Reports) {
    let report = |report| {
        let _ = reports.send((generation, report));
    };
    let mut socket = match tokio_tungstenite::connect_async_tls_with_config(
        url.as_str(),
        None,
        false,
        Some(Connector::Rustls(tls_config())),
    )
    .await
    {
        Ok((socket, _)) => socket,
        Err(err) => {
            return report(Report::Failure(
                DownReason::TransportError,
                Some(err.to_string()),
            ))
        }
    };
    if let Err(err) = socket.send(Message::text(SUBSCRIBE)).await {
        return report(Report::Failure(
            DownReason::TransportError,
            Some(err.to_string()),
        ));
    }
    let mut subscribed = false;
    loop {
        match socket.next().await {
            Some(Ok(Message::Text(text))) => match read_frame(&text, subscribed) {
                Frame::Head(height) => report(Report::Height(height)),
                Frame::Confirmed => {
                    subscribed = true;
                    report(Report::Connected);
                }
                Frame::Rejected => {
                    return report(Report::Failure(
                        DownReason::SubscribeRejected,
                        Some(text.to_string()),
                    ))
                }
                Frame::Ignored => {}
                Frame::Unreadable => report(Report::Unreadable(text.to_string())),
            },
            // A peer that should only ever be sending JSON text.
            Some(Ok(Message::Binary(_))) => report(Report::Unreadable("binary frame".into())),
            Some(Ok(Message::Ping(_) | Message::Pong(_) | Message::Frame(_))) => {}
            // A peer that drops the socket without the closing handshake has
            // still ended the connection, as one that sends it has.
            Some(Ok(Message::Close(_)))
            | None
            | Some(Err(
                tungstenite::Error::ConnectionClosed
                | tungstenite::Error::AlreadyClosed
                | tungstenite::Error::Protocol(
                    tungstenite::error::ProtocolError::ResetWithoutClosingHandshake,
                ),
            )) => return report(Report::Failure(DownReason::Closed, None)),
            Some(Err(err)) => {
                return report(Report::Failure(
                    DownReason::TransportError,
                    Some(err.to_string()),
                ))
            }
        }
    }
}

fn tls_config() -> Arc<rustls::ClientConfig> {
    static CONFIG: OnceLock<Arc<rustls::ClientConfig>> = OnceLock::new();
    CONFIG
        .get_or_init(|| {
            let mut roots = rustls::RootCertStore::empty();
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            Arc::new(
                rustls::ClientConfig::builder_with_provider(Arc::new(
                    rustls::crypto::ring::default_provider(),
                ))
                .with_safe_default_protocol_versions()
                .expect("ring supports the default protocol versions")
                .with_root_certificates(roots)
                .with_no_client_auth(),
            )
        })
        .clone()
}

#[derive(Debug, PartialEq)]
enum Frame {
    Head(i64),
    /// The node accepted the subscription.
    Confirmed,
    /// The node refused the subscription.
    Rejected,
    /// A response about something else sharing the socket.
    Ignored,
    Unreadable,
}

/// A JSON-RPC id is any scalar, and gateways echo an int id back as a string.
/// Both spellings name the same request, so both read as the one text. JSON-RPC
/// answers a request whose id it couldn't read with an explicit null.
fn response_id(frame: &serde_json::Map<String, Value>) -> Option<Option<String>> {
    match frame.get("id") {
        None | Some(Value::Null) => Some(None),
        Some(Value::String(id)) => Some(Some(id.clone())),
        Some(Value::Number(id)) => id.as_i64().map(|id| Some(id.to_string())),
        Some(_) => None,
    }
}

/// The subscribe is the only request this socket ever sends, so an error naming
/// its id is that subscription being refused. So is one naming no id at all,
/// which is how JSON-RPC answers a request it could not parse, but only until
/// the node has confirmed the subscription: after that, a null id belongs to
/// whatever else the provider wants to say, throttling most of all, and tearing
/// a delivering subscription down over it would reconnect against an endpoint
/// already asking for less.
fn refuses_subscribe(id: Option<&str>, subscribed: bool) -> bool {
    match id {
        None => !subscribed,
        Some(id) => id == SUBSCRIBE_ID,
    }
}

fn head_number(frame: &serde_json::Map<String, Value>) -> Option<i64> {
    let number = frame
        .get("params")?
        .get("result")?
        .get("number")?
        .as_str()?;
    match number.strip_prefix("0x") {
        Some(hex) => i64::from_str_radix(hex, 16).ok(),
        None => number.parse().ok(),
    }
}

fn read_frame(text: &str, subscribed: bool) -> Frame {
    let Ok(Value::Object(frame)) = serde_json::from_str::<Value>(text) else {
        return Frame::Unreadable;
    };
    if frame.get("method").and_then(Value::as_str) == Some("eth_subscription") {
        return head_number(&frame).map_or(Frame::Unreadable, Frame::Head);
    }
    let Some(id) = response_id(&frame) else {
        return Frame::Unreadable;
    };
    if frame.get("result").is_some_and(Value::is_string) {
        // An open socket isn't usable until the node accepts the subscription,
        // and only the answer to the subscribe says that it has.
        return if id.as_deref() == Some(SUBSCRIBE_ID) {
            Frame::Confirmed
        } else {
            Frame::Ignored
        };
    }
    // The error member as JSON-RPC defines it: a frame with no code is not an
    // error response, and reading it as one would name a cause the provider
    // never gave.
    if frame
        .get("error")
        .and_then(|error| error.get("code"))
        .is_some_and(Value::is_i64)
    {
        return if refuses_subscribe(id.as_deref(), subscribed) {
            Frame::Rejected
        } else {
            Frame::Ignored
        };
    }
    Frame::Unreadable
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frames(texts: &[&str], subscribed: bool) -> Vec<Frame> {
        texts
            .iter()
            .map(|text| read_frame(text, subscribed))
            .collect()
    }

    #[test]
    fn reads_heads_confirmations_and_rejections() {
        assert_eq!(
            frames(
                &[
                    r#"{"jsonrpc":"2.0","method":"eth_subscription","params":{"subscription":"0xs","result":{"number":"0x2a"}}}"#,
                    r#"{"jsonrpc":"2.0","id":1,"result":"0xs"}"#,
                    r#"{"jsonrpc":"2.0","id":"1","result":"0xs"}"#,
                    r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"no"}}"#,
                    r#"{"jsonrpc":"2.0","id":"1","error":{"code":-32601,"message":"no"}}"#,
                    r#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse"}}"#,
                ],
                false
            ),
            vec![
                Frame::Head(42),
                Frame::Confirmed,
                Frame::Confirmed,
                Frame::Rejected,
                Frame::Rejected,
                Frame::Rejected
            ]
        );
    }

    #[test]
    fn ignores_responses_about_anything_else() {
        assert_eq!(
            (
                frames(
                    &[
                        r#"{"jsonrpc":"2.0","id":7,"result":"0xother"}"#,
                        r#"{"jsonrpc":"2.0","id":7,"error":{"code":-32005,"message":"limit"}}"#,
                    ],
                    false
                ),
                frames(
                    &[r#"{"jsonrpc":"2.0","id":null,"error":{"code":-32029,"message":"limit"}}"#],
                    true
                ),
            ),
            (vec![Frame::Ignored, Frame::Ignored], vec![Frame::Ignored])
        );
    }

    #[test]
    fn calls_anything_else_unreadable() {
        assert_eq!(
            frames(
                &[
                    "not json at all",
                    r#"{"jsonrpc":"2.0","hello":"world"}"#,
                    r#"[1,2]"#,
                    r#"{"jsonrpc":"2.0","method":"eth_subscription","params":{"result":{"number":"later"}}}"#,
                ],
                false
            ),
            vec![
                Frame::Unreadable,
                Frame::Unreadable,
                Frame::Unreadable,
                Frame::Unreadable
            ]
        );
    }
}
