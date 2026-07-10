//! Intermediate representation of a validated GraphQL operation, produced
//! by `validate.rs` and consumed by `sql.rs`/`executor`. Everything here is
//! fully resolved: aliases, db column names, coerced argument values.

// Several fields (StreamCursor typing, selection table names) are populated
// by the planner but only read by the WS subscription executor, which is
// not implemented yet.
#![allow(dead_code)]

use crate::serve::model::Scalar;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum OperationKind {
    Query,
    Subscription,
}

#[derive(Debug)]
pub struct Operation {
    pub kind: OperationKind,
    pub root_fields: Vec<RootField>,
}

// Table is the overwhelmingly common variant; boxing it would cost an
// allocation per root field for no benefit.
#[allow(clippy::large_enum_variant)]
#[derive(Debug)]
pub enum RootField {
    /// `__typename` on the root: resolves to "query_root"/"subscription_root".
    Typename { alias: String },
    /// `__schema` / `__type` — resolved in-memory against the registry.
    /// The raw selection tree is kept for the introspection resolver.
    Introspection(IntrospectionField),
    /// A table root field, executed as one SQL statement.
    Table(TableRoot),
}

#[derive(Debug)]
pub struct IntrospectionField {
    pub alias: String,
    /// "__schema" or "__type"
    pub field: String,
    /// For `__type(name: ...)`.
    pub type_name: Option<String>,
    pub selection: IntroSelection,
}

/// Selection tree for introspection resolution: pre-validated field names
/// on the __Schema/__Type/__Field/... meta types.
#[derive(Debug)]
pub struct IntroSelection {
    pub items: Vec<IntroSelItem>,
}

#[derive(Debug)]
pub struct IntroSelItem {
    pub alias: String,
    pub field: String,
    /// includeDeprecated for fields()/enumValues(); name for __type-like args.
    pub include_deprecated: bool,
    pub selection: Option<IntroSelection>,
}

#[derive(Debug)]
pub struct TableRoot {
    pub alias: String,
    pub table: String,
    pub kind: TableRootKind,
}

#[derive(Debug)]
pub enum TableRootKind {
    /// `<T>(...) : [T!]!`
    Many {
        args: SelectArgs,
        selection: ObjectSelection,
    },
    /// `<T>_by_pk(...)`
    ByPk {
        /// (db column, value) pairs.
        pk: Vec<(String, SqlValue)>,
        selection: ObjectSelection,
    },
    /// `<T>_aggregate(...)`
    Aggregate {
        args: SelectArgs,
        selection: AggregateSelection,
    },
    /// `<T>_stream(...)` — subscriptions only.
    Stream {
        batch_size: i64,
        cursor: Vec<StreamCursor>,
        where_: Option<BoolExp>,
        selection: ObjectSelection,
    },
}

#[derive(Debug)]
pub struct StreamCursor {
    /// db column name
    pub column: String,
    pub scalar: Scalar,
    pub pg_type: String,
    pub is_array: bool,
    pub initial_value: Option<SqlValue>,
    pub descending: bool,
}

/// Selection over a table object type.
#[derive(Debug)]
pub struct ObjectSelection {
    pub table: String,
    pub items: Vec<SelItem>,
}

#[derive(Debug)]
pub enum SelItem {
    Typename {
        alias: String,
        /// The GraphQL object type name to return.
        type_name: String,
    },
    Column {
        alias: String,
        /// db column name
        column: String,
        scalar: Scalar,
        pg_type: String,
        is_array: bool,
        /// For json/jsonb columns: the parsed `path` argument as a Postgres
        /// #> path (list of keys/indexes), if provided.
        json_path: Option<Vec<String>>,
    },
    ObjectRel {
        alias: String,
        /// db column on the parent joined to remote id
        local_column: String,
        remote_table: String,
        selection: ObjectSelection,
    },
    ArrayRel {
        alias: String,
        /// db column on the remote table joined to parent id
        remote_column: String,
        remote_table: String,
        args: SelectArgs,
        selection: ObjectSelection,
    },
    ArrayRelAggregate {
        alias: String,
        remote_column: String,
        remote_table: String,
        args: SelectArgs,
        selection: AggregateSelection,
    },
}

#[derive(Debug)]
pub struct AggregateSelection {
    pub table: String,
    pub items: Vec<AggSelItem>,
    /// The public role's response limit caps the rows returned by `nodes`
    /// while the aggregate itself is computed over the uncapped set.
    pub nodes_limit: Option<i64>,
}

#[derive(Debug)]
pub enum AggSelItem {
    Typename {
        alias: String,
        type_name: String,
    },
    /// The `aggregate` field.
    Aggregate {
        alias: String,
        items: Vec<AggFieldItem>,
    },
    /// The `nodes` field.
    Nodes {
        alias: String,
        selection: ObjectSelection,
    },
}

#[derive(Debug)]
pub enum AggFieldItem {
    Typename {
        alias: String,
        type_name: String,
    },
    Count {
        alias: String,
        /// db column names; empty means count(*)
        columns: Vec<String>,
        distinct: bool,
    },
    /// sum/avg/min/max/stddev/... with its column sub-selection.
    Op {
        alias: String,
        op: String,
        columns: Vec<AggOpColumn>,
    },
}

#[derive(Debug)]
pub enum AggOpColumn {
    Typename {
        alias: String,
        type_name: String,
    },
    Column {
        alias: String,
        /// db column name
        column: String,
        scalar: Scalar,
        pg_type: String,
        is_array: bool,
        op: String,
    },
}

#[derive(Debug, Default)]
pub struct SelectArgs {
    pub where_: Option<BoolExp>,
    pub order_by: Vec<OrderByItem>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
    /// db column names
    pub distinct_on: Vec<String>,
}

#[derive(Debug)]
pub struct OrderByItem {
    pub target: OrderTarget,
    pub direction: OrderDirection,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum OrderDirection {
    Asc,
    AscNullsFirst,
    AscNullsLast,
    Desc,
    DescNullsFirst,
    DescNullsLast,
}

#[derive(Debug)]
pub enum OrderTarget {
    /// Order by a column of the current table (db name).
    Column { column: String },
    /// Order by a column reached through a chain of object relationships.
    /// Each step is (local db column, remote table).
    ObjectRelColumn {
        path: Vec<(String, String)>,
        column: String,
    },
    /// Order by an aggregate of an array relationship:
    /// `tokens_aggregate: {count: desc}` or `{max: {tokenId: asc}}`.
    /// A chain of object-relationship steps may precede the final
    /// array-relationship hop.
    ArrayRelAggregate {
        path: Vec<(String, String)>,
        /// (remote db column on the array rel's table, remote table)
        remote_column: String,
        remote_table: String,
        /// count / max / min / sum / avg / ...
        op: String,
        /// db column for per-column ops; None for count.
        column: Option<String>,
    },
}

#[derive(Debug)]
pub enum BoolExp {
    And(Vec<BoolExp>),
    Or(Vec<BoolExp>),
    Not(Box<BoolExp>),
    /// One comparison-exp entry on a column, e.g. `id: {_eq: "x", _gt: "y"}`
    /// becomes two Compare nodes.
    Compare {
        /// db column name
        column: String,
        scalar: Scalar,
        pg_type: String,
        is_array: bool,
        op: CompareOp,
    },
    /// Filter through an object relationship.
    ObjectRel {
        local_column: String,
        remote_table: String,
        exp: Box<BoolExp>,
    },
    /// EXISTS through an array relationship.
    ArrayRel {
        remote_column: String,
        remote_table: String,
        exp: Box<BoolExp>,
    },
    /// Aggregate predicate through an array relationship
    /// (`<rel>_aggregate: {count: {predicate: {_gt: 0}}}`).
    ArrayRelAggregate {
        remote_column: String,
        remote_table: String,
        pred: AggregatePredicate,
    },
}

#[derive(Debug)]
pub struct AggregatePredicate {
    /// count / bool_and / bool_or
    pub op: String,
    /// db columns for count arguments
    pub columns: Vec<String>,
    pub distinct: bool,
    pub filter: Option<Box<BoolExp>>,
    /// The comparison on the aggregate result (Int/Boolean comparison exp).
    pub predicate: Vec<CompareOp>,
}

#[derive(Debug)]
pub enum CompareOp {
    Eq(SqlValue),
    Neq(SqlValue),
    Gt(SqlValue),
    Gte(SqlValue),
    Lt(SqlValue),
    Lte(SqlValue),
    In(Vec<SqlValue>),
    Nin(Vec<SqlValue>),
    IsNull(bool),
    Like(SqlValue),
    Nlike(SqlValue),
    Ilike(SqlValue),
    Nilike(SqlValue),
    Similar(SqlValue),
    Nsimilar(SqlValue),
    Regex(SqlValue),
    Iregex(SqlValue),
    Nregex(SqlValue),
    Niregex(SqlValue),
    /// jsonb / array operators
    Contains(SqlValue),
    ContainedIn(SqlValue),
    HasKey(SqlValue),
    HasKeysAll(Vec<SqlValue>),
    HasKeysAny(Vec<SqlValue>),
    /// jsonb _cast: (String: String_comparison_exp) — compare col::text.
    CastText(Vec<CompareOp>),
}

/// A coerced scalar value ready to bind as a SQL parameter. Values are
/// carried as their Postgres text representation and cast to the right
/// type in SQL (`$1::numeric` etc.), which sidesteps binary encoding for
/// exotic types entirely.
#[derive(Clone, Debug)]
pub struct SqlValue {
    pub text: Option<String>,
    /// Cast target, e.g. "text", "int4", "numeric", "jsonb", an enum type
    /// name, or "text[]" for array values (text form `{a,b}`).
    pub cast: String,
}

impl SqlValue {
    pub fn new(text: impl Into<String>, cast: impl Into<String>) -> SqlValue {
        SqlValue {
            text: Some(text.into()),
            cast: cast.into(),
        }
    }
    pub fn null(cast: impl Into<String>) -> SqlValue {
        SqlValue {
            text: None,
            cast: cast.into(),
        }
    }
}
