//! HTTP server: POST /v1/graphql (+ health endpoints and the WebSocket
//! upgrade for subscriptions).

use super::exec::{self, GraphQLRequest, Schemas};
use super::gql::schema_build::Role;
use super::ServeState;
use axum::body::Bytes;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::Router;
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub serve: Arc<ServeState>,
    pub schemas: Arc<Schemas>,
}

pub async fn serve(state: Arc<ServeState>, host: &str, port: u16) -> anyhow::Result<()> {
    let schemas = Arc::new(Schemas::build(&state.model));
    let app_state = AppState {
        serve: state,
        schemas,
    };

    let app = Router::new()
        .route("/v1/graphql", post(graphql_handler).get(ws_or_get_handler))
        .route("/healthz", get(healthz))
        .route("/hasura/healthz", get(healthz))
        .with_state(app_state);

    let addr = format!("{host}:{port}");
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    println!("envio serve: GraphQL API at http://{addr}/v1/graphql");
    axum::serve(listener, app).await?;
    Ok(())
}

async fn healthz() -> impl IntoResponse {
    (StatusCode::OK, "OK")
}

/// Resolve the request's role from headers, mirroring Hasura:
/// - correct admin secret -> admin (or the role named in X-Hasura-Role)
/// - wrong admin secret -> 401 access-denied
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
