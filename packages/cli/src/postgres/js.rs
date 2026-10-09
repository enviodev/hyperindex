use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;
use std::sync::Mutex;

use napi::bindgen_prelude::{ArrayBuffer, Buffer, Object, Promise, PromiseRaw};
use napi::threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode};
use napi::{Env, Status};
use napi_derive::napi;

use crate::columnar::{self, Arena, ColumnKind};

use super::client::{self, PgConnectionOptions, SslSetting};
use super::ddl::{ColumnSpec, TableSpec};
use super::error::to_napi;
use super::history::Sequence;
use super::index_definition::{Direction, IndexColumn, IndexDefinition, BTREE};
use super::indexes::{Coverage, IndexEvent, Purpose};
use super::internal::ChainConfig;
use super::param::Param;
use super::pg_type::{ChainIdMode, FieldType};
use super::rows;
use super::storage::{
    self, Addresses, Batch, BatchError, Bounds, CacheFile, ChainMeta, Checkpoints,
    EffectCacheWrite, EntityWrite, Failure, Frontier, HistoryRegistration, HistoryWrite,
    Initialize, Partition, Progress, QueryRows, RollbackWrite, Rows, Storage, Table,
    TableRegistration,
};

/// One column, flattened for the boundary: napi carries no tagged union, so the
/// variant arrives as `fieldType` plus whichever of the modifiers it takes.
#[napi(object)]
pub struct PgColumnInput {
    /// The database column name, renames already resolved.
    pub name: String,
    pub field_type: String,
    pub is_array: Option<bool>,
    pub is_nullable: Option<bool>,
    pub is_primary_key: Option<bool>,
    pub default_value: Option<String>,
    /// `BigInt` and `BigDecimal` only.
    pub precision: Option<u32>,
    /// `BigDecimal` only.
    pub scale: Option<u32>,
    /// `Enum` only: the name of its Postgres type.
    pub enum_name: Option<String>,
}

impl TryFrom<PgColumnInput> for ColumnSpec {
    type Error = anyhow::Error;

    fn try_from(input: PgColumnInput) -> anyhow::Result<Self> {
        Ok(ColumnSpec {
            field_type: FieldType::parse(
                &input.field_type,
                input.precision,
                input.scale,
                input.enum_name.as_deref(),
            )?,
            name: input.name,
            is_array: input.is_array.unwrap_or(false),
            is_nullable: input.is_nullable.unwrap_or(false),
            is_primary_key: input.is_primary_key.unwrap_or(false),
            default_value: input.default_value,
        })
    }
}

#[napi(object)]
pub struct PgTableInput {
    pub table_name: String,
    /// In the order the table declares them.
    pub columns: Vec<PgColumnInput>,
    /// The columns a batch's rows carry, in the order they are laid out.
    pub write_columns: Vec<String>,
    pub partition_by_column: Option<String>,
    pub append_only: Option<bool>,
    /// An entity's history table.
    pub history_table: Option<String>,
    /// A per-chain entity's chain column.
    pub chain_id_column: Option<String>,
}

#[napi(object)]
pub struct PgRegisteredTable {
    pub handle: u32,
    /// The slot each write column travels in, for a table whose batches can be
    /// staged.
    pub kinds: Option<Vec<u8>>,
}

#[napi(object)]
pub struct PgIndexColumnInput {
    pub name: String,
    pub direction: String,
}

#[napi(object)]
pub struct PgIndexInput {
    pub table_name: String,
    pub columns: Vec<PgIndexColumnInput>,
    pub method: String,
}

impl TryFrom<PgIndexColumnInput> for IndexColumn {
    type Error = anyhow::Error;

    fn try_from(input: PgIndexColumnInput) -> anyhow::Result<Self> {
        Ok(IndexColumn {
            name: input.name,
            direction: match input.direction.as_str() {
                "Asc" => Direction::Asc,
                "Desc" => Direction::Desc,
                other => anyhow::bail!("`{other}` is not an index column direction"),
            },
        })
    }
}

impl TryFrom<PgIndexInput> for IndexDefinition {
    type Error = anyhow::Error;

    fn try_from(input: PgIndexInput) -> anyhow::Result<Self> {
        Ok(IndexDefinition {
            table_name: input.table_name,
            columns: input
                .columns
                .into_iter()
                .map(IndexColumn::try_from)
                .collect::<anyhow::Result<Vec<_>>>()?,
            method: input.method,
        })
    }
}

/// A result set laid out in the arena, waiting to be read.
///
/// The rows are not in this object: they are in arena memory, and
/// `lendResult` hands JavaScript the buffers to read them from. Only the shape
/// crosses here.
#[napi(object)]
pub struct PgQueryResult {
    pub handle: u32,
    pub names: Vec<String>,
    /// One per column, as `rows::ReadKind` ordinals. JavaScript picks the view
    /// to build over each buffer from these.
    pub kinds: Vec<u8>,
    /// What a list column's elements are, and null for a column that is not a
    /// list. A list's own ordinal says nothing about what it holds, and the
    /// element column is read exactly as a top-level one of that kind.
    pub element_kinds: Vec<Option<u8>>,
    pub rows: u32,
}

#[napi(object)]
pub struct PgStorageOptions {
    pub host: String,
    pub port: u32,
    pub user: String,
    pub password: String,
    pub database: String,
    /// As `ENVIO_PG_SSL_MODE` spells it.
    pub ssl: String,
    pub max_connections: u32,
    pub pg_schema: String,
    /// `Int32` or `Int64`.
    pub chain_id_mode: String,
    pub is_hasura_enabled: bool,
}

/// Which rows a bounded statement reaches: the chains and the checkpoint each
/// is held to.
#[napi(object)]
pub struct PgBounds {
    /// `SharedAcrossChains` or `PerChain`.
    pub sequence: String,
    pub chain_ids: Vec<f64>,
    pub checkpoint_ids: Vec<String>,
}

#[napi(object)]
pub struct PgProgress {
    pub chain_id: f64,
    pub progress_block: i32,
    pub progress_block_time: Option<f64>,
    pub events_processed: f64,
    pub source_block: i32,
}

#[napi(object)]
pub struct PgChainMeta {
    pub chain_id: f64,
    pub first_event_block: Option<i32>,
    pub buffer_block: i32,
    /// Unix milliseconds.
    pub ready_at: Option<f64>,
    pub is_hyper_sync: bool,
}

#[napi(object)]
pub struct PgAddresses {
    pub chain_ids: Vec<f64>,
    pub addresses: Vec<Buffer>,
    pub contract_ids: Vec<i32>,
    /// Left out for a key.
    pub registration_blocks: Option<Vec<i32>>,
}

#[napi(object)]
pub struct PgChainConfig {
    pub id: f64,
    pub ecosystem: String,
    pub start_block: i32,
    pub end_block: Option<i32>,
    pub max_reorg_depth: i32,
}

#[napi(object)]
pub struct PgPartition {
    pub table: u32,
    pub chain_id: f64,
    pub name: String,
}

#[napi(object)]
pub struct PgEnum {
    pub name: String,
    pub variants: Vec<String>,
}

#[napi(object)]
pub struct PgInitialize {
    pub sequence: String,
    pub is_empty_schema: bool,
    /// Every table but the indexer's own, which the storage declares itself.
    pub tables: Vec<u32>,
    pub partitions: Vec<PgPartition>,
    pub enums: Vec<PgEnum>,
    pub chains: Vec<PgChainConfig>,
    pub envio_info: String,
    pub contract_names: Vec<String>,
    pub addresses: PgAddresses,
}

#[napi(object)]
pub struct PgAddChain {
    pub chain: PgChainConfig,
    pub partitions: Vec<PgPartition>,
    pub addresses: PgAddresses,
}

#[napi(object)]
pub struct PgStoredChain {
    pub id: f64,
    pub ecosystem: String,
    pub start_block: i32,
    pub end_block: Option<i32>,
    pub max_reorg_depth: i32,
}

#[napi(object)]
pub struct PgStoredConfig {
    pub envio_info: Option<String>,
    pub contract_names: Option<Vec<String>>,
    pub chains: Vec<PgStoredChain>,
    pub config_addresses: PgQueryResult,
}

#[napi(object)]
pub struct PgResumedChain {
    pub id: f64,
    pub start_block: i32,
    pub end_block: Option<i32>,
    pub max_reorg_depth: i32,
    pub first_event_block: Option<i32>,
    /// Unix milliseconds.
    pub ready_at: Option<f64>,
    pub events_processed: f64,
    pub progress_block: i32,
    /// Unix seconds.
    pub progress_block_time: Option<f64>,
    pub source_block: i32,
    pub checkpoint_id: String,
}

#[napi(object)]
pub struct PgReorgCheckpoint {
    pub id: String,
    pub chain_id: f64,
    pub block_number: i32,
    pub block_hash: String,
}

#[napi(object)]
pub struct PgResumed {
    pub chains: Vec<PgResumedChain>,
    pub addresses: PgQueryResult,
    pub reorg_checkpoints: Vec<PgReorgCheckpoint>,
}

#[napi(object)]
pub struct PgProgressDiff {
    pub chain_id: f64,
    pub events_processed: String,
    pub progress_block: i32,
}

#[napi(object)]
pub struct PgRollbackData {
    pub removed: PgQueryResult,
    pub restored: PgQueryResult,
}

#[napi(object)]
pub struct PgCacheTable {
    pub table_name: String,
    pub rows: i32,
}

#[napi(object)]
pub struct PgCacheUpload {
    pub table: u32,
    pub path: String,
}

#[napi(object)]
pub struct PgCacheDump {
    pub table_name: String,
    pub path: String,
}

/// Rows staged into an arena, or rendered one parameter per cell, every row's
/// first column first.
#[napi(object)]
pub struct PgRows {
    pub staged: Option<u32>,
    pub cells: Option<Vec<Option<String>>>,
    pub rows: u32,
}

#[napi(object)]
pub struct PgHistoryWrite {
    pub backfill: Vec<String>,
    pub sets: Option<PgRows>,
    pub set_checkpoint_ids: Vec<String>,
    pub delete_ids: Vec<String>,
    pub delete_checkpoint_ids: Vec<String>,
}

#[napi(object)]
pub struct PgEntityWrite {
    pub table: u32,
    pub chain_id: Option<f64>,
    pub sets: Option<PgRows>,
    pub deletes: Vec<String>,
    pub history: Option<PgHistoryWrite>,
}

#[napi(object)]
pub struct PgRollbackWrite {
    pub bounds: PgBounds,
    pub histories: Vec<u32>,
    pub progress: Vec<PgProgress>,
    pub removed_addresses: PgAddresses,
}

#[napi(object)]
pub struct PgCheckpoints {
    pub ids: Vec<String>,
    pub chain_ids: Vec<f64>,
    pub block_numbers: Vec<i32>,
    pub block_hashes: Vec<Option<String>>,
    pub events_processed: Vec<f64>,
}

#[napi(object)]
pub struct PgFrontier {
    pub chain_ids: Vec<f64>,
    pub checkpoint_ids: Vec<String>,
}

#[napi(object)]
pub struct PgEffectCacheWrite {
    pub table: u32,
    pub create: bool,
    pub rows: PgRows,
}

#[napi(object)]
pub struct PgTableWrite {
    pub table: u32,
    pub rows: PgRows,
}

#[napi(object)]
pub struct PgBatch {
    pub rollback: Option<PgRollbackWrite>,
    pub progress: Vec<PgProgress>,
    pub raw_events: Option<PgTableWrite>,
    pub entities: Vec<PgEntityWrite>,
    pub chain_meta: Vec<PgChainMeta>,
    pub addresses: PgAddresses,
    pub frontier: PgFrontier,
    pub checkpoints: PgCheckpoints,
    pub effect_caches: Vec<PgEffectCacheWrite>,
}

/// The indexer's storage in one Postgres schema, and the connections it runs
/// on.
#[napi]
pub struct PgStorage {
    inner: Storage,
    /// Result sets handed out but not yet read and released. An entry lives
    /// only between the call that returned it and `releaseResult`.
    results: Mutex<HashMap<u32, Arena>>,
    /// Batches lent to JavaScript to fill, and then waiting to be written.
    staged: columnar::js::Stages<Arc<Table>>,
    next_handle: AtomicU32,
}

#[napi]
impl PgStorage {
    /// `onIndexEvent` hears what the indexes are doing, for the logs.
    #[napi(factory)]
    pub fn create(
        env: &Env,
        options: PgStorageOptions,
        mut on_index_event: ThreadsafeFunction<IndexEvent, (), IndexEvent, Status, false>,
    ) -> napi::Result<Self> {
        // Unreferenced, or a storage nobody closed would keep the process
        // from exiting. See the same call in the ClickHouse sink.
        #[allow(deprecated)]
        on_index_event.unref(env)?;
        let port = u16::try_from(options.port)
            .map_err(|_| napi::Error::from_reason(format!("`{}` is not a port", options.port)))?;
        let client = client::PgClient::connect(PgConnectionOptions {
            host: options.host,
            port,
            user: options.user.clone(),
            password: options.password,
            database: options.database,
            ssl: SslSetting::parse(&options.ssl).map_err(to_napi)?,
            max_connections: options.max_connections as usize,
            application_name: None,
            connect_timeout: std::time::Duration::from_secs(30),
        })
        .map_err(to_napi)?;
        Ok(Self {
            inner: Storage::new(
                client,
                storage::Settings {
                    pg_schema: options.pg_schema,
                    pg_user: options.user,
                    chain_id_mode: ChainIdMode::parse(&options.chain_id_mode).map_err(to_napi)?,
                    numeric_array_as_text: options.is_hasura_enabled,
                },
                Arc::new(move |event| {
                    on_index_event.call(event, ThreadsafeFunctionCallMode::NonBlocking);
                }),
            ),
            results: Mutex::new(HashMap::new()),
            staged: Default::default(),
            next_handle: AtomicU32::new(0),
        })
    }

    /// Registers a table the storage writes or creates. Its batches are staged
    /// when it has no column of arrays: unnesting one spreads it across the
    /// rows instead of keeping it as a value, so such a table binds a
    /// parameter per cell instead.
    #[napi]
    pub fn register_table(&self, table: PgTableInput) -> napi::Result<PgRegisteredTable> {
        let spec = TableSpec {
            table_name: table.table_name,
            columns: table
                .columns
                .into_iter()
                .map(ColumnSpec::try_from)
                .collect::<anyhow::Result<Vec<_>>>()
                .map_err(to_napi)?,
            partition_by_column: table.partition_by_column,
        };
        let (handle, registered) = self
            .inner
            .register(TableRegistration {
                spec,
                write_columns: table.write_columns,
                append_only: table.append_only.unwrap_or(false),
                history: table.history_table.map(|table_name| HistoryRegistration {
                    table_name,
                    chain_id_column: table.chain_id_column,
                }),
            })
            .map_err(to_napi)?;
        Ok(PgRegisteredTable {
            handle,
            kinds: registered
                .kinds
                .as_ref()
                .map(|kinds| kinds.iter().map(|&kind| kind as u8).collect()),
        })
    }

    /// Lays out a batch and lends JavaScript the memory to fill it in. Nothing
    /// may await between here and `commitStage` — see the phase rules in
    /// `columnar`.
    #[napi]
    pub fn begin_stage<'env>(
        &self,
        env: &'env Env,
        table: u32,
        rows: u32,
    ) -> napi::Result<Object<'env>> {
        let table = self.inner.table(table).map_err(to_napi)?;
        let kinds: Vec<ColumnKind> = table.kinds.clone().ok_or_else(|| {
            napi::Error::from_reason(format!(
                "\"{}\" has an array column, so its rows are bound a cell at a time",
                table.name()
            ))
        })?;
        let handle = self.next_handle.fetch_add(1, Ordering::Relaxed);
        self.staged.begin(env, handle, rows, &kinds, table)
    }

    #[napi]
    pub fn grow_stage<'env>(
        &self,
        env: &'env Env,
        handle: u32,
        column: u32,
        needed: u32,
        stale: ArrayBuffer,
    ) -> napi::Result<ArrayBuffer<'env>> {
        self.staged.grow(env, handle, column, needed, stale)
    }

    #[napi]
    pub fn commit_stage(&self, handle: u32, buffers: Vec<ArrayBuffer>) -> napi::Result<()> {
        self.staged
            .commit(handle, buffers, |table| table.write_column_names())
    }

    /// Gives up on a batch. Whatever sent the caller here is the error worth
    /// reading, so a batch that cannot be handed back is abandoned rather than
    /// reported over the top of it.
    #[napi]
    pub fn abort_stage(&self, handle: u32, buffers: Vec<ArrayBuffer>) {
        let _ = self.staged.abort(handle, buffers);
    }

    /// Frees batches that were staged for a write that never happened — one
    /// whose next table failed to convert.
    #[napi]
    pub fn discard_staged(&self, handles: Vec<u32>) {
        for handle in handles {
            let _ = self.staged.take_sealed(handle);
        }
    }

    #[napi]
    pub async fn query(
        &self,
        sql: String,
        params: Vec<Option<String>>,
    ) -> napi::Result<PgQueryResult> {
        let rows = self
            .inner
            .client
            .query(&sql, &to_params(params))
            .await
            .map_err(to_napi)?;
        self.hold(rows)
    }

    /// The buffers a result's columns live in. They stay valid until
    /// `releaseResult` takes them back, and reading through one after that is
    /// what detaching prevents.
    #[napi]
    pub fn lend_result<'env>(
        &self,
        env: &'env Env,
        handle: u32,
    ) -> napi::Result<Vec<ArrayBuffer<'env>>> {
        let mut results = self.results.lock().unwrap();
        let arena = results
            .get_mut(&handle)
            .ok_or_else(|| napi::Error::from_reason(format!("Unknown result {handle}")))?;
        let lent = columnar::js::lend_for_reading(env, arena);
        if lent.is_err() {
            drop_unless_lent(&mut results, handle);
        }
        lent
    }

    /// Detaches a result's buffers and frees it. A result that cannot hand them
    /// all back still has a JavaScript view into its memory, so that memory is
    /// abandoned rather than freed.
    #[napi]
    pub fn release_result(&self, handle: u32, buffers: Vec<ArrayBuffer>) -> napi::Result<()> {
        let mut results = self.results.lock().unwrap();
        let Some(arena) = results.get_mut(&handle) else {
            return Ok(());
        };
        match columnar::js::detach_all(arena, buffers) {
            Ok(()) => {
                results.remove(&handle);
                Ok(())
            }
            Err(failed) => {
                std::mem::forget(results.remove(&handle));
                Err(failed)
            }
        }
    }

    #[napi]
    pub async fn is_initialized(&self) -> napi::Result<bool> {
        self.inner.is_initialized().await.map_err(to_napi)
    }

    /// Whether the schema is empty, refusing one that holds anything but an
    /// indexer's tables.
    #[napi]
    pub async fn check_schema_for_initialize(&self) -> napi::Result<bool> {
        self.inner
            .check_schema_for_initialize()
            .await
            .map_err(to_napi)
    }

    #[napi]
    pub async fn initialize(&self, input: PgInitialize) -> napi::Result<()> {
        let input = Initialize {
            sequence: Sequence::parse(&input.sequence).map_err(to_napi)?,
            is_empty_schema: input.is_empty_schema,
            tables: self.tables(&input.tables)?,
            partitions: self.partitions(input.partitions)?,
            enums: input
                .enums
                .into_iter()
                .map(|enum_type| storage::Enum {
                    name: enum_type.name,
                    variants: enum_type.variants,
                })
                .collect(),
            chains: input.chains.into_iter().map(chain_config).collect(),
            envio_info: input.envio_info,
            contract_names: input.contract_names,
            addresses: addresses(input.addresses),
        };
        self.inner.initialize(input).await.map_err(to_napi)
    }

    #[napi]
    pub async fn add_chain(&self, input: PgAddChain) -> napi::Result<()> {
        let input = storage::AddChain {
            chain: chain_config(input.chain),
            partitions: self.partitions(input.partitions)?,
            addresses: addresses(input.addresses),
        };
        self.inner.add_chain(input).await.map_err(to_napi)
    }

    #[napi]
    pub async fn read_stored_config(&self) -> napi::Result<PgStoredConfig> {
        let (config, addresses) = self.inner.read_stored_config().await.map_err(to_napi)?;
        Ok(PgStoredConfig {
            envio_info: config.envio_info,
            contract_names: config.contract_names,
            chains: config
                .chains
                .into_iter()
                .map(|chain| PgStoredChain {
                    id: chain.id,
                    ecosystem: chain.ecosystem,
                    start_block: chain.start_block,
                    end_block: chain.end_block,
                    max_reorg_depth: chain.max_reorg_depth,
                })
                .collect(),
            config_addresses: self.hold(addresses)?,
        })
    }

    #[napi]
    pub async fn resume(&self) -> napi::Result<PgResumed> {
        let (chains, addresses, checkpoints) = self.inner.resume().await.map_err(to_napi)?;
        Ok(PgResumed {
            chains: chains
                .into_iter()
                .map(|chain| PgResumedChain {
                    id: chain.id,
                    start_block: chain.start_block,
                    end_block: chain.end_block,
                    max_reorg_depth: chain.max_reorg_depth,
                    first_event_block: chain.first_event_block,
                    ready_at: chain.ready_at,
                    events_processed: chain.events_processed,
                    progress_block: chain.progress_block,
                    progress_block_time: chain.progress_block_time,
                    source_block: chain.source_block,
                    checkpoint_id: chain.checkpoint_id,
                })
                .collect(),
            addresses: self.hold(addresses)?,
            reorg_checkpoints: checkpoints
                .into_iter()
                .map(|checkpoint| PgReorgCheckpoint {
                    id: checkpoint.id,
                    chain_id: checkpoint.chain_id,
                    block_number: checkpoint.block_number,
                    block_hash: checkpoint.block_hash,
                })
                .collect(),
        })
    }

    #[napi]
    pub async fn set_chain_meta(&self, chains: Vec<PgChainMeta>) -> napi::Result<()> {
        let chains = chains.into_iter().map(chain_meta).collect::<Vec<_>>();
        self.inner.set_chain_meta(&chains).await.map_err(to_napi)
    }

    /// `readyAt` in unix milliseconds.
    #[napi]
    pub async fn finalize_backfill(
        &self,
        definitions: Vec<PgIndexInput>,
        chain_ids: Vec<f64>,
        ready_at: f64,
    ) -> napi::Result<()> {
        let definitions = definitions_of(definitions)?;
        let chain_ids = chain_ids.into_iter().map(chain_id).collect::<Vec<_>>();
        self.inner
            .finalize_backfill(definitions, &chain_ids, ready_at)
            .await
            .map_err(to_napi)
    }

    /// Restores whatever the schema promises and the database no longer has.
    /// Never rejects: a failed build is reported, and its queries run
    /// unindexed until the next restart.
    #[napi]
    pub async fn ensure_schema_indexes(&self, definitions: Vec<PgIndexInput>) -> napi::Result<()> {
        let definitions = definitions_of(definitions)?;
        self.inner
            .indexes
            .ensure(definitions, Purpose::Schema)
            .await;
        Ok(())
    }

    /// The single-column indexes a getWhere on `columns` wants. Null when the
    /// catalog already covers them, which is every call but the first: this
    /// runs on every batched load, so it answers without leaving the thread.
    /// Never rejects: a failed build is reported, and the query runs without
    /// it.
    #[napi]
    pub fn ensure_query_indexes<'env>(
        &self,
        env: &'env Env,
        table_name: String,
        columns: Vec<String>,
    ) -> napi::Result<Option<PromiseRaw<'env, ()>>> {
        let definitions = columns
            .into_iter()
            .map(|name| IndexDefinition {
                table_name: table_name.clone(),
                columns: vec![IndexColumn {
                    name,
                    direction: Direction::Asc,
                }],
                method: BTREE.to_string(),
            })
            .collect::<Vec<_>>();
        let indexes = &self.inner.indexes;
        if indexes.covers_all(&definitions, Coverage::LeadingColumns) {
            return Ok(None);
        }
        let indexes = indexes.clone();
        env.spawn_future(async move {
            indexes.ensure(definitions, Purpose::Query).await;
            Ok(())
        })
        .map(Some)
    }

    #[napi]
    pub async fn prune_checkpoints(&self, bounds: PgBounds) -> napi::Result<()> {
        let bounds = to_bounds(bounds)?;
        self.inner.prune_checkpoints(&bounds).await.map_err(to_napi)
    }

    #[napi]
    pub async fn prune_history(&self, table: u32, bounds: PgBounds) -> napi::Result<()> {
        let table = self.inner.table(table).map_err(to_napi)?;
        let bounds = to_bounds(bounds)?;
        self.inner
            .prune_history(&table, &bounds)
            .await
            .map_err(to_napi)
    }

    #[napi]
    pub async fn rollback_target_checkpoint(
        &self,
        chain_id: f64,
        block_number: i32,
    ) -> napi::Result<Option<String>> {
        self.inner
            .rollback_target_checkpoint(self::chain_id(chain_id), block_number)
            .await
            .map_err(to_napi)
    }

    #[napi]
    pub async fn rollback_progress_diff(
        &self,
        bounds: PgBounds,
    ) -> napi::Result<Vec<PgProgressDiff>> {
        let bounds = to_bounds(bounds)?;
        Ok(self
            .inner
            .rollback_progress_diff(&bounds)
            .await
            .map_err(to_napi)?
            .into_iter()
            .map(|diff| PgProgressDiff {
                chain_id: diff.chain_id,
                events_processed: diff.events_processed,
                progress_block: diff.progress_block,
            })
            .collect())
    }

    #[napi]
    pub async fn rollback_data(
        &self,
        table: u32,
        bounds: PgBounds,
    ) -> napi::Result<PgRollbackData> {
        let table = self.inner.table(table).map_err(to_napi)?;
        let bounds = to_bounds(bounds)?;
        let (removed, restored) = self
            .inner
            .rollback_data(&table, &bounds)
            .await
            .map_err(to_napi)?;
        let removed = self.hold(removed)?;
        let restored = self.hold(restored).inspect_err(|_| {
            self.results.lock().unwrap().remove(&removed.handle);
        })?;
        Ok(PgRollbackData { removed, restored })
    }

    #[napi]
    pub async fn effect_cache_tables(&self) -> napi::Result<Vec<PgCacheTable>> {
        Ok(self
            .inner
            .effect_cache_tables()
            .await
            .map_err(to_napi)?
            .into_iter()
            .map(|table| PgCacheTable {
                table_name: table.table_name,
                rows: table.rows,
            })
            .collect())
    }

    #[napi]
    pub async fn upload_effect_cache(&self, files: Vec<PgCacheUpload>) -> napi::Result<()> {
        let files = files
            .into_iter()
            .map(|file| {
                Ok(CacheFile {
                    table: self.inner.table(file.table).map_err(to_napi)?,
                    path: file.path,
                })
            })
            .collect::<napi::Result<Vec<_>>>()?;
        self.inner
            .upload_effect_cache(&files)
            .await
            .map_err(to_napi)
    }

    #[napi]
    pub async fn dump_effect_cache(&self, files: Vec<PgCacheDump>) -> napi::Result<()> {
        let files = files
            .into_iter()
            .map(|file| (file.table_name, file.path))
            .collect::<Vec<_>>();
        self.inner.dump_effect_cache(&files).await.map_err(to_napi)
    }

    #[napi]
    pub async fn reset(&self) -> napi::Result<()> {
        self.inner.reset().await.map_err(to_napi)
    }

    /// Writes a batch in one transaction. `sink` settles once the sink has
    /// written its half: `true` lets the batch commit, `false` rolls it back
    /// and rejects with `SinkFailed`, the sink's own error staying with the
    /// caller.
    ///
    /// A failed statement rejects with what it was doing as the message, and
    /// the server's error as the `cause`.
    #[napi]
    pub async fn write_batch(
        &self,
        batch: PgBatch,
        sink: Option<Promise<bool>>,
    ) -> napi::Result<()> {
        let batch = self.to_batch(batch)?;
        let sink =
            sink.map(|sink| Box::pin(async move { sink.await.unwrap_or(false) }) as storage::Sink);
        match self.inner.write_batch(batch, sink).await {
            Ok(()) => Ok(()),
            Err(BatchError::SinkFailed) => Err(napi::Error::from_reason("SinkFailed")),
            Err(BatchError::Failed(Failure { context, error })) => {
                let mut failed = napi::Error::from_reason(context);
                failed.set_cause(to_napi(error));
                Err(failed)
            }
        }
    }

    /// Closes the pool.
    #[napi]
    pub async fn close(&self) {
        self.inner.client.close();
    }
}

fn definitions_of(definitions: Vec<PgIndexInput>) -> napi::Result<Vec<IndexDefinition>> {
    definitions
        .into_iter()
        .map(IndexDefinition::try_from)
        .collect::<anyhow::Result<Vec<_>>>()
        .map_err(to_napi)
}

impl PgStorage {
    fn hold(&self, (rows, columns): QueryRows) -> napi::Result<PgQueryResult> {
        let types = columns
            .iter()
            .map(|column| column.ty.clone())
            .collect::<Vec<_>>();
        let arena = rows::into_arena(&rows, &types).map_err(to_napi)?;
        let result = PgQueryResult {
            handle: self.next_handle.fetch_add(1, Ordering::Relaxed),
            names: columns.into_iter().map(|column| column.name).collect(),
            kinds: types
                .iter()
                .map(|ty| rows::column_read_kind(ty) as u8)
                .collect(),
            element_kinds: types.iter().map(rows::element_read_kind).collect(),
            rows: arena.rows() as u32,
        };
        self.results.lock().unwrap().insert(result.handle, arena);
        Ok(result)
    }

    fn tables(&self, handles: &[u32]) -> napi::Result<Vec<Arc<Table>>> {
        handles
            .iter()
            .map(|&handle| self.inner.table(handle).map_err(to_napi))
            .collect()
    }

    fn partitions(&self, partitions: Vec<PgPartition>) -> napi::Result<Vec<Partition>> {
        partitions
            .into_iter()
            .map(|partition| {
                Ok(Partition {
                    table: self.inner.table(partition.table).map_err(to_napi)?,
                    chain_id: chain_id(partition.chain_id),
                    name: partition.name,
                })
            })
            .collect()
    }

    /// Takes every batch a write names out of the registry before anything
    /// can fail, so a write refused here frees them rather than leaving them
    /// for a `discardStaged` nobody makes.
    fn rows(&self, rows: PgRows, taken: &mut Vec<napi::Result<()>>) -> Option<Rows> {
        match (rows.staged, rows.cells) {
            (Some(handle), _) => match self.staged.take_sealed(handle) {
                Ok(staged) => Some(Rows::Staged(staged.arena)),
                Err(error) => {
                    taken.push(Err(error));
                    None
                }
            },
            (None, Some(cells)) => Some(Rows::Cells {
                cells: to_params(cells),
                rows: rows.rows as usize,
            }),
            (None, None) => {
                taken.push(Err(napi::Error::from_reason(
                    "Rows have to be staged or given as cells",
                )));
                None
            }
        }
    }

    fn to_batch(&self, batch: PgBatch) -> napi::Result<Batch> {
        let mut problems = Vec::new();
        let table = |handle: u32, problems: &mut Vec<napi::Result<()>>| {
            self.inner
                .table(handle)
                .map_err(|error| problems.push(Err(to_napi(error))))
                .ok()
        };
        let raw_events = batch.raw_events.and_then(|write| {
            let rows = self.rows(write.rows, &mut problems)?;
            Some((table(write.table, &mut problems)?, rows))
        });
        let entities = batch
            .entities
            .into_iter()
            .filter_map(|write| {
                let sets = write.sets.map(|rows| self.rows(rows, &mut problems));
                let history = write.history.map(|history| HistoryWrite {
                    backfill: history.backfill,
                    sets: history.sets.and_then(|rows| {
                        Some((self.rows(rows, &mut problems)?, history.set_checkpoint_ids))
                    }),
                    delete_ids: history.delete_ids,
                    delete_checkpoint_ids: history.delete_checkpoint_ids,
                });
                Some(EntityWrite {
                    table: table(write.table, &mut problems)?,
                    chain_id: write.chain_id.map(chain_id),
                    sets: sets.flatten(),
                    deletes: write.deletes,
                    history,
                })
            })
            .collect();
        let effect_caches = batch
            .effect_caches
            .into_iter()
            .filter_map(|write| {
                let rows = self.rows(write.rows, &mut problems)?;
                Some(EffectCacheWrite {
                    table: table(write.table, &mut problems)?,
                    create: write.create,
                    rows,
                })
            })
            .collect();
        let rollback = batch
            .rollback
            .map(|rollback| -> napi::Result<RollbackWrite> {
                Ok(RollbackWrite {
                    bounds: to_bounds(rollback.bounds)?,
                    histories: self.tables(&rollback.histories)?,
                    progress: rollback.progress.into_iter().map(progress).collect(),
                    removed_addresses: addresses(rollback.removed_addresses),
                })
            });
        if let Some(Err(error)) = problems.into_iter().find(|problem| problem.is_err()) {
            return Err(error);
        }
        Ok(Batch {
            rollback: rollback.transpose()?,
            progress: batch.progress.into_iter().map(progress).collect(),
            raw_events,
            entities,
            chain_meta: batch.chain_meta.into_iter().map(chain_meta).collect(),
            addresses: addresses(batch.addresses),
            frontier: Frontier {
                chain_ids: batch.frontier.chain_ids.into_iter().map(chain_id).collect(),
                checkpoint_ids: batch.frontier.checkpoint_ids,
            },
            checkpoints: Checkpoints {
                ids: batch.checkpoints.ids,
                chain_ids: batch
                    .checkpoints
                    .chain_ids
                    .into_iter()
                    .map(chain_id)
                    .collect(),
                block_numbers: batch.checkpoints.block_numbers,
                block_hashes: batch.checkpoints.block_hashes,
                events_processed: batch
                    .checkpoints
                    .events_processed
                    .into_iter()
                    .map(|count| count as i64)
                    .collect(),
            },
            effect_caches,
        })
    }
}

/// Chain ids reach here as JavaScript numbers, every one of them a safe
/// integer.
fn chain_id(id: f64) -> i64 {
    id as i64
}

fn chain_config(chain: PgChainConfig) -> ChainConfig {
    ChainConfig {
        id: chain_id(chain.id),
        ecosystem: chain.ecosystem,
        start_block: chain.start_block,
        end_block: chain.end_block,
        max_reorg_depth: chain.max_reorg_depth,
    }
}

fn progress(progress: PgProgress) -> Progress {
    Progress {
        chain_id: chain_id(progress.chain_id),
        progress_block: progress.progress_block,
        progress_block_time: progress.progress_block_time,
        events_processed: progress.events_processed,
        source_block: progress.source_block,
    }
}

fn chain_meta(meta: PgChainMeta) -> ChainMeta {
    ChainMeta {
        chain_id: chain_id(meta.chain_id),
        first_event_block: meta.first_event_block,
        buffer_block: meta.buffer_block,
        ready_at: meta.ready_at,
        is_hyper_sync: meta.is_hyper_sync,
    }
}

fn addresses(addresses: PgAddresses) -> Addresses {
    Addresses {
        chain_ids: addresses.chain_ids.into_iter().map(chain_id).collect(),
        addresses: addresses
            .addresses
            .into_iter()
            .map(|bytes| bytes.to_vec())
            .collect(),
        contract_ids: addresses.contract_ids,
        registration_blocks: addresses.registration_blocks.unwrap_or_default(),
    }
}

fn to_bounds(bounds: PgBounds) -> napi::Result<Bounds> {
    Ok(Bounds {
        sequence: Sequence::parse(&bounds.sequence).map_err(to_napi)?,
        chain_ids: bounds.chain_ids.into_iter().map(chain_id).collect(),
        checkpoint_ids: bounds
            .checkpoint_ids
            .iter()
            .map(|id| {
                id.parse::<i64>()
                    .map_err(|_| napi::Error::from_reason(format!("`{id}` is not a checkpoint id")))
            })
            .collect::<napi::Result<_>>()?,
    })
}

fn to_params(params: Vec<Option<String>>) -> Vec<Param> {
    params
        .into_iter()
        .map(|param| match param {
            None => Param::Null,
            Some(text) => Param::Text(text),
        })
        .collect()
}

/// After a failed lend. A result already lent out still has JavaScript views
/// into it, and only `releaseResult` may free it, having detached them; one
/// that never reached JavaScript has nothing pointing into it and goes now.
fn drop_unless_lent(results: &mut HashMap<u32, Arena>, handle: u32) {
    if results.get(&handle).is_some_and(|arena| !arena.is_lent()) {
        results.remove(&handle);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failed_lend_frees_only_a_result_javascript_holds_nothing_of() {
        let lent = Arena::new(1, &[ColumnKind::F64]).unwrap();
        let mut sealed = Arena::new(1, &[ColumnKind::F64]).unwrap();
        sealed.seal_for_test().unwrap();
        let mut results = HashMap::from([(1, lent), (2, sealed)]);
        drop_unless_lent(&mut results, 1);
        drop_unless_lent(&mut results, 2);
        assert_eq!(results.keys().copied().collect::<Vec<_>>(), vec![1]);
    }
}
