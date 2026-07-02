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

    let request: GraphQLRequest = match serde_json::from_slice(&body) {
        Ok(r) => r,
        Err(_) => {
            let e = exec::error::GraphQLError {
                message: "Error in $: Failed reading: not a valid json value".to_string(),
                path: "$".to_string(),
                code: exec::error::CODE_BAD_REQUEST,
                status: 400,
            };
            return (
                StatusCode::BAD_REQUEST,
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

/// GET /v1/graphql serves the WebSocket upgrade (subscriptions).
async fn ws_or_get_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    ws: axum::extract::ws::WebSocketUpgrade,
) -> axum::response::Response {
    super::ws::handle_upgrade(state, headers, ws)
}
