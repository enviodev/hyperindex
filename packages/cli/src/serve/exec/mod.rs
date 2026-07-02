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

/// Executes an already-planned (non-subscription) operation.
pub async fn execute_operation(
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
                let piece = sql::execute_root(state, table_root).await?;
                out.push_str(&serde_json::to_string(&table_root.alias).unwrap());
                out.push(':');
                out.push_str(&piece);
            }
        }
    }
    out.push_str("}}");
    Ok(out)
}
