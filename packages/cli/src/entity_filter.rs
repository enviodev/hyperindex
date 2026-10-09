//! A get or getWhere filter as a storage receives it: which column, how it
//! compares, and the values it compares against.
//!
//! It names no statement. Each storage writes its own from it, so the same
//! filter can be answered by Postgres or ClickHouse. Turning a handler's values
//! into text takes the entity's schema, which lives in JavaScript, so they
//! arrive rendered; how a storage spells a list or a type cast is its own
//! business.

use napi_derive::napi;

#[napi(string_enum)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Operator {
    Eq,
    Gt,
    Lt,
    Gte,
    Lte,
    /// Any of the values.
    In,
}

#[napi(object)]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Condition {
    /// The database column name, renames already resolved.
    pub column: String,
    pub operator: Operator,
    /// One value for every operator but `In`, which takes any number. Each
    /// value is its elements: one for a scalar column (`None` for NULL), the
    /// list's own for a list column.
    pub values: Vec<Vec<Option<String>>>,
    pub is_list: bool,
    /// The column's enum, by the name its type is declared under.
    pub enum_name: Option<String>,
    /// The chain column of a per-chain entity.
    pub is_chain_id: bool,
}
