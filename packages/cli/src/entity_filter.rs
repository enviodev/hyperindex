//! A get or getWhere filter in the form every storage receives, Postgres and
//! ClickHouse alike: each writes its own statement from it, so nothing here
//! may be one storage's spelling. Values arrive as text because turning a
//! handler's value into one takes the entity's schema, which lives in
//! JavaScript; `ValueKind` says how that text is spelled.

use napi_derive::napi;

#[napi(string_enum)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Operator {
    Eq,
    Gt,
    Lt,
    Gte,
    Lte,
    In,
}

/// How a value's text is spelled.
#[napi(string_enum)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ValueKind {
    Text,
    /// `true` or `false`.
    Boolean,
    /// Digits, with a sign and a decimal point where the type has them.
    Number,
    /// ISO 8601.
    Timestamp,
    /// `0x` and two lowercase hex digits per byte.
    Bytes,
    /// A JSON document.
    Json,
    /// The variant's name.
    Enum,
}

#[napi(object)]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Condition {
    /// In the receiving storage's own naming.
    pub column: String,
    pub operator: Operator,
    /// One value for every operator but `In`, which takes any number. Each
    /// value is its elements: one for a scalar column, the list's own for a
    /// list column.
    pub values: Vec<Vec<Option<String>>>,
    pub kind: ValueKind,
    pub is_list: bool,
    pub enum_name: Option<String>,
    /// The chain column of a per-chain entity.
    pub is_chain_id: bool,
}
