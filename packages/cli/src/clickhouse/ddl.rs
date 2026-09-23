use std::collections::HashMap;
use std::fmt::Write as _;
use std::sync::LazyLock;

use anyhow::{bail, Result};
use napi_derive::napi;
use regex::{Captures, Regex};

use super::ch_type::{ChType, FieldSpec};
use super::{literal, quoted};
use crate::config_parsing::system_config::ChainIdMode;

#[derive(Debug, Clone)]
pub struct ColumnSpec {
    pub name: String,
    pub field_name: String,
    pub field: FieldSpec,
}

#[napi(object)]
#[derive(Debug, Clone)]
pub struct SkippingIndexSpec {
    pub name: String,
    pub expr: String,
    pub index_type: String,
    pub granularity: Option<u32>,
}

#[derive(Debug, Clone)]
pub struct EntitySpec {
    pub name: String,
    pub history_table: String,
    pub columns: Vec<ColumnSpec>,
    pub chain_id_column: Option<String>,
    pub partition_by: Option<String>,
    pub order_by: Option<Vec<String>>,
    pub ttl: Option<String>,
    pub skipping_indexes: Vec<SkippingIndexSpec>,
}

#[napi(object)]
#[derive(Debug, Clone)]
pub struct HistorySchema {
    pub id_column: String,
    pub checkpoint_id_column: String,
    pub change_column: String,
    pub change_variants: Vec<String>,
    pub set_variant: String,
    pub checkpoints_table: String,
    /// Columns of the checkpoints table a resume reads to decide which
    /// checkpoints each chain's recorded progress already covers.
    pub checkpoint_chain_id_column: String,
    pub checkpoint_block_number_column: String,
    /// One row per chain, mirroring the Postgres table of the same name: the
    /// highest checkpoint id the chain has landed, kept by a materialized view
    /// over the checkpoints table. The entity views read it as their commit
    /// marker.
    pub chains_table: String,
    pub chains_checkpoint_id_column: String,
}

/// The rows a resume has to remove: everything written past the checkpoint it
/// resumes from. One id every chain is held to under a shared sequence, one id
/// per chain when each chain counts its own — a chain's ids then say nothing
/// about another's, so one bound cannot stand for all of them.
#[derive(Debug, Clone)]
pub enum ResumeBounds {
    SharedAcrossChains(String),
    PerChain(Vec<(String, String)>),
}

impl ResumeBounds {
    /// One `(chain_id, checkpoint_id)` row per chain: a shared bound holds
    /// every chain to the same id.
    pub fn frontier_rows<'a>(
        &self,
        chain_ids: impl Iterator<Item = &'a str>,
    ) -> Vec<(String, String)> {
        match self {
            ResumeBounds::SharedAcrossChains(checkpoint_id) => chain_ids
                .map(|chain_id| (chain_id.to_string(), checkpoint_id.clone()))
                .collect(),
            ResumeBounds::PerChain(bounds) => bounds.clone(),
        }
    }

    /// The predicate matching the rows above the bound in a table whose chain
    /// column is `chain_column`. Per-chain bounds need that column: without it
    /// a row can't be attributed to the sequence its id came from.
    pub fn above(&self, chain_column: Option<&str>, checkpoint_column: &str) -> Result<String> {
        let checkpoint = quoted(checkpoint_column);
        match self {
            ResumeBounds::SharedAcrossChains(checkpoint_id) => {
                Ok(format!("{checkpoint} > {checkpoint_id}"))
            }
            ResumeBounds::PerChain(bounds) => {
                let Some(chain_column) = chain_column else {
                    bail!(
                        "Internal error: per-chain checkpoint bounds can't bound a table with no \
                         chain-id column. Only a schema whose entities are all per-chain has them."
                    )
                };
                let chain = quoted(chain_column);
                Ok(bounds
                    .iter()
                    .map(|(chain_id, checkpoint_id)| {
                        format!("({chain} = {chain_id} AND {checkpoint} > {checkpoint_id})")
                    })
                    .collect::<Vec<_>>()
                    .join(" OR "))
            }
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct Topology {
    pub replicated: bool,
    /// Whether table-level DDL carries its own `ON CLUSTER`. A `Replicated`
    /// database engine propagates DDL through its own log, and combining the two
    /// is rejected — so the clause is only for the plain-database case.
    pub ddl_on_cluster: bool,
}

impl Topology {
    fn engine(&self) -> &'static str {
        if self.replicated {
            "ReplicatedMergeTree"
        } else {
            "MergeTree()"
        }
    }

    fn replacing_engine(&self) -> &'static str {
        if self.replicated {
            "ReplicatedReplacingMergeTree"
        } else {
            "ReplacingMergeTree()"
        }
    }

    pub fn on_cluster(&self) -> &'static str {
        on_cluster_clause(self.ddl_on_cluster)
    }

    /// ReplicatedMergeTree drops an insert whose block hash is already in
    /// Keeper, and mutations don't clear those hashes. Crash recovery trims the
    /// history tail past the committed Postgres checkpoint and replays it, so an
    /// identical replayed block would be discarded while still reporting success
    /// — a permanent gap nothing surfaces. Trim-then-replay is what makes
    /// recovery correct here, and the duplicates dedup would have caught are
    /// already collapsed by the view's `LIMIT 1 BY`. Plain MergeTree goes by
    /// `non_replicated_deduplication_window` (0 by default), so it needs no
    /// clause.
    fn settings(&self) -> &'static str {
        if self.replicated {
            "\nSETTINGS replicated_deduplication_window = 0"
        } else {
            ""
        }
    }
}

/// A plain database created with ON CLUSTER doesn't turn subsequent DDL into
/// cluster-wide statements; ClickHouse keeps no "this database is clustered"
/// flag. Without a Replicated database engine, every CREATE must carry its own
/// ON CLUSTER to reach all replicas, otherwise it runs only on the connected
/// node. The '{cluster}' macro resolves to each node's configured cluster name.
pub fn on_cluster_clause(on_cluster: bool) -> &'static str {
    if on_cluster {
        " ON CLUSTER '{cluster}'"
    } else {
        ""
    }
}

pub fn database_engine_name(engine_spec: &str) -> &str {
    engine_spec
        .trim()
        .split('(')
        .next()
        .unwrap_or_default()
        .split(' ')
        .next()
        .unwrap_or_default()
        .trim()
}

impl HistorySchema {
    fn trailing_columns(&self) -> Vec<(String, ChType)> {
        vec![
            (self.checkpoint_id_column.clone(), ChType::UInt64),
            (
                self.change_column.clone(),
                ChType::Enum {
                    variants: self.change_variants.clone(),
                },
            ),
        ]
    }
}

impl ColumnSpec {
    pub fn typed(&self, chain_id_mode: ChainIdMode, context: &str) -> Result<(String, ChType)> {
        let ch_type = self
            .field
            .ch_type(chain_id_mode)
            .map_err(|error| error.context(format!("Column `{}` of {context}", self.name)))?;
        Ok((self.name.clone(), ch_type))
    }
}

impl EntitySpec {
    pub fn history_columns(
        &self,
        history: &HistorySchema,
        chain_id_mode: ChainIdMode,
    ) -> Result<Vec<(String, ChType)>> {
        let context = format!("entity `{}`", self.name);
        let mut columns = self
            .columns
            .iter()
            .map(|column| column.typed(chain_id_mode, &context))
            .collect::<Result<Vec<_>>>()?;
        columns.extend(history.trailing_columns());
        Ok(columns)
    }

    fn column_by_field_name(&self) -> HashMap<&str, &str> {
        self.columns
            .iter()
            .map(|column| (column.field_name.as_str(), column.name.as_str()))
            .collect()
    }

    /// Only the fields an expression cannot name as-is. A field whose column
    /// kept its name already reads as the column, and quoting it would also
    /// claim every other meaning the bare word has — a field named `day` would
    /// swallow the unit of `INTERVAL 30 day`.
    fn renamed_column_by_field_name(&self) -> HashMap<&str, &str> {
        self.columns
            .iter()
            .filter(|column| column.field_name != column.name)
            .map(|column| (column.field_name.as_str(), column.name.as_str()))
            .collect()
    }
}

static EXPRESSION_TOKEN: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`|"(?:[^"\\]|\\.)*"|[A-Za-z_][A-Za-z0-9_]*"#)
        .expect("expression token regex")
});

fn resolve_expression_columns(expression: &str, columns: &HashMap<&str, &str>) -> String {
    EXPRESSION_TOKEN
        .replace_all(expression, |captures: &Captures| {
            let token = &captures[0];
            match columns.get(token) {
                Some(column) => quoted(column),
                None => token.to_string(),
            }
        })
        .into_owned()
}

pub fn create_history_table(
    entity: &EntitySpec,
    database: &str,
    history: &HistorySchema,
    topology: Topology,
    chain_id_mode: ChainIdMode,
) -> Result<String> {
    let columns = entity.history_columns(history, chain_id_mode)?;
    let definitions: Vec<String> = columns
        .iter()
        .map(|(name, ch_type)| format!("{} {ch_type}", quoted(name)))
        .collect();

    let by_field_name = entity.column_by_field_name();

    let order_by = match &entity.order_by {
        Some(field_names) => {
            let mut resolved = Vec::with_capacity(field_names.len());
            for field_name in field_names {
                match by_field_name.get(field_name.as_str()) {
                    Some(column) => resolved.push(quoted(column)),
                    None => bail!(
                        "ClickHouse orderBy field \"{field_name}\" is not defined on entity \"{}\"",
                        entity.name
                    ),
                }
            }
            format!(
                "{}, {}",
                resolved.join(", "),
                quoted(&history.checkpoint_id_column)
            )
        }
        None => format!(
            "{}, {}",
            quoted(&history.id_column),
            quoted(&history.checkpoint_id_column)
        ),
    };

    let renamed = entity.renamed_column_by_field_name();
    let partition_by = match &entity.partition_by {
        Some(expression) => format!(
            "\nPARTITION BY {}",
            resolve_expression_columns(expression, &renamed)
        ),
        None => String::new(),
    };
    let ttl = match &entity.ttl {
        Some(expression) => format!("\nTTL {}", resolve_expression_columns(expression, &renamed)),
        None => String::new(),
    };

    let mut indexes = String::new();
    for index in &entity.skipping_indexes {
        let granularity = match index.granularity {
            Some(granularity) => format!(" GRANULARITY {granularity}"),
            None => String::new(),
        };
        write!(
            indexes,
            ",\n  INDEX {} {} TYPE {}{granularity}",
            quoted(&index.name),
            resolve_expression_columns(&index.expr, &renamed),
            index.index_type
        )
        .expect("writing to a String cannot fail");
    }

    Ok(format!(
        "CREATE TABLE IF NOT EXISTS {}.{}{} (\n  {}{indexes}\n)\nENGINE = {}{partition_by}\nORDER BY ({order_by}){ttl}{}",
        quoted(database),
        quoted(&entity.history_table),
        topology.on_cluster(),
        definitions.join(",\n  "),
        topology.engine(),
        topology.settings(),
    ))
}

pub fn create_checkpoints_table(
    columns: &[(String, ChType)],
    database: &str,
    history: &HistorySchema,
    topology: Topology,
) -> String {
    let definitions: Vec<String> = columns
        .iter()
        .map(|(name, ch_type)| format!("  {} {ch_type}", quoted(name)))
        .collect();
    // The chain leads the key: nothing reads the table without naming a chain
    // — the entity views take their marker from the frontier table — and the
    // per-chain resume trims a chain's rows as one range.
    format!(
        "CREATE TABLE IF NOT EXISTS {}.{}{} (\n{}\n)\nENGINE = {}\nORDER BY ({}, {}){}",
        quoted(database),
        quoted(&history.checkpoints_table),
        topology.on_cluster(),
        definitions.join(",\n"),
        topology.engine(),
        quoted(&history.checkpoint_chain_id_column),
        quoted(&history.id_column),
        topology.settings(),
    )
}

/// One row per chain, replaced on every write: a batch's checkpoints raise its
/// checkpoint id through the materialized view, a resume lowers it by inserting
/// the id it trims back to. The row a chain settles on is the last one written,
/// so the table has no version column and is read with FINAL — which also means
/// every writer has to write the whole row once it grows past this column.
///
/// The dedup window is off for the same reason as on the other tables: a chain
/// lowered by a resume and later raised to an id it once held would insert a
/// block identical to one already seen, and a dropped insert would leave the
/// chain's rows unreadable.
pub fn create_chains_table(
    chain_id_type: &ChType,
    database: &str,
    history: &HistorySchema,
    topology: Topology,
) -> String {
    format!(
        "CREATE TABLE IF NOT EXISTS {}.{}{} (\n  {} {chain_id_type},\n  {} UInt64\n)\nENGINE = {}\nORDER BY ({}){}",
        quoted(database),
        quoted(&history.chains_table),
        topology.on_cluster(),
        quoted(&history.checkpoint_chain_id_column),
        quoted(&history.chains_checkpoint_id_column),
        topology.replacing_engine(),
        quoted(&history.checkpoint_chain_id_column),
        topology.settings(),
    )
}

/// Feeds the chains table from every checkpoint insert. It runs as part of that
/// insert, after the entity rows the checkpoints cover, so a chain's marker can
/// never get ahead of the rows it makes readable.
pub fn create_chains_materialized_view(
    database: &str,
    history: &HistorySchema,
    topology: Topology,
) -> String {
    format!(
        "CREATE MATERIALIZED VIEW IF NOT EXISTS {db}.{}{} TO {db}.{} AS\nSELECT {chain}, max({id}) AS {checkpoint_id}\nFROM {db}.{}\nGROUP BY {chain}",
        quoted(&chains_view_name(history)),
        topology.on_cluster(),
        quoted(&history.chains_table),
        quoted(&history.checkpoints_table),
        db = quoted(database),
        chain = quoted(&history.checkpoint_chain_id_column),
        id = quoted(&history.id_column),
        checkpoint_id = quoted(&history.chains_checkpoint_id_column),
    )
}

fn chains_view_name(history: &HistorySchema) -> String {
    format!("{}_mv", history.chains_table)
}

/// Sets each chain's frontier to the id a resume trims it back to. Inserted
/// before the trims so nothing above the id is readable while they run.
pub fn set_chains_frontier(
    database: &str,
    history: &HistorySchema,
    rows: &[(String, String)],
) -> String {
    let values: Vec<String> = rows
        .iter()
        .map(|(chain_id, checkpoint_id)| format!("({chain_id}, {checkpoint_id})"))
        .collect();
    format!(
        "INSERT INTO {}.{} ({}, {}) VALUES {}",
        quoted(database),
        quoted(&history.chains_table),
        quoted(&history.checkpoint_chain_id_column),
        quoted(&history.chains_checkpoint_id_column),
        values.join(", "),
    )
}

/// The rows an entity view reads as current: the latest at or below its
/// chain's frontier, which the checkpoint insert raises only after the entity
/// rows it covers have landed. A per-chain entity's row compares against its
/// own chain's id — a sibling's id says nothing about it, and under a per-chain
/// sequence isn't even comparable. A cross-chain entity's rows belong to no one
/// chain; they only exist under one shared sequence, where the highest id is
/// the frontier of the whole run.
///
/// The frontier is read once per query as a scalar and looked up per row, which
/// costs one comparison and leaves the predicate free to run as PREWHERE. A
/// chain the frontier doesn't name reads as 0, so its rows stay hidden.
pub fn create_view(
    entity: &EntitySpec,
    database: &str,
    history: &HistorySchema,
    topology: Topology,
) -> String {
    let mut dedup_key = vec![quoted(&history.id_column)];
    if let Some(chain_id_column) = &entity.chain_id_column {
        dedup_key.push(quoted(chain_id_column));
    }

    let entity_fields: Vec<String> = entity
        .columns
        .iter()
        .map(|column| quoted(&column.name))
        .collect();
    let entity_fields = entity_fields.join(", ");

    let chains = format!(
        "{}.{} FINAL",
        quoted(database),
        quoted(&history.chains_table)
    );
    let checkpoint_id = quoted(&history.chains_checkpoint_id_column);
    let (with, marker) = match &entity.chain_id_column {
        Some(chain_id_column) => (
            format!(
                "WITH (SELECT mapFromArrays(groupArray({chain}), groupArray({checkpoint_id})) FROM {chains}) AS envio_frontier\n",
                chain = quoted(&history.checkpoint_chain_id_column),
            ),
            format!("envio_frontier[{}]", quoted(chain_id_column)),
        ),
        None => (
            String::new(),
            format!("(SELECT max({checkpoint_id}) FROM {chains})"),
        ),
    };

    // The dedup key leads the sort so the rows a `LIMIT 1 BY` group needs
    // arrive together: the history table is sorted by that key already (or by a
    // prefix of it, under a custom `orderBy`), so ClickHouse reads in order and
    // a `LIMIT n` over the view stops after n groups instead of sorting every
    // version in the table first. Sorting by the checkpoint alone forced that
    // full sort on every read. The checkpoint stays last and descending, which
    // is what makes the surviving row per key the latest one.
    let dedup_sort = format!(
        "{}, {} DESC",
        dedup_key.join(", "),
        quoted(&history.checkpoint_id_column)
    );

    format!(
        "CREATE VIEW IF NOT EXISTS {db}.{}{} AS\n{with}SELECT {entity_fields}\nFROM (\n  SELECT {entity_fields}, {}\n  FROM {db}.{}\n  WHERE {} <= {marker}\n  ORDER BY {dedup_sort}\n  LIMIT 1 BY {}\n)\nWHERE {} = {}",
        quoted(&entity.name),
        topology.on_cluster(),
        quoted(&history.change_column),
        quoted(&entity.history_table),
        quoted(&history.checkpoint_id_column),
        dedup_key.join(", "),
        quoted(&history.change_column),
        literal(&history.set_variant),
        db = quoted(database),
    )
}

pub fn insert_query(
    database: &str,
    table: &str,
    columns: impl Iterator<Item = impl AsRef<str>>,
) -> String {
    let names: Vec<String> = columns.map(|name| quoted(name.as_ref())).collect();
    format!(
        "INSERT INTO {}.{} ({}) FORMAT RowBinary",
        quoted(database),
        quoted(table),
        names.join(", ")
    )
}

/// One read that answers, for every table a resume could trim, whether any
/// row sits above the checkpoint it trims to. A table answering no needs no
/// mutation, and on a clean restart every one of them does — which is what
/// keeps a resume from scheduling a part rewrite per entity for nothing.
///
/// `count()` over a `LIMIT 1` subquery stops at the first matching row where a
/// bare `count()` would scan the whole column: `envio_checkpoint_id` trails the
/// sorting key, so the primary index prunes nothing. The aliases live outside
/// the table's own scope and carry a prefix no entity field can, since `exists`
/// loses its alias under the old analyzer and a user may have named a column
/// `name`.
pub fn holds_rows_above_checkpoint(database: &str, above_by_table: &[(String, String)]) -> String {
    let branches: Vec<String> = above_by_table
        .iter()
        .map(|(table, above)| {
            format!(
                "SELECT {} AS `_envio_table`, count() AS `_envio_holds` FROM (SELECT 1 FROM {}.{} \
                 WHERE {above} LIMIT 1)",
                literal(table),
                quoted(database),
                quoted(table),
            )
        })
        .collect();
    format!(
        "SELECT `_envio_table`, `_envio_holds` FROM ({}) FORMAT TabSeparated",
        branches.join(" UNION ALL ")
    )
}

/// Trims one history table's rows past the checkpoint being resumed from.
///
/// `ALTER ... DELETE` schedules a mutation rather than running one, so without
/// `mutations_sync` the statement returns while the rows are still there and
/// resume would report a rewind it has only asked for. Waiting for this node
/// (`1`) is what makes the storage actually be at the checkpoint by the time
/// the indexer starts writing again; the indexer reads and writes this node
/// alone, and the replicas behind it catch up on their own.
pub fn trim_history_table(database: &str, table: &str, above: &str) -> String {
    format!(
        "ALTER TABLE {}.{} DELETE WHERE {above} SETTINGS mutations_sync = 1",
        quoted(database),
        quoted(table),
    )
}

/// Trims the checkpoints past the one being resumed from.
///
/// `DELETE FROM` is a lightweight delete, which `mutations_sync` has no say
/// over — `lightweight_deletes_sync` is the setting that makes the statement
/// wait for the rows to actually be masked. Named explicitly rather than left to
/// the server default, which a profile is free to set to 0: resume would then
/// return with checkpoints still above the frontier, and replayed rows would
/// become readable through a checkpoint that no longer covers them.
pub fn trim_checkpoints(database: &str, history: &HistorySchema, above: &str) -> String {
    format!(
        "DELETE FROM {}.{} WHERE {above} SETTINGS lightweight_deletes_sync = 1",
        quoted(database),
        quoted(&history.checkpoints_table),
    )
}

#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use crate::clickhouse::ch_type::test_support::field;

    pub fn history_schema() -> HistorySchema {
        HistorySchema {
            id_column: "id".to_string(),
            checkpoint_id_column: "envio_checkpoint_id".to_string(),
            change_column: "envio_change".to_string(),
            change_variants: vec!["SET".to_string(), "DELETE".to_string()],
            set_variant: "SET".to_string(),
            checkpoints_table: "envio_checkpoints".to_string(),
            checkpoint_chain_id_column: "chain_id".to_string(),
            checkpoint_block_number_column: "block_number".to_string(),
            chains_table: "envio_chains".to_string(),
            chains_checkpoint_id_column: "checkpoint_id".to_string(),
        }
    }

    pub fn plain() -> Topology {
        Topology {
            replicated: false,
            ddl_on_cluster: false,
        }
    }

    pub fn replicated() -> Topology {
        Topology {
            replicated: true,
            ddl_on_cluster: true,
        }
    }

    pub fn column(name: &str, field_type: &str) -> ColumnSpec {
        ColumnSpec {
            name: name.to_string(),
            field_name: name.to_string(),
            field: field(field_type),
        }
    }

    pub fn entity(name: &str, columns: Vec<ColumnSpec>) -> EntitySpec {
        EntitySpec {
            name: name.to_string(),
            history_table: format!("envio_history_{name}"),
            columns,
            chain_id_column: None,
            partition_by: None,
            order_by: None,
            ttl: None,
            skipping_indexes: Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::*;
    use super::*;
    use crate::clickhouse::ch_type::test_support::field;
    use pretty_assertions::assert_eq;

    fn typed(columns: &[ColumnSpec]) -> Vec<(String, ChType)> {
        columns
            .iter()
            .map(|column| {
                column
                    .typed(ChainIdMode::Int32, "the checkpoints table")
                    .unwrap()
            })
            .collect()
    }

    fn render(entity: &EntitySpec, topology: Topology) -> String {
        create_history_table(
            entity,
            "test_db",
            &history_schema(),
            topology,
            ChainIdMode::Int32,
        )
        .unwrap()
    }

    #[test]
    fn creates_a_history_table_with_the_checkpoint_and_change_columns_appended() {
        let entity = entity(
            "Account",
            vec![column("id", "String"), column("balance", "Int32")],
        );
        assert_eq!(
            render(&entity, plain()),
            "CREATE TABLE IF NOT EXISTS `test_db`.`envio_history_Account` (\n  \
             `id` String,\n  \
             `balance` Int32,\n  \
             `envio_checkpoint_id` UInt64,\n  \
             `envio_change` Enum8('SET' = 1, 'DELETE' = 2)\n\
             )\n\
             ENGINE = MergeTree()\n\
             ORDER BY (`id`, `envio_checkpoint_id`)"
        );
    }

    #[test]
    fn a_replicated_table_carries_the_engine_cluster_and_dedup_settings() {
        let entity = entity("Account", vec![column("id", "String")]);
        assert_eq!(
            render(&entity, replicated()),
            "CREATE TABLE IF NOT EXISTS `test_db`.`envio_history_Account` ON CLUSTER '{cluster}' (\n  \
             `id` String,\n  \
             `envio_checkpoint_id` UInt64,\n  \
             `envio_change` Enum8('SET' = 1, 'DELETE' = 2)\n\
             )\n\
             ENGINE = ReplicatedMergeTree\n\
             ORDER BY (`id`, `envio_checkpoint_id`)\n\
             SETTINGS replicated_deduplication_window = 0"
        );
    }

    #[test]
    fn table_options_resolve_field_names_to_columns() {
        let mut entity = entity(
            "Account",
            vec![
                column("id", "String"),
                ColumnSpec {
                    name: "created_at".to_string(),
                    field_name: "createdAt".to_string(),
                    field: field("Date"),
                },
            ],
        );
        entity.order_by = Some(vec!["createdAt".to_string()]);
        entity.partition_by = Some("toYYYYMM(createdAt)".to_string());
        entity.ttl = Some("createdAt + INTERVAL 1 MONTH".to_string());
        entity.skipping_indexes = vec![SkippingIndexSpec {
            name: "idx_created".to_string(),
            expr: "createdAt".to_string(),
            index_type: "minmax".to_string(),
            granularity: Some(4),
        }];
        assert_eq!(
            render(&entity, plain()),
            "CREATE TABLE IF NOT EXISTS `test_db`.`envio_history_Account` (\n  \
             `id` String,\n  \
             `created_at` DateTime64(3, 'UTC'),\n  \
             `envio_checkpoint_id` UInt64,\n  \
             `envio_change` Enum8('SET' = 1, 'DELETE' = 2),\n  \
             INDEX `idx_created` `created_at` TYPE minmax GRANULARITY 4\n\
             )\n\
             ENGINE = MergeTree()\n\
             PARTITION BY toYYYYMM(`created_at`)\n\
             ORDER BY (`created_at`, `envio_checkpoint_id`)\n\
             TTL `created_at` + INTERVAL 1 MONTH"
        );
    }

    #[test]
    fn expression_rewriting_leaves_everything_that_is_not_a_field_alone() {
        let columns = HashMap::from([("createdAt", "created_at")]);
        let resolved = [
            "toYYYYMM(createdAt)",
            "kind = 'createdAt'",
            "`createdAt` + 1",
            "toStartOfDay(createdAt) + INTERVAL 7 DAY",
            "toYYYYMM(\"created_at\")",
            "kind = 'a' || \"createdAt\"",
            // ClickHouse reads C-style escapes inside a literal, so a \' does
            // not end one and nothing inside is a bare identifier.
            r"kind = 'a\'createdAt b'",
        ]
        .map(|expression| resolve_expression_columns(expression, &columns));
        assert_eq!(
            resolved,
            [
                "toYYYYMM(`created_at`)",
                "kind = 'createdAt'",
                "`createdAt` + 1",
                "toStartOfDay(`created_at`) + INTERVAL 7 DAY",
                "toYYYYMM(\"created_at\")",
                "kind = 'a' || \"createdAt\"",
                r"kind = 'a\'createdAt b'",
            ]
        );
    }

    // A field whose column keeps its name already reads as that column in the
    // expression, so rewriting it buys nothing — and quoting it turns every
    // other meaning the bare word has into the column: a field named `day`
    // would swallow the unit of `INTERVAL 30 day`.
    #[test]
    fn a_field_whose_column_keeps_its_name_is_not_rewritten() {
        let mut entity = entity(
            "Visit",
            vec![
                column("id", "String"),
                column("day", "Int32"),
                ColumnSpec {
                    name: "created_at".to_string(),
                    field_name: "createdAt".to_string(),
                    field: field("Date"),
                },
            ],
        );
        entity.ttl = Some("createdAt + INTERVAL 30 day".to_string());
        entity.partition_by = Some("day".to_string());
        assert_eq!(
            render(&entity, plain()),
            "CREATE TABLE IF NOT EXISTS `test_db`.`envio_history_Visit` (\n  \
             `id` String,\n  \
             `day` Int32,\n  \
             `created_at` DateTime64(3, 'UTC'),\n  \
             `envio_checkpoint_id` UInt64,\n  \
             `envio_change` Enum8('SET' = 1, 'DELETE' = 2)\n\
             )\n\
             ENGINE = MergeTree()\n\
             PARTITION BY day\n\
             ORDER BY (`id`, `envio_checkpoint_id`)\n\
             TTL `created_at` + INTERVAL 30 day"
        );
    }

    #[test]
    fn rejects_an_order_by_field_the_entity_does_not_have() {
        let mut entity = entity("Account", vec![column("id", "String")]);
        entity.order_by = Some(vec!["missing".to_string()]);
        assert_eq!(
            create_history_table(
                &entity,
                "test_db",
                &history_schema(),
                plain(),
                ChainIdMode::Int32
            )
            .unwrap_err()
            .to_string(),
            "ClickHouse orderBy field \"missing\" is not defined on entity \"Account\""
        );
    }

    #[test]
    fn creates_the_checkpoints_table() {
        let columns = [
            column("chain_id", "ChainId"),
            column("id", "UInt64"),
            column("block_number", "Int32"),
            ColumnSpec {
                field: FieldSpec {
                    is_nullable: true,
                    ..field("String")
                },
                ..column("block_hash", "String")
            },
        ];
        assert_eq!(
            create_checkpoints_table(&typed(&columns), "test_db", &history_schema(), plain()),
            "CREATE TABLE IF NOT EXISTS `test_db`.`envio_checkpoints` (\n  \
             `chain_id` Int32,\n  \
             `id` UInt64,\n  \
             `block_number` Int32,\n  \
             `block_hash` Nullable(String)\n\
             )\n\
             ENGINE = MergeTree()\n\
             ORDER BY (`chain_id`, `id`)"
        );
    }

    #[test]
    fn creates_the_chains_table_and_the_view_that_feeds_it() {
        assert_eq!(
            (
                create_chains_table(&ChType::Int32, "test_db", &history_schema(), plain()),
                create_chains_materialized_view("test_db", &history_schema(), plain()),
            ),
            (
                "CREATE TABLE IF NOT EXISTS `test_db`.`envio_chains` (\n  \
                 `chain_id` Int32,\n  \
                 `checkpoint_id` UInt64\n\
                 )\n\
                 ENGINE = ReplacingMergeTree()\n\
                 ORDER BY (`chain_id`)"
                    .to_string(),
                "CREATE MATERIALIZED VIEW IF NOT EXISTS `test_db`.`envio_chains_mv` TO \
                 `test_db`.`envio_chains` AS\n\
                 SELECT `chain_id`, max(`id`) AS `checkpoint_id`\n\
                 FROM `test_db`.`envio_checkpoints`\n\
                 GROUP BY `chain_id`"
                    .to_string(),
            )
        );
    }

    #[test]
    fn a_replicated_chains_table_carries_the_engine_cluster_and_dedup_settings() {
        assert_eq!(
            create_chains_table(&ChType::Int64, "test_db", &history_schema(), replicated()),
            "CREATE TABLE IF NOT EXISTS `test_db`.`envio_chains` ON CLUSTER '{cluster}' (\n  \
             `chain_id` Int64,\n  \
             `checkpoint_id` UInt64\n\
             )\n\
             ENGINE = ReplicatedReplacingMergeTree\n\
             ORDER BY (`chain_id`)\n\
             SETTINGS replicated_deduplication_window = 0"
        );
    }

    #[test]
    fn sets_every_chains_frontier_in_one_insert() {
        assert_eq!(
            set_chains_frontier(
                "test_db",
                &history_schema(),
                &[
                    ("1".to_string(), "5".to_string()),
                    ("137".to_string(), "9".to_string())
                ]
            ),
            "INSERT INTO `test_db`.`envio_chains` (`chain_id`, `checkpoint_id`) VALUES (1, 5), (137, 9)"
        );
    }

    #[test]
    fn a_replicated_checkpoints_table_carries_the_engine_cluster_and_dedup_settings() {
        let columns = [column("id", "UInt64")];
        assert_eq!(
            create_checkpoints_table(&typed(&columns), "test_db", &history_schema(), replicated()),
            "CREATE TABLE IF NOT EXISTS `test_db`.`envio_checkpoints` ON CLUSTER '{cluster}' (\n  \
             `id` UInt64\n\
             )\n\
             ENGINE = ReplicatedMergeTree\n\
             ORDER BY (`chain_id`, `id`)\n\
             SETTINGS replicated_deduplication_window = 0"
        );
    }

    #[test]
    fn creates_a_view_over_the_history_table() {
        let entity = entity(
            "Account",
            vec![column("id", "String"), column("balance", "Int32")],
        );
        assert_eq!(
            create_view(&entity, "test_db", &history_schema(), plain()),
            "CREATE VIEW IF NOT EXISTS `test_db`.`Account` AS\n\
             SELECT `id`, `balance`\n\
             FROM (\n  \
             SELECT `id`, `balance`, `envio_change`\n  \
             FROM `test_db`.`envio_history_Account`\n  \
             WHERE `envio_checkpoint_id` <= (SELECT max(`checkpoint_id`) FROM `test_db`.`envio_chains` FINAL)\n  \
             ORDER BY `id`, `envio_checkpoint_id` DESC\n  \
             LIMIT 1 BY `id`\n\
             )\n\
             WHERE `envio_change` = 'SET'"
        );
    }

    // A sibling's id says nothing about this chain's rows, so each row is held
    // to its own chain's frontier — read once as a scalar, looked up per row.
    #[test]
    fn a_per_chain_entity_view_holds_each_row_to_its_own_chains_frontier() {
        let entity = EntitySpec {
            chain_id_column: Some("chainId".to_string()),
            ..entity(
                "Account",
                vec![
                    column("id", "String"),
                    column("chainId", "ChainId"),
                    column("balance", "Int32"),
                ],
            )
        };
        assert_eq!(
            create_view(&entity, "test_db", &history_schema(), plain()),
            "CREATE VIEW IF NOT EXISTS `test_db`.`Account` AS\n\
             WITH (SELECT mapFromArrays(groupArray(`chain_id`), groupArray(`checkpoint_id`)) FROM \
             `test_db`.`envio_chains` FINAL) AS envio_frontier\n\
             SELECT `id`, `chainId`, `balance`\n\
             FROM (\n  \
             SELECT `id`, `chainId`, `balance`, `envio_change`\n  \
             FROM `test_db`.`envio_history_Account`\n  \
             WHERE `envio_checkpoint_id` <= envio_frontier[`chainId`]\n  \
             ORDER BY `id`, `chainId`, `envio_checkpoint_id` DESC\n  \
             LIMIT 1 BY `id`, `chainId`\n\
             )\n\
             WHERE `envio_change` = 'SET'"
        );
    }

    #[test]
    fn a_replicated_view_is_created_on_the_cluster() {
        let entity = entity("Account", vec![column("id", "String")]);
        assert_eq!(
            create_view(&entity, "test_db", &history_schema(), replicated())
                .lines()
                .next(),
            Some("CREATE VIEW IF NOT EXISTS `test_db`.`Account` ON CLUSTER '{cluster}' AS")
        );
    }

    #[test]
    fn a_per_chain_entity_dedups_on_id_and_chain() {
        let mut entity = entity(
            "Account",
            vec![column("id", "String"), column("chain_id", "ChainId")],
        );
        entity.chain_id_column = Some("chain_id".to_string());
        let sql = create_view(&entity, "test_db", &history_schema(), plain());
        assert!(sql.contains("ORDER BY `id`, `chain_id`, `envio_checkpoint_id` DESC"));
        assert!(sql.contains("LIMIT 1 BY `id`, `chain_id`"));
    }

    #[test]
    fn strips_arguments_and_settings_from_a_database_engine() {
        let names = [
            "Replicated('/p','{shard}','{replica}') SETTINGS x=1",
            "Replicated SETTINGS x=1",
            "  Atomic  ",
        ]
        .map(database_engine_name);
        assert_eq!(names, ["Replicated", "Replicated", "Atomic"]);
    }

    #[test]
    fn names_every_column_the_insert_sends_and_escapes_them() {
        assert_eq!(
            insert_query(
                "db",
                "envio_history_Account",
                ["id", "bal`ance", r"back\slash"].iter()
            ),
            concat!(
                "INSERT INTO `db`.`envio_history_Account` ",
                r"(`id`, `bal``ance`, `back\\slash`) FORMAT RowBinary"
            )
        );
    }

    #[test]
    fn trims_history_and_checkpoints_past_a_checkpoint() {
        let history = history_schema();
        let bounds = ResumeBounds::SharedAcrossChains("42".to_string());
        let above = |column: &str| bounds.above(None, column).unwrap();
        assert_eq!(
            (
                trim_history_table(
                    "db",
                    "envio_history_Account",
                    &above(&history.checkpoint_id_column)
                ),
                trim_checkpoints("db", &history, &above(&history.id_column))
            ),
            (
                "ALTER TABLE `db`.`envio_history_Account` DELETE WHERE \
                 `envio_checkpoint_id` > 42 SETTINGS mutations_sync = 1"
                    .to_string(),
                "DELETE FROM `db`.`envio_checkpoints` WHERE `id` > 42 \
                 SETTINGS lightweight_deletes_sync = 1"
                    .to_string()
            )
        );
    }
}
