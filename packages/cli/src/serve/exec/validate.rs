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
use std::collections::{BTreeMap, HashMap, HashSet};

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
        inf_floats: scan.inf_floats,
    };

    // Fragment reachability (undefined spreads, cycles) is checked before
    // variables, which are checked before any schema validation — matching
    // Hasura's inline -> resolveVariables -> parse pipeline.
    fragment_prepass(&ctx, op.selection_set, "$.selectionSet", &mut Vec::new())?;
    variable_prepass(&ctx, op.selection_set)?;
    if let Some(vars) = variables_json {
        let used = ctx.used_vars.borrow();
        let unexpected: Vec<&str> = vars
            .keys()
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
// Variables
// ---------------------------------------------------------------------------

enum VarValue<'a> {
    Json(&'a Json),
    Lit(&'a AValue),
}

struct VarInfo<'a> {
    ty: &'a AType,
    default: Option<&'a AValue>,
    value: VarValue<'a>,
}

fn atype_display(t: &AType) -> String {
    match t {
        q::Type::NamedType(n) => n.clone(),
        q::Type::ListType(inner) => format!("[{}]", atype_display(inner)),
        q::Type::NonNullType(inner) => format!("{}!", atype_display(inner)),
    }
}

fn atype_is_non_null(t: &AType) -> bool {
    matches!(t, q::Type::NonNullType(_))
}

fn build_variables<'a>(
    defs: &'a [AVarDef],
    provided: Option<&'a serde_json::Map<String, Json>>,
) -> GResult<HashMap<&'a str, VarInfo<'a>>> {
    let mut vars: HashMap<&str, VarInfo> = HashMap::new();
    for def in defs {
        if vars.contains_key(def.name.as_str()) {
            return Err(perr(
                "$",
                format!("multiple definitions for variable \"{}\"", def.name),
            ));
        }
        let value = match provided.and_then(|m| m.get(def.name.as_str())) {
            Some(json) => {
                if json.is_null() && atype_is_non_null(&def.var_type) {
                    return Err(verr(
                        "$",
                        format!(
                            "null value found for non-nullable type: \"{}\"",
                            atype_display(&def.var_type)
                        ),
                    ));
                }
                VarValue::Json(json)
            }
            None => match &def.default_value {
                Some(d) => VarValue::Lit(d),
                None => {
                    if atype_is_non_null(&def.var_type) {
                        return Err(verr(
                            "$",
                            format!(
                                "expecting a value for non-nullable variable: \"{}\"",
                                def.name
                            ),
                        ));
                    }
                    VarValue::Lit(&NULL_LIT)
                }
            },
        };
        vars.insert(
            def.name.as_str(),
            VarInfo {
                ty: &def.var_type,
                default: def.default_value.as_ref(),
                value,
            },
        );
    }
    Ok(vars)
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
    used_vars: RefCell<HashSet<String>>,
    /// i64-overflowing int literals were rewritten to magic sentinel values
    /// before parsing; this maps each sentinel back to the original digits.
    int_originals: HashMap<i64, String>,
    /// Float literals that overflow f64, in source order, for reconstructing
    /// Hasura's error display of values the AST can no longer represent.
    inf_floats: Vec<String>,
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
    fn mark_used(&self, name: &str) {
        self.used_vars.borrow_mut().insert(name.to_string());
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
// Lexical pre-scan
// ---------------------------------------------------------------------------
//
// graphql-parser cannot represent three things Hasura handles at the lexer
// level: duplicate argument names, duplicate keys in input-object literals
// (both "not a valid graphql query" in Hasura, while graphql-parser silently
// collapses them into a BTreeMap), and int literals beyond i64 (Hasura keeps
// arbitrary precision, graphql-parser fails the whole parse). This token
// scan rejects the duplicates and rewrites oversized int literals to unused
// sentinel i64 values, remembering the original digits.

struct Prescan {
    rewritten: String,
    int_originals: HashMap<i64, String>,
    inf_floats: Vec<String>,
}

#[derive(Clone, Copy, PartialEq)]
enum TokKind {
    Name,
    Int,
    Float,
    Str,
    Punct(char),
}

struct Tok<'a> {
    kind: TokKind,
    text: &'a str,
    start: usize,
    end: usize,
}

fn tokenize(src: &str) -> Result<Vec<Tok<'_>>, ()> {
    let bytes = src.as_bytes();
    let mut toks = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i];
        match c {
            b' ' | b'\t' | b'\r' | b'\n' | b',' => i += 1,
            b'#' => {
                while i < bytes.len() && bytes[i] != b'\n' {
                    i += 1;
                }
            }
            b'"' => {
                let start = i;
                if bytes[i..].starts_with(b"\"\"\"") {
                    i += 3;
                    loop {
                        if i >= bytes.len() {
                            return Err(());
                        }
                        if bytes[i] == b'\\' {
                            i += 2;
                        } else if bytes[i..].starts_with(b"\"\"\"") {
                            i += 3;
                            break;
                        } else {
                            i += 1;
                        }
                    }
                } else {
                    i += 1;
                    loop {
                        if i >= bytes.len() {
                            return Err(());
                        }
                        match bytes[i] {
                            b'\\' => i += 2,
                            b'"' => {
                                i += 1;
                                break;
                            }
                            b'\n' => return Err(()),
                            _ => i += 1,
                        }
                    }
                }
                toks.push(Tok {
                    kind: TokKind::Str,
                    text: &src[start..i],
                    start,
                    end: i,
                });
            }
            b'-' | b'0'..=b'9' => {
                let start = i;
                if c == b'-' {
                    i += 1;
                }
                while i < bytes.len() && bytes[i].is_ascii_digit() {
                    i += 1;
                }
                let mut is_float = false;
                if i < bytes.len() && bytes[i] == b'.' {
                    is_float = true;
                    i += 1;
                    while i < bytes.len() && bytes[i].is_ascii_digit() {
                        i += 1;
                    }
                }
                if i < bytes.len() && (bytes[i] == b'e' || bytes[i] == b'E') {
                    is_float = true;
                    i += 1;
                    if i < bytes.len() && (bytes[i] == b'+' || bytes[i] == b'-') {
                        i += 1;
                    }
                    while i < bytes.len() && bytes[i].is_ascii_digit() {
                        i += 1;
                    }
                }
                toks.push(Tok {
                    kind: if is_float {
                        TokKind::Float
                    } else {
                        TokKind::Int
                    },
                    text: &src[start..i],
                    start,
                    end: i,
                });
            }
            b'_' | b'a'..=b'z' | b'A'..=b'Z' => {
                let start = i;
                while i < bytes.len() && (bytes[i] == b'_' || bytes[i].is_ascii_alphanumeric()) {
                    i += 1;
                }
                toks.push(Tok {
                    kind: TokKind::Name,
                    text: &src[start..i],
                    start,
                    end: i,
                });
            }
            _ => {
                // Multi-byte UTF-8 or punctuation; treat one char at a time.
                let ch_len = src[i..].chars().next().map(|c| c.len_utf8()).unwrap_or(1);
                toks.push(Tok {
                    kind: TokKind::Punct(c as char),
                    text: &src[i..i + ch_len],
                    start: i,
                    end: i + ch_len,
                });
                i += ch_len;
            }
        }
    }
    Ok(toks)
}

fn prescan(src: &str) -> GResult<Prescan> {
    let toks = tokenize(src).map_err(|_| invalid_query())?;

    // Duplicate argument names / duplicate input-object keys. Inside
    // argument parentheses every `{` opens an object literal (selection
    // sets cannot occur there), so key tracking only runs at paren depth
    // > 0. Names preceded by `$` are variable definitions, not keys.
    enum Scope {
        Args(HashSet<String>),
        Object(HashSet<String>),
        List,
    }
    let mut scopes: Vec<Scope> = Vec::new();
    for (idx, t) in toks.iter().enumerate() {
        match t.kind {
            TokKind::Punct('(') => scopes.push(Scope::Args(HashSet::new())),
            TokKind::Punct(')') => {
                while let Some(s) = scopes.pop() {
                    if matches!(s, Scope::Args(_)) {
                        break;
                    }
                }
            }
            TokKind::Punct('{') if !scopes.is_empty() => scopes.push(Scope::Object(HashSet::new())),
            TokKind::Punct('}') => {
                if matches!(scopes.last(), Some(Scope::Object(_))) {
                    scopes.pop();
                }
            }
            TokKind::Punct('[') if !scopes.is_empty() => scopes.push(Scope::List),
            TokKind::Punct(']') => {
                if matches!(scopes.last(), Some(Scope::List)) {
                    scopes.pop();
                }
            }
            TokKind::Name => {
                let followed_by_colon =
                    matches!(toks.get(idx + 1), Some(n) if n.kind == TokKind::Punct(':'));
                let preceded_by_dollar = idx > 0 && toks[idx - 1].kind == TokKind::Punct('$');
                if followed_by_colon && !preceded_by_dollar {
                    match scopes.last_mut() {
                        Some(Scope::Args(keys)) | Some(Scope::Object(keys)) => {
                            if !keys.insert(t.text.to_string()) {
                                return Err(invalid_query());
                            }
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }

    // Oversized int literals and f64-overflowing float literals.
    let mut int_originals: HashMap<i64, String> = HashMap::new();
    let mut inf_floats: Vec<String> = Vec::new();
    let mut oversized: Vec<usize> = Vec::new();
    let mut taken_values: HashSet<i64> = HashSet::new();
    for (idx, t) in toks.iter().enumerate() {
        match t.kind {
            TokKind::Int => match t.text.parse::<i64>() {
                Ok(n) => {
                    taken_values.insert(n);
                }
                Err(_) => oversized.push(idx),
            },
            TokKind::Float => {
                if let Ok(f) = t.text.parse::<f64>() {
                    if f.is_infinite() {
                        inf_floats.push(t.text.to_string());
                    }
                }
            }
            _ => {}
        }
    }

    let rewritten = if oversized.is_empty() {
        src.to_string()
    } else {
        let mut magic = i64::MAX;
        let mut out = String::with_capacity(src.len());
        let mut pos = 0;
        for idx in oversized {
            let t = &toks[idx];
            while taken_values.contains(&magic) || int_originals.contains_key(&magic) {
                magic -= 1;
            }
            int_originals.insert(magic, t.text.to_string());
            out.push_str(&src[pos..t.start]);
            out.push_str(&magic.to_string());
            pos = t.end;
        }
        out.push_str(&src[pos..]);
        out
    };

    Ok(Prescan {
        rewritten,
        int_originals,
        inf_floats,
    })
}

// ---------------------------------------------------------------------------
// Prepasses: fragment reachability, variable usage
// ---------------------------------------------------------------------------

fn english_list(names: &[String]) -> String {
    match names.len() {
        0 => String::new(),
        1 => names[0].clone(),
        _ => format!(
            "{} and {}",
            names[..names.len() - 1].join(", "),
            names[names.len() - 1]
        ),
    }
}

fn fragment_prepass(
    ctx: &Ctx,
    set: &ASelSet,
    sel_path: &str,
    stack: &mut Vec<String>,
) -> GResult<()> {
    for item in &set.items {
        match item {
            q::Selection::Field(f) => {
                if !f.selection_set.items.is_empty() {
                    let inner = format!("{sel_path}.{}.selectionSet", f.name);
                    fragment_prepass(ctx, &f.selection_set, &inner, stack)?;
                }
            }
            q::Selection::FragmentSpread(spread) => {
                let name = spread.fragment_name.as_str();
                let Some(frag) = ctx.fragments.get(name) else {
                    return Err(verr(
                        sel_path,
                        format!("reference to undefined fragment \"{name}\""),
                    ));
                };
                if let Some(first) = stack.iter().position(|n| n == name) {
                    return Err(verr(
                        sel_path,
                        format!(
                            "the fragment definition(s) {} form a cycle",
                            english_list(&stack[first..])
                        ),
                    ));
                }
                stack.push(name.to_string());
                let inner = format!("{sel_path}.{name}.selectionSet");
                fragment_prepass(ctx, &frag.selection_set, &inner, stack)?;
                stack.pop();
            }
            q::Selection::InlineFragment(inline) => {
                fragment_prepass(ctx, &inline.selection_set, sel_path, stack)?;
            }
        }
    }
    Ok(())
}

fn variable_prepass(ctx: &Ctx, set: &ASelSet) -> GResult<()> {
    fn mark_value(ctx: &Ctx, v: &AValue) -> GResult<()> {
        match v {
            q::Value::Variable(name) => {
                if !ctx.vars.contains_key(name.as_str()) {
                    return Err(verr("$", format!("unbound variable \"{name}\"")));
                }
                ctx.mark_used(name);
            }
            q::Value::List(items) => {
                for item in items {
                    mark_value(ctx, item)?;
                }
            }
            q::Value::Object(map) => {
                for value in map.values() {
                    mark_value(ctx, value)?;
                }
            }
            _ => {}
        }
        Ok(())
    }
    fn mark_directives(ctx: &Ctx, dirs: &[ADirective]) -> GResult<()> {
        for d in dirs {
            for (_, v) in &d.arguments {
                mark_value(ctx, v)?;
            }
        }
        Ok(())
    }
    for item in &set.items {
        match item {
            q::Selection::Field(f) => {
                for (_, v) in &f.arguments {
                    mark_value(ctx, v)?;
                }
                mark_directives(ctx, &f.directives)?;
                variable_prepass(ctx, &f.selection_set)?;
            }
            q::Selection::FragmentSpread(spread) => {
                mark_directives(ctx, &spread.directives)?;
                if let Some(frag) = ctx.fragments.get(spread.fragment_name.as_str()) {
                    variable_prepass(ctx, &frag.selection_set)?;
                }
            }
            q::Selection::InlineFragment(inline) => {
                mark_directives(ctx, &inline.directives)?;
                variable_prepass(ctx, &inline.selection_set)?;
            }
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Selection walking: directives, fragments, field merging
// ---------------------------------------------------------------------------

struct Flat<'a> {
    key: String,
    name: &'a str,
    args: &'a [(String, AValue)],
    sel_sets: Vec<&'a ASelSet>,
    had_selection: bool,
}

/// Evaluates @include/@skip (with variables) on a selection item. Returns
/// false when the item must be dropped. Unknown/duplicate directives and
/// bad `if` arguments error with paths anchored at the enclosing
/// selection set, matching Hasura.
fn eval_directives<'a>(ctx: &'a Ctx<'a>, dirs: &'a [ADirective], sel_path: &str) -> GResult<bool> {
    if dirs.is_empty() {
        return Ok(true);
    }
    let mut seen: Vec<&str> = Vec::new();
    let mut dups: Vec<&str> = Vec::new();
    for d in dirs {
        let name = d.name.as_str();
        if seen.contains(&name) {
            if !dups.contains(&name) {
                dups.push(name);
            }
        } else {
            seen.push(name);
        }
    }
    if !dups.is_empty() {
        let list = dups
            .iter()
            .map(|n| format!("'{n}'"))
            .collect::<Vec<_>>()
            .join(", ");
        return Err(verr(
            sel_path,
            format!("the following directives are used more than once: [{list}]"),
        ));
    }

    let mut include = true;
    for d in dirs {
        let name = d.name.as_str();
        match name {
            "include" | "skip" => {
                for (arg, _) in &d.arguments {
                    if arg != "if" {
                        return Err(verr(
                            format!("{sel_path}.{name}"),
                            format!("'{name}' has no argument named '{arg}'"),
                        ));
                    }
                }
                let if_path = format!("{sel_path}.{name}.args.if");
                let Some((_, raw)) = d.arguments.iter().find(|(a, _)| a == "if") else {
                    return Err(verr(if_path, "missing required field 'if'"));
                };
                let loc_ty = TypeRef::non_null(TypeRef::named("Boolean"));
                let v = ctx.resolve(raw, &loc_ty, false, &if_path)?;
                let cond = coerce_bool_strict(v, &if_path)?;
                match name {
                    "include" if !cond => include = false,
                    "skip" if cond => include = false,
                    _ => {}
                }
            }
            "cached" => {
                return Err(verr(
                    sel_path,
                    "directive 'cached' is not allowed on a field",
                ));
            }
            other => {
                return Err(verr(
                    sel_path,
                    format!("directive '{other}' is not defined in the schema"),
                ));
            }
        }
    }
    Ok(include)
}

fn collect_fields<'a>(
    ctx: &'a Ctx<'a>,
    type_name: &str,
    sets: &[&'a ASelSet],
    sel_path: &str,
) -> GResult<Vec<Flat<'a>>> {
    let mut out: Vec<Flat<'a>> = Vec::new();
    let mut index: HashMap<String, usize> = HashMap::new();
    for set in sets {
        collect_into(ctx, type_name, set, sel_path, &mut out, &mut index)?;
    }
    Ok(out)
}

fn collect_into<'a>(
    ctx: &'a Ctx<'a>,
    type_name: &str,
    set: &'a ASelSet,
    sel_path: &str,
    out: &mut Vec<Flat<'a>>,
    index: &mut HashMap<String, usize>,
) -> GResult<()> {
    for item in &set.items {
        match item {
            q::Selection::Field(f) => {
                if !eval_directives(ctx, &f.directives, sel_path)? {
                    continue;
                }
                let key = f.alias.clone().unwrap_or_else(|| f.name.clone());
                match index.get(&key) {
                    Some(&i) => {
                        let existing = &mut out[i];
                        if existing.name != f.name {
                            return Err(verr(
                                sel_path,
                                format!(
                                    "selection of both '{}' and '{}' specify the same response name, '{}'",
                                    existing.name, f.name, key
                                ),
                            ));
                        }
                        if !args_equal(existing.args, &f.arguments) {
                            return Err(verr(
                                sel_path,
                                format!(
                                    "inconsistent arguments between multiple selections of field '{}'",
                                    f.name
                                ),
                            ));
                        }
                        if !f.selection_set.items.is_empty() {
                            existing.sel_sets.push(&f.selection_set);
                            existing.had_selection = true;
                        }
                    }
                    None => {
                        index.insert(key.clone(), out.len());
                        let had_selection = !f.selection_set.items.is_empty();
                        out.push(Flat {
                            key,
                            name: &f.name,
                            args: &f.arguments,
                            sel_sets: if had_selection {
                                vec![&f.selection_set]
                            } else {
                                vec![]
                            },
                            had_selection,
                        });
                    }
                }
            }
            q::Selection::FragmentSpread(spread) => {
                if !eval_directives(ctx, &spread.directives, sel_path)? {
                    continue;
                }
                let Some(frag) = ctx.fragments.get(spread.fragment_name.as_str()) else {
                    return Err(verr(
                        sel_path,
                        format!(
                            "reference to undefined fragment \"{}\"",
                            spread.fragment_name
                        ),
                    ));
                };
                // Non-matching (or unknown) type conditions drop the
                // fragment silently, as Hasura does.
                let q::TypeCondition::On(cond) = &frag.type_condition;
                if cond == type_name {
                    collect_into(ctx, type_name, &frag.selection_set, sel_path, out, index)?;
                }
            }
            q::Selection::InlineFragment(inline) => {
                if !eval_directives(ctx, &inline.directives, sel_path)? {
                    continue;
                }
                let matches = match &inline.type_condition {
                    None => true,
                    Some(q::TypeCondition::On(cond)) => cond == type_name,
                };
                if matches {
                    collect_into(ctx, type_name, &inline.selection_set, sel_path, out, index)?;
                }
            }
        }
    }
    Ok(())
}

fn args_equal(a: &[(String, AValue)], b: &[(String, AValue)]) -> bool {
    let to_map =
        |args: &[(String, AValue)]| -> BTreeMap<String, AValue> { args.iter().cloned().collect() };
    to_map(a) == to_map(b)
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
fn plan_admin_mutation(ctx: &Ctx, set: &ASelSet) -> GResult<ir::Operation> {
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
                    if !v.is_null() {
                        let enum_name = format!("{table_name}_select_column");
                        for (i, item) in list_items(v).into_iter().enumerate() {
                            let ipath = format!("{field_path}.args.columns[{i}]");
                            let api = coerce_enum(ctx, item, &enum_name, &ipath)?;
                            columns.push(api_to_db_column(table, &api));
                        }
                    }
                }
                let distinct = match resolve_arg(ctx, flat, field, "distinct", &field_path)? {
                    Some(v) if !v.is_null() => {
                        coerce_bool_strict(v, &format!("{field_path}.args.distinct"))?
                    }
                    _ => false,
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

// ---------------------------------------------------------------------------
// Argument coercion: select args, by_pk, stream
// ---------------------------------------------------------------------------

/// Looks up a provided argument and resolves variables against the
/// argument's declared type. Returns None when the argument was not given.
fn resolve_arg<'a>(
    ctx: &'a Ctx<'a>,
    flat: &Flat<'a>,
    field: &FieldDef,
    name: &str,
    field_path: &str,
) -> GResult<Option<V<'a>>> {
    let Some((_, raw)) = flat.args.iter().find(|(n, _)| n == name) else {
        return Ok(None);
    };
    let ivd = field
        .args
        .iter()
        .find(|a| a.name == name)
        .expect("argument definition must exist after unknown-arg check");
    let path = format!("{field_path}.args.{name}");
    Ok(Some(ctx.resolve(
        raw,
        &ivd.ty,
        ivd.default_value.is_some(),
        &path,
    )?))
}

fn coerce_select_args<'a>(
    ctx: &'a Ctx<'a>,
    flat: &Flat<'a>,
    field: &FieldDef,
    table_name: &str,
    field_path: &str,
    clamp: bool,
) -> GResult<ir::SelectArgs> {
    let table = model_table(ctx, table_name);
    let mut args = ir::SelectArgs::default();

    if let Some(v) = resolve_arg(ctx, flat, field, "where", field_path)? {
        if !v.is_null() {
            let path = format!("{field_path}.args.where");
            args.where_ = Some(coerce_bool_exp(ctx, table_name, v, &path)?);
        }
    }
    if let Some(v) = resolve_arg(ctx, flat, field, "order_by", field_path)? {
        if !v.is_null() {
            let path = format!("{field_path}.args.order_by");
            args.order_by = coerce_order_by(ctx, table_name, v, &path)?;
        }
    }
    if let Some(v) = resolve_arg(ctx, flat, field, "distinct_on", field_path)? {
        if !v.is_null() {
            let enum_name = format!("{table_name}_select_column");
            for (i, item) in list_items(v).into_iter().enumerate() {
                let ipath = format!("{field_path}.args.distinct_on[{i}]");
                let api = coerce_enum(ctx, item, &enum_name, &ipath)?;
                args.distinct_on.push(api_to_db_column(table, &api));
            }
        }
    }
    if let Some(v) = resolve_arg(ctx, flat, field, "limit", field_path)? {
        args.limit = coerce_limit(ctx, v, &format!("{field_path}.args.limit"))?;
    }
    if let Some(v) = resolve_arg(ctx, flat, field, "offset", field_path)? {
        args.offset = coerce_offset(ctx, v, &format!("{field_path}.args.offset"))?;
    }

    if !args.distinct_on.is_empty() && !args.order_by.is_empty() {
        // Hasura: the first N order_by entries (N = distinct_on length,
        // duplicates included) must all be plain columns and must contain
        // every distinct_on column.
        let n = args.distinct_on.len();
        let initial: Vec<&str> = args
            .order_by
            .iter()
            .take(n)
            .filter_map(|item| match &item.target {
                ir::OrderTarget::Column { column } => Some(column.as_str()),
                _ => None,
            })
            .collect();
        let matches = initial.len() == n
            && args
                .distinct_on
                .iter()
                .all(|c| initial.contains(&c.as_str()));
        if !matches {
            return Err(verr(
                format!("{field_path}.args"),
                "\"distinct_on\" columns must match initial \"order_by\" columns",
            ));
        }
    }

    if clamp {
        if let Some(n) = ctx.response_limit {
            args.limit = Some(args.limit.map_or(n, |l| l.min(n)));
        }
    }
    Ok(args)
}

fn coerce_by_pk_args<'a>(
    ctx: &'a Ctx<'a>,
    flat: &Flat<'a>,
    field: &FieldDef,
    table_name: &str,
    field_path: &str,
) -> GResult<Vec<(String, ir::SqlValue)>> {
    let table = model_table(ctx, table_name);
    let mut pk: Vec<(String, ir::SqlValue)> = Vec::new();
    for arg in &field.args {
        let path = format!("{field_path}.args.{}", arg.name);
        let Some(v) = resolve_arg(ctx, flat, field, &arg.name, field_path)? else {
            return Err(verr(path, format!("missing required field '{}'", arg.name)));
        };
        let col = table
            .column_by_api_name(&arg.name)
            .expect("by_pk argument must be a table column");
        let value = coerce_column_value(ctx, col.scalar, &col.pg_type, col.is_array, v, &path)?;
        pk.push((col.db_name.clone(), value));
    }
    Ok(pk)
}

fn coerce_stream_args<'a>(
    ctx: &'a Ctx<'a>,
    flat: &Flat<'a>,
    field: &FieldDef,
    table_name: &str,
    field_path: &str,
) -> GResult<(i64, Vec<ir::StreamCursor>, Option<ir::BoolExp>)> {
    let batch_path = format!("{field_path}.args.batch_size");
    let mut batch_size = match resolve_arg(ctx, flat, field, "batch_size", field_path)? {
        Some(v) => coerce_limit(ctx, v, &batch_path)?
            .ok_or_else(|| verr(&batch_path, "unexpected null value for type 'Int'"))?,
        None => return Err(verr(batch_path, "missing required field 'batch_size'")),
    };
    if let Some(n) = ctx.response_limit {
        batch_size = batch_size.min(n);
    }

    let cursor_path = format!("{field_path}.args.cursor");
    let Some(cursor_v) = resolve_arg(ctx, flat, field, "cursor", field_path)? else {
        return Err(verr(cursor_path, "missing required field 'cursor'"));
    };
    let mut cursor: Vec<ir::StreamCursor> = Vec::new();
    let table = model_table(ctx, table_name);
    for (i, item) in list_items(cursor_v).into_iter().enumerate() {
        if item.is_null() {
            continue;
        }
        let ipath = format!("{cursor_path}[{i}]");
        let input_type = format!("{table_name}_stream_cursor_input");
        let entries = expect_object(item, &input_type, &ipath)?;
        let type_def = ctx.registry.get(&input_type);
        let mut initial: Option<V> = None;
        let mut descending = false;
        for (key, value) in &entries {
            let Some(fd) = type_def.and_then(|d| d.input_field(key)) else {
                return Err(verr(
                    format!("{ipath}.{key}"),
                    format!("field '{key}' not found in type: '{input_type}'"),
                ));
            };
            let vpath = format!("{ipath}.{key}");
            let v = resolve_nested(ctx, *value, &fd.ty, fd.default_value.is_some(), &vpath)?;
            match key.as_str() {
                "initial_value" => initial = Some(v),
                "ordering" => {
                    if !v.is_null() {
                        let dir = coerce_enum(ctx, v, "cursor_ordering", &vpath)?;
                        descending = dir == "DESC";
                    }
                }
                _ => {}
            }
        }
        let init_path = format!("{ipath}.initial_value");
        let Some(initial) = initial else {
            return Err(verr(init_path, "missing required field 'initial_value'"));
        };
        let value_type = format!("{table_name}_stream_cursor_value_input");
        let value_def = ctx.registry.get(&value_type);
        let cols = expect_object(initial, &value_type, &init_path)?;
        for (key, value) in ordered_keys(table, cols) {
            let Some(fd) = value_def.and_then(|d| d.input_field(&key)) else {
                return Err(verr(
                    format!("{init_path}.{key}"),
                    format!("field '{key}' not found in type: '{value_type}'"),
                ));
            };
            let vpath = format!("{init_path}.{key}");
            let v = resolve_nested(ctx, value, &fd.ty, fd.default_value.is_some(), &vpath)?;
            let col = table
                .column_by_api_name(&key)
                .expect("cursor value input field must be a table column");
            let initial_value = if v.is_null() {
                None
            } else {
                Some(coerce_column_value(
                    ctx,
                    col.scalar,
                    &col.pg_type,
                    col.is_array,
                    v,
                    &vpath,
                )?)
            };
            cursor.push(ir::StreamCursor {
                column: col.db_name.clone(),
                scalar: col.scalar,
                pg_type: col.pg_type.clone(),
                is_array: col.is_array,
                initial_value,
                descending,
            });
        }
    }

    let mut where_ = None;
    if let Some(v) = resolve_arg(ctx, flat, field, "where", field_path)? {
        if !v.is_null() {
            let path = format!("{field_path}.args.where");
            where_ = Some(coerce_bool_exp(ctx, table_name, v, &path)?);
        }
    }
    Ok((batch_size, cursor, where_))
}

/// json/jsonb column `path` argument.
fn coerce_json_path_arg<'a>(
    ctx: &'a Ctx<'a>,
    flat: &Flat<'a>,
    field: &FieldDef,
    field_path: &str,
) -> GResult<Option<Vec<String>>> {
    let Some(v) = resolve_arg(ctx, flat, field, "path", field_path)? else {
        return Ok(None);
    };
    if v.is_null() {
        return Ok(None);
    }
    let text = coerce_string_strict(v, &format!("{field_path}.args.path"))?;
    match parse_json_path(&text) {
        Ok(segments) => Ok(if segments.is_empty() {
            None
        } else {
            Some(segments)
        }),
        Err(()) => Err(verr(
            format!("{field_path}.args"),
            format!(
                "parse json path error: {text}. Accept letters, digits, underscore (_) or hyphen (-) only. Use quotes enclosed in bracket ([\"...\"]) if there is any special character"
            ),
        )),
    }
}

// ---------------------------------------------------------------------------
// Nested value plumbing
// ---------------------------------------------------------------------------

/// Resolves one nesting level: literals may contain variables, JSON values
/// stay JSON all the way down.
fn resolve_nested<'a>(
    ctx: &'a Ctx<'a>,
    v: V<'a>,
    loc_ty: &TypeRef,
    loc_has_default: bool,
    path: &str,
) -> GResult<V<'a>> {
    match v {
        V::L(l) => ctx.resolve(l, loc_ty, loc_has_default, path),
        j => Ok(j),
    }
}

/// List coercion: single non-null values coerce to one-element lists.
fn list_items<'a>(v: V<'a>) -> Vec<V<'a>> {
    match v {
        V::L(q::Value::List(items)) => items.iter().map(V::L).collect(),
        V::J(Json::Array(items)) => items.iter().map(V::J).collect(),
        single => vec![single],
    }
}

fn expect_list<'a>(v: V<'a>, path: &str) -> GResult<Vec<V<'a>>> {
    if v.is_null() {
        return Err(verr(path, "expected a list, but found null"));
    }
    Ok(list_items(v))
}

/// Sorted (key, value) entries of an input object, with the standard
/// "expected an object" error otherwise.
fn expect_object<'a>(v: V<'a>, type_name: &str, path: &str) -> GResult<Vec<(String, V<'a>)>> {
    match v {
        V::L(q::Value::Object(map)) => {
            Ok(map.iter().map(|(k, val)| (k.clone(), V::L(val))).collect())
        }
        V::J(Json::Object(map)) => Ok(map.iter().map(|(k, val)| (k.clone(), V::J(val))).collect()),
        other => Err(verr(
            path,
            format!(
                "expected an object for type '{type_name}', but found {}",
                found_desc(other)
            ),
        )),
    }
}

/// Reorders input-object keys: primary-key columns first (in key order),
/// then the rest alphabetically. Hasura's processing order is its HashMap's
/// hash order, which cannot be reproduced; this matches every order the
/// oracle snapshots pin.
fn ordered_keys<'a>(table: &Table, entries: Vec<(String, V<'a>)>) -> Vec<(String, V<'a>)> {
    let pk_apis: Vec<&str> = table
        .primary_key
        .iter()
        .filter_map(|db| table.columns.iter().find(|c| &c.db_name == db))
        .map(|c| c.api_name.as_str())
        .collect();
    let mut front: Vec<(String, V)> = Vec::new();
    let mut rest: Vec<(String, V)> = Vec::new();
    for entry in entries {
        if pk_apis.contains(&entry.0.as_str()) {
            front.push(entry);
        } else {
            rest.push(entry);
        }
    }
    front.sort_by_key(|(k, _)| pk_apis.iter().position(|p| p == k));
    front.extend(rest);
    front
}

fn api_to_db_column(table: &Table, api_name: &str) -> String {
    table
        .column_by_api_name(api_name)
        .map(|c| c.db_name.clone())
        .unwrap_or_else(|| api_name.to_string())
}

// ---------------------------------------------------------------------------
// order_by coercion
// ---------------------------------------------------------------------------

fn order_direction(name: &str) -> ir::OrderDirection {
    match name {
        "asc" => ir::OrderDirection::Asc,
        "asc_nulls_first" => ir::OrderDirection::AscNullsFirst,
        "asc_nulls_last" => ir::OrderDirection::AscNullsLast,
        "desc" => ir::OrderDirection::Desc,
        "desc_nulls_first" => ir::OrderDirection::DescNullsFirst,
        _ => ir::OrderDirection::DescNullsLast,
    }
}

fn coerce_order_by<'a>(
    ctx: &'a Ctx<'a>,
    table_name: &str,
    v: V<'a>,
    base_path: &str,
) -> GResult<Vec<ir::OrderByItem>> {
    let mut out: Vec<ir::OrderByItem> = Vec::new();
    let elem_ty = TypeRef::non_null(TypeRef::named(&format!("{table_name}_order_by")));
    for (i, item) in list_items(v).into_iter().enumerate() {
        let ipath = format!("{base_path}[{i}]");
        let item = resolve_item(ctx, item, &elem_ty, &ipath)?;
        let mut chain: Vec<(String, String)> = Vec::new();
        expand_order_object(ctx, table_name, item, &ipath, &mut chain, &mut out)?;
    }
    Ok(out)
}

fn resolve_item<'a>(ctx: &'a Ctx<'a>, v: V<'a>, elem_ty: &TypeRef, path: &str) -> GResult<V<'a>> {
    match v {
        V::L(l) => ctx.resolve(l, elem_ty, false, path),
        j => Ok(j),
    }
}

fn expand_order_object<'a>(
    ctx: &'a Ctx<'a>,
    table_name: &str,
    v: V<'a>,
    path: &str,
    chain: &mut Vec<(String, String)>,
    out: &mut Vec<ir::OrderByItem>,
) -> GResult<()> {
    let type_name = format!("{table_name}_order_by");
    let entries = expect_object(v, &type_name, path)?;
    let table = model_table(ctx, table_name);
    let type_def = ctx.registry.get(&type_name);
    for (key, value) in ordered_keys(table, entries) {
        let kpath = format!("{path}.{key}");
        let Some(fd) = type_def.and_then(|d| d.input_field(&key)) else {
            return Err(verr(
                kpath,
                format!("field '{key}' not found in type: '{type_name}'"),
            ));
        };
        let value = resolve_nested(ctx, value, &fd.ty, fd.default_value.is_some(), &kpath)?;
        if value.is_null() {
            continue;
        }
        if let Some(col) = table.column_by_api_name(&key) {
            let dir = coerce_enum(ctx, value, "order_by", &kpath)?;
            let target = if chain.is_empty() {
                ir::OrderTarget::Column {
                    column: col.db_name.clone(),
                }
            } else {
                ir::OrderTarget::ObjectRelColumn {
                    path: chain.clone(),
                    column: col.db_name.clone(),
                }
            };
            out.push(ir::OrderByItem {
                target,
                direction: order_direction(&dir),
            });
        } else if let Some(rel) = table.object_relationships.iter().find(|r| r.name == key) {
            chain.push((rel.local_db_column.clone(), rel.remote_table.clone()));
            expand_order_object(ctx, &rel.remote_table, value, &kpath, chain, out)?;
            chain.pop();
        } else if let Some(rel) = key
            .strip_suffix("_aggregate")
            .and_then(|base| table.array_relationships.iter().find(|r| r.name == base))
        {
            expand_aggregate_order(ctx, rel, value, &kpath, chain, out)?;
        } else {
            return Err(verr(
                kpath,
                format!("field '{key}' not found in type: '{type_name}'"),
            ));
        }
    }
    Ok(())
}

fn expand_aggregate_order<'a>(
    ctx: &'a Ctx<'a>,
    rel: &crate::serve::model::ArrayRelationship,
    v: V<'a>,
    path: &str,
    chain: &[(String, String)],
    out: &mut Vec<ir::OrderByItem>,
) -> GResult<()> {
    let remote = model_table(ctx, &rel.remote_table);
    let type_name = format!("{}_aggregate_order_by", rel.remote_table);
    let type_def = ctx.registry.get(&type_name);
    for (op, value) in expect_object(v, &type_name, path)? {
        let opath = format!("{path}.{op}");
        let Some(fd) = type_def.and_then(|d| d.input_field(&op)) else {
            return Err(verr(
                opath,
                format!("field '{op}' not found in type: '{type_name}'"),
            ));
        };
        let value = resolve_nested(ctx, value, &fd.ty, fd.default_value.is_some(), &opath)?;
        if value.is_null() {
            continue;
        }
        if op == "count" {
            let dir = coerce_enum(ctx, value, "order_by", &opath)?;
            out.push(ir::OrderByItem {
                target: ir::OrderTarget::ArrayRelAggregate {
                    path: chain.to_vec(),
                    remote_column: rel.remote_db_column.clone(),
                    remote_table: rel.remote_table.clone(),
                    op: "count".to_string(),
                    column: None,
                },
                direction: order_direction(&dir),
            });
        } else {
            let col_type = format!("{}_{op}_order_by", rel.remote_table);
            let col_def = ctx.registry.get(&col_type);
            for (col_key, col_value) in expect_object(value, &col_type, &opath)? {
                let cpath = format!("{opath}.{col_key}");
                let Some(cfd) = col_def.and_then(|d| d.input_field(&col_key)) else {
                    return Err(verr(
                        cpath,
                        format!("field '{col_key}' not found in type: '{col_type}'"),
                    ));
                };
                let col_value =
                    resolve_nested(ctx, col_value, &cfd.ty, cfd.default_value.is_some(), &cpath)?;
                if col_value.is_null() {
                    continue;
                }
                let dir = coerce_enum(ctx, col_value, "order_by", &cpath)?;
                let col = remote
                    .column_by_api_name(&col_key)
                    .expect("aggregate order_by field must be a column");
                out.push(ir::OrderByItem {
                    target: ir::OrderTarget::ArrayRelAggregate {
                        path: chain.to_vec(),
                        remote_column: rel.remote_db_column.clone(),
                        remote_table: rel.remote_table.clone(),
                        op: op.clone(),
                        column: Some(col.db_name.clone()),
                    },
                    direction: order_direction(&dir),
                });
            }
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// bool_exp coercion
// ---------------------------------------------------------------------------

fn coerce_bool_exp<'a>(
    ctx: &'a Ctx<'a>,
    table_name: &str,
    v: V<'a>,
    path: &str,
) -> GResult<ir::BoolExp> {
    let type_name = format!("{table_name}_bool_exp");
    let entries = expect_object(v, &type_name, path)?;
    let table = model_table(ctx, table_name);
    let type_def = ctx.registry.get(&type_name);

    let mut parts: Vec<ir::BoolExp> = Vec::new();
    for (key, value) in entries {
        let kpath = format!("{path}.{key}");
        let Some(fd) = type_def.and_then(|d| d.input_field(&key)) else {
            return Err(verr(
                kpath,
                format!("field '{key}' not found in type: '{type_name}'"),
            ));
        };
        let value = resolve_nested(ctx, value, &fd.ty, fd.default_value.is_some(), &kpath)?;
        match key.as_str() {
            "_and" | "_or" => {
                let items = expect_list(value, &kpath)?;
                let mut inner: Vec<ir::BoolExp> = Vec::new();
                for (i, item) in items.into_iter().enumerate() {
                    let ipath = format!("{kpath}[{i}]");
                    let elem_ty = TypeRef::non_null(TypeRef::named(&type_name));
                    let item = resolve_item(ctx, item, &elem_ty, &ipath)?;
                    inner.push(coerce_bool_exp(ctx, table_name, item, &ipath)?);
                }
                parts.push(if key == "_and" {
                    ir::BoolExp::And(inner)
                } else {
                    ir::BoolExp::Or(inner)
                });
            }
            "_not" => {
                let inner = coerce_bool_exp(ctx, table_name, value, &kpath)?;
                parts.push(ir::BoolExp::Not(Box::new(inner)));
            }
            _ => {
                if let Some(col) = table.column_by_api_name(&key) {
                    let ops = coerce_comparison(ctx, col, value, &kpath)?;
                    for op in ops {
                        parts.push(ir::BoolExp::Compare {
                            column: col.db_name.clone(),
                            scalar: col.scalar,
                            pg_type: col.pg_type.clone(),
                            is_array: col.is_array,
                            op,
                        });
                    }
                } else if let Some(rel) = table.object_relationships.iter().find(|r| r.name == key)
                {
                    let inner = coerce_bool_exp(ctx, &rel.remote_table, value, &kpath)?;
                    parts.push(ir::BoolExp::ObjectRel {
                        local_column: rel.local_db_column.clone(),
                        remote_table: rel.remote_table.clone(),
                        exp: Box::new(inner),
                    });
                } else if let Some(rel) = table.array_relationships.iter().find(|r| r.name == key) {
                    let inner = coerce_bool_exp(ctx, &rel.remote_table, value, &kpath)?;
                    parts.push(ir::BoolExp::ArrayRel {
                        remote_column: rel.remote_db_column.clone(),
                        remote_table: rel.remote_table.clone(),
                        exp: Box::new(inner),
                    });
                } else if let Some(rel) = key
                    .strip_suffix("_aggregate")
                    .and_then(|base| table.array_relationships.iter().find(|r| r.name == base))
                {
                    let preds = coerce_aggregate_bool_exp(ctx, rel, value, &kpath)?;
                    parts.extend(preds);
                } else {
                    return Err(verr(
                        kpath,
                        format!("field '{key}' not found in type: '{type_name}'"),
                    ));
                }
            }
        }
    }
    Ok(if parts.len() == 1 {
        parts.pop().unwrap()
    } else {
        ir::BoolExp::And(parts)
    })
}

// ---------------------------------------------------------------------------
// Comparison expressions
// ---------------------------------------------------------------------------

fn comparison_type_name(scalar: Scalar, pg_type: &str, is_array: bool) -> String {
    let s = scalar.gql_name(pg_type);
    if is_array {
        format!("{s}_array_comparison_exp")
    } else {
        format!("{s}_comparison_exp")
    }
}

fn coerce_comparison<'a>(
    ctx: &'a Ctx<'a>,
    col: &Column,
    v: V<'a>,
    path: &str,
) -> GResult<Vec<ir::CompareOp>> {
    let type_name = comparison_type_name(col.scalar, &col.pg_type, col.is_array);
    coerce_comparison_ops(
        ctx,
        col.scalar,
        &col.pg_type,
        col.is_array,
        &type_name,
        v,
        path,
    )
}

fn coerce_comparison_ops<'a>(
    ctx: &'a Ctx<'a>,
    scalar: Scalar,
    pg_type: &str,
    is_array: bool,
    type_name: &str,
    v: V<'a>,
    path: &str,
) -> GResult<Vec<ir::CompareOp>> {
    let entries = expect_object(v, type_name, path)?;
    let type_def = ctx.registry.get(type_name);

    let mut ops: Vec<ir::CompareOp> = Vec::new();
    for (op, value) in entries {
        let opath = format!("{path}.{op}");
        // The registry defines exactly which operators exist per scalar;
        // when the comparison type itself is absent (e.g. Int predicates
        // with no int column anywhere), fall back to accepting the op.
        if let Some(def) = type_def {
            if def.input_field(&op).is_none() {
                return Err(verr(
                    opath,
                    format!("field '{op}' not found in type: '{type_name}'"),
                ));
            }
        }
        let loc = type_def.and_then(|d| d.input_field(&op));
        let value = match loc {
            Some(fd) => resolve_nested(ctx, value, &fd.ty, fd.default_value.is_some(), &opath)?,
            None => value,
        };
        let scalar_value =
            |v: V<'a>, p: &str| coerce_column_value(ctx, scalar, pg_type, is_array, v, p);
        let list_value = |v: V<'a>, p: &str| -> GResult<Vec<ir::SqlValue>> {
            let items = expect_list(v, p)?;
            let mut out = Vec::new();
            for (i, item) in items.into_iter().enumerate() {
                out.push(scalar_value(item, &format!("{p}[{i}]"))?);
            }
            Ok(out)
        };
        let compare = match op.as_str() {
            "_eq" => ir::CompareOp::Eq(scalar_value(value, &opath)?),
            "_neq" => ir::CompareOp::Neq(scalar_value(value, &opath)?),
            "_gt" => ir::CompareOp::Gt(scalar_value(value, &opath)?),
            "_gte" => ir::CompareOp::Gte(scalar_value(value, &opath)?),
            "_lt" => ir::CompareOp::Lt(scalar_value(value, &opath)?),
            "_lte" => ir::CompareOp::Lte(scalar_value(value, &opath)?),
            "_in" => ir::CompareOp::In(list_value(value, &opath)?),
            "_nin" => ir::CompareOp::Nin(list_value(value, &opath)?),
            "_is_null" => ir::CompareOp::IsNull(coerce_bool_strict(value, &opath)?),
            "_like" => ir::CompareOp::Like(scalar_value(value, &opath)?),
            "_nlike" => ir::CompareOp::Nlike(scalar_value(value, &opath)?),
            "_ilike" => ir::CompareOp::Ilike(scalar_value(value, &opath)?),
            "_nilike" => ir::CompareOp::Nilike(scalar_value(value, &opath)?),
            "_similar" => ir::CompareOp::Similar(scalar_value(value, &opath)?),
            "_nsimilar" => ir::CompareOp::Nsimilar(scalar_value(value, &opath)?),
            "_regex" => ir::CompareOp::Regex(scalar_value(value, &opath)?),
            "_iregex" => ir::CompareOp::Iregex(scalar_value(value, &opath)?),
            "_nregex" => ir::CompareOp::Nregex(scalar_value(value, &opath)?),
            "_niregex" => ir::CompareOp::Niregex(scalar_value(value, &opath)?),
            "_contains" => ir::CompareOp::Contains(scalar_value(value, &opath)?),
            "_contained_in" => ir::CompareOp::ContainedIn(scalar_value(value, &opath)?),
            "_has_key" => {
                let s = coerce_string_strict(value, &opath)?;
                ir::CompareOp::HasKey(ir::SqlValue::new(s, "text"))
            }
            "_has_keys_all" | "_has_keys_any" => {
                let items = expect_list(value, &opath)?;
                let mut out = Vec::new();
                for (i, item) in items.into_iter().enumerate() {
                    let s = coerce_string_strict(item, &format!("{opath}[{i}]"))?;
                    out.push(ir::SqlValue::new(s, "text"));
                }
                if op == "_has_keys_all" {
                    ir::CompareOp::HasKeysAll(out)
                } else {
                    ir::CompareOp::HasKeysAny(out)
                }
            }
            "_cast" => {
                let cast_entries = expect_object(value, "jsonb_cast_exp", &opath)?;
                let mut inner: Vec<ir::CompareOp> = Vec::new();
                for (ck, cv) in cast_entries {
                    let cpath = format!("{opath}.{ck}");
                    if ck != "String" {
                        return Err(verr(
                            cpath,
                            format!("field '{ck}' not found in type: 'jsonb_cast_exp'"),
                        ));
                    }
                    let text_ops = coerce_comparison_ops(
                        ctx,
                        Scalar::String,
                        "text",
                        false,
                        "String_comparison_exp",
                        cv,
                        &cpath,
                    )?;
                    inner.extend(text_ops);
                }
                ir::CompareOp::CastText(inner)
            }
            other => {
                return Err(verr(
                    opath,
                    format!("field '{other}' not found in type: '{type_name}'"),
                ));
            }
        };
        ops.push(compare);
    }
    Ok(ops)
}

// ---------------------------------------------------------------------------
// Aggregate predicates in bool_exp
// ---------------------------------------------------------------------------

fn coerce_aggregate_bool_exp<'a>(
    ctx: &'a Ctx<'a>,
    rel: &crate::serve::model::ArrayRelationship,
    v: V<'a>,
    path: &str,
) -> GResult<Vec<ir::BoolExp>> {
    let rt = &rel.remote_table;
    let type_name = format!("{rt}_aggregate_bool_exp");
    let type_def = ctx.registry.get(&type_name);
    let remote = model_table(ctx, rt);

    let mut out: Vec<ir::BoolExp> = Vec::new();
    for (op, value) in expect_object(v, &type_name, path)? {
        let opath = format!("{path}.{op}");
        let Some(fd) = type_def.and_then(|d| d.input_field(&op)) else {
            return Err(verr(
                opath,
                format!("field '{op}' not found in type: '{type_name}'"),
            ));
        };
        let value = resolve_nested(ctx, value, &fd.ty, fd.default_value.is_some(), &opath)?;
        let inner_type = format!("{rt}_aggregate_bool_exp_{op}");
        let inner_def = ctx.registry.get(&inner_type);
        let entries = expect_object(value, &inner_type, &opath)?;

        let mut columns: Vec<String> = Vec::new();
        let mut distinct = false;
        let mut filter: Option<Box<ir::BoolExp>> = None;
        let mut predicate: Option<Vec<ir::CompareOp>> = None;
        let mut has_arguments = false;
        for (key, kv) in entries {
            let kpath = format!("{opath}.{key}");
            let Some(kfd) = inner_def.and_then(|d| d.input_field(&key)) else {
                return Err(verr(
                    kpath,
                    format!("field '{key}' not found in type: '{inner_type}'"),
                ));
            };
            let kv = resolve_nested(ctx, kv, &kfd.ty, kfd.default_value.is_some(), &kpath)?;
            match key.as_str() {
                "arguments" => {
                    has_arguments = true;
                    if kv.is_null() {
                        continue;
                    }
                    if op == "count" {
                        let enum_name = format!("{rt}_select_column");
                        for (i, item) in list_items(kv).into_iter().enumerate() {
                            let ipath = format!("{kpath}[{i}]");
                            let api = coerce_enum(ctx, item, &enum_name, &ipath)?;
                            columns.push(api_to_db_column(remote, &api));
                        }
                    } else {
                        let enum_name = format!(
                            "{rt}_select_column_{rt}_aggregate_bool_exp_{op}_arguments_columns"
                        );
                        let api = coerce_enum(ctx, kv, &enum_name, &kpath)?;
                        columns.push(api_to_db_column(remote, &api));
                    }
                }
                "distinct" => {
                    if !kv.is_null() {
                        distinct = coerce_bool_strict(kv, &kpath)?;
                    }
                }
                "filter" => {
                    if !kv.is_null() {
                        filter = Some(Box::new(coerce_bool_exp(ctx, rt, kv, &kpath)?));
                    }
                }
                "predicate" => {
                    let (scalar, pg, cmp) = if op == "count" {
                        (Scalar::Int, "int4", "Int_comparison_exp")
                    } else {
                        (Scalar::Boolean, "bool", "Boolean_comparison_exp")
                    };
                    predicate = Some(coerce_comparison_ops(
                        ctx, scalar, pg, false, cmp, kv, &kpath,
                    )?);
                }
                _ => {}
            }
        }
        let Some(predicate) = predicate else {
            return Err(verr(
                format!("{opath}.predicate"),
                "missing required field 'predicate'",
            ));
        };
        if op != "count" && !has_arguments {
            return Err(verr(
                format!("{opath}.arguments"),
                "missing required field 'arguments'",
            ));
        }
        out.push(ir::BoolExp::ArrayRelAggregate {
            remote_column: rel.remote_db_column.clone(),
            remote_table: rt.clone(),
            pred: ir::AggregatePredicate {
                op: op.clone(),
                columns,
                distinct,
                filter,
                predicate,
            },
        });
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// Strict (GraphQL-native) scalar coercion
// ---------------------------------------------------------------------------

fn coerce_bool_strict(v: V, path: &str) -> GResult<bool> {
    match v {
        V::L(q::Value::Boolean(b)) => Ok(*b),
        V::J(Json::Bool(b)) => Ok(*b),
        other => Err(verr(
            path,
            format!(
                "expected a boolean for type 'Boolean', but found {}",
                found_desc(other)
            ),
        )),
    }
}

fn coerce_string_strict(v: V, path: &str) -> GResult<String> {
    match v {
        V::L(q::Value::String(s)) => Ok(s.clone()),
        V::J(Json::String(s)) => Ok(s.clone()),
        other => Err(verr(
            path,
            format!(
                "expected a string for type 'String', but found {}",
                found_desc(other)
            ),
        )),
    }
}

/// Enum value coercion: GraphQL enum literals and JSON strings are valid,
/// string literals are not.
fn coerce_enum(ctx: &Ctx, v: V, enum_type: &str, path: &str) -> GResult<String> {
    let name = match v {
        V::L(q::Value::Enum(n)) => n.clone(),
        V::J(Json::String(n)) => n.clone(),
        V::L(q::Value::String(_)) => {
            return Err(verr(
                path,
                format!("expected an enum value for type '{enum_type}', but found a string"),
            ));
        }
        other => {
            return Err(verr(
                path,
                format!(
                    "expected an enum value for type '{enum_type}', but found {}",
                    found_desc(other)
                ),
            ));
        }
    };
    let values = enum_values_for_message(ctx, enum_type);
    if values.iter().any(|value| value == &name) {
        Ok(name)
    } else {
        let list = values
            .iter()
            .map(|value| format!("'{value}'"))
            .collect::<Vec<_>>()
            .join(", ");
        Err(verr(
            path,
            format!(
                "expected one of the values [{list}] for type '{enum_type}', but found '{name}'"
            ),
        ))
    }
}

/// Enum values in Hasura's HashMap-driven order: for select-column enums the
/// primary key comes first (which is all the snapshots pin); everything else
/// keeps registry (alphabetical) order.
fn enum_values_for_message(ctx: &Ctx, enum_type: &str) -> Vec<String> {
    let registry_values: Vec<String> = match ctx.registry.get(enum_type) {
        Some(TypeDef::Enum { values, .. }) => values.iter().map(|v| v.name.clone()).collect(),
        _ => vec![],
    };
    let Some(table) = enum_type
        .strip_suffix("_select_column")
        .and_then(|t| ctx.model.table(t))
    else {
        return registry_values;
    };
    let pk_apis: Vec<&str> = table
        .primary_key
        .iter()
        .filter_map(|db| table.columns.iter().find(|c| &c.db_name == db))
        .map(|c| c.api_name.as_str())
        .collect();
    let mut out: Vec<String> = pk_apis
        .iter()
        .filter(|pk| registry_values.iter().any(|v| v == *pk))
        .map(|pk| pk.to_string())
        .collect();
    for v in registry_values {
        if !pk_apis.contains(&v.as_str()) {
            out.push(v);
        }
    }
    out
}

/// Numeric value under coercion, keeping the original decimal text for
/// literals that overflow i64 so error displays and SQL keep full precision.
enum Num {
    Small(i64),
    Big(String),
    Float(f64),
}

fn numeric_of(ctx: &Ctx, v: V) -> Option<Num> {
    match v {
        V::L(q::Value::Int(n)) => {
            let n = n.as_i64().unwrap_or(0);
            Some(match ctx.int_originals.get(&n) {
                Some(orig) => Num::Big(orig.clone()),
                None => Num::Small(n),
            })
        }
        V::L(q::Value::Float(f)) => Some(Num::Float(*f)),
        V::J(Json::Number(n)) => {
            if let Some(i) = n.as_i64() {
                Some(Num::Small(i))
            } else if let Some(u) = n.as_u64() {
                Some(Num::Big(u.to_string()))
            } else {
                n.as_f64().map(Num::Float)
            }
        }
        _ => None,
    }
}

impl Num {
    fn display(&self, ctx: &Ctx) -> String {
        match self {
            Num::Small(n) => hs_scientific_decimal(&n.to_string()),
            Num::Big(s) => hs_scientific_decimal(s),
            Num::Float(f) => {
                if f.is_infinite() {
                    let neg = *f < 0.0;
                    ctx.inf_floats
                        .iter()
                        .find(|s| s.starts_with('-') == neg)
                        .or_else(|| ctx.inf_floats.first())
                        .map(|s| hs_scientific_decimal(s))
                        .unwrap_or_else(|| "Infinity".to_string())
                } else {
                    hs_scientific_decimal(&format!("{f}"))
                }
            }
        }
    }

    /// Integral value within [min, max], or Err(display) Hasura-style.
    fn as_int_bounded(&self, ctx: &Ctx, min: i64, max: i64) -> Result<i64, String> {
        match self {
            Num::Small(n) => {
                if *n >= min && *n <= max {
                    Ok(*n)
                } else {
                    Err(self.display(ctx))
                }
            }
            Num::Big(_) => Err(self.display(ctx)),
            Num::Float(f) => {
                if f.is_finite() && f.fract() == 0.0 && *f >= min as f64 && *f <= max as f64 {
                    Ok(*f as i64)
                } else {
                    Err(self.display(ctx))
                }
            }
        }
    }

    /// SQL text form (full precision for oversized literals).
    fn sql_text(&self) -> String {
        match self {
            Num::Small(n) => n.to_string(),
            Num::Big(s) => s.clone(),
            Num::Float(f) => format!("{f}"),
        }
    }
}

/// `limit` (and stream `batch_size`): non-negative 32-bit Int. GraphQL
/// float literals are a kind error; JSON numbers go through scientific
/// bounds checking (so 1.5 reports the bounds message instead).
fn coerce_limit(ctx: &Ctx, v: V, path: &str) -> GResult<Option<i64>> {
    if v.is_null() {
        return Ok(None);
    }
    let kind_err = |found: &str| {
        verr(
            path,
            format!("expected a non-negative 32-bit integer for type 'Int', but found {found}"),
        )
    };
    let num = match v {
        V::L(q::Value::Int(_)) | V::J(Json::Number(_)) => numeric_of(ctx, v).unwrap(),
        other => return Err(kind_err(found_desc(other))),
    };
    match num.as_int_bounded(ctx, i32::MIN as i64, i32::MAX as i64) {
        Ok(n) if n >= 0 => Ok(Some(n)),
        Ok(_) => Err(kind_err("an integer")),
        Err(display) => Err(int_bounds_error(path, &display)),
    }
}

/// `offset`: 32-bit ints, 64-bit ints, or 64-bit integers as strings
/// (oversized digit strings saturate, as observed against Hasura).
fn coerce_offset(ctx: &Ctx, v: V, path: &str) -> GResult<Option<i64>> {
    if v.is_null() {
        return Ok(None);
    }
    let kind_err = |found: &str| {
        verr(
            path,
            format!(
                "expected a 32-bit integer, or a 64-bit integer represented as a string for type 'Int', but found {found}"
            ),
        )
    };
    match v {
        V::L(q::Value::Int(_)) | V::J(Json::Number(_)) => {
            let num = numeric_of(ctx, v).unwrap();
            match num.as_int_bounded(ctx, i64::MIN, i64::MAX) {
                Ok(n) => Ok(Some(n)),
                Err(display) => Err(int_bounds_error(path, &display)),
            }
        }
        V::L(q::Value::String(s)) | V::J(Json::String(s)) => match s.parse::<i64>() {
            Ok(n) => Ok(Some(n)),
            Err(_) => {
                let digits = s.strip_prefix('-').unwrap_or(s);
                if !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) {
                    Ok(Some(if s.starts_with('-') {
                        i64::MIN
                    } else {
                        i64::MAX
                    }))
                } else {
                    Err(kind_err("a string"))
                }
            }
        },
        other => Err(kind_err(found_desc(other))),
    }
}

// ---------------------------------------------------------------------------
// Column-typed value coercion (comparison values, by_pk, stream cursors)
// ---------------------------------------------------------------------------

fn pg_cast(scalar: Scalar, pg_type: &str) -> String {
    match scalar {
        Scalar::String => "text".to_string(),
        Scalar::Int => "int4".to_string(),
        Scalar::Smallint => "int2".to_string(),
        Scalar::Bigint => "int8".to_string(),
        Scalar::Float => "float4".to_string(),
        Scalar::Float8 => "float8".to_string(),
        Scalar::Numeric => "numeric".to_string(),
        Scalar::Boolean => "bool".to_string(),
        Scalar::Timestamptz => "timestamptz".to_string(),
        Scalar::Timestamp => "timestamp".to_string(),
        Scalar::Date => "date".to_string(),
        Scalar::Jsonb => "jsonb".to_string(),
        Scalar::Json => "json".to_string(),
        Scalar::PgEnum | Scalar::Other => pg_type.to_string(),
    }
}

fn coerce_column_value(
    ctx: &Ctx,
    scalar: Scalar,
    pg_type: &str,
    is_array: bool,
    v: V,
    path: &str,
) -> GResult<ir::SqlValue> {
    if v.is_null() {
        let base = scalar.gql_name(pg_type);
        let display = if is_array { format!("[{base}!]") } else { base };
        return Err(verr(
            path,
            format!("unexpected null value for type '{display}'"),
        ));
    }
    if is_array {
        let cast = format!("{}[]", pg_cast(scalar, pg_type));
        let mut elems: Vec<String> = Vec::new();
        for (i, item) in list_items(v).into_iter().enumerate() {
            let elem =
                coerce_column_value(ctx, scalar, pg_type, false, item, &format!("{path}[{i}]"))?;
            elems.push(elem.text.unwrap_or_default());
        }
        return Ok(ir::SqlValue::new(pg_array_literal(&elems), cast));
    }

    let cast = pg_cast(scalar, pg_type);
    // Strings (and enum literals) always pass through: Hasura's typed parse
    // falls back to an opaque value, so bad text errors in Postgres, not here.
    let passthrough = match v {
        V::L(q::Value::String(s)) | V::J(Json::String(s)) => Some(s.clone()),
        V::L(q::Value::Enum(e)) => Some(e.clone()),
        _ => None,
    };

    match scalar {
        Scalar::Jsonb | Scalar::Json => {
            let json = value_to_json(ctx, v)?;
            Ok(ir::SqlValue::new(json.to_string(), cast))
        }
        Scalar::String => match passthrough {
            Some(s) => Ok(ir::SqlValue::new(s, cast)),
            None => Err(perr(
                path,
                format!(
                    "parsing Text failed, expected String, but encountered {}",
                    aeson_kind(v)
                ),
            )),
        },
        Scalar::Timestamptz | Scalar::Timestamp | Scalar::Date => match passthrough {
            Some(s) => Ok(ir::SqlValue::new(s, cast)),
            None => {
                let hs_type = match scalar {
                    Scalar::Timestamptz => "UTCTime",
                    Scalar::Timestamp => "LocalTime",
                    _ => "Day",
                };
                Err(perr(
                    path,
                    format!(
                        "parsing {hs_type} failed, expected String, but encountered {}",
                        aeson_kind(v)
                    ),
                ))
            }
        },
        Scalar::PgEnum | Scalar::Other => match passthrough {
            Some(s) => Ok(ir::SqlValue::new(s, cast)),
            None => Err(perr(
                path,
                format!("A string is expected for type: {pg_type}"),
            )),
        },
        Scalar::Boolean => match v {
            V::L(q::Value::Boolean(b)) => Ok(ir::SqlValue::new(b.to_string(), cast)),
            V::J(Json::Bool(b)) => Ok(ir::SqlValue::new(b.to_string(), cast)),
            _ => match passthrough {
                Some(s) => Ok(ir::SqlValue::new(s, cast)),
                None => Err(perr(
                    path,
                    format!("expected Bool, but encountered {}", aeson_kind(v)),
                )),
            },
        },
        Scalar::Int | Scalar::Smallint | Scalar::Bigint => {
            if let Some(s) = passthrough {
                return Ok(ir::SqlValue::new(s, cast));
            }
            let pg_name = match scalar {
                Scalar::Int => "PGInteger",
                Scalar::Smallint => "PGSmallInt",
                _ => "PGBigInt",
            };
            let (min, max) = match scalar {
                Scalar::Int => (i32::MIN as i64, i32::MAX as i64),
                Scalar::Smallint => (i16::MIN as i64, i16::MAX as i64),
                _ => (i64::MIN, i64::MAX),
            };
            let Some(num) = numeric_of(ctx, v) else {
                return Err(perr(
                    path,
                    format!(
                        "parsing Integer expected for input type: {pg_name} failed, expected Number, but encountered {}",
                        aeson_kind(v)
                    ),
                ));
            };
            match num.as_int_bounded(ctx, min, max) {
                Ok(n) => Ok(ir::SqlValue::new(n.to_string(), cast)),
                Err(display) => Err(int_bounds_error(path, &display)),
            }
        }
        Scalar::Numeric => {
            if let Some(s) = passthrough {
                return Ok(ir::SqlValue::new(s, cast));
            }
            let Some(num) = numeric_of(ctx, v) else {
                return Err(perr(
                    path,
                    format!(
                        "parsing Scientific failed, expected Number, but encountered {}",
                        aeson_kind(v)
                    ),
                ));
            };
            Ok(ir::SqlValue::new(num.sql_text(), cast))
        }
        Scalar::Float | Scalar::Float8 => {
            if let Some(s) = passthrough {
                return Ok(ir::SqlValue::new(s, cast));
            }
            let pg_name = if scalar == Scalar::Float {
                "PGFloat"
            } else {
                "PGDouble"
            };
            let Some(num) = numeric_of(ctx, v) else {
                return Err(perr(
                    path,
                    format!(
                        "parsing Float expected for input type: {pg_name} failed, expected Number, but encountered {}",
                        aeson_kind(v)
                    ),
                ));
            };
            if let Num::Float(f) = &num {
                if f.is_infinite() {
                    return Err(float_bounds_error(path, &num.display(ctx)));
                }
            }
            Ok(ir::SqlValue::new(num.sql_text(), cast))
        }
    }
}

/// GraphQL literal (with variables substituted) to a JSON value, for
/// jsonb/json column positions.
fn value_to_json(ctx: &Ctx, v: V) -> GResult<Json> {
    match v {
        V::J(j) => Ok(j.clone()),
        V::L(l) => literal_to_json(ctx, l),
    }
}

fn literal_to_json(ctx: &Ctx, l: &AValue) -> GResult<Json> {
    Ok(match l {
        q::Value::Null => Json::Null,
        q::Value::Boolean(b) => Json::Bool(*b),
        q::Value::Int(n) => {
            let n = n.as_i64().unwrap_or(0);
            match ctx.int_originals.get(&n) {
                Some(orig) => orig
                    .parse::<f64>()
                    .ok()
                    .and_then(serde_json::Number::from_f64)
                    .map(Json::Number)
                    .unwrap_or(Json::Null),
                None => Json::Number(n.into()),
            }
        }
        q::Value::Float(f) => serde_json::Number::from_f64(*f)
            .map(Json::Number)
            .unwrap_or(Json::Null),
        q::Value::String(s) => Json::String(s.clone()),
        q::Value::Enum(e) => Json::String(e.clone()),
        q::Value::List(items) => Json::Array(
            items
                .iter()
                .map(|i| literal_to_json(ctx, i))
                .collect::<GResult<Vec<_>>>()?,
        ),
        q::Value::Object(map) => {
            let mut out = serde_json::Map::new();
            for (k, val) in map {
                out.insert(k.clone(), literal_to_json(ctx, val)?);
            }
            Json::Object(out)
        }
        q::Value::Variable(name) => {
            ctx.mark_used(name);
            match ctx.vars.get(name.as_str()) {
                Some(var) => match &var.value {
                    VarValue::Json(j) => (*j).clone(),
                    VarValue::Lit(l) => literal_to_json(ctx, l)?,
                },
                None => return Err(verr("$", format!("unbound variable \"{name}\""))),
            }
        }
    })
}

/// Postgres array literal text form, e.g. `{a,"b c"}`.
fn pg_array_literal(elems: &[String]) -> String {
    let mut out = String::from("{");
    for (i, e) in elems.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        let needs_quoting = e.is_empty()
            || e.eq_ignore_ascii_case("null")
            || e.chars()
                .any(|c| matches!(c, '{' | '}' | ',' | '"' | '\\') || c.is_whitespace());
        if needs_quoting {
            out.push('"');
            for c in e.chars() {
                if c == '"' || c == '\\' {
                    out.push('\\');
                }
                out.push(c);
            }
            out.push('"');
        } else {
            out.push_str(e);
        }
    }
    out.push('}');
    out
}

// ---------------------------------------------------------------------------
// Hasura JSONPath parsing (json/jsonb `path` argument)
// ---------------------------------------------------------------------------

/// Parses Hasura's JSONPath dialect into `#>` path segments. Accepted:
/// `$`, dotted names (unicode letters/digits/_/-, leading `$`/`.` optional),
/// `[123]` indexes, and `["..."]`/`['...']` quoted keys.
fn parse_json_path(input: &str) -> Result<Vec<String>, ()> {
    if input == "$" {
        return Ok(vec![]);
    }
    let mut chars = input.chars().peekable();
    if let Some('$') = chars.peek() {
        chars.next();
    }
    let mut segments: Vec<String> = Vec::new();
    while chars.peek().is_some() {
        if let Some('.') = chars.peek() {
            chars.next();
        }
        match chars.peek() {
            Some('[') => {
                chars.next();
                match chars.peek() {
                    Some(q @ '"') | Some(q @ '\'') => {
                        let quote = *q;
                        chars.next();
                        let mut key = String::new();
                        loop {
                            match chars.next() {
                                Some('\\') => match chars.next() {
                                    Some(c) => key.push(c),
                                    None => return Err(()),
                                },
                                Some(c) if c == quote => break,
                                Some(c) => key.push(c),
                                None => return Err(()),
                            }
                        }
                        if chars.next() != Some(']') {
                            return Err(());
                        }
                        segments.push(key);
                    }
                    Some(c) if c.is_ascii_digit() => {
                        let mut index = String::new();
                        while let Some(c) = chars.peek() {
                            if c.is_ascii_digit() {
                                index.push(*c);
                                chars.next();
                            } else {
                                break;
                            }
                        }
                        if chars.next() != Some(']') {
                            return Err(());
                        }
                        segments.push(index);
                    }
                    _ => return Err(()),
                }
            }
            Some(c) if *c == '_' || *c == '-' || c.is_alphanumeric() => {
                let mut name = String::new();
                while let Some(c) = chars.peek() {
                    if *c == '_' || *c == '-' || c.is_alphanumeric() {
                        name.push(*c);
                        chars.next();
                    } else {
                        break;
                    }
                }
                segments.push(name);
            }
            _ => return Err(()),
        }
    }
    if segments.is_empty() {
        return Err(());
    }
    Ok(segments)
}

// ---------------------------------------------------------------------------
// Haskell Scientific display (Data.Scientific Show)
// ---------------------------------------------------------------------------

/// Formats a decimal literal the way Haskell shows a Scientific:
/// normalized digits, fixed notation for exponents 0..=7, otherwise
/// `d.ddde<exp>` (e.g. "5000000000" -> "5.0e9", "0.001" -> "1.0e-3").
fn hs_scientific_decimal(s: &str) -> String {
    let Some((neg, digits, e)) = parse_decimal(s) else {
        return s.to_string();
    };
    hs_scientific_parts(neg, &digits, e)
}

/// Splits a decimal/scientific literal into (negative, normalized mantissa
/// digits, e) with value = 0.digits * 10^e.
fn parse_decimal(s: &str) -> Option<(bool, String, i64)> {
    let s = s.trim();
    let (neg, s) = match s.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, s),
    };
    let (mantissa, exp) = match s.find(['e', 'E']) {
        Some(i) => (&s[..i], s[i + 1..].parse::<i64>().ok()?),
        None => (s, 0),
    };
    let (int_part, frac_part) = match mantissa.find('.') {
        Some(i) => (&mantissa[..i], &mantissa[i + 1..]),
        None => (mantissa, ""),
    };
    if int_part.is_empty() && frac_part.is_empty() {
        return None;
    }
    if !int_part.bytes().all(|b| b.is_ascii_digit())
        || !frac_part.bytes().all(|b| b.is_ascii_digit())
    {
        return None;
    }
    let mut digits: String = format!("{int_part}{frac_part}");
    let mut e = int_part.len() as i64 + exp;
    let leading_zeros = digits.len() - digits.trim_start_matches('0').len();
    digits = digits[leading_zeros..].to_string();
    e -= leading_zeros as i64;
    digits = digits.trim_end_matches('0').to_string();
    if digits.is_empty() {
        return Some((false, "0".to_string(), 0));
    }
    Some((neg, digits, e))
}

fn hs_scientific_parts(neg: bool, digits: &str, e: i64) -> String {
    let sign = if neg { "-" } else { "" };
    if !(0..=7).contains(&e) {
        // Exponent format: first digit, '.', remaining digits (or 0), e<e-1>.
        let first = &digits[..1];
        let rest = if digits.len() > 1 { &digits[1..] } else { "0" };
        format!("{sign}{first}.{rest}e{}", e - 1)
    } else if e <= 0 {
        format!("{sign}0.{}{digits}", "0".repeat((-e) as usize))
    } else {
        let e = e as usize;
        if digits.len() <= e {
            format!("{sign}{digits}{}.0", "0".repeat(e - digits.len()))
        } else {
            format!("{sign}{}.{}", &digits[..e], &digits[e..])
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scientific_display_matches_hasura() {
        let cases = [
            ("1.5", "1.5"),
            ("2147483648", "2.147483648e9"),
            ("-2147483649", "-2.147483649e9"),
            ("5000000000", "5.0e9"),
            ("99999999999999", "9.9999999999999e13"),
            ("9223372036854775808", "9.223372036854775808e18"),
            ("99999999999999999999999", "9.9999999999999999999999e22"),
            ("0.001", "1.0e-3"),
            ("0.0025", "2.5e-3"),
            ("2.5e-3", "2.5e-3"),
            ("1e400", "1.0e400"),
            ("100000000000000000000000000", "1.0e26"),
            ("1.5e3", "1500.0"),
            ("42", "42.0"),
            ("5", "5.0"),
            ("0.5", "0.5"),
            ("0", "0.0"),
            ("123.45", "123.45"),
        ];
        for (input, expected) in cases {
            assert_eq!(
                (input, hs_scientific_decimal(input).as_str()),
                (input, expected)
            );
        }
    }

    #[test]
    fn json_path_parsing() {
        let ok = [
            ("$", vec![]),
            ("$.a.b", vec!["a", "b"]),
            ("$.nested.a[0]", vec!["nested", "a", "0"]),
            ("kind", vec!["kind"]),
            (".kind", vec!["kind"]),
            ("a.b", vec!["a", "b"]),
            ("[0]", vec!["0"]),
            ("$[2]", vec!["2"]),
            ("['x']", vec!["x"]),
            ("$[\"x y\"]", vec!["x y"]),
            ("[\"a\\\"b\"]", vec!["a\"b"]),
            ("$.héllo", vec!["héllo"]),
            ("$[4].k", vec!["4", "k"]),
            ("a-b_c1", vec!["a-b_c1"]),
        ];
        for (input, expected) in ok {
            assert_eq!(
                parse_json_path(input),
                Ok(expected.into_iter().map(String::from).collect::<Vec<_>>()),
                "{input}"
            );
        }
        for bad in [
            "",
            "$.",
            "a..b",
            "$[",
            "[x]",
            "[12ab]",
            "a b",
            "$$",
            "totally broken [",
        ] {
            assert_eq!(parse_json_path(bad), Err(()), "{bad}");
        }
    }

    #[test]
    fn prescan_duplicates_and_rewrites() {
        assert!(prescan("{ User(limit: 1, limit: 2) { id } }").is_err());
        assert!(prescan("{ User(where: {id: {_eq: \"a\", _eq: \"b\"}}) { id } }").is_err());
        assert!(prescan("query ($l: Int, $l: Int) { User(limit: $l) { id } }").is_ok());
        assert!(prescan("{ a: User { id } a: User { id } }").is_ok());
        assert!(prescan("{ User(where: {a: {_eq: 1}, b: {_eq: 1}}) { id } }").is_ok());
        // String contents must not confuse scope tracking.
        assert!(prescan("{ User(where: {id: {_eq: \"({[\"}}) { id } }").is_ok());

        let scan = prescan("{ User(limit: 9223372036854775808) { id } }").unwrap();
        assert_eq!(scan.int_originals.len(), 1);
        let (magic, orig) = scan.int_originals.iter().next().unwrap();
        assert_eq!(orig, "9223372036854775808");
        assert!(scan.rewritten.contains(&magic.to_string()));
        assert!(q::parse_query::<String>(&scan.rewritten).is_ok());

        let scan = prescan("{ E(where: {f: {_lt: 1e400}}) { id } }").unwrap();
        assert_eq!(scan.inf_floats, vec!["1e400".to_string()]);
    }

    #[test]
    fn order_direction_mapping() {
        assert_eq!(order_direction("asc"), ir::OrderDirection::Asc);
        assert_eq!(
            order_direction("asc_nulls_first"),
            ir::OrderDirection::AscNullsFirst
        );
        assert_eq!(
            order_direction("asc_nulls_last"),
            ir::OrderDirection::AscNullsLast
        );
        assert_eq!(order_direction("desc"), ir::OrderDirection::Desc);
        assert_eq!(
            order_direction("desc_nulls_first"),
            ir::OrderDirection::DescNullsFirst
        );
        assert_eq!(
            order_direction("desc_nulls_last"),
            ir::OrderDirection::DescNullsLast
        );
    }

    #[test]
    fn pg_array_literal_quoting() {
        assert_eq!(
            pg_array_literal(&[
                "one".to_string(),
                "two words".to_string(),
                "a\"b\\c".to_string(),
                "".to_string(),
                "NULL".to_string(),
            ]),
            r#"{one,"two words","a\"b\\c","","NULL"}"#
        );
    }

    #[test]
    fn graphql_name_validation() {
        assert!(is_valid_graphql_name("Query1"));
        assert!(is_valid_graphql_name("_a"));
        assert!(!is_valid_graphql_name(""));
        assert!(!is_valid_graphql_name("9x"));
        assert!(!is_valid_graphql_name("a-b"));
    }
}
