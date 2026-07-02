//! Compiles a table root field into one SQL statement and executes it,
//! returning the raw JSON text produced by Postgres so serialization is
//! byte-identical to Hasura's.

use super::error::{GResult, GraphQLError};
use super::ir;
use crate::serve::ServeState;
use std::sync::Arc;

/// Executes one table root field; returns the JSON fragment for its value
/// (e.g. `[{"id":"..."}]`, `{"aggregate":{"count":3}}`, or `null`).
pub async fn execute_root(_state: &Arc<ServeState>, _root: &ir::TableRoot) -> GResult<String> {
    Err(GraphQLError::unexpected_payload("not implemented yet"))
}
