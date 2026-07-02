//! Resolves `__schema` / `__type` selections against the registry,
//! producing JSON text that matches Hasura's introspection responses
//! byte-for-byte (field order follows the selection set; type lists are
//! ordered by type name).

use super::types::Registry;
use crate::serve::exec::error::{GResult, GraphQLError};
use crate::serve::exec::ir::IntrospectionField;

/// Returns the serialized JSON value for the introspection field.
pub fn resolve(_registry: &Registry, _field: &IntrospectionField) -> GResult<String> {
    Err(GraphQLError::unexpected_payload("not implemented yet"))
}
