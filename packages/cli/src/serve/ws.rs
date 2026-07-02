//! GraphQL-over-WebSocket subscriptions, supporting both protocols Hasura
//! serves on /v1/graphql:
//! - `graphql-transport-ws` (the modern graphql-ws protocol)
//! - `graphql-ws` (the legacy subscriptions-transport-ws protocol)
//!
//! Live queries are implemented the way Hasura's multiplexed live queries
//! behave observably: an immediate first result, then a ~1s poll loop that
//! pushes a new payload whenever the result changes.

use super::http::AppState;
use axum::http::HeaderMap;
use axum::response::IntoResponse;

pub fn handle_upgrade(
    _state: AppState,
    _headers: HeaderMap,
    upgrade: axum::extract::ws::WebSocketUpgrade,
) -> axum::response::Response {
    // Placeholder: accept and immediately close until implemented.
    upgrade
        .protocols(["graphql-transport-ws", "graphql-ws"])
        .on_upgrade(|_socket| async {})
        .into_response()
}
