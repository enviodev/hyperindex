//! GraphQL-over-WebSocket subscriptions, supporting both protocols Hasura
//! serves on /v1/graphql:
//! - `graphql-transport-ws` (the modern graphql-ws protocol)
//! - `graphql-ws` (the legacy subscriptions-transport-ws protocol)
//!
//! Live queries behave like Hasura's multiplexed live queries observably:
//! an immediate first result, then a ~1s poll loop that pushes a new
//! payload whenever the result changes. `<T>_stream` roots advance their
//! cursor after every non-empty batch.
//!
//! Protocol differences pinned by the differential suite:
//! - subscribe/start message types (`subscribe` vs `start`), data types
//!   (`next` vs `data`).
//! - error frame payloads: the modern protocol carries a bare ARRAY of
//!   GraphQL errors; the legacy protocol wraps them in `{"errors": [...]}`.
//! - the legacy protocol emits `ka` keepalives.

use super::exec::error::GraphQLError;
use super::exec::{self, ir, GraphQLRequest, Transport};
use super::gql::schema_build::Role;
use super::http::AppState;
use axum::body::Bytes;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::http::HeaderMap;
use axum::response::IntoResponse;
use futures_util::sink::SinkExt;
use futures_util::stream::StreamExt;
use serde_json::json;
use std::collections::HashMap;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const POLL_INTERVAL: Duration = Duration::from_millis(1000);
const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(5);
/// How often the dead-connection check runs (independent of the
/// server-configured ping interval, so detection latency doesn't depend on
/// a large ENVIO_SERVE_WS_PING_INTERVAL_MS): a connection is only ever
/// declared dead on one of these ticks, so this bounds how far past "2x
/// ping interval" the actual close can lag.
const DEAD_CHECK_INTERVAL: Duration = Duration::from_secs(2);
/// Longest a graceful writer-task drain waits after the connection loop
/// exits before the task is force-aborted. Guards against a peer that
/// stopped reading (TCP send buffer full) leaving `ws_tx.send` blocked
/// forever on close.
const WRITER_DRAIN_TIMEOUT: Duration = Duration::from_secs(2);
/// Consecutive connection-level Postgres failures a subscription survives
/// (silently retrying on the poll interval) before it gives up with a
/// terminal error frame. Without this, any 1-second Postgres blip
/// permanently kills every active subscription — most graphql-ws clients
/// treat an error frame as terminal and never resubscribe.
const SUBSCRIPTION_TRANSIENT_RETRIES: u32 = 5;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Protocol {
    /// graphql-transport-ws
    Modern,
    /// subscriptions-transport-ws (legacy; subprotocol name "graphql-ws")
    Legacy,
}

impl Protocol {
    fn data_type(&self) -> &'static str {
        match self {
            Protocol::Modern => "next",
            Protocol::Legacy => "data",
        }
    }
    fn start_type(&self) -> &'static str {
        match self {
            Protocol::Modern => "subscribe",
            Protocol::Legacy => "start",
        }
    }
    fn stop_type(&self) -> &'static str {
        match self {
            Protocol::Modern => "complete",
            Protocol::Legacy => "stop",
        }
    }
}

pub fn handle_upgrade(
    state: AppState,
    _headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> axum::response::Response {
    upgrade
        .protocols(["graphql-transport-ws", "graphql-ws"])
        .on_upgrade(move |socket| async move {
            let protocol = match socket.protocol().and_then(|p| p.to_str().ok()) {
                Some("graphql-transport-ws") => Protocol::Modern,
                _ => Protocol::Legacy,
            };
            run_connection(state, socket, protocol).await;
        })
        .into_response()
}

struct Connection {
    state: AppState,
    protocol: Protocol,
    sender: mpsc::UnboundedSender<Message>,
    role: Option<Role>,
    /// Live operations by client-assigned id; sending on the channel stops
    /// the poll task.
    operations: HashMap<String, tokio::task::JoinHandle<()>>,
}

async fn run_connection(state: AppState, socket: WebSocket, protocol: Protocol) {
    let ping_interval = state.serve.ws_ping_interval;
    let dead_after = ping_interval * 2;

    let (mut ws_tx, mut ws_rx) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();

    let mut writer = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if ws_tx.send(msg).await.is_err() {
                break;
            }
        }
    });

    let mut conn = Connection {
        state,
        protocol,
        sender: tx.clone(),
        role: None,
        operations: HashMap::new(),
    };

    let mut keepalive = tokio::time::interval(KEEPALIVE_INTERVAL);
    keepalive.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    // Server-driven protocol-level ping, independent of either GraphQL
    // sub-protocol's own app-level keepalive frames: a client that stops
    // reading (frozen, network black hole) never returns a pong or any
    // other traffic, so the connection -- and every subscription poll task
    // it's keeping alive -- gets torn down instead of running against
    // Postgres forever in the background.
    let mut dead_check = tokio::time::interval(std::cmp::min(ping_interval, DEAD_CHECK_INTERVAL));
    dead_check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut last_activity = Instant::now();
    let mut last_ping_sent = Instant::now();

    loop {
        tokio::select! {
            _ = keepalive.tick() => {
                if conn.protocol == Protocol::Legacy && conn.role.is_some() {
                    let _ = conn.sender.send(Message::Text("{\"type\":\"ka\"}".into()));
                }
            }
            _ = dead_check.tick() => {
                let now = Instant::now();
                if now.duration_since(last_activity) > dead_after {
                    println!("envio serve: closing websocket, no pong/traffic for {:?}", now.duration_since(last_activity));
                    let _ = conn.sender.send(Message::Close(Some(axum::extract::ws::CloseFrame {
                        code: 4408,
                        reason: "ping timeout".into(),
                    })));
                    break;
                }
                if now.duration_since(last_ping_sent) >= ping_interval {
                    last_ping_sent = now;
                    let _ = conn.sender.send(Message::Ping(Bytes::new()));
                }
            }
            incoming = ws_rx.next() => {
                let Some(Ok(msg)) = incoming else { break };
                last_activity = Instant::now();
                match msg {
                    Message::Text(text) => {
                        if handle_frame(&mut conn, &text).await.is_err() {
                            break;
                        }
                    }
                    Message::Ping(_) | Message::Pong(_) => {}
                    Message::Close(_) => break,
                    Message::Binary(_) => {}
                }
            }
        }
    }

    for (_, task) in conn.operations.drain() {
        task.abort();
    }
    drop(tx);
    if tokio::time::timeout(WRITER_DRAIN_TIMEOUT, &mut writer)
        .await
        .is_err()
    {
        writer.abort();
    }
}

/// Returns Err to close the connection.
async fn handle_frame(conn: &mut Connection, text: &str) -> Result<(), ()> {
    let frame: serde_json::Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(_) => {
            return if conn.protocol == Protocol::Modern {
                Err(())
            } else {
                Ok(())
            }
        }
    };
    let frame_type = frame.get("type").and_then(|t| t.as_str()).unwrap_or("");

    match frame_type {
        "connection_init" => {
            let secret = frame
                .get("payload")
                .and_then(|p| p.get("headers"))
                .and_then(|h| {
                    h.get("x-hasura-admin-secret")
                        .or_else(|| h.get("X-Hasura-Admin-Secret"))
                })
                .and_then(|v| v.as_str());
            let role = match secret {
                None => Role::Public,
                Some(s) if s == conn.state.serve.admin_secret => Role::Admin,
                Some(_) => {
                    let err = GraphQLError::access_denied();
                    match conn.protocol {
                        Protocol::Modern => {
                            // graphql-ws: reject with a close frame.
                            let _ = conn.sender.send(Message::Close(Some(
                                axum::extract::ws::CloseFrame {
                                    code: 4403,
                                    reason: "Forbidden".into(),
                                },
                            )));
                            return Err(());
                        }
                        Protocol::Legacy => {
                            send_json(
                                conn,
                                json!({"type": "connection_error", "payload": err.response_body()}),
                            );
                            return Err(());
                        }
                    }
                }
            };
            conn.role = Some(role);
            send_json(conn, json!({"type": "connection_ack"}));
            if conn.protocol == Protocol::Legacy {
                let _ = conn.sender.send(Message::Text("{\"type\":\"ka\"}".into()));
            }
            Ok(())
        }
        "ping" => {
            send_json(conn, json!({"type": "pong"}));
            Ok(())
        }
        "pong" => Ok(()),
        "connection_terminate" => Err(()),
        t if t == conn.protocol.start_type() => {
            let Some(role) = conn.role else {
                // Operations before connection_init.
                return match conn.protocol {
                    Protocol::Modern => {
                        let _ =
                            conn.sender
                                .send(Message::Close(Some(axum::extract::ws::CloseFrame {
                                    code: 4401,
                                    reason: "Unauthorized".into(),
                                })));
                        Err(())
                    }
                    Protocol::Legacy => Ok(()),
                };
            };
            let Some(id) = frame.get("id").and_then(|v| v.as_str()).map(String::from) else {
                return Ok(());
            };
            if conn.operations.contains_key(&id) {
                if conn.protocol == Protocol::Modern {
                    let _ = conn
                        .sender
                        .send(Message::Close(Some(axum::extract::ws::CloseFrame {
                            code: 4409,
                            reason: format!("Subscriber for {id} already exists").into(),
                        })));
                    return Err(());
                }
                return Ok(());
            }
            let payload = frame.get("payload").cloned().unwrap_or(json!({}));
            let request = GraphQLRequest {
                query: payload
                    .get("query")
                    .and_then(|q| q.as_str())
                    .map(String::from),
                variables: payload.get("variables").cloned(),
                operation_name: payload
                    .get("operationName")
                    .and_then(|o| o.as_str())
                    .map(String::from),
            };
            start_operation(conn, role, id, request);
            Ok(())
        }
        t if t == conn.protocol.stop_type() => {
            if let Some(id) = frame.get("id").and_then(|v| v.as_str()) {
                if let Some(task) = conn.operations.remove(id) {
                    task.abort();
                    // The client asked to stop; the legacy protocol echoes a
                    // complete frame, the modern one does not.
                    if conn.protocol == Protocol::Legacy {
                        send_json(conn, json!({"type": "complete", "id": id}));
                    }
                }
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn send_json(conn: &Connection, value: serde_json::Value) {
    let _ = conn.sender.send(Message::Text(value.to_string().into()));
}

fn start_operation(conn: &mut Connection, role: Role, id: String, request: GraphQLRequest) {
    let state = conn.state.clone();
    let protocol = conn.protocol;
    let sender = conn.sender.clone();
    let op_id = id.clone();

    let task = tokio::spawn(async move {
        run_operation(state, protocol, role, op_id, request, sender).await;
    });
    conn.operations.insert(id, task);
}

fn send_frame(
    sender: &mpsc::UnboundedSender<Message>,
    frame_type: &str,
    id: &str,
    payload_json: Option<&str>,
) {
    let mut out = String::with_capacity(64 + payload_json.map_or(0, |p| p.len()));
    out.push_str("{\"type\":");
    out.push_str(&serde_json::to_string(frame_type).unwrap());
    out.push_str(",\"id\":");
    out.push_str(&serde_json::to_string(id).unwrap());
    if let Some(p) = payload_json {
        out.push_str(",\"payload\":");
        out.push_str(p);
    }
    out.push('}');
    let _ = sender.send(Message::Text(out.into()));
}

fn send_error(
    sender: &mpsc::UnboundedSender<Message>,
    protocol: Protocol,
    id: &str,
    error: &GraphQLError,
) {
    let payload = match protocol {
        // Modern protocol: a bare array of GraphQL errors.
        Protocol::Modern => serde_json::Value::Array(vec![error.to_json()]).to_string(),
        // Legacy protocol: wrapped in an errors object.
        Protocol::Legacy => error.response_body().to_string(),
    };
    send_frame(sender, "error", id, Some(&payload));
}

async fn run_operation(
    state: AppState,
    protocol: Protocol,
    role: Role,
    id: String,
    request: GraphQLRequest,
    sender: mpsc::UnboundedSender<Message>,
) {
    let schema = state.schemas.for_role(role);
    let operation =
        match exec::validate::plan_request(&state.serve.model, schema, &request, Transport::Ws) {
            Ok(op) => op,
            Err(e) => {
                send_error(&sender, protocol, &id, &e);
                return;
            }
        };

    match operation.kind {
        ir::OperationKind::Query => {
            match exec::execute_operation(&state.serve, schema, &operation).await {
                Ok(body) => {
                    send_frame(&sender, protocol.data_type(), &id, Some(&body));
                    send_frame(&sender, "complete", &id, None);
                }
                Err(e) => send_error(&sender, protocol, &id, &e),
            }
        }
        ir::OperationKind::Subscription => {
            run_subscription(state.clone(), protocol, role, id, operation, sender).await
        }
    }
}

/// Live query / stream loop: emit the first result immediately, then poll,
/// pushing only when the payload changes (streams: when a batch is
/// non-empty, advancing the cursor).
async fn run_subscription(
    state: AppState,
    protocol: Protocol,
    role: Role,
    id: String,
    mut operation: ir::Operation,
    sender: mpsc::UnboundedSender<Message>,
) {
    let schema = state.schemas.for_role(role);
    let is_stream = matches!(
        operation.root_fields.first(),
        Some(ir::RootField::Table(ir::TableRoot {
            kind: ir::TableRootKind::Stream { .. },
            ..
        }))
    );

    let mut last_payload: Option<String> = None;
    let mut consecutive_failures: u32 = 0;
    loop {
        let result = if is_stream {
            match exec::execute_stream_operation(&state.serve, &operation).await {
                Ok((body, Some(new_cursor_values))) => {
                    // Non-empty batch: emit and move the cursor.
                    send_frame(&sender, protocol.data_type(), &id, Some(&body));
                    apply_cursor(&mut operation, new_cursor_values);
                    Ok(())
                }
                Ok((_, None)) => Ok(()), // empty batch: keep waiting
                Err(e) => Err(e),
            }
        } else {
            match exec::execute_operation(&state.serve, schema, &operation).await {
                Ok(body) => {
                    if last_payload.as_deref() != Some(body.as_str()) {
                        send_frame(&sender, protocol.data_type(), &id, Some(&body));
                        last_payload = Some(body);
                    }
                    Ok(())
                }
                Err(e) => Err(e),
            }
        };
        match result {
            Ok(()) => consecutive_failures = 0,
            Err(e) => {
                // Connection-level failures (Postgres down/restarting, pool
                // exhausted) self-heal: keep polling and re-attempt so the
                // stream resumes when Postgres does. Deterministic query
                // errors terminate immediately, matching Hasura.
                if !e.is_transient_infra() || consecutive_failures >= SUBSCRIPTION_TRANSIENT_RETRIES
                {
                    send_error(&sender, protocol, &id, &e);
                    return;
                }
                consecutive_failures += 1;
            }
        }
        tokio::time::sleep(POLL_INTERVAL).await;
    }
}

fn apply_cursor(operation: &mut ir::Operation, values: Vec<String>) {
    if let Some(ir::RootField::Table(root)) = operation.root_fields.first_mut() {
        if let ir::TableRootKind::Stream { cursor, .. } = &mut root.kind {
            for (c, v) in cursor.iter_mut().zip(values) {
                c.initial_value = Some(ir::SqlValue::new(v, c.pg_type.clone()));
            }
        }
    }
}
