//! Every statement that shapes the ClickHouse database, and the ones a resume
//! trims it back with.

use std::collections::HashMap;
use std::fmt::Write as _;
use std::sync::LazyLock;

use anyhow::{bail, Result};
use napi_derive::napi;
use regex::{Captures, Regex};

use super::ch_type::{ChType, FieldSpec};
use super::{literal, quoted};
use crate::config_parsing::system_config::ChainIdMode;
use crate::storage::types::{
    ADDRESSES_TABLE, CHAINS_TABLE, CHANGE_COLUMN, CHECKPOINTS_TABLE, CHECKPOINT_ID_COLUMN,
    CONTRACTS_TABLE, DELETE, INFO_TABLE, SET,
};

pub const ID_COLUMN: &str = "id";
pub const CHAIN_ID_COLUMN: &str = "chain_id";
pub const BLOCK_NUMBER_COLUMN: &str = "block_number";
/// On a checkpoints row a rollback wrote, the checkpoint it rolled its chain
/// back to — which can be 0, nothing at all — and NULL on every other row.
/// Between them a marker's own id and its target bound the checkpoints the
/// rollback orphaned, which stay in the table: the store never deletes, so what
/// the rollback took away is read off the markers.
pub const ROLLBACK_TARGET_COLUMN: &str = "rollback_target";
/// What a chains row is ordered by among the rows written for the same chain.
/// The latest one written is the chain's state.
pub const VERSION_COLUMN: &str = "version";
pub const FRONTIER_COLUMN: &str = "checkpoint_id";

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

    fn replacing_engine(&self, version: Option<&str>) -> String {
        let version = version.map(quoted).unwrap_or_default();
        if self.replicated {
            if version.is_empty() {
                "ReplicatedReplacingMergeTree".to_string()
            } else {
                format!("ReplicatedReplacingMergeTree({version})")
            }
        } else {
            format!("ReplacingMergeTree({version})")
        }
    }

    pub fn on_cluster(&self) -> &'static str {
        on_cluster_clause(self.ddl_on_cluster)
    }

    /// ReplicatedMergeTree drops an insert whose block hash is already in
    /// Keeper, and mutations don't clear those hashes. Crash recovery trims the
    /// history tail past the committed checkpoint and replays it, so an
    /// identical replayed block would be discarded while still reporting success
    /// — a permanent gap nothing surfaces. Trim-then-replay is what makes
    /// recovery correct here, and the duplicates dedup would have caught are
    /// already collapsed by every read's `LIMIT 1 BY`. Plain MergeTree goes by
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

pub fn change_type() -> ChType {
    ChType::Enum {
        variants: vec![SET.to_string(), DELETE.to_string()],
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
    /// The entity's own columns, typed.
    pub fn entity_columns(&self, chain_id_mode: ChainIdMode) -> Result<Vec<(String, ChType)>> {
        let context = format!("entity `{}`", self.name);
        self.columns
            .iter()
            .map(|column| column.typed(chain_id_mode, &context))
            .collect()
    }

    /// What a history row carries: the entity's columns, then the checkpoint
    /// it was written at and whether it set or deleted the entity.
    pub fn history_columns(&self, chain_id_mode: ChainIdMode) -> Result<Vec<(String, ChType)>> {
        let mut columns = self.entity_columns(chain_id_mode)?;
        columns.push((CHECKPOINT_ID_COLUMN.to_string(), ChType::UInt64));
        columns.push((CHANGE_COLUMN.to_string(), change_type()));
        Ok(columns)
    }

    /// The columns naming one entity: its id, and the chain a per-chain one
    /// belongs to.
    pub fn key(&self) -> Vec<String> {
        let mut key = vec![ID_COLUMN.to_string()];
        if let Some(chain_id_column) = &self.chain_id_column {
            key.push(chain_id_column.clone());
        }
        key
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

fn definitions(columns: &[(String, ChType)]) -> String {
    columns
        .iter()
        .map(|(name, ch_type)| format!("{} {ch_type}", quoted(name)))
        .collect::<Vec<_>>()
        .join(",\n  ")
}

fn table_ref(database: &str, table: &str) -> String {
    format!("{}.{}", quoted(database), quoted(table))
}

pub fn create_history_table(
    entity: &EntitySpec,
    database: &str,
    topology: Topology,
    chain_id_mode: ChainIdMode,
) -> Result<String> {
    let columns = entity.history_columns(chain_id_mode)?;
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
            format!("{}, {}", resolved.join(", "), quoted(CHECKPOINT_ID_COLUMN))
        }
        None => format!("{}, {}", quoted(ID_COLUMN), quoted(CHECKPOINT_ID_COLUMN)),
    };

    let renamed = entity.renamed_column_by_field_name();
    let partition_by = match &entity.partition_by {
        Some(expression) => format!(
            "\nPARTITION BY {}",
            resolve_expression_columns(expression, &renamed)
        ),
        None => String::new(),
    };
    // A delete leaves every column but its key at the type's default, which the
    // expression would read as long expired: kept, it outlives the sets it
    // cancels rather than going first and bringing the entity back.
    let ttl = match &entity.ttl {
        Some(expression) => format!(
            "\nTTL {} WHERE {} = '{SET}'",
            resolve_expression_columns(expression, &renamed),
            quoted(CHANGE_COLUMN)
        ),
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
        "CREATE TABLE IF NOT EXISTS {}{} (\n  {}{indexes}\n)\nENGINE = {}{partition_by}\nORDER BY ({order_by}){ttl}{}",
        table_ref(database, &entity.history_table),
        topology.on_cluster(),
        definitions(&columns),
        topology.engine(),
        topology.settings(),
    ))
}

pub fn checkpoint_columns(chain_id_type: &ChType) -> Vec<(String, ChType)> {
    vec![
        (CHAIN_ID_COLUMN.to_string(), chain_id_type.clone()),
        (ID_COLUMN.to_string(), ChType::UInt64),
        (BLOCK_NUMBER_COLUMN.to_string(), ChType::Int32),
        (
            "block_hash".to_string(),
            ChType::Nullable(Box::new(ChType::String)),
        ),
        // A count of every event a chain has processed outgrows an Int32 where
        // Postgres keeps one, and ClickHouse has the id's width to spare.
        ("events_processed".to_string(), ChType::UInt64),
        (
            ROLLBACK_TARGET_COLUMN.to_string(),
            ChType::Nullable(Box::new(ChType::UInt64)),
        ),
    ]
}

/// Every checkpoint a write made, which is what maps a history row's checkpoint
/// back to the block it came from.
///
/// The chain leads the key: every read of the table names one, and a resume
/// trims a chain's rows as one range. Within a chain ids grow with the block, so
/// a block range is narrowed by the min-max index rather than read in full.
pub fn create_checkpoints_table(
    chain_id_type: &ChType,
    database: &str,
    topology: Topology,
) -> String {
    format!(
        "CREATE TABLE IF NOT EXISTS {}{} (\n  {},\n  INDEX `block_number_minmax` {} TYPE minmax GRANULARITY 1\n)\nENGINE = {}\nORDER BY ({}, {}){}",
        table_ref(database, CHECKPOINTS_TABLE),
        topology.on_cluster(),
        definitions(&checkpoint_columns(chain_id_type)),
        quoted(BLOCK_NUMBER_COLUMN),
        topology.engine(),
        quoted(CHAIN_ID_COLUMN),
        quoted(ID_COLUMN),
        topology.settings(),
    )
}

pub fn chain_columns(chain_id_type: &ChType) -> Vec<(String, ChType)> {
    let nullable = |ch_type: ChType| ChType::Nullable(Box::new(ch_type));
    vec![
        (CHAIN_ID_COLUMN.to_string(), chain_id_type.clone()),
        (FRONTIER_COLUMN.to_string(), ChType::UInt64),
        (VERSION_COLUMN.to_string(), ChType::UInt64),
        ("ecosystem".to_string(), ChType::String),
        ("start_block".to_string(), ChType::Int32),
        ("end_block".to_string(), nullable(ChType::Int32)),
        ("max_reorg_depth".to_string(), ChType::Int32),
        ("buffer_block".to_string(), ChType::Int32),
        ("source_block".to_string(), ChType::Int32),
        ("first_event_block".to_string(), nullable(ChType::Int32)),
        ("ready_at".to_string(), nullable(ChType::DateTime64)),
        ("events_processed".to_string(), ChType::UInt64),
        ("_is_hyper_sync".to_string(), ChType::Bool),
        ("progress_block".to_string(), ChType::Int32),
        (
            "progress_block_time".to_string(),
            nullable(ChType::DateTime64),
        ),
    ]
}

/// One row per chain, written whole every time anything about the chain
/// changes. A write's last insert is its chains' rows, which is what commits
/// it: `checkpoint_id` is the chain's frontier, and nothing a write stamped
/// past it is readable until the row carrying it lands. The latest version of
/// a chain's row is its state, so the table is read with FINAL.
///
/// The dedup window is off for the same reason as on the other tables: a row
/// identical to one already written would otherwise be dropped while the insert
/// reports success.
pub fn create_chains_table(chain_id_type: &ChType, database: &str, topology: Topology) -> String {
    format!(
        "CREATE TABLE IF NOT EXISTS {}{} (\n  {}\n)\nENGINE = {}\nORDER BY ({}){}",
        table_ref(database, CHAINS_TABLE),
        topology.on_cluster(),
        definitions(&chain_columns(chain_id_type)),
        topology.replacing_engine(Some(VERSION_COLUMN)),
        quoted(CHAIN_ID_COLUMN),
        topology.settings(),
    )
}

pub fn info_columns() -> Vec<(String, ChType)> {
    vec![
        (ID_COLUMN.to_string(), ChType::Int32),
        ("config".to_string(), ChType::String),
    ]
}

/// A singleton holding the config the schema was created from, which a resume
/// is checked against. Text rather than JSON so it reads back byte for byte.
pub fn create_info_table(database: &str, topology: Topology) -> String {
    format!(
        "CREATE TABLE IF NOT EXISTS {}{} (\n  {}\n)\nENGINE = {}\nORDER BY ({}){}",
        table_ref(database, INFO_TABLE),
        topology.on_cluster(),
        definitions(&info_columns()),
        topology.engine(),
        quoted(ID_COLUMN),
        topology.settings(),
    )
}

pub fn contract_columns() -> Vec<(String, ChType)> {
    vec![
        (ID_COLUMN.to_string(), ChType::Int32),
        ("name".to_string(), ChType::String),
    ]
}

/// The canonical contract ids: a name's position in the list written at
/// initialize, so an id names the same contract on every chain and across
/// restarts.
pub fn create_contracts_table(database: &str, topology: Topology) -> String {
    format!(
        "CREATE TABLE IF NOT EXISTS {}{} (\n  {}\n)\nENGINE = {}\nORDER BY ({}){}",
        table_ref(database, CONTRACTS_TABLE),
        topology.on_cluster(),
        definitions(&contract_columns()),
        topology.engine(),
        quoted(ID_COLUMN),
        topology.settings(),
    )
}

pub fn address_columns(chain_id_type: &ChType) -> Vec<(String, ChType)> {
    vec![
        (CHAIN_ID_COLUMN.to_string(), chain_id_type.clone()),
        ("address".to_string(), ChType::Bytes),
        ("contract_id".to_string(), ChType::Int32),
        ("registration_block".to_string(), ChType::Int32),
        (CHECKPOINT_ID_COLUMN.to_string(), ChType::UInt64),
        (CHANGE_COLUMN.to_string(), change_type()),
    ]
}

/// Address registrations kept the way an entity's history is: a row per
/// change, stamped with the checkpoint it belongs to. A registration is a set
/// and a rollback that drops one writes a delete, so the addresses a chain has
/// are the latest row of each at or below its frontier that sets it.
pub fn create_addresses_table(
    chain_id_type: &ChType,
    database: &str,
    topology: Topology,
) -> String {
    format!(
        "CREATE TABLE IF NOT EXISTS {}{} (\n  {}\n)\nENGINE = {}\nORDER BY ({}, `address`, `contract_id`, {}){}",
        table_ref(database, ADDRESSES_TABLE),
        topology.on_cluster(),
        definitions(&address_columns(chain_id_type)),
        topology.engine(),
        quoted(CHAIN_ID_COLUMN),
        quoted(CHECKPOINT_ID_COLUMN),
        topology.settings(),
    )
}

/// A table whose rows are replaced rather than accumulated: a row written again
/// under the same key is the same row, and a read through FINAL sees it once.
pub fn create_replacing_table(
    database: &str,
    table: &str,
    columns: &[(String, ChType)],
    order_by: &[&str],
    topology: Topology,
) -> String {
    format!(
        "CREATE TABLE IF NOT EXISTS {}{} (\n  {}\n)\nENGINE = {}\nORDER BY ({}){}",
        table_ref(database, table),
        topology.on_cluster(),
        definitions(columns),
        topology.replacing_engine(None),
        order_by
            .iter()
            .map(|column| quoted(column))
            .collect::<Vec<_>>()
            .join(", "),
        topology.settings(),
    )
}

/// The rows an entity view reads as current: the latest at or below its
/// chain's frontier, which a write raises only once the rows it covers have
/// landed. A per-chain entity's row compares against its own chain's id — a
/// sibling's id says nothing about it, and under a per-chain sequence isn't
/// even comparable. A cross-chain entity's rows belong to no one chain; they
/// only exist under one shared sequence, where the highest id is the frontier
/// of the whole run.
///
/// The frontier is read once per query as a scalar and looked up per row, which
/// costs one comparison and leaves the predicate free to run as PREWHERE. A
/// chain the frontier doesn't name reads as 0, so its rows stay hidden.
pub fn create_view(entity: &EntitySpec, database: &str, topology: Topology) -> String {
    let dedup_key = entity
        .key()
        .iter()
        .map(|column| quoted(column))
        .collect::<Vec<_>>();

    let entity_fields = entity
        .columns
        .iter()
        .map(|column| quoted(&column.name))
        .collect::<Vec<_>>()
        .join(", ");

    let chains = format!("{} FINAL", table_ref(database, CHAINS_TABLE));
    let checkpoint_id = quoted(FRONTIER_COLUMN);
    let (with, marker) = match &entity.chain_id_column {
        Some(chain_id_column) => (
            format!(
                "WITH (SELECT mapFromArrays(groupArray({chain}), groupArray({checkpoint_id})) FROM {chains}) AS envio_frontier\n",
                chain = quoted(CHAIN_ID_COLUMN),
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
    // version in the table first. The checkpoint stays last and descending,
    // which is what makes the surviving row per key the latest one.
    let dedup_sort = format!(
        "{}, {} DESC",
        dedup_key.join(", "),
        quoted(CHECKPOINT_ID_COLUMN)
    );

    format!(
        "CREATE VIEW IF NOT EXISTS {}{} AS\n{with}SELECT {entity_fields}\nFROM (\n  SELECT {entity_fields}, {}\n  FROM {}\n  WHERE {} <= {marker}\n  ORDER BY {dedup_sort}\n  LIMIT 1 BY {}\n)\nWHERE {} = {}",
        table_ref(database, &entity.name),
        topology.on_cluster(),
        quoted(CHANGE_COLUMN),
        table_ref(database, &entity.history_table),
        quoted(CHECKPOINT_ID_COLUMN),
        dedup_key.join(", "),
        quoted(CHANGE_COLUMN),
        literal(SET),
    )
}

pub fn insert_query(
    database: &str,
    table: &str,
    columns: impl Iterator<Item = impl AsRef<str>>,
) -> String {
    let names: Vec<String> = columns.map(|name| quoted(name.as_ref())).collect();
    format!(
        "INSERT INTO {} ({}) FORMAT RowBinary",
        table_ref(database, table),
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
                "SELECT {} AS `_envio_table`, count() AS `_envio_holds` FROM (SELECT 1 FROM {} \
                 WHERE {above} LIMIT 1)",
                literal(table),
                table_ref(database, table),
            )
        })
        .collect();
    format!(
        "SELECT `_envio_table`, `_envio_holds` FROM ({}) FORMAT TabSeparated",
        branches.join(" UNION ALL ")
    )
}

/// Trims one table's rows past the checkpoint being resumed from.
///
/// `ALTER ... DELETE` schedules a mutation rather than running one, so without
/// `mutations_sync` the statement returns while the rows are still there and
/// resume would report a rewind it has only asked for. Waiting for this node
/// (`1`) is what makes the storage actually be at the checkpoint by the time
/// the indexer starts writing again; the indexer reads and writes this node
/// alone, and the replicas behind it catch up on their own.
pub fn trim_table(database: &str, table: &str, above: &str) -> String {
    format!(
        "ALTER TABLE {} DELETE WHERE {above} SETTINGS mutations_sync = 1",
        table_ref(database, table),
    )
}

#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use crate::clickhouse::ch_type::test_support::field;

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

    fn render(entity: &EntitySpec, topology: Topology) -> String {
        create_history_table(entity, "test_db", topology, ChainIdMode::Int32).unwrap()
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
             TTL `created_at` + INTERVAL 1 MONTH WHERE `envio_change` = 'SET'"
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
             TTL `created_at` + INTERVAL 30 day WHERE `envio_change` = 'SET'"
        );
    }

    #[test]
    fn rejects_an_order_by_field_the_entity_does_not_have() {
        let mut entity = entity("Account", vec![column("id", "String")]);
        entity.order_by = Some(vec!["missing".to_string()]);
        assert_eq!(
            create_history_table(&entity, "test_db", plain(), ChainIdMode::Int32)
                .unwrap_err()
                .to_string(),
            "ClickHouse orderBy field \"missing\" is not defined on entity \"Account\""
        );
    }

    #[test]
    fn creates_the_checkpoints_table() {
        assert_eq!(
            create_checkpoints_table(&ChType::Int32, "test_db", plain()),
            "CREATE TABLE IF NOT EXISTS `test_db`.`envio_checkpoints` (\n  \
             `chain_id` Int32,\n  \
             `id` UInt64,\n  \
             `block_number` Int32,\n  \
             `block_hash` Nullable(String),\n  \
             `events_processed` UInt64,\n  \
             `rollback_target` Nullable(UInt64),\n  \
             INDEX `block_number_minmax` `block_number` TYPE minmax GRANULARITY 1\n\
             )\n\
             ENGINE = MergeTree()\n\
             ORDER BY (`chain_id`, `id`)"
        );
    }

    #[test]
    fn a_replicated_checkpoints_table_carries_the_engine_cluster_and_dedup_settings() {
        let created = create_checkpoints_table(&ChType::UInt64, "test_db", replicated());
        assert_eq!(
            (
                created.lines().next(),
                created.lines().nth(1),
                created.lines().rev().take(3).collect::<Vec<_>>()
            ),
            (
                Some("CREATE TABLE IF NOT EXISTS `test_db`.`envio_checkpoints` ON CLUSTER '{cluster}' ("),
                Some("  `chain_id` UInt64,"),
                vec![
                    "SETTINGS replicated_deduplication_window = 0",
                    "ORDER BY (`chain_id`, `id`)",
                    "ENGINE = ReplicatedMergeTree"
                ]
            )
        );
    }

    #[test]
    fn the_chains_table_keeps_the_latest_version_of_each_chain() {
        assert_eq!(
            create_chains_table(&ChType::Int32, "test_db", plain()),
            "CREATE TABLE IF NOT EXISTS `test_db`.`envio_chains` (\n  \
             `chain_id` Int32,\n  \
             `checkpoint_id` UInt64,\n  \
             `version` UInt64,\n  \
             `ecosystem` String,\n  \
             `start_block` Int32,\n  \
             `end_block` Nullable(Int32),\n  \
             `max_reorg_depth` Int32,\n  \
             `buffer_block` Int32,\n  \
             `source_block` Int32,\n  \
             `first_event_block` Nullable(Int32),\n  \
             `ready_at` Nullable(DateTime64(3, 'UTC')),\n  \
             `events_processed` UInt64,\n  \
             `_is_hyper_sync` Bool,\n  \
             `progress_block` Int32,\n  \
             `progress_block_time` Nullable(DateTime64(3, 'UTC'))\n\
             )\n\
             ENGINE = ReplacingMergeTree(`version`)\n\
             ORDER BY (`chain_id`)"
        );
    }

    #[test]
    fn a_replicated_chains_table_carries_the_engine_cluster_and_dedup_settings() {
        let created = create_chains_table(&ChType::UInt64, "test_db", replicated());
        assert_eq!(
            created.lines().rev().take(3).collect::<Vec<_>>(),
            vec![
                "SETTINGS replicated_deduplication_window = 0",
                "ORDER BY (`chain_id`)",
                "ENGINE = ReplicatedReplacingMergeTree(`version`)"
            ]
        );
    }

    #[test]
    fn addresses_are_kept_as_a_history_of_registrations() {
        assert_eq!(
            create_addresses_table(&ChType::Int32, "test_db", plain()),
            "CREATE TABLE IF NOT EXISTS `test_db`.`envio_addresses` (\n  \
             `chain_id` Int32,\n  \
             `address` String,\n  \
             `contract_id` Int32,\n  \
             `registration_block` Int32,\n  \
             `envio_checkpoint_id` UInt64,\n  \
             `envio_change` Enum8('SET' = 1, 'DELETE' = 2)\n\
             )\n\
             ENGINE = MergeTree()\n\
             ORDER BY (`chain_id`, `address`, `contract_id`, `envio_checkpoint_id`)"
        );
    }

    #[test]
    fn a_replacing_table_is_keyed_by_what_it_is_ordered_by() {
        assert_eq!(
            create_replacing_table(
                "test_db",
                "envio_effect_price",
                &[
                    ("id".to_string(), ChType::String),
                    ("output".to_string(), ChType::String)
                ],
                &["id"],
                plain()
            ),
            "CREATE TABLE IF NOT EXISTS `test_db`.`envio_effect_price` (\n  \
             `id` String,\n  \
             `output` String\n\
             )\n\
             ENGINE = ReplacingMergeTree()\n\
             ORDER BY (`id`)"
        );
    }

    #[test]
    fn creates_a_view_over_the_history_table() {
        let entity = entity(
            "Account",
            vec![column("id", "String"), column("balance", "Int32")],
        );
        assert_eq!(
            create_view(&entity, "test_db", plain()),
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
            create_view(&entity, "test_db", plain()),
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
            create_view(&entity, "test_db", replicated()).lines().next(),
            Some("CREATE VIEW IF NOT EXISTS `test_db`.`Account` ON CLUSTER '{cluster}' AS")
        );
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
    fn trims_a_table_past_a_checkpoint() {
        assert_eq!(
            trim_table("db", "envio_history_Account", "`envio_checkpoint_id` > 42"),
            "ALTER TABLE `db`.`envio_history_Account` DELETE WHERE `envio_checkpoint_id` > 42 \
             SETTINGS mutations_sync = 1"
        );
    }
}
