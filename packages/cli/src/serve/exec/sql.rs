//! Compiles a table root field into one SQL statement and executes it,
//! returning the raw JSON text produced by Postgres so serialization is
//! byte-identical to Hasura's.
//!
//! The SQL mirrors the shapes Hasura v2.43 generates (verified against
//! `/v1/graphql/explain` on a live instance): rows are serialized with
//! `row_to_json` over an aliased subselect, lists aggregated with
//! `json_agg`, aggregates built with `json_build_object`, relationships
//! joined via `LEFT OUTER JOIN LATERAL`. With STRINGIFY_NUMERIC_TYPES,
//! non-array bigint/numeric/float8 values (and their sum/avg/min/...
//! aggregates) are cast to `::text`; float4, arrays and everything else
//! use Postgres' native JSON serialization.

use super::error::{GResult, GraphQLError, CODE_POSTGRES_ERROR, CODE_UNEXPECTED};
use super::ir;
use crate::serve::ServeState;
use futures_util::TryStreamExt;
use std::fmt::Write as _;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio_postgres::types::{ToSql, Type};

/// Above this many cached prepared statements on one pooled connection the
/// whole per-connection cache is dropped. Dropping the cached `Statement`
/// handles sends a protocol-level Close for each server-side prepared
/// statement (tokio-postgres `StatementInner::drop`), so this bounds both
/// server and Postgres backend memory even under an unbounded variety of
/// query texts.
const STATEMENT_CACHE_CAP: usize = 500;

fn slow_query_threshold() -> Duration {
    static MS: std::sync::OnceLock<u64> = std::sync::OnceLock::new();
    Duration::from_millis(*MS.get_or_init(|| {
        std::env::var("ENVIO_SERVE_SLOW_QUERY_MS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(5000)
    }))
}

/// Stable identifier for one compiled statement, loggable without exposing
/// the full SQL text.
fn sql_hash(sql: &str) -> String {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    sql.hash(&mut h);
    format!("{:016x}", h.finish())
}

/// Runs `sql`/`params` (as compiled by `compile_root`) and returns the
/// single output row every root-field query produces.
async fn run_root_query(
    state: &Arc<ServeState>,
    sql: &str,
    params: &[Option<String>],
) -> GResult<tokio_postgres::Row> {
    let started = Instant::now();
    // Pool failures (connect refused, wait timeout) get the same
    // postgres-error code as connection-level query failures so
    // subscriptions can tell "Postgres is briefly unreachable" (retryable)
    // apart from deterministic query errors.
    let client = state.pool.get().await.map_err(|e| {
        tracing::error!(error = %e, "envio serve: postgres pool checkout failed");
        GraphQLError {
            message: "database query error".to_string(),
            path: "$".to_string(),
            code: CODE_POSTGRES_ERROR,
            status: 200,
        }
    })?;
    if client.statement_cache.size() >= STATEMENT_CACHE_CAP {
        client.statement_cache.clear();
    }
    // All parameters are bound as text and cast in the SQL itself
    // (`($1)::numeric`), which keeps runtime coercion errors identical to
    // Hasura's inlined-literal form.
    let types = vec![Type::TEXT; params.len()];
    let stmt = client
        .prepare_typed_cached(sql, &types)
        .await
        .map_err(|e| pg_error(e, sql))?;
    let row_stream = client
        .query_raw(&stmt, params.iter().map(|p| p as &(dyn ToSql + Sync)))
        .await
        .map_err(|e| pg_error(e, sql))?;
    // Every compiled statement is expected to produce exactly one row, but
    // read only the first one off the wire instead of buffering a Vec: a
    // statement that unexpectedly degenerates to per-row output must not
    // buffer the whole table in memory.
    futures_util::pin_mut!(row_stream);
    let row = row_stream.try_next().await.map_err(|e| pg_error(e, sql))?;
    let elapsed = started.elapsed();
    if elapsed >= slow_query_threshold() {
        tracing::warn!(
            elapsed_ms = elapsed.as_millis() as u64,
            sql_hash = %sql_hash(sql),
            "envio serve: slow root-field query"
        );
    }
    match row {
        // Hasura fails the same way when its aggregate statement degenerates
        // to a non-aggregate query (e.g. `_aggregate { aggregate { __typename } }`)
        // over an empty table.
        None => {
            tracing::warn!(
                sql_hash = %sql_hash(sql),
                "envio serve: root-field query returned no rows"
            );
            Err(internal_db_error())
        }
        Some(row) => Ok(row),
    }
}

/// Executes one table root field, appending the JSON fragment for its value
/// (e.g. `[{"id":"..."}]`, `{"aggregate":{"count":3}}`, or `null`) to `out`.
///
/// Writes the driver's `&str` column value straight into `out` instead of
/// collecting it into an intermediate `String` first — on large unfiltered
/// list queries (tens of MB of JSON per response) that owned copy briefly
/// doubled peak memory, since Postgres already hands back one contiguous
/// text value.
pub async fn execute_root(
    state: &Arc<ServeState>,
    root: &ir::TableRoot,
    out: &mut String,
) -> GResult<()> {
    let compiled = compile_root_full(&state.model.pg_schema, root);
    let row = run_root_query(state, &compiled.sql, &compiled.params).await?;
    let text: &str = row.try_get(0).map_err(|e| {
        tracing::warn!(error = %e, "envio serve: root value decode failed");
        internal_db_error()
    })?;
    out.push_str(text);
    Ok(())
}

/// Executes an already-compiled ordinary live-query root and owns the
/// result so one Postgres response can be fanned out to many subscribers.
/// Compilation is deliberately outside the poll loop.
pub async fn execute_root_compiled(
    state: &Arc<ServeState>,
    compiled: &CompiledRoot,
) -> GResult<String> {
    let row = run_root_query(state, &compiled.sql, &compiled.params).await?;
    let text: &str = row.try_get(0).map_err(|e| {
        tracing::warn!(error = %e, "envio serve: live-query root value decode failed");
        internal_db_error()
    })?;
    Ok(text.to_string())
}

/// Like `execute_root`, but for an already-compiled `_stream` root: also
/// reads back each cursor column's value for the batch's last row from the
/// same query result (see `emit_stream_select`), instead of a second,
/// near-identical query fired just to read those columns back out --
/// halving the DB load of each subscription poll. Returns `None` (cursor
/// unchanged) when the batch was empty.
///
/// A non-empty batch always delivers its cursor values; individual values
/// can be `None` because NULL cursor positions are reachable (nullable
/// columns are exposed in `<T>_stream_cursor_value_input`, and DESC
/// ordering puts NULL rows in the first batch) — the compiled predicate
/// handles a NULL position (see `emit_cursor_bounds`).
pub async fn execute_stream_compiled(
    state: &Arc<ServeState>,
    sql: &str,
    params: &[Option<String>],
    out: &mut String,
) -> GResult<Option<Vec<Option<String>>>> {
    let row = run_root_query(state, sql, params).await?;
    let root_text: &str = row.try_get(0).map_err(|e| {
        tracing::warn!(error = %e, "envio serve: stream root value decode failed");
        internal_db_error()
    })?;
    out.push_str(root_text);
    if root_text == "[]" {
        return Ok(None);
    }

    let mut cursor_values = Vec::with_capacity(row.len().saturating_sub(1));
    for i in 1..row.len() {
        let v = row.try_get::<_, Option<&str>>(i).map_err(|e| {
            tracing::warn!(error = %e, "envio serve: stream cursor value decode failed");
            internal_db_error()
        })?;
        cursor_values.push(v.map(str::to_string));
    }
    Ok(Some(cursor_values))
}

fn internal_db_error() -> GraphQLError {
    GraphQLError {
        message: "database query error".to_string(),
        path: "$".to_string(),
        code: CODE_UNEXPECTED,
        status: 200,
    }
}

fn pg_error(e: tokio_postgres::Error, sql: &str) -> GraphQLError {
    let Some(db) = e.as_db_error() else {
        tracing::warn!(
            error = %e,
            sql_hash = %sql_hash(sql),
            "envio serve: connection-level postgres query failure"
        );
        return GraphQLError {
            message: "database query error".to_string(),
            path: "$".to_string(),
            code: CODE_POSTGRES_ERROR,
            status: 200,
        };
    };
    // Server-side cancellation (statement_timeout etc.) is the server twin
    // of the client-side query timeout, so it gets the retryable
    // postgres-error code instead of the deterministic "unexpected" mask.
    if db.code().code() == "57014" {
        tracing::warn!(
            error = %db,
            sqlstate = %db.code().code(),
            sql_hash = %sql_hash(sql),
            "envio serve: postgres query cancelled"
        );
        return GraphQLError {
            message: "database query error".to_string(),
            path: "$".to_string(),
            code: CODE_POSTGRES_ERROR,
            status: 200,
        };
    }
    // Hasura maps SQLSTATE classes: data exceptions and constraint
    // violations surface the Postgres message, everything else is the
    // opaque "unexpected" internal error.
    let class = &db.code().code()[..2.min(db.code().code().len())];
    let (code, message) = match class {
        "22" => ("data-exception", db.message().to_string()),
        "23" => ("constraint-violation", db.message().to_string()),
        _ => {
            tracing::warn!(
                error = %db,
                sqlstate = %db.code().code(),
                sql_hash = %sql_hash(sql),
                "envio serve: postgres error masked as \"database query error\""
            );
            (CODE_UNEXPECTED, "database query error".to_string())
        }
    };
    GraphQLError {
        message,
        path: "$".to_string(),
        code,
        status: 200,
    }
}

#[derive(Clone)]
pub struct CompiledRoot {
    pub sql: String,
    pub params: Vec<Option<String>>,
    /// Every parameter slot bound to a stream-cursor value, as
    /// (cursor index, param index) — one cursor value may occupy several
    /// slots (strict bound + tie equality). Lets a subscription poll loop
    /// swap in the next cursor position without recompiling the SQL.
    pub cursor_slots: Vec<(usize, usize)>,
}

pub fn compile_root_full(pg_schema: &str, root: &ir::TableRoot) -> CompiledRoot {
    let mut b = Sql::new(pg_schema, estimate_capacity(root));
    match &root.kind {
        ir::TableRootKind::Many { args, selection } => {
            let ra = RowsArgs::from_select_args(args);
            emit_many_select(&mut b, &root.table, &ra, selection, None, Out::Root);
        }
        ir::TableRootKind::ByPk { pk, selection } => {
            let ra = RowsArgs {
                pk,
                ..RowsArgs::default()
            };
            b.push("SELECT (coalesce((json_agg(\"_v\")->0), 'null'))::text AS \"root\" FROM (");
            emit_rows_middle(&mut b, &root.table, &ra, selection, None);
            b.push(") AS \"_r\"");
        }
        ir::TableRootKind::Aggregate { args, selection } => {
            let ra = RowsArgs::from_select_args(args);
            emit_agg_select(&mut b, &root.table, &ra, selection, None, Out::Root);
        }
        ir::TableRootKind::Stream {
            batch_size,
            cursor,
            where_,
            selection,
        } => {
            let ra = RowsArgs {
                where_: where_.as_ref(),
                cursors: cursor,
                order: cursor
                    .iter()
                    .map(|c| Ord {
                        target: OrdTarget::Col(&c.column),
                        dir: if c.descending { "DESC" } else { "ASC" },
                    })
                    .collect(),
                limit: Some(*batch_size),
                ..RowsArgs::default()
            };
            emit_stream_select(&mut b, &root.table, &ra, selection);
        }
    }
    CompiledRoot {
        sql: b.text,
        params: b.params,
        cursor_slots: b.cursor_slots,
    }
}

/// Rough output-size guess from the IR shape, so the text buffer doesn't
/// crawl up through repeated reallocation on deeply nested selections.
fn estimate_capacity(root: &ir::TableRoot) -> usize {
    fn sel(s: &ir::ObjectSelection) -> usize {
        s.items
            .iter()
            .map(|i| match i {
                ir::SelItem::Typename { .. } | ir::SelItem::Column { .. } => 48,
                ir::SelItem::ObjectRel { selection, .. }
                | ir::SelItem::ArrayRel { selection, .. } => 280 + sel(selection),
                ir::SelItem::ArrayRelAggregate { .. } => 448,
            })
            .sum()
    }
    256 + match &root.kind {
        ir::TableRootKind::Many { selection, .. }
        | ir::TableRootKind::ByPk { selection, .. }
        | ir::TableRootKind::Stream { selection, .. } => sel(selection),
        ir::TableRootKind::Aggregate { selection, .. } => {
            selection.items.len() * 96
                + selection
                    .items
                    .iter()
                    .map(|i| match i {
                        ir::AggSelItem::Nodes { selection, .. } => sel(selection),
                        _ => 0,
                    })
                    .sum::<usize>()
        }
    }
}

/// Table alias `"tN"`; aliases never need quoting-escapes, so they are
/// written straight into the text buffer without an intermediate String.
#[derive(Clone, Copy)]
struct Alias(usize);

struct Sql<'a> {
    text: String,
    params: Vec<Option<String>>,
    cursor_slots: Vec<(usize, usize)>,
    schema: &'a str,
    aliases: usize,
}

impl<'a> Sql<'a> {
    fn new(schema: &'a str, capacity: usize) -> Sql<'a> {
        Sql {
            text: String::with_capacity(capacity),
            params: Vec::new(),
            cursor_slots: Vec::new(),
            schema,
            aliases: 0,
        }
    }

    fn alias(&mut self) -> Alias {
        let a = Alias(self.aliases);
        self.aliases += 1;
        a
    }

    fn push(&mut self, s: &str) {
        self.text.push_str(s);
    }

    fn push_alias(&mut self, a: Alias) {
        let _ = write!(self.text, "\"t{}\"", a.0);
    }

    /// `"prefixK"` for the fixed internal column names (`_oK`, `_pcK`, ...).
    fn ident_n(&mut self, prefix: &str, k: usize) {
        let _ = write!(self.text, "\"{prefix}{k}\"");
    }

    fn ident(&mut self, name: &str) {
        push_ident_to(&mut self.text, name);
    }

    fn string_lit(&mut self, s: &str) {
        self.text.push('\'');
        for c in s.chars() {
            if c == '\'' {
                self.text.push('\'');
            }
            self.text.push(c);
        }
        self.text.push('\'');
    }

    fn qual(&mut self, alias: Alias, col: &str) {
        self.push_alias(alias);
        self.text.push('.');
        self.ident(col);
    }

    fn table(&mut self, name: &str) {
        let schema = self.schema;
        self.text.push('"');
        self.text.push_str(schema);
        self.text.push_str("\".");
        self.ident(name);
    }

    /// `::cast`, quoting the base type name unless it is a plain lowercase
    /// name (builtin types, and enum types created unquoted).
    fn push_cast(&mut self, cast: &str) {
        self.text.push_str("::");
        let base = cast.trim_end_matches("[]");
        let plain = !base.is_empty()
            && base
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == ' ');
        if plain {
            self.text.push_str(cast);
        } else {
            let brackets = cast.len() - base.len();
            let base = base.to_string();
            self.ident(&base);
            self.text.push_str(&cast[cast.len() - brackets..]);
        }
    }

    /// `(($n)::cast)` binding one value; returns the param slot index.
    fn param_text(&mut self, text: Option<String>, cast: &str) -> usize {
        self.params.push(text);
        let n = self.params.len();
        let _ = write!(self.text, "((${n})");
        self.push_cast(cast);
        self.text.push(')');
        n - 1
    }

    fn param(&mut self, v: &ir::SqlValue) -> usize {
        self.param_text(v.text.clone(), &v.cast)
    }

    fn param_i64(&mut self, v: i64) {
        self.param_text(Some(v.to_string()), "int8");
    }

    /// `(($n)::elem_cast[])` binding one array-literal parameter built from
    /// the elements' text forms.
    fn param_array<'i>(&mut self, elems: impl Iterator<Item = Option<&'i str>>, elem_cast: &str) {
        let mut lit = String::from("{");
        for (i, e) in elems.enumerate() {
            if i > 0 {
                lit.push(',');
            }
            match e {
                None => lit.push_str("NULL"),
                Some(s) => {
                    lit.push('"');
                    for c in s.chars() {
                        if c == '"' || c == '\\' {
                            lit.push('\\');
                        }
                        lit.push(c);
                    }
                    lit.push('"');
                }
            }
        }
        lit.push('}');
        self.param_text(Some(lit), &format!("{elem_cast}[]"));
    }
}

fn dir_sql(d: ir::OrderDirection) -> &'static str {
    match d {
        ir::OrderDirection::Asc | ir::OrderDirection::AscNullsLast => "ASC NULLS LAST",
        ir::OrderDirection::AscNullsFirst => "ASC NULLS FIRST",
        ir::OrderDirection::Desc | ir::OrderDirection::DescNullsFirst => "DESC NULLS FIRST",
        ir::OrderDirection::DescNullsLast => "DESC NULLS LAST",
    }
}

enum OrdTarget<'a> {
    Col(&'a str),
    Rel(&'a ir::OrderTarget),
}

struct Ord<'a> {
    target: OrdTarget<'a>,
    dir: &'static str,
}

/// Join condition of a lateral/EXISTS child against its parent row:
/// `(("child"."child_col") = ("parent"."parent_col"))`.
struct Corr<'a> {
    parent_alias: Alias,
    parent_col: &'a str,
    child_col: &'a str,
}

#[derive(Default)]
struct RowsArgs<'a> {
    pk: &'a [(String, ir::SqlValue)],
    where_: Option<&'a ir::BoolExp>,
    cursors: &'a [ir::StreamCursor],
    order: Vec<Ord<'a>>,
    distinct_on: &'a [String],
    limit: Option<i64>,
    offset: Option<i64>,
}

impl<'a> RowsArgs<'a> {
    fn from_select_args(args: &'a ir::SelectArgs) -> RowsArgs<'a> {
        RowsArgs {
            pk: &[],
            where_: args.where_.as_ref(),
            cursors: &[],
            order: args
                .order_by
                .iter()
                .map(|o| Ord {
                    target: match &o.target {
                        ir::OrderTarget::Column { column } => OrdTarget::Col(column),
                        other => OrdTarget::Rel(other),
                    },
                    dir: dir_sql(o.direction),
                })
                .collect(),
            distinct_on: &args.distinct_on,
            limit: args.limit,
            offset: args.offset,
        }
    }

    /// Relationship-based order targets can only be computed alongside the
    /// lateral joins, so ordering/distinct/limit move from the base table
    /// subquery to the row-building level — exactly as Hasura does.
    fn order_in_base(&self) -> bool {
        !self
            .order
            .iter()
            .any(|o| matches!(o.target, OrdTarget::Rel(_)))
    }
}

enum Out {
    /// Root statement: the single output column is cast to text.
    Root,
    /// A lateral join's value column, kept as json.
    Lateral,
}

/// `SELECT coalesce(json_agg("_v" ORDER BY ...), '[]') ... FROM (rows) AS "_r"`
fn emit_many_select(
    b: &mut Sql,
    table: &str,
    ra: &RowsArgs,
    sel: &ir::ObjectSelection,
    corr: Option<&Corr>,
    out: Out,
) {
    b.push("SELECT ");
    if matches!(out, Out::Root) {
        b.push("(");
    }
    b.push("coalesce(json_agg(\"_v\"");
    emit_order_by_refs(b, &ra.order);
    b.push("), '[]')");
    match out {
        Out::Root => b.push(")::text AS \"root\""),
        Out::Lateral => b.push(" AS \"_v\""),
    }
    b.push(" FROM (");
    emit_rows_middle(b, table, ra, sel, corr);
    b.push(") AS \"_r\"");
}

/// Like `emit_many_select`'s `Out::Root` shape, but also selects each order
/// (cursor) column's value from the batch's last row in final sort order,
/// text-cast for lossless round-tripping -- so a `_stream` subscription's
/// poll loop can read the next cursor position out of this same query
/// instead of firing a second, near-identical query just for that.
fn emit_stream_select(b: &mut Sql, table: &str, ra: &RowsArgs, sel: &ir::ObjectSelection) {
    b.push("SELECT (coalesce(json_agg(\"_v\"");
    emit_order_by_refs(b, &ra.order);
    b.push("), '[]'))::text AS \"root\"");
    for k in 0..ra.order.len() {
        b.push(", (array_agg((");
        b.ident_n("_o", k);
        b.push(")::text");
        emit_order_by_refs(b, &ra.order);
        b.push("))[count(*)] AS ");
        b.ident_n("cursor_", k);
    }
    b.push(" FROM (");
    emit_rows_middle(b, table, ra, sel, None);
    b.push(") AS \"_r\"");
}

fn emit_order_by_refs(b: &mut Sql, order: &[Ord]) {
    for (k, o) in order.iter().enumerate() {
        b.push(if k == 0 { " ORDER BY " } else { ", " });
        b.ident_n("_o", k);
        b.push(" ");
        b.push(o.dir);
    }
}

/// The row-building level: one output row per selected table row, with the
/// row JSON as "_v" and each order expression as "_oK".
fn emit_rows_middle(
    b: &mut Sql,
    table: &str,
    ra: &RowsArgs,
    sel: &ir::ObjectSelection,
    corr: Option<&Corr>,
) {
    let order_in_base = ra.order_in_base();
    let t = b.alias();
    let rel_aliases = alloc_rel_aliases(b, sel);
    let order_join_aliases = alloc_order_join_aliases(b, &ra.order);

    b.push("SELECT ");
    if !order_in_base && !ra.distinct_on.is_empty() {
        emit_middle_distinct(b, ra.distinct_on.len());
    }
    emit_row_json(b, t, sel, &rel_aliases);
    b.push(" AS \"_v\"");
    emit_order_cols(b, t, &ra.order, &order_join_aliases);
    b.push(" FROM ");
    emit_base(b, table, t, ra, corr, order_in_base);
    emit_order_rel_joins(b, t, &ra.order, &order_join_aliases);
    emit_rel_laterals(b, t, sel, &rel_aliases);
    if !order_in_base {
        emit_middle_order_limit(b, ra);
    }
}

fn emit_middle_distinct(b: &mut Sql, n_cols: usize) {
    b.push("DISTINCT ON (");
    for k in 0..n_cols {
        if k > 0 {
            b.push(", ");
        }
        b.ident_n("_o", k);
    }
    b.push(") ");
}

/// Pre-allocates one alias per hop of every `ObjectRelColumn` order target,
/// so the order column (in the SELECT list, emitted before the FROM clause
/// text) can reference the leaf alias that `emit_order_rel_joins` later
/// joins into the FROM clause — the same alloc-then-reference pattern
/// `alloc_rel_aliases`/`emit_rel_laterals` use for relationship fields.
fn alloc_order_join_aliases(b: &mut Sql, order: &[Ord]) -> Vec<Option<Vec<Alias>>> {
    order
        .iter()
        .map(|o| match &o.target {
            OrdTarget::Rel(ir::OrderTarget::ObjectRelColumn { path, .. }) => {
                Some(path.iter().map(|_| b.alias()).collect())
            }
            _ => None,
        })
        .collect()
}

/// The expression one order target sorts by, shared between the `_oK`
/// select-list columns and the row-number window in `emit_agg_middle`.
fn emit_order_target(b: &mut Sql, t: Alias, o: &Ord, join_aliases: &Option<Vec<Alias>>) {
    match (&o.target, join_aliases) {
        (OrdTarget::Col(c), _) => b.qual(t, c),
        (OrdTarget::Rel(ir::OrderTarget::ObjectRelColumn { column, .. }), Some(aliases)) => {
            // `aliases` has one entry per path hop, and ObjectRelColumn's
            // path is never empty (see validate.rs's chain-based builder).
            b.qual(*aliases.last().unwrap(), column);
        }
        (OrdTarget::Rel(target), _) => emit_order_rel_expr(b, t, target),
    }
}

fn emit_order_cols(
    b: &mut Sql,
    t: Alias,
    order: &[Ord],
    order_join_aliases: &[Option<Vec<Alias>>],
) {
    for (k, o) in order.iter().enumerate() {
        b.push(", ");
        emit_order_target(b, t, o, &order_join_aliases[k]);
        b.push(" AS ");
        b.ident_n("_o", k);
    }
}

/// LEFT JOINs the tables reached by `ObjectRelColumn` order targets into the
/// FROM clause instead of computing them via a correlated subselect per row.
/// Safe because object relationships match at most one remote row (the join
/// is on the remote table's PK), so this can't change the base row count —
/// unlike a join on an array relationship, which would fan out rows.
fn emit_order_rel_joins(
    b: &mut Sql,
    t: Alias,
    order: &[Ord],
    order_join_aliases: &[Option<Vec<Alias>>],
) {
    for (o, aliases) in order.iter().zip(order_join_aliases) {
        let (OrdTarget::Rel(ir::OrderTarget::ObjectRelColumn { path, .. }), Some(aliases)) =
            (&o.target, aliases)
        else {
            continue;
        };
        let mut parent = t;
        for ((local, remote), alias) in path.iter().zip(aliases) {
            b.push(" LEFT JOIN ");
            b.table(remote);
            b.push(" AS ");
            b.push_alias(*alias);
            b.push(" ON ((");
            b.qual(parent, local);
            b.push(") = (");
            b.qual(*alias, "id");
            b.push("))");
            parent = *alias;
        }
    }
}

fn emit_middle_order_limit(b: &mut Sql, ra: &RowsArgs) {
    emit_order_by_refs(b, &ra.order);
    if let Some(l) = ra.limit {
        b.push(" LIMIT ");
        b.param_i64(l);
    }
    if let Some(o) = ra.offset {
        b.push(" OFFSET ");
        b.param_i64(o);
    }
}

/// `(SELECT [DISTINCT ON (..)] * FROM "schema"."T" AS "t" WHERE ..
/// [ORDER BY .. LIMIT .. OFFSET ..]) AS "t"`
fn emit_base(
    b: &mut Sql,
    table: &str,
    t: Alias,
    ra: &RowsArgs,
    corr: Option<&Corr>,
    order_in_base: bool,
) {
    b.push("(SELECT ");
    if order_in_base && !ra.distinct_on.is_empty() {
        b.push("DISTINCT ON (");
        for (i, c) in ra.distinct_on.iter().enumerate() {
            if i > 0 {
                b.push(", ");
            }
            b.ident(c);
        }
        b.push(") ");
    }
    b.push("* FROM ");
    b.table(table);
    b.push(" AS ");
    b.push_alias(t);
    b.push(" WHERE ");

    let mut first = true;
    let mut sep = |b: &mut Sql| {
        if !first {
            b.push(" AND ");
        }
        first = false;
    };
    if let Some(c) = corr {
        sep(b);
        b.push("((");
        b.qual(t, c.child_col);
        b.push(") = (");
        b.qual(c.parent_alias, c.parent_col);
        b.push("))");
    }
    for (col, v) in ra.pk {
        sep(b);
        b.push("((");
        b.qual(t, col);
        b.push(") = ");
        b.param(v);
        b.push(")");
    }
    if ra.cursors.iter().any(|c| c.initial_value.is_some()) {
        sep(b);
        emit_cursor_bounds(b, t, ra.cursors);
    }
    if let Some(w) = ra.where_ {
        sep(b);
        emit_bool(b, t, w);
    }
    if first {
        b.push("('true')");
    }

    if order_in_base {
        for (k, o) in ra.order.iter().enumerate() {
            b.push(if k == 0 { " ORDER BY " } else { ", " });
            match &o.target {
                OrdTarget::Col(c) => b.ident(c),
                OrdTarget::Rel(_) => unreachable!("rel order targets are never base-ordered"),
            }
            b.push(" ");
            b.push(o.dir);
        }
        if let Some(l) = ra.limit {
            b.push(" LIMIT ");
            b.param_i64(l);
        }
        if let Some(o) = ra.offset {
            b.push(" OFFSET ");
            b.param_i64(o);
        }
    }
    b.push(") AS ");
    b.push_alias(t);
}

/// Lexicographic bound over the stream cursor columns; a missing initial
/// value means that column is unbounded.
///
/// A present-but-NULL cursor value is a real position in the ordering
/// (nullable cursor columns; bare ASC sorts NULLS LAST, DESC NULLS FIRST):
/// under ASC nothing sorts strictly after NULL, so the strict bound matches
/// nothing (the stream has drained but keeps polling); under DESC the
/// remainder is exactly the non-null rows. Ties on a NULL position continue
/// the lexicographic chain via `IS NULL`.
fn emit_cursor_bounds(b: &mut Sql, t: Alias, cursors: &[ir::StreamCursor]) {
    let bounded: Vec<(usize, &ir::StreamCursor)> = cursors
        .iter()
        .enumerate()
        .filter(|(_, c)| c.initial_value.is_some())
        .collect();

    fn strict(b: &mut Sql, t: Alias, ci: usize, c: &ir::StreamCursor) {
        let v = c.initial_value.as_ref().unwrap();
        match (&v.text, c.descending) {
            (None, false) => b.push("('false')"),
            (None, true) => {
                b.push("((");
                b.qual(t, &c.column);
                b.push(") IS NOT NULL)");
            }
            (Some(_), descending) => {
                b.push("((");
                b.qual(t, &c.column);
                b.push(")");
                b.push(if descending { " < " } else { " > " });
                let slot = b.param(v);
                b.cursor_slots.push((ci, slot));
                b.push(")");
            }
        }
    }

    fn tie(b: &mut Sql, t: Alias, ci: usize, c: &ir::StreamCursor) {
        let v = c.initial_value.as_ref().unwrap();
        match &v.text {
            None => {
                b.push("((");
                b.qual(t, &c.column);
                b.push(") IS NULL)");
            }
            Some(_) => {
                b.push("((");
                b.qual(t, &c.column);
                b.push(") = ");
                let slot = b.param(v);
                b.cursor_slots.push((ci, slot));
                b.push(")");
            }
        }
    }

    fn emit_from(b: &mut Sql, t: Alias, bounded: &[(usize, &ir::StreamCursor)]) {
        let (ci, c) = bounded[0];
        if bounded.len() == 1 {
            strict(b, t, ci, c);
            return;
        }
        b.push("(");
        strict(b, t, ci, c);
        b.push(" OR (");
        tie(b, t, ci, c);
        b.push(" AND ");
        emit_from(b, t, &bounded[1..]);
        b.push("))");
    }
    emit_from(b, t, &bounded);
}

fn alloc_rel_aliases(b: &mut Sql, sel: &ir::ObjectSelection) -> Vec<Option<Alias>> {
    sel.items
        .iter()
        .map(|item| match item {
            ir::SelItem::ObjectRel { .. }
            | ir::SelItem::ArrayRel { .. }
            | ir::SelItem::ArrayRelAggregate { .. } => Some(b.alias()),
            _ => None,
        })
        .collect()
}

/// `row_to_json((SELECT "_e" FROM (SELECT <items>) AS "_e"))`
fn emit_row_json(b: &mut Sql, t: Alias, sel: &ir::ObjectSelection, rel_aliases: &[Option<Alias>]) {
    b.push("row_to_json((SELECT \"_e\" FROM (SELECT ");
    for (i, item) in sel.items.iter().enumerate() {
        if i > 0 {
            b.push(", ");
        }
        match item {
            ir::SelItem::Typename { alias, type_name } => {
                b.string_lit(type_name);
                b.push(" AS ");
                b.ident(alias);
            }
            ir::SelItem::Column {
                alias,
                column,
                scalar,
                is_array,
                json_path,
                ..
            } => {
                if let Some(path) = json_path {
                    b.push("(");
                    b.qual(t, column);
                    b.push("#>");
                    b.param_array(path.iter().map(|p| Some(p.as_str())), "text");
                    b.push(")");
                } else if scalar.stringified() && !is_array {
                    b.push("(");
                    b.qual(t, column);
                    b.push(")::text");
                } else {
                    b.qual(t, column);
                }
                b.push(" AS ");
                b.ident(alias);
            }
            ir::SelItem::ObjectRel { alias, .. }
            | ir::SelItem::ArrayRel { alias, .. }
            | ir::SelItem::ArrayRelAggregate { alias, .. } => {
                let rel = rel_aliases[i].unwrap();
                b.qual(rel, "_v");
                b.push(" AS ");
                b.ident(alias);
            }
        }
    }
    b.push(") AS \"_e\"))");
}

fn emit_rel_laterals(
    b: &mut Sql,
    t: Alias,
    sel: &ir::ObjectSelection,
    rel_aliases: &[Option<Alias>],
) {
    for (i, item) in sel.items.iter().enumerate() {
        let Some(rel) = rel_aliases[i] else {
            continue;
        };
        b.push(" LEFT OUTER JOIN LATERAL (");
        match item {
            ir::SelItem::ObjectRel {
                local_column,
                remote_table,
                selection,
                ..
            } => {
                let corr = Corr {
                    parent_alias: t,
                    parent_col: local_column,
                    child_col: "id",
                };
                let ra = RowsArgs {
                    limit: Some(1),
                    ..RowsArgs::default()
                };
                emit_rows_middle(b, remote_table, &ra, selection, Some(&corr));
            }
            ir::SelItem::ArrayRel {
                remote_column,
                remote_table,
                args,
                selection,
                ..
            } => {
                let corr = Corr {
                    parent_alias: t,
                    parent_col: "id",
                    child_col: remote_column,
                };
                let ra = RowsArgs::from_select_args(args);
                emit_many_select(b, remote_table, &ra, selection, Some(&corr), Out::Lateral);
            }
            ir::SelItem::ArrayRelAggregate {
                remote_column,
                remote_table,
                args,
                selection,
                ..
            } => {
                let corr = Corr {
                    parent_alias: t,
                    parent_col: "id",
                    child_col: remote_column,
                };
                let ra = RowsArgs::from_select_args(args);
                emit_agg_select(b, remote_table, &ra, selection, Some(&corr), Out::Lateral);
            }
            _ => unreachable!(),
        }
        b.push(") AS ");
        b.push_alias(rel);
        b.push(" ON ('true')");
    }
}

/// `SELECT json_build_object(..aggregates.., 'nodes', json_agg(..)) FROM
/// (SELECT <needed cols>, <node row jsons>, <order cols> FROM base ..) AS "_r"`
fn emit_agg_select(
    b: &mut Sql,
    table: &str,
    ra: &RowsArgs,
    sel: &ir::AggregateSelection,
    corr: Option<&Corr>,
    out: Out,
) {
    // Columns referenced by count/op aggregates, deduplicated; each becomes
    // a middle-level column "_pcK".
    let add = |cols: &mut Vec<String>, c: &str| {
        if !cols.iter().any(|x| x == c) {
            cols.push(c.to_string());
        }
    };
    let mut cols: Vec<String> = Vec::new();
    let mut nodes: Vec<&ir::ObjectSelection> = Vec::new();
    for item in &sel.items {
        match item {
            ir::AggSelItem::Aggregate { items, .. } => {
                for f in items {
                    match f {
                        ir::AggFieldItem::Count { columns, .. } => {
                            for c in columns {
                                add(&mut cols, c);
                            }
                        }
                        ir::AggFieldItem::Op { columns, .. } => {
                            for c in columns {
                                if let ir::AggOpColumn::Column { column, .. } = c {
                                    add(&mut cols, column);
                                }
                            }
                        }
                        ir::AggFieldItem::Typename { .. } => {}
                    }
                }
            }
            ir::AggSelItem::Nodes { selection, .. } => nodes.push(selection),
            ir::AggSelItem::Typename { .. } => {}
        }
    }
    // Whether the statement contains at least one SQL aggregate function
    // (count/sum/json_agg/the top-level Typename's bool_or). Without one,
    // the "aggregate" degenerates to a plain per-row select whose output is
    // the same constant for every table row — see the LIMIT 1 below.
    let has_aggregate_fn = sel.items.iter().any(|item| match item {
        ir::AggSelItem::Typename { .. } => true,
        ir::AggSelItem::Nodes { .. } => true,
        ir::AggSelItem::Aggregate { items, .. } => items.iter().any(|f| match f {
            ir::AggFieldItem::Typename { .. } => false,
            ir::AggFieldItem::Count { .. } => true,
            ir::AggFieldItem::Op { columns, .. } => columns
                .iter()
                .any(|c| matches!(c, ir::AggOpColumn::Column { .. })),
        }),
    });
    let col_idx = |c: &str| -> usize { cols.iter().position(|x| x == c).unwrap() };

    b.push("SELECT ");
    if matches!(out, Out::Root) {
        b.push("(");
    }
    b.push("json_build_object(");
    let mut node_idx = 0usize;
    for (i, item) in sel.items.iter().enumerate() {
        if i > 0 {
            b.push(", ");
        }
        match item {
            ir::AggSelItem::Typename { alias, type_name } => {
                b.string_lit(alias);
                // bool_or forces aggregate context so the statement returns
                // exactly one row even without other aggregate functions.
                b.push(", coalesce(");
                b.string_lit(type_name);
                b.push(", (bool_or('true'))::text)");
            }
            ir::AggSelItem::Aggregate { alias, items } => {
                b.string_lit(alias);
                b.push(", json_build_object(");
                for (j, f) in items.iter().enumerate() {
                    if j > 0 {
                        b.push(", ");
                    }
                    emit_agg_field(b, f, &col_idx);
                }
                b.push(")");
            }
            ir::AggSelItem::Nodes { alias, .. } => {
                b.string_lit(alias);
                b.push(", coalesce(json_agg(");
                b.ident_n("_n", node_idx);
                node_idx += 1;
                emit_order_by_refs(b, &ra.order);
                b.push(")");
                // The role's response limit caps nodes rows while the
                // aggregates above stay uncapped.
                if let Some(n) = sel.nodes_limit {
                    let _ = write!(b.text, " FILTER (WHERE \"_rn\" <= {n})");
                }
                b.push(", '[]')");
            }
        }
    }
    b.push(")");
    match out {
        Out::Root => b.push(")::text AS \"root\""),
        Out::Lateral => b.push(" AS \"_v\""),
    }
    b.push(" FROM (");
    let with_row_numbers = sel.nodes_limit.is_some() && !nodes.is_empty();
    emit_agg_middle(b, table, ra, &cols, &nodes, corr, with_row_numbers);
    b.push(") AS \"_r\"");
    if !has_aggregate_fn {
        // Every output row is the same constant, so cap the scan at one row
        // instead of materializing one per table row. Zero rows on an empty
        // table still surface Hasura's "database query error" (see
        // `run_root_query`).
        b.push(" LIMIT 1");
    }
}

fn emit_agg_field(b: &mut Sql, f: &ir::AggFieldItem, col_idx: &dyn Fn(&str) -> usize) {
    match f {
        ir::AggFieldItem::Typename { alias, type_name } => {
            b.string_lit(alias);
            b.push(", ");
            b.string_lit(type_name);
        }
        ir::AggFieldItem::Count {
            alias,
            columns,
            distinct,
        } => {
            b.string_lit(alias);
            b.push(", count(");
            if columns.is_empty() {
                b.push("*");
            } else {
                if *distinct {
                    b.push("DISTINCT ");
                }
                b.push("(");
                for (i, c) in columns.iter().enumerate() {
                    if i > 0 {
                        b.push(", ");
                    }
                    b.push("\"_r\".");
                    b.ident_n("_pc", col_idx(c));
                }
                b.push(")");
            }
            b.push(")");
        }
        ir::AggFieldItem::Op { alias, columns, .. } => {
            b.string_lit(alias);
            b.push(", json_build_object(");
            for (i, c) in columns.iter().enumerate() {
                if i > 0 {
                    b.push(", ");
                }
                match c {
                    ir::AggOpColumn::Typename { alias, type_name } => {
                        b.string_lit(alias);
                        b.push(", ");
                        b.string_lit(type_name);
                    }
                    ir::AggOpColumn::Column {
                        alias,
                        column,
                        scalar,
                        is_array,
                        op,
                        ..
                    } => {
                        b.string_lit(alias);
                        b.push(", ");
                        let stringify = scalar.stringified() && !is_array;
                        if stringify {
                            b.push("(");
                        }
                        b.push(op);
                        b.push("(");
                        b.push("\"_r\".");
                        b.ident_n("_pc", col_idx(column));
                        b.push(")");
                        if stringify {
                            b.push(")::text");
                        }
                    }
                }
            }
            b.push(")");
        }
    }
}

fn emit_agg_middle(
    b: &mut Sql,
    table: &str,
    ra: &RowsArgs,
    cols: &[String],
    nodes: &[&ir::ObjectSelection],
    corr: Option<&Corr>,
    with_row_numbers: bool,
) {
    let order_in_base = ra.order_in_base();
    let t = b.alias();
    let node_rel_aliases: Vec<Vec<Option<Alias>>> =
        nodes.iter().map(|sel| alloc_rel_aliases(b, sel)).collect();
    let order_join_aliases = alloc_order_join_aliases(b, &ra.order);

    b.push("SELECT ");
    if !order_in_base && !ra.distinct_on.is_empty() {
        emit_middle_distinct(b, ra.distinct_on.len());
    }
    let mut first = true;
    for (k, c) in cols.iter().enumerate() {
        if !first {
            b.push(", ");
        }
        first = false;
        b.qual(t, c);
        b.push(" AS ");
        b.ident_n("_pc", k);
    }
    for (n, sel) in nodes.iter().enumerate() {
        if !first {
            b.push(", ");
        }
        first = false;
        emit_row_json(b, t, sel, &node_rel_aliases[n]);
        b.push(" AS ");
        b.ident_n("_n", n);
    }
    if with_row_numbers {
        if !first {
            b.push(", ");
        }
        first = false;
        // The requested ORDER BY goes inside the window: an empty OVER ()
        // numbers rows in scan order, which need not match the ordering
        // applied above the base relation, so the `_rn <= n` FILTER would
        // keep arbitrary rows instead of the first n in requested order.
        b.push("row_number() OVER (");
        for (k, o) in ra.order.iter().enumerate() {
            b.push(if k == 0 { "ORDER BY " } else { ", " });
            emit_order_target(b, t, o, &order_join_aliases[k]);
            b.push(" ");
            b.push(o.dir);
        }
        b.push(") AS \"_rn\"");
    }
    if first && ra.order.is_empty() {
        b.push("1");
    } else if first && !ra.order.is_empty() {
        // Order columns follow with a leading comma; keep the list valid.
        b.push("1 AS \"_one\"");
    }
    emit_order_cols(b, t, &ra.order, &order_join_aliases);
    b.push(" FROM ");
    emit_base(b, table, t, ra, corr, order_in_base);
    emit_order_rel_joins(b, t, &ra.order, &order_join_aliases);
    for (n, sel) in nodes.iter().enumerate() {
        emit_rel_laterals(b, t, sel, &node_rel_aliases[n]);
    }
    if !order_in_base {
        emit_middle_order_limit(b, ra);
    }
}

/// Order expression for an `ArrayRelAggregate` target, as a correlated
/// subselect (`ObjectRelColumn` targets are LEFT JOINed in by
/// `emit_order_rel_joins` instead; `Column` never reaches here — see
/// `RowsArgs::from_select_args`).
fn emit_order_rel_expr(b: &mut Sql, parent: Alias, target: &ir::OrderTarget) {
    match target {
        ir::OrderTarget::Column { .. } | ir::OrderTarget::ObjectRelColumn { .. } => {
            unreachable!("handled directly in emit_order_target")
        }
        ir::OrderTarget::ArrayRelAggregate {
            path,
            remote_column,
            remote_table,
            op,
            column,
        } => {
            emit_order_obj_path(b, parent, path, &mut |b, leaf| {
                let a = b.alias();
                b.push("(SELECT ");
                if op == "count" && column.is_none() {
                    b.push("count(*)");
                } else {
                    b.push(op);
                    b.push("(");
                    if let Some(c) = column {
                        b.qual(a, c);
                    } else {
                        b.push("*");
                    }
                    b.push(")");
                }
                b.push(" FROM ");
                b.table(remote_table);
                b.push(" AS ");
                b.push_alias(a);
                b.push(" WHERE ((");
                b.qual(a, remote_column);
                b.push(") = (");
                b.qual(leaf, "id");
                b.push(")))");
            });
        }
    }
}

/// Walks object-relationship hops `(local col, remote table)` and calls
/// `leaf` with the alias of the innermost table.
fn emit_order_obj_path(
    b: &mut Sql,
    parent: Alias,
    path: &[(String, String)],
    leaf: &mut dyn FnMut(&mut Sql, Alias),
) {
    match path.split_first() {
        None => leaf(b, parent),
        Some(((local, remote), rest)) => {
            let a = b.alias();
            b.push("(SELECT ");
            emit_order_obj_path(b, a, rest, leaf);
            b.push(" FROM ");
            b.table(remote);
            b.push(" AS ");
            b.push_alias(a);
            b.push(" WHERE ((");
            b.qual(parent, local);
            b.push(") = (");
            b.qual(a, "id");
            b.push(")) LIMIT 1)");
        }
    }
}

fn emit_bool(b: &mut Sql, t: Alias, e: &ir::BoolExp) {
    match e {
        ir::BoolExp::And(list) => {
            if list.is_empty() {
                b.push("('true')");
            } else {
                b.push("(");
                for (i, e) in list.iter().enumerate() {
                    if i > 0 {
                        b.push(" AND ");
                    }
                    emit_bool(b, t, e);
                }
                b.push(")");
            }
        }
        ir::BoolExp::Or(list) => {
            if list.is_empty() {
                b.push("('false')");
            } else {
                b.push("(");
                for (i, e) in list.iter().enumerate() {
                    if i > 0 {
                        b.push(" OR ");
                    }
                    emit_bool(b, t, e);
                }
                b.push(")");
            }
        }
        ir::BoolExp::Not(e) => {
            b.push("(NOT ");
            emit_bool(b, t, e);
            b.push(")");
        }
        ir::BoolExp::Compare {
            column,
            pg_type,
            op,
            ..
        } => {
            let mut lhs = String::new();
            lhs_qual(&mut lhs, t, column);
            emit_compare(b, &lhs, op, pg_type);
        }
        ir::BoolExp::ObjectRel {
            local_column,
            remote_table,
            exp,
        } => {
            emit_exists(b, remote_table, "id", t, local_column, exp);
        }
        ir::BoolExp::ArrayRel {
            remote_column,
            remote_table,
            exp,
        } => {
            emit_exists(b, remote_table, remote_column, t, "id", exp);
        }
        ir::BoolExp::ArrayRelAggregate {
            remote_column,
            remote_table,
            pred,
        } => {
            let a = b.alias();
            b.push("(EXISTS (SELECT 1 FROM (SELECT ");
            emit_agg_predicate_expr(b, a, pred);
            b.push(" AS \"_agg\" FROM ");
            b.table(remote_table);
            b.push(" AS ");
            b.push_alias(a);
            b.push(" WHERE (((");
            b.qual(a, remote_column);
            b.push(") = (");
            b.qual(t, "id");
            b.push("))");
            if let Some(f) = &pred.filter {
                b.push(" AND ");
                emit_bool(b, a, f);
            }
            b.push(")) AS \"_sub\" WHERE ");
            if pred.predicate.is_empty() {
                b.push("('true')");
            } else {
                b.push("(");
                for (i, op) in pred.predicate.iter().enumerate() {
                    if i > 0 {
                        b.push(" AND ");
                    }
                    emit_compare(b, "(\"_sub\".\"_agg\")", op, "int4");
                }
                b.push(")");
            }
            b.push("))");
        }
    }
}

fn emit_exists(
    b: &mut Sql,
    remote_table: &str,
    child_col: &str,
    parent: Alias,
    parent_col: &str,
    exp: &ir::BoolExp,
) {
    let a = b.alias();
    b.push("(EXISTS (SELECT 1 FROM ");
    b.table(remote_table);
    b.push(" AS ");
    b.push_alias(a);
    b.push(" WHERE (((");
    b.qual(a, child_col);
    b.push(") = (");
    b.qual(parent, parent_col);
    b.push(")) AND ");
    emit_bool(b, a, exp);
    b.push(")))");
}

fn emit_agg_predicate_expr(b: &mut Sql, t: Alias, pred: &ir::AggregatePredicate) {
    if pred.op == "count" && pred.columns.is_empty() {
        b.push("count(*)");
        return;
    }
    b.push(&pred.op);
    b.push("(");
    if pred.distinct {
        b.push("DISTINCT ");
    }
    if pred.columns.is_empty() {
        b.push("*");
    } else {
        for (i, c) in pred.columns.iter().enumerate() {
            if i > 0 {
                b.push(", ");
            }
            b.qual(t, c);
        }
    }
    b.push(")");
}

fn lhs_qual(out: &mut String, alias: Alias, col: &str) {
    let _ = write!(out, "(\"t{}\".", alias.0);
    push_ident_to(out, col);
    out.push(')');
}

fn push_ident_to(out: &mut String, name: &str) {
    out.push('"');
    for c in name.chars() {
        if c == '"' {
            out.push('"');
        }
        out.push(c);
    }
    out.push('"');
}

fn emit_compare(b: &mut Sql, lhs: &str, op: &ir::CompareOp, pg_type: &str) {
    use ir::CompareOp as C;

    let binary = |b: &mut Sql, sql_op: &str, v: &ir::SqlValue| {
        b.push("(");
        b.push(lhs);
        b.push(" ");
        b.push(sql_op);
        b.push(" ");
        b.param(v);
        b.push(")");
    };

    match op {
        C::Eq(v) => binary(b, "=", v),
        C::Neq(v) => binary(b, "<>", v),
        C::Gt(v) => binary(b, ">", v),
        C::Gte(v) => binary(b, ">=", v),
        C::Lt(v) => binary(b, "<", v),
        C::Lte(v) => binary(b, "<=", v),
        C::Like(v) => binary(b, "LIKE", v),
        C::Nlike(v) => binary(b, "NOT LIKE", v),
        C::Ilike(v) => binary(b, "ILIKE", v),
        C::Nilike(v) => binary(b, "NOT ILIKE", v),
        C::Similar(v) => binary(b, "SIMILAR TO", v),
        C::Nsimilar(v) => binary(b, "NOT SIMILAR TO", v),
        C::Regex(v) => binary(b, "~", v),
        C::Iregex(v) => binary(b, "~*", v),
        C::Nregex(v) => binary(b, "!~", v),
        C::Niregex(v) => binary(b, "!~*", v),
        C::Contains(v) => binary(b, "@>", v),
        C::ContainedIn(v) => binary(b, "<@", v),
        C::HasKey(v) => binary(b, "?", v),
        C::In(vs) => {
            b.push("(");
            b.push(lhs);
            b.push(" = ANY(");
            emit_in_array(b, vs, pg_type);
            b.push("))");
        }
        C::Nin(vs) => {
            b.push("(NOT (");
            b.push(lhs);
            b.push(" = ANY(");
            emit_in_array(b, vs, pg_type);
            b.push(")))");
        }
        C::IsNull(true) => {
            b.push("(");
            b.push(lhs);
            b.push(" IS NULL)");
        }
        C::IsNull(false) => {
            b.push("(");
            b.push(lhs);
            b.push(" IS NOT NULL)");
        }
        C::HasKeysAll(vs) => {
            b.push("(");
            b.push(lhs);
            b.push(" ?& ");
            b.param_array(vs.iter().map(|v| v.text.as_deref()), "text");
            b.push(")");
        }
        C::HasKeysAny(vs) => {
            b.push("(");
            b.push(lhs);
            b.push(" ?| ");
            b.param_array(vs.iter().map(|v| v.text.as_deref()), "text");
            b.push(")");
        }
        C::CastText(ops) => {
            let cast_lhs = format!("({lhs}::text)");
            b.push("(");
            for (i, op) in ops.iter().enumerate() {
                if i > 0 {
                    b.push(" AND ");
                }
                emit_compare(b, &cast_lhs, op, "text");
            }
            b.push(")");
        }
    }
}

/// For array-typed columns this deliberately reproduces Hasura v2.43's
/// broken `_in`/`_nin`: each element (itself an array, text form `{a,b}`)
/// is quoted into a flat 1-D array literal, losing dimensionality, so
/// Postgres rejects `col = ANY(...)` with "operator does not exist" and
/// the client sees the masked "database query error" — pinned by
/// snapshots/default/wm-array-in-database-error.json. Do not "fix" the
/// dimensionality.
fn emit_in_array(b: &mut Sql, vs: &[ir::SqlValue], pg_type: &str) {
    let elem_cast = vs
        .first()
        .map(|v| v.cast.as_str())
        .unwrap_or(pg_type)
        .to_string();
    b.param_array(vs.iter().map(|v| v.text.as_deref()), &elem_cast);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::serve::model::Scalar;

    fn compile_root(pg_schema: &str, root: &ir::TableRoot) -> (String, Vec<Option<String>>) {
        let c = compile_root_full(pg_schema, root);
        (c.sql, c.params)
    }

    fn col(alias: &str, column: &str, scalar: Scalar, pg_type: &str) -> ir::SelItem {
        ir::SelItem::Column {
            alias: alias.to_string(),
            column: column.to_string(),
            scalar,
            pg_type: pg_type.to_string(),
            is_array: false,
            json_path: None,
        }
    }

    #[test]
    fn many_with_where_order_limit() {
        let root = ir::TableRoot {
            alias: "User".to_string(),
            table: "User".to_string(),
            kind: ir::TableRootKind::Many {
                args: ir::SelectArgs {
                    where_: Some(ir::BoolExp::Compare {
                        column: "id".to_string(),
                        scalar: Scalar::String,
                        pg_type: "text".to_string(),
                        is_array: false,
                        op: ir::CompareOp::Eq(ir::SqlValue::new("u1", "text")),
                    }),
                    order_by: vec![ir::OrderByItem {
                        target: ir::OrderTarget::Column {
                            column: "age".to_string(),
                        },
                        direction: ir::OrderDirection::Desc,
                    }],
                    limit: Some(2),
                    offset: Some(1),
                    distinct_on: vec![],
                },
                selection: ir::ObjectSelection {
                    table: "User".to_string(),
                    items: vec![
                        col("id", "id", Scalar::String, "text"),
                        col("big", "big", Scalar::Numeric, "numeric"),
                        ir::SelItem::Typename {
                            alias: "__typename".to_string(),
                            type_name: "User".to_string(),
                        },
                    ],
                },
            },
        };
        let (sql, params) = compile_root("public", &root);
        assert_eq!(
            (sql.as_str(), params),
            (
                "SELECT (coalesce(json_agg(\"_v\" ORDER BY \"_o0\" DESC NULLS FIRST), '[]'))::text AS \"root\" \
                 FROM (SELECT row_to_json((SELECT \"_e\" FROM (SELECT \"t0\".\"id\" AS \"id\", (\"t0\".\"big\")::text AS \"big\", 'User' AS \"__typename\") AS \"_e\")) AS \"_v\", \"t0\".\"age\" AS \"_o0\" \
                 FROM (SELECT * FROM \"public\".\"User\" AS \"t0\" WHERE ((\"t0\".\"id\") = (($1)::text)) ORDER BY \"age\" DESC NULLS FIRST LIMIT (($2)::int8) OFFSET (($3)::int8)) AS \"t0\") AS \"_r\"",
                vec![
                    Some("u1".to_string()),
                    Some("2".to_string()),
                    Some("1".to_string())
                ]
            )
        );
    }

    #[test]
    fn by_pk() {
        let root = ir::TableRoot {
            alias: "u".to_string(),
            table: "User".to_string(),
            kind: ir::TableRootKind::ByPk {
                pk: vec![("id".to_string(), ir::SqlValue::new("u1", "text"))],
                selection: ir::ObjectSelection {
                    table: "User".to_string(),
                    items: vec![col("id", "id", Scalar::String, "text")],
                },
            },
        };
        let (sql, params) = compile_root("public", &root);
        assert_eq!(
            (sql.as_str(), params),
            (
                "SELECT (coalesce((json_agg(\"_v\")->0), 'null'))::text AS \"root\" \
                 FROM (SELECT row_to_json((SELECT \"_e\" FROM (SELECT \"t0\".\"id\" AS \"id\") AS \"_e\")) AS \"_v\" \
                 FROM (SELECT * FROM \"public\".\"User\" AS \"t0\" WHERE ((\"t0\".\"id\") = (($1)::text))) AS \"t0\") AS \"_r\"",
                vec![Some("u1".to_string())]
            )
        );
    }

    #[test]
    fn bool_exp_nesting_and_in() {
        let root = ir::TableRoot {
            alias: "T".to_string(),
            table: "T".to_string(),
            kind: ir::TableRootKind::Many {
                args: ir::SelectArgs {
                    where_: Some(ir::BoolExp::And(vec![
                        ir::BoolExp::Or(vec![]),
                        ir::BoolExp::Not(Box::new(ir::BoolExp::Compare {
                            column: "name".to_string(),
                            scalar: Scalar::String,
                            pg_type: "text".to_string(),
                            is_array: false,
                            op: ir::CompareOp::In(vec![
                                ir::SqlValue::new("a\"b", "text"),
                                ir::SqlValue::new("c\\d", "text"),
                            ]),
                        })),
                        ir::BoolExp::Compare {
                            column: "name".to_string(),
                            scalar: Scalar::String,
                            pg_type: "text".to_string(),
                            is_array: false,
                            op: ir::CompareOp::IsNull(false),
                        },
                    ])),
                    ..Default::default()
                },
                selection: ir::ObjectSelection {
                    table: "T".to_string(),
                    items: vec![col("id", "id", Scalar::String, "text")],
                },
            },
        };
        let (sql, params) = compile_root("public", &root);
        assert_eq!(
            (sql.as_str(), params),
            (
                "SELECT (coalesce(json_agg(\"_v\"), '[]'))::text AS \"root\" \
                 FROM (SELECT row_to_json((SELECT \"_e\" FROM (SELECT \"t0\".\"id\" AS \"id\") AS \"_e\")) AS \"_v\" \
                 FROM (SELECT * FROM \"public\".\"T\" AS \"t0\" WHERE (('false') AND (NOT ((\"t0\".\"name\") = ANY((($1)::text[])))) AND ((\"t0\".\"name\") IS NOT NULL))) AS \"t0\") AS \"_r\"",
                vec![Some("{\"a\\\"b\",\"c\\\\d\"}".to_string())]
            )
        );
    }

    #[test]
    fn in_on_array_column_reproduces_hasura_error_shape() {
        // Matches Hasura's broken flat-array encoding pinned by
        // wm-array-in-database-error.json: elements keep their 1-D text
        // form as quoted scalars while the cast gains a (meaningless)
        // extra dimension, so Postgres errors on `text[] = text`.
        let root = ir::TableRoot {
            alias: "E".to_string(),
            table: "E".to_string(),
            kind: ir::TableRootKind::Many {
                args: ir::SelectArgs {
                    where_: Some(ir::BoolExp::Compare {
                        column: "arrayOfStrings".to_string(),
                        scalar: Scalar::String,
                        pg_type: "text".to_string(),
                        is_array: true,
                        op: ir::CompareOp::In(vec![
                            ir::SqlValue::new("{\"a\"}", "text[]"),
                            ir::SqlValue::new("{\"one\",\"two\"}", "text[]"),
                        ]),
                    }),
                    ..Default::default()
                },
                selection: ir::ObjectSelection {
                    table: "E".to_string(),
                    items: vec![col("id", "id", Scalar::String, "text")],
                },
            },
        };
        let (sql, params) = compile_root("public", &root);
        assert_eq!(
            (sql.as_str(), params),
            (
                "SELECT (coalesce(json_agg(\"_v\"), '[]'))::text AS \"root\" \
                 FROM (SELECT row_to_json((SELECT \"_e\" FROM (SELECT \"t0\".\"id\" AS \"id\") AS \"_e\")) AS \"_v\" \
                 FROM (SELECT * FROM \"public\".\"E\" AS \"t0\" WHERE ((\"t0\".\"arrayOfStrings\") = ANY((($1)::text[][])))) AS \"t0\") AS \"_r\"",
                vec![Some(
                    "{\"{\\\"a\\\"}\",\"{\\\"one\\\",\\\"two\\\"}\"}".to_string()
                )]
            )
        );
    }

    #[test]
    fn aggregate_with_nodes_and_typename() {
        let root = ir::TableRoot {
            alias: "User_aggregate".to_string(),
            table: "User".to_string(),
            kind: ir::TableRootKind::Aggregate {
                args: ir::SelectArgs::default(),
                selection: ir::AggregateSelection {
                    table: "User".to_string(),
                    items: vec![
                        ir::AggSelItem::Typename {
                            alias: "__typename".to_string(),
                            type_name: "User_aggregate".to_string(),
                        },
                        ir::AggSelItem::Aggregate {
                            alias: "aggregate".to_string(),
                            items: vec![
                                ir::AggFieldItem::Count {
                                    alias: "count".to_string(),
                                    columns: vec![],
                                    distinct: false,
                                },
                                ir::AggFieldItem::Count {
                                    alias: "c2".to_string(),
                                    columns: vec!["a".to_string(), "b".to_string()],
                                    distinct: true,
                                },
                                ir::AggFieldItem::Op {
                                    alias: "sum".to_string(),
                                    op: "sum".to_string(),
                                    columns: vec![ir::AggOpColumn::Column {
                                        alias: "big".to_string(),
                                        column: "big".to_string(),
                                        scalar: Scalar::Numeric,
                                        pg_type: "numeric".to_string(),
                                        is_array: false,
                                        op: "sum".to_string(),
                                    }],
                                },
                            ],
                        },
                        ir::AggSelItem::Nodes {
                            alias: "nodes".to_string(),
                            selection: ir::ObjectSelection {
                                table: "User".to_string(),
                                items: vec![col("id", "id", Scalar::String, "text")],
                            },
                        },
                    ],
                    nodes_limit: None,
                },
            },
        };
        let (sql, params) = compile_root("public", &root);
        assert_eq!(
            (sql.as_str(), params),
            (
                "SELECT (json_build_object('__typename', coalesce('User_aggregate', (bool_or('true'))::text), \
                 'aggregate', json_build_object('count', count(*), 'c2', count(DISTINCT (\"_r\".\"_pc0\", \"_r\".\"_pc1\")), 'sum', json_build_object('big', (sum(\"_r\".\"_pc2\"))::text)), \
                 'nodes', coalesce(json_agg(\"_n0\"), '[]')))::text AS \"root\" \
                 FROM (SELECT \"t0\".\"a\" AS \"_pc0\", \"t0\".\"b\" AS \"_pc1\", \"t0\".\"big\" AS \"_pc2\", \
                 row_to_json((SELECT \"_e\" FROM (SELECT \"t0\".\"id\" AS \"id\") AS \"_e\")) AS \"_n0\" \
                 FROM (SELECT * FROM \"public\".\"User\" AS \"t0\" WHERE ('true')) AS \"t0\") AS \"_r\"",
                vec![]
            )
        );
    }

    #[test]
    fn aggregate_typename_only_gets_limit_1() {
        // `X_aggregate { aggregate { __typename } }` compiles to no SQL
        // aggregate function; without the LIMIT 1 the statement would
        // return one identical constant row per table row.
        let root = ir::TableRoot {
            alias: "User_aggregate".to_string(),
            table: "User".to_string(),
            kind: ir::TableRootKind::Aggregate {
                args: ir::SelectArgs::default(),
                selection: ir::AggregateSelection {
                    table: "User".to_string(),
                    items: vec![ir::AggSelItem::Aggregate {
                        alias: "aggregate".to_string(),
                        items: vec![ir::AggFieldItem::Typename {
                            alias: "__typename".to_string(),
                            type_name: "User_aggregate_fields".to_string(),
                        }],
                    }],
                    nodes_limit: None,
                },
            },
        };
        let (sql, params) = compile_root("public", &root);
        assert_eq!(
            (sql.as_str(), params),
            (
                "SELECT (json_build_object('aggregate', json_build_object('__typename', 'User_aggregate_fields')))::text AS \"root\" \
                 FROM (SELECT 1 FROM (SELECT * FROM \"public\".\"User\" AS \"t0\" WHERE ('true')) AS \"t0\") AS \"_r\" LIMIT 1",
                vec![]
            )
        );
    }

    #[test]
    fn aggregate_nodes_limit_orders_row_numbers() {
        let root = ir::TableRoot {
            alias: "User_aggregate".to_string(),
            table: "User".to_string(),
            kind: ir::TableRootKind::Aggregate {
                args: ir::SelectArgs {
                    order_by: vec![ir::OrderByItem {
                        target: ir::OrderTarget::Column {
                            column: "id".to_string(),
                        },
                        direction: ir::OrderDirection::Asc,
                    }],
                    ..Default::default()
                },
                selection: ir::AggregateSelection {
                    table: "User".to_string(),
                    items: vec![ir::AggSelItem::Nodes {
                        alias: "nodes".to_string(),
                        selection: ir::ObjectSelection {
                            table: "User".to_string(),
                            items: vec![col("id", "id", Scalar::String, "text")],
                        },
                    }],
                    nodes_limit: Some(5),
                },
            },
        };
        let (sql, params) = compile_root("public", &root);
        assert_eq!(
            (sql.as_str(), params),
            (
                "SELECT (json_build_object('nodes', coalesce(json_agg(\"_n0\" ORDER BY \"_o0\" ASC NULLS LAST) FILTER (WHERE \"_rn\" <= 5), '[]')))::text AS \"root\" \
                 FROM (SELECT row_to_json((SELECT \"_e\" FROM (SELECT \"t0\".\"id\" AS \"id\") AS \"_e\")) AS \"_n0\", \
                 row_number() OVER (ORDER BY \"t0\".\"id\" ASC NULLS LAST) AS \"_rn\", \"t0\".\"id\" AS \"_o0\" \
                 FROM (SELECT * FROM \"public\".\"User\" AS \"t0\" WHERE ('true') ORDER BY \"id\" ASC NULLS LAST) AS \"t0\") AS \"_r\"",
                vec![]
            )
        );
    }

    #[test]
    fn relationships_and_rel_order() {
        let root = ir::TableRoot {
            alias: "Gravatar".to_string(),
            table: "Gravatar".to_string(),
            kind: ir::TableRootKind::Many {
                args: ir::SelectArgs {
                    order_by: vec![ir::OrderByItem {
                        target: ir::OrderTarget::ObjectRelColumn {
                            path: vec![("owner_id".to_string(), "User".to_string())],
                            column: "name".to_string(),
                        },
                        direction: ir::OrderDirection::Asc,
                    }],
                    limit: Some(3),
                    ..Default::default()
                },
                selection: ir::ObjectSelection {
                    table: "Gravatar".to_string(),
                    items: vec![
                        col("id", "id", Scalar::String, "text"),
                        ir::SelItem::ObjectRel {
                            alias: "owner".to_string(),
                            local_column: "owner_id".to_string(),
                            remote_table: "User".to_string(),
                            selection: ir::ObjectSelection {
                                table: "User".to_string(),
                                items: vec![col("id", "id", Scalar::String, "text")],
                            },
                        },
                        ir::SelItem::ArrayRel {
                            alias: "tags".to_string(),
                            remote_column: "gravatar_id".to_string(),
                            remote_table: "Tag".to_string(),
                            args: ir::SelectArgs {
                                limit: Some(2),
                                ..Default::default()
                            },
                            selection: ir::ObjectSelection {
                                table: "Tag".to_string(),
                                items: vec![col("id", "id", Scalar::String, "text")],
                            },
                        },
                    ],
                },
            },
        };
        let (sql, params) = compile_root("public", &root);
        assert_eq!(
            (sql.as_str(), params),
            (
                "SELECT (coalesce(json_agg(\"_v\" ORDER BY \"_o0\" ASC NULLS LAST), '[]'))::text AS \"root\" \
                 FROM (SELECT row_to_json((SELECT \"_e\" FROM (SELECT \"t0\".\"id\" AS \"id\", \"t1\".\"_v\" AS \"owner\", \"t2\".\"_v\" AS \"tags\") AS \"_e\")) AS \"_v\", \
                 \"t3\".\"name\" AS \"_o0\" \
                 FROM (SELECT * FROM \"public\".\"Gravatar\" AS \"t0\" WHERE ('true')) AS \"t0\" \
                 LEFT JOIN \"public\".\"User\" AS \"t3\" ON ((\"t0\".\"owner_id\") = (\"t3\".\"id\")) \
                 LEFT OUTER JOIN LATERAL (SELECT row_to_json((SELECT \"_e\" FROM (SELECT \"t4\".\"id\" AS \"id\") AS \"_e\")) AS \"_v\" \
                 FROM (SELECT * FROM \"public\".\"User\" AS \"t4\" WHERE ((\"t4\".\"id\") = (\"t0\".\"owner_id\")) LIMIT (($1)::int8)) AS \"t4\") AS \"t1\" ON ('true') \
                 LEFT OUTER JOIN LATERAL (SELECT coalesce(json_agg(\"_v\"), '[]') AS \"_v\" \
                 FROM (SELECT row_to_json((SELECT \"_e\" FROM (SELECT \"t5\".\"id\" AS \"id\") AS \"_e\")) AS \"_v\" \
                 FROM (SELECT * FROM \"public\".\"Tag\" AS \"t5\" WHERE ((\"t5\".\"gravatar_id\") = (\"t0\".\"id\")) LIMIT (($2)::int8)) AS \"t5\") AS \"_r\") AS \"t2\" ON ('true') \
                 ORDER BY \"_o0\" ASC NULLS LAST LIMIT (($3)::int8)) AS \"_r\"",
                vec![
                    Some("1".to_string()),
                    Some("2".to_string()),
                    Some("3".to_string())
                ]
            )
        );
    }

    fn stream_root(cursors: Vec<ir::StreamCursor>) -> ir::TableRoot {
        ir::TableRoot {
            alias: "Token_stream".to_string(),
            table: "Token".to_string(),
            kind: ir::TableRootKind::Stream {
                batch_size: 10,
                cursor: cursors,
                where_: None,
                selection: ir::ObjectSelection {
                    table: "Token".to_string(),
                    items: vec![col("id", "id", Scalar::String, "text")],
                },
            },
        }
    }

    fn cursor(
        column: &str,
        initial_value: Option<ir::SqlValue>,
        descending: bool,
    ) -> ir::StreamCursor {
        ir::StreamCursor {
            column: column.to_string(),
            scalar: Scalar::Numeric,
            pg_type: "numeric".to_string(),
            is_array: false,
            initial_value,
            descending,
        }
    }

    #[test]
    fn stream_cursor_bound() {
        let root = stream_root(vec![cursor(
            "tokenId",
            Some(ir::SqlValue::new("5", "numeric")),
            false,
        )]);
        let c = compile_root_full("public", &root);
        assert_eq!(
            (c.sql.as_str(), c.params, c.cursor_slots),
            (
                "SELECT (coalesce(json_agg(\"_v\" ORDER BY \"_o0\" ASC), '[]'))::text AS \"root\", \
                 (array_agg((\"_o0\")::text ORDER BY \"_o0\" ASC))[count(*)] AS \"cursor_0\" \
                 FROM (SELECT row_to_json((SELECT \"_e\" FROM (SELECT \"t0\".\"id\" AS \"id\") AS \"_e\")) AS \"_v\", \"t0\".\"tokenId\" AS \"_o0\" \
                 FROM (SELECT * FROM \"public\".\"Token\" AS \"t0\" WHERE ((\"t0\".\"tokenId\") > (($1)::numeric)) ORDER BY \"tokenId\" ASC LIMIT (($2)::int8)) AS \"t0\") AS \"_r\"",
                vec![Some("5".to_string()), Some("10".to_string())],
                vec![(0usize, 0usize)]
            )
        );
    }

    #[test]
    fn stream_cursor_null_position_asc_matches_nothing() {
        // ASC = NULLS LAST: no rows sort strictly after a NULL position,
        // so the stream drains but keeps polling with an empty result.
        let root = stream_root(vec![cursor(
            "tokenId",
            Some(ir::SqlValue::null("numeric")),
            false,
        )]);
        let c = compile_root_full("public", &root);
        assert_eq!(
            (c.sql.as_str(), c.params, c.cursor_slots),
            (
                "SELECT (coalesce(json_agg(\"_v\" ORDER BY \"_o0\" ASC), '[]'))::text AS \"root\", \
                 (array_agg((\"_o0\")::text ORDER BY \"_o0\" ASC))[count(*)] AS \"cursor_0\" \
                 FROM (SELECT row_to_json((SELECT \"_e\" FROM (SELECT \"t0\".\"id\" AS \"id\") AS \"_e\")) AS \"_v\", \"t0\".\"tokenId\" AS \"_o0\" \
                 FROM (SELECT * FROM \"public\".\"Token\" AS \"t0\" WHERE ('false') ORDER BY \"tokenId\" ASC LIMIT (($1)::int8)) AS \"t0\") AS \"_r\"",
                vec![Some("10".to_string())],
                vec![]
            )
        );
    }

    #[test]
    fn stream_cursor_null_position_desc_with_tiebreak() {
        // DESC = NULLS FIRST: after a NULL position the remainder is the
        // non-null rows; ties on the NULL continue via IS NULL into the
        // second cursor column's strict bound.
        let root = stream_root(vec![
            cursor("blockNumber", Some(ir::SqlValue::null("numeric")), true),
            cursor("logIndex", Some(ir::SqlValue::new("7", "numeric")), false),
        ]);
        let c = compile_root_full("public", &root);
        assert_eq!(
            (c.sql.as_str(), c.params, c.cursor_slots),
            (
                "SELECT (coalesce(json_agg(\"_v\" ORDER BY \"_o0\" DESC, \"_o1\" ASC), '[]'))::text AS \"root\", \
                 (array_agg((\"_o0\")::text ORDER BY \"_o0\" DESC, \"_o1\" ASC))[count(*)] AS \"cursor_0\", \
                 (array_agg((\"_o1\")::text ORDER BY \"_o0\" DESC, \"_o1\" ASC))[count(*)] AS \"cursor_1\" \
                 FROM (SELECT row_to_json((SELECT \"_e\" FROM (SELECT \"t0\".\"id\" AS \"id\") AS \"_e\")) AS \"_v\", \"t0\".\"blockNumber\" AS \"_o0\", \"t0\".\"logIndex\" AS \"_o1\" \
                 FROM (SELECT * FROM \"public\".\"Token\" AS \"t0\" WHERE (((\"t0\".\"blockNumber\") IS NOT NULL) OR (((\"t0\".\"blockNumber\") IS NULL) AND ((\"t0\".\"logIndex\") > (($1)::numeric)))) ORDER BY \"blockNumber\" DESC, \"logIndex\" ASC LIMIT (($2)::int8)) AS \"t0\") AS \"_r\"",
                vec![Some("7".to_string()), Some("10".to_string())],
                vec![(1usize, 0usize)]
            )
        );
    }

    #[test]
    fn stream_two_bounded_cursors_record_all_slots() {
        let root = stream_root(vec![
            cursor(
                "blockNumber",
                Some(ir::SqlValue::new("100", "numeric")),
                false,
            ),
            cursor("logIndex", Some(ir::SqlValue::new("7", "numeric")), false),
        ]);
        let c = compile_root_full("public", &root);
        assert_eq!(
            (c.sql.as_str(), c.params, c.cursor_slots),
            (
                "SELECT (coalesce(json_agg(\"_v\" ORDER BY \"_o0\" ASC, \"_o1\" ASC), '[]'))::text AS \"root\", \
                 (array_agg((\"_o0\")::text ORDER BY \"_o0\" ASC, \"_o1\" ASC))[count(*)] AS \"cursor_0\", \
                 (array_agg((\"_o1\")::text ORDER BY \"_o0\" ASC, \"_o1\" ASC))[count(*)] AS \"cursor_1\" \
                 FROM (SELECT row_to_json((SELECT \"_e\" FROM (SELECT \"t0\".\"id\" AS \"id\") AS \"_e\")) AS \"_v\", \"t0\".\"blockNumber\" AS \"_o0\", \"t0\".\"logIndex\" AS \"_o1\" \
                 FROM (SELECT * FROM \"public\".\"Token\" AS \"t0\" WHERE (((\"t0\".\"blockNumber\") > (($1)::numeric)) OR (((\"t0\".\"blockNumber\") = (($2)::numeric)) AND ((\"t0\".\"logIndex\") > (($3)::numeric)))) ORDER BY \"blockNumber\" ASC, \"logIndex\" ASC LIMIT (($4)::int8)) AS \"t0\") AS \"_r\"",
                vec![
                    Some("100".to_string()),
                    Some("100".to_string()),
                    Some("7".to_string()),
                    Some("10".to_string())
                ],
                vec![(0usize, 0usize), (0usize, 1usize), (1usize, 2usize)]
            )
        );
    }
}
