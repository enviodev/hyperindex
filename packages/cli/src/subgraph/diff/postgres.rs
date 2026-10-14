//! The indexer's own Postgres, read inside one read-only snapshot so the
//! progress block and every row the diff sees belong to the same batch.

use std::collections::HashMap;

use anyhow::{anyhow, Context, Result};
use serde_json::Value;
use tokio_postgres::config::SslMode;

use super::model::{Entity, FieldKind};
use crate::utils::project_env::ProjectEnv;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PgConfig {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub database: String,
    pub schema: String,
    pub ssl: Ssl,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ssl {
    Disable,
    /// TLS when the server offers it, unverified.
    Prefer,
    /// TLS, unverified — what `ENVIO_PG_SSL_MODE=require` means to the runtime.
    Require,
    VerifyFull,
}

impl PgConfig {
    /// The connection the indexer itself uses: the same `ENVIO_PG_*` variables,
    /// process environment first, then the project's `.env`, with the
    /// runtime's defaults.
    pub fn from_env(env: &ProjectEnv) -> Result<Self> {
        let var = |name: &str, default: &str| env.var(name).unwrap_or_else(|| default.to_string());
        let port = var("ENVIO_PG_PORT", "5433");
        let ssl = match env.var("ENVIO_PG_SSL_MODE").as_deref() {
            None | Some("false") | Some("") => Ssl::Disable,
            Some("allow") | Some("prefer") => Ssl::Prefer,
            Some("require") => Ssl::Require,
            Some("true") | Some("verify-full") => Ssl::VerifyFull,
            Some(other) => {
                return Err(anyhow!(
                    "ENVIO_PG_SSL_MODE={other:?} isn't one of true, false, require, allow, \
                     prefer, verify-full."
                ))
            }
        };
        Ok(PgConfig {
            host: var("ENVIO_PG_HOST", "localhost"),
            port: port
                .parse()
                .map_err(|_| anyhow!("ENVIO_PG_PORT={port:?} is not a port number."))?,
            user: var("ENVIO_PG_USER", "postgres"),
            password: env
                .var("ENVIO_PG_PASSWORD")
                .or_else(|| env.var("ENVIO_POSTGRES_PASSWORD"))
                .unwrap_or_else(|| "testing".to_string()),
            database: var("ENVIO_PG_DATABASE", "envio-dev"),
            schema: env
                .var("ENVIO_PG_SCHEMA")
                .or_else(|| env.var("ENVIO_PG_PUBLIC_SCHEMA"))
                .unwrap_or_else(|| "public".to_string()),
            ssl,
        })
    }

    pub fn describe(&self) -> String {
        format!(
            "postgres://{}@{}:{}/{} (schema {})",
            self.user, self.host, self.port, self.database, self.schema
        )
    }
}

pub struct PgSide {
    client: tokio_postgres::Client,
    schema: String,
}

/// A stored column and the SQL that renders it as graph-node would encode it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Column {
    pub name: String,
    pub udt: String,
}

/// A compared field as ours stores it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Planned {
    pub field: String,
    pub column: Column,
    /// For a relation graph-node resolves leniently (a nullable one, or a
    /// list), the entity it points at, so an id with no entity behind it reads
    /// the way graph-node serves it.
    pub relation: Option<Relation>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Relation {
    /// The target entity's table.
    pub table: String,
    /// The type of its `id` column.
    pub id_udt: String,
}

/// The JSON key a row carries the count of a field's dangling ids under. `:`
/// can't appear in a GraphQL name, so it never collides with a field.
pub fn dangling_key(field: &str) -> String {
    format!("dangling:{field}")
}

impl PgSide {
    pub async fn connect(config: &PgConfig) -> Result<Self> {
        let mut pg = tokio_postgres::Config::new();
        pg.host(&config.host)
            .port(config.port)
            .user(&config.user)
            .password(&config.password)
            .dbname(&config.database)
            .application_name("envio subgraph diff")
            .connect_timeout(std::time::Duration::from_secs(10));
        let context = || format!("Failed to connect to {}", config.describe());
        let client = match config.ssl {
            Ssl::Disable => {
                pg.ssl_mode(SslMode::Disable);
                let (client, connection) = pg
                    .connect(tokio_postgres::NoTls)
                    .await
                    .with_context(context)?;
                tokio::spawn(connection);
                client
            }
            ssl => {
                pg.ssl_mode(if ssl == Ssl::Prefer {
                    SslMode::Prefer
                } else {
                    SslMode::Require
                });
                let connector = native_tls::TlsConnector::builder()
                    .danger_accept_invalid_certs(ssl != Ssl::VerifyFull)
                    .danger_accept_invalid_hostnames(ssl != Ssl::VerifyFull)
                    .build()
                    .context("Failed to set up TLS for Postgres")?;
                let (client, connection) = pg
                    .connect(postgres_native_tls::MakeTlsConnector::new(connector))
                    .await
                    .with_context(context)?;
                tokio::spawn(connection);
                client
            }
        };
        // Every later read goes through this one connection, so they all see
        // the snapshot this opens — the batch the progress block belongs to.
        client
            .batch_execute("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
            .await
            .context("Failed to open a read-only snapshot")?;
        Ok(PgSide {
            client,
            schema: config.schema.clone(),
        })
    }

    fn table(&self, name: &str) -> String {
        format!("{}.{}", quote(&self.schema), quote(name))
    }

    /// The block the indexer has fully processed: `envio_chains.progress_block`.
    pub async fn progress_block(&self) -> Result<u64> {
        let rows = self
            .client
            .query(
                &format!(
                    "SELECT id::bigint, progress_block::bigint FROM {} ORDER BY id",
                    self.table("envio_chains")
                ),
                &[],
            )
            .await
            .context(
                "Failed to read envio_chains — is this the database the indexer writes to? \
                 Check ENVIO_PG_DATABASE / ENVIO_PG_SCHEMA",
            )?;
        let chains: Vec<(i64, i64)> = rows.iter().map(|row| (row.get(0), row.get(1))).collect();
        match chains.as_slice() {
            [] => Err(anyhow!(
                "envio_chains is empty: the indexer hasn't started yet"
            )),
            [(_, progress)] if *progress < 0 => Err(anyhow!(
                "The indexer hasn't processed a block yet (progress_block {progress})"
            )),
            [(_, progress)] => Ok(*progress as u64),
            many => Err(anyhow!(
                "The database holds {} chains ({}); a subgraph indexes one network",
                many.len(),
                many.iter()
                    .map(|(id, _)| id.to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            )),
        }
    }

    pub async fn columns(&self, table: &str) -> Result<HashMap<String, Column>> {
        let rows = self
            .client
            .query(
                "SELECT column_name::text, udt_name::text FROM information_schema.columns \
                 WHERE table_schema = $1 AND table_name = $2",
                &[&self.schema, &table],
            )
            .await?;
        Ok(rows
            .iter()
            .map(|row| {
                let name: String = row.get(0);
                (
                    name.clone(),
                    Column {
                        name,
                        udt: row.get(1),
                    },
                )
            })
            .collect())
    }

    pub async fn count(&self, table: &str) -> Result<u64> {
        let row = self
            .client
            .query_one(
                &format!("SELECT count(*)::bigint FROM {}", self.table(table)),
                &[],
            )
            .await?;
        Ok(row.get::<_, i64>(0) as u64)
    }

    pub async fn ids(&self, table: &str) -> Result<Vec<Value>> {
        let rows = self
            .client
            .query(&format!("SELECT id::text FROM {}", self.table(table)), &[])
            .await?;
        Ok(rows
            .iter()
            .map(|row| Value::String(row.get::<_, String>(0)))
            .collect())
    }

    /// The rows for `ids`, each a JSON object keyed by the subgraph's field
    /// names, values rendered as text the normalizer reads like graph-node's.
    /// A relation in the plan also yields, under [`dangling_key`], how many of
    /// its ids point at no entity: graph-node serves such a relation as `null`
    /// and leaves such an id out of a list, and so does this read.
    pub async fn rows(
        &self,
        entity: &Entity,
        plan: &[Planned],
        id_udt: &str,
        ids: &[Value],
    ) -> Result<Vec<Value>> {
        let mut select = vec![format!("{} AS \"id\"", render("id", id_udt))];
        for planned in plan {
            let column = format!("e.{}", quote(&planned.column.name));
            match &planned.relation {
                None => select.push(format!(
                    "{} AS {}",
                    render(&column, &planned.column.udt),
                    quote(&planned.field)
                )),
                Some(relation) => {
                    let (value, dangling) = render_relation(
                        &column,
                        &planned.column.udt,
                        &self.table(&relation.table),
                        &relation.id_udt,
                    );
                    select.push(format!("{value} AS {}", quote(&planned.field)));
                    select.push(format!(
                        "{dangling} AS {}",
                        quote(&dangling_key(&planned.field))
                    ));
                }
            }
        }
        let id_filter = if id_udt == "text" {
            "\"id\" = ANY($1::text[])".to_string()
        } else {
            format!("\"id\" = ANY($1::text[]::{}[])", quote(id_udt))
        };
        let sql = format!(
            "SELECT row_to_json(t)::text FROM (SELECT {} FROM {} e WHERE {id_filter}) t",
            select.join(", "),
            self.table(&entity.name)
        );
        let ids: Vec<String> = ids
            .iter()
            .map(|id| {
                id.as_str()
                    .map(str::to_string)
                    .unwrap_or_else(|| id.to_string())
            })
            .collect();
        let rows = self.client.query(&sql, &[&ids]).await?;
        rows.iter()
            .map(|row| {
                serde_json::from_str(row.get::<_, &str>(0))
                    .context("Postgres returned a row that isn't JSON")
            })
            .collect()
    }
}

/// The column a field is stored in: `<field>_id` for a single relation.
pub fn column_for(field: &super::model::Field) -> String {
    match (&field.kind, field.list) {
        (FieldKind::Entity { .. }, false) => format!("{}_id", field.name),
        _ => field.name.clone(),
    }
}

pub fn quote(identifier: &str) -> String {
    format!("\"{}\"", identifier.replace('"', "\"\""))
}

/// SQL rendering a column the way graph-node encodes the value: `0x` hex for
/// bytes, microseconds for a timestamp, and text for everything else, so no
/// numeric precision is lost on the way to JSON.
pub fn render(column: &str, udt: &str) -> String {
    if udt.starts_with('_') {
        // `ARRAY(... unnest(NULL))` is `{}`, and an unset list is null.
        format!(
            "CASE WHEN {column} IS NULL THEN NULL ELSE ARRAY(SELECT {} FROM unnest({column}) \
             WITH ORDINALITY AS u(x, i) ORDER BY i) END",
            element("u.x", udt)
        )
    } else {
        element(column, udt)
    }
}

/// One stored value (a list's element type for a list `udt`) as text.
fn element(x: &str, udt: &str) -> String {
    match udt.trim_start_matches('_') {
        "bytea" => format!("'0x' || encode({x}, 'hex')"),
        "timestamptz" | "timestamp" => {
            format!("trunc(extract(epoch from {x}) * 1000000)::text")
        }
        _ => format!("{x}::text"),
    }
}

/// A relation column the way graph-node serves it: graph-node joins the
/// target table, so a single relation whose entity doesn't exist is `null`,
/// and a list keeps only the ids that do (`relational_queries.rs`, child types
/// C and D). Returns that SQL and the SQL counting the ids it dropped.
pub fn render_relation(
    column: &str,
    udt: &str,
    target: &str,
    target_udt: &str,
) -> (String, String) {
    let element_udt = udt.trim_start_matches('_');
    let exists = |x: &str| {
        let matches = if element_udt == target_udt {
            format!("r.\"id\" = {x}")
        } else {
            format!(
                "{} = {}",
                element("r.\"id\"", target_udt),
                element(x, element_udt)
            )
        };
        format!("EXISTS (SELECT 1 FROM {target} r WHERE {matches})")
    };
    if udt.starts_with('_') {
        (
            format!(
                "CASE WHEN {column} IS NULL THEN NULL ELSE ARRAY(SELECT {} FROM unnest({column}) \
                 WITH ORDINALITY AS u(x, i) WHERE {} ORDER BY i) END",
                element("u.x", udt),
                exists("u.x")
            ),
            format!(
                "(SELECT count(*) FROM unnest({column}) AS u(x) WHERE NOT {})::int",
                exists("u.x")
            ),
        )
    } else {
        (
            format!(
                "CASE WHEN {} THEN {} END",
                exists(column),
                element(column, udt)
            ),
            format!("({column} IS NOT NULL AND NOT {})::int", exists(column)),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn renders_columns_as_graph_node_encodes_them() {
        assert_eq!(
            [
                ("\"owner\"", "bytea"),
                ("\"supply\"", "numeric"),
                ("\"hashes\"", "_bytea"),
                ("\"minted\"", "timestamptz"),
                ("\"tags\"", "_text"),
            ]
            .map(|(column, udt)| render(column, udt))
            .to_vec(),
            [
                "'0x' || encode(\"owner\", 'hex')",
                "\"supply\"::text",
                "CASE WHEN \"hashes\" IS NULL THEN NULL ELSE ARRAY(SELECT '0x' || encode(u.x, \
                 'hex') FROM unnest(\"hashes\") WITH ORDINALITY AS u(x, i) ORDER BY i) END",
                "trunc(extract(epoch from \"minted\") * 1000000)::text",
                "CASE WHEN \"tags\" IS NULL THEN NULL ELSE ARRAY(SELECT u.x::text FROM \
                 unnest(\"tags\") WITH ORDINALITY AS u(x, i) ORDER BY i) END",
            ]
        );
    }

    #[test]
    fn renders_a_relation_as_graph_node_resolves_it() {
        assert_eq!(
            [
                render_relation("e.\"owner_id\"", "text", "public.\"Account\"", "text"),
                render_relation("e.\"owner_id\"", "text", "public.\"Account\"", "bytea"),
                render_relation("e.\"tokens\"", "_text", "public.\"Token\"", "text"),
            ]
            .to_vec(),
            [
                (
                    "CASE WHEN EXISTS (SELECT 1 FROM public.\"Account\" r WHERE r.\"id\" = \
                     e.\"owner_id\") THEN e.\"owner_id\"::text END"
                        .to_string(),
                    "(e.\"owner_id\" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM \
                     public.\"Account\" r WHERE r.\"id\" = e.\"owner_id\"))::int"
                        .to_string()
                ),
                (
                    "CASE WHEN EXISTS (SELECT 1 FROM public.\"Account\" r WHERE '0x' || \
                     encode(r.\"id\", 'hex') = e.\"owner_id\"::text) THEN \
                     e.\"owner_id\"::text END"
                        .to_string(),
                    "(e.\"owner_id\" IS NOT NULL AND NOT EXISTS (SELECT 1 FROM \
                     public.\"Account\" r WHERE '0x' || encode(r.\"id\", 'hex') = \
                     e.\"owner_id\"::text))::int"
                        .to_string()
                ),
                (
                    "CASE WHEN e.\"tokens\" IS NULL THEN NULL ELSE ARRAY(SELECT u.x::text FROM \
                     unnest(e.\"tokens\") WITH ORDINALITY AS u(x, i) WHERE EXISTS (SELECT 1 \
                     FROM public.\"Token\" r WHERE r.\"id\" = u.x) ORDER BY i) END"
                        .to_string(),
                    "(SELECT count(*) FROM unnest(e.\"tokens\") AS u(x) WHERE NOT EXISTS \
                     (SELECT 1 FROM public.\"Token\" r WHERE r.\"id\" = u.x))::int"
                        .to_string()
                ),
            ]
        );
    }
}
