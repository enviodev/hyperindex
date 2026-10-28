use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use napi::bindgen_prelude::{ArrayBuffer, BigInt, Buffer, Object, PromiseRaw};
use napi::Env;
use napi_derive::napi;
use serde_json::json;

use super::batch::{Batch, EffectCacheWrite, RollbackWrite};
use super::changes::{self, ChangeSet};
use super::rows::ResultSet;
use super::schema::{effect_cache_fields, raw_event_fields, Encoding, Field, Schema};
use super::types::{
    Addresses, Bounds, CacheTable, ChainConfig, ChainMeta, Checkpoints, DiffCheckpoint, Frontier,
    Progress,
};
use super::{AddChain, CacheDump, CacheFile, Holding, Initialize, Store};
use crate::clickhouse;
use crate::clickhouse::client::{Connection, Tuning};
use crate::columnar::{self, Arena, ColumnKind};
use crate::config_parsing::system_config::ChainIdMode;
use crate::entity_filter::Condition;
use crate::logger::{Level, Logger};
use crate::postgres;
use crate::postgres::client::{self, PgConnectionOptions, SslSetting};
use crate::postgres::error::to_napi;
use crate::postgres::indexes::IndexEvent;
use crate::postgres::param::Param;

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
    pub isolated: bool,
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
    pub postgres: PostgresOptions,
    pub clickhouse: Option<ClickHouseOptions>,
}

/// One value a staged row carries, and how JavaScript has to encode it.
#[napi(object)]
pub struct StagedField {
    pub name: String,
    pub encoding: Encoding,
    /// What a list's elements are encoded as; the field's own for a scalar.
    pub element: Encoding,
    pub is_nullable: bool,
}

impl From<&Field> for StagedField {
    fn from(field: &Field) -> Self {
        Self {
            name: field.name.clone(),
            encoding: field.encoding(),
            element: field.field_type.encoding(),
            is_nullable: field.is_nullable,
        }
    }
}

#[napi(object)]
pub struct EntityLayout {
    pub name: String,
    /// The store the entity is read from; none when no configured store keeps
    /// it, which only an operation on it reports.
    pub home: Option<Store>,
    /// What a change set stages ahead of each change's checkpoint and whether
    /// it deletes.
    pub fields: Vec<StagedField>,
}

#[napi(object)]
pub struct Layouts {
    /// By entity index.
    pub entities: Vec<EntityLayout>,
    pub raw_events: Vec<StagedField>,
    pub effect_cache: Vec<StagedField>,
}

#[napi(string_enum)]
pub enum StagedTable {
    RawEvents,
    EffectCache,
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
pub struct BoundsInput {
    pub chain_ids: Vec<i64>,
    pub checkpoint_ids: Vec<BigInt>,
}

#[napi(object)]
pub struct AddressesInput {
    pub chain_ids: Vec<i64>,
    pub addresses: Vec<Buffer>,
    pub contract_ids: Vec<i32>,
    /// Left out for a key.
    pub registration_blocks: Option<Vec<i32>>,
}

#[napi(object)]
pub struct InitializeInput {
    pub chains: Vec<ChainConfig>,
    pub envio_info: String,
    pub contract_names: Vec<String>,
    pub addresses: AddressesInput,
}

#[napi(object)]
pub struct AddChainInput {
    pub chain: ChainConfig,
    pub addresses: AddressesInput,
}

#[napi(object)]
pub struct StoredConfigOutput {
    pub envio_info: Option<String>,
    pub contract_names: Option<Vec<String>>,
    pub chains: Vec<ChainConfig>,
    pub config_addresses: QueryResult,
}

#[napi(object)]
pub struct ResumedChainOutput {
    pub id: i64,
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
    pub checkpoint_id: BigInt,
}

#[napi(object)]
pub struct ReorgCheckpointOutput {
    pub id: BigInt,
    pub chain_id: i64,
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
    pub chain_id: i64,
    pub events_processed: String,
    pub progress_block: i32,
}

#[napi(object)]
pub struct RollbackDataOutput {
    pub removed: QueryResult,
    pub restored: QueryResult,
}

#[napi(object)]
pub struct CacheUploadInput {
    pub table: String,
    pub path: String,
}

/// One entity's changes within one chain scope, staged.
#[napi(object)]
pub struct ChangesInput {
    pub entity: u32,
    /// The scope's chain, for a per-chain entity.
    pub chain_id: Option<i64>,
    pub keeps_history: bool,
    pub changes: u32,
}

#[napi(object)]
pub struct DiffCheckpointInput {
    pub chain_id: i64,
    pub checkpoint_id: BigInt,
    pub block_number: i32,
}

#[napi(object)]
pub struct RollbackWriteInput {
    pub bounds: BoundsInput,
    pub progress: Vec<Progress>,
    pub removed_addresses: AddressesInput,
    pub diff_checkpoints: Vec<DiffCheckpointInput>,
}

#[napi(object)]
pub struct CheckpointsInput {
    pub ids: Vec<BigInt>,
    pub chain_ids: Vec<i64>,
    pub block_numbers: Vec<i32>,
    pub block_hashes: Vec<Option<String>>,
    pub events_processed: Vec<f64>,
    pub keeps_history: Vec<bool>,
}

#[napi(object)]
pub struct FrontierInput {
    pub chain_ids: Vec<i64>,
    pub checkpoint_ids: Vec<BigInt>,
}

#[napi(object)]
pub struct EffectCacheWriteInput {
    pub table: String,
    pub create: bool,
    pub rows: u32,
}

#[napi(object)]
pub struct BatchInput {
    pub rollback: Option<RollbackWriteInput>,
    pub progress: Vec<Progress>,
    pub raw_events: Option<u32>,
    pub changes: Vec<ChangesInput>,
    pub chain_meta: Vec<ChainMeta>,
    pub addresses: AddressesInput,
    pub frontier: FrontierInput,
    pub checkpoints: CheckpointsInput,
    pub effect_caches: Vec<EffectCacheWriteInput>,
}

#[napi(object)]
pub struct WriteTiming {
    pub store: Store,
    pub seconds: f64,
}

#[napi(js_name = "Storage")]
pub struct JsStorage {
    inner: super::Storage,
    /// Result sets handed out but not yet read and released. An entry lives
    /// only between the call that returned it and `releaseResult`.
    results: Mutex<HashMap<u32, Arena>>,
    /// Batches lent to JavaScript to fill, and then waiting to be written.
    staged: columnar::js::Stages,
    next_handle: AtomicU32,
}

#[napi]
impl JsStorage {
    /// The storage of the entities `configJson` — the config the CLI wrote —
    /// declares, or of none. Logs what Postgres's indexes are doing and what
    /// ClickHouse retried through `logger`, with `boundFieldsJson` as the
    /// JavaScript logger binds them.
    #[napi(factory)]
    pub fn create(
        options: StorageOptions,
        config_json: Option<String>,
        logger: &Logger,
        bound_fields_json: Vec<String>,
    ) -> napi::Result<Self> {
        let logger = logger.bind(bound_fields_json);
        let schema = Arc::new(match config_json {
            Some(json) => Schema::from_config_json(&json).map_err(to_napi)?,
            None => Schema::empty(ChainIdMode::Int32),
        });
        let pg = options.postgres;
        let port = u16::try_from(pg.port)
            .map_err(|_| napi::Error::from_reason(format!("`{}` is not a port", pg.port)))?;
        let client = client::PgClient::connect(PgConnectionOptions {
            host: pg.host,
            port,
            user: pg.user.clone(),
            password: pg.password,
            database: pg.database,
            ssl: SslSetting::parse(&pg.ssl).map_err(to_napi)?,
            max_connections: pg.max_connections as usize,
            application_name: Some(pg.application_name),
            extra_ca_file: std::env::var_os("NODE_EXTRA_CA_CERTS").map(Into::into),
            connect_timeout: std::time::Duration::from_secs(30),
        })
        .map_err(to_napi)?;
        let postgres = Arc::new(
            postgres::storage::Storage::new(
                client,
                postgres::storage::Settings {
                    pg_schema: pg.pg_schema.clone(),
                    pg_user: pg.user,
                    numeric_array_as_text: pg.is_hasura_enabled,
                    isolated: pg.isolated,
                },
                schema.clone(),
                Arc::new({
                    let logger = logger.clone();
                    move |event: IndexEvent| event.log(&logger, &pg.pg_schema)
                }),
            )
            .map_err(to_napi)?,
        );
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
                            logger.log(Level::WARN, message, &json!({"storage": "clickhouse"}));
                        }),
                        clickhouse::storage::Settings {
                            replicated: options.replicated,
                            database_engine: options.database_engine,
                        },
                        schema.clone(),
                    )
                    .map_err(to_napi)?,
                ))
            })
            .transpose()?;
        Ok(Self {
            inner: super::Storage {
                schema,
                postgres,
                clickhouse,
            },
            results: Mutex::new(HashMap::new()),
            staged: Default::default(),
            next_handle: AtomicU32::new(0),
        })
    }

    /// How every batch JavaScript stages is laid out.
    #[napi]
    pub fn layouts(&self) -> Layouts {
        Layouts {
            entities: self
                .inner
                .schema
                .entities
                .iter()
                .map(|entity| EntityLayout {
                    name: entity.name.clone(),
                    home: self.inner.home(entity).ok(),
                    fields: entity.fields.iter().map(StagedField::from).collect(),
                })
                .collect(),
            raw_events: raw_event_fields().iter().map(StagedField::from).collect(),
            effect_cache: effect_cache_fields()
                .iter()
                .map(StagedField::from)
                .collect(),
        }
    }

    /// Lays out an entity's change set and lends JavaScript the memory to fill
    /// it in. Nothing may await between here and `commitStage` — see the phase
    /// rules in `columnar`.
    #[napi]
    pub fn begin_changes<'env>(
        &self,
        env: &'env Env,
        entity: u32,
        rows: u32,
    ) -> napi::Result<Object<'env>> {
        let entity = self.inner.schema.entity(entity).map_err(to_napi)?;
        let (names, kinds) = changes::layout(entity);
        self.begin(env, rows, &kinds, names)
    }

    #[napi]
    pub fn begin_rows<'env>(
        &self,
        env: &'env Env,
        table: StagedTable,
        rows: u32,
    ) -> napi::Result<Object<'env>> {
        let fields = match table {
            StagedTable::RawEvents => raw_event_fields(),
            StagedTable::EffectCache => effect_cache_fields(),
        };
        let (names, kinds): (Vec<String>, Vec<ColumnKind>) = fields
            .iter()
            .map(|field| (field.name.clone(), field.encoding().kind()))
            .unzip();
        self.begin(env, rows, &kinds, names)
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
        self.staged.commit(handle, buffers)
    }

    /// Gives up on a batch. Whatever sent the caller here is the error worth
    /// reading, so a batch that cannot be handed back is abandoned rather than
    /// reported over the top of it.
    #[napi]
    pub fn abort_stage(&self, handle: u32, buffers: Vec<ArrayBuffer>) {
        let _ = self.staged.abort(handle, buffers);
    }

    /// Frees batches staged for a write the addon never took: one whose next
    /// table failed to stage, or one `writeBatch` refused before reading.
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
        let params = params
            .into_iter()
            .map(|param| param.map_or(Param::Null, Param::Text))
            .collect::<Vec<_>>();
        let (rows, columns) = self
            .inner
            .postgres
            .client
            .query(&sql, &params)
            .await
            .map_err(to_napi)?;
        Ok(self.hold(postgres::rows::into_result(&rows, &columns).map_err(to_napi)?))
    }

    /// Every committed history row of an entity ClickHouse keeps, for tests to
    /// read back.
    #[napi]
    pub async fn history_for_tests(&self, entity: u32) -> napi::Result<QueryResult> {
        let entity = self.entity(entity)?;
        let result = self
            .inner
            .clickhouse_history(&entity)
            .await
            .map_err(to_napi)?;
        Ok(self.hold(result))
    }

    /// Every current row of an entity's ClickHouse copy, wherever it is read
    /// from, for tests to hold it to Postgres's.
    #[napi]
    pub async fn clickhouse_rows_for_tests(&self, entity: u32) -> napi::Result<QueryResult> {
        let entity = self.entity(entity)?;
        let result = self.inner.clickhouse_rows(&entity).await.map_err(to_napi)?;
        Ok(self.hold(result))
    }

    #[napi]
    pub async fn load_where(
        &self,
        entity: u32,
        conditions: Vec<Condition>,
    ) -> napi::Result<QueryResult> {
        let entity = self.entity(entity)?;
        let result = self
            .inner
            .load_where(&entity, conditions)
            .await
            .map_err(to_napi)?;
        Ok(self.hold(result))
    }

    #[napi]
    pub async fn load_effect_cache(
        &self,
        table: String,
        conditions: Vec<Condition>,
    ) -> napi::Result<QueryResult> {
        let result = self
            .inner
            .load_effect_cache(&table, conditions)
            .await
            .map_err(to_napi)?;
        Ok(self.hold(result))
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
    pub async fn holding(&self) -> napi::Result<Holding> {
        self.inner.holding().await.map_err(to_napi)
    }

    #[napi]
    pub async fn initialize(&self, input: InitializeInput) -> napi::Result<()> {
        let input = Initialize {
            chains: input.chains,
            envio_info: input.envio_info,
            contract_names: input.contract_names,
            addresses: addresses(input.addresses)?,
        };
        self.inner.initialize(input).await.map_err(to_napi)
    }

    #[napi]
    pub async fn add_chain(&self, input: AddChainInput) -> napi::Result<()> {
        let input = AddChain {
            chain: input.chain,
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
            chains: read.config.chains,
            config_addresses: self.hold(read.config_addresses),
        })
    }

    /// Resumes the chains this run drives.
    #[napi]
    pub async fn resume(&self, chain_ids: Vec<i64>) -> napi::Result<ResumedOutput> {
        let resumed = self.inner.resume(&chain_ids).await.map_err(to_napi)?;
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
                    checkpoint_id: BigInt::from(chain.checkpoint_id),
                })
                .collect(),
            addresses: self.hold(resumed.addresses),
            reorg_checkpoints: resumed
                .reorg_checkpoints
                .into_iter()
                .map(|checkpoint| ReorgCheckpointOutput {
                    id: BigInt::from(checkpoint.id),
                    chain_id: checkpoint.chain_id,
                    block_number: checkpoint.block_number,
                    block_hash: checkpoint.block_hash,
                })
                .collect(),
        })
    }

    #[napi]
    pub async fn set_chain_meta(&self, chains: Vec<ChainMeta>) -> napi::Result<()> {
        self.inner.set_chain_meta(&chains).await.map_err(to_napi)
    }

    /// Builds every index the schema promises for the chains, then stamps
    /// them ready at `readyAt`, in unix milliseconds.
    #[napi]
    pub async fn finalize_backfill(&self, chain_ids: Vec<i64>, ready_at: f64) -> napi::Result<()> {
        self.inner
            .finalize_backfill(&chain_ids, ready_at)
            .await
            .map_err(to_napi)
    }

    /// Restores whatever the schema promises and Postgres no longer has. Never
    /// rejects: a failed build is reported, and its queries run unindexed
    /// until the next restart.
    #[napi]
    pub async fn ensure_schema_indexes(&self, chain_ids: Vec<i64>) {
        self.inner.ensure_schema_indexes(&chain_ids).await
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
        entity: u32,
        chain_id: Option<i64>,
        columns: Vec<String>,
    ) -> napi::Result<Option<PromiseRaw<'env, ()>>> {
        let entity = self.entity(entity)?;
        match self.inner.ensure_query_indexes(&entity, chain_id, columns) {
            None => Ok(None),
            Some(building) => env
                .spawn_future(async move {
                    building.await;
                    Ok(())
                })
                .map(Some),
        }
    }

    #[napi]
    pub async fn prune_checkpoints(&self, bounds: BoundsInput) -> napi::Result<()> {
        let bounds = self.bounds(bounds)?;
        self.inner.prune_checkpoints(&bounds).await.map_err(to_napi)
    }

    #[napi]
    pub async fn prune_history(&self, entity: u32, bounds: BoundsInput) -> napi::Result<()> {
        let entity = self.entity(entity)?;
        let bounds = self.bounds(bounds)?;
        self.inner
            .prune_history(&entity, &bounds)
            .await
            .map_err(to_napi)
    }

    #[napi]
    pub async fn rollback_target_checkpoint(
        &self,
        chain_id: i64,
        block_number: i32,
    ) -> napi::Result<Option<BigInt>> {
        Ok(self
            .inner
            .rollback_target_checkpoint(chain_id, block_number)
            .await
            .map_err(to_napi)?
            .map(BigInt::from))
    }

    #[napi]
    pub async fn rollback_progress_diff(
        &self,
        bounds: BoundsInput,
    ) -> napi::Result<Vec<ProgressDiffOutput>> {
        let bounds = self.bounds(bounds)?;
        Ok(self
            .inner
            .rollback_progress_diff(&bounds)
            .await
            .map_err(to_napi)?
            .into_iter()
            .map(|diff| ProgressDiffOutput {
                chain_id: diff.chain_id,
                events_processed: diff.events_processed.to_string(),
                progress_block: diff.progress_block,
            })
            .collect())
    }

    #[napi]
    pub async fn rollback_data(
        &self,
        entity: u32,
        bounds: BoundsInput,
    ) -> napi::Result<RollbackDataOutput> {
        let entity = self.entity(entity)?;
        let bounds = self.bounds(bounds)?;
        let data = self
            .inner
            .rollback_data(&entity, &bounds)
            .await
            .map_err(to_napi)?;
        Ok(RollbackDataOutput {
            removed: self.hold(data.removed),
            restored: self.hold(data.restored),
        })
    }

    #[napi]
    pub async fn effect_cache_tables(&self) -> napi::Result<Vec<CacheTable>> {
        self.inner.effect_cache_tables().await.map_err(to_napi)
    }

    #[napi]
    pub async fn upload_effect_cache(&self, files: Vec<CacheUploadInput>) -> napi::Result<()> {
        let files = files
            .into_iter()
            .map(|file| CacheFile {
                table: file.table,
                path: file.path,
            })
            .collect::<Vec<_>>();
        self.inner
            .upload_effect_cache(&files)
            .await
            .map_err(to_napi)
    }

    #[napi]
    pub async fn dump_effect_cache(&self, files: Vec<CacheDump>) -> napi::Result<()> {
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
                .map(|(store, seconds)| WriteTiming { store, seconds })
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

impl JsStorage {
    fn begin<'env>(
        &self,
        env: &'env Env,
        rows: u32,
        kinds: &[ColumnKind],
        names: Vec<String>,
    ) -> napi::Result<Object<'env>> {
        let handle = self.next_handle.fetch_add(1, Ordering::Relaxed);
        self.staged.begin(env, handle, rows, kinds, names)
    }

    fn entity(&self, index: u32) -> napi::Result<Arc<super::schema::Entity>> {
        self.inner.schema.entity(index).cloned().map_err(to_napi)
    }

    fn hold(&self, result: ResultSet) -> QueryResult {
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
        result
    }

    fn bounds(&self, bounds: BoundsInput) -> napi::Result<Bounds> {
        same_length(
            "bound",
            &[bounds.chain_ids.len(), bounds.checkpoint_ids.len()],
        )?;
        Ok(Bounds {
            sequence: self.inner.schema.sequence,
            chain_ids: bounds.chain_ids,
            checkpoint_ids: checkpoint_ids(bounds.checkpoint_ids)?,
        })
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

    /// Takes every batch a write names out of the registry before anything
    /// can fail, so a write refused here frees them rather than leaving them
    /// for a `discardStaged` nobody makes.
    fn to_batch(&self, batch: BatchInput) -> napi::Result<Batch> {
        let mut problems = Vec::new();
        let raw_events = batch
            .raw_events
            .and_then(|handle| self.arena(handle, &mut problems));
        let changes = batch
            .changes
            .into_iter()
            .filter_map(|input| {
                let rows = self.arena(input.changes, &mut problems)?;
                let entity = self
                    .entity(input.entity)
                    .map_err(|error| problems.push(error))
                    .ok()?;
                ChangeSet::new(entity, input.chain_id, input.keeps_history, rows)
                    .map(Arc::new)
                    .map_err(|error| problems.push(to_napi(error)))
                    .ok()
            })
            .collect();
        let effect_caches = batch
            .effect_caches
            .into_iter()
            .filter_map(|write| {
                Some(EffectCacheWrite {
                    rows: self.arena(write.rows, &mut problems)?,
                    table: write.table,
                    create: write.create,
                })
            })
            .collect();
        if let Some(problem) = problems.into_iter().next() {
            return Err(problem);
        }
        let rollback = batch
            .rollback
            .map(|rollback| -> napi::Result<RollbackWrite> {
                Ok(RollbackWrite {
                    bounds: self.bounds(rollback.bounds)?,
                    progress: rollback.progress,
                    removed_addresses: addresses(rollback.removed_addresses)?,
                    diff_checkpoints: rollback
                        .diff_checkpoints
                        .into_iter()
                        .map(|diff| {
                            Ok(DiffCheckpoint {
                                chain_id: diff.chain_id,
                                checkpoint_id: checkpoint_id(&diff.checkpoint_id)?,
                                block_number: diff.block_number,
                            })
                        })
                        .collect::<napi::Result<_>>()?,
                })
            })
            .transpose()?;
        same_length(
            "frontier",
            &[
                batch.frontier.chain_ids.len(),
                batch.frontier.checkpoint_ids.len(),
            ],
        )?;
        let checkpoints = &batch.checkpoints;
        same_length(
            "checkpoint",
            &[
                checkpoints.ids.len(),
                checkpoints.chain_ids.len(),
                checkpoints.block_numbers.len(),
                checkpoints.block_hashes.len(),
                checkpoints.events_processed.len(),
                checkpoints.keeps_history.len(),
            ],
        )?;
        Ok(Batch {
            rollback,
            progress: batch.progress,
            raw_events,
            changes,
            chain_meta: batch.chain_meta,
            addresses: addresses(batch.addresses)?,
            frontier: Frontier {
                chain_ids: batch.frontier.chain_ids,
                checkpoint_ids: checkpoint_ids(batch.frontier.checkpoint_ids)?,
            },
            checkpoints: Checkpoints {
                ids: checkpoint_ids(batch.checkpoints.ids)?,
                chain_ids: batch.checkpoints.chain_ids,
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

/// Rows cross as one list per column, which every store reads by index
/// together: lists of different lengths are refused here rather than read past.
fn same_length(rows: &str, lengths: &[usize]) -> napi::Result<()> {
    if lengths.windows(2).all(|pair| pair[0] == pair[1]) {
        Ok(())
    } else {
        Err(napi::Error::from_reason(format!(
            "Internal error: the {rows} columns have different lengths, {lengths:?}"
        )))
    }
}

fn checkpoint_id(id: &BigInt) -> napi::Result<i64> {
    match id.get_i64() {
        (id, true) => Ok(id),
        (_, false) => Err(napi::Error::from_reason(
            "A checkpoint id is out of the 64-bit range",
        )),
    }
}

fn checkpoint_ids(ids: Vec<BigInt>) -> napi::Result<Vec<i64>> {
    ids.iter().map(checkpoint_id).collect()
}

fn addresses(addresses: AddressesInput) -> napi::Result<Addresses> {
    let mut lengths = vec![
        addresses.chain_ids.len(),
        addresses.addresses.len(),
        addresses.contract_ids.len(),
    ];
    lengths.extend(addresses.registration_blocks.as_ref().map(Vec::len));
    same_length("address", &lengths)?;
    Ok(Addresses {
        chain_ids: addresses.chain_ids,
        addresses: addresses
            .addresses
            .into_iter()
            .map(|bytes| bytes.to_vec())
            .collect(),
        contract_ids: addresses.contract_ids,
        registration_blocks: addresses.registration_blocks.unwrap_or_default(),
    })
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
