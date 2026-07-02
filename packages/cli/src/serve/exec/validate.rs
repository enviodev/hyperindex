//! Parses and validates a GraphQL request against the role's registry,
//! producing the execution IR. All error messages/paths must match Hasura
//! byte-for-byte (see the oracle snapshots under
//! packages/e2e-tests/fixtures/differential/snapshots/).

use super::error::{GResult, GraphQLError};
use super::ir;
use super::{GraphQLRequest, Transport};
use crate::serve::gql::schema_build::RoleSchema;
use crate::serve::model::ServerModel;

/// Parse + validate + coerce a request into the execution IR.
///
/// - `transport` gates the admissible operation types: subscriptions over
///   HTTP fail with `unexpected-payload` before selection validation.
/// - The role's response limit (public role) is applied here by clamping
///   the effective SQL limit of every table select.
pub fn plan_request(
    _model: &ServerModel,
    _schema: &RoleSchema,
    _request: &GraphQLRequest,
    _transport: Transport,
) -> GResult<ir::Operation> {
    Err(GraphQLError::unexpected_payload("not implemented yet"))
}
