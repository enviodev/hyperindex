//! ClickHouse beside Postgres, keeping the entities configured for it. Nothing
//! here is updated in place: every write appends rows stamped with the
//! checkpoint they belong to. A batch's rows land first, Postgres commits, and
//! only then do the chains' rows move each chain's frontier, `checkpoint_id`,
//! over them. A read only sees rows at or below its chain's frontier, and a
//! resume trims away whatever a batch Postgres never committed left above it.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, bail, Context, Result};
use futures_util::future::{try_join_all, BoxFuture};

use super::ch_type::{ChType, FieldSpec};
use super::client::{error_code, Client, Connection, Tuning, Warn};
use super::ddl::{self, Topology, CHAIN_ID_COLUMN, ID_COLUMN};
use super::row_binary::{self, encode_values, EncodedRows, Value};
use super::select::{self, Frontier};
use super::table::{ClickHouseTableInput, Table};
use super::{literal, quoted};
use crate::columnar::Arena;
use crate::config_parsing::system_config::ChainIdMode;
use crate::entity_filter::Condition;
use crate::storage::rows::{self, Cell, ColumnRead, ReadKind, ResultSet};
use crate::storage::types::{
    Bounds, ChainConfig, ChainMeta, Checkpoints, DiffCheckpoint, Progress, ResumedChain, Sequence,
    CHAINS_TABLE, CHANGE_COLUMN, CHECKPOINTS_TABLE, CHECKPOINT_ID_COLUMN, INFO_TABLE,
};
use crate::storage::{
    Batch, EntityStore, Failure, Handoff, Initialize, Op, Resume, Store, WriteError,
};

pub struct Settings {
    pub chain_id_mode: ChainIdMode,
    pub replicated: bool,
    pub database_engine: Option<String>,
}

/// How far a resume moves the chains' version past the highest it read. A
/// process that died mid-commit can still have its chains insert land after
/// the next one resumed — with a version a little above what that one read —
/// and the rows with the higher version are the ones that stand.
const RESUME_FENCE: u64 = 1 << 32;

/// A chain as its row holds it. A write rewrites the whole row, so the latest
/// one is kept here to write the next from.
#[derive(Clone, Debug, PartialEq)]
pub struct ChainRow {
    pub id: i64,
    pub checkpoint_id: i64,
    pub ecosystem: String,
    pub start_block: i32,
    pub end_block: Option<i32>,
    pub max_reorg_depth: i32,
    pub buffer_block: i32,
    pub source_block: i32,
    pub first_event_block: Option<i32>,
    /// Unix milliseconds.
    pub ready_at: Option<f64>,
    pub events_processed: f64,
    pub is_hyper_sync: bool,
    pub progress_block: i32,
    /// Unix seconds.
    pub progress_block_time: Option<f64>,
}

impl ChainRow {
    fn new(config: &ChainConfig) -> Self {
        Self {
            id: config.id,
            checkpoint_id: 0,
            ecosystem: config.ecosystem.clone(),
            start_block: config.start_block,
            end_block: config.end_block,
            max_reorg_depth: config.max_reorg_depth,
            buffer_block: -1,
            source_block: 0,
            first_event_block: None,
            ready_at: None,
            events_processed: 0.0,
            is_hyper_sync: false,
            progress_block: -1,
            progress_block_time: None,
        }
    }

    fn of_resumed(chain: &ResumedChain) -> Self {
        Self {
            id: chain.id,
            checkpoint_id: chain.checkpoint_id,
            ecosystem: chain.ecosystem.clone(),
            start_block: chain.start_block,
            end_block: chain.end_block,
            max_reorg_depth: chain.max_reorg_depth,
            buffer_block: -1,
            source_block: chain.source_block,
            first_event_block: chain.first_event_block,
            ready_at: chain.ready_at,
            events_processed: chain.events_processed,
            is_hyper_sync: false,
            progress_block: chain.progress_block,
            progress_block_time: chain.progress_block_time,
        }
    }

    fn values(&self, version: u64) -> Vec<Value> {
        let optional =
            |value: Option<i32>| value.map_or(Value::Null, |value| Value::Int(value.into()));
        let millis =
            |value: Option<f64>| value.map_or(Value::Null, |ms| Value::Int(ms.round() as i128));
        vec![
            Value::Int(self.id.into()),
            Value::Int(self.checkpoint_id.into()),
            Value::Int(version.into()),
            Value::Text(self.ecosystem.clone()),
            Value::Int(self.start_block.into()),
            optional(self.end_block),
            Value::Int(self.max_reorg_depth.into()),
            Value::Int(self.buffer_block.into()),
            Value::Int(self.source_block.into()),
            optional(self.first_event_block),
            millis(self.ready_at),
            Value::Int(self.events_processed.max(0.0) as i128),
            Value::Bool(self.is_hyper_sync),
            Value::Int(self.progress_block.into()),
            millis(self.progress_block_time.map(|seconds| seconds * 1000.0)),
        ]
    }

    fn apply_progress(&mut self, progress: &Progress) {
        self.progress_block = progress.progress_block;
        self.progress_block_time = progress.progress_block_time;
        self.events_processed = progress.events_processed;
        self.source_block = progress.source_block;
    }

    /// A chain that caught up never un-catches up: a batch staged before the
    /// stamp can carry metadata from before it.
    fn apply_meta(&mut self, meta: &ChainMeta) {
        self.buffer_block = meta.buffer_block;
        self.first_event_block = meta.first_event_block;
        self.ready_at = meta.ready_at.or(self.ready_at);
        self.is_hyper_sync = meta.is_hyper_sync;
    }
}

#[derive(Default)]
struct Chains {
    rows: BTreeMap<i64, ChainRow>,
    /// The version the last write stamped its rows with.
    version: u64,
}

pub struct Storage {
    client: Client,
    settings: Settings,
    chains: Mutex<Chains>,
}

/// A Replicated database engine only replicates data when its tables use the
/// ReplicatedMergeTree engine, so it implies replicated DDL even when
/// ENVIO_CLICKHOUSE_REPLICATED is unset.
fn has_replicated_engine(database_engine: Option<&str>) -> bool {
    database_engine.map(ddl::database_engine_name) == Some("Replicated")
}

impl Storage {
    pub fn new(
        connection: Connection,
        tuning: Tuning,
        warn: Warn,
        settings: Settings,
    ) -> Result<Self> {
        Ok(Self {
            client: Client::new(connection, tuning, warn)?,
            settings,
            chains: Mutex::new(Chains::default()),
        })
    }

    pub fn register(&self, input: ClickHouseTableInput) -> Result<Table> {
        Table::new(input, self.database(), self.settings.chain_id_mode)
    }

    fn database(&self) -> &str {
        &self.client.database
    }

    fn table_ref(&self, table: &str) -> String {
        format!("{}.{}", quoted(self.database()), quoted(table))
    }

    fn chain_id_type(&self) -> ChType {
        FieldSpec {
            field_type: "ChainId".to_string(),
            is_nullable: false,
            is_array: false,
            precision: None,
            scale: None,
            enum_variants: None,
        }
        .ch_type(self.settings.chain_id_mode)
        .expect("a chain id always has a ClickHouse type")
    }

    fn topology(&self) -> Topology {
        let has_replicated_engine = has_replicated_engine(self.settings.database_engine.as_deref());
        let replicated = self.settings.replicated || has_replicated_engine;
        Topology {
            replicated,
            // DDL a Replicated database engine propagates itself must not carry
            // ON CLUSTER on top of it.
            ddl_on_cluster: replicated && !has_replicated_engine,
        }
    }

    fn frontier(&self) -> Frontier {
        self.chains
            .lock()
            .unwrap()
            .rows
            .values()
            .map(|row| (row.id, row.checkpoint_id))
            .collect()
    }

    /// Code 81 is the database itself being gone, 60 one of its tables. No
    /// schema of ours survives either, so both are answered with the way back
    /// rather than with the statement that tripped over it.
    fn reinitialize_if_gone(&self, err: anyhow::Error) -> anyhow::Error {
        let reinitialize = "Please run 'envio start -r' to reinitialize the indexer (it'll also \
                            drop Postgres database).";
        match error_code(&format!("{err:#}")) {
            Some(81) => anyhow!(
                "ClickHouse storage database \"{}\" not found. {reinitialize}",
                self.database()
            ),
            Some(60) => err.context(format!(
                "ClickHouse storage database \"{}\" is missing a table the indexer needs. \
                 {reinitialize}",
                self.database()
            )),
            _ => err,
        }
    }

    async fn insert(&self, table: &str, query: &str, encoded: &EncodedRows) -> Result<()> {
        self.client
            .insert(table, query, encoded)
            .await
            .with_context(|| format!("Failed inserting into ClickHouse table `{table}`"))
    }

    async fn insert_values(
        &self,
        table: &str,
        columns: &[(String, ChType)],
        rows: &[Vec<Value>],
    ) -> Result<()> {
        if rows.is_empty() {
            return Ok(());
        }
        let types = columns
            .iter()
            .map(|(_, ch_type)| ch_type.clone())
            .collect::<Vec<_>>();
        let encoded = encode_values(&types, rows)
            .with_context(|| format!("Failed encoding rows for ClickHouse table `{table}`"))?;
        let query = ddl::insert_query(self.database(), table, columns.iter().map(|(name, _)| name));
        self.insert(table, &query, &encoded).await
    }

    /// Sends a batch JavaScript staged. Encoding runs off the async workers:
    /// it is pure CPU over every cell of the batch.
    async fn insert_staged(&self, table: Arc<Table>, arena: Arena) -> Result<()> {
        let rows = arena.rows();
        let schema = table.clone();
        let encoded = tokio::task::spawn_blocking(move || {
            let columns: Vec<row_binary::Column> = schema
                .staged
                .iter()
                .zip(arena.columns())
                .map(|((name, ch_type), values)| row_binary::Column {
                    name: std::borrow::Cow::Borrowed(name),
                    ch_type: std::borrow::Cow::Borrowed(ch_type),
                    values,
                })
                .collect();
            row_binary::encode(&columns, rows)
        })
        .await
        .context("ClickHouse encode task failed")?
        .with_context(|| {
            format!(
                "Failed encoding rows for ClickHouse table `{}`",
                table.physical
            )
        })?;
        self.insert(&table.physical, &table.insert_query, &encoded)
            .await
    }

    /// Writes the rows of the chains `change` changes, made from the rows as
    /// the last write left them: the commit point of whatever was written
    /// before them. They go in one insert, since half of them would move some
    /// chains' frontiers and not the others', and are only taken as the chains'
    /// state once they landed. Writes are never concurrent: batches are
    /// written one at a time, and a resume or an initialize before any.
    async fn change_chains(
        &self,
        change: impl FnOnce(&mut BTreeMap<i64, ChainRow>) -> HashSet<i64>,
    ) -> Result<()> {
        // Spent whether the insert lands or not: one that failed here can
        // still land later, and must not tie with the next.
        let (mut rows, version) = {
            let mut chains = self.chains.lock().unwrap();
            chains.version += 1;
            (chains.rows.clone(), chains.version)
        };
        let changed = change(&mut rows);
        let rows = rows
            .into_values()
            .filter(|row| changed.contains(&row.id))
            .collect::<Vec<_>>();
        if rows.is_empty() {
            return Ok(());
        }
        let columns = ddl::chain_columns(&self.chain_id_type());
        let types = columns
            .iter()
            .map(|(_, ch_type)| ch_type.clone())
            .collect::<Vec<_>>();
        let values = rows
            .iter()
            .map(|row| row.values(version))
            .collect::<Vec<_>>();
        let encoded = encode_values(&types, &values)
            .context("Failed encoding rows for ClickHouse table `envio_chains`")?;
        let query = ddl::insert_query(
            self.database(),
            CHAINS_TABLE,
            columns.iter().map(|(name, _)| name),
        );
        self.client
            .insert_whole(CHAINS_TABLE, &query, &encoded)
            .await
            .with_context(|| format!("Failed inserting into ClickHouse table `{CHAINS_TABLE}`"))?;
        let mut chains = self.chains.lock().unwrap();
        for row in rows {
            chains.rows.insert(row.id, row);
        }
        Ok(())
    }

    async fn write_chains(&self, rows: Vec<ChainRow>) -> Result<()> {
        self.change_chains(|current| {
            rows.into_iter()
                .map(|row| {
                    let id = row.id;
                    current.insert(id, row);
                    id
                })
                .collect()
        })
        .await
    }

    fn checkpoint_values(checkpoints: &Checkpoints) -> Vec<Vec<Value>> {
        (0..checkpoints.len())
            .map(|index| {
                vec![
                    Value::Int(checkpoints.chain_ids[index].into()),
                    Value::Int(checkpoints.ids[index].into()),
                    Value::Int(checkpoints.block_numbers[index].into()),
                    checkpoints.block_hashes[index]
                        .clone()
                        .map_or(Value::Null, Value::Text),
                    Value::Int(checkpoints.events_processed[index].max(0).into()),
                ]
            })
            .collect()
    }

    /// The checkpoint a rollback stamps the rows restoring its chain with.
    fn diff_checkpoint_values(diff: &DiffCheckpoint) -> Vec<Value> {
        vec![
            Value::Int(diff.chain_id.into()),
            Value::Int(diff.checkpoint_id.into()),
            Value::Int(diff.block_number.into()),
            Value::Null,
            Value::Int(0),
        ]
    }

    async fn existing_database_engine(&self) -> Result<Option<String>> {
        let answer = self
            .client
            .statement(format!(
                "SELECT engine FROM system.databases WHERE name = {} FORMAT TabSeparated",
                literal(self.database())
            ))
            .await?;
        Ok(match answer.trim() {
            "" => None,
            engine => Some(engine.to_string()),
        })
    }

    /// What initializing would have to destroy or could not change, refused
    /// before anything is touched.
    pub async fn check_for_initialize(&self) -> Result<()> {
        if let Some(engine_spec) = self.settings.database_engine.as_deref() {
            let expected = ddl::database_engine_name(engine_spec);
            match self.existing_database_engine().await?.as_deref() {
                Some(engine) if engine != expected => bail!(
                    "ClickHouse database \"{}\" exists with engine \"{engine}\" but \
                     ENVIO_CLICKHOUSE_DATABASE_ENGINE specifies \"{expected}\" (from \
                     \"{engine_spec}\"). Drop the database manually to change its engine.",
                    self.database()
                ),
                _ => {}
            }
        }
        let answer = self
            .client
            .statement(format!(
                "SELECT name FROM system.tables WHERE database = {} FORMAT TabSeparated",
                literal(self.database())
            ))
            .await?;
        let names = answer
            .lines()
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .collect::<Vec<_>>();
        // An entity's view is named after the entity, so a database the
        // indexer built is told by its chains' table. One whose setup failed
        // before that table was created holds only tables named the
        // indexer's way.
        let foreign = names.iter().any(|name| !name.starts_with("envio_"));
        if foreign && !names.contains(&CHAINS_TABLE) {
            bail!(
                "ClickHouse database \"{}\" holds tables that aren't the indexer's, and emptying it \
                 for the indexer would delete them.\n\nTo resolve this:\n1. Set \
                 ENVIO_CLICKHOUSE_DATABASE to a database of the indexer's own\n2. Or drop those \
                 tables yourself if you're certain they aren't needed.",
                self.database()
            );
        }
        Ok(())
    }

    async fn initialize_inner(&self, input: &Initialize) -> Result<()> {
        let topology = self.topology();
        let database_engine = self.settings.database_engine.as_deref();
        let has_replicated_engine = has_replicated_engine(database_engine);
        if has_replicated_engine && !self.settings.replicated {
            (self.client.warn)(
                "ENVIO_CLICKHOUSE_DATABASE_ENGINE is Replicated; enabling replicated mode so \
                 tables use the ReplicatedMergeTree engine.",
            );
        }
        let database = quoted(self.database());

        let entities = input
            .tables
            .iter()
            .filter_map(|table| table.clickhouse.as_ref().map(|table| &table.entity))
            .collect::<Vec<_>>();
        let history_tables = entities
            .iter()
            .map(|entity| {
                ddl::create_history_table(
                    entity,
                    self.database(),
                    topology,
                    self.settings.chain_id_mode,
                )
            })
            .collect::<Result<Vec<_>>>()?;

        self.stop_inserts_left_running(Some(
            &input
                .chains
                .iter()
                .map(|chain| chain.id)
                .collect::<Vec<_>>(),
        ))
        .await;
        self.reset_database(topology).await?;
        self.client
            .statement(format!(
                "CREATE DATABASE IF NOT EXISTS {database}{}{}",
                ddl::on_cluster_clause(topology.replicated),
                match database_engine {
                    Some(engine) => format!(" ENGINE = {engine}"),
                    None => String::new(),
                }
            ))
            .await?;

        let chain_id_type = self.chain_id_type();
        let mut statements = history_tables;
        statements.push(ddl::create_checkpoints_table(
            &chain_id_type,
            self.database(),
            topology,
        ));
        statements.push(ddl::create_chains_table(
            &chain_id_type,
            self.database(),
            topology,
        ));
        statements.push(ddl::create_info_table(self.database(), topology));
        try_join_all(
            statements
                .into_iter()
                .map(|query| self.client.statement(query)),
        )
        .await?;
        try_join_all(entities.iter().map(|entity| {
            self.client
                .statement(ddl::create_view(entity, self.database(), topology))
        }))
        .await?;

        *self.chains.lock().unwrap() = Chains::default();
        self.write_chains(input.chains.iter().map(ChainRow::new).collect())
            .await?;
        // Last: the record is what says the storage exists, so it only does
        // once everything above it is in place.
        self.insert_values(
            INFO_TABLE,
            &ddl::info_columns(),
            &[vec![
                Value::Int(1),
                Value::Text(input.envio_info.clone()),
                Value::Text(input.instance.clone()),
            ]],
        )
        .await
    }

    pub async fn initialize(&self, input: &Initialize) -> Result<()> {
        self.initialize_inner(input)
            .await
            .context("Failed to initialize ClickHouse storage")
    }

    async fn has_table(&self, name: &str) -> Result<bool> {
        let count = self
            .client
            .statement(format!(
                "SELECT count() FROM system.tables WHERE `database` = {} AND `name` = {} \
                 FORMAT TabSeparated",
                literal(self.database()),
                literal(name)
            ))
            .await?;
        Ok(count.trim() != "0")
    }

    /// The instance of the initialize that built the database, if one finished
    /// building it.
    pub async fn instance(&self) -> Result<Option<String>> {
        if !self.has_table(INFO_TABLE).await? {
            return Ok(None);
        }
        let body = self
            .client
            .read(format!(
                "SELECT `instance` FROM {} ORDER BY `id` LIMIT 1 FORMAT RowBinary",
                self.table_ref(INFO_TABLE)
            ))
            .await?;
        match row_binary::decode(&body, &[(ChType::String, ReadKind::Text)])?.as_slice() {
            [] => Ok(None),
            [Cell::Str(instance)] => Ok(Some(instance.to_string())),
            other => bail!("Unexpected info record {other:?}"),
        }
    }

    /// Stops the inserts a process before this one left running on any of
    /// `chain_ids` — on any chain, given none — and tags this one's inserts as
    /// writing them. An insert keeps running on the server after the process
    /// that sent it is gone, and one landing after a trim would leave rows the
    /// next batches reuse the checkpoints of. Stopping one is best effort: a
    /// server that refuses is warned about, and the run goes on.
    async fn stop_inserts_left_running(&self, chain_ids: Option<&[i64]>) {
        let prefix = format!("envio:{}:", self.database());
        let mut filter = format!("startsWith(query_id, {})", literal(&prefix));
        if let Some(chain_ids) = chain_ids {
            self.client.tag_inserts(chain_ids);
            let needles = chain_ids
                .iter()
                .map(|chain_id| literal(&format!(",{chain_id},")))
                .collect::<Vec<_>>()
                .join(", ");
            filter.push_str(&format!(" AND multiSearchAny(query_id, [{needles}])"));
        }
        let stopped = self
            .client
            .statement(format!(
                "KILL QUERY{} WHERE {filter} SYNC FORMAT TabSeparated",
                ddl::on_cluster_clause(self.topology().replicated),
            ))
            .await;
        if let Err(error) = stopped {
            (self.client.warn)(&format!(
                "Couldn't stop the ClickHouse inserts a previous run may have left running: \
                 {error:#}"
            ));
        }
    }

    /// Emptied rather than dropped, so a database the operator provisioned
    /// keeps its engine and grants — except where emptying is not an option.
    async fn reset_database(&self, topology: Topology) -> Result<()> {
        let database = quoted(self.database());
        if has_replicated_engine(self.settings.database_engine.as_deref()) {
            // TRUNCATE DATABASE is unsupported on Replicated databases, so a
            // reset has to DROP and recreate instead. ON CLUSTER removes the
            // database from every node — the engine's own log can't replicate
            // the drop of the database it lives in — and SYNC waits for the drop
            // to finish before anything is created again.
            self.client
                .statement(format!(
                    "DROP DATABASE IF EXISTS {database} ON CLUSTER '{{cluster}}' SYNC"
                ))
                .await?;
        } else {
            self.client
                .statement(format!(
                    "TRUNCATE DATABASE IF EXISTS {database}{}",
                    ddl::on_cluster_clause(topology.ddl_on_cluster)
                ))
                .await?;
        }
        Ok(())
    }

    /// The highest version any write stamped the chains' rows with.
    async fn read_version(&self) -> Result<u64> {
        let answer = self
            .client
            .statement(format!(
                "SELECT max({}) FROM {} FORMAT TabSeparated",
                quoted(ddl::VERSION_COLUMN),
                self.table_ref(CHAINS_TABLE)
            ))
            .await?;
        answer
            .trim()
            .parse()
            .with_context(|| format!("Unexpected chains version {answer:?}"))
    }

    /// Trims every table holding rows stamped past `frontier`, which only a
    /// batch Postgres never committed leaves behind. A table with nothing
    /// above it is left alone: a mutation rewrites parts, and on a clean
    /// restart there is nothing to rewrite.
    async fn trim_above(
        &self,
        sequence: Sequence,
        frontier: &Frontier,
        tables: &[Arc<Table>],
    ) -> Result<()> {
        if frontier.is_empty() {
            return Ok(());
        }
        let bounds = Bounds {
            sequence,
            chain_ids: frontier.keys().copied().collect(),
            checkpoint_ids: match sequence {
                // Under one shared counter every chain counts from the same
                // run of it, so the highest committed id is where all of them
                // trim — a lower one would remove another chain's rows.
                Sequence::SharedAcrossChains => {
                    let highest = frontier.values().copied().max().unwrap_or(0);
                    vec![highest; frontier.len()]
                }
                Sequence::PerChain => frontier.values().copied().collect(),
            },
        };
        let mut above_by_table = tables
            .iter()
            .map(|table| {
                Ok((
                    table.physical.clone(),
                    select::above(
                        &bounds,
                        table.entity.chain_id_column.as_deref(),
                        CHECKPOINT_ID_COLUMN,
                    )?,
                ))
            })
            .collect::<Result<Vec<_>>>()?;
        above_by_table.push((
            CHECKPOINTS_TABLE.to_string(),
            select::above(&bounds, Some(CHAIN_ID_COLUMN), ID_COLUMN)?,
        ));

        let holding = self.tables_holding_rows_above(&above_by_table).await?;
        try_join_all(
            above_by_table
                .iter()
                .filter(|(table, _)| holding.contains(table))
                .map(|(table, above)| {
                    self.client
                        .statement(ddl::trim_table(self.database(), table, above))
                }),
        )
        .await?;
        Ok(())
    }

    /// Which of the tables hold a row above the checkpoint. TabSeparated
    /// answers one `name<TAB>0|1` per table, in whatever order the server ran
    /// the branches. The shape is fully known here, so anything else is an
    /// answer to refuse rather than a table to skip: a skipped trim leaves
    /// rolled-back rows visible.
    async fn tables_holding_rows_above(
        &self,
        above_by_table: &[(String, String)],
    ) -> Result<HashSet<String>> {
        let answer = self
            .client
            .statement(ddl::holds_rows_above_checkpoint(
                self.database(),
                above_by_table,
            ))
            .await?;
        let answered: HashMap<&str, bool> = answer
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(|line| {
                let (table, holds) = line
                    .split_once('\t')
                    .with_context(|| format!("Unexpected row count answer {line:?}"))?;
                let holds = match holds.trim() {
                    "0" => false,
                    "1" => true,
                    _ => bail!("Unexpected row count answer {line:?}"),
                };
                Ok((table.trim(), holds))
            })
            .collect::<Result<_>>()?;
        above_by_table
            .iter()
            .filter_map(|(table, _)| match answered.get(table.as_str()) {
                Some(true) => Some(Ok(table.clone())),
                Some(false) => None,
                None => Some(Err(anyhow!("No row count answered for table {table}"))),
            })
            .collect()
    }

    /// Takes the chains' state from what Postgres committed, frontier first
    /// so nothing above it is readable while the trims run. The rows are
    /// written past a fence, so a previous process's commit still in flight
    /// can't land over them.
    async fn resume_inner(&self, input: &Resume) -> Result<()> {
        self.stop_inserts_left_running(Some(
            &input
                .committed
                .iter()
                .map(|chain| chain.id)
                .collect::<Vec<_>>(),
        ))
        .await;
        let version = self.read_version().await?;
        *self.chains.lock().unwrap() = Chains {
            rows: BTreeMap::new(),
            version: version + RESUME_FENCE,
        };
        let rows = input
            .committed
            .iter()
            .map(ChainRow::of_resumed)
            .collect::<Vec<_>>();
        // No chain, no rows to hold to anything: Postgres writes every chain's
        // row in the transaction that creates its schema, so an empty list
        // means a config without chains.
        if rows.is_empty() {
            return Ok(());
        }
        let frontier: Frontier = rows.iter().map(|row| (row.id, row.checkpoint_id)).collect();
        self.write_chains(rows).await?;
        let tables = input
            .tables
            .iter()
            .filter_map(|table| table.clickhouse.clone())
            .collect::<Vec<_>>();
        self.trim_above(input.sequence, &frontier, &tables).await
    }

    pub async fn resume(&self, input: &Resume) -> Result<()> {
        self.resume_inner(input)
            .await
            .map_err(|err| self.reinitialize_if_gone(err))
            .context("Failed to resume ClickHouse storage")
    }

    async fn load_where_inner(
        &self,
        table: &crate::storage::Table,
        conditions: Vec<Condition>,
    ) -> Result<ResultSet> {
        let table = table.clickhouse()?;
        let query = select::load(self.database(), table, &conditions, &self.frontier())?;
        let body = self.client.read(query).await?;
        let (types, reads) = table.reads();
        rows::lay_out(&row_binary::decode(&body, &types)?, reads)
    }

    async fn rollback_data_inner(
        &self,
        table: &crate::storage::Table,
        bounds: &Bounds,
    ) -> Result<(ResultSet, ResultSet)> {
        let table = table.clickhouse()?;
        let (removed, restored) = futures_util::try_join!(
            self.client
                .read(select::rollback_removed(self.database(), table, bounds)?),
            self.client
                .read(select::rollback_restored(self.database(), table, bounds)?),
        )?;
        let key = table
            .entity
            .key()
            .iter()
            .map(|name| {
                table
                    .columns
                    .iter()
                    .find(|column| &column.name == name)
                    .ok_or_else(|| anyhow!("\"{}\" has no column `{name}`", table.name))
            })
            .collect::<Result<Vec<_>>>()?;
        let removed = rows::lay_out(
            &row_binary::decode(
                &removed,
                &key.iter()
                    .map(|column| (column.ch_type.clone(), column.read))
                    .collect::<Vec<_>>(),
            )?,
            key.iter()
                .map(|column| ColumnRead::scalar(&column.row_name, column.read))
                .collect(),
        )?;
        let (mut types, mut reads) = table.reads();
        types.push((ddl::change_type(), ReadKind::Text));
        reads.push(ColumnRead::scalar(CHANGE_COLUMN, ReadKind::Text));
        let restored = rows::lay_out(&row_binary::decode(&restored, &types)?, reads)?;
        Ok((removed, restored))
    }

    /// Whether the batch was committed: one landed but not told to commit is
    /// left above the frontier, unread and trimmed by the next resume.
    async fn write_inner(&self, batch: Batch, mut handoff: Handoff) -> Result<bool> {
        let Batch {
            rollback,
            progress,
            entities,
            chain_meta,
            frontier,
            checkpoints,
            ..
        } = batch;

        let checkpoint_columns = ddl::checkpoint_columns(&self.chain_id_type());
        let mut checkpoint_rows = Self::checkpoint_values(&checkpoints);
        if let Some(rollback) = &rollback {
            checkpoint_rows.extend(
                rollback
                    .diff_checkpoints
                    .iter()
                    .map(Self::diff_checkpoint_values),
            );
        }
        let mut rows: Vec<BoxFuture<'_, Result<()>>> = vec![Box::pin(self.insert_values(
            CHECKPOINTS_TABLE,
            &checkpoint_columns,
            &checkpoint_rows,
        ))];
        for write in entities {
            if let Some(arena) = write.clickhouse {
                let table = write.table.clickhouse()?.clone();
                rows.push(Box::pin(self.insert_staged(table, arena)));
            }
        }
        try_join_all(rows).await?;

        // Every row above has landed, so the chains' rows can make them
        // readable once the handoff says to.
        if !handoff.ready_to_commit().await {
            return Ok(false);
        }
        self.change_chains(|chains| {
            let mut changed = HashSet::new();
            for update in rollback
                .iter()
                .flat_map(|rollback| &rollback.progress)
                .chain(&progress)
            {
                if let Some(row) = chains.get_mut(&update.chain_id) {
                    row.apply_progress(update);
                    changed.insert(update.chain_id);
                }
            }
            for meta in &chain_meta {
                if let Some(row) = chains.get_mut(&meta.chain_id) {
                    row.apply_meta(meta);
                    changed.insert(meta.chain_id);
                }
            }
            for (chain_id, checkpoint_id) in frontier.entries() {
                if let Some(row) = chains.get_mut(&chain_id) {
                    row.checkpoint_id = checkpoint_id;
                    changed.insert(chain_id);
                }
            }
            changed
        })
        .await
        .map(|()| true)
    }

    pub async fn write_batch(
        &self,
        batch: Batch,
        handoff: Handoff,
    ) -> std::result::Result<(), WriteError> {
        match self.write_inner(batch, handoff).await {
            Ok(true) => Ok(()),
            Ok(false) => Err(WriteError::Gated),
            Err(error) => Err(WriteError::Failed(Failure::new(
                "Failed to write a batch to ClickHouse",
                error,
            ))),
        }
    }

    /// Refuses a database it may not empty, as initializing would.
    pub async fn reset(&self) -> Result<()> {
        self.check_for_initialize().await?;
        self.stop_inserts_left_running(None).await;
        self.reset_database(self.topology()).await?;
        *self.chains.lock().unwrap() = Chains::default();
        Ok(())
    }
}

impl EntityStore for Storage {
    fn store(&self) -> Store {
        Store::ClickHouse
    }

    fn load_where<'a>(
        &'a self,
        table: &'a crate::storage::Table,
        conditions: Vec<Condition>,
    ) -> Op<'a, ResultSet> {
        Box::pin(self.load_where_inner(table, conditions))
    }

    fn rollback_data<'a>(
        &'a self,
        table: &'a crate::storage::Table,
        bounds: &'a Bounds,
    ) -> Op<'a, (ResultSet, ResultSet)> {
        Box::pin(self.rollback_data_inner(table, bounds))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clickhouse::mock_server::MockClickHouse;
    use crate::clickhouse::table::test_support::{column, entity_input};
    use crate::storage::types::{Addresses, Frontier};
    use crate::storage::EntityWrite;
    use pretty_assertions::assert_eq;

    fn storage_at(server: &MockClickHouse) -> Storage {
        Storage::new(
            crate::clickhouse::client::test_support::connection(server.url.clone()),
            Tuning::default(),
            Arc::new(|_: &str| {}),
            Settings {
                chain_id_mode: ChainIdMode::Int32,
                replicated: false,
                database_engine: None,
            },
        )
        .unwrap()
    }

    fn account(storage: &Storage) -> Arc<crate::storage::Table> {
        Arc::new(crate::storage::Table {
            name: "Account".to_string(),
            postgres: None,
            clickhouse: Some(Arc::new(
                storage
                    .register(entity_input("Account", vec![column("id", "String")]))
                    .unwrap(),
            )),
        })
    }

    /// The table each insert went to, in the order they were sent.
    fn inserted_tables(server: &MockClickHouse) -> Vec<String> {
        server
            .heads()
            .iter()
            .filter_map(|head| {
                let query = head.split_once("query=")?.1;
                let table = query.split("%60").nth(3)?;
                Some(table.to_string())
            })
            .collect()
    }

    async fn initialize(storage: &Storage, tables: Vec<Arc<crate::storage::Table>>) {
        storage
            .initialize(&Initialize {
                sequence: Sequence::PerChain,
                tables,
                partitions: Vec::new(),
                enums: Vec::new(),
                chains: vec![ChainConfig {
                    id: 1,
                    ecosystem: "evm".to_string(),
                    start_block: 0,
                    end_block: None,
                    max_reorg_depth: 0,
                }],
                envio_info: "{}".to_string(),
                instance: "instance".to_string(),
                contract_names: Vec::new(),
                addresses: Addresses::default(),
            })
            .await
            .unwrap();
    }

    /// Initializing empties the database, so one that holds tables but none of
    /// the indexer's is refused rather than emptied.
    #[tokio::test(flavor = "multi_thread")]
    async fn initializing_refuses_a_database_with_tables_of_someone_elses() {
        let server = MockClickHouse::answering_statements(Arc::new(|statement: &str| {
            if statement.contains("system.tables") {
                (200, "orders\ncustomers".to_string())
            } else {
                (200, String::new())
            }
        }))
        .await;
        let storage = storage_at(&server);

        let refused = storage.check_for_initialize().await.unwrap_err();

        assert_eq!(
            (
                format!("{refused:#}").contains("holds tables that aren't the indexer's"),
                server.inserts_seen()
            ),
            (true, 0)
        );
    }

    /// A setup that failed partway leaves tables of its own behind, possibly
    /// without the chains' table, and the next one takes them over.
    #[tokio::test(flavor = "multi_thread")]
    async fn initializing_takes_over_what_a_failed_setup_left() {
        let server = MockClickHouse::answering_statements(Arc::new(|statement: &str| {
            if statement.contains("system.tables") {
                (200, "envio_history_Account\nenvio_checkpoints".to_string())
            } else {
                (200, String::new())
            }
        }))
        .await;
        let storage = storage_at(&server);

        assert_eq!(
            storage
                .check_for_initialize()
                .await
                .map_err(|error| format!("{error:#}")),
            Ok(())
        );
    }

    /// The chains' rows are what make a write readable, so they go only once
    /// every row they cover has landed.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_write_commits_with_its_chains_rows_last() {
        let server =
            MockClickHouse::answering_statements(Arc::new(|_: &str| (200, String::new()))).await;
        let storage = storage_at(&server);
        let account = account(&storage);
        initialize(&storage, vec![account.clone()]).await;
        let initialized = inserted_tables(&server).len();

        let mut arena = Arena::new(
            1,
            &[
                crate::columnar::ColumnKind::Text,
                crate::columnar::ColumnKind::U64,
                crate::columnar::ColumnKind::Text,
            ],
        )
        .unwrap();
        arena.set_bytes(0, 0, b"a");
        arena.set_u64(1, 0, 1);
        arena.set_bytes(2, 0, b"SET");
        arena
            .seal_unlent(&["id", "envio_checkpoint_id", "envio_change"].map(str::to_string))
            .unwrap();
        let queries_before = server.queries_seen();
        storage
            .write_batch(
                Batch {
                    entities: vec![EntityWrite {
                        table: account,
                        chain_id: None,
                        postgres: None,
                        clickhouse: Some(arena),
                    }],
                    frontier: Frontier {
                        chain_ids: vec![1],
                        checkpoint_ids: vec![1],
                    },
                    checkpoints: Checkpoints {
                        ids: vec![1],
                        chain_ids: vec![1],
                        block_numbers: vec![10],
                        block_hashes: vec![None],
                        events_processed: vec![1],
                        keeps_history: vec![true],
                    },
                    ..Batch::default()
                },
                Handoff::default(),
            )
            .await
            .map_err(|error| match error {
                WriteError::Failed(failure) => format!("{}: {:#}", failure.context, failure.error),
                WriteError::Gated => "gated".to_string(),
            })
            .unwrap();

        let mut written = inserted_tables(&server).split_off(initialized);
        let last = written.pop();
        written.sort();
        assert_eq!(
            (written, last, server.queries_seen() - queries_before),
            (
                vec![
                    "envio_checkpoints".to_string(),
                    "envio_history_Account".to_string()
                ],
                Some("envio_chains".to_string()),
                0
            )
        );
    }

    /// A restart after a clean stop finds nothing above the frontier, so it
    /// schedules no mutation: each one rewrites parts.
    #[tokio::test(flavor = "multi_thread")]
    async fn resuming_after_a_clean_stop_rewrites_nothing() {
        let server = MockClickHouse::answering_statements(Arc::new(|statement: &str| {
            if statement.contains("_envio_holds") {
                (
                    200,
                    "envio_history_Account\t0\nenvio_checkpoints\t0".to_string(),
                )
            } else if statement.contains("max(`version`)") {
                (200, "3".to_string())
            } else {
                (200, String::new())
            }
        }))
        .await;
        let storage = storage_at(&server);
        let account = account(&storage);
        storage
            .resume(&Resume {
                // A cross-chain entity has no chain column, which only a
                // shared sequence bounds.
                sequence: Sequence::SharedAcrossChains,
                tables: vec![account],
                committed: vec![ResumedChain {
                    id: 1,
                    ecosystem: "evm".to_string(),
                    start_block: 0,
                    end_block: None,
                    max_reorg_depth: 0,
                    first_event_block: None,
                    ready_at: None,
                    events_processed: 0.0,
                    progress_block: 10,
                    progress_block_time: None,
                    source_block: 10,
                    checkpoint_id: 7,
                }],
            })
            .await
            .unwrap();
        assert_eq!(
            (
                server
                    .statements_seen()
                    .iter()
                    .filter(|statement| statement.starts_with("ALTER"))
                    .count(),
                inserted_tables(&server),
            ),
            (0, vec!["envio_chains".to_string()])
        );
    }
}
