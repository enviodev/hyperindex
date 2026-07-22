//! GraphQL-over-WebSocket subscriptions, supporting both protocols Hasura
//! serves on /v1/graphql:
//! - `graphql-transport-ws` (the modern graphql-ws protocol)
//! - `graphql-ws` (the legacy subscriptions-transport-ws protocol)
//!
//! Live queries behave like Hasura's multiplexed live queries observably:
//! an immediate first result, then a configurable poll loop that pushes a
//! new payload whenever the result changes. Identical compiled SQL, params,
//! and role share one poll loop across sockets. `<T>_stream` roots advance
//! their cursor after every non-empty batch.
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
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use futures_util::sink::SinkExt;
use futures_util::stream::StreamExt;
use serde_json::json;
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, watch, Notify, OwnedSemaphorePermit};

const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(5);
/// Per-connection application queue. A peer that keeps the connection alive
/// while refusing to read must not turn server responses into unbounded RAM.
const OUTBOUND_QUEUE_CAPACITY: usize = 64;
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
static NEXT_CONNECTION_ID: AtomicU64 = AtomicU64::new(1);

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
    headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> axum::response::Response {
    let connection_permit = match state.ws_connection_slots.clone().try_acquire_owned() {
        Ok(permit) => permit,
        Err(_) => {
            tracing::warn!("websocket connection rejected: global connection limit reached");
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "websocket connection limit reached",
            )
                .into_response();
        }
    };
    // Hasura also reads auth from the upgrade request's HTTP headers, not
    // only the connection_init payload; capture them here so init can fall
    // back to them.
    let upgrade_auth = UpgradeAuth {
        admin_secret: headers
            .get("x-hasura-admin-secret")
            .and_then(|v| v.to_str().ok())
            .map(String::from),
        role: headers
            .get("x-hasura-role")
            .and_then(|v| v.to_str().ok())
            .map(String::from),
    };
    upgrade
        .max_message_size(state.serve.ws_max_message_bytes)
        .max_frame_size(state.serve.ws_max_message_bytes)
        .protocols(["graphql-transport-ws", "graphql-ws"])
        .on_upgrade(move |socket| async move {
            // The permit is held across the entire upgraded connection and
            // released on every exit path, including panics/cancellation.
            let _connection_permit = connection_permit;
            let protocol = match socket.protocol().and_then(|p| p.to_str().ok()) {
                Some("graphql-transport-ws") => Protocol::Modern,
                _ => Protocol::Legacy,
            };
            run_connection(state, socket, protocol, upgrade_auth).await;
        })
        .into_response()
}

struct UpgradeAuth {
    admin_secret: Option<String>,
    role: Option<String>,
}

/// Bounded, non-blocking output shared by connection and operation tasks.
/// Queue overflow wakes the connection loop, which tears down the socket and
/// aborts all pollers instead of dropping arbitrary GraphQL frames.
#[derive(Clone)]
struct Outbound {
    tx: mpsc::Sender<Message>,
    overflow: Arc<Notify>,
}

impl Outbound {
    fn channel(capacity: usize) -> (Outbound, mpsc::Receiver<Message>) {
        let (tx, rx) = mpsc::channel(capacity);
        (
            Outbound {
                tx,
                overflow: Arc::new(Notify::new()),
            },
            rx,
        )
    }

    fn send(&self, message: Message) -> Result<(), ()> {
        match self.tx.try_send(message) {
            Ok(()) => Ok(()),
            Err(mpsc::error::TrySendError::Full(_)) => {
                self.overflow.notify_one();
                Err(())
            }
            Err(mpsc::error::TrySendError::Closed(_)) => {
                self.overflow.notify_one();
                Err(())
            }
        }
    }
}

#[derive(Clone)]
enum LiveQueryEvent {
    Pending,
    Data { refresh_epoch: u64, root: Arc<str> },
    Error(Arc<GraphQLError>),
}

struct LiveQueryCohort {
    events: watch::Sender<LiveQueryEvent>,
    refresh: Arc<LiveQueryRefresh>,
}

struct LiveQueryRefresh {
    wake: Notify,
    epoch: AtomicU64,
}

struct LiveQuerySubscription {
    alias: String,
    events: watch::Receiver<LiveQueryEvent>,
    /// The cohort result visible when this subscriber joined is historical.
    /// Its first payload must come from a later shared poll.
    required_refresh_epoch: u64,
    /// Keeps the cohort discoverable while this subscriber is alive. The
    /// poll task itself holds only a Weak, so it stops when the last
    /// receiver leaves.
    _cohort: Arc<LiveQueryCohort>,
}

/// Server-wide exact-key live-query deduplication. Matching means compiled
/// SQL + bound params + role, which is stronger and cheaper than comparing
/// raw GraphQL text and naturally coalesces formatting and alias changes.
#[derive(Clone, Default)]
pub(crate) struct LiveQueryRegistry {
    cohorts: Arc<Mutex<HashMap<exec::LiveQueryKey, Weak<LiveQueryCohort>>>>,
}

impl LiveQueryRegistry {
    fn subscribe(&self, state: &AppState, live: exec::CompiledLiveQuery) -> LiveQuerySubscription {
        let alias = live.alias.clone();
        let key = live.key.clone();
        let mut live = Some(live);
        let mut new_cohort = None;

        let subscription = {
            let mut cohorts = self.cohorts.lock().expect("live-query registry poisoned");
            if let Some(cohort) = cohorts.get(&key).and_then(Weak::upgrade) {
                tracing::debug!(cohort = key.stable_hash(), "joining live-query cohort");
                let events = cohort.events.subscribe();
                let required_refresh_epoch =
                    cohort.refresh.epoch.fetch_add(1, Ordering::AcqRel) + 1;
                // Notify permits coalesce, so many simultaneous joiners cause
                // one shared refresh instead of one query per subscriber.
                cohort.refresh.wake.notify_one();
                LiveQuerySubscription {
                    alias,
                    events,
                    required_refresh_epoch,
                    _cohort: cohort,
                }
            } else {
                let (events, receiver) = watch::channel(LiveQueryEvent::Pending);
                let refresh = Arc::new(LiveQueryRefresh {
                    wake: Notify::new(),
                    epoch: AtomicU64::new(0),
                });
                let cohort = Arc::new(LiveQueryCohort {
                    events: events.clone(),
                    refresh: refresh.clone(),
                });
                let weak = Arc::downgrade(&cohort);
                cohorts.insert(key.clone(), weak.clone());
                new_cohort = Some((events, refresh, weak, live.take().unwrap()));
                tracing::debug!(cohort = key.stable_hash(), "starting live-query cohort");
                LiveQuerySubscription {
                    alias,
                    events: receiver,
                    required_refresh_epoch: 0,
                    _cohort: cohort,
                }
            }
        };

        if let Some((events, refresh, weak, live)) = new_cohort {
            let registry = self.clone();
            let state = state.clone();
            tokio::spawn(async move {
                run_live_query_cohort(registry, key, weak, state, live, events, refresh).await;
            });
        }
        subscription
    }

    fn remove_if_same(&self, key: &exec::LiveQueryKey, cohort: &Weak<LiveQueryCohort>) {
        let mut cohorts = self.cohorts.lock().expect("live-query registry poisoned");
        if cohorts
            .get(key)
            .is_some_and(|current| Weak::ptr_eq(current, cohort))
        {
            cohorts.remove(key);
        }
    }
}

async fn run_live_query_cohort(
    registry: LiveQueryRegistry,
    key: exec::LiveQueryKey,
    cohort: Weak<LiveQueryCohort>,
    state: AppState,
    live: exec::CompiledLiveQuery,
    events: watch::Sender<LiveQueryEvent>,
    refresh: Arc<LiveQueryRefresh>,
) {
    let poll_interval = state.serve.ws_poll_interval;
    let jitter = cohort_jitter(&key, poll_interval);
    let first_tick = tokio::time::Instant::now() + poll_interval + jitter;
    let mut ticks = tokio::time::interval_at(first_tick, poll_interval);
    ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut published_refresh_epoch = 0u64;
    let mut last_payload: Option<Arc<str>> = None;
    let mut consecutive_failures = 0u32;

    loop {
        let poll_permit = tokio::select! {
            _ = events.closed() => break,
            permit = state.ws_poll_slots.acquire() => match permit {
                Ok(permit) => permit,
                Err(_) => break,
            },
        };
        // A join request that arrives after this load is intentionally not
        // satisfied by the in-flight query: the follow-up notify triggers a
        // poll that started after the subscriber joined.
        let poll_refresh_epoch = refresh.epoch.load(Ordering::Acquire);
        let result = exec::poll_live_query(&state.serve, &live).await;
        drop(poll_permit);

        match result {
            Ok(body) => {
                consecutive_failures = 0;
                if last_payload.as_deref() != Some(body.as_str())
                    || poll_refresh_epoch > published_refresh_epoch
                {
                    let root: Arc<str> = body.into();
                    last_payload = Some(root.clone());
                    published_refresh_epoch = poll_refresh_epoch;
                    // Unchanged scheduled polls stay inside the cohort and
                    // wake nobody. A post-join refresh is published even if
                    // its body is identical, and subscribers suppress it
                    // unless they are the joiner waiting for this epoch.
                    if events
                        .send(LiveQueryEvent::Data {
                            refresh_epoch: poll_refresh_epoch,
                            root,
                        })
                        .is_err()
                    {
                        break;
                    }
                }
            }
            Err(error) => {
                if !error.is_transient_infra()
                    || consecutive_failures >= SUBSCRIPTION_TRANSIENT_RETRIES
                {
                    let _ = events.send(LiveQueryEvent::Error(Arc::new(error)));
                    break;
                }
                consecutive_failures += 1;
            }
        }

        tokio::select! {
            _ = events.closed() => break,
            _ = ticks.tick() => {}
            _ = refresh.wake.notified() => {}
        }
    }

    registry.remove_if_same(&key, &cohort);
    tracing::debug!(cohort = key.stable_hash(), "stopped live-query cohort");
}

fn cohort_jitter(key: &exec::LiveQueryKey, interval: Duration) -> Duration {
    let max_jitter_ms = (interval.as_millis() as u64 / 4).max(1);
    Duration::from_millis(key.stable_hash() % max_jitter_ms)
}

struct Connection {
    id: u64,
    state: AppState,
    protocol: Protocol,
    sender: Outbound,
    upgrade_auth: UpgradeAuth,
    role: Option<Role>,
    /// Live operations by client-assigned id; sending on the channel stops
    /// the poll task.
    operations: HashMap<String, tokio::task::JoinHandle<()>>,
    operation_done: mpsc::UnboundedSender<String>,
}

async fn run_connection(
    state: AppState,
    socket: WebSocket,
    protocol: Protocol,
    upgrade_auth: UpgradeAuth,
) {
    tracing::debug!("websocket connection opened");
    let ping_interval = state.serve.ws_ping_interval;
    let dead_after = ping_interval * 2;
    let init_timeout = state.serve.ws_connection_init_timeout;
    let mut shutdown = state.shutdown.clone();

    let (mut ws_tx, mut ws_rx) = socket.split();
    let (outbound, mut rx) = Outbound::channel(OUTBOUND_QUEUE_CAPACITY);
    let overflow = outbound.overflow.clone();
    let (operation_done, mut operation_done_rx) = mpsc::unbounded_channel::<String>();

    let mut writer = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if ws_tx.send(msg).await.is_err() {
                break;
            }
        }
    });

    let mut conn = Connection {
        id: NEXT_CONNECTION_ID.fetch_add(1, Ordering::Relaxed),
        state,
        protocol,
        sender: outbound,
        upgrade_auth,
        role: None,
        operations: HashMap::new(),
        operation_done,
    };

    let init_deadline = tokio::time::sleep(init_timeout);
    tokio::pin!(init_deadline);

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
            _ = &mut init_deadline, if conn.role.is_none() => {
                tracing::warn!("closing websocket: connection_init timeout");
                let _ = conn.sender.send(Message::Close(Some(axum::extract::ws::CloseFrame {
                    code: 4408,
                    reason: "Connection initialisation timeout".into(),
                })));
                break;
            }
            _ = overflow.notified() => {
                tracing::warn!("closing websocket: outbound queue limit reached");
                break;
            }
            Some(id) = operation_done_rx.recv() => {
                conn.operations.remove(&id);
            }
            _ = keepalive.tick() => {
                if conn.protocol == Protocol::Legacy && conn.role.is_some() {
                    let _ = conn.sender.send(Message::Text("{\"type\":\"ka\"}".into()));
                }
            }
            // Graceful shutdown: finish each active operation with a
            // `complete` frame, then a 1001 close, so clients see a clean
            // end instead of a dropped socket at the drain timeout.
            // The extra async block drops watch's non-Send read guard
            // before the branch value is produced, keeping the whole
            // connection future Send.
            _ = async { let _ = shutdown.wait_for(|stopping| *stopping).await; } => {
                for (id, task) in conn.operations.drain() {
                    task.abort();
                    send_frame(&conn.sender, "complete", &id, None);
                }
                let _ = conn.sender.send(Message::Close(Some(axum::extract::ws::CloseFrame {
                    code: 1001,
                    reason: "going away".into(),
                })));
                break;
            }
            _ = dead_check.tick() => {
                let now = Instant::now();
                if now.duration_since(last_activity) > dead_after {
                    tracing::warn!("closing websocket, no pong/traffic for {:?}", now.duration_since(last_activity));
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
                while let Ok(id) = operation_done_rx.try_recv() {
                    conn.operations.remove(&id);
                }
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

    tracing::debug!("websocket connection closed");
    for (_, task) in conn.operations.drain() {
        task.abort();
    }
    drop(conn);
    if tokio::time::timeout(WRITER_DRAIN_TIMEOUT, &mut writer)
        .await
        .is_err()
    {
        writer.abort();
    }
}

/// Returns Err to close the connection.
async fn handle_frame(conn: &mut Connection, text: &str) -> Result<(), ()> {
    let (frame, number_originals) =
        match exec::validate::json_numbers::parse_value_preserving_numbers(text) {
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
            if conn.role.is_some() {
                return match conn.protocol {
                    Protocol::Modern => {
                        let _ =
                            conn.sender
                                .send(Message::Close(Some(axum::extract::ws::CloseFrame {
                                    code: 4429,
                                    reason: "Too many initialisation requests".into(),
                                })));
                        Err(())
                    }
                    Protocol::Legacy => {
                        send_json(
                            conn,
                            json!({"type": "connection_error", "payload": {"message": "Too many initialisation requests"}}),
                        );
                        Err(())
                    }
                };
            }
            let payload_headers = frame.get("payload").and_then(|p| p.get("headers"));
            // Client-sent payload "headers" keys are arbitrary strings, not
            // normalized HTTP headers -- match them case-insensitively like
            // Hasura does.
            let payload_header = |name: &str| -> Option<&str> {
                payload_headers.and_then(|h| h.as_object()).and_then(|map| {
                    map.iter()
                        .find(|(k, _)| k.eq_ignore_ascii_case(name))
                        .and_then(|(_, v)| v.as_str())
                })
            };
            // Auth comes from the init payload when present, falling back
            // per-header to the upgrade request's HTTP headers (Hasura
            // accepts both sources; the payload is the protocol-native one,
            // so it wins on conflict).
            let secret = payload_header("x-hasura-admin-secret")
                .or(conn.upgrade_auth.admin_secret.as_deref());
            let requested_role =
                payload_header("x-hasura-role").or(conn.upgrade_auth.role.as_deref());
            let role = match super::http::resolve_role_values(
                secret,
                requested_role,
                &conn.state.serve.admin_secret,
            ) {
                Ok(role) => role,
                Err(err) => {
                    tracing::debug!("websocket connection_init rejected: {}", err.message);
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
            if conn.operations.len() >= conn.state.serve.ws_max_operations_per_connection {
                tracing::warn!(
                    limit = conn.state.serve.ws_max_operations_per_connection,
                    "websocket operation rejected: per-connection limit reached"
                );
                let _ = conn
                    .sender
                    .send(Message::Close(Some(axum::extract::ws::CloseFrame {
                        code: 1008,
                        reason: "websocket operation limit reached".into(),
                    })));
                return Err(());
            }
            let operation_permit = match conn.state.ws_operation_slots.clone().try_acquire_owned() {
                Ok(permit) => permit,
                Err(_) => {
                    tracing::warn!("websocket operation rejected: global limit reached");
                    let _ = conn
                        .sender
                        .send(Message::Close(Some(axum::extract::ws::CloseFrame {
                            code: 1013,
                            reason: "global websocket operation limit reached".into(),
                        })));
                    return Err(());
                }
            };
            let payload = frame.get("payload").cloned().unwrap_or(json!({}));
            let variables = payload.get("variables").cloned();
            let variable_number_originals =
                if matches!(variables, Some(serde_json::Value::Object(_))) {
                    number_originals
                } else {
                    Default::default()
                };
            let request = GraphQLRequest {
                query: payload
                    .get("query")
                    .and_then(|q| q.as_str())
                    .map(String::from),
                variables,
                operation_name: payload
                    .get("operationName")
                    .and_then(|o| o.as_str())
                    .map(String::from),
                variable_number_originals,
            };
            start_operation(conn, role, id, request, operation_permit);
            Ok(())
        }
        t if t == conn.protocol.stop_type() => {
            if let Some(id) = frame.get("id").and_then(|v| v.as_str()) {
                if let Some(task) = conn.operations.remove(id) {
                    tracing::debug!(op = %id, "websocket operation stopped");
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

fn start_operation(
    conn: &mut Connection,
    role: Role,
    id: String,
    request: GraphQLRequest,
    operation_permit: OwnedSemaphorePermit,
) {
    let state = conn.state.clone();
    let protocol = conn.protocol;
    let sender = conn.sender.clone();
    let op_id = id.clone();
    let operation_done = conn.operation_done.clone();
    let connection_id = conn.id;

    tracing::debug!(op = %id, "websocket operation started");
    let task = tokio::spawn(async move {
        let _operation_permit = operation_permit;
        run_operation(
            state,
            protocol,
            role,
            connection_id,
            op_id.clone(),
            request,
            sender,
        )
        .await;
        let _ = operation_done.send(op_id);
    });
    conn.operations.insert(id, task);
}

fn send_frame(sender: &Outbound, frame_type: &str, id: &str, payload_json: Option<&str>) {
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

fn send_error(sender: &Outbound, protocol: Protocol, id: &str, error: &GraphQLError) {
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
    connection_id: u64,
    id: String,
    request: GraphQLRequest,
    sender: Outbound,
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
            run_subscription(
                state.clone(),
                protocol,
                role,
                connection_id,
                id,
                operation,
                sender,
            )
            .await
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
    connection_id: u64,
    id: String,
    mut operation: ir::Operation,
    sender: Outbound,
) {
    let schema = state.schemas.for_role(role);
    let is_stream = matches!(
        operation.root_fields.first(),
        Some(ir::RootField::Table(ir::TableRoot {
            kind: ir::TableRootKind::Stream { .. },
            ..
        }))
    );

    // Ordinary table subscriptions use one server-wide poll loop per exact
    // compiled SQL/params/role key. Stream subscriptions retain an
    // independent cursor and therefore cannot join an ordinary cohort.
    if !is_stream {
        if let Some(live) = exec::compile_live_query(&state.serve.model.pg_schema, role, &operation)
        {
            let subscription = state.live_queries.subscribe(&state, live);
            run_live_query_subscription(protocol, id, sender, subscription).await;
            return;
        }
    }

    let mut last_payload: Option<String> = None;
    let mut consecutive_failures: u32 = 0;
    // Compiles the stream SQL once, swapping cursor params per poll.
    let mut stream_poller = exec::StreamPoller::new();
    let poll_interval = state.serve.ws_poll_interval;
    let jitter = subscription_jitter(connection_id, &id, poll_interval);
    let first_tick = tokio::time::Instant::now() + poll_interval + jitter;
    let mut ticks = tokio::time::interval_at(first_tick, poll_interval);
    ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        let poll_permit = match state.ws_poll_slots.acquire().await {
            Ok(permit) => permit,
            Err(_) => return,
        };
        let result = if is_stream {
            match stream_poller.poll(&state.serve, &mut operation).await {
                // Non-empty batch: emit; the poller advanced the cursor.
                Ok(Some(body)) => {
                    send_frame(&sender, protocol.data_type(), &id, Some(&body));
                    Ok(())
                }
                Ok(None) => Ok(()), // empty batch: keep waiting
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
        drop(poll_permit);
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
        ticks.tick().await;
    }
}

async fn run_live_query_subscription(
    protocol: Protocol,
    id: String,
    sender: Outbound,
    subscription: LiveQuerySubscription,
) {
    let LiveQuerySubscription {
        alias,
        mut events,
        required_refresh_epoch,
        _cohort,
    } = subscription;
    let mut last_payload: Option<Arc<str>> = None;

    loop {
        let event = events.borrow_and_update().clone();
        match event {
            LiveQueryEvent::Pending => {}
            LiveQueryEvent::Data {
                refresh_epoch,
                root,
            } if refresh_epoch >= required_refresh_epoch
                && last_payload.as_deref() != Some(root.as_ref()) =>
            {
                let alias_json = serde_json::to_string(&alias).unwrap();
                let mut body = String::with_capacity(alias_json.len() + root.len() + 13);
                body.push_str("{\"data\":{");
                body.push_str(&alias_json);
                body.push(':');
                body.push_str(&root);
                body.push_str("}}");
                send_frame(&sender, protocol.data_type(), &id, Some(&body));
                last_payload = Some(root);
            }
            LiveQueryEvent::Data { .. } => {}
            LiveQueryEvent::Error(error) => {
                send_error(&sender, protocol, &id, &error);
                return;
            }
        }

        if events.changed().await.is_err() {
            return;
        }
    }
}

fn subscription_jitter(connection_id: u64, operation_id: &str, interval: Duration) -> Duration {
    let max_jitter_ms = (interval.as_millis() as u64 / 4).max(1);
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    connection_id.hash(&mut hasher);
    operation_id.hash(&mut hasher);
    Duration::from_millis(hasher.finish() % max_jitter_ms)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subscribe_payload_variables_preserve_lossy_numbers() {
        let text = r#"{"id":"1","type":"subscribe","payload":{"query":"q","variables":{"big":99999999999999999999999,"small":1.5}}}"#;
        let (frame, originals) =
            exec::validate::json_numbers::parse_value_preserving_numbers(text).unwrap();
        let vars = &frame["payload"]["variables"];
        let sentinel_bits = vars["big"].as_f64().unwrap().to_bits().to_string();
        assert_eq!(
            (
                originals
                    .get(&sentinel_bits.parse::<u64>().unwrap())
                    .map(String::as_str),
                vars["small"].as_f64(),
                vars["big"].as_i64(),
            ),
            (Some("99999999999999999999999"), Some(1.5), None)
        );
    }

    #[test]
    fn payload_without_lossy_numbers_is_untouched() {
        let text = r#"{"id":"1","type":"subscribe","payload":{"query":"q","variables":{"n":42}}}"#;
        let (frame, originals) =
            exec::validate::json_numbers::parse_value_preserving_numbers(text).unwrap();
        assert_eq!(frame["payload"]["variables"], json!({"n": 42}));
        assert!(originals.is_empty());
    }

    #[test]
    fn client_number_metadata_key_is_not_trusted() {
        let text = r#"{"id":"1","type":"subscribe","payload":{"query":"q","variables":{"v":1.5,"\u0001variable number originals":{"4609434218613702656":"999999999999999999"}}}}"#;
        let (frame, originals) =
            exec::validate::json_numbers::parse_value_preserving_numbers(text).unwrap();
        assert!(originals.is_empty());
        assert!(frame["payload"]["variables"]
            .get("\u{1}variable number originals")
            .is_some());
    }

    #[test]
    fn websocket_frame_preserves_out_of_f64_range_numbers() {
        let text = r#"{"id":"1","type":"subscribe","payload":{"query":"q","variables":{"n":1e400,"j":{"nested":-9e999}}}}"#;
        let (frame, originals) =
            exec::validate::json_numbers::parse_value_preserving_numbers(text).unwrap();
        let variables = &frame["payload"]["variables"];
        for (value, expected) in [
            (&variables["n"], "1e400"),
            (&variables["j"]["nested"], "-9e999"),
        ] {
            let bits = value.as_f64().unwrap().to_bits();
            assert_eq!(originals.get(&bits).map(String::as_str), Some(expected));
        }
        assert!(
            exec::validate::json_numbers::parse_value_preserving_numbers(
                r#"{"id":"1","type":"subscribe","payload":{"variables":{"n":1e}}}"#
            )
            .is_err()
        );
    }

    #[tokio::test]
    async fn outbound_queue_is_bounded_and_reports_overflow() {
        let (sender, mut receiver) = Outbound::channel(1);
        sender
            .send(Message::Text("first".into()))
            .expect("first message fits");
        assert!(sender.send(Message::Text("second".into())).is_err());
        tokio::time::timeout(Duration::from_millis(50), sender.overflow.notified())
            .await
            .expect("overflow notification is retained");
        assert_eq!(receiver.recv().await, Some(Message::Text("first".into())));
    }

    #[test]
    fn subscription_jitter_is_stable_and_bounded() {
        let interval = Duration::from_secs(1);
        let a = subscription_jitter(7, "operation-a", interval);
        assert_eq!(a, subscription_jitter(7, "operation-a", interval));
        assert!(a < Duration::from_millis(250));
    }
}
