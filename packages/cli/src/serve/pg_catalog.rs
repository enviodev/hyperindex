//! Live Postgres catalog introspection — the source of truth for column
//! shapes, exactly like Hasura's own source introspection.

use anyhow::Context;
use std::collections::HashMap;
use tokio_postgres::types::{ToSql, Type};

pub struct Catalog {
    /// Tables and views in the target schema, keyed by relation name.
    pub relations: HashMap<String, Relation>,
}

pub struct Relation {
    pub name: String,
    pub kind: RelationKind,
    pub columns: Vec<Column>,
    /// Primary key column names, in key order. Empty for views.
    pub primary_key: Vec<String>,
}

#[derive(PartialEq, Eq, Clone, Copy)]
pub enum RelationKind {
    Table,
    View,
}

#[derive(Clone)]
pub struct Column {
    pub name: String,
    /// Base type name from pg_type (e.g. "text", "int4", "numeric",
    /// "timestamptz", or an enum type name like "accounttype").
    pub pg_type: String,
    /// Namespace owning the base/element type (`pg_catalog` for builtins,
    /// the project schema for enums and other custom types).
    pub pg_type_schema: String,
    pub is_array: bool,
    pub nullable: bool,
    pub is_enum: bool,
}

fn column_from_row(row: &tokio_postgres::Row) -> Result<Column, tokio_postgres::Error> {
    Ok(Column {
        name: row.try_get("column_name")?,
        pg_type: row.try_get("pg_type")?,
        pg_type_schema: row.try_get("pg_type_schema")?,
        is_array: row.try_get("is_array")?,
        nullable: row.try_get("nullable")?,
        is_enum: row.try_get("is_enum")?,
    })
}

pub async fn introspect(
    pool: &deadpool_postgres::Pool,
    pg_schema: &str,
) -> anyhow::Result<Catalog> {
    let client = pool.get().await.context("Failed acquiring PG connection")?;

    // Unnamed extended-protocol statements (`query_typed`), never named
    // prepared ones: startup introspection must survive a transaction-mode
    // pooler too, not just the root-query path. `$1` is bound as NAME to match
    // the `nspname` column type exactly, as server type inference would.
    let schema_param: &[(&(dyn ToSql + Sync), Type)] = &[(&pg_schema, Type::NAME)];

    let column_rows = client
        .query_typed(
            r#"
            SELECT
              c.relname::text AS table_name,
              c.relkind::text AS relkind,
              a.attname::text AS column_name,
              CASE WHEN t.typtype = 'd' THEN bt_base.typname ELSE base_t.typname END::text AS pg_type,
              CASE
                WHEN t.typtype = 'd' THEN bt_ns.nspname
                WHEN t.typcategory = 'A' THEN elem_ns.nspname
                ELSE type_ns.nspname
              END::text AS pg_type_schema,
              (t.typcategory = 'A')::bool AS is_array,
              NOT (a.attnotnull)::bool AS nullable,
              (CASE WHEN t.typcategory = 'A' THEN elem_t.typtype ELSE t.typtype END = 'e')::bool AS is_enum,
              a.attnum
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
            JOIN pg_type t ON t.oid = a.atttypid
            LEFT JOIN pg_type elem_t ON elem_t.oid = t.typelem
            LEFT JOIN pg_type bt_base ON t.typtype = 'd' AND bt_base.oid = t.typbasetype
            LEFT JOIN pg_namespace type_ns ON type_ns.oid = t.typnamespace
            LEFT JOIN pg_namespace elem_ns ON elem_ns.oid = elem_t.typnamespace
            LEFT JOIN pg_namespace bt_ns ON bt_ns.oid = bt_base.typnamespace
            JOIN LATERAL (
              SELECT CASE WHEN t.typcategory = 'A' THEN elem_t.typname ELSE t.typname END AS typname
            ) base_t ON true
            WHERE n.nspname = $1 AND c.relkind IN ('r', 'v', 'm')
            ORDER BY c.relname, a.attnum
            "#,
            schema_param,
        )
        .await
        .context("Failed querying pg_catalog for columns")?;

    let pk_rows = client
        .query_typed(
            r#"
            SELECT c.relname::text AS table_name, a.attname::text AS column_name, k.ordinality
            FROM pg_index i
            JOIN pg_class c ON c.oid = i.indrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ordinality) ON true
            JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
            WHERE n.nspname = $1 AND i.indisprimary
            ORDER BY c.relname, k.ordinality
            "#,
            schema_param,
        )
        .await
        .context("Failed querying pg_catalog for primary keys")?;

    let mut relations: HashMap<String, Relation> = HashMap::new();
    for row in column_rows {
        let table_name: String = row.get("table_name");
        let relkind: String = row.get("relkind");
        let relation = relations
            .entry(table_name.clone())
            .or_insert_with(|| Relation {
                name: table_name,
                kind: if relkind == "r" {
                    RelationKind::Table
                } else {
                    RelationKind::View
                },
                columns: Vec::new(),
                primary_key: Vec::new(),
            });
        // pg_type/pg_type_schema/is_enum come from LEFT JOINs on the type
        // catalog and are NULL only for a type that can't be resolved
        // (e.g. a domain or array whose base/element type row is missing).
        // Hasura refuses such a column as a source inconsistency; fail
        // startup with a clear error rather than panicking in `Row::get`.
        let column = column_from_row(&row).with_context(|| {
            format!(
                "Column \"{}\" of \"{pg_schema}\".\"{}\" has an unresolvable or unsupported type",
                row.get::<_, String>("column_name"),
                relation.name,
            )
        })?;
        relation.columns.push(column);
    }

    for row in pk_rows {
        let table_name: String = row.get("table_name");
        if let Some(rel) = relations.get_mut(&table_name) {
            rel.primary_key.push(row.get("column_name"));
        }
    }

    Ok(Catalog { relations })
}
