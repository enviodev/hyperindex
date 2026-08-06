//! `tables:` in config.yaml — table definitions that own both their schema and
//! their writes. A table declares `from` + `select` and is maintained by the
//! runtime with no handler code; tables handlers write stay in schema.graphql.
//!
//! Compilation turns each one into
//!   * GraphQL SDL, merged into the schema the rest of the pipeline already
//!     consumes, so entity types, tables, Hasura and the generated TS types all
//!     come out of the existing machinery,
//!   * a flat list of write plans, one per (table, event, union branch), carried
//!     to the runtime through the public config JSON, and
//!   * the block/transaction fields each event has to fetch, attached to that
//!     event rather than to the source, so an event no table reads pays nothing.
//!
//! Table-local CTEs (`with`) are inlined at compile time: a union branch's
//! column expressions are substituted into the outer `select`, so the runtime
//! never sees a CTE. That is sound because CTEs cannot be recursive and cannot
//! reference each other.

use super::{
    abi_compat::AbiType,
    entity_parsing::{GqlScalar, Schema, UserDefinedFieldType},
    system_config::{Contract, Event, EventKind, FieldSelection, SelectedField},
};
use crate::{type_schema::TypeIdent, utils::text::Capitalize};
use anyhow::{anyhow, Context, Result};
use indexmap::IndexMap;
use schemars::{json_schema, JsonSchema, Schema as JsonSchemaSchema, SchemaGenerator};
use serde::{Deserialize, Serialize};
use serde_yaml::Value as Yaml;
use std::{borrow::Cow, collections::BTreeMap, collections::BTreeSet};

/// The only source a materialized table can read from today.
const EVM_EVENTS_SOURCE: &str = "evm.events";

//
// ── Human config surface ────────────────────────────────────────────────────
//

/// Arbitrary YAML kept unparsed so expressions and filters can be validated by
/// the compiler, which knows the surrounding table and can name the offending
/// path in its error.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RawYaml(pub Yaml);

impl JsonSchema for RawYaml {
    fn schema_name() -> Cow<'static, str> {
        "MaterializationExpression".into()
    }

    fn json_schema(_gen: &mut SchemaGenerator) -> JsonSchemaSchema {
        json_schema!({
            "description": "A source path (\"params.owner\"), a YAML literal, or a structured \
                            expression whose single key is an operator (`_literal`, `_negate`, \
                            `_sum`, `_concat`, `_ref`, `_derived_from`)."
        })
    }

    fn inline_schema() -> bool {
        true
    }
}

/// A `where` clause, kept unparsed for the same reason as `RawYaml`. Separate
/// only so editors describe a filter as a filter.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RawFilter(pub Yaml);

impl JsonSchema for RawFilter {
    fn schema_name() -> Cow<'static, str> {
        "MaterializationFilter".into()
    }

    fn json_schema(_gen: &mut SchemaGenerator) -> JsonSchemaSchema {
        json_schema!({
            "type": "object",
            "description": "Field conditions, ANDed together. A scalar is equality shorthand \
                            (`eventName: Transfer`); an object is either a nested path \
                            (`block: {number: {_gte: 100}}`) or operators (`_eq`, `_ne`, `_gt`, \
                            `_gte`, `_lt`, `_lte`, `_in`, `_nin`). `_and`/`_or` take lists of \
                            filters. `contractName` and `eventName` also narrow which events the \
                            table's paths are typed against."
        })
    }

    fn inline_schema() -> bool {
        true
    }
}

/// `tables:` — insertion order is preserved so generated columns follow the
/// order they were written in.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Tables(pub IndexMap<String, TableConfig>);

impl JsonSchema for Tables {
    fn schema_name() -> Cow<'static, str> {
        "Tables".into()
    }

    fn json_schema(gen: &mut SchemaGenerator) -> JsonSchemaSchema {
        let table = TableConfig::json_schema(gen);
        json_schema!({
            "type": "object",
            "additionalProperties": table
        })
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TableConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(
        description = "Share one row across every chain instead of keeping the same id per chain. \
                       Only meaningful with `disable_default_cross_chain: true`."
    )]
    pub cross_chain: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(
        description = "Read the events from every address that emits them, rather than only the \
                       contract's configured addresses. Needed when the contract has no `address` \
                       in config.yaml."
    )]
    pub wildcard: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(
        with = "Option<BTreeMap<String, Queries>>",
        description = "Table-local intermediate relations, like SQL CTEs. A list of queries is a \
                       UNION ALL; every branch must produce the same columns."
    )]
    pub with: Option<IndexMap<String, Queries>>,
    #[schemars(
        description = "What the table is materialized from: `evm.events`, or the name of one of \
                       its own `with` relations."
    )]
    pub from: String,
    #[serde(rename = "where", skip_serializing_if = "Option::is_none")]
    pub filter: Option<RawFilter>,
    #[schemars(
        with = "BTreeMap<String, RawYaml>",
        description = "The table's complete public shape. Plain strings are source paths; YAML \
                       numbers, booleans and null are literals."
    )]
    pub select: IndexMap<String, RawYaml>,
}

/// One or many queries. A bare mapping is the single-branch shorthand.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(transparent)]
pub struct Queries(pub Vec<Query>);

impl<'de> Deserialize<'de> for Queries {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct QueriesVisitor;

        impl<'de> serde::de::Visitor<'de> for QueriesVisitor {
            type Value = Queries;

            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("a query object, or a list of them for a union")
            }

            fn visit_seq<A: serde::de::SeqAccess<'de>>(
                self,
                seq: A,
            ) -> Result<Self::Value, A::Error> {
                Vec::deserialize(serde::de::value::SeqAccessDeserializer::new(seq)).map(Queries)
            }

            fn visit_map<A: serde::de::MapAccess<'de>>(
                self,
                map: A,
            ) -> Result<Self::Value, A::Error> {
                Query::deserialize(serde::de::value::MapAccessDeserializer::new(map))
                    .map(|q| Queries(vec![q]))
            }
        }

        deserializer.deserialize_any(QueriesVisitor)
    }
}

impl JsonSchema for Queries {
    fn schema_name() -> Cow<'static, str> {
        "Queries".into()
    }

    fn json_schema(gen: &mut SchemaGenerator) -> JsonSchemaSchema {
        let query = Query::json_schema(gen);
        json_schema!({
            "anyOf": [query, {"type": "array", "items": query}]
        })
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Query {
    #[schemars(description = "Source to read from. Currently only `evm.events`.")]
    pub from: String,
    #[serde(rename = "where", skip_serializing_if = "Option::is_none")]
    pub filter: Option<RawFilter>,
    #[schemars(with = "BTreeMap<String, RawYaml>")]
    pub select: IndexMap<String, RawYaml>,
}

//
// ── Types ───────────────────────────────────────────────────────────────────
//

#[derive(Debug, Clone, PartialEq, Eq)]
enum Scalar {
    String,
    Boolean,
    Int,
    Float,
    BigInt,
    BigDecimal,
    Json,
    /// Reference to another table; carries the target's name.
    Ref(String),
    /// An unsuffixed YAML integer. Widens to whichever numeric type it meets.
    NumLit,
    /// A YAML `null` with nothing to unify against yet.
    Null,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Ty {
    scalar: Scalar,
    nullable: bool,
    array: bool,
}

impl Ty {
    fn new(scalar: Scalar) -> Self {
        Self {
            scalar,
            nullable: false,
            array: false,
        }
    }

    fn nullable(mut self) -> Self {
        self.nullable = true;
        self
    }

    fn array(mut self) -> Self {
        self.array = true;
        self
    }

    fn describe(&self) -> String {
        let base = match &self.scalar {
            Scalar::String => "String".to_string(),
            Scalar::Boolean => "Boolean".to_string(),
            Scalar::Int => "Int".to_string(),
            Scalar::Float => "Float".to_string(),
            Scalar::BigInt => "BigInt".to_string(),
            Scalar::BigDecimal => "BigDecimal".to_string(),
            Scalar::Json => "Json".to_string(),
            Scalar::Ref(target) => target.clone(),
            Scalar::NumLit => "a number literal".to_string(),
            Scalar::Null => "null".to_string(),
        };
        let base = if self.array {
            format!("[{base}]")
        } else {
            base
        };
        if self.nullable {
            base
        } else {
            format!("{base}!")
        }
    }

    /// GraphQL rendering. `id` positions render `String` as `ID`.
    fn to_gql(&self, is_id: bool) -> Result<String> {
        let base = match &self.scalar {
            Scalar::String if is_id => "ID".to_string(),
            Scalar::String => "String".to_string(),
            Scalar::Boolean => "Boolean".to_string(),
            Scalar::Int => "Int".to_string(),
            Scalar::Float => "Float".to_string(),
            Scalar::BigInt => "BigInt".to_string(),
            Scalar::BigDecimal => "BigDecimal".to_string(),
            Scalar::Json => "Json".to_string(),
            Scalar::Ref(target) => target.clone(),
            // Nothing ever unified with it, so the literal keeps its narrowest
            // faithful type rather than silently becoming a BigInt column.
            Scalar::NumLit => "Int".to_string(),
            Scalar::Null => {
                return Err(anyhow!(
                    "the expression is always null, so its type can't be inferred. Give it a \
                     typed sibling in the union, or drop the field."
                ))
            }
        };
        let base = if self.array {
            format!("[{base}{}]", if self.nullable { "" } else { "!" })
        } else {
            base
        };
        Ok(if self.nullable {
            base
        } else {
            format!("{base}!")
        })
    }

    /// The runtime tag a numeric reducer and `_negate` dispatch on.
    fn numeric_tag(&self) -> Option<&'static str> {
        if self.array {
            return None;
        }
        match self.scalar {
            // NumLit reports the type `to_gql` would give it, so a reducer over
            // a literal that never widened still agrees with its column.
            Scalar::Int | Scalar::NumLit => Some("int"),
            Scalar::Float => Some("float"),
            Scalar::BigInt => Some("bigint"),
            Scalar::BigDecimal => Some("bigdecimal"),
            _ => None,
        }
    }
}

/// Widen two types to one that holds both. Number literals adopt the other
/// side's numeric type; `null` makes the other side nullable.
fn unify(a: &Ty, b: &Ty) -> Result<Ty> {
    if a.scalar == Scalar::Null {
        return Ok(b.clone().nullable());
    }
    if b.scalar == Scalar::Null {
        return Ok(a.clone().nullable());
    }
    let nullable = a.nullable || b.nullable;
    if a.array != b.array {
        return Err(anyhow!(
            "cannot unify {} with {}",
            a.describe(),
            b.describe()
        ));
    }
    let scalar = match (&a.scalar, &b.scalar) {
        (Scalar::NumLit, other) | (other, Scalar::NumLit) => match other {
            Scalar::Int | Scalar::Float | Scalar::BigInt | Scalar::BigDecimal => other.clone(),
            Scalar::NumLit => Scalar::NumLit,
            _ => {
                return Err(anyhow!(
                    "cannot unify {} with {}",
                    a.describe(),
                    b.describe()
                ))
            }
        },
        (x, y) if x == y => x.clone(),
        _ => {
            return Err(anyhow!(
                "cannot unify {} with {}",
                a.describe(),
                b.describe()
            ))
        }
    };
    Ok(Ty {
        scalar,
        nullable,
        array: a.array,
    })
}

//
// ── Compiled expressions (serialized to the public config JSON) ─────────────
//

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(tag = "kind")]
enum CExpr {
    #[serde(rename = "path")]
    Path { path: Vec<String> },
    #[serde(rename = "string")]
    LitString { value: String },
    #[serde(rename = "bool")]
    LitBool { value: bool },
    #[serde(rename = "int")]
    LitInt { value: i64 },
    #[serde(rename = "float")]
    LitFloat { value: f64 },
    /// Decimal text: JSON has no bigint, and the runtime needs an exact value.
    #[serde(rename = "bigint")]
    LitBigInt { value: String },
    #[serde(rename = "bigdecimal")]
    LitBigDecimal { value: String },
    #[serde(rename = "null")]
    LitNull,
    #[serde(rename = "negate")]
    Negate {
        #[serde(rename = "type")]
        numeric_type: &'static str,
        expr: Box<CExpr>,
    },
    #[serde(rename = "concat")]
    Concat {
        #[serde(skip_serializing_if = "Option::is_none")]
        separator: Option<String>,
        values: Vec<CExpr>,
    },
}

#[derive(Debug, Clone, PartialEq)]
struct Typed {
    expr: CExpr,
    ty: Ty,
}

impl Typed {
    /// Rewrite untyped literals to the target type. Everything else must
    /// already unify with the target.
    fn coerce(self, target: &Ty) -> Result<CExpr> {
        let Typed { expr, ty } = self;
        if ty.scalar == Scalar::NumLit && !target.array {
            let text = match &expr {
                CExpr::LitInt { value } => value.to_string(),
                other => {
                    // NumLit is only ever produced by an integer literal.
                    return Err(anyhow!("unexpected number literal expression {other:?}"));
                }
            };
            return Ok(match target.scalar {
                Scalar::BigInt => CExpr::LitBigInt { value: text },
                Scalar::BigDecimal => CExpr::LitBigDecimal { value: text },
                Scalar::Float => CExpr::LitFloat {
                    value: text.parse().context("number literal out of float range")?,
                },
                // A literal that never met a wider sibling becomes an Int
                // column, so it has to fit one.
                Scalar::Int | Scalar::NumLit => {
                    let value: i64 = text.parse().expect("came from an i64 literal");
                    if i32::try_from(value).is_err() {
                        return Err(anyhow!(
                            "the literal {value} is outside the Int (32-bit) range. Unify it with \
                             a BigInt expression (e.g. a uint256 param) so the column widens."
                        ));
                    }
                    expr
                }
                _ => {
                    return Err(anyhow!(
                        "a number literal can't be used where {} is expected",
                        target.describe()
                    ))
                }
            });
        }
        if ty.scalar == Scalar::Null {
            return Ok(CExpr::LitNull);
        }
        unify(&ty, target).with_context(|| {
            format!(
                "expected {} but the expression is {}",
                target.describe(),
                ty.describe()
            )
        })?;
        Ok(expr)
    }
}

//
// ── Compiled filters ───────────────────────────────────────────────────────
//

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(tag = "kind")]
enum CFilter {
    #[serde(rename = "and")]
    And { filters: Vec<CFilter> },
    #[serde(rename = "or")]
    Or { filters: Vec<CFilter> },
    #[serde(rename = "cmp")]
    Cmp {
        path: Vec<String>,
        op: &'static str,
        value: CExpr,
    },
    #[serde(rename = "in")]
    In {
        path: Vec<String>,
        /// True for `_nin`.
        #[serde(skip_serializing_if = "std::ops::Not::not")]
        negated: bool,
        values: Vec<CExpr>,
    },
}

/// A filter partially evaluated against a candidate event. `Unknown` carries
/// the residual the runtime still has to check.
#[derive(Debug, Clone)]
enum Residual {
    True,
    False,
    Unknown(CFilter),
}

fn residual_and(parts: Vec<Residual>) -> Residual {
    let mut kept = Vec::new();
    for part in parts {
        match part {
            Residual::False => return Residual::False,
            Residual::True => (),
            Residual::Unknown(f) => kept.push(f),
        }
    }
    match kept.len() {
        0 => Residual::True,
        1 => Residual::Unknown(kept.pop().expect("checked length")),
        _ => Residual::Unknown(CFilter::And { filters: kept }),
    }
}

fn residual_or(parts: Vec<Residual>) -> Residual {
    let mut kept = Vec::new();
    for part in parts {
        match part {
            Residual::True => return Residual::True,
            Residual::False => (),
            Residual::Unknown(f) => kept.push(f),
        }
    }
    match kept.len() {
        0 => Residual::False,
        1 => Residual::Unknown(kept.pop().expect("checked length")),
        _ => Residual::Unknown(CFilter::Or { filters: kept }),
    }
}

//
// ── Compiled output ────────────────────────────────────────────────────────
//

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FieldWrite {
    /// Column name as the entity API spells it (`owner_id` for a reference).
    name: String,
    /// `set` overwrites; `sum` adds to whatever the row already holds.
    op: &'static str,
    /// Numeric tag the reducer needs to pick a zero and an addition. Only
    /// emitted for `sum`.
    #[serde(rename = "type", skip_serializing_if = "Option::is_none")]
    numeric_type: Option<&'static str>,
    expr: CExpr,
}

/// One write, bound to one event on one table.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Materialization {
    pub table: String,
    pub contract_name: String,
    pub event_name: String,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub wildcard: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    filter: Option<CFilter>,
    id: CExpr,
    fields: Vec<FieldWrite>,
}

pub struct Compiled {
    /// GraphQL SDL for every table declared in `tables`.
    pub sdl: String,
    pub materializations: Vec<Materialization>,
    /// Per-event block/transaction fields the materializations read, so each
    /// event fetches exactly what its tables select.
    pub field_demand: DemandByEvent,
}

//
// ── Source shapes ──────────────────────────────────────────────────────────
//

/// What a path can resolve to inside a `select` or `where`.
enum Shape<'a> {
    /// `evm.events`, narrowed to one event.
    Event {
        contract_name: &'a str,
        event: &'a Event,
        block_fields: &'a BTreeMap<String, Ty>,
        transaction_fields: &'a BTreeMap<String, Ty>,
    },
    /// A table-local relation: single-segment column names only.
    Relation {
        name: &'a str,
        columns: &'a IndexMap<String, Ty>,
    },
}

fn ty_from_type_ident(ident: &TypeIdent) -> Ty {
    // The field tables are built from `FieldSelection::all_evm`, whose idents
    // only ever nest option/array one level deep.
    match ident {
        TypeIdent::Option(inner) => ty_from_type_ident(inner).nullable(),
        TypeIdent::Array(inner) => ty_from_type_ident(inner).array(),
        TypeIdent::Int => Ty::new(Scalar::Int),
        TypeIdent::Float => Ty::new(Scalar::Float),
        TypeIdent::BigInt => Ty::new(Scalar::BigInt),
        TypeIdent::BigDecimal => Ty::new(Scalar::BigDecimal),
        TypeIdent::Bool => Ty::new(Scalar::Boolean),
        TypeIdent::Json => Ty::new(Scalar::Json),
        TypeIdent::Timestamp => Ty::new(Scalar::Int),
        // Address / String / ID and anything opaque are strings at runtime.
        _ => Ty::new(Scalar::String),
    }
}

/// Params are typed by the one ABI-to-scalar mapping the rest of the pipeline
/// uses, so a param can't type differently depending on whether a table or a
/// contract import looked at it.
fn ty_from_abi(abi: &AbiType) -> Result<Ty> {
    fn from_gql(gql: &UserDefinedFieldType) -> Result<Ty> {
        Ok(match gql {
            UserDefinedFieldType::NonNullType(inner) => from_gql(inner)?,
            UserDefinedFieldType::ListType(inner) => from_gql(inner)?.array(),
            UserDefinedFieldType::Single(scalar) => Ty::new(match scalar {
                GqlScalar::Boolean => Scalar::Boolean,
                GqlScalar::BigInt(_) => Scalar::BigInt,
                GqlScalar::BigDecimal(_) => Scalar::BigDecimal,
                GqlScalar::Int => Scalar::Int,
                GqlScalar::Float => Scalar::Float,
                GqlScalar::Json => Scalar::Json,
                GqlScalar::ID | GqlScalar::String | GqlScalar::Bytes => Scalar::String,
                other => return Err(anyhow!("ABI params can't produce the `{other}` type")),
            }),
        })
    }
    from_gql(&UserDefinedFieldType::from_dyn_sol_type(
        &abi.to_dyn_sol_type(),
    )?)
}

/// Walk into a tuple param by component name.
fn descend_abi<'a>(abi: &'a AbiType, segment: &str) -> Option<&'a AbiType> {
    match abi {
        AbiType::Tuple(fields) => fields
            .iter()
            .enumerate()
            .find(|(index, field)| {
                field.name.as_deref() == Some(segment) || index.to_string() == segment
            })
            .map(|(_, field)| &field.kind),
        _ => None,
    }
}

/// What one event's resolved paths cost in fetched data.
#[derive(Default)]
pub struct Demand {
    pub block: BTreeSet<String>,
    pub transaction: BTreeSet<String>,
}

/// Field demand keyed by the event that carries it, so each `events:` entry
/// selects only what the tables reading it actually touch, rather than every
/// event on every contract paying for the widest selection.
#[derive(Default)]
pub struct DemandByEvent(pub BTreeMap<(String, String), Demand>);

impl DemandByEvent {
    fn merge(&mut self, contract_name: &str, event_name: &str, from: Demand) {
        if from.block.is_empty() && from.transaction.is_empty() {
            return;
        }
        let into = self
            .0
            .entry((contract_name.to_string(), event_name.to_string()))
            .or_default();
        into.block.extend(from.block);
        into.transaction.extend(from.transaction);
    }
}

impl Shape<'_> {
    fn resolve(&self, path: &[String], demand: &mut Demand) -> Result<Ty> {
        match self {
            Shape::Relation { name, columns } => {
                if path.len() != 1 {
                    return Err(anyhow!(
                        "`{}` is a table-local relation, so its columns are plain names — `{}` \
                         has no nested fields",
                        name,
                        path.join(".")
                    ));
                }
                columns.get(&path[0]).cloned().ok_or_else(|| {
                    anyhow!(
                        "`{}` is not a column of `{}`. Available: {}",
                        path[0],
                        name,
                        columns.keys().cloned().collect::<Vec<_>>().join(", ")
                    )
                })
            }
            Shape::Event {
                contract_name,
                event,
                block_fields,
                transaction_fields,
            } => {
                let head = path[0].as_str();
                let rest = &path[1..];
                match head {
                    "contractName" | "eventName" | "srcAddress" if rest.is_empty() => {
                        Ok(Ty::new(Scalar::String))
                    }
                    "chainId" | "logIndex" if rest.is_empty() => Ok(Ty::new(Scalar::Int)),
                    "params" => {
                        let params = match &event.kind {
                            EventKind::Params(params) => params,
                            _ => {
                                return Err(anyhow!(
                                    "`evm.events` only exposes `params` for EVM log events"
                                ))
                            }
                        };
                        let (first, nested) = rest.split_first().ok_or_else(|| {
                            anyhow!(
                                "`params` is a record — select one of its fields, e.g. `params.{}`",
                                params
                                    .first()
                                    .map(|p| p.name.clone())
                                    .unwrap_or_else(|| "value".to_string())
                            )
                        })?;
                        let param = params.iter().find(|p| &p.name == first).ok_or_else(|| {
                            anyhow!(
                                "`{}.{}` has no parameter `{}`. Available: {}",
                                contract_name,
                                event.name,
                                first,
                                params
                                    .iter()
                                    .map(|p| p.name.clone())
                                    .collect::<Vec<_>>()
                                    .join(", ")
                            )
                        })?;
                        let mut abi = &param.kind;
                        for segment in nested {
                            abi = descend_abi(abi, segment).ok_or_else(|| {
                                anyhow!(
                                    "`{}` has no field `{}`",
                                    path[..path.len() - nested.len()].join("."),
                                    segment
                                )
                            })?;
                        }
                        ty_from_abi(abi)
                    }
                    "block" | "transaction" => {
                        let (table, label) = if head == "block" {
                            (block_fields, "block")
                        } else {
                            (transaction_fields, "transaction")
                        };
                        let field = match rest {
                            [field] => field,
                            [] => {
                                return Err(anyhow!(
                                    "`{label}` is a record — select one of its fields, e.g. \
                                     `{label}.hash`"
                                ))
                            }
                            _ => {
                                return Err(anyhow!(
                                    "`{}` is not a valid path: `{label}` fields are flat",
                                    path.join(".")
                                ))
                            }
                        };
                        let ty = table
                            .get(field)
                            .cloned()
                            .ok_or_else(|| anyhow!("`{label}` has no field `{field}`"))?;
                        // number/timestamp/hash always come with the log; the
                        // rest have to be requested from the source.
                        if head == "block" {
                            if !matches!(field.as_str(), "number" | "timestamp" | "hash") {
                                demand.block.insert(field.clone());
                            }
                        } else {
                            demand.transaction.insert(field.clone());
                        }
                        Ok(ty)
                    }
                    other => Err(anyhow!(
                        "`{other}` is not a field of `evm.events`. Available: contractName, \
                         eventName, chainId, srcAddress, logIndex, params, block, transaction"
                    )),
                }
            }
        }
    }
}

//
// ── Expression parsing ─────────────────────────────────────────────────────
//

fn split_path(text: &str) -> Result<Vec<String>> {
    if text.is_empty() {
        return Err(anyhow!("an empty string is not a source path"));
    }
    let segments: Vec<String> = text.split('.').map(|s| s.to_string()).collect();
    if segments.iter().any(|s| s.is_empty()) {
        return Err(anyhow!(
            "`{text}` is not a source path. Use dots between field names, e.g. `params.owner`."
        ));
    }
    Ok(segments)
}

/// The single `_`-prefixed key of an operator mapping, if that is what this is.
fn as_operator(value: &Yaml) -> Result<Option<(String, &Yaml)>> {
    let map = match value {
        Yaml::Mapping(map) => map,
        _ => return Ok(None),
    };
    let mut operators = Vec::new();
    let mut plain = Vec::new();
    for key in map.keys() {
        let key = key
            .as_str()
            .ok_or_else(|| anyhow!("expected a string key in an expression object"))?;
        if key.starts_with('_') {
            operators.push(key.to_string());
        } else {
            plain.push(key.to_string());
        }
    }
    if operators.is_empty() {
        return Ok(None);
    }
    if operators.len() > 1 || !plain.is_empty() {
        return Err(anyhow!(
            "an expression object holds exactly one operator, but got: {}",
            operators
                .into_iter()
                .chain(plain)
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    let operator = operators.remove(0);
    let inner = map
        .get(Yaml::String(operator.clone()))
        .expect("key came from the same map");
    Ok(Some((operator, inner)))
}

fn yaml_string(value: &Yaml, what: &str) -> Result<String> {
    value
        .as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| anyhow!("{what} must be a string"))
}

struct ExprCtx<'a> {
    shape: &'a Shape<'a>,
    /// Column expressions to substitute for a relation's bare column names.
    substitutions: Option<&'a IndexMap<String, CExpr>>,
    /// Tables declared in `tables`, for validating `_ref`/`_derived_from`.
    table_names: &'a [String],
}

/// Field-level operators, which are not expressions: they say how the column is
/// maintained rather than what value the event produces.
enum Selected {
    Value(Typed),
    Sum(Typed),
    Ref { table: String, id: Typed },
    DerivedFrom { table: String, field: String },
}

fn compile_selected(value: &Yaml, ctx: &ExprCtx, demand: &mut Demand) -> Result<Selected> {
    if let Some((operator, inner)) = as_operator(value)? {
        match operator.as_str() {
            "_sum" => {
                let inner = compile_expr(inner, ctx, demand).context("in `_sum`")?;
                if inner.ty.numeric_tag().is_none() {
                    return Err(anyhow!(
                        "`_sum` needs a numeric expression, but got {}",
                        inner.ty.describe()
                    ));
                }
                return Ok(Selected::Sum(inner));
            }
            "_ref" => {
                let map = inner
                    .as_mapping()
                    .ok_or_else(|| anyhow!("`_ref` takes `{{table, id}}`"))?;
                let table = map
                    .get(Yaml::String("table".into()))
                    .ok_or_else(|| anyhow!("`_ref` is missing `table`"))?;
                let table = yaml_string(table, "`_ref.table`")?;
                if !ctx.table_names.iter().any(|name| name == &table) {
                    return Err(anyhow!(
                        "`_ref.table` points at `{table}`, which is not declared in `tables`"
                    ));
                }
                let id = map
                    .get(Yaml::String("id".into()))
                    .ok_or_else(|| anyhow!("`_ref` is missing `id`"))?;
                for key in map.keys() {
                    let key = yaml_string(key, "a `_ref` key")?;
                    if key != "table" && key != "id" {
                        return Err(anyhow!("`_ref` has no `{key}` option"));
                    }
                }
                let id = compile_expr(id, ctx, demand).context("in `_ref.id`")?;
                return Ok(Selected::Ref { table, id });
            }
            "_derived_from" => {
                let target = yaml_string(inner, "`_derived_from`")?;
                let (table, field) = target.split_once('.').ok_or_else(|| {
                    anyhow!(
                        "`_derived_from` takes `<table>.<field>`, e.g. `approvals.owner`, but got \
                         `{target}`"
                    )
                })?;
                if !ctx.table_names.iter().any(|name| name == table) {
                    return Err(anyhow!(
                        "`_derived_from` points at table `{table}`, which is not declared in \
                         `tables`"
                    ));
                }
                return Ok(Selected::DerivedFrom {
                    table: table.to_string(),
                    field: field.to_string(),
                });
            }
            _ => (),
        }
    }
    Ok(Selected::Value(compile_expr(value, ctx, demand)?))
}

fn compile_expr(value: &Yaml, ctx: &ExprCtx, demand: &mut Demand) -> Result<Typed> {
    if let Some((operator, inner)) = as_operator(value)? {
        return compile_operator(&operator, inner, ctx, demand);
    }
    match value {
        // Plain strings are source paths. A literal string needs `_literal`, so
        // a typo like `params.owenr` can't silently become data.
        Yaml::String(text) => {
            let path = split_path(text)?;
            if let (Some(substitutions), 1) = (ctx.substitutions, path.len()) {
                if let Some(expr) = substitutions.get(&path[0]) {
                    let ty = ctx.shape.resolve(&path, demand)?;
                    return Ok(Typed {
                        expr: expr.clone(),
                        ty,
                    });
                }
            }
            let ty = ctx.shape.resolve(&path, demand)?;
            Ok(Typed {
                expr: CExpr::Path { path },
                ty,
            })
        }
        Yaml::Bool(value) => Ok(Typed {
            expr: CExpr::LitBool { value: *value },
            ty: Ty::new(Scalar::Boolean),
        }),
        Yaml::Number(number) => {
            if let Some(value) = number.as_i64() {
                Ok(Typed {
                    expr: CExpr::LitInt { value },
                    ty: Ty::new(Scalar::NumLit),
                })
            } else if let Some(value) = number.as_f64() {
                Ok(Typed {
                    expr: CExpr::LitFloat { value },
                    ty: Ty::new(Scalar::Float),
                })
            } else {
                Err(anyhow!("`{number:?}` is not a supported number literal"))
            }
        }
        Yaml::Null => Ok(Typed {
            expr: CExpr::LitNull,
            ty: Ty::new(Scalar::Null),
        }),
        Yaml::Sequence(_) => Err(anyhow!(
            "a list is not an expression. Use `_concat` to join values."
        )),
        Yaml::Mapping(_) => Err(anyhow!(
            "an object is only an expression when its single key is an operator like `_literal`, \
             `_negate`, `_sum`, `_concat` or `_ref`."
        )),
        Yaml::Tagged(tagged) => compile_expr(&tagged.value, ctx, demand),
    }
}

fn compile_operator(
    operator: &str,
    inner: &Yaml,
    ctx: &ExprCtx,
    demand: &mut Demand,
) -> Result<Typed> {
    match operator {
        "_literal" => {
            let value = yaml_string(
                inner,
                "`_literal` (numbers, booleans and null are already literals, so they need no \
                 `_literal`)",
            )?;
            Ok(Typed {
                expr: CExpr::LitString { value },
                ty: Ty::new(Scalar::String),
            })
        }
        "_negate" => {
            let inner = compile_expr(inner, ctx, demand).context("in `_negate`")?;
            let numeric_type = inner.ty.numeric_tag().ok_or_else(|| {
                anyhow!(
                    "`_negate` needs a numeric expression, but got {}",
                    inner.ty.describe()
                )
            })?;
            // Folded so a negated literal stays a literal and can still widen to
            // whatever numeric type its siblings settle on.
            let expr = match inner.expr {
                CExpr::LitInt { value } => CExpr::LitInt { value: -value },
                CExpr::LitFloat { value } => CExpr::LitFloat { value: -value },
                expr => CExpr::Negate {
                    numeric_type,
                    expr: Box::new(expr),
                },
            };
            Ok(Typed { ty: inner.ty, expr })
        }
        "_concat" => {
            let (separator, values) = match inner {
                Yaml::Sequence(items) => (None, items.clone()),
                Yaml::Mapping(map) => {
                    for key in map.keys() {
                        let key = yaml_string(key, "a `_concat` key")?;
                        if key != "separator" && key != "values" {
                            return Err(anyhow!("`_concat` has no `{key}` option"));
                        }
                    }
                    let separator = match map.get(Yaml::String("separator".into())) {
                        Some(value) => Some(yaml_string(value, "`_concat.separator`")?),
                        None => None,
                    };
                    let values = map
                        .get(Yaml::String("values".into()))
                        .and_then(|value| value.as_sequence().cloned())
                        .ok_or_else(|| anyhow!("`_concat.values` must be a list"))?;
                    (separator, values)
                }
                _ => {
                    return Err(anyhow!(
                        "`_concat` takes a list of values, or `{{separator, values}}`"
                    ))
                }
            };
            if values.is_empty() {
                return Err(anyhow!("`_concat.values` must not be empty"));
            }
            let mut compiled = Vec::with_capacity(values.len());
            for (index, value) in values.iter().enumerate() {
                let part = compile_expr(value, ctx, demand)
                    .with_context(|| format!("in `_concat.values[{index}]`"))?;
                match part.ty.scalar {
                    Scalar::Json | Scalar::Null | Scalar::Ref(_) => {
                        return Err(anyhow!(
                            "`_concat.values[{index}]` is {}, which has no canonical text form. \
                             Convert it explicitly first.",
                            part.ty.describe()
                        ))
                    }
                    _ if part.ty.array => {
                        return Err(anyhow!(
                            "`_concat.values[{index}]` is a list, which has no canonical text form"
                        ))
                    }
                    _ if part.ty.nullable => {
                        return Err(anyhow!(
                            "`_concat.values[{index}]` is nullable ({}), so the result could \
                             silently collide. Handle the null case explicitly.",
                            part.ty.describe()
                        ))
                    }
                    _ => (),
                }
                compiled.push(part.expr);
            }
            Ok(Typed {
                expr: CExpr::Concat {
                    separator,
                    values: compiled,
                },
                ty: Ty::new(Scalar::String),
            })
        }
        "_sum" => Err(anyhow!(
            "`_sum` is a reducer, so it can only be a top-level field of `select`"
        )),
        "_ref" => Err(anyhow!(
            "`_ref` declares a relationship, so it can only be a top-level field of `select`"
        )),
        "_derived_from" => Err(anyhow!(
            "`_derived_from` declares a virtual field, so it can only be a top-level field of \
             `select`"
        )),
        other => Err(anyhow!("`{other}` is not a known operator")),
    }
}

//
// ── Filter parsing ─────────────────────────────────────────────────────────
//

const COMPARISON_OPS: &[(&str, &str)] = &[
    ("_eq", "eq"),
    ("_ne", "ne"),
    ("_gt", "gt"),
    ("_gte", "gte"),
    ("_lt", "lt"),
    ("_lte", "lte"),
];

/// A single condition, before it is evaluated against a candidate event.
enum Condition {
    And(Vec<Condition>),
    Or(Vec<Condition>),
    Cmp {
        path: Vec<String>,
        op: &'static str,
        value: Yaml,
    },
    In {
        path: Vec<String>,
        negated: bool,
        values: Vec<Yaml>,
    },
}

fn parse_filter(value: &Yaml) -> Result<Condition> {
    let map = value
        .as_mapping()
        .ok_or_else(|| anyhow!("`where` must be an object"))?;
    let mut parts = Vec::with_capacity(map.len());
    for (key, item) in map {
        let key = yaml_string(key, "a `where` key")?;
        match key.as_str() {
            "_and" | "_or" => {
                let items = item
                    .as_sequence()
                    .ok_or_else(|| anyhow!("`{key}` takes a list of filters"))?;
                let branches = items
                    .iter()
                    .map(parse_filter)
                    .collect::<Result<Vec<_>>>()
                    .with_context(|| format!("in `{key}`"))?;
                if branches.is_empty() {
                    return Err(anyhow!("`{key}` must not be empty"));
                }
                parts.push(if key == "_and" {
                    Condition::And(branches)
                } else {
                    Condition::Or(branches)
                });
            }
            _ if key.starts_with('_') => {
                return Err(anyhow!(
                    "`{key}` is not valid at the top of a filter — put it under the field it \
                     applies to"
                ))
            }
            _ => parts.push(parse_field_filter(std::slice::from_ref(&key), item)?),
        }
    }
    if parts.is_empty() {
        return Err(anyhow!("`where` must not be empty"));
    }
    Ok(Condition::And(parts))
}

fn parse_field_filter(path: &[String], value: &Yaml) -> Result<Condition> {
    let map = match value {
        Yaml::Mapping(map) => map,
        // A scalar is equality shorthand.
        scalar => {
            return Ok(Condition::Cmp {
                path: path.to_vec(),
                op: "eq",
                value: scalar.clone(),
            })
        }
    };
    let mut parts = Vec::with_capacity(map.len());
    for (key, item) in map {
        let key = yaml_string(key, "a `where` key")?;
        if let Some((_, op)) = COMPARISON_OPS.iter().find(|(name, _)| *name == key) {
            parts.push(Condition::Cmp {
                path: path.to_vec(),
                op,
                value: item.clone(),
            });
        } else if key == "_in" || key == "_nin" {
            let values = item
                .as_sequence()
                .ok_or_else(|| anyhow!("`{key}` takes a list of values"))?;
            parts.push(Condition::In {
                path: path.to_vec(),
                negated: key == "_nin",
                values: values.clone(),
            });
        } else if key.starts_with('_') {
            return Err(anyhow!(
                "`{key}` is not a known filter operator. Available: {}, _in, _nin",
                COMPARISON_OPS
                    .iter()
                    .map(|(name, _)| *name)
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        } else {
            let mut nested = path.to_vec();
            nested.push(key);
            parts.push(parse_field_filter(&nested, item)?);
        }
    }
    if parts.is_empty() {
        return Err(anyhow!("`{}` has an empty filter object", path.join(".")));
    }
    Ok(Condition::And(parts))
}

/// Collect the `contractName`/`eventName` equalities a filter can express, so a
/// table only ever generates plans for events it could match.
fn discriminators(condition: &Condition, out: &mut (BTreeSet<String>, BTreeSet<String>)) {
    match condition {
        Condition::And(parts) | Condition::Or(parts) => {
            for part in parts {
                discriminators(part, out);
            }
        }
        Condition::Cmp { path, op, value } if *op == "eq" && path.len() == 1 => {
            if let Some(text) = value.as_str() {
                if path[0] == "contractName" {
                    out.0.insert(text.to_string());
                } else if path[0] == "eventName" {
                    out.1.insert(text.to_string());
                }
            }
        }
        Condition::In {
            path,
            negated: false,
            values,
        } if path.len() == 1 => {
            for value in values {
                if let Some(text) = value.as_str() {
                    if path[0] == "contractName" {
                        out.0.insert(text.to_string());
                    } else if path[0] == "eventName" {
                        out.1.insert(text.to_string());
                    }
                }
            }
        }
        _ => (),
    }
}

/// Partially evaluate against one candidate event: the discriminators are known,
/// everything else becomes a runtime check.
fn evaluate(
    condition: &Condition,
    contract_name: &str,
    event_name: &str,
    shape: &Shape,
    demand: &mut Demand,
    table_names: &[String],
) -> Result<Residual> {
    match condition {
        // A sibling discriminator narrows what the other conjuncts are typed
        // against, so a path that doesn't resolve on THIS candidate is only an
        // error if the candidate isn't already excluded — `eventName: Approval`
        // next to `params.owner` must not fail on the Transfer candidate.
        Condition::And(parts) => {
            let mut resolved = Vec::with_capacity(parts.len());
            let mut first_error = None;
            for part in parts {
                match evaluate(part, contract_name, event_name, shape, demand, table_names) {
                    Ok(Residual::False) => return Ok(Residual::False),
                    Ok(part) => resolved.push(part),
                    Err(error) => first_error = first_error.or(Some(error)),
                }
            }
            match first_error {
                Some(error) => Err(error),
                None => Ok(residual_and(resolved)),
            }
        }
        // Dually, a disjunct that errors can't matter once another one is
        // already `true` for this candidate.
        Condition::Or(parts) => {
            let mut resolved = Vec::with_capacity(parts.len());
            let mut first_error = None;
            for part in parts {
                match evaluate(part, contract_name, event_name, shape, demand, table_names) {
                    Ok(Residual::True) => return Ok(Residual::True),
                    Ok(part) => resolved.push(part),
                    Err(error) => first_error = first_error.or(Some(error)),
                }
            }
            match first_error {
                Some(error) => Err(error),
                None => Ok(residual_or(resolved)),
            }
        }
        Condition::Cmp { path, op, value } => {
            if let Some(known) = known_discriminator(path, contract_name, event_name) {
                if let Some(text) = value.as_str() {
                    let matches = known == text;
                    return Ok(match (*op, matches) {
                        ("eq", true) | ("ne", false) => Residual::True,
                        ("eq", false) | ("ne", true) => Residual::False,
                        _ => {
                            return Err(anyhow!(
                                "`{}` only supports `_eq`/`_ne`/`_in`",
                                path.join(".")
                            ))
                        }
                    });
                }
                return Err(anyhow!("`{}` must be compared to a string", path.join(".")));
            }
            let ctx = ExprCtx {
                shape,
                substitutions: None,
                table_names,
            };
            let target = shape
                .resolve(path, demand)
                .with_context(|| format!("in `where.{}`", path.join(".")))?;
            let compiled = compile_expr(value, &ctx, demand)
                .with_context(|| format!("in `where.{}`", path.join(".")))?;
            let value = compiled
                .coerce(&target)
                .with_context(|| format!("in `where.{}`", path.join(".")))?;
            Ok(Residual::Unknown(CFilter::Cmp {
                path: path.clone(),
                op,
                value,
            }))
        }
        Condition::In {
            path,
            negated,
            values,
        } => {
            if let Some(known) = known_discriminator(path, contract_name, event_name) {
                let mut matches = false;
                for value in values {
                    let text = value.as_str().ok_or_else(|| {
                        anyhow!("`{}` must be compared to strings", path.join("."))
                    })?;
                    matches = matches || text == known;
                }
                return Ok(if matches != *negated {
                    Residual::True
                } else {
                    Residual::False
                });
            }
            let ctx = ExprCtx {
                shape,
                substitutions: None,
                table_names,
            };
            let target = shape
                .resolve(path, demand)
                .with_context(|| format!("in `where.{}`", path.join(".")))?;
            let compiled = values
                .iter()
                .map(|value| {
                    compile_expr(value, &ctx, demand).and_then(|compiled| compiled.coerce(&target))
                })
                .collect::<Result<Vec<_>>>()
                .with_context(|| format!("in `where.{}`", path.join(".")))?;
            Ok(Residual::Unknown(CFilter::In {
                path: path.clone(),
                negated: *negated,
                values: compiled,
            }))
        }
    }
}

fn known_discriminator<'a>(
    path: &[String],
    contract_name: &'a str,
    event_name: &'a str,
) -> Option<&'a str> {
    if path.len() != 1 {
        return None;
    }
    match path[0].as_str() {
        "contractName" => Some(contract_name),
        "eventName" => Some(event_name),
        _ => None,
    }
}

//
// ── Compilation ────────────────────────────────────────────────────────────
//

/// A table's compiled schema, before it is rendered as SDL.
struct TableSchema {
    name: String,
    cross_chain: bool,
    /// `(field name as written, GraphQL type, derived-from target)`
    fields: Vec<(String, String, Option<String>)>,
}

impl TableSchema {
    fn to_sdl(&self) -> String {
        let mut sdl = format!(
            "type {}{} {{\n",
            self.name,
            if self.cross_chain { " @crossChain" } else { "" }
        );
        for (name, gql_type, derived_from) in &self.fields {
            match derived_from {
                Some(field) => sdl.push_str(&format!(
                    "  {name}: {gql_type} @derivedFrom(field: \"{field}\")\n"
                )),
                None => sdl.push_str(&format!("  {name}: {gql_type}\n")),
            }
        }
        sdl.push_str("}\n");
        sdl
    }
}

/// A `select` field's resolved shape, unified across the union's branches.
struct FieldShape {
    name: String,
    ty: Ty,
    /// The target field on the other table, for `_derived_from`. A derived field
    /// is virtual: it appears in the schema but never in a write.
    derived_from: Option<String>,
    is_ref: bool,
}

/// One resolved union branch of a materialized table.
struct Branch {
    contract_name: String,
    event_name: String,
    filter: Option<CFilter>,
    /// Column expressions, for a table reading from a `with` relation.
    columns: IndexMap<String, CExpr>,
}

pub fn compile(
    tables: &Tables,
    contracts: &BTreeMap<String, &Contract>,
    schema: &Schema,
) -> Result<Compiled> {
    let table_names: Vec<String> = tables.0.keys().cloned().collect();
    for name in &table_names {
        if schema.entities.contains_key(name) {
            return Err(anyhow!(
                "Table `{name}` is declared in `tables` and as an entity in schema.graphql. A \
                 table has exactly one definition — remove one of them."
            ));
        }
    }

    let all_evm = FieldSelection::all_evm();
    let block_field_types = field_type_table(&all_evm.block_fields, true);
    let transaction_field_types = field_type_table(&all_evm.transaction_fields, false);

    let mut schemas = Vec::new();
    let mut materializations = Vec::new();
    let mut demand = DemandByEvent::default();

    for (table_name, table) in &tables.0 {
        let compiled = compile_table(
            table_name,
            table,
            &table_names,
            contracts,
            &block_field_types,
            &transaction_field_types,
            &mut demand,
        )
        .with_context(|| format!("Failed compiling table `{table_name}`"))?;
        schemas.push(compiled.0);
        materializations.extend(compiled.1);
    }

    let sdl = schemas
        .iter()
        .map(TableSchema::to_sdl)
        .collect::<Vec<_>>()
        .join("\n");

    Ok(Compiled {
        sdl,
        materializations,
        field_demand: demand,
    })
}

fn field_type_table(fields: &[SelectedField], is_block: bool) -> BTreeMap<String, Ty> {
    let mut table: BTreeMap<String, Ty> = fields
        .iter()
        .map(|field| (field.name.clone(), ty_from_type_ident(&field.data_type)))
        .collect();
    if is_block {
        table.insert("number".to_string(), Ty::new(Scalar::Int));
        table.insert("timestamp".to_string(), Ty::new(Scalar::Int));
        table.insert("hash".to_string(), Ty::new(Scalar::String));
    }
    table
}

#[allow(clippy::type_complexity)]
fn compile_table(
    table_name: &str,
    table: &TableConfig,
    table_names: &[String],
    contracts: &BTreeMap<String, &Contract>,
    block_field_types: &BTreeMap<String, Ty>,
    transaction_field_types: &BTreeMap<String, Ty>,
    demand: &mut DemandByEvent,
) -> Result<(TableSchema, Vec<Materialization>)> {
    let select = &table.select;
    let from = table.from.as_str();
    if !select.contains_key("id") {
        return Err(anyhow!("every table must select an `id`"));
    }

    // Resolve `from` to the branches that feed the outer `select`. Reading a
    // relation means one branch per union arm; reading the source directly is
    // the single-branch case with no columns to substitute.
    let (branches, relation_columns) = match table.with.as_ref().and_then(|with| with.get(from)) {
        Some(queries) => {
            // No defined meaning yet, and dropping it silently would
            // materialize rows the user asked to exclude.
            if table.filter.is_some() {
                return Err(anyhow!(
                    "`where` is not supported on a table reading a `with` relation. Put the \
                     filter on the relation's queries instead."
                ));
            }
            compile_relation(
                from,
                queries,
                table_names,
                contracts,
                block_field_types,
                transaction_field_types,
                demand,
            )?
        }
        None => {
            // A relation is only reachable through `from`, so declaring one and
            // then reading something else leaves it dead — almost always a typo.
            if let Some(with) = &table.with {
                if !with.is_empty() {
                    return Err(anyhow!(
                        "`from: {from}` doesn't read any of this table's `with` relations ({}), \
                         which are only usable through `from`.",
                        with.keys().cloned().collect::<Vec<_>>().join(", ")
                    ));
                }
            }
            if from != EVM_EVENTS_SOURCE {
                return Err(anyhow!(
                    "`from: {from}` is not a known source. Use `{EVM_EVENTS_SOURCE}`, or one of \
                     this table's `with` relations."
                ));
            }
            let condition = table
                .filter
                .as_ref()
                .map(|filter| parse_filter(&filter.0))
                .transpose()
                .context("in `where`")?;
            let branches = resolve_event_branches(
                condition.as_ref(),
                contracts,
                block_field_types,
                transaction_field_types,
                demand,
                table_names,
            )?
            .into_iter()
            .map(|(contract_name, event_name, filter)| Branch {
                contract_name,
                event_name,
                filter,
                columns: IndexMap::new(),
            })
            .collect();
            (branches, None)
        }
    };

    if branches.is_empty() {
        return Err(anyhow!(
            "`where` matches no configured event, so the table could never be written"
        ));
    }

    // Compile the outer select once per branch. Types are unified across
    // branches, which is what makes a union's arms interchangeable.
    let mut declared: Option<Vec<FieldShape>> = None;
    let mut plans = Vec::new();

    for branch in &branches {
        let contract = contracts
            .get(&branch.contract_name)
            .ok_or_else(|| anyhow!("contract `{}` is not configured", branch.contract_name))?;
        let event = contract
            .events
            .iter()
            .find(|event| event.name == branch.event_name)
            .ok_or_else(|| {
                anyhow!(
                    "event `{}` is not configured on contract `{}`",
                    branch.event_name,
                    branch.contract_name
                )
            })?;
        let event_shape = Shape::Event {
            contract_name: &branch.contract_name,
            event,
            block_fields: block_field_types,
            transaction_fields: transaction_field_types,
        };
        let (shape, substitutions) = match &relation_columns {
            Some((name, columns)) => (Shape::Relation { name, columns }, Some(&branch.columns)),
            None => (event_shape, None),
        };
        let ctx = ExprCtx {
            shape: &shape,
            substitutions,
            table_names,
        };

        let mut branch_demand = Demand::default();
        let mut resolved = Vec::with_capacity(select.len());
        for (field_name, value) in select {
            let selected = compile_selected(&value.0, &ctx, &mut branch_demand)
                .with_context(|| format!("in `select.{field_name}`"))?;
            resolved.push((field_name.clone(), selected));
        }
        demand.merge(&branch.contract_name, &branch.event_name, branch_demand);

        let shapes: Vec<FieldShape> = resolved
            .iter()
            .map(|(field_name, selected)| {
                let name = field_name.clone();
                match selected {
                    Selected::Value(typed) | Selected::Sum(typed) => FieldShape {
                        name,
                        ty: typed.ty.clone(),
                        derived_from: None,
                        is_ref: false,
                    },
                    Selected::Ref { table, id } => FieldShape {
                        name,
                        ty: Ty {
                            scalar: Scalar::Ref(table.clone()),
                            nullable: id.ty.nullable,
                            array: false,
                        },
                        derived_from: None,
                        is_ref: true,
                    },
                    Selected::DerivedFrom { table, field } => FieldShape {
                        name,
                        ty: Ty::new(Scalar::Ref(table.clone())).array(),
                        derived_from: Some(field.clone()),
                        is_ref: false,
                    },
                }
            })
            .collect();

        match &mut declared {
            None => declared = Some(shapes),
            Some(declared) => {
                if declared.len() != shapes.len() {
                    return Err(anyhow!(
                        "the union branches select different fields for `{table_name}`"
                    ));
                }
                for (existing, incoming) in declared.iter_mut().zip(shapes) {
                    if existing.name != incoming.name {
                        return Err(anyhow!(
                            "the union branches select different fields for `{table_name}`: `{}` \
                             vs `{}`",
                            existing.name,
                            incoming.name
                        ));
                    }
                    existing.ty = unify(&existing.ty, &incoming.ty).with_context(|| {
                        format!(
                            "the union branches disagree on the type of `{}`",
                            existing.name
                        )
                    })?;
                }
            }
        }

        plans.push((branch, resolved));
    }

    let declared = declared.expect("branches is non-empty");

    // Now that every branch has been seen, the declared types are final; write
    // the plans against them so a widened literal serializes as the right type.
    let mut materializations = Vec::with_capacity(plans.len());
    for (branch, resolved) in plans {
        let mut id = None;
        let mut fields = Vec::new();
        for ((field_name, selected), shape) in resolved.into_iter().zip(&declared) {
            let ty = &shape.ty;
            // A reducer's numeric type is read off the unified column, not off
            // this branch's own expression: a `0` in one branch and a BigInt in
            // another must agree on the zero the reducer starts from.
            let (op, numeric_type, expr) = match selected {
                Selected::Value(typed) => (
                    "set",
                    None,
                    typed
                        .coerce(ty)
                        .with_context(|| format!("in `select.{field_name}`"))?,
                ),
                Selected::Sum(typed) => (
                    "sum",
                    ty.numeric_tag(),
                    typed
                        .coerce(ty)
                        .with_context(|| format!("in `select.{field_name}`"))?,
                ),
                Selected::Ref { id, .. } => {
                    let target = Ty {
                        scalar: Scalar::String,
                        nullable: ty.nullable,
                        array: false,
                    };
                    (
                        "set",
                        None,
                        id.coerce(&target)
                            .with_context(|| format!("in `select.{field_name}._ref.id`"))?,
                    )
                }
                Selected::DerivedFrom { .. } => continue,
            };
            if field_name == "id" {
                if op == "sum" {
                    return Err(anyhow!(
                        "`select.id` can't be a `_sum` — the id is the key contributions group by"
                    ));
                }
                id = Some(expr);
                continue;
            }
            fields.push(FieldWrite {
                // A reference is stored under the `_id` column the entity API
                // exposes, which is what the runtime writes.
                name: if shape.is_ref {
                    format!("{field_name}_id")
                } else {
                    field_name.clone()
                },
                op,
                numeric_type,
                expr,
            });
        }
        materializations.push(Materialization {
            table: table_name.to_string(),
            // The runtime's chain configs carry capitalized contract names, so
            // the plan has to match or its registration finds no contract.
            contract_name: branch.contract_name.capitalize(),
            event_name: branch.event_name.clone(),
            wildcard: table.wildcard.unwrap_or(false),
            filter: branch.filter.clone(),
            id: id.ok_or_else(|| anyhow!("every table must select an `id`"))?,
            fields,
        });
    }

    // Reject an id that storage can't key on before the mismatch reaches
    // codegen, where the message no longer mentions the table.
    let id_ty = &declared
        .iter()
        .find(|shape| shape.name == "id")
        .expect("id is required above")
        .ty;
    if id_ty.nullable || id_ty.array {
        return Err(anyhow!(
            "`select.id` must be a non-null scalar, but it is {}",
            id_ty.describe()
        ));
    }
    if !matches!(
        id_ty.scalar,
        Scalar::String | Scalar::Int | Scalar::BigInt | Scalar::NumLit
    ) {
        return Err(anyhow!(
            "`select.id` is {}, which can't be an id. Use String, Int or BigInt.",
            id_ty.describe()
        ));
    }

    let fields = declared
        .iter()
        .map(|shape| {
            let gql_type = shape
                .ty
                .to_gql(shape.name == "id")
                .with_context(|| format!("in `select.{}`", shape.name))?;
            Ok((shape.name.clone(), gql_type, shape.derived_from.clone()))
        })
        .collect::<Result<Vec<_>>>()?;

    Ok((
        TableSchema {
            name: table_name.to_string(),
            cross_chain: table.cross_chain.unwrap_or(false),
            fields,
        },
        materializations,
    ))
}

/// Compile the union branches of a `with` relation and unify their columns.
#[allow(clippy::type_complexity)]
fn compile_relation(
    relation_name: &str,
    queries: &Queries,
    table_names: &[String],
    contracts: &BTreeMap<String, &Contract>,
    block_field_types: &BTreeMap<String, Ty>,
    transaction_field_types: &BTreeMap<String, Ty>,
    demand: &mut DemandByEvent,
) -> Result<(Vec<Branch>, Option<(String, IndexMap<String, Ty>)>)> {
    if queries.0.is_empty() {
        return Err(anyhow!(
            "`with.{relation_name}` must have at least one query"
        ));
    }

    let mut branches: Vec<Branch> = Vec::new();
    // Per-branch column types, unified once every branch has been compiled.
    let mut column_types: Option<IndexMap<String, Ty>> = None;
    let mut pending: Vec<(usize, IndexMap<String, Typed>)> = Vec::new();

    for (query_index, query) in queries.0.iter().enumerate() {
        if query.from != EVM_EVENTS_SOURCE {
            return Err(anyhow!(
                "`with.{relation_name}[{query_index}].from` is `{}`, but a relation can only read \
                 `{EVM_EVENTS_SOURCE}`",
                query.from
            ));
        }
        let condition = query
            .filter
            .as_ref()
            .map(|filter| parse_filter(&filter.0))
            .transpose()
            .with_context(|| format!("in `with.{relation_name}[{query_index}].where`"))?;
        let events = resolve_event_branches(
            condition.as_ref(),
            contracts,
            block_field_types,
            transaction_field_types,
            demand,
            table_names,
        )
        .with_context(|| format!("in `with.{relation_name}[{query_index}]`"))?;
        if events.is_empty() {
            return Err(anyhow!(
                "`with.{relation_name}[{query_index}].where` matches no configured event"
            ));
        }

        for (contract_name, event_name, filter) in events {
            let contract = contracts
                .get(&contract_name)
                .ok_or_else(|| anyhow!("contract `{contract_name}` is not configured"))?;
            let event = contract
                .events
                .iter()
                .find(|event| event.name == event_name)
                .ok_or_else(|| {
                    anyhow!("event `{event_name}` is not configured on `{contract_name}`")
                })?;
            let shape = Shape::Event {
                contract_name: &contract_name,
                event,
                block_fields: block_field_types,
                transaction_fields: transaction_field_types,
            };
            let ctx = ExprCtx {
                shape: &shape,
                substitutions: None,
                table_names,
            };
            let mut branch_demand = Demand::default();
            let mut columns: IndexMap<String, Typed> = IndexMap::new();
            for (column_name, value) in &query.select {
                let typed =
                    compile_expr(&value.0, &ctx, &mut branch_demand).with_context(|| {
                        format!("in `with.{relation_name}[{query_index}].select.{column_name}`")
                    })?;
                columns.insert(column_name.clone(), typed);
            }
            demand.merge(&contract_name, &event_name, branch_demand);

            match &mut column_types {
                None => {
                    column_types = Some(
                        columns
                            .iter()
                            .map(|(name, typed)| (name.clone(), typed.ty.clone()))
                            .collect(),
                    );
                }
                Some(existing) => {
                    if existing.len() != columns.len() || existing.keys().ne(columns.keys()) {
                        return Err(anyhow!(
                            "the branches of `with.{relation_name}` must select the same columns, \
                             but got [{}] and [{}]",
                            existing.keys().cloned().collect::<Vec<_>>().join(", "),
                            columns.keys().cloned().collect::<Vec<_>>().join(", ")
                        ));
                    }
                    for (name, ty) in existing.iter_mut() {
                        let incoming = &columns.get(name).expect("keys were compared above").ty;
                        *ty = unify(ty, incoming).with_context(|| {
                            format!(
                                "the branches of `with.{relation_name}` disagree on the type of \
                                 `{name}`"
                            )
                        })?;
                    }
                }
            }

            branches.push(Branch {
                contract_name,
                event_name,
                filter,
                columns: IndexMap::new(),
            });
            pending.push((branches.len() - 1, columns));
        }
    }

    let column_types = column_types.expect("queries is non-empty");
    for (branch_index, columns) in pending {
        let branch = &mut branches[branch_index];
        for (name, typed) in columns {
            let target = column_types
                .get(&name)
                .expect("every branch selects the same columns");
            let expr = typed
                .coerce(target)
                .with_context(|| format!("in `with.{relation_name}` column `{name}`"))?;
            branch.columns.insert(name, expr);
        }
    }

    Ok((branches, Some((relation_name.to_string(), column_types))))
}

/// Every configured (contract, event) a filter could match, with the part of the
/// filter the runtime still has to check.
#[allow(clippy::type_complexity)]
fn resolve_event_branches(
    condition: Option<&Condition>,
    contracts: &BTreeMap<String, &Contract>,
    block_field_types: &BTreeMap<String, Ty>,
    transaction_field_types: &BTreeMap<String, Ty>,
    demand: &mut DemandByEvent,
    table_names: &[String],
) -> Result<Vec<(String, String, Option<CFilter>)>> {
    let mut named = (BTreeSet::new(), BTreeSet::new());
    if let Some(condition) = condition {
        discriminators(condition, &mut named);
    }
    for contract_name in &named.0 {
        if !contracts.contains_key(contract_name) {
            return Err(anyhow!(
                "`contractName: {contract_name}` is not configured. Configured contracts: {}",
                contracts.keys().cloned().collect::<Vec<_>>().join(", ")
            ));
        }
    }
    if !named.1.is_empty() {
        let configured: BTreeSet<&str> = contracts
            .values()
            .flat_map(|contract| contract.events.iter().map(|event| event.name.as_str()))
            .collect();
        for event_name in &named.1 {
            if !configured.contains(event_name.as_str()) {
                return Err(anyhow!(
                    "`eventName: {event_name}` is not configured on any contract. Configured \
                     events: {}",
                    configured.iter().copied().collect::<Vec<_>>().join(", ")
                ));
            }
        }
    }

    let mut branches = Vec::new();
    for (contract_name, contract) in contracts {
        for event in &contract.events {
            let filter = match condition {
                None => None,
                Some(condition) => {
                    let shape = Shape::Event {
                        contract_name,
                        event,
                        block_fields: block_field_types,
                        transaction_fields: transaction_field_types,
                    };
                    // Field demand is only real for branches that survive, so
                    // it is collected into a scratch set and merged on success.
                    let mut branch_demand = Demand::default();
                    let residual = evaluate(
                        condition,
                        contract_name,
                        &event.name,
                        &shape,
                        &mut branch_demand,
                        table_names,
                    )?;
                    match residual {
                        Residual::False => continue,
                        Residual::True => {
                            demand.merge(contract_name, &event.name, branch_demand);
                            None
                        }
                        Residual::Unknown(filter) => {
                            demand.merge(contract_name, &event.name, branch_demand);
                            Some(filter)
                        }
                    }
                }
            };
            branches.push((contract_name.clone(), event.name.clone(), filter));
        }
    }
    Ok(branches)
}

/// `_ref` and `_derived_from` name tables, and the generated SDL uses those
/// names verbatim — so a table name has to be a usable GraphQL type name.
pub fn validate_table_names(tables: &Tables) -> Result<()> {
    for name in tables.0.keys() {
        // No leading underscore: `capitalize` leaves `_` unchanged, so it
        // would reach codegen as an invalid ReScript module name.
        let mut chars = name.chars();
        let valid = matches!(chars.next(), Some(c) if c.is_ascii_alphabetic())
            && chars.all(|c| c.is_ascii_alphanumeric() || c == '_');
        if !valid {
            return Err(anyhow!(
                "Table name `{name}` is not a valid identifier. Use letters, digits and \
                 underscores, starting with a letter."
            ));
        }
        if name.capitalize() != *name && tables.0.contains_key(&name.capitalize()) {
            return Err(anyhow!(
                "Tables `{name}` and `{}` differ only by case, which the generated code can't \
                 tell apart.",
                name.capitalize()
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod test {
    use crate::config_parsing::system_config::SystemConfig;
    use std::collections::HashMap;

    const ERC20_YAML: &str = r#"
name: erc20-indexer
disable_default_cross_chain: true
contracts:
  - name: ERC20
    events:
      - event: "Approval(address indexed owner, address indexed spender, uint256 value)"
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
tables:
  accounts:
    with:
      balance_changes:
        - from: evm.events
          where:
            contractName: ERC20
            eventName: Approval
          select:
            account: params.owner
            delta: 0
        - from: evm.events
          where:
            contractName: ERC20
            eventName: Approval
          select:
            account: params.spender
            delta: 0
        - from: evm.events
          where:
            contractName: ERC20
            eventName: Transfer
          select:
            account: params.from
            delta:
              _negate: params.value
        - from: evm.events
          where:
            contractName: ERC20
            eventName: Transfer
          select:
            account: params.to
            delta: params.value
    from: balance_changes
    select:
      id: account
      balance:
        _sum: delta
      approvals:
        _derived_from: approvals.owner
  approvals:
    from: evm.events
    where:
      contractName: ERC20
      eventName: Approval
    select:
      id:
        _concat:
          separator: "-"
          values:
            - params.owner
            - params.spender
      amount: params.value
      owner:
        _ref:
          table: accounts
          id: params.owner
      spender:
        _ref:
          table: accounts
          id: params.spender
"#;

    pub(super) fn parse(yaml: &str) -> anyhow::Result<SystemConfig> {
        SystemConfig::parse_yaml(yaml, None, &HashMap::new(), &HashMap::new(), false)
    }

    fn parse_error(yaml: &str) -> String {
        format!("{:#}", parse(yaml).expect_err("expected a config error"))
    }

    /// The ERC-20 template's config, which is the reference case: keyed
    /// overwrite, two events, a union, an aggregate, references and an inverse
    /// relationship.
    #[test]
    fn compiles_the_erc20_tables() {
        let config = parse(ERC20_YAML).expect("erc20 tables should compile");

        // The inferred schema, as the runtime and the database see it.
        let public: serde_json::Value =
            serde_json::from_str(&config.to_public_config_json(false).expect("public config"))
                .expect("valid json");
        assert_eq!(
            public["entities"],
            serde_json::json!([
                {
                    "name": "accounts",
                    "properties": [
                        {"name": "id", "type": "string"},
                        {"name": "balance", "type": "bigint"}
                    ],
                    "derivedFields": [{
                        "fieldName": "approvals",
                        "derivedFromEntity": "approvals",
                        "derivedFromField": "owner"
                    }]
                },
                {
                    "name": "approvals",
                    "properties": [
                        {"name": "id", "type": "string"},
                        {"name": "amount", "type": "bigint"},
                        // `_ref` stores the target's id and marks the relation.
                        {"name": "owner", "type": "string", "linkedEntity": "accounts"},
                        {"name": "spender", "type": "string", "linkedEntity": "accounts"}
                    ]
                }
            ])
        );

        // Four union branches for `accounts` plus one keyed write for
        // `approvals`, each bound to the event it reads.
        assert_eq!(
            config
                .materializations
                .iter()
                .map(|m| format!("{}<-{}.{}", m.table, m.contract_name, m.event_name))
                .collect::<Vec<_>>(),
            vec![
                "accounts<-ERC20.Approval",
                "accounts<-ERC20.Approval",
                "accounts<-ERC20.Transfer",
                "accounts<-ERC20.Transfer",
                "approvals<-ERC20.Approval",
            ]
        );

        assert_eq!(
            serde_json::to_value(&config.materializations).expect("serializable"),
            serde_json::json!([
                {
                    "table": "accounts",
                    "contractName": "ERC20",
                    "eventName": "Approval",
                    "id": {"kind": "path", "path": ["params", "owner"]},
                    "fields": [{
                        "name": "balance",
                        "op": "sum",
                        "type": "bigint",
                        // The `0` literal widened to BigInt from its siblings.
                        "expr": {"kind": "bigint", "value": "0"}
                    }]
                },
                {
                    "table": "accounts",
                    "contractName": "ERC20",
                    "eventName": "Approval",
                    "id": {"kind": "path", "path": ["params", "spender"]},
                    "fields": [{
                        "name": "balance",
                        "op": "sum",
                        "type": "bigint",
                        "expr": {"kind": "bigint", "value": "0"}
                    }]
                },
                {
                    "table": "accounts",
                    "contractName": "ERC20",
                    "eventName": "Transfer",
                    "id": {"kind": "path", "path": ["params", "from"]},
                    "fields": [{
                        "name": "balance",
                        "op": "sum",
                        "type": "bigint",
                        "expr": {
                            "kind": "negate",
                            "type": "bigint",
                            "expr": {"kind": "path", "path": ["params", "value"]}
                        }
                    }]
                },
                {
                    "table": "accounts",
                    "contractName": "ERC20",
                    "eventName": "Transfer",
                    "id": {"kind": "path", "path": ["params", "to"]},
                    "fields": [{
                        "name": "balance",
                        "op": "sum",
                        "type": "bigint",
                        "expr": {"kind": "path", "path": ["params", "value"]}
                    }]
                },
                {
                    "table": "approvals",
                    "contractName": "ERC20",
                    "eventName": "Approval",
                    "id": {
                        "kind": "concat",
                        "separator": "-",
                        "values": [
                            {"kind": "path", "path": ["params", "owner"]},
                            {"kind": "path", "path": ["params", "spender"]}
                        ]
                    },
                    "fields": [
                        {"name": "amount", "op": "set", "expr": {"kind": "path", "path": ["params", "value"]}},
                        {"name": "owner_id", "op": "set", "expr": {"kind": "path", "path": ["params", "owner"]}},
                        {"name": "spender_id", "op": "set", "expr": {"kind": "path", "path": ["params", "spender"]}}
                    ]
                }
            ])
        );
    }

    #[test]
    fn narrows_types_per_event_and_reports_unknown_paths() {
        let yaml = ERC20_YAML.replace("account: params.owner", "account: params.owenr");
        assert!(
            parse_error(&yaml).contains("`ERC20.Approval` has no parameter `owenr`"),
            "{}",
            parse_error(&yaml)
        );
    }

    #[test]
    fn rejects_a_union_whose_branches_disagree() {
        let yaml = ERC20_YAML.replace(
            "            account: params.spender\n            delta: 0",
            "            account: params.spender\n            delta:\n              _literal: nope",
        );
        let error = parse_error(&yaml);
        assert!(
            error.contains("disagree on the type of `delta`") && error.contains("String!"),
            "{error}"
        );
    }

    /// `_and`/`_or` nest, and a filter that pins no discriminator in a branch
    /// still narrows to the events the conjunction allows.
    #[test]
    fn compiles_nested_boolean_filters_into_a_runtime_residual() {
        let yaml = r#"
name: t
disable_default_cross_chain: true
contracts:
  - name: ERC20
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
tables:
  transfers:
    from: evm.events
    where:
      _and:
        - contractName: ERC20
          eventName: Transfer
        - _or:
            - chainId: 1
              block:
                number:
                  _gte: 4000
            - chainId: 100
    select:
      id: transaction.hash
      value: params.value
"#;
        let config = parse(yaml).expect("filter config should compile");
        assert_eq!(
            serde_json::to_value(&config.materializations).expect("serializable"),
            serde_json::json!([{
                "table": "transfers",
                "contractName": "ERC20",
                "eventName": "Transfer",
                "filter": {
                    "kind": "or",
                    "filters": [
                        {
                            "kind": "and",
                            "filters": [
                                {"kind": "cmp", "path": ["chainId"], "op": "eq", "value": {"kind": "int", "value": 1}},
                                {"kind": "cmp", "path": ["block", "number"], "op": "gte", "value": {"kind": "int", "value": 4000}}
                            ]
                        },
                        {"kind": "cmp", "path": ["chainId"], "op": "eq", "value": {"kind": "int", "value": 100}}
                    ]
                },
                "id": {"kind": "path", "path": ["transaction", "hash"]},
                "fields": [{"name": "value", "op": "set", "expr": {"kind": "path", "path": ["params", "value"]}}]
            }])
        );
        // Selecting `transaction.hash` is what makes it get fetched — and it
        // lands on the event that carries it, not on every event globally.
        let event = &config
            .get_contract(&"ERC20".to_string())
            .expect("ERC20")
            .events[0];
        assert_eq!(
            event.field_selection.as_ref().map(|selection| (
                selection
                    .block_fields
                    .iter()
                    .map(|f| f.name.clone())
                    .collect::<Vec<_>>(),
                selection
                    .transaction_fields
                    .iter()
                    .map(|f| f.name.clone())
                    .collect::<Vec<_>>()
            )),
            Some((vec![], vec!["hash".to_string()]))
        );
        assert!(config.field_selection.transaction_fields.is_empty());
    }

    // The discriminators in an AND narrow which paths the rest of the filter is
    // typed against, so `params.owner` must not error on the Transfer candidate
    // the `eventName: Approval` conjunct already excluded.
    #[test]
    fn narrows_param_filters_by_the_sibling_discriminator() {
        let yaml = ERC20_YAML.replace(
            "  approvals:\n    from: evm.events\n    where:\n      contractName: ERC20\n      \
             eventName: Approval",
            "  approvals:\n    from: evm.events\n    where:\n      contractName: ERC20\n      \
             eventName: Approval\n      params:\n        owner:\n          _ne:\n            \
             _literal: \"0x0000000000000000000000000000000000000000\"",
        );
        let config = parse(&yaml).expect("param filter narrowed by discriminator should compile");
        let approval_plans: Vec<_> = config
            .materializations
            .iter()
            .filter(|m| m.table == "approvals")
            .collect();
        assert_eq!(
            serde_json::to_value(&approval_plans[0].filter).expect("serializable"),
            serde_json::json!({
                "kind": "cmp",
                "path": ["params", "owner"],
                "op": "ne",
                "value": {"kind": "string", "value": "0x0000000000000000000000000000000000000000"}
            })
        );
    }

    // `where` on a table reading a relation has no defined meaning yet; dropping
    // it silently would materialize rows the user asked to exclude.
    #[test]
    fn rejects_an_outer_where_on_a_relation_fed_table() {
        let yaml = ERC20_YAML.replace(
            "    from: balance_changes\n    select:",
            "    from: balance_changes\n    where:\n      chainId: 1\n    select:",
        );
        let error = parse_error(&yaml);
        assert!(
            error.contains("`where` is not supported on a table reading a `with` relation"),
            "{error}"
        );
    }

    // The id is the grouping key a reducer folds into, so reducing the id
    // itself has no meaning.
    #[test]
    fn rejects_a_sum_id() {
        let yaml = ERC20_YAML.replace(
            "    select:\n      id: account",
            "    select:\n      id:\n        _sum: delta",
        );
        let error = parse_error(&yaml);
        assert!(error.contains("`select.id` can't be a `_sum`"), "{error}");
    }

    // An unwidened integer literal becomes an Int column, so a literal outside
    // i32 has to fail at codegen rather than on the first Postgres insert.
    #[test]
    fn rejects_an_int_literal_out_of_i32_range() {
        let yaml = ERC20_YAML.replace("      amount: params.value", "      amount: 5000000000");
        let error = parse_error(&yaml);
        assert!(error.contains("outside the Int (32-bit) range"), "{error}");
    }

    // `capitalize` leaves `_` unchanged, so a leading underscore would reach
    // codegen as an invalid ReScript module name.
    #[test]
    fn rejects_a_leading_underscore_table_name() {
        let yaml = ERC20_YAML.replace("  approvals:", "  _approvals:").replace(
            "        _derived_from: approvals.owner",
            "        _derived_from: _approvals.owner",
        );
        let error = parse_error(&yaml);
        assert!(error.contains("is not a valid identifier"), "{error}");
    }

    // Shared rows across chains would make the same id on two chains collide,
    // which for a token indexer silently merges balances.
    #[test]
    fn requires_per_chain_entities() {
        let yaml = ERC20_YAML.replace("disable_default_cross_chain: true\n", "");
        let error = parse_error(&yaml);
        assert!(
            error.contains("`tables` needs `disable_default_cross_chain: true`")
                && error.contains("`cross_chain: true`"),
            "{error}"
        );
    }

    #[test]
    fn rejects_a_string_literal_written_without_underscore_literal() {
        let yaml = ERC20_YAML.replace("amount: params.value", "amount: approved");
        assert!(
            parse_error(&yaml).contains("`approved` is not a field of `evm.events`"),
            "{}",
            parse_error(&yaml)
        );
    }
}

#[cfg(test)]
mod expression_test {
    use super::test::parse;

    fn config_with(select: &str) -> String {
        format!(
            r#"
name: t
disable_default_cross_chain: true
contracts:
  - name: ERC20
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
tables:
  rows:
{select}
"#
        )
    }

    // A negated literal has to stay a literal, or widening it to the BigInt its
    // sibling branch produces has nothing to rewrite.
    #[test]
    fn widens_a_negated_literal_to_its_sibling_branchs_type() {
        let yaml = config_with(
            r#"    with:
      changes:
        - from: evm.events
          where:
            eventName: Transfer
          select:
            key: params.from
            delta:
              _negate: 1
        - from: evm.events
          where:
            eventName: Transfer
          select:
            key: params.to
            delta: params.value
    from: changes
    select:
      id: key
      total:
        _sum: delta"#,
        );
        let config = parse(&yaml).expect("negated literal should widen");
        assert_eq!(
            serde_json::to_value(&config.materializations).expect("serializable"),
            serde_json::json!([
                {
                    "table": "rows",
                    "contractName": "ERC20",
                    "eventName": "Transfer",
                    "id": {"kind": "path", "path": ["params", "from"]},
                    "fields": [{
                        "name": "total",
                        "op": "sum",
                        "type": "bigint",
                        "expr": {"kind": "bigint", "value": "-1"}
                    }]
                },
                {
                    "table": "rows",
                    "contractName": "ERC20",
                    "eventName": "Transfer",
                    "id": {"kind": "path", "path": ["params", "to"]},
                    "fields": [{
                        "name": "total",
                        "op": "sum",
                        "type": "bigint",
                        "expr": {"kind": "path", "path": ["params", "value"]}
                    }]
                }
            ])
        );
    }

    // `_literal` is the only way to write a string constant: a plain string is a
    // source path, so a typo can't silently become data.
    #[test]
    fn compiles_a_string_literal() {
        let yaml = config_with(
            r#"    from: evm.events
    where:
      eventName: Transfer
    select:
      id: params.from
      kind:
        _literal: transfer"#,
        );
        let config = parse(&yaml).expect("literals should compile");
        let public: serde_json::Value =
            serde_json::from_str(&config.to_public_config_json(false).expect("public config"))
                .expect("valid json");
        assert_eq!(
            public["entities"][0]["properties"],
            serde_json::json!([
                {"name": "id", "type": "string"},
                {"name": "kind", "type": "string"}
            ])
        );
        assert_eq!(
            serde_json::to_value(&config.materializations[0].fields).expect("serializable"),
            serde_json::json!([
                {"name": "kind", "op": "set", "expr": {"kind": "string", "value": "transfer"}}
            ])
        );
    }

    // Fetch demand is per event, not per source: an event no table reads keeps
    // paying nothing, and one that is read adds its fields on top of whatever
    // the global `field_selection` already asked for.
    #[test]
    fn adds_field_demand_only_to_the_events_that_carry_it() {
        let yaml = r#"
name: t
disable_default_cross_chain: true
field_selection:
  transaction_fields:
    - gasPrice
contracts:
  - name: ERC20
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
      - event: "Approval(address indexed owner, address indexed spender, uint256 value)"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
tables:
  transfers:
    from: evm.events
    where:
      eventName: Transfer
    select:
      id: transaction.hash
      miner: block.miner
"#;
        let config = parse(yaml).expect("per-event demand should compile");
        let public: serde_json::Value =
            serde_json::from_str(&config.to_public_config_json(false).expect("public config"))
                .expect("valid json");
        let events = &public["evm"]["contracts"]["ERC20"]["events"];
        assert_eq!(
            events,
            &serde_json::json!([
                {
                    "name": "Transfer",
                    "sighash": "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
                    "params": [
                        {"name": "from", "abiType": "address", "indexed": true},
                        {"name": "to", "abiType": "address", "indexed": true},
                        {"name": "value", "abiType": "uint256"}
                    ],
                    // Its own two fields, plus the global `gasPrice` it would
                    // have inherited had it not overridden the selection.
                    "blockFields": ["miner"],
                    "transactionFields": ["gasPrice", "hash"]
                },
                {
                    "name": "Approval",
                    "sighash": "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925",
                    "params": [
                        {"name": "owner", "abiType": "address", "indexed": true},
                        {"name": "spender", "abiType": "address", "indexed": true},
                        {"name": "value", "abiType": "uint256"}
                    ]
                }
            ])
        );
    }

    // `with` relations are only reachable through `from`, so an unread one is
    // dead config rather than a table that quietly reads every event.
    #[test]
    fn rejects_a_with_relation_that_from_never_reads() {
        let yaml = config_with(
            r#"    with:
      changes:
        - from: evm.events
          select:
            key: params.from
    from: evm.events
    select:
      id: params.from"#,
        );
        let error = format!("{:#}", parse(&yaml).expect_err("expected a config error"));
        assert!(
            error.contains("doesn't read any of this table's `with` relations (changes)"),
            "{error}"
        );
    }

    #[test]
    fn shares_a_cross_chain_table_across_chains() {
        let yaml = config_with(
            r#"    cross_chain: true
    from: evm.events
    select:
      id: params.from
      last:
        _sum: params.value"#,
        );
        let config = parse(&yaml).expect("cross_chain table should compile");
        let public: serde_json::Value =
            serde_json::from_str(&config.to_public_config_json(false).expect("public config"))
                .expect("valid json");
        assert_eq!(public["entities"][0]["crossChain"], serde_json::json!(true));
    }
}

#[cfg(test)]
mod ecosystem_test {
    use crate::config_parsing::system_config::SystemConfig;
    use std::collections::HashMap;

    // `tables` lives on the EVM config only; a fuel/svm config using it must be
    // rejected loudly, not silently ignored (serde's deny_unknown_fields does
    // not fire through `#[serde(flatten)]`).
    #[test]
    fn rejects_tables_on_a_non_evm_config() {
        let yaml = r#"
ecosystem: fuel
name: t
contracts:
  - name: Greeter
    abi_file_path: ./abi.json
    events:
      - name: NewGreeting
chains:
  - id: 0
    start_block: 0
    contracts:
      - name: Greeter
        address: "0xdeadbeef"
tables:
  rows:
    from: evm.events
    select:
      id: params.x
"#;
        let error = format!(
            "{:#}",
            SystemConfig::parse_yaml(yaml, None, &HashMap::new(), &HashMap::new(), false)
                .expect_err("fuel + tables must error")
        );
        assert!(error.contains("unknown field `tables`"), "{error}");
    }
}

#[cfg(test)]
mod abi_type_test {
    use super::test::parse;

    // Param typing goes through the shared ABI mapping, so every shape a
    // contract import can produce is selectable here too.
    #[test]
    fn types_every_param_shape_the_shared_mapping_supports() {
        let yaml = r#"
name: t
disable_default_cross_chain: true
contracts:
  - name: Shapes
    events:
      - event: "E(address a, uint256 n, bool b, bytes32 h, uint256[] list, (address x, uint256 y) pair, uint256[][] grid)"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Shapes
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
tables:
  rows:
    from: evm.events
    select:
      id: params.a
      n: params.n
      b: params.b
      h: params.h
      list: params.list
      pair: params.pair
      grid: params.grid
"#;
        let config = parse(yaml).expect("every param shape should be selectable");
        let public: serde_json::Value =
            serde_json::from_str(&config.to_public_config_json(false).expect("public config"))
                .expect("valid json");
        assert_eq!(
            public["entities"][0]["properties"],
            serde_json::json!([
                {"name": "id", "type": "string"},
                {"name": "n", "type": "bigint"},
                {"name": "b", "type": "boolean"},
                {"name": "h", "type": "string"},
                {"name": "list", "type": "bigint", "isArray": true},
                {"name": "pair", "type": "json"},
                {"name": "grid", "type": "json"}
            ])
        );
    }
}
