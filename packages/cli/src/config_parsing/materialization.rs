//! `tables:` in config.yaml — tables the indexer defines and writes itself,
//! from a `from` and a `select`, with no handler code. Tables that handlers
//! write stay in schema.graphql.
//!
//! Each one compiles to three things:
//!   * GraphQL SDL, merged into the schema the rest of the pipeline already
//!     reads — so entity types, database tables, Hasura and the generated TS
//!     types come out of the existing machinery untouched,
//!   * write plans, one per table per matching event, handed to the runtime
//!     through the public config JSON, and
//!   * the block/transaction fields to fetch, recorded against the event that
//!     carries them, so an event no table reads costs nothing.
//!
//! A `where` matching several events produces one plan per event, and the
//! columns they select must agree — that agreement is what lets one table be
//! written by several events.
//!
//! `with` queries are inlined here rather than passed on: their column
//! expressions are substituted into the outer `select`, so the runtime never
//! sees them. Sound because they can neither recurse nor read each other.

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

/// Kept as raw YAML so the compiler validates it instead of serde: only the
/// compiler knows the surrounding table, and can name the path that is wrong.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RawYaml(pub Yaml);

impl JsonSchema for RawYaml {
    fn schema_name() -> Cow<'static, str> {
        "MaterializationExpression".into()
    }

    fn json_schema(_gen: &mut SchemaGenerator) -> JsonSchemaSchema {
        json_schema!({
            "description": "A field of the event (\"params.owner\"), a number, boolean or null, or \
                            an object holding one of `_value`, `_literal`, `_negate`, `_sum`, \
                            `_concat`, `_ref`, `_derived_from`."
        })
    }

    fn inline_schema() -> bool {
        true
    }
}

/// A column of a table's own `select`: an expression, plus the `_description`
/// only a real column can carry. Separate from `RawYaml` so editors offer
/// `_description` here and not on a nested expression.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RawColumn(pub Yaml);

impl JsonSchema for RawColumn {
    fn schema_name() -> Cow<'static, str> {
        "MaterializationColumn".into()
    }

    fn json_schema(gen: &mut SchemaGenerator) -> JsonSchemaSchema {
        let expression = RawYaml::json_schema(gen);
        json_schema!({
            "anyOf": [
                expression,
                {
                    "type": "object",
                    "properties": {
                        "_description": {
                            "type": "string",
                            "description": "What this column holds. Becomes the column's \
                                            description in GraphQL and its comment in the database."
                        }
                    }
                }
            ]
        })
    }

    fn inline_schema() -> bool {
        true
    }
}

/// A `where` clause, raw for the same reason as `RawYaml`. Separate only so
/// editors describe a filter as a filter.
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
            "description": "Conditions a row must match, all of them. A plain value means equals \
                            (`eventName: Transfer`); an object is either a nested field (`block: \
                            {number: {_gte: 100}}`) or a comparison (`_eq`, `_neq`, `_gt`, \
                            `_gte`, \
                            `_lt`, `_lte`, `_in`, `_nin`). `_and` and `_or` take lists of \
                            conditions."
        })
    }

    fn inline_schema() -> bool {
        true
    }
}

/// `tables:`. Insertion-ordered, so generated columns follow the config.
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
        description = "Keep one row per id across all chains instead of one per chain. Only \
                       meaningful with `disable_default_cross_chain: true`."
    )]
    pub cross_chain: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(
        description = "Read this event from every address that emits it, not only the addresses \
                       configured for the contract. Needed when the contract has no `address` in \
                       config.yaml."
    )]
    pub wildcard: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(
        description = "Where this table is stored, overriding the top-level `storage`. `postgres` \
                       and `clickhouse` each take true/false, or an object of settings (which also \
                       turns the backend on)."
    )]
    pub storage: Option<TableStorage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(
        description = "Let handlers read this table, under this name: `as_entity: Account` gives \
                       them `context.Account`. Left out, the table is still stored and queryable \
                       over GraphQL, just not visible to handlers. Handlers can never write it."
    )]
    pub as_entity: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(
        with = "Option<BTreeMap<String, Queries>>",
        description = "Intermediate queries this table can read through `from`, like SQL CTEs. A \
                       list of queries is read as one combined result, so every query in it must \
                       select the same columns."
    )]
    pub with: Option<IndexMap<String, Queries>>,
    #[schemars(
        description = "Where the rows come from: `evm.events`, or the name of one of this table's \
                       own `with` queries."
    )]
    pub from: String,
    #[serde(rename = "where", skip_serializing_if = "Option::is_none")]
    pub filter: Option<RawFilter>,
    #[schemars(
        with = "BTreeMap<String, RawColumn>",
        description = "The table's columns. A plain string is a field of the event; numbers, \
                       booleans and null are values as written. Add `_description` beside a \
                       column's value to document it."
    )]
    pub select: IndexMap<String, RawColumn>,
}

/// Per-table storage, mirroring the `@storage` directive an entity carries.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TableStorage {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub postgres: Option<PostgresStorage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub clickhouse: Option<ClickHouseStorage>,
}

/// A boolean, or table options that imply the backend is enabled.
#[derive(Debug, Clone, PartialEq, Serialize, JsonSchema)]
#[serde(untagged)]
pub enum PostgresStorage {
    Enabled(bool),
    Options(PostgresOptions),
}

// Hand-rolled for the same reason as `ClickHouseStorage`: the untagged derive
// would swallow the inner unknown-field error.
impl<'de> Deserialize<'de> for PostgresStorage {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Visitor;

        impl<'de> serde::de::Visitor<'de> for Visitor {
            type Value = PostgresStorage;

            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("a boolean or a Postgres options object")
            }

            fn visit_bool<E: serde::de::Error>(self, v: bool) -> Result<Self::Value, E> {
                Ok(PostgresStorage::Enabled(v))
            }

            fn visit_map<A: serde::de::MapAccess<'de>>(
                self,
                map: A,
            ) -> Result<Self::Value, A::Error> {
                PostgresOptions::deserialize(serde::de::value::MapAccessDeserializer::new(map))
                    .map(PostgresStorage::Options)
            }
        }

        deserializer.deserialize_any(Visitor)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PostgresOptions {
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(
        description = "Extra indexes for this table. An entry is a field name, a list of field \
                       names for an index over several fields, or `{field, direction}` to sort a \
                       field descending. `id` is already indexed."
    )]
    pub indexes: Option<Vec<Index>>,
}

/// One index: a single field, or an ordered list of fields.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(untagged)]
pub enum Index {
    Single(IndexField),
    Composite(Vec<IndexField>),
}

impl<'de> Deserialize<'de> for Index {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Visitor;

        impl<'de> serde::de::Visitor<'de> for Visitor {
            type Value = Index;

            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("a field name, a list of field names, or {field, direction}")
            }

            fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<Self::Value, E> {
                Ok(Index::Single(IndexField {
                    field: v.to_string(),
                    direction: None,
                }))
            }

            fn visit_seq<A: serde::de::SeqAccess<'de>>(
                self,
                seq: A,
            ) -> Result<Self::Value, A::Error> {
                Vec::deserialize(serde::de::value::SeqAccessDeserializer::new(seq))
                    .map(Index::Composite)
            }

            fn visit_map<A: serde::de::MapAccess<'de>>(
                self,
                map: A,
            ) -> Result<Self::Value, A::Error> {
                IndexField::deserialize(serde::de::value::MapAccessDeserializer::new(map))
                    .map(Index::Single)
            }
        }

        deserializer.deserialize_any(Visitor)
    }
}

impl JsonSchema for Index {
    fn schema_name() -> Cow<'static, str> {
        "Index".into()
    }

    fn json_schema(gen: &mut SchemaGenerator) -> JsonSchemaSchema {
        let field = IndexField::json_schema(gen);
        json_schema!({
            "anyOf": [field, {"type": "array", "items": field}]
        })
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, JsonSchema)]
pub struct IndexField {
    pub field: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub direction: Option<IndexDirection>,
}

// A bare string is the ascending shorthand; the object form adds a direction.
// A string micro-syntax (`"amount:desc"`) was avoided on purpose — the rest of
// this config keeps structure in YAML rather than inside a string.
impl<'de> Deserialize<'de> for IndexField {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Object {
            field: String,
            direction: Option<IndexDirection>,
        }

        struct Visitor;

        impl<'de> serde::de::Visitor<'de> for Visitor {
            type Value = IndexField;

            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("a field name or {field, direction}")
            }

            fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<Self::Value, E> {
                Ok(IndexField {
                    field: v.to_string(),
                    direction: None,
                })
            }

            fn visit_map<A: serde::de::MapAccess<'de>>(
                self,
                map: A,
            ) -> Result<Self::Value, A::Error> {
                let object =
                    Object::deserialize(serde::de::value::MapAccessDeserializer::new(map))?;
                Ok(IndexField {
                    field: object.field,
                    direction: object.direction,
                })
            }
        }

        deserializer.deserialize_any(Visitor)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum IndexDirection {
    Asc,
    Desc,
}

impl Index {
    fn fields(&self) -> Vec<&IndexField> {
        match self {
            Index::Single(field) => vec![field],
            Index::Composite(fields) => fields.iter().collect(),
        }
    }
}

/// A boolean, or table options that imply the backend is enabled.
#[derive(Debug, Clone, PartialEq, Serialize, JsonSchema)]
#[serde(untagged)]
pub enum ClickHouseStorage {
    Enabled(bool),
    Options(ClickHouseOptions),
}

// Hand-rolled rather than `#[serde(untagged)]`: the derive swallows the inner
// error, so a typo like `{partiton_by: ...}` would surface as "did not match any
// variant" instead of the precise unknown-field error.
impl<'de> Deserialize<'de> for ClickHouseStorage {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Visitor;

        impl<'de> serde::de::Visitor<'de> for Visitor {
            type Value = ClickHouseStorage;

            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("a boolean or a ClickHouse table options object")
            }

            fn visit_bool<E: serde::de::Error>(self, v: bool) -> Result<Self::Value, E> {
                Ok(ClickHouseStorage::Enabled(v))
            }

            fn visit_map<A: serde::de::MapAccess<'de>>(
                self,
                map: A,
            ) -> Result<Self::Value, A::Error> {
                ClickHouseOptions::deserialize(serde::de::value::MapAccessDeserializer::new(map))
                    .map(ClickHouseStorage::Options)
            }
        }

        deserializer.deserialize_any(Visitor)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ClickHouseOptions {
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(description = "Raw ClickHouse expression emitted as `PARTITION BY <expr>`.")]
    pub partition_by: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(description = "Fields to sort the stored rows by, in place of the default `id`.")]
    pub order_by: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(description = "Raw ClickHouse expression emitted as `TTL <expr>`.")]
    pub ttl: Option<String>,
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
    /// Reference to another table, by that table's name.
    Ref(String),
    /// A YAML integer. Becomes whichever numeric type it is used alongside.
    NumLit,
    /// A YAML `null`, with nothing yet to take a type from.
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
            format!("a list of {base}")
        } else {
            base
        };
        if self.nullable {
            format!("{base} or null")
        } else {
            base
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
            // Nothing widened it, so it keeps the narrowest type that fits
            // rather than silently becoming a BigInt column.
            Scalar::NumLit => "Int".to_string(),
            Scalar::Null => {
                return Err(anyhow!(
                    "this is always null, so its type is unknown. Select a value that has a type, \
                     or drop the field."
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

    /// The tag the runtime picks a zero and an addition by, for `_sum`/`_negate`.
    fn numeric_tag(&self) -> Option<&'static str> {
        if self.array {
            return None;
        }
        match self.scalar {
            // The type `to_gql` would give it, so a `_sum` over a literal that
            // never widened still agrees with its column.
            Scalar::Int | Scalar::NumLit => Some("int"),
            Scalar::Float => Some("float"),
            Scalar::BigInt => Some("bigint"),
            Scalar::BigDecimal => Some("bigdecimal"),
            _ => None,
        }
    }
}

/// One type that holds both. A number takes the other side's numeric type;
/// `null` makes the other side nullable.
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
    /// Give a literal the column's type. Anything else must already match it.
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
                            "{value} is too big for an Int column. Select a BigInt value (a \
                             uint256 param, say) into the same column so the column becomes \
                             BigInt."
                        ));
                    }
                    expr
                }
                _ => {
                    return Err(anyhow!(
                        "a number can't be used where {} is expected",
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

/// A filter evaluated as far as it can be at compile time. `Unknown` carries
/// what is left for the runtime to check.
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
    /// `set` overwrites; `sum` adds to what the row already holds.
    op: &'static str,
    /// How to add. Only emitted for `sum`.
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
    /// The name handlers reach each table by, or `None` when the table stays out
    /// of the handler context. Keyed by table name.
    pub handler_names: BTreeMap<String, Option<String>>,
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
    /// A `with` query: plain column names, nothing nested.
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
                other => return Err(anyhow!("`{other}` params are not supported yet")),
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

/// Keyed by event, so each `events:` entry fetches only what the tables
/// reading it touch — rather than every event paying for the widest selection.
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
                        "`{}` comes from `with`, and its columns hold plain values — `{}` goes one \
                         level too deep",
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
                            _ => return Err(anyhow!("only EVM log events have `params`")),
                        };
                        let (first, nested) = rest.split_first().ok_or_else(|| {
                            anyhow!(
                                "`params` has several fields — pick one, e.g. `params.{}`",
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
                                    "`{label}` has several fields — pick one, e.g. `{label}.hash`"
                                ))
                            }
                            _ => {
                                return Err(anyhow!(
                                    "`{}` goes one level too deep — `{label}` fields hold plain \
                                     values",
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
                         eventName, chainId, srcAddress, logIndex, params, block, transaction. To \
                         write the text `{other}` instead, use `_literal: {other}`."
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
        return Err(anyhow!(
            "an empty string is not a value. Use a field of the event, e.g. \
                            `params.owner`."
        ));
    }
    let segments: Vec<String> = text.split('.').map(|s| s.to_string()).collect();
    if segments.iter().any(|s| s.is_empty()) {
        return Err(anyhow!(
            "`{text}` is not a field of the event. Use dots between names, e.g. `params.owner`."
        ));
    }
    Ok(segments)
}

/// An expression written as an object: the one `_` key that makes the value,
/// plus `_description` when the author wrote one.
struct ExprObject<'a> {
    operator: String,
    inner: &'a Yaml,
    description: Option<String>,
}

const DESCRIPTION_KEY: &str = "_description";

fn as_operator(value: &Yaml) -> Result<Option<ExprObject<'_>>> {
    let map = match value {
        Yaml::Mapping(map) => map,
        _ => return Ok(None),
    };
    let mut operators = Vec::new();
    let mut plain = Vec::new();
    let mut description = None;
    for key in map.keys() {
        let key = key
            .as_str()
            .ok_or_else(|| anyhow!("expected a string key in an expression object"))?;
        if key == DESCRIPTION_KEY {
            let value = map
                .get(Yaml::String(key.into()))
                .expect("key from this map");
            description = Some(yaml_string(value, "`_description`")?);
        } else if key.starts_with('_') {
            operators.push(key.to_string());
        } else {
            plain.push(key.to_string());
        }
    }
    if operators.is_empty() {
        if description.is_some() {
            return Err(anyhow!(
                "`_description` needs a value beside it, such as `_value: params.owner` or `_sum: \
                 params.value`."
            ));
        }
        return Ok(None);
    }
    if operators.len() > 1 || !plain.is_empty() {
        return Err(anyhow!(
            "expected exactly one of `_value`, `_literal`, `_negate`, `_sum`, `_concat`, `_ref`, \
             `_derived_from`, plus an optional `_description`, but got: {}",
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
    Ok(Some(ExprObject {
        operator,
        inner,
        description,
    }))
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

/// How a column is maintained, as opposed to what value the event produces.
enum Selected {
    Value(Typed),
    Sum(Typed),
    Ref { table: String, id: Typed },
    DerivedFrom { table: String, field: String },
}

fn compile_selected(
    value: &Yaml,
    ctx: &ExprCtx,
    demand: &mut Demand,
) -> Result<(Selected, Option<String>)> {
    let ExprObject {
        operator,
        inner,
        description,
    } = match as_operator(value)? {
        Some(object) => object,
        None => return Ok((Selected::Value(compile_expr(value, ctx, demand)?), None)),
    };
    let selected = {
        match operator.as_str() {
            "_sum" => {
                let inner = compile_expr(inner, ctx, demand).context("in `_sum`")?;
                if inner.ty.numeric_tag().is_none() {
                    return Err(anyhow!(
                        "`_sum` needs a number, but got {}",
                        inner.ty.describe()
                    ));
                }
                Selected::Sum(inner)
            }
            "_ref" => {
                let map = inner
                    .as_mapping()
                    .ok_or_else(|| anyhow!("`_ref` takes `table` and `id`"))?;
                let table = map
                    .get(Yaml::String("table".into()))
                    .ok_or_else(|| anyhow!("`_ref` is missing `table`"))?;
                let table = yaml_string(table, "`_ref.table`")?;
                if !ctx.table_names.iter().any(|name| name == &table) {
                    return Err(anyhow!(
                        "`_ref.table` is `{table}`, which is not one of the tables in `tables`"
                    ));
                }
                let id = map
                    .get(Yaml::String("id".into()))
                    .ok_or_else(|| anyhow!("`_ref` is missing `id`"))?;
                for key in map.keys() {
                    let key = yaml_string(key, "a `_ref` key")?;
                    if key != "table" && key != "id" {
                        return Err(anyhow!(
                            "`_ref` has no `{key}` option. It takes `table` and \
                                            `id`."
                        ));
                    }
                }
                let id = compile_expr(id, ctx, demand).context("in `_ref.id`")?;
                Selected::Ref { table, id }
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
                        "`_derived_from` names table `{table}`, which is not one of the tables in \
                         `tables`"
                    ));
                }
                Selected::DerivedFrom {
                    table: table.to_string(),
                    field: field.to_string(),
                }
            }
            _ => Selected::Value(compile_operator(&operator, inner, ctx, demand)?),
        }
    };
    Ok((selected, description))
}

fn compile_expr(value: &Yaml, ctx: &ExprCtx, demand: &mut Demand) -> Result<Typed> {
    if let Some(ExprObject {
        operator,
        inner,
        description,
    }) = as_operator(value)?
    {
        // Only a table's own `select` fields become columns; a nested
        // expression and a `with` query's columns have nowhere to put one.
        if description.is_some() {
            return Err(anyhow!(
                "`_description` describes a column, so it only works on a table's own `select` \
                 field"
            ));
        }
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
                Err(anyhow!("`{number:?}` is not a supported number"))
            }
        }
        Yaml::Null => Ok(Typed {
            expr: CExpr::LitNull,
            ty: Ty::new(Scalar::Null),
        }),
        Yaml::Sequence(_) => Err(anyhow!(
            "a list is not a value. Use `_concat` to join several values into one."
        )),
        Yaml::Mapping(_) => Err(anyhow!(
            "an object needs one of `_value`, `_literal`, `_negate`, `_sum`, `_concat`, `_ref`, \
             `_derived_from` to say what the value is."
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
        // The identity, so a plain path can carry a `_description`.
        "_value" => compile_expr(inner, ctx, demand).context("in `_value`"),
        "_negate" => {
            let inner = compile_expr(inner, ctx, demand).context("in `_negate`")?;
            let numeric_type = inner.ty.numeric_tag().ok_or_else(|| {
                anyhow!("`_negate` needs a number, but got {}", inner.ty.describe())
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
                            return Err(anyhow!(
                                "`_concat` has no `{key}` option. It takes `values` \
                                                and `separator`."
                            ));
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
                        "`_concat` takes a list of values, or `values` with a `separator`"
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
                            "`_concat.values[{index}]` is {}, which can't be turned into text",
                            part.ty.describe()
                        ))
                    }
                    _ if part.ty.array => {
                        return Err(anyhow!(
                            "`_concat.values[{index}]` is a list, which can't be turned into text"
                        ))
                    }
                    _ if part.ty.nullable => {
                        return Err(anyhow!(
                            "`_concat.values[{index}]` is {}, and a null would make two \
                             different rows join to the same text. Select a value that is always \
                             set.",
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
            "`_sum` can only be used directly on a `select` field"
        )),
        "_ref" => Err(anyhow!(
            "`_ref` can only be used directly on a `select` field"
        )),
        "_derived_from" => Err(anyhow!(
            "`_derived_from` can only be used directly on a `select` field"
        )),
        other => Err(anyhow!(
            "`{other}` is not one of `_value`, `_literal`, `_negate`, `_sum`, \
                              `_concat`, `_ref`, `_derived_from`"
        )),
    }
}

//
// ── Filter parsing ─────────────────────────────────────────────────────────
//

const COMPARISON_OPS: &[(&str, &str)] = &[
    ("_eq", "eq"),
    ("_neq", "ne"),
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
                    "`{key}` compares one field, so it goes under a field name, not at the top of \
                     `where`"
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
        return Err(anyhow!(
            "`{}` has nothing to compare it to. Add a condition such as `_eq`.",
            path.join(".")
        ));
    }
    Ok(Condition::And(parts))
}

/// The `contractName`/`eventName` a filter can match, so a table only gets
/// plans for events it could actually be written by.
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

/// Evaluate against one candidate event: `contractName`/`eventName` are known
/// here, everything else becomes a runtime check.
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
                                "`{}` only supports `_eq`/`_neq`/`_in`",
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
    storage: Option<TableStorage>,
    fields: Vec<SchemaField>,
}

struct SchemaField {
    /// The field name as written in `select`.
    name: String,
    gql_type: String,
    /// The target field on the other table, for `_derived_from`.
    derived_from: Option<String>,
    description: Option<String>,
}

/// A GraphQL string. `partition_by`, `ttl` and `_description` are user text
/// that reaches the schema through here, so quotes and backslashes are escaped
/// instead of breaking the parse.
fn sdl_string(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

impl TableSchema {
    /// The directives an entity in schema.graphql would carry. Emitting them
    /// means the existing directive parsing and validations apply unchanged.
    fn directives(&self) -> String {
        let mut directives = String::new();
        if self.cross_chain {
            directives.push_str(" @crossChain");
        }
        if let Some(storage) = &self.storage {
            let mut args = Vec::new();
            match &storage.postgres {
                // Options imply the backend is on, as in the directive.
                Some(PostgresStorage::Enabled(enabled)) => {
                    args.push(format!("postgres: {enabled}"))
                }
                Some(PostgresStorage::Options(_)) => args.push("postgres: true".to_string()),
                None => (),
            }
            match &storage.clickhouse {
                Some(ClickHouseStorage::Enabled(enabled)) => {
                    args.push(format!("clickhouse: {enabled}"))
                }
                Some(ClickHouseStorage::Options(options)) => {
                    let mut inner = Vec::new();
                    if let Some(partition_by) = &options.partition_by {
                        inner.push(format!("partitionBy: {}", sdl_string(partition_by)));
                    }
                    if let Some(order_by) = &options.order_by {
                        inner.push(format!(
                            "orderBy: [{}]",
                            order_by
                                .iter()
                                .map(|field| sdl_string(field))
                                .collect::<Vec<_>>()
                                .join(", ")
                        ));
                    }
                    if let Some(ttl) = &options.ttl {
                        inner.push(format!("ttl: {}", sdl_string(ttl)));
                    }
                    args.push(format!("clickhouse: {{{}}}", inner.join(", ")));
                }
                None => (),
            }
            if !args.is_empty() {
                directives.push_str(&format!(" @storage({})", args.join(", ")));
            }
            if let Some(PostgresStorage::Options(options)) = &storage.postgres {
                for index in options.indexes.iter().flatten() {
                    let fields = index
                        .fields()
                        .iter()
                        .map(|field| match field.direction {
                            // The directive spells a descending field as a two-element
                            // list; ascending is the bare name.
                            Some(IndexDirection::Desc) => {
                                format!("[{}, \"DESC\"]", sdl_string(&field.field))
                            }
                            Some(IndexDirection::Asc) | None => sdl_string(&field.field),
                        })
                        .collect::<Vec<_>>();
                    directives.push_str(&format!(" @index(fields: [{}])", fields.join(", ")));
                }
            }
        }
        directives
    }

    fn to_sdl(&self) -> String {
        let mut sdl = format!("type {}{} {{\n", self.name, self.directives());
        for SchemaField {
            name,
            gql_type,
            derived_from,
            description,
        } in &self.fields
        {
            if let Some(description) = description {
                sdl.push_str(&format!("  {}\n", sdl_string(description)));
            }
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

/// A `select` field's resolved shape, merged across every matching event.
struct FieldShape {
    name: String,
    ty: Ty,
    description: Option<String>,
    /// For `_derived_from`, the field on the other table. Such a field is in
    /// the schema but never written.
    derived_from: Option<String>,
    is_ref: bool,
}

/// One table's writes for one event.
struct Branch {
    contract_name: String,
    event_name: String,
    filter: Option<CFilter>,
    /// Column expressions, when the table reads a `with` query.
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
                "`{name}` is defined twice: in `tables` and in schema.graphql. Remove one of them."
            ));
        }
    }

    let all_evm = FieldSelection::all_evm();
    let block_field_types = field_type_table(&all_evm.block_fields, true);
    let transaction_field_types = field_type_table(&all_evm.transaction_fields, false);

    let mut schemas = Vec::new();
    let mut materializations = Vec::new();
    let mut demand = DemandByEvent::default();
    let mut handler_names = BTreeMap::new();

    for (table_name, table) in &tables.0 {
        let handler_name = match &table.as_entity {
            Some(name) => Some(name.clone()),
            None => None,
        };
        if let Some(name) = &handler_name {
            validate_handler_name(name, table_name)?;
        }
        handler_names.insert(table_name.clone(), handler_name);

        let compiled = compile_table(
            table_name,
            table,
            &table_names,
            contracts,
            &block_field_types,
            &transaction_field_types,
            &mut demand,
        )
        .with_context(|| format!("in `tables.{table_name}`"))?;
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
        handler_names,
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

    // Reading a `with` query gives one branch per query in it; reading
    // `evm.events` gives one branch per matching event, with no columns to
    // substitute.
    let (branches, relation_columns) = match table.with.as_ref().and_then(|with| with.get(from)) {
        Some(queries) => {
            // No defined meaning yet, and ignoring it would write rows the
            // user asked to exclude.
            if table.filter.is_some() {
                return Err(anyhow!(
                    "a table reading a `with` query can't have its own `where`. Move the \
                     conditions into the `with` queries."
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
            // A `with` query is only reachable through `from`, so declaring
            // one and reading something else leaves it dead — usually a typo.
            if let Some(with) = &table.with {
                if !with.is_empty() {
                    return Err(anyhow!(
                        "`with` declares {}, but `from: {from}` reads none of them. Set `from` to \
                         one of them, or drop `with`.",
                        with.keys().cloned().collect::<Vec<_>>().join(", ")
                    ));
                }
            }
            if from != EVM_EVENTS_SOURCE {
                return Err(anyhow!(
                    "`from: {from}` is not a source. Use `{EVM_EVENTS_SOURCE}`, or the name of one \
                     of this table's `with` queries."
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
            )
            .context("in `where`")?
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
            "`where` matches none of the configured events, so this table would never get any rows"
        ));
    }

    // Once per branch: each event sees its own paths, and the column types
    // are then merged across all of them.
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
            .map(|(field_name, (selected, description))| {
                let name = field_name.clone();
                let description = description.clone();
                match selected {
                    Selected::Value(typed) | Selected::Sum(typed) => FieldShape {
                        name,
                        ty: typed.ty.clone(),
                        derived_from: None,
                        is_ref: false,
                        description,
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
                        description,
                    },
                    Selected::DerivedFrom { table, field } => FieldShape {
                        name,
                        ty: Ty::new(Scalar::Ref(table.clone())).array(),
                        derived_from: Some(field.clone()),
                        is_ref: false,
                        description,
                    },
                }
            })
            .collect();

        match &mut declared {
            None => declared = Some(shapes),
            Some(declared) => {
                if declared.len() != shapes.len() {
                    return Err(anyhow!(
                        "`{table_name}` selects a different number of columns for different events"
                    ));
                }
                for (existing, incoming) in declared.iter_mut().zip(shapes) {
                    if existing.name != incoming.name {
                        return Err(anyhow!(
                            "`{table_name}` selects different columns for different events: `{}` \
                             for one, `{}` for another",
                            existing.name,
                            incoming.name
                        ));
                    }
                    existing.ty = unify(&existing.ty, &incoming.ty).with_context(|| {
                        format!(
                            "`{}` has a different type for different events",
                            existing.name
                        )
                    })?;
                    existing.description = match (existing.description.take(), incoming.description)
                    {
                        (Some(existing_text), Some(incoming_text))
                            if existing_text != incoming_text =>
                        {
                            return Err(anyhow!(
                                "`{}` has a different `_description` for different events",
                                existing.name
                            ))
                        }
                        (Some(text), _) | (None, Some(text)) => Some(text),
                        (None, None) => None,
                    };
                }
            }
        }

        plans.push((branch, resolved));
    }

    let declared = declared.expect("branches is non-empty");

    // Column types are final only once every branch has been seen, so the plans
    // are written here — a literal serializes as the type it widened to.
    let mut materializations = Vec::with_capacity(plans.len());
    for (branch, resolved) in plans {
        let mut id = None;
        let mut fields = Vec::new();
        for ((field_name, (selected, _)), shape) in resolved.into_iter().zip(&declared) {
            let ty = &shape.ty;
            // A `_sum` adds in the column's type, not this branch's own: a `0`
            // in one branch and a BigInt in another must agree on the zero.
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
                        "`select.id` can't be a `_sum`: the id names the row, it isn't added up"
                    ));
                }
                id = Some(expr);
                continue;
            }
            fields.push(FieldWrite {
                // A reference is written to the `_id` column, as the entity API
                // spells it.
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
            contract_name: branch.contract_name.clone(),
            event_name: branch.event_name.clone(),
            wildcard: table.wildcard.unwrap_or(false),
            filter: branch.filter.clone(),
            id: id.ok_or_else(|| anyhow!("every table must select an `id`"))?,
            fields,
        });
    }

    // Caught here rather than in codegen, where the error would no longer
    // name the table.
    let id_ty = &declared
        .iter()
        .find(|shape| shape.name == "id")
        .expect("id is required above")
        .ty;
    if id_ty.nullable || id_ty.array {
        return Err(anyhow!(
            "`select.id` must always be set and hold a single value, but it is {}",
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

    // Checked here rather than after the SDL round-trip, where the error would
    // talk about a `@index` directive the user never wrote.
    if let Some(PostgresStorage::Options(options)) =
        table.storage.as_ref().and_then(|s| s.postgres.as_ref())
    {
        for index in options.indexes.iter().flatten() {
            for field in index.fields() {
                if !declared.iter().any(|shape| shape.name == field.field) {
                    return Err(anyhow!(
                        "`storage.postgres.indexes` names `{}`, which this table doesn't select. \
                         Available: {}",
                        field.field,
                        declared
                            .iter()
                            .map(|shape| shape.name.clone())
                            .collect::<Vec<_>>()
                            .join(", ")
                    ));
                }
            }
        }
    }

    let fields = declared
        .iter()
        .map(|shape| {
            let gql_type = shape
                .ty
                .to_gql(shape.name == "id")
                .with_context(|| format!("in `select.{}`", shape.name))?;
            Ok(SchemaField {
                name: shape.name.clone(),
                gql_type,
                derived_from: shape.derived_from.clone(),
                description: shape.description.clone(),
            })
        })
        .collect::<Result<Vec<_>>>()?;

    Ok((
        TableSchema {
            name: table_name.to_string(),
            cross_chain: table.cross_chain.unwrap_or(false),
            storage: table.storage.clone(),
            fields,
        },
        materializations,
    ))
}

/// Compile the queries of one `with` and merge their column types.
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
        return Err(anyhow!("`with.{relation_name}` needs at least one query"));
    }

    let mut branches: Vec<Branch> = Vec::new();
    // Merged once every query has been compiled.
    let mut column_types: Option<IndexMap<String, Ty>> = None;
    let mut pending: Vec<(usize, IndexMap<String, Typed>)> = Vec::new();

    for (query_index, query) in queries.0.iter().enumerate() {
        if query.from != EVM_EVENTS_SOURCE {
            return Err(anyhow!(
                "`with.{relation_name}[{query_index}].from` must be `{EVM_EVENTS_SOURCE}`, but got \
                 `{}`",
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
                "`with.{relation_name}[{query_index}].where` matches none of the configured events"
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
                            "every query in `with.{relation_name}` must select the same columns, \
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

/// Every configured (contract, event) a filter could match, each with whatever
/// of the filter the runtime still has to check.
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
                    // Only a surviving branch's fields need fetching, so they are
                    // collected aside and merged once the branch is kept.
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

/// The name becomes a field in generated ReScript and a key in generated
/// TypeScript, so it has the same rules as a contract name.
fn validate_handler_name(name: &str, table_name: &str) -> Result<()> {
    let mut chars = name.chars();
    let valid = matches!(chars.next(), Some(c) if c.is_ascii_uppercase())
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_');
    if valid {
        return Ok(());
    }
    Err(anyhow!(
        "`tables.{table_name}.as_entity` is `{name}`, which handlers can't use as a name. Use \
         letters, digits and underscores, starting with a capital."
    ))
}

/// `_ref` and `_derived_from` name tables, and the generated SDL uses those
/// names verbatim — so a table name has to be a usable GraphQL type name.
pub fn validate_table_names(tables: &Tables) -> Result<()> {
    for name in tables.0.keys() {
        // No leading underscore: capitalizing leaves `_` alone, so it would
        // reach codegen as an invalid ReScript module name.
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
                "tables `{name}` and `{}` differ only by case, which the generated code can't tell \
                 apart. Rename one of them.",
                name.capitalize()
            ));
        }
    }
    Ok(())
}
