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
use std::hash::{Hash, Hasher};
use std::sync::Arc;

#[derive(Deserialize, Clone)]
pub struct GraphQLRequest {
    pub query: Option<String>,
    #[serde(default)]
    pub variables: Option<serde_json::Value>,
    #[serde(default, rename = "operationName")]
    pub operation_name: Option<String>,
    /// Trusted decoder metadata for JSON variable numbers that cannot be
    /// represented losslessly by serde_json's default number model. This is
    /// deliberately kept outside `variables` so a client cannot forge it.
    #[serde(skip)]
    pub(crate) variable_number_originals: std::collections::HashMap<u64, String>,
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

/// Identity of one ordinary live-query cohort. The response alias is not
/// part of the key: subscribers may spell the same root differently while
/// sharing the exact same database result. Role remains explicit even when
/// two role-specific plans happen to compile to the same SQL.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct LiveQueryKey {
    role: Role,
    sql: String,
    params: Vec<Option<String>>,
}

impl LiveQueryKey {
    pub fn stable_hash(&self) -> u64 {
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        self.hash(&mut hasher);
        hasher.finish()
    }
}

/// An ordinary (non-stream) table subscription compiled once before it
/// joins the server-wide polling cohort.
pub struct CompiledLiveQuery {
    pub key: LiveQueryKey,
    pub alias: String,
    compiled: sql::CompiledRoot,
}

pub fn compile_live_query(
    pg_schema: &str,
    role: Role,
    operation: &ir::Operation,
) -> Option<CompiledLiveQuery> {
    let [ir::RootField::Table(root)] = operation.root_fields.as_slice() else {
        return None;
    };
    if matches!(root.kind, ir::TableRootKind::Stream { .. }) {
        return None;
    }
    let compiled = sql::compile_root_full(pg_schema, root);
    let key = LiveQueryKey {
        role,
        sql: compiled.sql.clone(),
        params: compiled.params.clone(),
    };
    Some(CompiledLiveQuery {
        key,
        alias: root.alias.clone(),
        compiled,
    })
}

/// One poll for a precompiled ordinary live query. The timeout covers pool
/// admission, prepare, execution and result decoding just like HTTP work.
pub async fn poll_live_query(
    state: &Arc<ServeState>,
    live: &CompiledLiveQuery,
) -> Result<String, GraphQLError> {
    with_query_timeout(state, sql::execute_root_compiled(state, &live.compiled)).await
}

/// Executes `_stream` subscription polls for one subscription, compiling
/// the SQL once and re-executing it each poll with only the cursor
/// parameter values swapped in place. It recompiles only when the cursor's
/// shape changes (a column moving between unbounded / bound-at-a-value /
/// bound-at-NULL changes the predicate text), which happens at most a few
/// times over a subscription's lifetime.
#[derive(Default)]
pub struct StreamPoller {
    compiled: Option<CompiledStream>,
}

struct CompiledStream {
    /// `{"data":{"alias":` — constant across polls.
    prefix: String,
    compiled: sql::CompiledRoot,
    shape: Vec<Option<bool>>,
}

/// Per cursor column: `None` = unbounded, `Some(is_null)` = bounded at a
/// value / at NULL. Each shape compiles to different predicate text.
fn cursor_shape(root: &ir::TableRoot) -> Vec<Option<bool>> {
    match &root.kind {
        ir::TableRootKind::Stream { cursor, .. } => cursor
            .iter()
            .map(|c| c.initial_value.as_ref().map(|v| v.text.is_none()))
            .collect(),
        _ => Vec::new(),
    }
}

impl StreamPoller {
    pub fn new() -> StreamPoller {
        StreamPoller::default()
    }

    /// One subscription poll: returns the response body for a non-empty
    /// batch (advancing the cursor past its last row, NULL cursor values
    /// included), or `None` when the batch was empty. The next cursor
    /// position comes back from the same query as the batch (see
    /// `sql::execute_stream_compiled`) instead of a second poll-doubling
    /// round trip.
    pub async fn poll(
        &mut self,
        state: &Arc<ServeState>,
        operation: &mut ir::Operation,
    ) -> Result<Option<String>, GraphQLError> {
        with_query_timeout(state, self.poll_inner(state, operation)).await
    }

    async fn poll_inner(
        &mut self,
        state: &Arc<ServeState>,
        operation: &mut ir::Operation,
    ) -> Result<Option<String>, GraphQLError> {
        let Some(ir::RootField::Table(root)) = operation.root_fields.first() else {
            return Err(GraphQLError::unexpected_payload(
                "internal: stream operation missing its table root field",
            ));
        };
        if self.compiled.is_none() {
            let compiled = sql::compile_root_full(&state.model.pg_schema, root);
            let mut prefix = String::with_capacity(16 + root.alias.len());
            prefix.push_str("{\"data\":{");
            prefix.push_str(&serde_json::to_string(&root.alias).unwrap());
            prefix.push(':');
            self.compiled = Some(CompiledStream {
                prefix,
                compiled,
                shape: cursor_shape(root),
            });
        }
        let c = self.compiled.as_ref().unwrap();
        let mut out = String::with_capacity(c.prefix.len() + 258);
        out.push_str(&c.prefix);
        let cursor =
            sql::execute_stream_compiled(state, &c.compiled.sql, &c.compiled.params, &mut out)
                .await?;
        out.push_str("}}");
        let Some(values) = cursor else {
            return Ok(None);
        };

        let Some(ir::RootField::Table(root)) = operation.root_fields.first_mut() else {
            unreachable!("checked above");
        };
        if let ir::TableRootKind::Stream { cursor, .. } = &mut root.kind {
            update_stream_cursor_positions(cursor, &values);
        }
        let new_shape = cursor_shape(root);
        let c = self.compiled.as_mut().unwrap();
        if new_shape == c.shape {
            for &(ci, slot) in &c.compiled.cursor_slots {
                c.compiled.params[slot] = values[ci].clone();
            }
        } else {
            self.compiled = None;
        }
        Ok(Some(out))
    }
}

fn update_stream_cursor_positions(cursors: &mut [ir::StreamCursor], values: &[Option<String>]) {
    for (cursor, value) in cursors.iter_mut().zip(values) {
        cursor.initial_value = Some(ir::SqlValue {
            text: value.clone(),
            cast: cursor.cast.clone(),
        });
    }
}

/// Runs every root field concurrently instead of one at a time, then
/// splices their fragments back in the request's original order (each
/// fragment is computed independently, so completion order doesn't matter,
/// only the order they're written to `out` in).
///
/// A query with N table root fields can therefore hold up to N pooled
/// connections at once instead of one at a time -- the same total DB work,
/// just concurrent instead of serial. That's bounded by the existing pool
/// safety valves: `ENVIO_SERVE_POOL_MAX_SIZE` caps how many connections
/// exist at all, and `ENVIO_SERVE_POOL_WAIT_TIMEOUT_MS` turns "pool
/// exhausted" into a clean per-field error instead of an unbounded wait, so
/// a single many-root-field request can't monopolize the pool indefinitely.
async fn execute_operation_inner(
    state: &Arc<ServeState>,
    schema: &RoleSchema,
    operation: &ir::Operation,
) -> Result<String, GraphQLError> {
    let root_type_name = match operation.kind {
        ir::OperationKind::Query => "query_root",
        ir::OperationKind::Subscription => "subscription_root",
    };
    let fragments = futures_util::future::join_all(
        operation
            .root_fields
            .iter()
            .map(|root| execute_root_field(state, schema, root_type_name, root)),
    )
    .await;

    let mut out = String::with_capacity(256);
    out.push_str("{\"data\":{");
    for (i, fragment) in fragments.into_iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(&fragment?);
    }
    out.push_str("}}");
    Ok(out)
}

/// One root field's `"alias":value` fragment.
async fn execute_root_field(
    state: &Arc<ServeState>,
    schema: &RoleSchema,
    root_type_name: &str,
    root: &ir::RootField,
) -> Result<String, GraphQLError> {
    match root {
        ir::RootField::Typename { alias } => Ok(format!(
            "{}:\"{root_type_name}\"",
            serde_json::to_string(alias).unwrap()
        )),
        ir::RootField::Introspection(intro) => {
            let value_json = introspection::resolve(&schema.registry, intro)?;
            Ok(format!(
                "{}:{value_json}",
                serde_json::to_string(&intro.alias).unwrap()
            ))
        }
        ir::RootField::Table(table_root) => {
            let mut out = serde_json::to_string(&table_root.alias).unwrap();
            out.push(':');
            sql::execute_root(state, table_root, &mut out).await?;
            Ok(out)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn live_operation(alias: &str, id: &str) -> ir::Operation {
        ir::Operation {
            kind: ir::OperationKind::Subscription,
            root_fields: vec![ir::RootField::Table(ir::TableRoot {
                alias: alias.to_string(),
                table: "User".to_string(),
                kind: ir::TableRootKind::ByPk {
                    pk: vec![("id".to_string(), ir::SqlValue::new(id, "text"))],
                    selection: ir::ObjectSelection {
                        table: "User".to_string(),
                        items: Vec::new(),
                    },
                },
            })],
        }
    }

    #[test]
    fn live_query_cohort_key_uses_sql_params_and_role_but_not_alias() {
        let public_a = compile_live_query("public", Role::Public, &live_operation("a", "1"))
            .expect("ordinary table subscription");
        let public_b = compile_live_query("public", Role::Public, &live_operation("b", "1"))
            .expect("ordinary table subscription");
        let different_params =
            compile_live_query("public", Role::Public, &live_operation("a", "2"))
                .expect("ordinary table subscription");
        let different_role = compile_live_query("public", Role::Admin, &live_operation("a", "1"))
            .expect("ordinary table subscription");

        assert_eq!(public_a.key, public_b.key);
        assert_eq!(public_a.alias, "a");
        assert_eq!(public_b.alias, "b");
        assert_ne!(public_a.key, different_params.key);
        assert_ne!(public_a.key, different_role.key);
    }

    #[test]
    fn stream_cursor_advance_preserves_array_cast() {
        let mut cursors = vec![ir::StreamCursor {
            column: "tags".to_string(),
            cast: "text[]".to_string(),
            initial_value: None,
            descending: false,
        }];
        update_stream_cursor_positions(&mut cursors, &[Some("{a,b}".to_string())]);
        let advanced = cursors[0].initial_value.as_ref().unwrap();
        assert_eq!(
            (advanced.text.as_deref(), advanced.cast.as_str()),
            (Some("{a,b}"), "text[]")
        );
    }
}
