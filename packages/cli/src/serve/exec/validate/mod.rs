//! Parses and validates a GraphQL request against the role's registry,
//! producing the execution IR. All error messages/paths must match Hasura
//! byte-for-byte (see the oracle snapshots under
//! packages/e2e-tests/fixtures/differential/snapshots/).

use super::error::{GResult, GraphQLError, CODE_PARSE_FAILED, CODE_VALIDATION_FAILED};
use super::ir;
use super::{GraphQLRequest, Transport};
use crate::serve::gql::schema_build::{Role, RoleSchema};
use crate::serve::gql::types::{FieldDef, FieldKind, Registry, TypeDef, TypeRef};
use crate::serve::model::{Column, Scalar, ServerModel, Table};
use graphql_parser::query as q;
use serde_json::Value as Json;
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};

mod args;
mod bool_exp;
mod coerce;
mod fragments;
pub mod json_numbers;
mod prescan;
mod selection;
mod variables;

use args::{
    api_to_db_column, coerce_by_pk_args, coerce_json_path_arg, coerce_select_args,
    coerce_stream_args, expect_list, resolve_arg,
};
use coerce::{coerce_bool_strict, coerce_enum, coerce_string_strict};
use fragments::fragment_prepass;
use prescan::prescan;
use selection::{collect_fields, Flat};
use variables::{
    atype_display, atype_is_non_null, build_variables, variable_prepass, VarInfo, VarValue,
};

type AValue = q::Value<'static, String>;
type AType = q::Type<'static, String>;
type ASelSet = q::SelectionSet<'static, String>;
type ADirective = q::Directive<'static, String>;
type AVarDef = q::VariableDefinition<'static, String>;
type AFragment = q::FragmentDefinition<'static, String>;

static NULL_LIT: AValue = q::Value::Null;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

fn verr(path: impl Into<String>, message: impl Into<String>) -> GraphQLError {
    GraphQLError::validation(path, message)
}

fn perr(path: impl Into<String>, message: impl Into<String>) -> GraphQLError {
    GraphQLError {
        message: message.into(),
        path: path.into(),
        code: CODE_PARSE_FAILED,
        status: 200,
    }
}

/// Divergence from Hasura (which has no depth limit): nesting beyond this
/// would overflow the stack in graphql_parser and the recursive walkers.
const MAX_DEPTH: usize = 100;

fn depth_error() -> GraphQLError {
    verr(
        "$.query",
        format!("the query exceeds the maximum allowed nesting depth of {MAX_DEPTH}"),
    )
}

/// Hasura reports syntax errors as validation-failed at `$.query`.
fn invalid_query() -> GraphQLError {
    GraphQLError {
        message: "not a valid graphql query".to_string(),
        path: "$.query".to_string(),
        code: CODE_VALIDATION_FAILED,
        status: 200,
    }
}

fn int_bounds_error(path: &str, display: &str) -> GraphQLError {
    perr(
        path,
        format!(
            "The value {display} lies outside the bounds or is not an integer. Maybe it is a float, or is there integer overflow?"
        ),
    )
}

fn float_bounds_error(path: &str, display: &str) -> GraphQLError {
    perr(
        path,
        format!("The value {display} lies outside the bounds. Is it overflowing the float bounds?"),
    )
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Parse + validate + coerce a request into the execution IR.
///
/// - `transport` gates the admissible operation types: subscriptions over
///   HTTP fail with `unexpected-payload`, but only after full validation
///   (Hasura validates the selection set first).
/// - The role's response limit (public role) is applied here by clamping
///   the effective SQL limit of table selects.
pub fn plan_request(
    model: &ServerModel,
    schema: &RoleSchema,
    request: &GraphQLRequest,
    transport: Transport,
) -> GResult<ir::Operation> {
    let query_text = request.query.as_deref().unwrap_or("");
    let scan = prescan(query_text)?;
    let doc = match q::parse_query::<String>(&scan.rewritten) {
        Ok(doc) => doc.into_static(),
        Err(_) => return Err(invalid_query()),
    };
    if doc.definitions.is_empty() {
        return Err(invalid_query());
    }

    let mut operations: Vec<OpParts> = Vec::new();
    let mut fragment_defs: Vec<&AFragment> = Vec::new();
    for def in &doc.definitions {
        match def {
            q::Definition::Operation(op) => operations.push(OpParts::from_ast(op)),
            q::Definition::Fragment(f) => fragment_defs.push(f),
        }
    }

    let op = select_operation(&operations, request.operation_name.as_deref())?;
    check_operation_directives(op.kind, op.directives)?;

    // Hasura throws this before fragment/variable validation: the public
    // role has no mutation parser at all.
    if op.kind == OpKind::Mutation && schema.role == Role::Public {
        return Err(verr("$", "no mutations exist"));
    }

    let mut fragments: HashMap<&str, &AFragment> = HashMap::new();
    for f in &fragment_defs {
        if fragments.insert(f.name.as_str(), f).is_some() {
            return Err(perr(
                "$",
                format!("multiple definitions for fragment \"{}\"", f.name),
            ));
        }
    }

    let variables_json = match &request.variables {
        Some(Json::Object(m)) => Some(m),
        _ => None,
    };

    let ctx = Ctx {
        model,
        registry: &schema.registry,
        response_limit: if schema.role == Role::Public {
            model.response_limit.map(|n| n as i64)
        } else {
            None
        },
        fragments,
        vars: build_variables(op.var_defs, variables_json)?,
        used_vars: RefCell::new(HashSet::new()),
        int_originals: scan.int_originals,
        inf_float_originals: scan.inf_float_originals,
        var_number_originals: variables_json
            .map(json_numbers::extract_originals)
            .unwrap_or_default(),
    };

    // Fragment reachability (undefined spreads, cycles) is checked before
    // variables, which are checked before any schema validation — matching
    // Hasura's inline -> resolveVariables -> parse pipeline.
    let expanded_depth = fragment_prepass(
        &ctx,
        op.selection_set,
        "$.selectionSet",
        &mut Vec::new(),
        &mut HashMap::new(),
        0,
    )?;
    if expanded_depth > MAX_DEPTH {
        return Err(depth_error());
    }
    variable_prepass(&ctx, op.selection_set)?;
    if let Some(vars) = variables_json {
        let used = ctx.used_vars.borrow();
        let unexpected: Vec<&str> = vars
            .keys()
            .filter(|k| k.as_str() != json_numbers::NUMBER_ORIGINALS_KEY)
            .filter(|k| !used.contains(k.as_str()))
            .map(|k| k.as_str())
            .collect();
        if !unexpected.is_empty() {
            return Err(verr(
                "$",
                format!(
                    "unexpected variables in variableValues: {}",
                    unexpected.join(", ")
                ),
            ));
        }
    }

    let kind = match op.kind {
        OpKind::Query => ir::OperationKind::Query,
        OpKind::Subscription => ir::OperationKind::Subscription,
        OpKind::Mutation => return plan_admin_mutation(&ctx, op.selection_set),
    };
    let root_fields = plan_roots(&ctx, kind, op.selection_set)?;

    if kind == ir::OperationKind::Subscription {
        if root_fields.len() != 1 {
            return Err(verr("$", "subscriptions must select one top level field"));
        }
        if transport == Transport::Http {
            return Err(GraphQLError::unexpected_payload(
                "subscriptions are not supported over HTTP, use websockets instead",
            ));
        }
    }

    Ok(ir::Operation { kind, root_fields })
}

// ---------------------------------------------------------------------------
// Operation selection
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq)]
enum OpKind {
    Query,
    Mutation,
    Subscription,
}

struct OpParts<'a> {
    kind: OpKind,
    name: Option<&'a str>,
    var_defs: &'a [AVarDef],
    directives: &'a [ADirective],
    selection_set: &'a ASelSet,
}

impl<'a> OpParts<'a> {
    fn from_ast(op: &'a q::OperationDefinition<'static, String>) -> OpParts<'a> {
        match op {
            q::OperationDefinition::SelectionSet(set) => OpParts {
                kind: OpKind::Query,
                name: None,
                var_defs: &[],
                directives: &[],
                selection_set: set,
            },
            q::OperationDefinition::Query(x) => OpParts {
                kind: OpKind::Query,
                name: x.name.as_deref(),
                var_defs: &x.variable_definitions,
                directives: &x.directives,
                selection_set: &x.selection_set,
            },
            q::OperationDefinition::Mutation(x) => OpParts {
                kind: OpKind::Mutation,
                name: x.name.as_deref(),
                var_defs: &x.variable_definitions,
                directives: &x.directives,
                selection_set: &x.selection_set,
            },
            q::OperationDefinition::Subscription(x) => OpParts {
                kind: OpKind::Subscription,
                name: x.name.as_deref(),
                var_defs: &x.variable_definitions,
                directives: &x.directives,
                selection_set: &x.selection_set,
            },
        }
    }
}

fn is_valid_graphql_name(s: &str) -> bool {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) if c == '_' || c.is_ascii_alphabetic() => {}
        _ => return false,
    }
    chars.all(|c| c == '_' || c.is_ascii_alphanumeric())
}

fn select_operation<'a, 'b>(
    ops: &'b [OpParts<'a>],
    operation_name: Option<&str>,
) -> GResult<&'b OpParts<'a>> {
    match operation_name {
        Some(name) => {
            if !is_valid_graphql_name(name) {
                return Err(perr(
                    "$.operationName",
                    format!("{name} is not valid GraphQL name"),
                ));
            }
            if ops.iter().any(|o| o.name.is_none()) {
                return Err(verr(
                    "$",
                    "operationName cannot be used when an anonymous operation exists in the document",
                ));
            }
            ops.iter().find(|o| o.name == Some(name)).ok_or_else(|| {
                verr(
                    "$",
                    format!("no such operation found in the document: \"{name}\""),
                )
            })
        }
        None => {
            if ops.len() == 1 {
                Ok(&ops[0])
            } else {
                Err(verr(
                    "$",
                    "exactly one operation has to be present in the document when operationName is not specified",
                ))
            }
        }
    }
}

fn check_operation_directives(kind: OpKind, directives: &[ADirective]) -> GResult<()> {
    let location = match kind {
        OpKind::Query => "query",
        OpKind::Mutation => "mutation",
        OpKind::Subscription => "subscription",
    };
    for d in directives {
        match d.name.as_str() {
            "include" | "skip" => {
                return Err(verr(
                    "$",
                    format!("directive '{}' is not allowed on a {location}", d.name),
                ));
            }
            // Hasura accepts @cached on queries (a no-op without caching).
            "cached" => {}
            other => {
                return Err(verr(
                    "$",
                    format!("directive '{other}' is not defined in the schema"),
                ));
            }
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Context and values
// ---------------------------------------------------------------------------

struct Ctx<'a> {
    model: &'a ServerModel,
    registry: &'a Registry,
    response_limit: Option<i64>,
    fragments: HashMap<&'a str, &'a AFragment>,
    vars: HashMap<&'a str, VarInfo<'a>>,
    used_vars: RefCell<HashSet<&'a str>>,
    /// i64-overflowing int literals were rewritten to magic sentinel values
    /// before parsing; this maps each sentinel back to the original digits.
    int_originals: HashMap<i64, String>,
    /// f64-overflowing float literals were rewritten to per-occurrence
    /// finite sentinel values before parsing; this maps each sentinel's bit
    /// pattern back to the original digits, for reconstructing Hasura's
    /// error display of values the AST can no longer represent.
    inf_float_originals: HashMap<u64, String>,
    /// JSON variable numbers that cannot round-trip through serde_json's
    /// f64 were rewritten to sentinel values before body parsing (see
    /// json_numbers.rs); maps each sentinel's bit pattern back to the
    /// original number text.
    var_number_originals: HashMap<u64, String>,
}

/// A value under coercion: either a GraphQL literal or a JSON value that
/// arrived through a variable. Hasura distinguishes the two in error
/// messages ("an integer" vs "a number", strict vs scientific ints).
#[derive(Clone, Copy)]
enum V<'a> {
    L(&'a AValue),
    J(&'a Json),
}

impl<'a> V<'a> {
    fn is_null(&self) -> bool {
        matches!(self, V::L(q::Value::Null) | V::J(Json::Null))
    }
}

/// Value-kind description used by the GraphQL-native (strict) parsers.
fn found_desc(v: V) -> &'static str {
    match v {
        V::L(l) => match l {
            q::Value::Int(_) => "an integer",
            q::Value::Float(_) => "a float",
            q::Value::String(_) => "a string",
            q::Value::Boolean(_) => "a boolean",
            q::Value::Null => "null",
            q::Value::Enum(_) => "an enum value",
            q::Value::List(_) => "a list",
            q::Value::Object(_) => "an object",
            q::Value::Variable(_) => "a variable",
        },
        V::J(j) => match j {
            Json::Null => "null",
            Json::Bool(_) => "a boolean",
            Json::Number(_) => "a number",
            Json::String(_) => "a string",
            Json::Array(_) => "a list",
            Json::Object(_) => "an object",
        },
    }
}

/// Value-kind name as aeson prints it in "encountered X" messages.
fn aeson_kind(v: V) -> &'static str {
    match v {
        V::L(l) => match l {
            q::Value::Int(_) | q::Value::Float(_) => "Number",
            q::Value::String(_) | q::Value::Enum(_) => "String",
            q::Value::Boolean(_) => "Boolean",
            q::Value::Null => "Null",
            q::Value::List(_) => "Array",
            q::Value::Object(_) => "Object",
            q::Value::Variable(_) => "Null",
        },
        V::J(j) => match j {
            Json::Null => "Null",
            Json::Bool(_) => "Boolean",
            Json::Number(_) => "Number",
            Json::String(_) => "String",
            Json::Array(_) => "Array",
            Json::Object(_) => "Object",
        },
    }
}

impl<'a> Ctx<'a> {
    fn mark_used(&self, name: &'a str) {
        self.used_vars.borrow_mut().insert(name);
    }

    /// Resolves a possibly-variable value at an input location, type-checking
    /// the variable's declared type against the location type.
    fn resolve(
        &'a self,
        value: &'a AValue,
        loc_ty: &TypeRef,
        loc_has_default: bool,
        path: &str,
    ) -> GResult<V<'a>> {
        match value {
            q::Value::Variable(name) => {
                self.mark_used(name);
                let var = self
                    .vars
                    .get(name.as_str())
                    .ok_or_else(|| verr("$", format!("unbound variable \"{name}\"")))?;
                let compatible = types_compatible(loc_ty, var.ty);
                let allowed = compatible
                    && (!loc_ty.is_non_null()
                        || atype_is_non_null(var.ty)
                        || loc_has_default
                        || matches!(var.default, Some(d) if !matches!(d, q::Value::Null)));
                if !allowed {
                    return Err(verr(
                        path,
                        format!(
                            "variable '{name}' is declared as '{}', but used where '{}' is expected",
                            atype_display(var.ty),
                            loc_ty.display()
                        ),
                    ));
                }
                Ok(match &var.value {
                    VarValue::Json(j) => V::J(j),
                    VarValue::Lit(l) => V::L(l),
                })
            }
            other => Ok(V::L(other)),
        }
    }
}

/// Structural compatibility ignoring nullability at each level, as Hasura's
/// areTypesCompatible does.
fn types_compatible(loc: &TypeRef, var: &AType) -> bool {
    let loc = match loc {
        TypeRef::NonNull(inner) => inner,
        other => other,
    };
    let var = match var {
        q::Type::NonNullType(inner) => inner,
        other => other,
    };
    match (loc, var) {
        (TypeRef::Named(a), q::Type::NamedType(b)) => a == b,
        (TypeRef::List(li), q::Type::ListType(vi)) => types_compatible(li, vi),
        _ => false,
    }
}

// ---------------------------------------------------------------------------
// Root planning
// ---------------------------------------------------------------------------

fn plan_roots<'a>(
    ctx: &'a Ctx<'a>,
    kind: ir::OperationKind,
    set: &'a ASelSet,
) -> GResult<Vec<ir::RootField>> {
    let root_type = match kind {
        ir::OperationKind::Query => ctx.registry.query_root.as_str(),
        ir::OperationKind::Subscription => ctx.registry.subscription_root.as_str(),
    };
    let sel_path = "$.selectionSet";
    let flats = collect_fields(ctx, root_type, &[set], sel_path)?;
    let root_def = ctx.registry.get(root_type);

    let mut roots: Vec<ir::RootField> = Vec::new();
    for flat in &flats {
        let field_path = format!("{sel_path}.{}", flat.name);
        if flat.name == "__typename" {
            check_leaf_field(flat, &field_path)?;
            roots.push(ir::RootField::Typename {
                alias: flat.key.clone(),
            });
            continue;
        }
        if kind == ir::OperationKind::Query && (flat.name == "__schema" || flat.name == "__type") {
            if let Some(root) = plan_introspection(ctx, flat, &field_path)? {
                roots.push(root);
                continue;
            }
        }
        let Some(field) = root_def.and_then(|d| d.field(flat.name)) else {
            return Err(verr(
                &field_path,
                format!("field '{}' not found in type: '{root_type}'", flat.name),
            ));
        };
        check_unknown_args(flat, field, &field_path)?;
        let root = match &field.kind {
            FieldKind::SelectMany { table } => {
                let args = coerce_select_args(ctx, flat, field, table, &field_path, true)?;
                let selection = require_object_selection(ctx, flat, table, &field_path)?;
                ir::RootField::Table(ir::TableRoot {
                    alias: flat.key.clone(),
                    table: table.clone(),
                    kind: ir::TableRootKind::Many { args, selection },
                })
            }
            FieldKind::SelectByPk { table } => {
                let pk = coerce_by_pk_args(ctx, flat, field, table, &field_path)?;
                let selection = require_object_selection(ctx, flat, table, &field_path)?;
                ir::RootField::Table(ir::TableRoot {
                    alias: flat.key.clone(),
                    table: table.clone(),
                    kind: ir::TableRootKind::ByPk { pk, selection },
                })
            }
            FieldKind::SelectAggregate { table } => {
                let args = coerce_select_args(ctx, flat, field, table, &field_path, false)?;
                let selection = require_aggregate_selection(ctx, flat, table, &field_path)?;
                ir::RootField::Table(ir::TableRoot {
                    alias: flat.key.clone(),
                    table: table.clone(),
                    kind: ir::TableRootKind::Aggregate { args, selection },
                })
            }
            FieldKind::SelectStream { table } => {
                let (batch_size, cursor, where_) =
                    coerce_stream_args(ctx, flat, field, table, &field_path)?;
                let selection = require_object_selection(ctx, flat, table, &field_path)?;
                ir::RootField::Table(ir::TableRoot {
                    alias: flat.key.clone(),
                    table: table.clone(),
                    kind: ir::TableRootKind::Stream {
                        batch_size,
                        cursor,
                        where_,
                        selection,
                    },
                })
            }
            _ => {
                return Err(verr(
                    &field_path,
                    format!("field '{}' not found in type: '{root_type}'", flat.name),
                ));
            }
        };
        roots.push(root);
    }
    Ok(roots)
}

/// Admin mutations: the registry has no mutation types yet, but real Hasura
/// resolves unknown mutation fields against 'mutation_root', so walk the
/// selection with an empty virtual type to reproduce those errors.
fn plan_admin_mutation<'a>(ctx: &'a Ctx<'a>, set: &'a ASelSet) -> GResult<ir::Operation> {
    let sel_path = "$.selectionSet";
    let flats = collect_fields(ctx, "mutation_root", &[set], sel_path)?;
    for flat in &flats {
        if flat.name == "__typename" {
            continue;
        }
        if let Some(root_name) = &ctx.registry.mutation_root {
            if ctx
                .registry
                .get(root_name)
                .and_then(|d| d.field(flat.name))
                .is_some()
            {
                continue;
            }
        }
        return Err(verr(
            format!("{sel_path}.{}", flat.name),
            format!("field '{}' not found in type: 'mutation_root'", flat.name),
        ));
    }
    Err(verr("$", "no mutations exist"))
}

fn check_unknown_args(flat: &Flat, field: &FieldDef, field_path: &str) -> GResult<()> {
    for (name, _) in flat.args {
        if !field.args.iter().any(|a| &a.name == name) {
            return Err(verr(
                field_path,
                format!("'{}' has no argument named '{name}'", flat.name),
            ));
        }
    }
    Ok(())
}

/// Leaf fields take no arguments and no sub-selection.
fn check_leaf_field(flat: &Flat, field_path: &str) -> GResult<()> {
    if let Some((name, _)) = flat.args.first() {
        return Err(verr(
            field_path,
            format!("'{}' has no argument named '{name}'", flat.name),
        ));
    }
    if flat.had_selection {
        return Err(verr(
            field_path,
            "unexpected subselection set for non-object field",
        ));
    }
    Ok(())
}

fn require_object_selection<'a>(
    ctx: &'a Ctx<'a>,
    flat: &Flat<'a>,
    table: &str,
    field_path: &str,
) -> GResult<ir::ObjectSelection> {
    if !flat.had_selection {
        return Err(verr(
            format!("{field_path}.selectionSet"),
            format!("missing selection set for '{}'", flat.name),
        ));
    }
    object_selection(
        ctx,
        table,
        &flat.sel_sets,
        &format!("{field_path}.selectionSet"),
    )
}

fn require_aggregate_selection<'a>(
    ctx: &'a Ctx<'a>,
    flat: &Flat<'a>,
    table: &str,
    field_path: &str,
) -> GResult<ir::AggregateSelection> {
    if !flat.had_selection {
        return Err(verr(
            format!("{field_path}.selectionSet"),
            format!("missing selection set for '{}'", flat.name),
        ));
    }
    aggregate_selection(
        ctx,
        table,
        &flat.sel_sets,
        &format!("{field_path}.selectionSet"),
    )
}

// ---------------------------------------------------------------------------
// Table selections
// ---------------------------------------------------------------------------

fn model_table<'a>(ctx: &'a Ctx, name: &str) -> &'a Table {
    ctx.model
        .table(name)
        .expect("registry table missing from model")
}

fn object_selection<'a>(
    ctx: &'a Ctx<'a>,
    table_name: &str,
    sets: &[&'a ASelSet],
    sel_path: &str,
) -> GResult<ir::ObjectSelection> {
    let flats = collect_fields(ctx, table_name, sets, sel_path)?;
    let type_def = ctx.registry.get(table_name);
    let table = model_table(ctx, table_name);

    let mut items: Vec<ir::SelItem> = Vec::new();
    for flat in &flats {
        let field_path = format!("{sel_path}.{}", flat.name);
        if flat.name == "__typename" {
            check_leaf_field(flat, &field_path)?;
            items.push(ir::SelItem::Typename {
                alias: flat.key.clone(),
                type_name: table_name.to_string(),
            });
            continue;
        }
        let Some(field) = type_def.and_then(|d| d.field(flat.name)) else {
            return Err(verr(
                &field_path,
                format!("field '{}' not found in type: '{table_name}'", flat.name),
            ));
        };
        check_unknown_args(flat, field, &field_path)?;
        match &field.kind {
            FieldKind::Column { column } => {
                if flat.had_selection {
                    return Err(verr(
                        &field_path,
                        "unexpected subselection set for non-object field",
                    ));
                }
                let col = table
                    .column_by_api_name(column)
                    .expect("registry column missing from model");
                let json_path = coerce_json_path_arg(ctx, flat, field, &field_path)?;
                items.push(ir::SelItem::Column {
                    alias: flat.key.clone(),
                    column: col.db_name.clone(),
                    scalar: col.scalar,
                    pg_type: col.pg_type.clone(),
                    is_array: col.is_array,
                    json_path,
                });
            }
            FieldKind::ObjectRel { rel } => {
                let rel = table
                    .object_relationships
                    .iter()
                    .find(|r| &r.name == rel)
                    .expect("registry object rel missing from model");
                let selection =
                    require_object_selection(ctx, flat, &rel.remote_table, &field_path)?;
                items.push(ir::SelItem::ObjectRel {
                    alias: flat.key.clone(),
                    local_column: rel.local_db_column.clone(),
                    remote_table: rel.remote_table.clone(),
                    selection,
                });
            }
            FieldKind::ArrayRel { rel } => {
                let rel = table
                    .array_relationships
                    .iter()
                    .find(|r| &r.name == rel)
                    .expect("registry array rel missing from model");
                let args =
                    coerce_select_args(ctx, flat, field, &rel.remote_table, &field_path, true)?;
                let selection =
                    require_object_selection(ctx, flat, &rel.remote_table, &field_path)?;
                items.push(ir::SelItem::ArrayRel {
                    alias: flat.key.clone(),
                    remote_column: rel.remote_db_column.clone(),
                    remote_table: rel.remote_table.clone(),
                    args,
                    selection,
                });
            }
            FieldKind::ArrayRelAggregate { rel } => {
                let rel = table
                    .array_relationships
                    .iter()
                    .find(|r| &r.name == rel)
                    .expect("registry array rel missing from model");
                let args =
                    coerce_select_args(ctx, flat, field, &rel.remote_table, &field_path, false)?;
                let selection =
                    require_aggregate_selection(ctx, flat, &rel.remote_table, &field_path)?;
                items.push(ir::SelItem::ArrayRelAggregate {
                    alias: flat.key.clone(),
                    remote_column: rel.remote_db_column.clone(),
                    remote_table: rel.remote_table.clone(),
                    args,
                    selection,
                });
            }
            _ => {
                return Err(verr(
                    &field_path,
                    format!("field '{}' not found in type: '{table_name}'", flat.name),
                ));
            }
        }
    }
    Ok(ir::ObjectSelection {
        table: table_name.to_string(),
        items,
    })
}

fn aggregate_selection<'a>(
    ctx: &'a Ctx<'a>,
    table_name: &str,
    sets: &[&'a ASelSet],
    sel_path: &str,
) -> GResult<ir::AggregateSelection> {
    let agg_type = format!("{table_name}_aggregate");
    let flats = collect_fields(ctx, &agg_type, sets, sel_path)?;
    let type_def = ctx.registry.get(&agg_type);

    let mut items: Vec<ir::AggSelItem> = Vec::new();
    for flat in &flats {
        let field_path = format!("{sel_path}.{}", flat.name);
        if flat.name == "__typename" {
            check_leaf_field(flat, &field_path)?;
            items.push(ir::AggSelItem::Typename {
                alias: flat.key.clone(),
                type_name: agg_type.clone(),
            });
            continue;
        }
        let Some(field) = type_def.and_then(|d| d.field(flat.name)) else {
            return Err(verr(
                &field_path,
                format!("field '{}' not found in type: '{agg_type}'", flat.name),
            ));
        };
        check_unknown_args(flat, field, &field_path)?;
        match &field.kind {
            FieldKind::AggregateBody => {
                if !flat.had_selection {
                    return Err(verr(
                        format!("{field_path}.selectionSet"),
                        format!("missing selection set for '{}'", flat.name),
                    ));
                }
                let body_items = aggregate_body(
                    ctx,
                    table_name,
                    &flat.sel_sets,
                    &format!("{field_path}.selectionSet"),
                )?;
                items.push(ir::AggSelItem::Aggregate {
                    alias: flat.key.clone(),
                    items: body_items,
                });
            }
            FieldKind::AggregateNodes => {
                let selection = require_object_selection(ctx, flat, table_name, &field_path)?;
                items.push(ir::AggSelItem::Nodes {
                    alias: flat.key.clone(),
                    selection,
                });
            }
            _ => {
                return Err(verr(
                    &field_path,
                    format!("field '{}' not found in type: '{agg_type}'", flat.name),
                ));
            }
        }
    }
    Ok(ir::AggregateSelection {
        table: table_name.to_string(),
        items,
        // Hasura computes the aggregate over the uncapped set but caps the
        // rows `nodes` returns at the role's response limit
        // (limits-public-aggregate-count-exceeds-limit).
        nodes_limit: ctx.response_limit,
    })
}

fn aggregate_body<'a>(
    ctx: &'a Ctx<'a>,
    table_name: &str,
    sets: &[&'a ASelSet],
    sel_path: &str,
) -> GResult<Vec<ir::AggFieldItem>> {
    let fields_type = format!("{table_name}_aggregate_fields");
    let flats = collect_fields(ctx, &fields_type, sets, sel_path)?;
    let type_def = ctx.registry.get(&fields_type);
    let table = model_table(ctx, table_name);

    let mut items: Vec<ir::AggFieldItem> = Vec::new();
    for flat in &flats {
        let field_path = format!("{sel_path}.{}", flat.name);
        if flat.name == "__typename" {
            check_leaf_field(flat, &field_path)?;
            items.push(ir::AggFieldItem::Typename {
                alias: flat.key.clone(),
                type_name: fields_type.clone(),
            });
            continue;
        }
        let Some(field) = type_def.and_then(|d| d.field(flat.name)) else {
            return Err(verr(
                &field_path,
                format!("field '{}' not found in type: '{fields_type}'", flat.name),
            ));
        };
        check_unknown_args(flat, field, &field_path)?;
        match &field.kind {
            FieldKind::AggregateCount => {
                if flat.had_selection {
                    return Err(verr(
                        &field_path,
                        "unexpected subselection set for non-object field",
                    ));
                }
                let mut columns: Vec<String> = Vec::new();
                if let Some(v) = resolve_arg(ctx, flat, field, "columns", &field_path)? {
                    let columns_path = format!("{field_path}.args.columns");
                    let enum_name = format!("{table_name}_select_column");
                    for (i, item) in expect_list(v, &columns_path)?.into_iter().enumerate() {
                        let ipath = format!("{columns_path}[{i}]");
                        let api = coerce_enum(ctx, item, &enum_name, &ipath)?;
                        columns.push(api_to_db_column(table, &api));
                    }
                }
                let distinct = match resolve_arg(ctx, flat, field, "distinct", &field_path)? {
                    Some(v) => coerce_bool_strict(v, &format!("{field_path}.args.distinct"))?,
                    None => false,
                };
                items.push(ir::AggFieldItem::Count {
                    alias: flat.key.clone(),
                    columns,
                    distinct,
                });
            }
            FieldKind::AggregateOp { op } => {
                if !flat.had_selection {
                    return Err(verr(
                        format!("{field_path}.selectionSet"),
                        format!("missing selection set for '{}'", flat.name),
                    ));
                }
                let columns = aggregate_op_columns(
                    ctx,
                    table_name,
                    op,
                    &flat.sel_sets,
                    &format!("{field_path}.selectionSet"),
                )?;
                items.push(ir::AggFieldItem::Op {
                    alias: flat.key.clone(),
                    op: op.clone(),
                    columns,
                });
            }
            _ => {
                return Err(verr(
                    &field_path,
                    format!("field '{}' not found in type: '{fields_type}'", flat.name),
                ));
            }
        }
    }
    Ok(items)
}

fn aggregate_op_columns<'a>(
    ctx: &'a Ctx<'a>,
    table_name: &str,
    op: &str,
    sets: &[&'a ASelSet],
    sel_path: &str,
) -> GResult<Vec<ir::AggOpColumn>> {
    let op_type = format!("{table_name}_{op}_fields");
    let flats = collect_fields(ctx, &op_type, sets, sel_path)?;
    let type_def = ctx.registry.get(&op_type);
    let table = model_table(ctx, table_name);

    let mut columns: Vec<ir::AggOpColumn> = Vec::new();
    for flat in &flats {
        let field_path = format!("{sel_path}.{}", flat.name);
        if flat.name == "__typename" {
            check_leaf_field(flat, &field_path)?;
            columns.push(ir::AggOpColumn::Typename {
                alias: flat.key.clone(),
                type_name: op_type.clone(),
            });
            continue;
        }
        let Some(field) = type_def.and_then(|d| d.field(flat.name)) else {
            return Err(verr(
                &field_path,
                format!("field '{}' not found in type: '{op_type}'", flat.name),
            ));
        };
        check_unknown_args(flat, field, &field_path)?;
        if flat.had_selection {
            return Err(verr(
                &field_path,
                "unexpected subselection set for non-object field",
            ));
        }
        match &field.kind {
            FieldKind::AggregateOpColumn { op, column } => {
                let col = table
                    .column_by_api_name(column)
                    .expect("registry column missing from model");
                columns.push(ir::AggOpColumn::Column {
                    alias: flat.key.clone(),
                    column: col.db_name.clone(),
                    scalar: col.scalar,
                    pg_type: col.pg_type.clone(),
                    is_array: col.is_array,
                    op: op.clone(),
                });
            }
            _ => {
                return Err(verr(
                    &field_path,
                    format!("field '{}' not found in type: '{op_type}'", flat.name),
                ));
            }
        }
    }
    Ok(columns)
}

// ---------------------------------------------------------------------------
// Introspection planning
// ---------------------------------------------------------------------------

/// Returns None when the meta types are absent from the registry, in which
/// case the caller falls through to the regular unknown-field error.
fn plan_introspection<'a>(
    ctx: &'a Ctx<'a>,
    flat: &Flat<'a>,
    field_path: &str,
) -> GResult<Option<ir::RootField>> {
    let meta_type = match flat.name {
        "__schema" => "__Schema",
        _ => "__Type",
    };
    if ctx.registry.get(meta_type).is_none() {
        return Ok(None);
    }

    let mut type_name: Option<String> = None;
    if flat.name == "__type" {
        for (name, _) in flat.args {
            if name != "name" {
                return Err(verr(
                    field_path,
                    format!("'{}' has no argument named '{name}'", flat.name),
                ));
            }
        }
        let name_path = format!("{field_path}.args.name");
        let Some((_, raw)) = flat.args.iter().find(|(n, _)| n == "name") else {
            return Err(verr(name_path, "missing required field 'name'"));
        };
        let loc_ty = TypeRef::non_null(TypeRef::named("String"));
        let v = ctx.resolve(raw, &loc_ty, false, &name_path)?;
        type_name = Some(coerce_string_strict(v, &name_path)?);
    } else if let Some((name, _)) = flat.args.first() {
        return Err(verr(
            field_path,
            format!("'{}' has no argument named '{name}'", flat.name),
        ));
    }

    if !flat.had_selection {
        return Err(verr(
            format!("{field_path}.selectionSet"),
            format!("missing selection set for '{}'", flat.name),
        ));
    }
    let selection = intro_selection(
        ctx,
        meta_type,
        &flat.sel_sets,
        &format!("{field_path}.selectionSet"),
    )?;
    Ok(Some(ir::RootField::Introspection(ir::IntrospectionField {
        alias: flat.key.clone(),
        field: flat.name.to_string(),
        type_name,
        selection,
    })))
}

fn intro_selection<'a>(
    ctx: &'a Ctx<'a>,
    meta_type: &str,
    sets: &[&'a ASelSet],
    sel_path: &str,
) -> GResult<ir::IntroSelection> {
    let flats = collect_fields(ctx, meta_type, sets, sel_path)?;
    let type_def = ctx.registry.get(meta_type);

    let mut items: Vec<ir::IntroSelItem> = Vec::new();
    for flat in &flats {
        let field_path = format!("{sel_path}.{}", flat.name);
        if flat.name == "__typename" {
            check_leaf_field(flat, &field_path)?;
            items.push(ir::IntroSelItem {
                alias: flat.key.clone(),
                field: "__typename".to_string(),
                include_deprecated: false,
                selection: None,
            });
            continue;
        }
        let Some(field) = type_def.and_then(|d| d.field(flat.name)) else {
            return Err(verr(
                &field_path,
                format!("field '{}' not found in type: '{meta_type}'", flat.name),
            ));
        };
        check_unknown_args(flat, field, &field_path)?;
        let include_deprecated =
            match resolve_arg(ctx, flat, field, "includeDeprecated", &field_path)? {
                Some(v) if !v.is_null() => {
                    coerce_bool_strict(v, &format!("{field_path}.args.includeDeprecated"))?
                }
                _ => false,
            };
        let base = field.ty.base_name();
        let is_object = matches!(ctx.registry.get(base), Some(TypeDef::Object { .. }));
        let selection = if is_object {
            if !flat.had_selection {
                return Err(verr(
                    format!("{field_path}.selectionSet"),
                    format!("missing selection set for '{}'", flat.name),
                ));
            }
            Some(intro_selection(
                ctx,
                base,
                &flat.sel_sets,
                &format!("{field_path}.selectionSet"),
            )?)
        } else {
            if flat.had_selection {
                return Err(verr(
                    &field_path,
                    "unexpected subselection set for non-object field",
                ));
            }
            None
        };
        items.push(ir::IntroSelItem {
            alias: flat.key.clone(),
            field: flat.name.to_string(),
            include_deprecated,
            selection,
        });
    }
    Ok(ir::IntroSelection { items })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::serve::gql::schema_build;
    use crate::serve::pg_catalog::RelationKind;

    #[test]
    fn graphql_name_validation() {
        assert!(is_valid_graphql_name("Query1"));
        assert!(is_valid_graphql_name("_a"));
        assert!(!is_valid_graphql_name(""));
        assert!(!is_valid_graphql_name("9x"));
        assert!(!is_valid_graphql_name("a-b"));
    }

    fn column(name: &str, pg_type: &str, scalar: Scalar) -> Column {
        Column {
            api_name: name.to_string(),
            db_name: name.to_string(),
            pg_type: pg_type.to_string(),
            scalar,
            is_array: false,
            nullable: false,
            description: None,
        }
    }

    fn test_model() -> ServerModel {
        ServerModel {
            tables: vec![Table {
                name: "User".to_string(),
                kind: RelationKind::Table,
                description: None,
                columns: vec![
                    column("id", "text", Scalar::String),
                    column("big", "numeric", Scalar::Numeric),
                ],
                primary_key: vec!["id".to_string()],
                object_relationships: vec![],
                array_relationships: vec![],
                admin_only: false,
                public_aggregations: false,
            }],
            pg_schema: "public".to_string(),
            response_limit: None,
        }
    }

    /// Plans a request the way the HTTP path does, including the lossy
    /// variable-number rewrite of the raw variables text.
    fn plan(query: &str, variables: Option<&str>) -> GResult<ir::Operation> {
        let model = test_model();
        let schema = RoleSchema {
            registry: schema_build::build(&model, Role::Admin),
            role: Role::Admin,
        };
        let variables = variables.map(|text| match json_numbers::rewrite_lossy_numbers(text) {
            Some((rewritten, originals)) => {
                let Json::Object(mut m) = serde_json::from_str::<Json>(&rewritten).unwrap() else {
                    panic!("variables must be an object");
                };
                json_numbers::attach_originals(&mut m, &originals);
                Json::Object(m)
            }
            None => serde_json::from_str(text).unwrap(),
        });
        let request = GraphQLRequest {
            query: Some(query.to_string()),
            variables,
            operation_name: None,
        };
        plan_request(&model, &schema, &request, Transport::Http)
    }

    /// The SQL text of a single `big: {_eq: ...}` comparison.
    fn eq_sql_text(op: ir::Operation) -> String {
        let Some(ir::RootField::Table(root)) = op.root_fields.into_iter().next() else {
            panic!("expected a table root");
        };
        let ir::TableRootKind::Many { args, .. } = root.kind else {
            panic!("expected a many root");
        };
        let Some(ir::BoolExp::Compare {
            op: ir::CompareOp::Eq(v),
            ..
        }) = args.where_
        else {
            panic!("expected a single _eq comparison");
        };
        v.text.unwrap()
    }

    fn fragment_chain(count: usize, spreads_per_fragment: usize) -> String {
        let mut q = String::from("query { User { ...f0 } } ");
        for i in 0..count {
            q.push_str(&format!("fragment f{i} on User {{ "));
            if i + 1 < count {
                for _ in 0..spreads_per_fragment {
                    q.push_str(&format!("...f{} ", i + 1));
                }
            } else {
                q.push_str("id ");
            }
            q.push('}');
            q.push(' ');
        }
        q
    }

    #[test]
    fn double_spread_fragment_chain_small_succeeds() {
        assert!(plan(&fragment_chain(10, 2), None).is_ok());
    }

    #[test]
    fn double_spread_fragment_chain_large_hits_selection_budget() {
        // 2^40 naive expansions: must fail fast with the budget error
        // instead of hanging or exhausting memory.
        let err = plan(&fragment_chain(40, 2), None).unwrap_err();
        assert_eq!(
            err.message,
            "the selection set exceeds the maximum of 50000 selections after fragment expansion"
        );
    }

    #[test]
    fn long_single_spread_fragment_chain_hits_depth_limit() {
        // 100k chained fragments would recurse 100k frames in the prepass
        // without the frame cap.
        let err = plan(&fragment_chain(100_000, 1), None).unwrap_err();
        assert_eq!(
            err.message,
            "the query exceeds the maximum allowed nesting depth of 100"
        );
    }

    fn nested_not_query(n: usize) -> String {
        let mut q = String::from("{ User(where: ");
        for _ in 0..n {
            q.push_str("{_not: ");
        }
        q.push_str("{id: {_eq: \"1\"}}");
        for _ in 0..n {
            q.push('}');
        }
        q.push_str(") { id } }");
        q
    }

    #[test]
    fn nesting_depth_at_limit_passes() {
        // Depth: selection brace + arg paren + 94 `_not` braces + the two
        // `{id: {_eq:` braces = exactly 100.
        assert!(plan(&nested_not_query(96), None).is_ok());
    }

    #[test]
    fn nesting_depth_over_limit_errors() {
        for n in [97, 200, 100_000] {
            let err = plan(&nested_not_query(n), None).unwrap_err();
            assert_eq!(
                (n, err.message.as_str(), err.code),
                (
                    n,
                    "the query exceeds the maximum allowed nesting depth of 100",
                    CODE_VALIDATION_FAILED
                )
            );
        }
    }

    #[test]
    fn fragment_expansion_depth_over_limit_errors() {
        // Each fragment nests 50 selection levels lexically (fine), but
        // spreading one inside the other expands past 100.
        let mut q = String::from("query { User { ...f0 } } ");
        for i in 0..3 {
            q.push_str(&format!("fragment f{i} on User {{ "));
            let mut depth = 0;
            for _ in 0..49 {
                q.push_str("u { ");
                depth += 1;
            }
            if i < 2 {
                q.push_str(&format!("...f{} ", i + 1));
            } else {
                q.push_str("id ");
            }
            for _ in 0..depth {
                q.push('}');
            }
            q.push_str("} ");
        }
        let err = plan(&q, None).unwrap_err();
        assert_eq!(
            err.message,
            "the query exceeds the maximum allowed nesting depth of 100"
        );
    }

    #[test]
    fn fragment_cycle_error_is_preserved() {
        let q = "query { User { ...a } } \
                 fragment a on User { ...b } fragment b on User { ...a }";
        let err = plan(q, None).unwrap_err();
        assert_eq!(
            err.message,
            "the fragment definition(s) a and b form a cycle"
        );
    }

    #[test]
    fn big_integer_variable_reaches_sql_losslessly() {
        let op = plan(
            "query($v: numeric) { User(where: {big: {_eq: $v}}) { id } }",
            Some(r#"{"v": 99999999999999999999999}"#),
        )
        .unwrap();
        assert_eq!(eq_sql_text(op), "99999999999999999999999");
    }

    #[test]
    fn high_precision_decimal_variable_reaches_sql_losslessly() {
        let op = plan(
            "query($v: numeric) { User(where: {big: {_eq: $v}}) { id } }",
            Some(r#"{"v": 1.00000000000000000000001}"#),
        )
        .unwrap();
        assert_eq!(eq_sql_text(op), "1.00000000000000000000001");
    }

    #[test]
    fn ordinary_number_variables_are_unchanged() {
        for (vars, expected) in [
            (r#"{"v": 1.5}"#, "1.5"),
            (r#"{"v": 42}"#, "42"),
            (r#"{"v": 1e2}"#, "100"),
            (r#"{"v": -7}"#, "-7"),
        ] {
            let op = plan(
                "query($v: numeric) { User(where: {big: {_eq: $v}}) { id } }",
                Some(vars),
            )
            .unwrap();
            assert_eq!((vars, eq_sql_text(op).as_str()), (vars, expected));
        }
    }

    #[test]
    fn unexpected_variables_still_reported() {
        let err = plan(
            "query { User { id } }",
            Some(r#"{"v": 99999999999999999999999}"#),
        )
        .unwrap_err();
        assert_eq!(err.message, "unexpected variables in variableValues: v");
    }
}
