//! HTTP server: POST /v1/graphql (+ health endpoints and the WebSocket
//! upgrade for subscriptions).

use super::exec::{self, GraphQLRequest, Schemas};
use super::gql::schema_build::Role;
use super::ServeState;
use anyhow::Context;
use axum::body::Bytes;
use axum::error_handling::HandleErrorLayer;
use axum::extract::{ConnectInfo, Request, State};
use axum::http::{HeaderMap, StatusCode};
use axum::middleware::{self, Next};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::Router;
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tower::ServiceBuilder;

#[derive(Clone)]
pub struct AppState {
    pub serve: Arc<ServeState>,
    pub schemas: Arc<Schemas>,
}

/// How long in-flight requests get to finish after a shutdown signal
/// before the process exits anyway (open WebSocket subscriptions never
/// close on their own, so an unbounded drain would hang forever). Sits
/// just under Kubernetes' default 30s termination grace period so slow
/// but legitimate queries get most of the available window.
const SHUTDOWN_DRAIN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(25);

pub async fn serve(
    state: Arc<ServeState>,
    host: &str,
    port: u16,
    shutdown: impl std::future::Future<Output = ()> + Send + 'static,
) -> anyhow::Result<()> {
    let schemas = Arc::new(Schemas::build(&state.model));
    let rate_limiter = state
        .rate_limit_per_sec
        .map(|per_sec| Arc::new(RateLimiter::new(per_sec)));
    let app_state = AppState {
        serve: state,
        schemas,
    };

    // ConcurrencyLimitLayer caps in-flight query executions to the pool's
    // own capacity (default) so requests above that queue behind the
    // limiter instead of piling onto Postgres unboundedly; the outer
    // TimeoutLayer bounds that whole wait-for-slot-plus-execute window, so
    // a request that can't get a slot in time is shed with a clean error
    // instead of queuing forever. Scoped to the query POST handler only --
    // the WS upgrade GET on this same route must not inherit a request
    // timeout, or long-lived subscriptions would be killed after it elapses.
    let query_middleware = ServiceBuilder::new()
        .layer(HandleErrorLayer::new(handle_overload_error))
        .timeout(app_state.serve.request_timeout)
        .concurrency_limit(app_state.serve.max_concurrent_requests);

    let mut router = Router::new().route(
        "/v1/graphql",
        post(graphql_handler)
            .layer(query_middleware)
            .get(ws_or_get_handler),
    );
    if let Some(limiter) = rate_limiter {
        router = router.route_layer(middleware::from_fn_with_state(
            limiter,
            rate_limit_middleware,
        ));
    }

    let app = router
        .route("/healthz", get(healthz))
        .route("/hasura/healthz", get(healthz))
        .route("/livez", get(livez))
        .with_state(app_state)
        .into_make_service_with_connect_info::<SocketAddr>();

    let addr: SocketAddr = format!("{host}:{port}")
        .parse()
        .context("Invalid host/port")?;
    let listener = bind_with_keepalive(addr).context("Failed binding the serve listener")?;
    println!("envio serve: GraphQL API at http://{addr}/v1/graphql");

    let (tx, rx) = tokio::sync::watch::channel(false);
    tokio::spawn(async move {
        shutdown.await;
        let _ = tx.send(true);
    });
    let mut graceful_rx = rx.clone();
    let mut drain_rx = rx;
    tokio::select! {
        r = axum::serve(listener, app).with_graceful_shutdown(async move {
            let _ = graceful_rx.changed().await;
        }) => { r?; }
        _ = async move {
            let _ = drain_rx.changed().await;
            tokio::time::sleep(SHUTDOWN_DRAIN_TIMEOUT).await;
        } => {
            println!("envio serve: drain timeout reached, closing remaining connections");
        }
    }
    Ok(())
}

/// How long a connection can sit idle before the kernel starts probing it,
/// and how it probes -- tuned well below most orchestrators' idle-reap
/// windows so a half-open connection (peer vanished without a FIN/RST, e.g.
/// power loss or a hard network partition) gets reclaimed in well under a
/// minute instead of Linux's multi-hour default.
const TCP_KEEPALIVE_IDLE: Duration = Duration::from_secs(30);
const TCP_KEEPALIVE_INTERVAL: Duration = Duration::from_secs(10);
const TCP_KEEPALIVE_RETRIES: u32 = 3;

/// Binds the listening socket with SO_KEEPALIVE (and tuned probe timing
/// where the platform supports it) set before `listen()`, so accepted
/// connections inherit it -- a backstop under the WS-level ping/pong dead-
/// client detection for peers that vanish at the network level (ping/pong
/// only catches an application that stops reading on an otherwise-live
/// connection).
fn bind_with_keepalive(addr: SocketAddr) -> anyhow::Result<tokio::net::TcpListener> {
    use socket2::{Domain, Socket, TcpKeepalive, Type};

    let socket = Socket::new(Domain::for_address(addr), Type::STREAM, None)?;
    socket.set_nonblocking(true)?;
    socket.set_reuse_address(true)?;
    let keepalive = TcpKeepalive::new()
        .with_time(TCP_KEEPALIVE_IDLE)
        .with_interval(TCP_KEEPALIVE_INTERVAL);
    #[cfg(not(any(target_os = "windows", target_os = "openbsd", target_os = "redox")))]
    let keepalive = keepalive.with_retries(TCP_KEEPALIVE_RETRIES);
    socket.set_tcp_keepalive(&keepalive)?;
    socket.bind(&addr.into())?;
    socket.listen(1024)?;
    let std_listener: std::net::TcpListener = socket.into();
    Ok(tokio::net::TcpListener::from_std(std_listener)?)
}

/// Converts a tower error from the query middleware stack (timeout or
/// concurrency-limit overflow) into a clean HTTP response instead of a
/// hung connection or a panic. Outside Hasura-parity scope (Hasura has no
/// equivalent concept), so this is a plain HTTP status, not the
/// `{"errors": [...]}` GraphQL error shape.
async fn handle_overload_error(err: tower::BoxError) -> impl IntoResponse {
    if err.is::<tower::timeout::error::Elapsed>() {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            "request exceeded ENVIO_SERVE_REQUEST_TIMEOUT_MS",
        )
    } else {
        (StatusCode::INTERNAL_SERVER_ERROR, "internal error")
    }
}

/// Simple fixed-window per-IP request counter. Not exact (a client can
/// briefly exceed the rate right at a window boundary) but bounded memory,
/// lock-cheap, and enough to blunt a single misbehaving client -- this is
/// an optional backstop (ENVIO_SERVE_RATE_LIMIT_PER_SEC is unset by
/// default; Hasura OSS has no built-in rate limiting either).
struct RateLimiter {
    per_sec: u32,
    windows: Mutex<HashMap<std::net::IpAddr, (Instant, u32)>>,
}

impl RateLimiter {
    fn new(per_sec: u32) -> RateLimiter {
        RateLimiter {
            per_sec,
            windows: Mutex::new(HashMap::new()),
        }
    }

    /// True if the request should be allowed.
    fn check(&self, ip: std::net::IpAddr) -> bool {
        let mut windows = self.windows.lock().unwrap();
        let now = Instant::now();
        // Bound memory under many distinct IPs (e.g. a scan/DDoS): drop
        // windows that expired at least a second ago on every call instead
        // of growing the map forever.
        windows.retain(|_, (started, _)| now.duration_since(*started) < Duration::from_secs(2));
        let entry = windows.entry(ip).or_insert((now, 0));
        if now.duration_since(entry.0) >= Duration::from_secs(1) {
            *entry = (now, 0);
        }
        entry.1 += 1;
        entry.1 <= self.per_sec
    }
}

async fn rate_limit_middleware(
    State(limiter): State<Arc<RateLimiter>>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    req: Request,
    next: Next,
) -> axum::response::Response {
    if limiter.check(addr.ip()) {
        next.run(req).await
    } else {
        (StatusCode::TOO_MANY_REQUESTS, "rate limit exceeded").into_response()
    }
}

/// Readiness-style probe: verifies a pooled connection can run a query, so
/// orchestrators see Postgres outages instead of a permanently-green
/// process. Bounded independently of the pool's own wait timeout (via
/// ENVIO_SERVE_HEALTHZ_TIMEOUT_MS) so the probe answers fast even when the
/// pool is exhausted or the DB is frozen. Use `/livez` instead for a
/// process-only liveness check that doesn't depend on Postgres at all.
async fn healthz(State(state): State<AppState>) -> impl IntoResponse {
    let probe = async {
        let client = state.serve.pool.get().await.ok()?;
        client.simple_query("SELECT 1").await.ok()
    };
    match tokio::time::timeout(state.serve.healthz_timeout, probe).await {
        Ok(Some(_)) => (StatusCode::OK, "OK"),
        _ => (StatusCode::INTERNAL_SERVER_ERROR, "ERROR"),
    }
}

/// Liveness-style probe: the process is up and serving HTTP, full stop --
/// no Postgres round-trip. Orchestrators use this for "should this
/// container be restarted" (a slow/unreachable Postgres shouldn't trigger
/// a restart, since restarting the process doesn't fix Postgres and
/// startup retry already handles a not-yet-ready database) while `/healthz`
/// answers "should this instance receive traffic".
async fn livez() -> impl IntoResponse {
    (StatusCode::OK, "OK")
}

/// Resolve the request's role from headers, mirroring Hasura:
/// - correct admin secret -> admin (or the role named in X-Hasura-Role)
/// - wrong admin secret -> HTTP 200 with an access-denied GraphQL error
///   (verified live — Hasura never uses 401 for this)
/// - no secret -> the unauthorized role (public)
pub fn resolve_role(
    headers: &HeaderMap,
    admin_secret: &str,
) -> Result<Role, exec::error::GraphQLError> {
    let provided = headers
        .get("x-hasura-admin-secret")
        .and_then(|v| v.to_str().ok());
    match provided {
        None => Ok(Role::Public),
        Some(s) if s == admin_secret => {
            let role_header = headers.get("x-hasura-role").and_then(|v| v.to_str().ok());
            match role_header {
                None | Some("admin") => Ok(Role::Admin),
                Some("public") => Ok(Role::Public),
                Some(_) => Ok(Role::Public),
            }
        }
        Some(_) => Err(exec::error::GraphQLError::access_denied()),
    }
}

async fn graphql_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> impl IntoResponse {
    let role = match resolve_role(&headers, &state.serve.admin_secret) {
        Ok(role) => role,
        Err(e) => {
            return (
                StatusCode::from_u16(e.status).unwrap_or(StatusCode::UNAUTHORIZED),
                [("content-type", "application/json; charset=utf-8")],
                e.response_body().to_string(),
            );
        }
    };

    let request = match decode_request_body(&body) {
        Ok(r) => r,
        Err(e) => {
            return (
                StatusCode::from_u16(e.status).unwrap_or(StatusCode::OK),
                [("content-type", "application/json; charset=utf-8")],
                e.response_body().to_string(),
            );
        }
    };

    let (status, body) =
        exec::execute_query_request(&state.serve, &state.schemas, role, &request).await;
    (
        StatusCode::from_u16(status).unwrap_or(StatusCode::OK),
        [("content-type", "application/json; charset=utf-8")],
        body,
    )
}

/// aeson's name for a JSON value's kind, as it appears in Hasura's
/// parse-failed messages.
fn aeson_kind(v: &serde_json::Value) -> &'static str {
    match v {
        serde_json::Value::Null => "Null",
        serde_json::Value::Bool(_) => "Boolean",
        serde_json::Value::Number(_) => "Number",
        serde_json::Value::String(_) => "String",
        serde_json::Value::Array(_) => "Array",
        serde_json::Value::Object(_) => "Object",
    }
}

/// Decodes the POST body with Hasura's exact error shapes: invalid UTF-8
/// and malformed JSON are `invalid-json`; structurally wrong GQLReq
/// payloads are `parse-failed` with aeson-style messages.
fn decode_request_body(body: &[u8]) -> Result<GraphQLRequest, exec::error::GraphQLError> {
    use exec::error::GraphQLError;

    let invalid_json = |message: String| GraphQLError {
        message,
        path: "$".to_string(),
        code: "invalid-json",
        status: 200,
    };
    let parse_failed = |path: &str, message: String| GraphQLError {
        message,
        path: path.to_string(),
        code: exec::error::CODE_PARSE_FAILED,
        status: 200,
    };

    let text =
        match std::str::from_utf8(body) {
            Ok(t) => t,
            Err(_) => return Err(invalid_json(
                "Cannot decode input: Data.Text.Internal.Encoding.decodeUtf8: Invalid UTF-8 stream"
                    .to_string(),
            )),
        };

    let value: serde_json::Value = match serde_json::from_str(text) {
        Ok(v) => v,
        // Lone-surrogate escapes decode to invalid UTF-8 in Hasura's
        // text pipeline; it reports them as a UTF-8 decoding failure.
        // serde_json calls the same condition "unexpected end of hex
        // escape" (no continuation escape after the lead surrogate).
        Err(e)
            if e.to_string().contains("surrogate")
                || e.to_string().contains("unexpected end of hex escape") =>
        {
            return Err(invalid_json(
                "Cannot decode input: Data.Text.Internal.Encoding.decodeUtf8: Invalid UTF-8 stream"
                    .to_string(),
            ))
        }
        Err(e) => return Err(invalid_json(e.to_string())),
    };

    let obj = match &value {
        serde_json::Value::Object(o) => o,
        other => {
            return Err(parse_failed(
                "$",
                format!(
                    "parsing Hasura.GraphQL.Transport.HTTP.Protocol.GQLReq(GQLReq) failed, expected Object, but encountered {}",
                    aeson_kind(other)
                ),
            ))
        }
    };

    let query = match obj.get("query") {
        None => {
            return Err(parse_failed(
                "$",
                "parsing Hasura.GraphQL.Transport.HTTP.Protocol.GQLReq(GQLReq) failed, key \"query\" not found"
                    .to_string(),
            ))
        }
        Some(serde_json::Value::String(s)) => s.clone(),
        Some(other) => {
            return Err(parse_failed(
                "$.query",
                format!(
                    "parsing Text failed, expected String, but encountered {}",
                    aeson_kind(other)
                ),
            ))
        }
    };

    let operation_name = match obj.get("operationName") {
        None | Some(serde_json::Value::Null) => None,
        Some(serde_json::Value::String(s)) => Some(s.clone()),
        Some(other) => {
            return Err(parse_failed(
                "$.operationName",
                format!(
                    "parsing Text failed, expected String, but encountered {}",
                    aeson_kind(other)
                ),
            ))
        }
    };

    let variables = match obj.get("variables") {
        None => None,
        Some(v @ (serde_json::Value::Object(_) | serde_json::Value::Null)) => Some(v.clone()),
        Some(other) => {
            return Err(parse_failed(
                "$.variables",
                format!(
                    "parsing HashMap failed, expected Object, but encountered {}",
                    aeson_kind(other)
                ),
            ))
        }
    };

    Ok(GraphQLRequest {
        query: Some(query),
        variables,
        operation_name,
    })
}

/// GET /v1/graphql serves the WebSocket upgrade (subscriptions).
async fn ws_or_get_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    ws: axum::extract::ws::WebSocketUpgrade,
) -> axum::response::Response {
    super::ws::handle_upgrade(state, headers, ws)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rate_limiter_allows_up_to_the_configured_rate_then_rejects() {
        let limiter = RateLimiter::new(3);
        let ip: std::net::IpAddr = "127.0.0.1".parse().unwrap();
        let allowed: Vec<bool> = (0..5).map(|_| limiter.check(ip)).collect();
        assert_eq!(allowed, vec![true, true, true, false, false]);
    }

    #[test]
    fn rate_limiter_tracks_each_ip_independently() {
        let limiter = RateLimiter::new(1);
        let a: std::net::IpAddr = "127.0.0.1".parse().unwrap();
        let b: std::net::IpAddr = "127.0.0.2".parse().unwrap();
        assert_eq!(
            (limiter.check(a), limiter.check(a), limiter.check(b)),
            (true, false, true)
        );
    }
}
