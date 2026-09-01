pub mod ch_type;
pub mod ddl;
#[cfg(test)]
mod mock_server;
pub mod row_binary;

use std::borrow::Cow;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use bytes::Bytes;
use napi::bindgen_prelude::{BigInt64Array, BigUint64Array, Float64Array, Uint8Array};
use napi::threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode};
use napi::{Env, Status};
use napi_derive::napi;

use crate::config_parsing::system_config::ChainIdMode;
use ch_type::{ChType, ColumnKind, FieldSpec};
use row_binary::{Column, ColumnValues, EncodedRows};

const MAX_RETRIES: u32 = 8;

/// `@clickhouse/client`'s `request_timeout` default, which the JS insert path
/// ran under. Without it a peer that accepts a connection and then goes silent
/// — a black-holed socket through a load balancer sends neither RST nor FIN —
/// leaves the request hanging forever, and with it the whole write batch.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
/// What a schema or maintenance statement gets instead. `DROP DATABASE ... SYNC`
/// and the reorg trim's `ALTER ... DELETE ... mutations_sync` both run for as
/// long as the data takes, so holding them to the insert deadline would fail a
/// restart on a large history table — the one case the trim exists for.
const STATEMENT_TIMEOUT: Duration = Duration::from_secs(600);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// Probes an idle pooled socket so a connection dropped by a NAT or proxy is
/// discovered before a batch is handed to it.
const TCP_KEEPALIVE: Duration = Duration::from_secs(30);
/// How long a pooled socket may sit idle before the client drops it. Deliberately
/// under ClickHouse's own `keep_alive_timeout` (3s on older servers, 10s by
/// default), which is the deadline that matters: past it the server closes the
/// socket, and a batch dispatched onto one already carrying a FIN fails with
/// `connection closed before message completed`. `@clickhouse/client` set its
/// `idle_socket_ttl` to 2.5s for the same reason.
const POOL_IDLE_TIMEOUT: Duration = Duration::from_millis(2_500);
const MAX_RETRY_DELAY: Duration = Duration::from_millis(1_000);
/// How long one batch may spend on the whole retry ladder. Halving turns a
/// failure into two more attempts, so a range that keeps failing costs
/// exponentially many requests — cheap when each is refused in milliseconds,
/// hours when each one first has to reach [`REQUEST_TIMEOUT`] against a peer
/// that accepts the connection and then goes silent. `retries` bounds how deep
/// a single range may go; this bounds what the batch as a whole may cost.
const RETRY_BUDGET: Duration = Duration::from_secs(120);

#[derive(Debug, Clone, Copy)]
struct Tuning {
    retries: u32,
    statement_timeout: Duration,
    max_retry_delay: Duration,
    request_timeout: Duration,
    retry_budget: Duration,
}

impl Default for Tuning {
    fn default() -> Self {
        Self {
            retries: MAX_RETRIES,
            max_retry_delay: MAX_RETRY_DELAY,
            request_timeout: REQUEST_TIMEOUT,
            statement_timeout: STATEMENT_TIMEOUT,
            retry_budget: RETRY_BUDGET,
        }
    }
}

impl Tuning {
    fn delay(&self, retries_left: u32) -> Duration {
        if self.retries < 2 {
            return Duration::ZERO;
        }
        let span = self.max_retry_delay.as_millis() as u64;
        Duration::from_millis(
            (span / 10
                + (span - span / 10) * u64::from(self.retries - retries_left)
                    / u64::from(self.retries - 1))
            .min(span),
        )
    }
}

#[napi(object)]
pub struct ColumnSpecInput {
    pub name: String,
    /// Omitted when it matches `name`, which it does unless a column rename is
    /// configured.
    pub field_name: Option<String>,
    pub field_type: String,
    pub is_nullable: Option<bool>,
    pub is_array: Option<bool>,
    pub precision: Option<u32>,
    pub scale: Option<u32>,
    pub enum_variants: Option<Vec<String>>,
}

impl From<ColumnSpecInput> for ddl::ColumnSpec {
    fn from(input: ColumnSpecInput) -> Self {
        let ColumnSpecInput {
            name,
            field_name,
            field_type,
            is_nullable,
            is_array,
            precision,
            scale,
            enum_variants,
        } = input;
        ddl::ColumnSpec {
            field_name: field_name.unwrap_or_else(|| name.clone()),
            name,
            field: FieldSpec {
                field_type,
                is_nullable: is_nullable.unwrap_or(false),
                is_array: is_array.unwrap_or(false),
                precision,
                scale,
                enum_variants,
            },
        }
    }
}

#[napi(object)]
pub struct EntitySpecInput {
    pub name: String,
    pub history_table: String,
    pub columns: Vec<ColumnSpecInput>,
    pub chain_id_column: Option<String>,
    pub partition_by: Option<String>,
    pub order_by: Option<Vec<String>>,
    pub ttl: Option<String>,
    pub skipping_indexes: Option<Vec<ddl::SkippingIndexSpec>>,
}

impl From<EntitySpecInput> for ddl::EntitySpec {
    fn from(input: EntitySpecInput) -> Self {
        ddl::EntitySpec {
            name: input.name,
            history_table: input.history_table,
            columns: input.columns.into_iter().map(Into::into).collect(),
            chain_id_column: input.chain_id_column,
            partition_by: input.partition_by,
            order_by: input.order_by,
            ttl: input.ttl,
            skipping_indexes: input.skipping_indexes.unwrap_or_default(),
        }
    }
}

#[napi(object)]
pub struct InitializeInput {
    pub entities: Vec<EntitySpecInput>,
    pub checkpoint_columns: Vec<ColumnSpecInput>,
    pub replicated: bool,
    pub database_engine: Option<String>,
}

#[napi(object)]
#[derive(Debug)]
pub struct RegisteredTable {
    pub handle: u32,
    pub names: Vec<String>,
    pub kinds: Vec<u8>,
    pub nullable: Vec<bool>,
}

/// How far a chain has been committed, as `envio_chains` records it.
#[napi(object)]
pub struct ChainProgressInput {
    /// Decimal digits: chain ids outrun what a JS number holds exactly.
    pub chain_id: String,
    pub progress_block_number: i32,
}

#[napi(object)]
pub struct ColumnValuesInput {
    pub numbers: Option<Float64Array>,
    pub unsigned64: Option<BigUint64Array>,
    pub signed64: Option<BigInt64Array>,
    pub texts: Option<Vec<String>>,
    pub nulls: Option<Uint8Array>,
}

struct ColumnSchema {
    name: String,
    ch_type: ChType,
    kind: ColumnKind,
}

struct TableSchema {
    table: String,
    columns: Vec<ColumnSchema>,
    insert_query: String,
}

struct StagedColumnValues {
    values: ColumnValues,
    nulls: Vec<u8>,
}

struct Staged {
    schema: Arc<TableSchema>,
    rows: usize,
    columns: Vec<StagedColumnValues>,
}

#[napi]
pub struct ClickHouseSink {
    client: reqwest::Client,
    url: String,
    username: String,
    password: String,
    database: String,
    tables: Mutex<HashMap<u32, Arc<TableSchema>>>,
    staged: Mutex<HashMap<u32, Staged>>,
    next_handle: AtomicU32,
    tuning: Tuning,
    warn: WarningSink,
    chain_id_mode: ChainIdMode,
    history: ddl::HistorySchema,
}

type WarningSink = Arc<dyn Fn(&str) + Send + Sync>;

#[napi(object)]
pub struct ClickHouseSinkOptions {
    pub url: String,
    pub username: String,
    pub password: String,
    pub database: String,
    pub chain_id_mode: String,
    pub history: ddl::HistorySchema,
}

/// Guards a number that is about to be spliced into a statement as itself.
fn digits_only(value: &str, what: &str) -> Result<()> {
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        bail!("`{value}` is not {what}");
    }
    Ok(())
}

/// Backtick-quotes an identifier. ClickHouse reads C-style escapes inside one
/// just as it does inside a string, so a backslash is doubled alongside the
/// backtick — left alone, a name holding `a\tb` would be created with a tab in
/// it.
pub(crate) fn quoted(name: &str) -> String {
    format!("`{}`", name.replace('\\', "\\\\").replace('`', "``"))
}

/// Single-quotes a string literal. ClickHouse reads C-style escapes inside one,
/// so a backslash has to be doubled as well as a quote — left alone, `a\tb`
/// would be stored as `a`, a tab, `b`.
pub(crate) fn literal(value: &str) -> String {
    format!("'{}'", value.replace('\\', "\\\\").replace('\'', "''"))
}

fn to_napi(err: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{err:#}"))
}

#[napi]
impl ClickHouseSink {
    #[napi(factory)]
    pub fn new(
        env: &Env,
        options: ClickHouseSinkOptions,
        mut on_warning: ThreadsafeFunction<String, (), String, Status, false>,
    ) -> napi::Result<Self> {
        // A referenced threadsafe function holds the event loop open, so a sink
        // that outlives the run keeps the whole process from exiting. The
        // deprecation points at the `Weak` type parameter instead, but a weak
        // callback can be collected once JS drops its own reference — which it
        // does immediately, the closure being passed inline — and warnings would
        // then stop arriving with nothing to show for it.
        #[allow(deprecated)]
        on_warning.unref(env)?;
        Self::build(
            options,
            Tuning::default(),
            Arc::new(move |message: &str| {
                on_warning.call(message.to_string(), ThreadsafeFunctionCallMode::NonBlocking);
            }),
        )
    }

    fn build(
        options: ClickHouseSinkOptions,
        tuning: Tuning,
        warn: WarningSink,
    ) -> napi::Result<Self> {
        let client = reqwest::Client::builder()
            .pool_idle_timeout(POOL_IDLE_TIMEOUT)
            .pool_max_idle_per_host(8)
            .timeout(tuning.request_timeout)
            .connect_timeout(CONNECT_TIMEOUT)
            .tcp_keepalive(TCP_KEEPALIVE)
            // reqwest picks up HTTP_PROXY/HTTPS_PROXY by default; Node's http
            // client never did, so honouring them here would silently start
            // routing a deployment's inserts through a proxy that nothing asked
            // to be in the path.
            .no_proxy()
            .build()
            .map_err(|e| napi::Error::from_reason(format!("Failed building HTTP client: {e}")))?;
        let chain_id_mode = ChainIdMode::parse(&options.chain_id_mode).map_err(to_napi)?;
        Ok(Self {
            client,
            url: options.url.trim_end_matches('/').to_string(),
            username: options.username,
            password: options.password,
            database: options.database,
            tables: Mutex::new(HashMap::new()),
            staged: Mutex::new(HashMap::new()),
            next_handle: AtomicU32::new(1),
            tuning,
            warn,
            chain_id_mode,
            history: options.history,
        })
    }

    #[napi]
    pub fn register_entity_table(&self, entity: EntitySpecInput) -> napi::Result<RegisteredTable> {
        let entity: ddl::EntitySpec = entity.into();
        let columns = entity
            .history_columns(&self.history, self.chain_id_mode)
            .map_err(to_napi)?;
        self.register(entity.history_table.clone(), columns)
    }

    #[napi]
    pub fn register_checkpoints_table(
        &self,
        columns: Vec<ColumnSpecInput>,
    ) -> napi::Result<RegisteredTable> {
        let columns = self
            .checkpoint_column_types(columns.into_iter().map(Into::into).collect())
            .map_err(to_napi)?;
        self.register(self.history.checkpoints_table.clone(), columns)
    }

    #[napi]
    pub async fn initialize(&self, input: InitializeInput) -> napi::Result<()> {
        self.initialize_inner(input).await.map_err(to_napi)
    }

    #[napi]
    pub async fn resume(
        &self,
        checkpoint_id: String,
        chain_progress: Vec<ChainProgressInput>,
    ) -> napi::Result<()> {
        self.resume_inner(&checkpoint_id, &chain_progress)
            .await
            .map_err(to_napi)
    }

    /// Copies a batch into Rust memory and returns a handle to pass to
    /// `write_batch`. Synchronous by necessity: reading a JS value needs the
    /// isolate. Columns arrive in the order they were registered.
    #[napi]
    pub fn stage(
        &self,
        table: u32,
        rows: u32,
        columns: Vec<ColumnValuesInput>,
    ) -> napi::Result<u32> {
        let schema = self.table_schema(table).map_err(to_napi)?;
        if columns.len() != schema.columns.len() {
            return Err(napi::Error::from_reason(format!(
                "ClickHouse table `{}` has {} column(s), got {} in a batch",
                schema.table,
                schema.columns.len(),
                columns.len()
            )));
        }
        let rows = rows as usize;
        let mut staged_columns = Vec::with_capacity(columns.len());
        for (column, spec) in columns.into_iter().zip(&schema.columns) {
            let ColumnValuesInput {
                numbers,
                unsigned64,
                signed64,
                texts,
                nulls,
            } = column;
            let name = &spec.name;
            let values = match (numbers, unsigned64, signed64, texts) {
                (Some(v), None, None, None) => ColumnValues::F64(v.to_vec()),
                (None, Some(v), None, None) => ColumnValues::U64(v.to_vec()),
                (None, None, Some(v), None) => ColumnValues::I64(v.to_vec()),
                (None, None, None, Some(v)) => ColumnValues::Text(v),
                _ => {
                    return Err(napi::Error::from_reason(format!(
                    "Column `{name}` must carry exactly one of numbers/unsigned64/signed64/texts"
                )))
                }
            };
            let staged_kind = values.kind();
            if staged_kind != spec.kind {
                return Err(napi::Error::from_reason(format!(
                    "Column `{name}` is {:?} and must be sent as {:?}, got {staged_kind:?}",
                    spec.ch_type, spec.kind
                )));
            }
            staged_columns.push(StagedColumnValues {
                values,
                nulls: nulls.map(|n| n.to_vec()).unwrap_or_default(),
            });
        }
        let handle = self.next_handle.fetch_add(1, Ordering::Relaxed);
        self.staged.lock().unwrap().insert(
            handle,
            Staged {
                schema,
                rows,
                columns: staged_columns,
            },
        );
        Ok(handle)
    }

    #[napi]
    pub async fn write_batch(
        &self,
        entities: Vec<u32>,
        checkpoints: Option<u32>,
    ) -> napi::Result<()> {
        let (staged, checkpoints) = self.take_staged(&entities, checkpoints).map_err(to_napi)?;

        futures_util::future::try_join_all(
            staged.into_iter().map(|staged| self.insert_staged(staged)),
        )
        .await
        .map_err(to_napi)?;

        if let Some(checkpoints) = checkpoints {
            self.insert_staged(checkpoints).await.map_err(to_napi)?;
        }
        Ok(())
    }

    #[napi]
    pub fn discard(&self, handles: Vec<u32>) {
        let mut staged = self.staged.lock().unwrap();
        for handle in handles {
            staged.remove(&handle);
        }
    }
}

impl ClickHouseSink {
    fn register(
        &self,
        table: String,
        columns: Vec<(String, ChType)>,
    ) -> napi::Result<RegisteredTable> {
        if columns.is_empty() {
            return Err(napi::Error::from_reason(format!(
                "ClickHouse table `{table}` was registered with no columns"
            )));
        }
        let columns: Vec<ColumnSchema> = columns
            .into_iter()
            .map(|(name, ch_type)| ColumnSchema {
                kind: ch_type.column_kind(),
                ch_type,
                name,
            })
            .collect();
        let names = columns.iter().map(|column| column.name.clone()).collect();
        let kinds = columns.iter().map(|column| column.kind as u8).collect();
        let nullable = columns
            .iter()
            .map(|column| matches!(column.ch_type, ChType::Nullable(_)))
            .collect();
        let insert_query = ddl::insert_query(
            &self.database,
            &table,
            columns.iter().map(|column| &column.name),
        );
        let handle = self.next_handle.fetch_add(1, Ordering::Relaxed);
        self.tables.lock().unwrap().insert(
            handle,
            Arc::new(TableSchema {
                table,
                columns,
                insert_query,
            }),
        );
        Ok(RegisteredTable {
            handle,
            names,
            kinds,
            nullable,
        })
    }

    fn checkpoint_column_types(
        &self,
        columns: Vec<ddl::ColumnSpec>,
    ) -> Result<Vec<(String, ChType)>> {
        let context = format!("ClickHouse table `{}`", self.history.checkpoints_table);
        columns
            .iter()
            .map(|column| column.typed(self.chain_id_mode, &context))
            .collect()
    }

    async fn initialize_inner(&self, input: InitializeInput) -> Result<()> {
        let InitializeInput {
            entities,
            checkpoint_columns,
            replicated: env_replicated,
            database_engine,
        } = input;
        let entities: Vec<ddl::EntitySpec> = entities.into_iter().map(Into::into).collect();
        let checkpoint_columns =
            self.checkpoint_column_types(checkpoint_columns.into_iter().map(Into::into).collect())?;

        let engine_name = database_engine.as_deref().map(ddl::database_engine_name);
        // A Replicated database engine only replicates data when its tables use
        // the ReplicatedMergeTree engine, so it implies replicated mode even
        // when ENVIO_CLICKHOUSE_REPLICATED is unset.
        let has_replicated_engine = engine_name == Some("Replicated");
        let replicated = env_replicated || has_replicated_engine;
        if has_replicated_engine && !env_replicated {
            (self.warn)(
                "ENVIO_CLICKHOUSE_DATABASE_ENGINE is Replicated; enabling replicated mode so \
                 tables use the ReplicatedMergeTree engine.",
            );
        }
        let topology = ddl::Topology {
            replicated,
            // DDL a Replicated database engine propagates itself must not carry
            // ON CLUSTER on top of it.
            ddl_on_cluster: replicated && !has_replicated_engine,
        };
        let database_ident = quoted(&self.database);

        if let Some(engine_spec) = &database_engine {
            let expected = ddl::database_engine_name(engine_spec);
            match self.existing_database_engine().await?.as_deref() {
                Some(engine) if engine != expected => bail!(
                    "ClickHouse database \"{}\" exists with engine \"{engine}\" but \
                     ENVIO_CLICKHOUSE_DATABASE_ENGINE specifies \"{expected}\" (from \
                     \"{engine_spec}\"). Drop the database manually to change its engine.",
                    self.database
                ),
                _ => {}
            }
        }

        let history_tables = entities
            .iter()
            .map(|entity| {
                ddl::create_history_table(
                    entity,
                    &self.database,
                    &self.history,
                    topology,
                    self.chain_id_mode,
                )
            })
            .collect::<Result<Vec<_>>>()?;

        if has_replicated_engine {
            // TRUNCATE DATABASE is unsupported on Replicated databases, so a
            // reset has to DROP and recreate instead. ON CLUSTER removes the
            // database from every node — the engine's own log can't replicate
            // the drop of the database it lives in — and SYNC waits for the drop
            // to finish before the CREATE below.
            self.post_statement(format!(
                "DROP DATABASE IF EXISTS {database_ident} ON CLUSTER '{{cluster}}' SYNC"
            ))
            .await?;
        } else {
            self.post_statement(format!(
                "TRUNCATE DATABASE IF EXISTS {database_ident}{}",
                ddl::on_cluster_clause(topology.ddl_on_cluster)
            ))
            .await?;
        }
        self.post_statement(format!(
            "CREATE DATABASE IF NOT EXISTS {database_ident}{}{}",
            ddl::on_cluster_clause(replicated),
            match &database_engine {
                Some(engine) => format!(" ENGINE = {engine}"),
                None => String::new(),
            }
        ))
        .await?;

        futures_util::future::try_join_all(
            history_tables
                .into_iter()
                .map(|query| self.post_statement(query)),
        )
        .await?;

        self.post_statement(ddl::create_checkpoints_table(
            &checkpoint_columns,
            &self.database,
            &self.history,
            topology,
        ))
        .await?;

        // The client pools HTTP connections, so consecutive statements may reach
        // different replicas, while a Replicated database applies DDL from its
        // Keeper log asynchronously. A CREATE VIEW is analyzed against the
        // node's local metadata and can land on a replica that hasn't applied
        // the table creates yet, failing with UNKNOWN_TABLE. Block until every
        // replica has caught up first. ON CLUSTER must precede the database name
        // in this command's grammar.
        if has_replicated_engine {
            self.post_statement(format!(
                "SYSTEM SYNC DATABASE REPLICA ON CLUSTER '{{cluster}}' {database_ident}"
            ))
            .await?;
        }

        futures_util::future::try_join_all(entities.iter().map(|entity| {
            self.post_statement(ddl::create_view(
                entity,
                &self.database,
                &self.history,
                topology,
            ))
        }))
        .await?;

        Ok(())
    }

    async fn existing_database_engine(&self) -> Result<Option<String>> {
        let answer = self
            .post_statement(format!(
                "SELECT engine FROM system.databases WHERE name = {} FORMAT TabSeparated",
                literal(&self.database)
            ))
            .await?;
        Ok(match answer.trim() {
            "" => None,
            engine => Some(engine.to_string()),
        })
    }

    /// The checkpoint a resume keeps everything up to.
    ///
    /// A checkpoint is Postgres-committed if either witness says so: it is at or
    /// below the committed checkpoint id, or it is at or below its chain's
    /// recorded progress. The second witness is the one that matters outside the
    /// reorg threshold, where Postgres saves no checkpoint at all — the
    /// committed id is then the one meaning "nothing committed" while ClickHouse
    /// holds every row of the backfill, and the chains restart from their
    /// progress instead of replaying it. Progress and checkpoints are written in
    /// the same transaction, so a checkpoint its chain's progress has passed is
    /// one whose rows a replay will not write again.
    async fn safe_checkpoint_id(
        &self,
        committed: &str,
        chain_progress: &[ChainProgressInput],
    ) -> Result<String> {
        let committed: u64 = committed.parse()?;
        if chain_progress.is_empty() {
            return Ok(committed.to_string());
        }
        let covered = chain_progress
            .iter()
            .map(|chain| {
                digits_only(&chain.chain_id, "a chain id")?;
                Ok(format!(
                    "({} = {} AND {} <= {})",
                    quoted(&self.history.checkpoint_chain_id_column),
                    chain.chain_id,
                    quoted(&self.history.checkpoint_block_number_column),
                    chain.progress_block_number
                ))
            })
            .collect::<Result<Vec<_>>>()?
            .join(" OR ");
        let id = quoted(&self.history.id_column);
        let answer = self
            .post_statement(format!(
                "SELECT minIf({id}, NOT ({covered})), max({id}) FROM {}.{} FORMAT TabSeparated",
                quoted(&self.database),
                quoted(&self.history.checkpoints_table)
            ))
            .await?;
        // Both aggregates answer 0 over no rows, and ids start at 1 — so a
        // checkpoint nobody's progress covers means every checkpoint is covered,
        // and the highest of them is the frontier. It is the highest rather than
        // "no trim" so that history rows left above the checkpoints by an
        // interrupted resume still go.
        let mut columns = answer.trim().split('\t').map(|column| {
            let column: u64 = column.trim().parse().unwrap_or_default();
            column
        });
        let first_uncovered = columns.next().unwrap_or_default();
        let highest = columns.next().unwrap_or_default();
        Ok(match first_uncovered {
            0 => highest,
            first => first - 1,
        }
        .max(committed)
        .to_string())
    }

    async fn resume_inner(
        &self,
        checkpoint_id: &str,
        chain_progress: &[ChainProgressInput],
    ) -> Result<()> {
        digits_only(checkpoint_id, "a checkpoint id")?;
        if self.existing_database_engine().await?.is_none() {
            bail!(
                "ClickHouse storage database \"{}\" not found. Please run \
                 'envio start -r' to reinitialize the indexer (it'll also drop Postgres \
                 database).",
                self.database
            );
        }

        let checkpoint_id = &self
            .safe_checkpoint_id(checkpoint_id, chain_progress)
            .await?;

        // `startsWith` rather than `LIKE`: the prefix holds underscores, which
        // LIKE reads as single-character wildcards. TabSeparated answers one
        // table name per line, which is all this reads.
        let tables = self
            .post_statement(format!(
                "SELECT name FROM system.tables WHERE database = {} AND \
                 startsWith(name, {}) FORMAT TabSeparated",
                literal(&self.database),
                literal(&self.history.history_table_prefix)
            ))
            .await?;
        futures_util::future::try_join_all(
            tables
                .lines()
                .map(str::trim)
                .filter(|table| !table.is_empty())
                .map(|table| {
                    self.post_statement(ddl::trim_history_table(
                        &self.database,
                        table,
                        &self.history,
                        checkpoint_id,
                    ))
                }),
        )
        .await?;

        self.post_statement(ddl::trim_checkpoints(
            &self.database,
            &self.history,
            checkpoint_id,
        ))
        .await?;
        Ok(())
    }

    fn table_schema(&self, handle: u32) -> Result<Arc<TableSchema>> {
        self.tables
            .lock()
            .unwrap()
            .get(&handle)
            .cloned()
            .with_context(|| format!("Unknown ClickHouse table handle {handle}"))
    }

    fn take_staged(
        &self,
        entities: &[u32],
        checkpoints: Option<u32>,
    ) -> Result<(Vec<Staged>, Option<Staged>)> {
        let (entities, checkpoints) = {
            let mut staged = self.staged.lock().unwrap();
            let entities: Vec<(u32, Option<Staged>)> = entities
                .iter()
                .map(|&handle| (handle, staged.remove(&handle)))
                .collect();
            let checkpoints = checkpoints.map(|handle| (handle, staged.remove(&handle)));
            (entities, checkpoints)
        };
        let found = |(handle, staged): (u32, Option<Staged>)| {
            staged.with_context(|| format!("Unknown staged ClickHouse batch {handle}"))
        };
        Ok((
            entities
                .into_iter()
                .map(found)
                .collect::<Result<Vec<_>>>()?,
            checkpoints.map(found).transpose()?,
        ))
    }

    async fn post_statement(&self, query: String) -> Result<String> {
        let response = self
            .client
            .post(&self.url)
            .timeout(self.tuning.statement_timeout)
            .basic_auth(&self.username, Some(&self.password))
            .body(query)
            .send()
            .await
            .context("ClickHouse request failed")?;
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        if !status.is_success() {
            bail!("ClickHouse returned {status}: {text}");
        }
        Ok(text)
    }

    async fn insert_staged(&self, staged: Staged) -> Result<()> {
        let Staged {
            schema,
            rows,
            columns,
        } = staged;
        let encode_schema = schema.clone();
        let encoded = tokio::task::spawn_blocking(move || {
            let columns: Vec<Column> = encode_schema
                .columns
                .iter()
                .zip(columns)
                .map(|(spec, values)| Column {
                    name: Cow::Borrowed(&spec.name),
                    ch_type: Cow::Borrowed(&spec.ch_type),
                    values: values.values,
                    nulls: values.nulls,
                })
                .collect();
            row_binary::encode(&columns, rows)
        })
        .await
        .context("ClickHouse encode task failed")?
        .with_context(|| {
            format!(
                "Failed encoding rows for ClickHouse table `{}`",
                schema.table
            )
        })?;
        if encoded.rows() == 0 {
            return Ok(());
        }
        self.insert_with_retry(&schema.table, &schema.insert_query, &encoded)
            .await
            .with_context(|| format!("Failed inserting into ClickHouse table `{}`", schema.table))
    }

    async fn insert_with_retry(
        &self,
        table: &str,
        query: &str,
        encoded: &EncodedRows,
    ) -> Result<()> {
        let mut failures = 0usize;
        let started = std::time::Instant::now();
        let mut pending = vec![(0usize, encoded.rows(), self.tuning.retries)];
        while let Some((start, end, retries)) = pending.pop() {
            match self.post_rows(query, encoded.slice(start, end)).await {
                Ok(()) => continue,
                Err(failure) => {
                    let spent = started.elapsed();
                    let out_of_budget = spent >= self.tuning.retry_budget;
                    if retries == 0
                        || out_of_budget
                        || matches!(failure.retry, Retry::Never | Retry::Ambiguous)
                    {
                        return Err(match (failures, out_of_budget) {
                            (0, _) => failure.error,
                            (n, false) => failure
                                .error
                                .context(format!("after {n} failed attempt(s)")),
                            (n, true) => failure.error.context(format!(
                                "after {n} failed attempt(s) over {spent:.1?}, which is all the \
                                 time one batch may spend retrying"
                            )),
                        });
                    }
                    failures += 1;
                    let rows = end - start;
                    (self.warn)(&format!(
                        "ClickHouse insert of {rows} row(s) into `{table}` failed, \
                         {retries} retries left: {:#}",
                        failure.error
                    ));
                    tokio::time::sleep(self.tuning.delay(retries)).await;
                    match failure.retry {
                        Retry::Halved if rows > 1 => {
                            let mid = start + rows / 2;
                            pending.push((mid, end, retries - 1));
                            pending.push((start, mid, retries - 1));
                        }
                        _ => pending.push((start, end, retries - 1)),
                    }
                }
            }
        }
        Ok(())
    }

    async fn post_rows(&self, query: &str, body: Bytes) -> std::result::Result<(), InsertFailure> {
        let request = self
            .client
            .post(&self.url)
            .query(&[("query", query), ("database", &self.database)])
            // Base64 of the credentials rather than the X-ClickHouse-User/Key
            // headers: a header value may only carry visible ASCII, so a password
            // with a non-ASCII character in it fails every request before it is
            // sent. `@clickhouse/client` authenticated this way too.
            .basic_auth(&self.username, Some(&self.password))
            .header("Content-Type", "application/octet-stream")
            .body(body);
        let response = match request.send().await {
            Ok(response) => response,
            Err(err) => {
                return Err(InsertFailure {
                    retry: retry_for_send_error(&err),
                    error: anyhow::Error::new(err).context("ClickHouse insert request failed"),
                });
            }
        };
        let status = response.status();
        if status.is_success() {
            return Ok(());
        }
        let text = response.text().await.unwrap_or_default();
        Err(InsertFailure {
            retry: retry_for(status, &text),
            error: anyhow!("ClickHouse returned {status}: {text}"),
        })
    }
}

struct InsertFailure {
    error: anyhow::Error,
    retry: Retry,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Retry {
    Never,
    SameRows,
    Halved,
    /// The server may already have the rows. Another send would double-write,
    /// so the batch fails and a restart trims back to the Postgres checkpoint.
    Ambiguous,
}

/// Conditions a smaller batch is answered differently by, because what ran out
/// was proportional to the batch's size. Resending is safe for a table in one
/// partition, where an insert commits a single part or none; an entity with its
/// own `partitionBy` writes a part per partition, and one of those already
/// committed would be sent again — the entity view's `LIMIT 1 BY` reads past the
/// duplicate, a direct query of the history table does not.
/// A resend can leave the same rows in the history table twice: insert dedup is
/// off on purpose (see `Topology::settings`) so trim-then-replay recovery works.
/// Duplicates cost storage, not correctness — the serving view collapses them
/// with `LIMIT 1 BY`, and a resent row repeats the id, checkpoint id and values
/// of the one it duplicates. So a verdict answers whether sending again has a
/// mechanism to go differently, not whether the rows could already have landed:
/// a batch that outran a deadline or a memory limit fits once it is smaller.
const HALVED_ERROR_CODES: &[u32] = &[
    173, // CANNOT_ALLOCATE_MEMORY
    241, // MEMORY_LIMIT_EXCEEDED
    159, // TIMEOUT_EXCEEDED
    209, // SOCKET_TIMEOUT
];

/// Failures that say nothing about size or reachability, so a resend is only the
/// same request again for the same likely answer.
const AMBIGUOUS_ERROR_CODES: &[u32] = &[
    210, // NETWORK_ERROR
    319, // UNKNOWN_STATUS_OF_INSERT
];

/// Codes that say the deployment or the rows are what failed — a table that is
/// not there, credentials the server does not accept, a value it cannot read.
/// No retry of any size talks it out of one.
const NEVER_ERROR_CODES: &[u32] = &[
    6,   // CANNOT_PARSE_TEXT
    16,  // NO_SUCH_COLUMN_IN_TABLE
    27,  // CANNOT_PARSE_INPUT_ASSERTION_FAILED
    33,  // CANNOT_READ_ALL_DATA
    44,  // ILLEGAL_COLUMN
    47,  // UNKNOWN_IDENTIFIER
    53,  // TYPE_MISMATCH
    60,  // UNKNOWN_TABLE
    62,  // SYNTAX_ERROR
    81,  // UNKNOWN_DATABASE
    117, // INCORRECT_DATA
    192, // UNKNOWN_USER
    193, // WRONG_PASSWORD
    194, // REQUIRED_PASSWORD
    497, // ACCESS_DENIED
    516, // AUTHENTICATION_FAILED
];

/// A request that never reached the server carries no risk of a double write, so
/// it is resent whole. A timeout is resent smaller: the deadline is the one
/// thing a halved batch meets differently, whether it ran out mid-upload or
/// waiting on the server to finish. Anything else that failed after the body
/// went out leaves the same unknown as 319.
fn retry_for_send_error(err: &reqwest::Error) -> Retry {
    if err.is_connect() {
        Retry::SameRows
    } else if err.is_timeout() {
        Retry::Halved
    } else {
        Retry::Ambiguous
    }
}

/// A code nobody has classified is retried rather than surfaced: an overloaded
/// server has far more codes for saying so than this file can enumerate, and the
/// retry budget bounds what being wrong costs. Only the lists above,
/// and a 4xx the server never wrote, end a write on the first answer.
fn retry_for(status: reqwest::StatusCode, body: &str) -> Retry {
    match clickhouse_error_code(body) {
        Some(code) if HALVED_ERROR_CODES.contains(&code) => Retry::Halved,
        Some(code) if AMBIGUOUS_ERROR_CODES.contains(&code) => Retry::Ambiguous,
        Some(code) if NEVER_ERROR_CODES.contains(&code) => Retry::Never,
        Some(_) => Retry::SameRows,
        // Nothing in the body is ClickHouse's, so something in front of it
        // answered — a proxy or load balancer — and only its status says what.
        None => match status {
            // A body-size limit is the one proxy verdict a smaller batch meets
            // differently. Left unretried, a batch that outgrows the limit fails
            // the same way on every restart.
            reqwest::StatusCode::PAYLOAD_TOO_LARGE => Retry::Halved,
            // Rate limiting counts requests, so halving spends the budget
            // faster, and a 5xx from in front of ClickHouse is the same shape of
            // answer — an overloaded proxy, a refused upstream.
            reqwest::StatusCode::TOO_MANY_REQUESTS => Retry::SameRows,
            status if status.is_server_error() => Retry::SameRows,
            // Any other 4xx is the deployment's own configuration —
            // credentials, a route — which no smaller batch talks it out of.
            _ => Retry::Never,
        },
    }
}

/// The code out of a ClickHouse error body. A proxy in front of the server can
/// quote a `Code:` of its own, so the marker ClickHouse puts in every exception
/// it writes is what makes the number the server's own verdict rather than
/// someone else's.
fn clickhouse_error_code(body: &str) -> Option<u32> {
    if !body.contains("DB::Exception") {
        return None;
    }
    let digits: String = body
        .split_once("Code: ")?
        .1
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    digits.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    fn text_values(values: &[&str]) -> ColumnValuesInput {
        ColumnValuesInput {
            numbers: None,
            unsigned64: None,
            signed64: None,
            texts: Some(values.iter().map(|v| v.to_string()).collect()),
            nulls: None,
        }
    }

    fn spec(name: &str, field_type: &str) -> ColumnSpecInput {
        ColumnSpecInput {
            name: name.to_string(),
            field_name: None,
            field_type: field_type.to_string(),
            is_nullable: None,
            is_array: None,
            precision: None,
            scale: None,
            enum_variants: None,
        }
    }

    fn options(url: String) -> ClickHouseSinkOptions {
        ClickHouseSinkOptions {
            url,
            username: "default".to_string(),
            password: String::new(),
            database: "mock".to_string(),
            chain_id_mode: "int32".to_string(),
            history: ddl::test_support::history_schema(),
        }
    }

    #[test]
    fn a_literal_survives_whatever_it_is_given() {
        let escaped = [
            r"abc\",
            r"a\'b",
            "it's",
            "''",
            r"a\tb",
            "x'; DROP TABLE y; --",
            "plain",
        ]
        .map(literal);
        assert_eq!(
            escaped,
            [
                r"'abc\\'",
                r"'a\\''b'",
                "'it''s'",
                "''''''",
                r"'a\\tb'",
                "'x''; DROP TABLE y; --'",
                "'plain'",
            ]
        );
    }

    #[test]
    fn registering_rejects_a_field_type_it_cannot_encode() {
        let server_less = ClickHouseSink::build(
            options("http://127.0.0.1:1".to_string()),
            Tuning::default(),
            Arc::new(|_: &str| {}),
        )
        .unwrap();

        let err = server_less
            .register_checkpoints_table(vec![spec("t", "Tuple")])
            .unwrap_err();

        assert_eq!(
            err.reason,
            "Column `t` of ClickHouse table `envio_checkpoints`: unsupported field type `Tuple`"
        );
    }

    fn resume_answers(engine: &str, tables: &[&str]) -> Arc<mock_server::StatementFn> {
        resume_answers_with(engine, tables, "0")
    }

    /// `first_uncovered` is what the checkpoints table answers for the first
    /// checkpoint past a chain's recorded progress: `0` for none.
    fn resume_answers_with(
        engine: &str,
        tables: &[&str],
        first_uncovered: &str,
    ) -> Arc<mock_server::StatementFn> {
        let engine = engine.to_string();
        let tables = tables.join("\n");
        let first_uncovered = first_uncovered.to_string();
        Arc::new(move |statement: &str| {
            if statement.contains("system.databases") {
                (200, engine.clone())
            } else if statement.contains("system.tables") {
                (200, tables.clone())
            } else if statement.contains("minIf(") {
                (200, first_uncovered.clone())
            } else {
                (200, String::new())
            }
        })
    }

    fn progress(chain_id: &str, progress_block_number: i32) -> ChainProgressInput {
        ChainProgressInput {
            chain_id: chain_id.to_string(),
            progress_block_number,
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_resume_that_cannot_reach_the_server_does_not_report_a_missing_database() {
        let unreachable = ClickHouseSink::build(
            options("http://127.0.0.1:1".to_string()),
            Tuning::default(),
            Arc::new(|_: &str| {}),
        )
        .unwrap();

        let err = unreachable
            .resume("42".to_string(), Vec::new())
            .await
            .unwrap_err();

        assert_eq!(
            (
                err.reason.contains("start -r"),
                err.reason.contains("ClickHouse request failed"),
            ),
            (false, true),
            "got: {}",
            err.reason
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_resume_a_proxy_refuses_does_not_report_a_missing_database() {
        let server = mock_server::MockClickHouse::answering_statements(Arc::new(|_: &str| {
            (502, "upstream connect error".to_string())
        }))
        .await;
        let sink = sink_for(&server, 4);

        let err = sink.resume("42".to_string(), Vec::new()).await.unwrap_err();

        assert_eq!(
            (
                err.reason.contains("start -r"),
                err.reason.contains("upstream connect error"),
            ),
            (false, true),
            "got: {}",
            err.reason
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_resume_against_a_database_that_is_gone_says_how_to_reinitialize() {
        let server =
            mock_server::MockClickHouse::answering_statements(resume_answers("", &[])).await;
        let sink = sink_for(&server, 4);

        let err = sink.resume("42".to_string(), Vec::new()).await.unwrap_err();

        assert_eq!(
            (
                err.reason.contains("start -r"),
                err.reason.contains("\"mock\" not found"),
            ),
            (true, true),
            "got: {}",
            err.reason
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_resume_trims_every_history_table_and_then_the_checkpoints() {
        let server = mock_server::MockClickHouse::answering_statements(resume_answers(
            "Atomic",
            &["envio_history_a", "envio_history_b"],
        ))
        .await;
        let sink = sink_for(&server, 4);

        sink.resume("42".to_string(), Vec::new()).await.unwrap();

        let mut trims: Vec<String> = server
            .statements_seen()
            .into_iter()
            .filter(|statement| statement.starts_with("ALTER") || statement.starts_with("DELETE"))
            .collect();
        let checkpoints = trims.pop();
        trims.sort();
        assert_eq!(
            (trims, checkpoints),
            (
                vec![
                    "ALTER TABLE `mock`.`envio_history_a` DELETE WHERE `envio_checkpoint_id` > 42 \
                     SETTINGS mutations_sync = 2"
                        .to_string(),
                    "ALTER TABLE `mock`.`envio_history_b` DELETE WHERE `envio_checkpoint_id` > 42 \
                     SETTINGS mutations_sync = 2"
                        .to_string(),
                ],
                Some(
                    "DELETE FROM `mock`.`envio_checkpoints` WHERE `id` > 42 \
                     SETTINGS lightweight_deletes_sync = 2"
                        .to_string()
                )
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_resume_during_backfill_keeps_what_each_chains_progress_covers() {
        let server = mock_server::MockClickHouse::answering_statements(resume_answers_with(
            "Atomic",
            &["envio_history_a"],
            "7",
        ))
        .await;
        let sink = sink_for(&server, 4);

        // What Postgres commits during backfill: no checkpoint at all.
        sink.resume(
            "0".to_string(),
            vec![progress("1", 10), progress("137", -1)],
        )
        .await
        .unwrap();

        let statements = server.statements_seen();
        assert_eq!(
            (
                statements
                    .iter()
                    .find(|statement| statement.starts_with("SELECT minIf(")),
                statements
                    .iter()
                    .find(|statement| statement.starts_with("ALTER")),
            ),
            (
                Some(
                    &"SELECT minIf(`id`, NOT ((`chain_id` = 1 AND `block_number` <= 10) OR \
                      (`chain_id` = 137 AND `block_number` <= -1))), max(`id`) \
                      FROM `mock`.`envio_checkpoints` FORMAT TabSeparated"
                        .to_string()
                ),
                Some(
                    &"ALTER TABLE `mock`.`envio_history_a` DELETE WHERE `envio_checkpoint_id` > 6 \
                      SETTINGS mutations_sync = 2"
                        .to_string()
                ),
            ),
            "got: {statements:?}"
        );
    }

    /// The mixed case: one chain inside the reorg threshold saving checkpoints,
    /// another still backfilling and saving none. The committed id only accounts
    /// for the first, so progress is what keeps the second one's rows.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_resume_keeps_what_progress_covers_past_the_committed_checkpoint() {
        let server = mock_server::MockClickHouse::answering_statements(resume_answers_with(
            "Atomic",
            &["envio_history_a"],
            "99",
        ))
        .await;
        let sink = sink_for(&server, 4);

        sink.resume("42".to_string(), vec![progress("1", 10)])
            .await
            .unwrap();

        assert_eq!(
            server
                .statements_seen()
                .iter()
                .find(|statement| statement.starts_with("ALTER")),
            Some(
                &"ALTER TABLE `mock`.`envio_history_a` DELETE WHERE `envio_checkpoint_id` > 98 \
                  SETTINGS mutations_sync = 2"
                    .to_string()
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_resume_that_every_chains_progress_covers_trims_to_the_last_checkpoint() {
        let server =
            mock_server::MockClickHouse::answering_statements(Arc::new(|statement: &str| {
                match statement {
                    _ if statement.contains("system.databases") => (200, "Atomic".to_string()),
                    _ if statement.contains("system.tables") => {
                        (200, "envio_history_a".to_string())
                    }
                    // No checkpoint past a chain's progress, and 12 is the highest.
                    _ if statement.contains("minIf(") => (200, "0\t12".to_string()),
                    _ => (200, String::new()),
                }
            }))
            .await;
        let sink = sink_for(&server, 4);

        sink.resume("0".to_string(), vec![progress("1", 500)])
            .await
            .unwrap();

        assert_eq!(
            server
                .statements_seen()
                .iter()
                .find(|statement| statement.starts_with("ALTER")),
            Some(
                &"ALTER TABLE `mock`.`envio_history_a` DELETE WHERE `envio_checkpoint_id` > 12 \
                  SETTINGS mutations_sync = 2"
                    .to_string()
            )
        );
    }

    struct TestSink {
        sink: ClickHouseSink,
        warnings: Arc<Mutex<Vec<String>>>,
    }

    impl TestSink {
        fn warnings(&self) -> Vec<String> {
            self.warnings.lock().unwrap().clone()
        }
    }

    impl std::ops::Deref for TestSink {
        type Target = ClickHouseSink;
        fn deref(&self) -> &ClickHouseSink {
            &self.sink
        }
    }

    fn sink_at(url: String, tuning: Tuning) -> TestSink {
        let warnings = Arc::new(Mutex::new(Vec::new()));
        let collected = warnings.clone();
        let sink = ClickHouseSink::build(
            options(url),
            tuning,
            Arc::new(move |message: &str| collected.lock().unwrap().push(message.to_string())),
        )
        .unwrap();
        TestSink { sink, warnings }
    }

    fn sink_with(server: &mock_server::MockClickHouse, tuning: Tuning) -> TestSink {
        sink_at(server.url.clone(), tuning)
    }

    fn sink_for(server: &mock_server::MockClickHouse, retries: u32) -> TestSink {
        sink_with(
            server,
            Tuning {
                retries,
                max_retry_delay: Duration::ZERO,
                ..Tuning::default()
            },
        )
    }

    fn stage_ids(sink: &ClickHouseSink, values: &[&str]) -> u32 {
        let table = sink
            .register_checkpoints_table(vec![spec("id", "String")])
            .unwrap();
        sink.stage(table.handle, values.len() as u32, vec![text_values(values)])
            .unwrap()
    }

    async fn write(sink: &ClickHouseSink, handle: u32) -> napi::Result<()> {
        sink.write_batch(vec![handle], None).await
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_write_naming_an_unknown_handle_frees_the_batches_beside_it() {
        let server = mock_server::MockClickHouse::start(0).await;
        let sink = sink_for(&server, 4);
        let first = stage_ids(&sink, &["a"]);
        let last = stage_ids(&sink, &["b"]);
        let unknown = last + 1;

        let err = sink
            .write_batch(vec![first, unknown, last], None)
            .await
            .unwrap_err();

        assert_eq!(
            (
                err.reason.contains("Unknown staged ClickHouse batch"),
                sink.staged.lock().unwrap().len()
            ),
            (true, 0),
            "expected an unknown-handle error, got: {}",
            err.reason
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_rejected_insert_is_retried_as_halves_and_every_row_lands_once() {
        let server = mock_server::MockClickHouse::start(1).await;
        let sink = sink_for(&server, 4);
        let handle = stage_ids(&sink, &["a", "b", "c", "d"]);

        write(&sink, handle).await.unwrap();

        assert_eq!(
            (
                server.accepted_strings(),
                server.inserts_seen(),
                sink.warnings().len()
            ),
            (
                vec![
                    "a".to_string(),
                    "b".to_string(),
                    "c".to_string(),
                    "d".to_string()
                ],
                3,
                1
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_condition_the_batch_is_not_to_blame_for_is_retried_whole() {
        let server = mock_server::MockClickHouse::rejecting_with(
            2,
            "Code: 242. DB::Exception: Table is in readonly mode",
        )
        .await;
        let sink = sink_for(&server, 4);
        let handle = stage_ids(&sink, &["a", "b", "c", "d"]);

        write(&sink, handle).await.unwrap();

        assert_eq!(
            (server.accepted_batches(), server.inserts_seen()),
            (
                vec![vec![
                    "a".to_string(),
                    "b".to_string(),
                    "c".to_string(),
                    "d".to_string()
                ]],
                3
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_batch_too_large_for_a_proxy_is_retried_in_halves() {
        let server = mock_server::MockClickHouse::rejecting_with_status(
            1,
            413,
            "<html>413 Request Entity Too Large</html>",
        )
        .await;
        let sink = sink_for(&server, 4);
        let handle = stage_ids(&sink, &["a", "b", "c", "d"]);

        write(&sink, handle).await.unwrap();

        assert_eq!(
            (server.accepted_batches(), server.inserts_seen()),
            (
                vec![
                    vec!["a".to_string(), "b".to_string()],
                    vec!["c".to_string(), "d".to_string()]
                ],
                3
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_proxy_that_is_overloaded_is_retried_whole() {
        let server = mock_server::MockClickHouse::rejecting_with_status(
            2,
            503,
            "<html>503 Service Temporarily Unavailable</html>",
        )
        .await;
        let sink = sink_for(&server, 4);
        let handle = stage_ids(&sink, &["a", "b", "c", "d"]);

        write(&sink, handle).await.unwrap();

        assert_eq!(
            (server.accepted_batches(), server.inserts_seen()),
            (
                vec![vec![
                    "a".to_string(),
                    "b".to_string(),
                    "c".to_string(),
                    "d".to_string()
                ]],
                3
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_proxy_rejection_a_smaller_batch_cannot_answer_is_not_retried() {
        let server =
            mock_server::MockClickHouse::rejecting_with_status(usize::MAX, 403, "Forbidden").await;
        let sink = sink_for(&server, 8);
        let handle = stage_ids(&sink, &["a", "b"]);

        let err = write(&sink, handle).await.unwrap_err();

        assert_eq!(
            (err.reason.contains("403"), server.inserts_seen()),
            (true, 1),
            "expected a single attempt and the proxy's status, got: {}",
            err.reason
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_single_row_is_retried_in_place_until_it_lands() {
        let server = mock_server::MockClickHouse::start(2).await;
        let sink = sink_for(&server, 4);
        let handle = stage_ids(&sink, &["only"]);

        write(&sink, handle).await.unwrap();

        assert_eq!(
            (server.accepted_strings(), server.inserts_seen()),
            (vec!["only".to_string()], 3)
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn an_insert_that_never_succeeds_surfaces_the_error() {
        let server = mock_server::MockClickHouse::start(usize::MAX).await;
        let sink = sink_for(&server, 2);
        let handle = stage_ids(&sink, &["a", "b"]);

        let err = write(&sink, handle).await.unwrap_err();

        assert_eq!(
            (
                err.reason.contains("mock rejection"),
                err.reason.contains("envio_checkpoints"),
                server.accepted_strings()
            ),
            (true, true, Vec::<String>::new()),
            "expected the server's message and the table, got: {}",
            err.reason
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_rejection_the_rows_are_to_blame_for_is_not_retried() {
        let server = mock_server::MockClickHouse::rejecting_with(
            usize::MAX,
            "Code: 60. DB::Exception: Table mock.t does not exist",
        )
        .await;
        let sink = sink_for(&server, 8);
        let handle = stage_ids(&sink, &["a", "b", "c", "d"]);

        let err = write(&sink, handle).await.unwrap_err();

        assert_eq!(
            (
                err.reason.contains("does not exist"),
                server.inserts_seen(),
                sink.warnings()
            ),
            (true, 1, Vec::<String>::new()),
            "expected one attempt and the server's message, got: {}",
            err.reason
        );
    }

    /// An address nothing listens on, so every connection to it is refused.
    async fn refused_url() -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);
        url
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_refused_connection_is_retried() {
        let sink = sink_at(
            refused_url().await,
            Tuning {
                retries: 3,
                max_retry_delay: Duration::ZERO,
                ..Tuning::default()
            },
        );
        let handle = stage_ids(&sink, &["a"]);

        let err = write(&sink, handle).await.unwrap_err();

        assert_eq!(
            (
                err.reason.contains("ClickHouse insert request failed"),
                sink.warnings().len(),
                sink.warnings()
                    .first()
                    .is_some_and(|warning| warning.contains("3 retries left")),
            ),
            (true, 3, true),
            "expected three retries counted down from three, got: {:?} / {}",
            sink.warnings(),
            err.reason
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_transient_code_nobody_listed_is_retried_whole() {
        let server = mock_server::MockClickHouse::rejecting_with(
            2,
            "Code: 439. DB::Exception: Cannot schedule a task",
        )
        .await;
        let sink = sink_for(&server, 4);
        let handle = stage_ids(&sink, &["a", "b"]);

        write(&sink, handle).await.unwrap();

        assert_eq!(
            (server.accepted_batches(), server.inserts_seen()),
            (vec![vec!["a".to_string(), "b".to_string()]], 3)
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_proxy_page_quoting_a_code_is_read_as_the_proxys_own() {
        let server = mock_server::MockClickHouse::rejecting_with_status(
            1,
            502,
            "Error Code: 60. upstream unavailable",
        )
        .await;
        let sink = sink_for(&server, 4);
        let handle = stage_ids(&sink, &["a", "b"]);

        write(&sink, handle).await.unwrap();

        assert_eq!(
            (server.accepted_batches(), server.inserts_seen()),
            (vec![vec!["a".to_string(), "b".to_string()]], 2)
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn an_insert_whose_status_is_unknown_is_not_resent() {
        let server = mock_server::MockClickHouse::accepting_then_erroring(
            1,
            "Code: 319. DB::Exception: Unknown status of insert",
        )
        .await;
        let sink = sink_for(&server, 4);
        let handle = stage_ids(&sink, &["a", "b", "c", "d"]);

        let err = write(&sink, handle).await.unwrap_err();

        assert_eq!(
            (
                err.reason.contains("319"),
                server.inserts_seen(),
                server.accepted_batches(),
            ),
            (
                true,
                1,
                vec![vec![
                    "a".to_string(),
                    "b".to_string(),
                    "c".to_string(),
                    "d".to_string()
                ]],
            ),
            "expected one accepted insert of the original four, got: {}",
            err.reason
        );
    }

    /// The row counts each warning reports, in order — the shape of the retry
    /// ladder a batch walked before giving up.
    fn retried_row_counts(sink: &TestSink) -> Vec<String> {
        sink.warnings()
            .iter()
            .filter_map(|warning| {
                let rest = warning.strip_prefix("ClickHouse insert of ")?;
                let (count, _) = rest.split_once(" row(s)")?;
                Some(count.to_string())
            })
            .collect()
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_request_that_times_out_is_retried_as_halves() {
        let server = mock_server::MockClickHouse::start_unresponsive().await;
        let sink = sink_with(
            &server,
            Tuning {
                retries: 3,
                max_retry_delay: Duration::ZERO,
                request_timeout: Duration::from_millis(150),
                statement_timeout: Duration::from_millis(150),
                ..Tuning::default()
            },
        );
        let handle = stage_ids(&sink, &["a", "b", "c", "d"]);

        let err = write(&sink, handle).await.unwrap_err();

        assert_eq!(
            (
                retried_row_counts(&sink),
                err.reason.contains("operation timed out"),
            ),
            (
                vec!["4".to_string(), "2".to_string(), "1".to_string()],
                true
            ),
            "expected the batch to be halved on the way down, got: {}",
            err.reason
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_batch_stops_retrying_once_it_is_out_of_time() {
        let sink = sink_at(
            refused_url().await,
            Tuning {
                retries: 8,
                max_retry_delay: Duration::ZERO,
                retry_budget: Duration::ZERO,
                ..Tuning::default()
            },
        );
        let handle = stage_ids(&sink, &["a", "b", "c", "d"]);

        let err = write(&sink, handle).await.unwrap_err();

        assert_eq!(
            (
                retried_row_counts(&sink),
                err.reason.contains("ClickHouse insert request failed"),
            ),
            (Vec::<String>::new(), true),
            "expected the first failure to end the batch, got: {}",
            err.reason
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_server_that_never_answers_times_out_rather_than_hanging() {
        let server = mock_server::MockClickHouse::start_unresponsive().await;
        let sink = sink_with(
            &server,
            Tuning {
                retries: 1,
                max_retry_delay: Duration::ZERO,
                request_timeout: Duration::from_millis(150),
                statement_timeout: Duration::from_millis(150),
                ..Tuning::default()
            },
        );
        let handle = stage_ids(&sink, &["a"]);

        let err = write(&sink, handle).await.unwrap_err();

        assert_eq!(
            err.reason.contains("operation timed out"),
            true,
            "expected a timeout, got: {}",
            err.reason
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn the_sink_asks_the_server_for_nothing_but_the_insert() {
        let server = mock_server::MockClickHouse::start(0).await;
        let sink = sink_for(&server, 4);
        for _ in 0..3 {
            let handle = stage_ids(&sink, &["x"]);
            write(&sink, handle).await.unwrap();
        }
        assert_eq!((server.inserts_seen(), server.queries_seen()), (3, 0));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_value_the_column_cannot_hold_fails_before_anything_is_sent() {
        let server = mock_server::MockClickHouse::start(0).await;
        let sink = sink_for(&server, 4);
        let table = sink
            .register_checkpoints_table(vec![ColumnSpecInput {
                enum_variants: Some(vec!["SET".to_string()]),
                ..spec("e", "Enum")
            }])
            .unwrap();
        let handle = sink
            .stage(table.handle, 1, vec![text_values(&["NOPE"])])
            .unwrap();

        let err = write(&sink, handle).await.unwrap_err();

        assert_eq!(
            (err.reason.contains("not a variant"), server.inserts_seen()),
            (true, 0),
            "expected the encoder's message, got: {}",
            err.reason
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_non_ascii_password_still_authenticates() {
        let server = mock_server::MockClickHouse::start(0).await;
        let sink = ClickHouseSink::build(
            ClickHouseSinkOptions {
                username: "défaut".to_string(),
                password: "pässwörd".to_string(),
                ..options(server.url.clone())
            },
            Tuning::default(),
            Arc::new(|_: &str| ()),
        )
        .unwrap();
        let handle = stage_ids(&sink, &["a"]);

        write(&sink, handle).await.unwrap();

        let head = server.heads().first().cloned().unwrap_or_default();
        assert_eq!(
            (
                head.to_lowercase().contains(
                    "authorization: basic ZMOpZmF1dDpww6Rzc3fDtnJk"
                        .to_lowercase()
                        .as_str()
                ),
                head.contains("database=mock"),
                server.accepted_strings()
            ),
            (true, true, vec!["a".to_string()]),
            "expected a Basic credential, got head: {head}"
        );
    }
}
