//! The storage as JavaScript sees it: one class over every configured store.
//!
//! Rows cross in arenas both ways. A write stages its rows into memory the
//! addon lends (`beginStage` to `commitStage`); a read lands its rows in a
//! Rust-owned arena that `lendResult` hands over and `releaseResult` takes
//! back. The rules are the ones at the top of `columnar`.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, RwLock};

use napi::bindgen_prelude::{ArrayBuffer, Buffer, Object, PromiseRaw};
use napi::threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode};
use napi::{Env, Status};
use napi_derive::napi;

use super::rows::ResultSet;
use super::types::{
    Addresses, Bounds, ChainConfig, ChainMeta, Checkpoints, DiffCheckpoint, Frontier, Progress,
    Sequence,
};
use super::{
    AddChain, Batch, CacheDump, CacheFile, EffectCacheWrite, EntityWrite, Enum, HistoryWrite,
    Initialize, Partition, PgEntityWrite, RollbackWrite, Rows, Table, TableWrite,
};
use crate::clickhouse;
use crate::clickhouse::client::{Connection, Tuning};
use crate::clickhouse::table::ClickHouseTableInput;
use crate::columnar::{self, Arena, ColumnKind};
use crate::config_parsing::system_config::ChainIdMode;
use crate::entity_filter::Condition;
use crate::postgres;
use crate::postgres::client::{self, PgConnectionOptions, SslSetting};
use crate::postgres::ddl::{ColumnSpec, TableSpec};
use crate::postgres::error::to_napi as pg_to_napi;
use crate::postgres::index_definition::{Direction, IndexColumn, IndexDefinition, BTREE};
use crate::postgres::indexes::{Coverage, IndexEvent, Purpose};
use crate::postgres::param::Param;
use crate::postgres::pg_type::FieldType;
use crate::postgres::storage::{HistoryRegistration, TableRegistration};

fn to_napi(error: anyhow::Error) -> napi::Error {
    pg_to_napi(error)
}

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

#[napi(string_enum)]
#[derive(PartialEq, Eq)]
pub enum TableKind {
    Entity,
    RawEvents,
    EffectCache,
}

/// A table described for every store that could keep it. An entity is kept by
/// each store it describes itself for; the indexer's own tables by the store
/// of record alone.
#[napi(object)]
pub struct TableInput {
    pub name: String,
    pub kind: TableKind,
    pub postgres: Option<PgTableInput>,
    pub clickhouse: Option<ClickHouseTableInput>,
}

#[napi(object)]
pub struct PgRegistered {
    /// The slot each write column travels in, for a table whose batches can be
    /// staged.
    pub kinds: Option<Vec<u8>>,
}

#[napi(object)]
pub struct ClickHouseRegistered {
    pub names: Vec<String>,
    pub kinds: Vec<u8>,
    pub nullable: Vec<bool>,
}

#[napi(object)]
pub struct RegisteredTable {
    pub handle: u32,
    pub postgres: Option<PgRegistered>,
    pub clickhouse: Option<ClickHouseRegistered>,
}

#[napi(string_enum)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Store {
    Postgres,
    ClickHouse,
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
pub struct QueryResult {
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
pub struct PostgresOptions {
    pub host: String,
    pub port: u32,
    pub user: String,
    pub password: String,
    pub database: String,
    /// As `ENVIO_PG_SSL_MODE` spells it.
    pub ssl: String,
    pub max_connections: u32,
    pub application_name: String,
    pub pg_schema: String,
    pub is_hasura_enabled: bool,
}

#[napi(object)]
pub struct ClickHouseOptions {
    pub url: String,
    pub username: String,
    pub password: String,
    pub database: String,
    pub replicated: bool,
    pub database_engine: Option<String>,
}

#[napi(object)]
pub struct StorageOptions {
    /// `Int32` or `Int64`.
    pub chain_id_mode: String,
    pub postgres: Option<PostgresOptions>,
    pub clickhouse: Option<ClickHouseOptions>,
}

/// Which rows a bounded operation reaches: the chains and the checkpoint each
/// is held to.
#[napi(object)]
pub struct BoundsInput {
    /// `SharedAcrossChains` or `PerChain`.
    pub sequence: String,
    pub chain_ids: Vec<f64>,
    pub checkpoint_ids: Vec<String>,
}

#[napi(object)]
pub struct ProgressInput {
    pub chain_id: f64,
    pub progress_block: i32,
    pub progress_block_time: Option<f64>,
    pub events_processed: f64,
    pub source_block: i32,
}

#[napi(object)]
pub struct ChainMetaInput {
    pub chain_id: f64,
    pub first_event_block: Option<i32>,
    pub buffer_block: i32,
    /// Unix milliseconds.
    pub ready_at: Option<f64>,
    pub is_hyper_sync: bool,
}

#[napi(object)]
pub struct AddressesInput {
    pub chain_ids: Vec<f64>,
    pub addresses: Vec<Buffer>,
    pub contract_ids: Vec<i32>,
    /// Left out for a key.
    pub registration_blocks: Option<Vec<i32>>,
    /// The checkpoint each registration belongs to.
    pub checkpoint_ids: Option<Vec<String>>,
}

#[napi(object)]
pub struct ChainConfigInput {
    pub id: f64,
    pub ecosystem: String,
    pub start_block: i32,
    pub end_block: Option<i32>,
    pub max_reorg_depth: i32,
}

#[napi(object)]
pub struct PartitionInput {
    pub table: u32,
    pub chain_id: f64,
    pub name: String,
}

#[napi(object)]
pub struct EnumInput {
    pub name: String,
    pub variants: Vec<String>,
}

#[napi(object)]
pub struct InitializeInput {
    pub sequence: String,
    pub tables: Vec<u32>,
    pub partitions: Vec<PartitionInput>,
    pub enums: Vec<EnumInput>,
    pub chains: Vec<ChainConfigInput>,
    pub envio_info: String,
    pub contract_names: Vec<String>,
    pub addresses: AddressesInput,
}

#[napi(object)]
pub struct AddChainInput {
    pub chain: ChainConfigInput,
    pub partitions: Vec<PartitionInput>,
    pub addresses: AddressesInput,
}

#[napi(object)]
pub struct ResumeInput {
    pub sequence: String,
    /// Every entity table.
    pub tables: Vec<u32>,
}

#[napi(object)]
pub struct StoredChainOutput {
    pub id: f64,
    pub ecosystem: String,
    pub start_block: i32,
    pub end_block: Option<i32>,
    pub max_reorg_depth: i32,
}

#[napi(object)]
pub struct StoredConfigOutput {
    pub envio_info: Option<String>,
    pub contract_names: Option<Vec<String>>,
    pub chains: Vec<StoredChainOutput>,
    pub config_addresses: QueryResult,
}

#[napi(object)]
pub struct ResumedChainOutput {
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
pub struct ReorgCheckpointOutput {
    pub id: String,
    pub chain_id: f64,
    pub block_number: i32,
    pub block_hash: String,
}

#[napi(object)]
pub struct ResumedOutput {
    pub chains: Vec<ResumedChainOutput>,
    pub addresses: QueryResult,
    pub reorg_checkpoints: Vec<ReorgCheckpointOutput>,
}

#[napi(object)]
pub struct ProgressDiffOutput {
    pub chain_id: f64,
    pub events_processed: String,
    pub progress_block: i32,
}

#[napi(object)]
pub struct RollbackDataOutput {
    pub removed: QueryResult,
    pub restored: QueryResult,
}

#[napi(object)]
pub struct CacheTableOutput {
    pub table_name: String,
    pub rows: i32,
}

#[napi(object)]
pub struct CacheUploadInput {
    pub table: u32,
    pub path: String,
}

#[napi(object)]
pub struct CacheDumpInput {
    pub table_name: String,
    pub path: String,
}

/// Rows staged into an arena, or rendered one parameter per cell, every row's
/// first column first.
#[napi(object)]
pub struct RowsInput {
    pub staged: Option<u32>,
    pub cells: Option<Vec<Option<String>>>,
    pub rows: u32,
}

#[napi(object)]
pub struct HistoryWriteInput {
    pub backfill: Vec<String>,
    pub sets: Option<RowsInput>,
    pub set_checkpoint_ids: Vec<String>,
    pub delete_ids: Vec<String>,
    pub delete_checkpoint_ids: Vec<String>,
}

#[napi(object)]
pub struct PgEntityWriteInput {
    pub sets: Option<RowsInput>,
    pub deletes: Vec<String>,
    pub history: Option<HistoryWriteInput>,
}

#[napi(object)]
pub struct EntityWriteInput {
    pub table: u32,
    pub chain_id: Option<f64>,
    pub postgres: Option<PgEntityWriteInput>,
    /// Every change as a history row, staged.
    pub clickhouse: Option<u32>,
}

#[napi(object)]
pub struct DiffCheckpointInput {
    pub chain_id: f64,
    pub checkpoint_id: String,
    pub block_number: i32,
}

#[napi(object)]
pub struct RollbackWriteInput {
    pub bounds: BoundsInput,
    pub tables: Vec<u32>,
    pub progress: Vec<ProgressInput>,
    pub removed_addresses: AddressesInput,
    pub diff_checkpoints: Vec<DiffCheckpointInput>,
}

#[napi(object)]
pub struct CheckpointsInput {
    pub ids: Vec<String>,
    pub chain_ids: Vec<f64>,
    pub block_numbers: Vec<i32>,
    pub block_hashes: Vec<Option<String>>,
    pub events_processed: Vec<f64>,
    pub keeps_history: Vec<bool>,
}

#[napi(object)]
pub struct FrontierInput {
    pub chain_ids: Vec<f64>,
    pub checkpoint_ids: Vec<String>,
}

#[napi(object)]
pub struct TableWriteInput {
    pub table: u32,
    pub rows: RowsInput,
}

#[napi(object)]
pub struct EffectCacheWriteInput {
    pub table: u32,
    pub create: bool,
    pub rows: RowsInput,
}

#[napi(object)]
pub struct BatchInput {
    pub rollback: Option<RollbackWriteInput>,
    pub progress: Vec<ProgressInput>,
    pub raw_events: Option<TableWriteInput>,
    pub entities: Vec<EntityWriteInput>,
    pub chain_meta: Vec<ChainMetaInput>,
    pub addresses: AddressesInput,
    pub frontier: FrontierInput,
    pub checkpoints: CheckpointsInput,
    pub effect_caches: Vec<EffectCacheWriteInput>,
}

#[napi(object)]
pub struct WriteTiming {
    /// The store, as the metrics label it.
    pub store: String,
    pub seconds: f64,
}

/// What a staged batch is for: which store's table it fills.
#[derive(Clone)]
enum Target {
    Postgres(Arc<postgres::storage::Table>),
    ClickHouse(Arc<clickhouse::table::Table>),
}

impl Target {
    fn column_names(&self) -> Vec<String> {
        match self {
            Target::Postgres(table) => table.write_column_names(),
            Target::ClickHouse(table) => {
                table.staged.iter().map(|(name, _)| name.clone()).collect()
            }
        }
    }
}

/// The indexer's storage over every store it is configured with.
#[napi(js_name = "Storage")]
pub struct JsStorage {
    inner: super::Storage,
    tables: RwLock<Vec<Arc<Table>>>,
    /// Result sets handed out but not yet read and released. An entry lives
    /// only between the call that returned it and `releaseResult`.
    results: Mutex<HashMap<u32, Arena>>,
    /// Batches lent to JavaScript to fill, and then waiting to be written.
    staged: columnar::js::Stages<Target>,
    next_handle: AtomicU32,
}

#[napi]
impl JsStorage {
    /// `onIndexEvent` hears what Postgres's indexes are doing, and `onWarning`
    /// what ClickHouse retried, for the logs.
    #[napi(factory)]
    pub fn create(
        env: &Env,
        options: StorageOptions,
        mut on_index_event: ThreadsafeFunction<IndexEvent, (), IndexEvent, Status, false>,
        mut on_warning: ThreadsafeFunction<String, (), String, Status, false>,
    ) -> napi::Result<Self> {
        // Unreferenced, or a storage nobody closed would keep the process from
        // exiting. The deprecation points at the `Weak` type parameter instead,
        // but a weak callback can be collected once JS drops its own reference —
        // which it does immediately, the closure being passed inline — and the
        // events would then stop arriving with nothing to show for it.
        #[allow(deprecated)]
        on_index_event.unref(env)?;
        #[allow(deprecated)]
        on_warning.unref(env)?;
        let chain_id_mode = ChainIdMode::parse(&options.chain_id_mode).map_err(to_napi)?;
        let primary = options.postgres.is_none();
        let postgres = options
            .postgres
            .map(|options| -> napi::Result<_> {
                let port = u16::try_from(options.port).map_err(|_| {
                    napi::Error::from_reason(format!("`{}` is not a port", options.port))
                })?;
                let client = client::PgClient::connect(PgConnectionOptions {
                    host: options.host,
                    port,
                    user: options.user.clone(),
                    password: options.password,
                    database: options.database,
                    ssl: SslSetting::parse(&options.ssl).map_err(to_napi)?,
                    max_connections: options.max_connections as usize,
                    application_name: Some(options.application_name),
                    extra_ca_file: std::env::var_os("NODE_EXTRA_CA_CERTS").map(Into::into),
                    connect_timeout: std::time::Duration::from_secs(30),
                })
                .map_err(to_napi)?;
                Ok(Arc::new(postgres::storage::Storage::new(
                    client,
                    postgres::storage::Settings {
                        pg_schema: options.pg_schema,
                        pg_user: options.user,
                        chain_id_mode,
                        numeric_array_as_text: options.is_hasura_enabled,
                    },
                    Arc::new(move |event| {
                        on_index_event.call(event, ThreadsafeFunctionCallMode::NonBlocking);
                    }),
                )))
            })
            .transpose()?;
        let clickhouse = options
            .clickhouse
            .map(|options| -> napi::Result<_> {
                Ok(Arc::new(
                    clickhouse::storage::Storage::new(
                        Connection {
                            url: options.url,
                            username: options.username,
                            password: options.password,
                            database: options.database,
                        },
                        Tuning::default(),
                        Arc::new(move |message: &str| {
                            on_warning
                                .call(message.to_string(), ThreadsafeFunctionCallMode::NonBlocking);
                        }),
                        clickhouse::storage::Settings {
                            chain_id_mode,
                            replicated: options.replicated,
                            database_engine: options.database_engine,
                            primary,
                        },
                    )
                    .map_err(to_napi)?,
                ))
            })
            .transpose()?;
        if postgres.is_none() && clickhouse.is_none() {
            return Err(napi::Error::from_reason(
                "A storage needs Postgres, ClickHouse or both",
            ));
        }
        Ok(Self {
            inner: super::Storage {
                postgres,
                clickhouse,
            },
            tables: RwLock::new(Vec::new()),
            results: Mutex::new(HashMap::new()),
            staged: Default::default(),
            next_handle: AtomicU32::new(0),
        })
    }

    /// Registers a table with every store that keeps it. A Postgres table's
    /// batches are staged when it has no column of arrays: unnesting one
    /// spreads it across the rows instead of keeping it as a value, so such a
    /// table binds a parameter per cell instead.
    #[napi]
    pub fn register_table(&self, input: TableInput) -> napi::Result<RegisteredTable> {
        let is_own = input.kind != TableKind::Entity;
        let postgres = match (&self.inner.postgres, input.postgres) {
            (Some(store), Some(table)) => Some(Arc::new(
                store
                    .register(pg_registration(table).map_err(to_napi)?)
                    .map_err(to_napi)?,
            )),
            _ => None,
        };
        // The indexer's own tables live in the store of record only.
        let clickhouse = match (&self.inner.clickhouse, input.clickhouse) {
            (Some(store), Some(table)) if !is_own || self.inner.postgres.is_none() => {
                Some(Arc::new(store.register(table).map_err(to_napi)?))
            }
            _ => None,
        };
        let registered = RegisteredTable {
            handle: 0,
            postgres: postgres.as_ref().map(|table| PgRegistered {
                kinds: table
                    .kinds
                    .as_ref()
                    .map(|kinds| kinds.iter().map(|&kind| kind as u8).collect()),
            }),
            clickhouse: clickhouse.as_ref().map(|table| ClickHouseRegistered {
                names: table.staged.iter().map(|(name, _)| name.clone()).collect(),
                kinds: table
                    .staged_kinds()
                    .into_iter()
                    .map(|kind| kind as u8)
                    .collect(),
                nullable: table
                    .staged
                    .iter()
                    .map(|(_, ch_type)| matches!(ch_type, clickhouse::ch_type::ChType::Nullable(_)))
                    .collect(),
            }),
        };
        let mut tables = self.tables.write().unwrap();
        tables.push(Arc::new(Table {
            name: input.name,
            postgres,
            clickhouse,
        }));
        Ok(RegisteredTable {
            handle: (tables.len() - 1) as u32,
            ..registered
        })
    }

    /// Lays out a batch for one store's table and lends JavaScript the memory
    /// to fill it in. Nothing may await between here and `commitStage` — see the
    /// phase rules in `columnar`.
    #[napi]
    pub fn begin_stage<'env>(
        &self,
        env: &'env Env,
        table: u32,
        store: Store,
        rows: u32,
    ) -> napi::Result<Object<'env>> {
        let table = self.table(table)?;
        let (target, kinds): (Target, Vec<ColumnKind>) = match store {
            Store::Postgres => {
                let table = table.postgres().map_err(to_napi)?.clone();
                let kinds = table.kinds.clone().ok_or_else(|| {
                    napi::Error::from_reason(format!(
                        "\"{}\" has an array column, so its rows are bound a cell at a time",
                        table.name()
                    ))
                })?;
                (Target::Postgres(table), kinds)
            }
            Store::ClickHouse => {
                let table = table.clickhouse().map_err(to_napi)?.clone();
                let kinds = table.staged_kinds();
                (Target::ClickHouse(table), kinds)
            }
        };
        let handle = self.next_handle.fetch_add(1, Ordering::Relaxed);
        self.staged.begin(env, handle, rows, &kinds, target)
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
            .commit(handle, buffers, |target| target.column_names())
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

    /// Any statement at all against Postgres, for tests to set a database up
    /// and read it back. The indexer itself only ever calls the operations
    /// below.
    #[napi]
    pub async fn query_for_tests(
        &self,
        sql: String,
        params: Vec<Option<String>>,
    ) -> napi::Result<QueryResult> {
        let store = self
            .inner
            .postgres
            .as_ref()
            .ok_or_else(|| napi::Error::from_reason("No Postgres is configured"))?;
        let (rows, columns) = store
            .client
            .query(&sql, &to_params(params))
            .await
            .map_err(to_napi)?;
        self.hold(postgres::rows::into_result(&rows, &columns).map_err(to_napi)?)
    }

    #[napi]
    pub async fn load_where(
        &self,
        table: u32,
        conditions: Vec<Condition>,
    ) -> napi::Result<QueryResult> {
        let table = self.table(table)?;
        let result = self
            .inner
            .load_where(&table, conditions)
            .await
            .map_err(to_napi)?;
        self.hold(result)
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

    #[napi]
    pub async fn initialize(&self, input: InitializeInput) -> napi::Result<()> {
        let input = Initialize {
            sequence: Sequence::parse(&input.sequence).map_err(to_napi)?,
            tables: self.tables_of(&input.tables)?,
            partitions: self.partitions(input.partitions)?,
            enums: input
                .enums
                .into_iter()
                .map(|enum_type| Enum {
                    name: enum_type.name,
                    variants: enum_type.variants,
                })
                .collect(),
            chains: input.chains.into_iter().map(chain_config).collect(),
            envio_info: input.envio_info,
            contract_names: input.contract_names,
            addresses: addresses(input.addresses)?,
        };
        self.inner.initialize(input).await.map_err(to_napi)
    }

    #[napi]
    pub async fn add_chain(&self, input: AddChainInput) -> napi::Result<()> {
        let input = AddChain {
            chain: chain_config(input.chain),
            partitions: self.partitions(input.partitions)?,
            addresses: addresses(input.addresses)?,
        };
        self.inner.add_chain(input).await.map_err(to_napi)
    }

    #[napi]
    pub async fn read_stored_config(&self) -> napi::Result<StoredConfigOutput> {
        let read = self.inner.read_stored_config().await.map_err(to_napi)?;
        Ok(StoredConfigOutput {
            envio_info: read.config.envio_info,
            contract_names: read.config.contract_names,
            chains: read
                .config
                .chains
                .into_iter()
                .map(|chain| StoredChainOutput {
                    id: chain.id,
                    ecosystem: chain.ecosystem,
                    start_block: chain.start_block,
                    end_block: chain.end_block,
                    max_reorg_depth: chain.max_reorg_depth,
                })
                .collect(),
            config_addresses: self.hold(read.config_addresses)?,
        })
    }

    #[napi]
    pub async fn resume(&self, input: ResumeInput) -> napi::Result<ResumedOutput> {
        let sequence = Sequence::parse(&input.sequence).map_err(to_napi)?;
        let tables = self.tables_of(&input.tables)?;
        let resumed = self.inner.resume(sequence, tables).await.map_err(to_napi)?;
        Ok(ResumedOutput {
            chains: resumed
                .chains
                .into_iter()
                .map(|chain| ResumedChainOutput {
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
            addresses: self.hold(resumed.addresses)?,
            reorg_checkpoints: resumed
                .reorg_checkpoints
                .into_iter()
                .map(|checkpoint| ReorgCheckpointOutput {
                    id: checkpoint.id,
                    chain_id: checkpoint.chain_id,
                    block_number: checkpoint.block_number,
                    block_hash: checkpoint.block_hash,
                })
                .collect(),
        })
    }

    #[napi]
    pub async fn set_chain_meta(&self, chains: Vec<ChainMetaInput>) -> napi::Result<()> {
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

    /// Restores whatever the schema promises and Postgres no longer has. Never
    /// rejects: a failed build is reported, and its queries run unindexed
    /// until the next restart.
    #[napi]
    pub async fn ensure_schema_indexes(&self, definitions: Vec<PgIndexInput>) -> napi::Result<()> {
        let definitions = definitions_of(definitions)?;
        if let Some(store) = &self.inner.postgres {
            store.indexes.ensure(definitions, Purpose::Schema).await;
        }
        Ok(())
    }

    /// The single-column indexes a getWhere on `columns` wants. Null when the
    /// catalog already covers them, which is every call but the first — and
    /// every call to a store that builds none: this runs on every batched
    /// load, so it answers without leaving the thread. Never rejects: a failed
    /// build is reported, and the query runs without it.
    #[napi]
    pub fn ensure_query_indexes<'env>(
        &self,
        env: &'env Env,
        table: u32,
        table_name: String,
        columns: Vec<String>,
    ) -> napi::Result<Option<PromiseRaw<'env, ()>>> {
        let table = self.table(table)?;
        let Some(store) = &self.inner.postgres else {
            return Ok(None);
        };
        if table.postgres.is_none() {
            return Ok(None);
        }
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
        let indexes = &store.indexes;
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
    pub async fn prune_checkpoints(&self, bounds: BoundsInput) -> napi::Result<()> {
        let bounds = to_bounds(bounds)?;
        self.inner.prune_checkpoints(&bounds).await.map_err(to_napi)
    }

    #[napi]
    pub async fn prune_history(&self, table: u32, bounds: BoundsInput) -> napi::Result<()> {
        let table = self.table(table)?;
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
        Ok(self
            .inner
            .rollback_target_checkpoint(self::chain_id(chain_id), block_number)
            .await
            .map_err(to_napi)?
            .map(|id| id.to_string()))
    }

    #[napi]
    pub async fn rollback_progress_diff(
        &self,
        bounds: BoundsInput,
    ) -> napi::Result<Vec<ProgressDiffOutput>> {
        let bounds = to_bounds(bounds)?;
        Ok(self
            .inner
            .rollback_progress_diff(&bounds)
            .await
            .map_err(to_napi)?
            .into_iter()
            .map(|diff| ProgressDiffOutput {
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
        bounds: BoundsInput,
    ) -> napi::Result<RollbackDataOutput> {
        let table = self.table(table)?;
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
        Ok(RollbackDataOutput { removed, restored })
    }

    #[napi]
    pub async fn effect_cache_tables(&self) -> napi::Result<Vec<CacheTableOutput>> {
        Ok(self
            .inner
            .effect_cache_tables()
            .await
            .map_err(to_napi)?
            .into_iter()
            .map(|table| CacheTableOutput {
                table_name: table.table_name,
                rows: table.rows,
            })
            .collect())
    }

    #[napi]
    pub async fn upload_effect_cache(&self, files: Vec<CacheUploadInput>) -> napi::Result<()> {
        let files = files
            .into_iter()
            .map(|file| {
                Ok(CacheFile {
                    table: self.table(file.table)?,
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
    pub async fn dump_effect_cache(&self, files: Vec<CacheDumpInput>) -> napi::Result<()> {
        let files = files
            .into_iter()
            .map(|file| CacheDump {
                table_name: file.table_name,
                path: file.path,
            })
            .collect::<Vec<_>>();
        self.inner.dump_effect_cache(&files).await.map_err(to_napi)
    }

    #[napi]
    pub async fn reset(&self) -> napi::Result<()> {
        self.inner.reset().await.map_err(to_napi)
    }

    /// Writes a batch to every store, answering how long each one took. A
    /// failed write rejects with what it was doing as the message, and the
    /// store's own error as the `cause`.
    #[napi]
    pub async fn write_batch(&self, batch: BatchInput) -> napi::Result<Vec<WriteTiming>> {
        let batch = self.to_batch(batch)?;
        match self.inner.write_batch(batch).await {
            Ok(timings) => Ok(timings
                .into_iter()
                .map(|(store, seconds)| WriteTiming {
                    store: store.to_string(),
                    seconds,
                })
                .collect()),
            Err(failure) => {
                let mut failed = napi::Error::from_reason(failure.context);
                failed.set_cause(to_napi(failure.error));
                Err(failed)
            }
        }
    }

    #[napi]
    pub async fn close(&self) {
        self.inner.close();
    }
}

fn definitions_of(definitions: Vec<PgIndexInput>) -> napi::Result<Vec<IndexDefinition>> {
    definitions
        .into_iter()
        .map(IndexDefinition::try_from)
        .collect::<anyhow::Result<Vec<_>>>()
        .map_err(to_napi)
}

fn pg_registration(table: PgTableInput) -> anyhow::Result<TableRegistration> {
    Ok(TableRegistration {
        spec: TableSpec {
            table_name: table.table_name,
            columns: table
                .columns
                .into_iter()
                .map(ColumnSpec::try_from)
                .collect::<anyhow::Result<Vec<_>>>()?,
            partition_by_column: table.partition_by_column,
        },
        write_columns: table.write_columns,
        append_only: table.append_only.unwrap_or(false),
        history: table.history_table.map(|table_name| HistoryRegistration {
            table_name,
            chain_id_column: table.chain_id_column,
        }),
    })
}

impl JsStorage {
    fn table(&self, handle: u32) -> napi::Result<Arc<Table>> {
        self.tables
            .read()
            .unwrap()
            .get(handle as usize)
            .cloned()
            .ok_or_else(|| napi::Error::from_reason(format!("Unknown table {handle}")))
    }

    fn tables_of(&self, handles: &[u32]) -> napi::Result<Vec<Arc<Table>>> {
        handles.iter().map(|&handle| self.table(handle)).collect()
    }

    fn hold(&self, result: ResultSet) -> napi::Result<QueryResult> {
        let ResultSet { columns, arena } = result;
        let result = QueryResult {
            handle: self.next_handle.fetch_add(1, Ordering::Relaxed),
            names: columns.iter().map(|column| column.name.clone()).collect(),
            kinds: columns.iter().map(|column| column.kind as u8).collect(),
            element_kinds: columns
                .iter()
                .map(|column| column.element.map(|kind| kind as u8))
                .collect(),
            rows: arena.rows() as u32,
        };
        self.results.lock().unwrap().insert(result.handle, arena);
        Ok(result)
    }

    fn partitions(&self, partitions: Vec<PartitionInput>) -> napi::Result<Vec<Partition>> {
        partitions
            .into_iter()
            .map(|partition| {
                Ok(Partition {
                    table: self.table(partition.table)?,
                    chain_id: chain_id(partition.chain_id),
                    name: partition.name,
                })
            })
            .collect()
    }

    /// Takes every batch a write names out of the registry before anything
    /// can fail, so a write refused here frees them rather than leaving them
    /// for a `discardStaged` nobody makes.
    fn rows(&self, rows: RowsInput, problems: &mut Vec<napi::Error>) -> Option<Rows> {
        match (rows.staged, rows.cells) {
            (Some(handle), _) => self.arena(handle, problems).map(Rows::Staged),
            (None, Some(cells)) => Some(Rows::Cells {
                cells: to_params(cells),
                rows: rows.rows as usize,
            }),
            (None, None) => {
                problems.push(napi::Error::from_reason(
                    "Rows have to be staged or given as cells",
                ));
                None
            }
        }
    }

    fn arena(&self, handle: u32, problems: &mut Vec<napi::Error>) -> Option<Arena> {
        match self.staged.take_sealed(handle) {
            Ok(staged) => Some(staged.arena),
            Err(error) => {
                problems.push(error);
                None
            }
        }
    }

    fn to_batch(&self, batch: BatchInput) -> napi::Result<Batch> {
        let mut problems = Vec::new();
        let table = |handle: u32, problems: &mut Vec<napi::Error>| {
            self.table(handle)
                .map_err(|error| problems.push(error))
                .ok()
        };
        let raw_events = batch.raw_events.and_then(|write| {
            let rows = self.rows(write.rows, &mut problems)?;
            Some(TableWrite {
                table: table(write.table, &mut problems)?,
                rows,
            })
        });
        let entities = batch
            .entities
            .into_iter()
            .filter_map(|write| {
                let postgres = write.postgres.map(|write| PgEntityWrite {
                    sets: write.sets.and_then(|rows| self.rows(rows, &mut problems)),
                    deletes: write.deletes,
                    history: write.history.map(|history| HistoryWrite {
                        backfill: history.backfill,
                        sets: history.sets.and_then(|rows| {
                            Some((self.rows(rows, &mut problems)?, history.set_checkpoint_ids))
                        }),
                        delete_ids: history.delete_ids,
                        delete_checkpoint_ids: history.delete_checkpoint_ids,
                    }),
                });
                let clickhouse = write
                    .clickhouse
                    .and_then(|handle| self.arena(handle, &mut problems));
                Some(EntityWrite {
                    table: table(write.table, &mut problems)?,
                    chain_id: write.chain_id.map(chain_id),
                    postgres,
                    clickhouse,
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
                    tables: self.tables_of(&rollback.tables)?,
                    progress: rollback.progress.into_iter().map(progress).collect(),
                    removed_addresses: addresses(rollback.removed_addresses)?,
                    diff_checkpoints: rollback
                        .diff_checkpoints
                        .into_iter()
                        .map(|diff| {
                            Ok(DiffCheckpoint {
                                chain_id: chain_id(diff.chain_id),
                                checkpoint_id: checkpoint_id(&diff.checkpoint_id)?,
                                block_number: diff.block_number,
                            })
                        })
                        .collect::<napi::Result<_>>()?,
                })
            });
        if let Some(problem) = problems.into_iter().next() {
            return Err(problem);
        }
        Ok(Batch {
            rollback: rollback.transpose()?,
            progress: batch.progress.into_iter().map(progress).collect(),
            raw_events,
            entities,
            chain_meta: batch.chain_meta.into_iter().map(chain_meta).collect(),
            addresses: addresses(batch.addresses)?,
            frontier: Frontier {
                chain_ids: batch.frontier.chain_ids.into_iter().map(chain_id).collect(),
                checkpoint_ids: batch
                    .frontier
                    .checkpoint_ids
                    .iter()
                    .map(|id| checkpoint_id(id))
                    .collect::<napi::Result<_>>()?,
            },
            checkpoints: Checkpoints {
                ids: batch
                    .checkpoints
                    .ids
                    .iter()
                    .map(|id| checkpoint_id(id))
                    .collect::<napi::Result<_>>()?,
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
                keeps_history: batch.checkpoints.keeps_history,
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

fn checkpoint_id(id: &str) -> napi::Result<i64> {
    id.parse::<i64>()
        .map_err(|_| napi::Error::from_reason(format!("`{id}` is not a checkpoint id")))
}

fn chain_config(chain: ChainConfigInput) -> ChainConfig {
    ChainConfig {
        id: chain_id(chain.id),
        ecosystem: chain.ecosystem,
        start_block: chain.start_block,
        end_block: chain.end_block,
        max_reorg_depth: chain.max_reorg_depth,
    }
}

fn progress(progress: ProgressInput) -> Progress {
    Progress {
        chain_id: chain_id(progress.chain_id),
        progress_block: progress.progress_block,
        progress_block_time: progress.progress_block_time,
        events_processed: progress.events_processed,
        source_block: progress.source_block,
    }
}

fn chain_meta(meta: ChainMetaInput) -> ChainMeta {
    ChainMeta {
        chain_id: chain_id(meta.chain_id),
        first_event_block: meta.first_event_block,
        buffer_block: meta.buffer_block,
        ready_at: meta.ready_at,
        is_hyper_sync: meta.is_hyper_sync,
    }
}

fn addresses(addresses: AddressesInput) -> napi::Result<Addresses> {
    Ok(Addresses {
        chain_ids: addresses.chain_ids.into_iter().map(chain_id).collect(),
        addresses: addresses
            .addresses
            .into_iter()
            .map(|bytes| bytes.to_vec())
            .collect(),
        contract_ids: addresses.contract_ids,
        registration_blocks: addresses.registration_blocks.unwrap_or_default(),
        checkpoint_ids: addresses
            .checkpoint_ids
            .unwrap_or_default()
            .iter()
            .map(|id| checkpoint_id(id))
            .collect::<napi::Result<_>>()?,
    })
}

fn to_bounds(bounds: BoundsInput) -> napi::Result<Bounds> {
    Ok(Bounds {
        sequence: Sequence::parse(&bounds.sequence).map_err(to_napi)?,
        chain_ids: bounds.chain_ids.into_iter().map(chain_id).collect(),
        checkpoint_ids: bounds
            .checkpoint_ids
            .iter()
            .map(|id| checkpoint_id(id))
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
