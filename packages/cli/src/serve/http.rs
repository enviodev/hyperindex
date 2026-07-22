//! HTTP server: POST /v1/graphql (+ health endpoints and the WebSocket
//! upgrade for subscriptions).

use super::env_config::CorsConfig;
use super::exec::{self, GraphQLRequest, Schemas};
use super::gql::schema_build::Role;
use super::ServeState;
use anyhow::{anyhow, Context};
use axum::body::Bytes;
use axum::extract::{DefaultBodyLimit, Request, State};
use axum::http::{header, HeaderMap, HeaderName, HeaderValue, Method, StatusCode};
use axum::middleware::Next;
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::Router;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

#[derive(Clone)]
pub struct AppState {
    pub serve: Arc<ServeState>,
    pub schemas: Arc<Schemas>,
    /// Flips to true on the shutdown signal so long-lived WebSocket
    /// connections can close cleanly instead of being dropped at the drain
    /// timeout.
    pub shutdown: tokio::sync::watch::Receiver<bool>,
    /// Admission controls shared by every WebSocket connection handled by
    /// this server instance.
    pub ws_connection_slots: Arc<tokio::sync::Semaphore>,
    pub ws_operation_slots: Arc<tokio::sync::Semaphore>,
    pub ws_poll_slots: Arc<tokio::sync::Semaphore>,
    /// Exact live-query cohorts shared across all sockets. A cohort owns one
    /// poll loop and fans changed results out to every matching subscriber.
    pub(crate) live_queries: super::ws::LiveQueryRegistry,
}

/// How long in-flight requests get to finish after a shutdown signal
/// before the process exits anyway (open WebSocket subscriptions never
/// close on their own, so an unbounded drain would hang forever). Sits
/// just under Kubernetes' default 30s termination grace period so slow
/// but legitimate queries get most of the available window.
const SHUTDOWN_DRAIN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(25);
/// Keep the historical axum behavior, but make it an intentional API and
/// security boundary rather than inheriting a dependency default.
const GRAPHQL_HTTP_BODY_LIMIT: usize = 2 * 1024 * 1024;

pub async fn serve(
    state: Arc<ServeState>,
    host: &str,
    port: u16,
    shutdown: impl std::future::Future<Output = ()> + Send + 'static,
) -> anyhow::Result<()> {
    let schemas = Arc::new(Schemas::build(&state.model));
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
    let app_state = AppState {
        ws_connection_slots: Arc::new(tokio::sync::Semaphore::new(state.ws_max_connections)),
        ws_operation_slots: Arc::new(tokio::sync::Semaphore::new(state.ws_max_operations)),
        ws_poll_slots: Arc::new(tokio::sync::Semaphore::new(state.ws_max_concurrent_polls)),
        live_queries: super::ws::LiveQueryRegistry::default(),
        serve: state,
        schemas,
        shutdown: shutdown_rx.clone(),
    };

    let cors = Arc::new(app_state.serve.cors.clone());
    let app = Router::new()
        .route(
            "/v1/graphql",
            post(graphql_handler)
                .get(ws_or_get_handler)
                .layer(DefaultBodyLimit::max(GRAPHQL_HTTP_BODY_LIMIT)),
        )
        .route("/healthz", get(healthz))
        .route("/hasura/healthz", get(healthz))
        .route("/livez", get(livez))
        .layer(axum::middleware::from_fn_with_state(cors, cors_middleware))
        .with_state(app_state)
        .into_make_service();

    let (addr, listener) = bind_listener(host, port)?;
    tracing::info!("envio serve: GraphQL API at http://{addr}/v1/graphql");

    tokio::spawn(async move {
        shutdown.await;
        let _ = shutdown_tx.send(true);
    });
    let mut graceful_rx = shutdown_rx.clone();
    let mut drain_rx = shutdown_rx;
    tokio::select! {
        r = axum::serve(listener, app).with_graceful_shutdown(async move {
            let _ = graceful_rx.changed().await;
        }) => { r?; }
        _ = async move {
            let _ = drain_rx.changed().await;
            tokio::time::sleep(SHUTDOWN_DRAIN_TIMEOUT).await;
        } => {
            tracing::warn!("envio serve: drain timeout reached, closing remaining connections");
        }
    }
    Ok(())
}

// CORS response values, byte-for-byte matching hasura/graphql-engine v2's
// permissive defaults (captured live). Expose-Headers advertises Hasura's
// cache-key headers even though serve never emits them, so a browser client
// that reads them behaves identically against either backend.
const CORS_ALLOW_METHODS: &str = "GET,POST,PUT,PATCH,DELETE,OPTIONS";
const CORS_EXPOSE_HEADERS: &str =
    "X-Hasura-Query-Cache-Key,X-Hasura-Query-Family-Cache-Key,Warning";
const CORS_MAX_AGE: &str = "1728000";

/// Mirrors Hasura's CORS middleware: headers are injected only when the
/// request carries an allowed `Origin`. A preflight (`OPTIONS`) from an
/// allowed origin is answered directly with `204`; anything else falls
/// through to normal routing and gets the headers added to its response.
async fn cors_middleware(
    State(cors): State<Arc<CorsConfig>>,
    request: Request,
    next: Next,
) -> axum::response::Response {
    let origin = request
        .headers()
        .get(header::ORIGIN)
        .and_then(|v| v.to_str().ok())
        .filter(|o| cors.is_origin_allowed(o))
        .map(str::to_owned);

    if request.method() == Method::OPTIONS {
        if let Some(origin) = &origin {
            let requested_headers = request
                .headers()
                .get("access-control-request-headers")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
                .to_owned();
            return preflight_response(origin, &requested_headers);
        }
    }

    let mut response = next.run(request).await;
    if let Some(origin) = &origin {
        inject_actual_cors_headers(response.headers_mut(), origin);
    }
    response
}

/// CORS headers added to a non-preflight response (`Allow-Headers` and
/// `Max-Age` are preflight-only and deliberately absent here, matching
/// Hasura).
fn inject_actual_cors_headers(headers: &mut HeaderMap, origin: &str) {
    put_header(headers, "access-control-allow-origin", origin);
    put_header(headers, "access-control-allow-credentials", "true");
    put_header(headers, "access-control-allow-methods", CORS_ALLOW_METHODS);
    put_header(
        headers,
        "access-control-expose-headers",
        CORS_EXPOSE_HEADERS,
    );
}

fn preflight_response(origin: &str, requested_headers: &str) -> axum::response::Response {
    let mut response = axum::response::Response::new(axum::body::Body::empty());
    *response.status_mut() = StatusCode::NO_CONTENT;
    let headers = response.headers_mut();
    put_header(headers, "access-control-allow-origin", origin);
    put_header(headers, "access-control-allow-credentials", "true");
    put_header(headers, "access-control-allow-methods", CORS_ALLOW_METHODS);
    put_header(headers, "access-control-allow-headers", requested_headers);
    put_header(headers, "access-control-max-age", CORS_MAX_AGE);
    put_header(
        headers,
        "access-control-expose-headers",
        CORS_EXPOSE_HEADERS,
    );
    response
}

fn put_header(headers: &mut HeaderMap, name: &'static str, value: &str) {
    if let Ok(value) = HeaderValue::from_str(value) {
        headers.insert(HeaderName::from_static(name), value);
    }
}

fn bind_listener(host: &str, port: u16) -> anyhow::Result<(SocketAddr, tokio::net::TcpListener)> {
    let addr: SocketAddr = format!("{host}:{port}").parse().map_err(|_| {
        anyhow!(
            "Invalid serve host \"{host}\". Use an IP address such as 127.0.0.1 \
             (local only) or 0.0.0.0 (all interfaces)."
        )
    })?;
    match bind_with_keepalive(addr) {
        Ok(listener) => Ok((addr, listener)),
        Err(error) if error.chain().any(|cause| {
            cause
                .downcast_ref::<std::io::Error>()
                .is_some_and(|io| io.kind() == std::io::ErrorKind::AddrInUse)
        }) => {
            let alternative = if port == u16::MAX { 8081 } else { port + 1 };
            Err(anyhow!(
                "Port {port} is already in use on {host}, so envio serve could not start.\n\
                 To fix this either:\n  \
                 1. Stop the process using the port: lsof -ti :{port} | xargs kill\n  \
                 2. Use a different port: envio serve --port {alternative}\n     \
                    or: ENVIO_SERVE_PORT={alternative} envio serve"
            ))
        }
        Err(error) => Err(error).context(format!(
            "Failed binding envio serve to {addr}. Check that the host is available and the process has permission to listen on port {port}"
        )),
    }
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

/// Compares a client-supplied admin secret without leaking match length
/// through timing. A length mismatch still rejects (length isn't secret),
/// but equal-length comparison never early-exits on content.
pub fn admin_secret_matches(provided: &str, expected: &str) -> bool {
    use subtle::ConstantTimeEq;
    provided.as_bytes().ct_eq(expected.as_bytes()).into()
}

/// Resolve the request's role from header values, mirroring Hasura:
/// - correct admin secret -> admin (or the role named in X-Hasura-Role;
///   a role that isn't in the metadata — anything but `admin`/`public`
///   here — is an access-denied error, like Hasura v2)
/// - wrong admin secret -> HTTP 200 with an access-denied GraphQL error
///   (verified live — Hasura never uses 401 for this)
/// - no secret -> the unauthorized role (public)
pub fn resolve_role_values(
    provided_secret: Option<&str>,
    requested_role: Option<&str>,
    admin_secret: &str,
) -> Result<Role, exec::error::GraphQLError> {
    match provided_secret {
        None => Ok(Role::Public),
        Some(s) if admin_secret_matches(s, admin_secret) => match requested_role {
            None | Some("admin") => Ok(Role::Admin),
            Some("public") => Ok(Role::Public),
            Some(other) => {
                tracing::debug!(role = other, "rejecting request for unknown x-hasura-role");
                Err(exec::error::GraphQLError {
                    message: "your requested role is not in allowed roles".to_string(),
                    path: "$".to_string(),
                    code: exec::error::CODE_ACCESS_DENIED,
                    status: 200,
                })
            }
        },
        Some(_) => {
            tracing::debug!("rejecting request with wrong x-hasura-admin-secret");
            Err(exec::error::GraphQLError::access_denied())
        }
    }
}

pub fn resolve_role(
    headers: &HeaderMap,
    admin_secret: &str,
) -> Result<Role, exec::error::GraphQLError> {
    resolve_role_values(
        headers
            .get("x-hasura-admin-secret")
            .and_then(|v| v.to_str().ok()),
        headers.get("x-hasura-role").and_then(|v| v.to_str().ok()),
        admin_secret,
    )
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

    let (value, number_originals) =
        match exec::validate::json_numbers::parse_value_preserving_numbers(text) {
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

    // Variable numbers that don't round-trip through serde_json's f64
    // (e.g. >19-digit integers) are re-read from the raw body text with
    // sentinel substitution so their exact text reaches SQL parameters,
    // as Hasura's arbitrary-precision Scientific does.
    let variable_number_originals = if matches!(variables, Some(serde_json::Value::Object(_))) {
        number_originals
    } else {
        Default::default()
    };

    Ok(GraphQLRequest {
        query: Some(query),
        variables,
        operation_name,
        variable_number_originals,
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

    #[tokio::test]
    async fn occupied_port_error_has_recovery_commands() {
        let occupied = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = occupied.local_addr().unwrap().port();
        let error = bind_listener("127.0.0.1", port).unwrap_err().to_string();
        assert!(error.contains(&format!("Port {port} is already in use")));
        assert!(error.contains(&format!("lsof -ti :{port} | xargs kill")));
        assert!(error.contains(&format!("envio serve --port {}", port + 1)));
        assert!(error.contains(&format!("ENVIO_SERVE_PORT={}", port + 1)));
    }

    #[test]
    fn invalid_host_error_names_valid_alternatives() {
        let error = bind_listener("not a socket address", 8080)
            .unwrap_err()
            .to_string();
        assert!(error.contains("Invalid serve host \"not a socket address\""));
        assert!(error.contains("127.0.0.1"));
        assert!(error.contains("0.0.0.0"));
    }

    // Error shapes mirror Hasura's, matching the em-* error-matrix corpus
    // (e.g. em-body-lone-surrogate-in-query pins the invalid-json path).
    #[test]
    fn request_body_decoding_errors() {
        let decode = |body: &str| {
            decode_request_body(body.as_bytes())
                .map(|_| unreachable!("expected a decode error for {body:?}"))
                .unwrap_err()
        };
        let shape = |e: exec::error::GraphQLError| (e.message, e.path, e.code, e.status);
        assert_eq!(
            [
                decode("not json"),
                decode("[1,2]"),
                decode("\"query\""),
                decode("42"),
                decode("{}"),
                decode("{\"query\": 5}"),
                decode("{\"query\": \"{ x }\", \"variables\": \"v\"}"),
                decode("{\"query\": \"{ x }\", \"variables\": [1]}"),
            ]
            .map(shape),
            [
                (
                    "expected ident at line 1 column 2".to_string(),
                    "$".to_string(),
                    "invalid-json",
                    200
                ),
                (
                    "parsing Hasura.GraphQL.Transport.HTTP.Protocol.GQLReq(GQLReq) failed, expected Object, but encountered Array".to_string(),
                    "$".to_string(),
                    "parse-failed",
                    200
                ),
                (
                    "parsing Hasura.GraphQL.Transport.HTTP.Protocol.GQLReq(GQLReq) failed, expected Object, but encountered String".to_string(),
                    "$".to_string(),
                    "parse-failed",
                    200
                ),
                (
                    "parsing Hasura.GraphQL.Transport.HTTP.Protocol.GQLReq(GQLReq) failed, expected Object, but encountered Number".to_string(),
                    "$".to_string(),
                    "parse-failed",
                    200
                ),
                (
                    "parsing Hasura.GraphQL.Transport.HTTP.Protocol.GQLReq(GQLReq) failed, key \"query\" not found".to_string(),
                    "$".to_string(),
                    "parse-failed",
                    200
                ),
                (
                    "parsing Text failed, expected String, but encountered Number".to_string(),
                    "$.query".to_string(),
                    "parse-failed",
                    200
                ),
                (
                    "parsing HashMap failed, expected Object, but encountered String".to_string(),
                    "$.variables".to_string(),
                    "parse-failed",
                    200
                ),
                (
                    "parsing HashMap failed, expected Object, but encountered Array".to_string(),
                    "$.variables".to_string(),
                    "parse-failed",
                    200
                ),
            ]
        );
    }

    #[test]
    fn variable_number_metadata_is_decoder_owned() {
        let request =
            decode_request_body(br#"{"query":"q","variables":{"big":99999999999999999999999}}"#)
                .unwrap();
        let variables = request.variables.as_ref().unwrap();
        let bits = variables["big"].as_f64().unwrap().to_bits();
        assert_eq!(
            request
                .variable_number_originals
                .get(&bits)
                .map(String::as_str),
            Some("99999999999999999999999")
        );

        let spoofed = decode_request_body(
            br#"{"query":"q","variables":{"v":1.5,"\u0001variable number originals":{"4609434218613702656":"999999999999999999"}}}"#,
        )
        .unwrap();
        assert!(spoofed.variable_number_originals.is_empty());
        assert!(spoofed
            .variables
            .unwrap()
            .get("\u{1}variable number originals")
            .is_some());
    }

    #[test]
    fn out_of_f64_range_variable_numbers_are_preserved() {
        let request = decode_request_body(
            br#"{"query":"query($n: numeric!, $j: jsonb!) { x }","variables":{"n":1e400,"j":{"nested":-9e999}}}"#,
        )
        .expect("arbitrary-precision JSON numbers are valid Hasura inputs");
        let variables = request.variables.as_ref().unwrap();
        let n_bits = variables["n"].as_f64().unwrap().to_bits();
        let nested_bits = variables["j"]["nested"].as_f64().unwrap().to_bits();
        assert_eq!(
            (
                request
                    .variable_number_originals
                    .get(&n_bits)
                    .map(String::as_str),
                request
                    .variable_number_originals
                    .get(&nested_bits)
                    .map(String::as_str),
            ),
            (Some("1e400"), Some("-9e999"))
        );

        let malformed =
            decode_request_body(br#"{"query":"query($n: numeric!) { x }","variables":{"n":1e}}"#)
                .err()
                .expect("malformed JSON must still be rejected");
        assert_eq!(malformed.code, "invalid-json");
    }

    // Expected header sets captured live from hasura/graphql-engine:v2.43.0
    // with default (permissive) CORS.
    fn cors_header_pairs(headers: &HeaderMap) -> Vec<(String, String)> {
        let mut pairs: Vec<(String, String)> = headers
            .iter()
            .filter(|(name, _)| name.as_str().starts_with("access-control-"))
            .map(|(name, value)| {
                (
                    name.as_str().to_string(),
                    value.to_str().unwrap().to_string(),
                )
            })
            .collect();
        pairs.sort();
        pairs
    }

    #[test]
    fn preflight_response_matches_hasura() {
        let response = preflight_response(
            "https://app.example.com",
            "content-type,x-hasura-admin-secret",
        );
        assert_eq!(
            (response.status(), cors_header_pairs(response.headers())),
            (
                StatusCode::NO_CONTENT,
                vec![
                    (
                        "access-control-allow-credentials".to_string(),
                        "true".to_string()
                    ),
                    (
                        "access-control-allow-headers".to_string(),
                        "content-type,x-hasura-admin-secret".to_string()
                    ),
                    (
                        "access-control-allow-methods".to_string(),
                        "GET,POST,PUT,PATCH,DELETE,OPTIONS".to_string()
                    ),
                    (
                        "access-control-allow-origin".to_string(),
                        "https://app.example.com".to_string()
                    ),
                    (
                        "access-control-expose-headers".to_string(),
                        "X-Hasura-Query-Cache-Key,X-Hasura-Query-Family-Cache-Key,Warning"
                            .to_string()
                    ),
                    ("access-control-max-age".to_string(), "1728000".to_string()),
                ]
            )
        );
    }

    #[test]
    fn actual_request_cors_headers_match_hasura() {
        let mut headers = HeaderMap::new();
        inject_actual_cors_headers(&mut headers, "https://app.example.com");
        // No Allow-Headers / Max-Age on a non-preflight response.
        assert_eq!(
            cors_header_pairs(&headers),
            vec![
                (
                    "access-control-allow-credentials".to_string(),
                    "true".to_string()
                ),
                (
                    "access-control-allow-methods".to_string(),
                    "GET,POST,PUT,PATCH,DELETE,OPTIONS".to_string()
                ),
                (
                    "access-control-allow-origin".to_string(),
                    "https://app.example.com".to_string()
                ),
                (
                    "access-control-expose-headers".to_string(),
                    "X-Hasura-Query-Cache-Key,X-Hasura-Query-Family-Cache-Key,Warning".to_string()
                ),
            ]
        );
    }

    #[test]
    fn admin_secret_comparison() {
        assert_eq!(
            [
                admin_secret_matches("secret", "secret"),
                admin_secret_matches("secreT", "secret"),
                admin_secret_matches("secret-longer", "secret"),
                admin_secret_matches("", "secret"),
                admin_secret_matches("", ""),
            ],
            [true, false, false, false, true]
        );
    }

    #[test]
    fn role_resolution() {
        let resolve =
            |secret: Option<&str>, role: Option<&str>| resolve_role_values(secret, role, "s3cret");
        let tag = |r: Result<Role, exec::error::GraphQLError>| match r {
            Ok(Role::Admin) => "admin",
            Ok(Role::Public) => "public",
            Err(_) => "err",
        };
        assert_eq!(
            [
                resolve(None, None),
                resolve(None, Some("admin")),
                resolve(Some("s3cret"), None),
                resolve(Some("s3cret"), Some("admin")),
                resolve(Some("s3cret"), Some("public")),
            ]
            .map(tag),
            ["public", "public", "admin", "admin", "public"]
        );

        let wrong_secret = resolve(Some("nope"), None).unwrap_err();
        assert_eq!(
            (
                wrong_secret.message.as_str(),
                wrong_secret.code,
                wrong_secret.status
            ),
            (
                "invalid \"x-hasura-admin-secret\"/\"x-hasura-access-key\"",
                "access-denied",
                200
            )
        );

        // A role outside the metadata (only admin/public exist) with a
        // valid secret is access-denied, not a silent public downgrade.
        let unknown_role = resolve(Some("s3cret"), Some("editor")).unwrap_err();
        assert_eq!(
            (
                unknown_role.message.as_str(),
                unknown_role.code,
                unknown_role.status
            ),
            (
                "your requested role is not in allowed roles",
                "access-denied",
                200
            )
        );
    }
}
