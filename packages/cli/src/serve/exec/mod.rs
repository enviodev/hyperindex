//! Request execution pipeline: parse → validate/plan → execute → respond.

pub mod error;
pub mod ir;
pub mod sql;
pub mod validate;

use crate::serve::gql::schema_build::{Role, RoleSchema};
use crate::serve::gql::{introspection, schema_build};
use crate::serve::ServeState;
use error::GraphQLError;
use serde::Deserialize;
use std::sync::Arc;

#[derive(Deserialize, Clone)]
pub struct GraphQLRequest {
    pub query: Option<String>,
    #[serde(default)]
    pub variables: Option<serde_json::Value>,
    #[serde(default, rename = "operationName")]
    pub operation_name: Option<String>,
}

/// Where the request came from — determines which operation types are
/// admissible (Hasura rejects subscriptions over HTTP before validating
/// their selection sets).
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Transport {
    Http,
    Ws,
}

pub struct Schemas {
    pub admin: RoleSchema,
    pub public: RoleSchema,
}

impl Schemas {
    pub fn build(model: &crate::serve::model::ServerModel) -> Schemas {
        Schemas {
            admin: RoleSchema {
                registry: schema_build::build(model, Role::Admin),
                role: Role::Admin,
            },
            public: RoleSchema {
                registry: schema_build::build(model, Role::Public),
                role: Role::Public,
            },
        }
    }

    pub fn for_role(&self, role: Role) -> &RoleSchema {
        match role {
            Role::Admin => &self.admin,
            Role::Public => &self.public,
        }
    }
}

/// Executes one GraphQL request over HTTP semantics. Returns (status,
/// response JSON as a string). The response is assembled by string
/// splicing so values produced by Postgres keep their exact serialization.
pub async fn execute_query_request(
    state: &Arc<ServeState>,
    schemas: &Schemas,
    role: Role,
    request: &GraphQLRequest,
) -> (u16, String) {
    match execute_inner(state, schemas, role, request).await {
        Ok(body) => (200, body),
        Err(e) => (e.status, e.response_body().to_string()),
    }
}

async fn execute_inner(
    state: &Arc<ServeState>,
    schemas: &Schemas,
    role: Role,
    request: &GraphQLRequest,
) -> Result<String, GraphQLError> {
    let schema = schemas.for_role(role);
    let operation = validate::plan_request(&state.model, schema, request, Transport::Http)?;
    execute_operation(state, schema, &operation).await
}

/// Bounds `fut` by the whole-operation client-side query timeout, if one is
/// configured. Shared by every operation entry point so the timeout always
/// covers the whole operation — every root field's pool wait + prepare +
/// query — rather than each one individually, which would let an operation
/// with N root fields hang for N budgets.
async fn with_query_timeout<T>(
    state: &Arc<ServeState>,
    fut: impl std::future::Future<Output = Result<T, GraphQLError>>,
) -> Result<T, GraphQLError> {
    match state.query_timeout {
        None => fut.await,
        Some(limit) => tokio::time::timeout(limit, fut)
            .await
            .unwrap_or_else(|_| Err(GraphQLError::query_timeout())),
    }
}

/// Executes an already-planned (non-subscription) operation.
pub async fn execute_operation(
    state: &Arc<ServeState>,
    schema: &RoleSchema,
    operation: &ir::Operation,
) -> Result<String, GraphQLError> {
    with_query_timeout(state, execute_operation_inner(state, schema, operation)).await
}

/// Executes an already-planned `_stream` subscription poll: like
/// `execute_operation`, but via `sql::execute_stream_root` so the next
/// cursor position comes back from the same query as the batch instead of
/// a second poll-doubling round trip. Returns the response body plus the
/// new cursor values (`None` when the batch was empty, so the cursor
/// should stay put).
pub async fn execute_stream_operation(
    state: &Arc<ServeState>,
    operation: &ir::Operation,
) -> Result<(String, Option<Vec<String>>), GraphQLError> {
    with_query_timeout(state, execute_stream_operation_inner(state, operation)).await
}

async fn execute_stream_operation_inner(
    state: &Arc<ServeState>,
    operation: &ir::Operation,
) -> Result<(String, Option<Vec<String>>), GraphQLError> {
    let Some(ir::RootField::Table(table_root)) = operation.root_fields.first() else {
        return Err(GraphQLError::unexpected_payload(
            "internal: stream operation missing its table root field",
        ));
    };
    let mut out = String::with_capacity(256);
    out.push_str("{\"data\":{");
    out.push_str(&serde_json::to_string(&table_root.alias).unwrap());
    out.push(':');
    let cursor = sql::execute_stream_root(state, table_root, &mut out).await?;
    out.push_str("}}");
    Ok((out, cursor))
}

async fn execute_operation_inner(
    state: &Arc<ServeState>,
    schema: &RoleSchema,
    operation: &ir::Operation,
) -> Result<String, GraphQLError> {
    let root_type_name = match operation.kind {
        ir::OperationKind::Query => "query_root",
        ir::OperationKind::Subscription => "subscription_root",
    };
    let mut out = String::with_capacity(256);
    out.push_str("{\"data\":{");
    let mut first = true;
    for root in &operation.root_fields {
        if !first {
            out.push(',');
        }
        first = false;
        match root {
            ir::RootField::Typename { alias } => {
                out.push_str(&serde_json::to_string(alias).unwrap());
                out.push_str(":\"");
                out.push_str(root_type_name);
                out.push('"');
            }
            ir::RootField::Introspection(intro) => {
                let value_json = introspection::resolve(&schema.registry, intro)?;
                out.push_str(&serde_json::to_string(&intro.alias).unwrap());
                out.push(':');
                out.push_str(&value_json);
            }
            ir::RootField::Table(table_root) => {
                out.push_str(&serde_json::to_string(&table_root.alias).unwrap());
                out.push(':');
                sql::execute_root(state, table_root, &mut out).await?;
            }
        }
    }
    out.push_str("}}");
    Ok(out)
}
