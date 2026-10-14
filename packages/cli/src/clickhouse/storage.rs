//! Nothing here is updated in place. Every write appends rows stamped with the
//! checkpoint they belong to, and the last thing it appends is the chains'
//! rows, whose `checkpoint_id` is each chain's frontier. That insert is the
//! commit: a read only sees rows at or below its chain's frontier, and a
//! resume trims away whatever a write that never committed left above it.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, bail, Context, Result};
use futures_util::future::{try_join_all, BoxFuture};

use super::ch_type::{ChType, FieldSpec};
use super::client::{error_code, Client, Connection, Tuning, Warn};
use super::ddl::{self, Topology, CHAIN_ID_COLUMN, ID_COLUMN, ROLLBACK_TARGET_COLUMN};
use super::row_binary::{self, encode_values, EncodedRows, Value};
use super::select::{self, frontier_of, Frontier};
use super::table::{ClickHouseTableInput, Kind, Table};
use super::{literal, quoted};
use crate::columnar::Arena;
use crate::config_parsing::system_config::ChainIdMode;
use crate::entity_filter::Condition;
use crate::postgres::index_definition::IndexDefinition;
use crate::storage::rows::{self, Cell, ColumnRead, ReadKind, ResultSet};
use crate::storage::types::{
    Addresses, Bounds, CacheTable, ChainConfig, ChainMeta, Checkpoints, DiffCheckpoint, Progress,
    ProgressDiff, ReorgCheckpoint, ResumedChain, Sequence, StoredChain, StoredConfig,
    ADDRESSES_TABLE, CHAINS_TABLE, CHANGE_COLUMN, CHECKPOINTS_TABLE, CHECKPOINT_ID_COLUMN,
    CONFIG_REGISTRATION_BLOCK, CONTRACTS_TABLE, DELETE, INFO_TABLE, RAW_EVENTS_TABLE, SET,
};
use crate::storage::{
    AddChain, Backend, Batch, CacheDump, CacheFile, Failure, Handoff, Initialize, Op, Resume,
    Resumed, Store, StoredConfigRead, WriteError,
};

pub struct Settings {
    pub chain_id_mode: ChainIdMode,
    pub replicated: bool,
    pub database_engine: Option<String>,
    /// Whether ClickHouse is the store of record. Following Postgres it keeps
    /// the entities' history and the chains' frontier, and nothing else.
    pub primary: bool,
}

/// The info record's id says which part the database was built to play, so a
/// store of record can tell its own database from one that followed another,
/// and a follower from one built for something else.
const OWN_RECORD: i32 = 1;
const FOLLOWER_RECORD: i32 = 2;

pub struct Record {
    pub follower: bool,
    pub envio_info: String,
}

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

    fn resumed(&self) -> ResumedChain {
        ResumedChain {
            id: self.id,
            ecosystem: self.ecosystem.clone(),
            start_block: self.start_block,
            end_block: self.end_block,
            max_reorg_depth: self.max_reorg_depth,
            first_event_block: self.first_event_block,
            ready_at: self.ready_at,
            events_processed: self.events_processed,
            progress_block: self.progress_block,
            progress_block_time: self.progress_block_time,
            source_block: self.source_block,
            checkpoint_id: self.checkpoint_id,
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

    /// A chain that caught up never un-catches up: metadata is written on a
    /// throttle of its own, and a write staged before the stamp can land after
    /// it.
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
    /// Held across a chains write, from reading the rows it changes to taking
    /// what landed: metadata is written on a throttle of its own, alongside
    /// batches and finalization, and each rewrites whole rows.
    chain_writes: tokio::sync::Mutex<()>,
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
            chain_writes: tokio::sync::Mutex::new(()),
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

    /// How a chain id reads back: text where it is wider than a JavaScript
    /// number keeps exactly.
    fn chain_id_read(&self) -> ReadKind {
        match self.settings.chain_id_mode {
            ChainIdMode::Int32 => ReadKind::Float,
            ChainIdMode::Int64 => ReadKind::Text,
        }
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
        let reinitialize = if self.settings.primary {
            "Please run 'envio start -r' to reinitialize the indexer."
        } else {
            "Please run 'envio start -r' to reinitialize the indexer (it'll also drop Postgres \
             database)."
        };
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
    /// state once they landed.
    async fn change_chains(
        &self,
        change: impl FnOnce(&mut BTreeMap<i64, ChainRow>) -> HashSet<i64>,
    ) -> Result<()> {
        let _turn = self.chain_writes.lock().await;
        let (mut rows, version) = {
            let chains = self.chains.lock().unwrap();
            (chains.rows.clone(), chains.version + 1)
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
        chains.version = version;
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

    fn chain_rows(&self) -> BTreeMap<i64, ChainRow> {
        self.chains.lock().unwrap().rows.clone()
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
                    Value::Null,
                ]
            })
            .collect()
    }

    /// A rollback's marker: the checkpoint its diff is stamped with, carrying
    /// the one it rolled its chain back to.
    fn marker_values(diff: &DiffCheckpoint, target: i64) -> Vec<Value> {
        vec![
            Value::Int(diff.chain_id.into()),
            Value::Int(diff.checkpoint_id.into()),
            Value::Int(diff.block_number.into()),
            Value::Null,
            Value::Int(0),
            Value::Int(target.into()),
        ]
    }

    fn address_values(addresses: &Addresses, change: &str) -> Vec<Vec<Value>> {
        (0..addresses.chain_ids.len())
            .map(|index| {
                vec![
                    Value::Int(addresses.chain_ids[index].into()),
                    Value::Bytes(addresses.addresses[index].clone()),
                    Value::Int(addresses.contract_ids[index].into()),
                    Value::Int(
                        addresses
                            .registration_blocks
                            .get(index)
                            .copied()
                            .unwrap_or(CONFIG_REGISTRATION_BLOCK)
                            .into(),
                    ),
                    Value::Int(
                        addresses
                            .checkpoint_ids
                            .get(index)
                            .copied()
                            .unwrap_or(0)
                            .into(),
                    ),
                    Value::Text(change.to_string()),
                ]
            })
            .collect()
    }

    async fn insert_checkpoints(&self, rows: Vec<Vec<Value>>) -> Result<()> {
        self.insert_values(
            CHECKPOINTS_TABLE,
            &ddl::checkpoint_columns(&self.chain_id_type()),
            &rows,
        )
        .await
    }

    async fn insert_addresses(&self, rows: Vec<Vec<Value>>) -> Result<()> {
        self.insert_values(
            ADDRESSES_TABLE,
            &ddl::address_columns(&self.chain_id_type()),
            &rows,
        )
        .await
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
    async fn check_for_initialize_inner(&self) -> Result<()> {
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
        let foreign = names
            .iter()
            .any(|name| !name.starts_with("envio_") && *name != RAW_EVENTS_TABLE);
        if foreign && !names.contains(&CHAINS_TABLE) {
            bail!(
                "Cannot initialize the indexer in ClickHouse database \"{}\" because it holds \
                 tables that aren't the indexer's. Initializing would delete them.\n\nTo resolve \
                 this:\n1. Set ENVIO_CLICKHOUSE_DATABASE to a database of the indexer's own\n2. Or \
                 drop those tables yourself if you're certain they aren't needed.",
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

        let tables = input
            .tables
            .iter()
            .filter_map(|table| table.clickhouse.clone())
            .collect::<Vec<_>>();
        let entities = tables
            .iter()
            .filter_map(|table| table.entity())
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
        if self.settings.primary {
            statements.push(ddl::create_contracts_table(self.database(), topology));
            statements.push(ddl::create_addresses_table(
                &chain_id_type,
                self.database(),
                topology,
            ));
            for table in &tables {
                if matches!(table.kind, Kind::RawEvents) {
                    statements.push(table.create(self.database(), topology)?);
                }
            }
        }
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

        if self.settings.primary {
            self.insert_values(
                CONTRACTS_TABLE,
                &ddl::contract_columns(),
                &input
                    .contract_names
                    .iter()
                    .enumerate()
                    .map(|(id, name)| vec![Value::Int(id as i128), Value::Text(name.clone())])
                    .collect::<Vec<_>>(),
            )
            .await?;
            self.insert_addresses(Self::address_values(&input.addresses, SET))
                .await?;
        }
        *self.chains.lock().unwrap() = Chains::default();
        self.write_chains(input.chains.iter().map(ChainRow::new).collect())
            .await?;
        // Last: the record is what says the storage exists, so it only does
        // once everything above it is in place.
        let id = if self.settings.primary {
            OWN_RECORD
        } else {
            FOLLOWER_RECORD
        };
        self.insert_values(
            INFO_TABLE,
            &ddl::info_columns(),
            &[vec![
                Value::Int(id.into()),
                Value::Text(input.envio_info.clone()),
            ]],
        )
        .await
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

    /// What the database was built as, if an indexer finished building it.
    pub async fn record(&self) -> Result<Option<Record>> {
        if !self.has_table(INFO_TABLE).await? {
            return Ok(None);
        }
        let body = self
            .client
            .read(format!(
                "SELECT `id`, `config` FROM {} ORDER BY `id` LIMIT 1 FORMAT RowBinary",
                self.table_ref(INFO_TABLE)
            ))
            .await?;
        let cells = row_binary::decode(
            &body,
            &[
                (ChType::Int32, ReadKind::Text),
                (ChType::String, ReadKind::Text),
            ],
        )?;
        match cells.as_slice() {
            [] => Ok(None),
            [Cell::Str(id), Cell::Str(config)] => Ok(Some(Record {
                follower: id.parse::<i32>()? == FOLLOWER_RECORD,
                envio_info: config.to_string(),
            })),
            other => bail!("Unexpected info record {other:?}"),
        }
    }

    /// Empties the database, or drops it where emptying is not an option.
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

    async fn read_chains(&self) -> Result<(Vec<ChainRow>, u64)> {
        let columns = ddl::chain_columns(&self.chain_id_type());
        let names = columns
            .iter()
            .map(|(name, _)| quoted(name))
            .collect::<Vec<_>>()
            .join(", ");
        let body = self
            .client
            .read(format!(
                "SELECT {names} FROM {} FINAL ORDER BY {} FORMAT RowBinary",
                self.table_ref(CHAINS_TABLE),
                quoted(CHAIN_ID_COLUMN)
            ))
            .await?;
        // Every integer read as its digits, so none loses any on the way.
        let reads = columns
            .iter()
            .map(|(_, ch_type)| {
                let read = match ch_type.base() {
                    ChType::String => ReadKind::Text,
                    ChType::Bool => ReadKind::Bool,
                    ChType::DateTime64 => ReadKind::Timestamp,
                    _ => ReadKind::Text,
                };
                (ch_type.clone(), read)
            })
            .collect::<Vec<_>>();
        let cells = row_binary::decode(&body, &reads)?;
        let mut version = 0u64;
        let rows = cells
            .chunks(columns.len())
            .map(|row| {
                let text = |index: usize| -> Result<&str> {
                    match &row[index] {
                        Cell::Str(text) => Ok(text),
                        other => bail!("Unexpected {other:?} in column {}", columns[index].0),
                    }
                };
                let int = |index: usize| -> Result<i64> { Ok(text(index)?.parse()?) };
                let optional_int = |index: usize| -> Result<Option<i32>> {
                    match &row[index] {
                        Cell::Null => Ok(None),
                        _ => Ok(Some(text(index)?.parse()?)),
                    }
                };
                let millis = |index: usize| match &row[index] {
                    Cell::Timestamp(ms) => Some(*ms),
                    _ => None,
                };
                version = version.max(text(2)?.parse()?);
                Ok(ChainRow {
                    id: int(0)?,
                    checkpoint_id: int(1)?,
                    ecosystem: text(3)?.to_string(),
                    start_block: int(4)? as i32,
                    end_block: optional_int(5)?,
                    max_reorg_depth: int(6)? as i32,
                    buffer_block: int(7)? as i32,
                    source_block: int(8)? as i32,
                    first_event_block: optional_int(9)?,
                    ready_at: millis(10),
                    events_processed: int(11)? as f64,
                    is_hyper_sync: matches!(row[12], Cell::Bool(true)),
                    progress_block: int(13)? as i32,
                    progress_block_time: millis(14).map(|ms| ms / 1000.0),
                })
            })
            .collect::<Result<Vec<_>>>()?;
        Ok((rows, version))
    }

    async fn load_chains(&self) -> Result<()> {
        let (rows, version) = self.read_chains().await?;
        *self.chains.lock().unwrap() = Chains {
            rows: rows.into_iter().map(|row| (row.id, row)).collect(),
            version,
        };
        Ok(())
    }

    /// The addresses each chain has registered, as of its frontier.
    async fn read_addresses(&self, only_config: bool) -> Result<ResultSet> {
        let frontier = self.frontier();
        let config_only = if only_config {
            format!(" AND `registration_block` = {CONFIG_REGISTRATION_BLOCK}")
        } else {
            String::new()
        };
        let body = self
            .client
            .read(format!(
                "SELECT `chain_id`, `address`, `contract_id`, `registration_block` FROM (SELECT \
                 `chain_id`, `address`, `contract_id`, `registration_block`, {change} FROM {} \
                 WHERE {checkpoint} <= {}{config_only} ORDER BY `chain_id`, `address`, \
                 `contract_id`, {checkpoint} DESC LIMIT 1 BY `chain_id`, `address`, \
                 `contract_id`) WHERE {change} = {} FORMAT RowBinary",
                self.table_ref(ADDRESSES_TABLE),
                frontier_of(Some(CHAIN_ID_COLUMN), &frontier),
                literal(SET),
                change = quoted(CHANGE_COLUMN),
                checkpoint = quoted(CHECKPOINT_ID_COLUMN),
            ))
            .await?;
        let chain_id_type = self.chain_id_type();
        let cells = row_binary::decode(
            &body,
            &[
                (chain_id_type, self.chain_id_read()),
                (ChType::Bytes, ReadKind::Bytes),
                (ChType::Int32, ReadKind::Float),
                (ChType::Int32, ReadKind::Float),
            ],
        )?;
        rows::lay_out(
            &cells,
            vec![
                ColumnRead::scalar("chainId", self.chain_id_read()),
                ColumnRead::scalar("address", ReadKind::Bytes),
                ColumnRead::scalar("contractId", ReadKind::Float),
                ColumnRead::scalar("registrationBlock", ReadKind::Float),
            ],
        )
    }

    /// The rollback markers' ranges, as a ClickHouse array of `(chain, target,
    /// marker)`: a checkpoint inside one was orphaned by that rollback.
    fn rolled_back(&self) -> String {
        format!(
            "arrayExists(envio_marker -> envio_marker.1 = {chain} AND {id} > envio_marker.2 AND \
             {id} < envio_marker.3, (SELECT groupArray(({chain}, assumeNotNull({target}), {id})) \
             FROM {} WHERE {target} IS NOT NULL))",
            self.table_ref(CHECKPOINTS_TABLE),
            chain = quoted(CHAIN_ID_COLUMN),
            id = quoted(ID_COLUMN),
            target = quoted(ROLLBACK_TARGET_COLUMN),
        )
    }

    /// The checkpoints that stand: committed, not a marker, not orphaned by a
    /// rollback.
    fn standing_checkpoints(&self, frontier: &Frontier) -> String {
        format!(
            "{} <= {} AND {} IS NULL AND NOT {}",
            quoted(ID_COLUMN),
            frontier_of(Some(CHAIN_ID_COLUMN), frontier),
            quoted(ROLLBACK_TARGET_COLUMN),
            self.rolled_back()
        )
    }

    /// The checkpoints a reorg could still roll back to, the safe block's own
    /// included so the safe checkpoint can be tracked from it.
    async fn read_reorg_checkpoints(&self, rows: &[ChainRow]) -> Result<Vec<ReorgCheckpoint>> {
        let reachable = rows
            .iter()
            .filter(|row| {
                row.max_reorg_depth > 0
                    && row.progress_block > row.source_block - row.max_reorg_depth
            })
            .map(|row| {
                format!(
                    "({} = {} AND {} >= {})",
                    quoted(CHAIN_ID_COLUMN),
                    row.id,
                    quoted(ddl::BLOCK_NUMBER_COLUMN),
                    row.source_block - row.max_reorg_depth
                )
            })
            .collect::<Vec<_>>();
        if reachable.is_empty() {
            return Ok(Vec::new());
        }
        let frontier = rows.iter().map(|row| (row.id, row.checkpoint_id)).collect();
        let body = self
            .client
            .read(format!(
                "SELECT {id}, {chain}, `block_number`, `block_hash` FROM {} WHERE `block_hash` IS \
                 NOT NULL AND ({}) AND {} ORDER BY {id}, {chain} LIMIT 1 BY {chain}, {id} FORMAT \
                 RowBinary",
                self.table_ref(CHECKPOINTS_TABLE),
                reachable.join(" OR "),
                self.standing_checkpoints(&frontier),
                id = quoted(ID_COLUMN),
                chain = quoted(CHAIN_ID_COLUMN),
            ))
            .await?;
        let cells = row_binary::decode(
            &body,
            &[
                (ChType::UInt64, ReadKind::Text),
                (self.chain_id_type(), ReadKind::Text),
                (ChType::Int32, ReadKind::Float),
                (ChType::Nullable(Box::new(ChType::String)), ReadKind::Text),
            ],
        )?;
        cells
            .chunks(4)
            .map(|row| match row {
                [Cell::Str(id), Cell::Str(chain_id), Cell::Num(block_number), Cell::Str(hash)] => {
                    Ok(ReorgCheckpoint {
                        id: id.parse()?,
                        chain_id: chain_id.parse()?,
                        block_number: *block_number as i32,
                        block_hash: hash.to_string(),
                    })
                }
                other => bail!("Unexpected checkpoint row {other:?}"),
            })
            .collect()
    }

    /// Trims every table holding rows stamped past `frontier`, which only a
    /// write that never committed leaves behind. A table with nothing above it
    /// is left alone: a mutation rewrites parts, and on a clean restart there
    /// is nothing to rewrite.
    /// `progress` is each driven chain's committed progress block, past which
    /// its raw events, which carry no checkpoint, were never committed.
    async fn trim_above(
        &self,
        sequence: Sequence,
        frontier: &Frontier,
        progress: &[(i64, i32)],
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
        let shared = |column: &str| match sequence {
            Sequence::SharedAcrossChains => {
                Ok(format!("{} > {}", quoted(column), bounds.shared_id()))
            }
            Sequence::PerChain => select::above(&bounds, Some(CHAIN_ID_COLUMN), column),
        };
        let mut above_by_table = tables
            .iter()
            .filter_map(|table| table.entity().map(|entity| (table, entity)))
            .map(|(table, entity)| {
                Ok((
                    table.physical.clone(),
                    select::above(
                        &bounds,
                        entity.chain_id_column.as_deref(),
                        CHECKPOINT_ID_COLUMN,
                    )?,
                ))
            })
            .collect::<Result<Vec<_>>>()?;
        if self.settings.primary {
            above_by_table.push((ADDRESSES_TABLE.to_string(), shared(CHECKPOINT_ID_COLUMN)?));
        }
        if !progress.is_empty() && self.has_table(RAW_EVENTS_TABLE).await? {
            let past = progress
                .iter()
                .map(|(chain_id, block)| {
                    format!(
                        "({} = {chain_id} AND {} > {block})",
                        quoted(CHAIN_ID_COLUMN),
                        quoted(ddl::BLOCK_NUMBER_COLUMN)
                    )
                })
                .collect::<Vec<_>>()
                .join(" OR ");
            above_by_table.push((RAW_EVENTS_TABLE.to_string(), format!("({past})")));
        }
        // The checkpoints last: a trim interrupted before them still has the
        // checkpoints saying which rows the next one must remove.
        above_by_table.push((CHECKPOINTS_TABLE.to_string(), shared(ID_COLUMN)?));

        let holding = self.tables_holding_rows_above(&above_by_table).await?;
        let (checkpoints, rest) = above_by_table
            .split_last()
            .expect("the checkpoints are always trimmed");
        try_join_all(
            rest.iter()
                .filter(|(table, _)| holding.contains(table))
                .map(|(table, above)| {
                    self.client
                        .statement(ddl::trim_table(self.database(), table, above))
                }),
        )
        .await?;
        if holding.contains(&checkpoints.0) {
            self.client
                .statement(ddl::trim_table(
                    self.database(),
                    &checkpoints.0,
                    &checkpoints.1,
                ))
                .await?;
        }
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

    async fn resume_inner(&self, input: &Resume) -> Result<Resumed> {
        let tables = input
            .tables
            .iter()
            .filter_map(|table| table.clickhouse.clone())
            .collect::<Vec<_>>();
        match &input.committed {
            // Following the store of record: its frontier is the committed one,
            // and the chains' rows take its state, frontier first so nothing
            // above it is readable while the trims run.
            Some(committed) => {
                let (_, version) = self.read_chains().await?;
                *self.chains.lock().unwrap() = Chains {
                    rows: BTreeMap::new(),
                    version,
                };
                let rows = committed
                    .iter()
                    .map(ChainRow::of_resumed)
                    .collect::<Vec<_>>();
                // No chain, no rows to hold to anything: the store of record
                // writes every chain's row in the transaction that creates its
                // schema, so an empty list means a config without chains.
                if rows.is_empty() {
                    return Ok(Resumed {
                        chains: Vec::new(),
                        addresses: rows::lay_out(&[], Vec::new())?,
                        reorg_checkpoints: Vec::new(),
                    });
                }
                let frontier: Frontier =
                    rows.iter().map(|row| (row.id, row.checkpoint_id)).collect();
                self.write_chains(rows).await?;
                self.trim_above(input.sequence, &frontier, &[], &tables)
                    .await?;
                Ok(Resumed {
                    chains: committed.clone(),
                    addresses: rows::lay_out(&[], Vec::new())?,
                    reorg_checkpoints: Vec::new(),
                })
            }
            None => {
                self.load_chains().await?;
                let rows = self.chain_rows().into_values().collect::<Vec<_>>();
                let frontier = self
                    .frontier()
                    .into_iter()
                    .filter(|(chain_id, _)| input.chain_ids.contains(chain_id))
                    .collect();
                let progress = rows
                    .iter()
                    .filter(|row| input.chain_ids.contains(&row.id))
                    .map(|row| (row.id, row.progress_block))
                    .collect::<Vec<_>>();
                self.trim_above(input.sequence, &frontier, &progress, &tables)
                    .await?;
                let (addresses, reorg_checkpoints) = futures_util::try_join!(
                    self.read_addresses(false),
                    self.read_reorg_checkpoints(&rows)
                )?;
                Ok(Resumed {
                    chains: rows.iter().map(ChainRow::resumed).collect(),
                    addresses,
                    reorg_checkpoints,
                })
            }
        }
    }

    async fn read_stored_config_inner(&self) -> Result<StoredConfigRead> {
        let info = self
            .client
            .read(format!(
                "SELECT `config` FROM {} WHERE `id` = {OWN_RECORD} FORMAT RowBinary",
                self.table_ref(INFO_TABLE)
            ))
            .await?;
        let envio_info = match row_binary::decode(&info, &[(ChType::String, ReadKind::Text)])?
            .into_iter()
            .next()
        {
            Some(Cell::Str(config)) => Some(config.into_owned()),
            _ => None,
        };
        let contracts = self
            .client
            .read(format!(
                "SELECT `name` FROM {} ORDER BY `id` FORMAT RowBinary",
                self.table_ref(CONTRACTS_TABLE)
            ))
            .await?;
        let contract_names = row_binary::decode(&contracts, &[(ChType::String, ReadKind::Text)])?
            .into_iter()
            .map(|cell| match cell {
                Cell::Str(name) => Ok(name.into_owned()),
                other => bail!("Unexpected contract name {other:?}"),
            })
            .collect::<Result<Vec<_>>>()?;
        self.load_chains().await?;
        let chains = self
            .chain_rows()
            .into_values()
            .map(|row| StoredChain {
                id: row.id,
                ecosystem: row.ecosystem,
                start_block: row.start_block,
                end_block: row.end_block,
                max_reorg_depth: row.max_reorg_depth,
            })
            .collect();
        Ok(StoredConfigRead {
            config: StoredConfig {
                envio_info,
                contract_names: Some(contract_names),
                chains,
            },
            config_addresses: self.read_addresses(true).await?,
        })
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
        let entity = table
            .entity()
            .ok_or_else(|| anyhow!("\"{}\" is not an entity table", table.name))?;
        let (removed, restored) = futures_util::try_join!(
            self.client
                .read(select::rollback_removed(self.database(), table, bounds)?),
            self.client
                .read(select::rollback_restored(self.database(), table, bounds)?),
        )?;
        let key = entity
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

    async fn rollback_target_inner(&self, chain_id: i64, block_number: i32) -> Result<Option<i64>> {
        let frontier = self.frontier();
        // Read from the newest down, in the table's own order, so the scan stops
        // at the first checkpoint that stands.
        let answer = self
            .client
            .statement(format!(
                "SELECT {id} FROM {} WHERE {chain} = {chain_id} AND `block_number` <= \
                 {block_number} AND {} ORDER BY {id} DESC LIMIT 1 FORMAT TabSeparated",
                self.table_ref(CHECKPOINTS_TABLE),
                self.standing_checkpoints(&frontier),
                id = quoted(ID_COLUMN),
                chain = quoted(CHAIN_ID_COLUMN),
            ))
            .await?;
        Ok(match answer.trim() {
            "" => None,
            id => Some(id.parse::<i64>()?),
        })
    }

    async fn rollback_progress_diff_inner(&self, bounds: &Bounds) -> Result<Vec<ProgressDiff>> {
        let frontier = self.frontier();
        // A retried insert can have written a checkpoint twice, so each is
        // counted once.
        let answer = self
            .client
            .statement(format!(
                "SELECT {chain}, sum(`events_processed`), min(`block_number`) - 1 FROM (SELECT \
                 {chain}, {id}, any(`block_number`) AS `block_number`, any(`events_processed`) AS \
                 `events_processed` FROM {} WHERE {} AND {} GROUP BY {chain}, {id}) GROUP BY \
                 {chain} FORMAT TabSeparated",
                self.table_ref(CHECKPOINTS_TABLE),
                select::above(bounds, Some(CHAIN_ID_COLUMN), ID_COLUMN)?,
                self.standing_checkpoints(&frontier),
                chain = quoted(CHAIN_ID_COLUMN),
                id = quoted(ID_COLUMN),
            ))
            .await?;
        answer
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| {
                let columns = line.split('\t').collect::<Vec<_>>();
                let [chain_id, events, block] = columns.as_slice() else {
                    bail!("Unexpected progress diff row {line:?}");
                };
                Ok(ProgressDiff {
                    chain_id: chain_id.parse()?,
                    events_processed: events.parse()?,
                    progress_block: block.parse()?,
                })
            })
            .collect()
    }

    async fn effect_cache_tables_inner(&self) -> Result<Vec<CacheTable>> {
        let answer = self
            .client
            .statement(format!(
                "SELECT `name` FROM system.tables WHERE `database` = {} AND match(`name`, \
                 '^envio_([0-9]+_)?effect_.+') ORDER BY `name` FORMAT TabSeparated",
                literal(self.database())
            ))
            .await?;
        let names = answer
            .lines()
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .map(str::to_string)
            .collect::<Vec<_>>();
        try_join_all(names.into_iter().map(|table_name| async move {
            let count = self
                .client
                .statement(format!(
                    "SELECT count() FROM {} FINAL FORMAT TabSeparated",
                    self.table_ref(&table_name)
                ))
                .await?;
            Ok(CacheTable {
                rows: count.trim().parse()?,
                table_name,
            })
        }))
        .await
    }

    async fn upload_effect_cache_inner(&self, files: &[CacheFile]) -> Result<()> {
        let topology = self.topology();
        try_join_all(files.iter().map(|file| async move {
            let table = file.table.clickhouse()?;
            self.client
                .statement(table.create(self.database(), topology)?)
                .await?;
            let body = tokio::fs::File::open(&file.path)
                .await
                .with_context(|| format!("Failed opening {}", file.path))?;
            self.client
                .send_file(
                    &format!(
                        "INSERT INTO {} FORMAT TabSeparatedWithNames",
                        self.table_ref(&table.physical)
                    ),
                    body,
                )
                .await
                .with_context(|| format!("Failed uploading {}", file.path))
        }))
        .await?;
        Ok(())
    }

    async fn dump_effect_cache_inner(&self, files: &[CacheDump]) -> Result<()> {
        try_join_all(files.iter().map(|dump| {
            let query = format!(
                "SELECT `id`, `output` FROM {} FINAL FORMAT TabSeparatedWithNames",
                self.table_ref(&dump.table_name)
            );
            async move {
                dump.replace_with(async |file| self.client.read_into(query, file).await)
                    .await
            }
        }))
        .await?;
        Ok(())
    }

    async fn update_chains(&self, update: impl Fn(&mut ChainRow) -> bool) -> Result<()> {
        self.change_chains(|chains| {
            chains
                .values_mut()
                .filter_map(|row| update(row).then_some(row.id))
                .collect()
        })
        .await
    }

    /// Whether the batch was committed: one landed but not told to commit is
    /// left above the frontier, unread and trimmed by the next resume.
    async fn write_inner(&self, batch: Batch, mut handoff: Handoff) -> Result<bool> {
        let Batch {
            rollback,
            progress,
            raw_events,
            entities,
            chain_meta,
            addresses,
            frontier,
            checkpoints,
            effect_caches,
        } = batch;

        let caches = async {
            try_join_all(effect_caches.into_iter().map(|write| async move {
                let table = write.table.clickhouse()?.clone();
                if write.create {
                    self.client
                        .statement(table.create(self.database(), self.topology())?)
                        .await?;
                }
                match write.rows {
                    crate::storage::Rows::Staged(arena) => self.insert_staged(table, arena).await,
                    crate::storage::Rows::Cells { .. } => {
                        bail!("ClickHouse rows are always staged")
                    }
                }
            }))
            .await
        };

        let committed = async {
            let mut rows: Vec<BoxFuture<'_, Result<()>>> = Vec::new();
            for write in entities {
                if let Some(arena) = write.clickhouse {
                    let table = write.table.clickhouse()?.clone();
                    rows.push(Box::pin(self.insert_staged(table, arena)));
                }
            }
            if let Some(write) = raw_events {
                let table = write.table.clickhouse()?.clone();
                let crate::storage::Rows::Staged(arena) = write.rows else {
                    bail!("ClickHouse rows are always staged");
                };
                rows.push(Box::pin(self.insert_staged(table, arena)));
            }
            // Only those a rollback can reach: one past the reorg threshold would
            // count toward a rollback's progress diff as if it could be undone.
            let mut checkpoint_rows = Self::checkpoint_values(&checkpoints.keeping_history());
            let mut address_rows = if self.settings.primary {
                Self::address_values(&addresses, SET)
            } else {
                Vec::new()
            };
            if let Some(rollback) = &rollback {
                let targets: HashMap<i64, i64> = rollback.bounds.by_chain().collect();
                let diff_ids: HashMap<i64, i64> = rollback
                    .diff_checkpoints
                    .iter()
                    .map(|diff| (diff.chain_id, diff.checkpoint_id))
                    .collect();
                for diff in &rollback.diff_checkpoints {
                    let target = match rollback.bounds.sequence {
                        Sequence::SharedAcrossChains => rollback.bounds.shared_id(),
                        Sequence::PerChain => *targets.get(&diff.chain_id).ok_or_else(|| {
                            anyhow!(
                                "The rollback has a diff for chain {} but no bound for it",
                                diff.chain_id
                            )
                        })?,
                    };
                    checkpoint_rows.push(Self::marker_values(diff, target));
                }
                if self.settings.primary {
                    let mut removed = rollback.removed_addresses.clone();
                    removed.checkpoint_ids = removed
                        .chain_ids
                        .iter()
                        .map(|chain_id| {
                            diff_ids.get(chain_id).copied().ok_or_else(|| {
                                anyhow!(
                                    "The rollback dropped an address on chain {chain_id} without \
                                     a diff checkpoint for it"
                                )
                            })
                        })
                        .collect::<Result<_>>()?;
                    // Removals before the batch's own registrations: an address
                    // registered again is stamped with a later checkpoint.
                    let mut ordered = Self::address_values(&removed, DELETE);
                    ordered.append(&mut address_rows);
                    address_rows = ordered;
                }
            }
            rows.push(Box::pin(self.insert_checkpoints(checkpoint_rows)));
            if !address_rows.is_empty() {
                rows.push(Box::pin(self.insert_addresses(address_rows)));
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
        };

        let (committed, cached) = tokio::join!(committed, caches);
        let committed = committed?;
        cached?;
        Ok(committed)
    }
}

impl Backend for Storage {
    fn store(&self) -> Store {
        Store::ClickHouse
    }

    fn check_for_initialize(&self) -> Op<'_, ()> {
        Box::pin(self.check_for_initialize_inner())
    }

    fn initialize<'a>(&'a self, input: &'a Initialize) -> Op<'a, ()> {
        Box::pin(async move {
            self.initialize_inner(input)
                .await
                .context("Failed to initialize ClickHouse storage")
        })
    }

    fn add_chain<'a>(&'a self, input: &'a AddChain) -> Op<'a, ()> {
        Box::pin(async move {
            self.insert_addresses(Self::address_values(&input.addresses, SET))
                .await?;
            self.write_chains(vec![ChainRow::new(&input.chain)]).await
        })
    }

    fn read_stored_config(&self) -> Op<'_, StoredConfigRead> {
        Box::pin(async move {
            self.read_stored_config_inner()
                .await
                .map_err(|err| self.reinitialize_if_gone(err))
        })
    }

    fn resume<'a>(&'a self, input: &'a Resume) -> Op<'a, Resumed> {
        Box::pin(async move {
            self.resume_inner(input)
                .await
                .map_err(|err| self.reinitialize_if_gone(err))
                .context("Failed to resume ClickHouse storage")
        })
    }

    fn load_where<'a>(
        &'a self,
        table: &'a crate::storage::Table,
        conditions: Vec<Condition>,
    ) -> Op<'a, ResultSet> {
        Box::pin(self.load_where_inner(table, conditions))
    }

    fn set_chain_meta<'a>(&'a self, chains: &'a [ChainMeta]) -> Op<'a, ()> {
        Box::pin(async move {
            let by_chain: HashMap<i64, &ChainMeta> =
                chains.iter().map(|meta| (meta.chain_id, meta)).collect();
            self.update_chains(|row| match by_chain.get(&row.id) {
                Some(meta) => {
                    row.apply_meta(meta);
                    true
                }
                None => false,
            })
            .await
        })
    }

    fn finalize_backfill<'a>(
        &'a self,
        _indexes: Vec<IndexDefinition>,
        chain_ids: &'a [i64],
        ready_at: f64,
    ) -> Op<'a, ()> {
        Box::pin(async move {
            // A chain keeps the time it first caught up at.
            self.update_chains(|row| {
                if chain_ids.contains(&row.id) && row.ready_at.is_none() {
                    row.ready_at = Some(ready_at);
                    true
                } else {
                    false
                }
            })
            .await
        })
    }

    /// Nothing to prune: the history is what every read resolves the entities
    /// from, and the checkpoints are what maps it back to blocks.
    fn prune_checkpoints<'a>(&'a self, bounds: &'a Bounds) -> Op<'a, ()> {
        Box::pin(async move {
            // A marker below the bound only names checkpoints below it too.
            self.client
                .statement(format!(
                    "DELETE FROM {}{} WHERE {}",
                    self.table_ref(CHECKPOINTS_TABLE),
                    self.topology().on_cluster(),
                    select::below(bounds, Some(CHAIN_ID_COLUMN), ID_COLUMN)?
                ))
                .await?;
            Ok(())
        })
    }

    fn prune_history<'a>(
        &'a self,
        _table: &'a crate::storage::Table,
        _bounds: &'a Bounds,
    ) -> Op<'a, ()> {
        Box::pin(async { Ok(()) })
    }

    fn rollback_target_checkpoint(&self, chain_id: i64, block_number: i32) -> Op<'_, Option<i64>> {
        Box::pin(self.rollback_target_inner(chain_id, block_number))
    }

    fn rollback_progress_diff<'a>(&'a self, bounds: &'a Bounds) -> Op<'a, Vec<ProgressDiff>> {
        Box::pin(self.rollback_progress_diff_inner(bounds))
    }

    fn rollback_data<'a>(
        &'a self,
        table: &'a crate::storage::Table,
        bounds: &'a Bounds,
    ) -> Op<'a, (ResultSet, ResultSet)> {
        Box::pin(self.rollback_data_inner(table, bounds))
    }

    fn effect_cache_tables(&self) -> Op<'_, Vec<CacheTable>> {
        Box::pin(self.effect_cache_tables_inner())
    }

    fn upload_effect_cache<'a>(&'a self, files: &'a [CacheFile]) -> Op<'a, ()> {
        Box::pin(self.upload_effect_cache_inner(files))
    }

    fn dump_effect_cache<'a>(&'a self, files: &'a [CacheDump]) -> Op<'a, ()> {
        Box::pin(self.dump_effect_cache_inner(files))
    }

    /// Empties the database rather than dropping it, so one the operator
    /// provisioned keeps its engine and grants.
    fn reset(&self) -> Op<'_, ()> {
        Box::pin(async move {
            self.check_for_initialize_inner().await?;
            self.reset_database(self.topology()).await?;
            *self.chains.lock().unwrap() = Chains::default();
            Ok(())
        })
    }

    fn write_batch(
        &self,
        batch: Batch,
        handoff: Handoff,
    ) -> BoxFuture<'_, std::result::Result<(), WriteError>> {
        Box::pin(async move {
            match self.write_inner(batch, handoff).await {
                Ok(true) => Ok(()),
                Ok(false) => Err(WriteError::Gated),
                Err(error) => Err(WriteError::Failed(Failure::new(
                    "Failed to write a batch to ClickHouse",
                    error,
                ))),
            }
        })
    }

    fn close(&self) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clickhouse::mock_server::MockClickHouse;
    use crate::clickhouse::table::test_support::{column, entity_input};
    use crate::storage::types::Frontier;
    use crate::storage::EntityWrite;
    use pretty_assertions::assert_eq;

    fn storage_at(server: &MockClickHouse, primary: bool) -> Storage {
        Storage::new(
            crate::clickhouse::client::test_support::connection(server.url.clone()),
            Tuning::default(),
            Arc::new(|_: &str| {}),
            Settings {
                chain_id_mode: ChainIdMode::Int32,
                replicated: false,
                database_engine: None,
                primary,
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
        let storage = storage_at(&server, true);

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
                (
                    200,
                    "envio_history_Account\nenvio_checkpoints\nraw_events".to_string(),
                )
            } else {
                (200, String::new())
            }
        }))
        .await;
        let storage = storage_at(&server, true);

        assert_eq!(
            storage
                .check_for_initialize()
                .await
                .map_err(|error| format!("{error:#}")),
            Ok(())
        );
    }

    /// Metadata is written on a throttle of its own, alongside the
    /// finalization that marks a chain ready, and each rewrites the chain's
    /// whole row. Started from the same row, the later would undo the
    /// earlier's fields, and tie with its version, which leaves the server to
    /// keep either.
    #[tokio::test(flavor = "multi_thread")]
    async fn overlapping_chain_writes_build_on_each_other() {
        let server =
            MockClickHouse::answering_statements(Arc::new(|_: &str| (200, String::new()))).await;
        let storage = storage_at(&server, true);
        initialize(&storage, Vec::new()).await;

        let meta = [ChainMeta {
            chain_id: 1,
            first_event_block: Some(5),
            buffer_block: 10,
            ready_at: None,
            is_hyper_sync: true,
        }];
        let (ready, metadata) = tokio::join!(
            storage.finalize_backfill(Vec::new(), &[1], 1_000.0),
            storage.set_chain_meta(&meta)
        );

        let chains = storage.chains.lock().unwrap();
        let row = &chains.rows[&1];
        assert_eq!(
            (
                ready.is_ok(),
                metadata.is_ok(),
                chains.version,
                row.ready_at,
                row.buffer_block
            ),
            (true, true, 3, Some(1_000.0), 10)
        );
    }

    /// The chains' rows are what make a write readable, so they go only once
    /// every row they cover has landed.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_write_commits_with_its_chains_rows_last() {
        let server =
            MockClickHouse::answering_statements(Arc::new(|_: &str| (200, String::new()))).await;
        let storage = storage_at(&server, true);
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
                    rollback: None,
                    progress: Vec::new(),
                    raw_events: None,
                    entities: vec![EntityWrite {
                        table: account,
                        chain_id: None,
                        postgres: None,
                        clickhouse: Some(arena),
                    }],
                    chain_meta: Vec::new(),
                    addresses: Addresses::default(),
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
                    effect_caches: Vec::new(),
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
    async fn a_follower_resuming_after_a_clean_stop_rewrites_nothing() {
        let server = MockClickHouse::answering_statements(Arc::new(|statement: &str| {
            if statement.contains("_envio_holds") {
                (
                    200,
                    "envio_history_Account\t0\nenvio_checkpoints\t0".to_string(),
                )
            } else {
                (200, String::new())
            }
        }))
        .await;
        let storage = storage_at(&server, false);
        let account = account(&storage);
        storage
            .resume(&Resume {
                // A cross-chain entity has no chain column, which only a
                // shared sequence bounds.
                sequence: Sequence::SharedAcrossChains,
                tables: vec![account],
                chain_ids: vec![1],
                committed: Some(vec![ResumedChain {
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
                }]),
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
