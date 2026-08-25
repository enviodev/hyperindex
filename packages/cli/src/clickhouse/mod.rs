//! The ClickHouse write path.
//!
//! Everything the runtime sends ClickHouse goes through here: the DDL and the
//! reorg cleanup as plain statements, and the batch inserts as RowBinary. The
//! hot path never touches the Node main thread — column values cross the
//! boundary columnar, get encoded in Rust, and are sent from a tokio task.
//!
//! A table is registered once, before any batch. Registration derives each
//! column's type from the schema field it stores and builds the insert
//! statement, so a batch carries nothing but values and a handle.
//!
//! Splitting `stage` from `write_batch` is what makes the second half
//! off-thread work: a JS value can only be read while holding the isolate, so
//! `stage` copies the batch into owned Rust memory on the JS thread and
//! `write_batch` does the encoding and the HTTP round trips on the tokio pool.
//!
//! The runtime hands over the schema rather than ClickHouse types; `ch_type`
//! turns it into both the DDL and the encoder's layout.
//!
//! The encoding and transport are the crate's own rather than the `clickhouse`
//! crate's, because both ends of this path are shapes its row-oriented serde API
//! has no room for: values arrive as one array per column with a separate null
//! mask, and a body has to stay sliceable at row boundaries afterwards so a
//! failed insert can be retried in halves.

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

use ch_type::{ChType, ChainIdMode, ColumnKind, FieldSpec};
use row_binary::{Column, ColumnValues, EncodedRows};

/// Retries an insert this many times before giving up, as the JS client did.
/// What each retry sends is [`retry_for`]'s to decide.
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
/// The longest a retry waits, which the delay ramps up to.
const MAX_RETRY_DELAY: Duration = Duration::from_millis(1_000);

/// Knobs the tests turn down so a run takes milliseconds: the retry waits and
/// the request timeout a hanging server has to trip.
#[derive(Debug, Clone, Copy)]
struct Tuning {
    attempts: u32,
    /// Deadline for a schema or maintenance statement, which is not the insert
    /// deadline: these run as long as the data takes.
    statement_timeout: Duration,
    /// Ceiling on the retry backoff. Tests pass `ZERO` to skip the waits, which
    /// are the policy's concern rather than the encoder's.
    max_retry_delay: Duration,
    request_timeout: Duration,
}

impl Default for Tuning {
    fn default() -> Self {
        Self {
            attempts: MAX_RETRIES,
            max_retry_delay: MAX_RETRY_DELAY,
            request_timeout: REQUEST_TIMEOUT,
            statement_timeout: STATEMENT_TIMEOUT,
        }
    }
}

impl Tuning {
    /// Grows from a tenth of the ceiling up to it as the remaining retries run
    /// down.
    fn delay(&self, retries_left: u32) -> Duration {
        if self.attempts < 2 {
            return Duration::ZERO;
        }
        let span = self.max_retry_delay.as_millis() as u64;
        Duration::from_millis(
            (span / 10
                + (span - span / 10) * u64::from(self.attempts - retries_left)
                    / u64::from(self.attempts - 1))
            .min(span),
        )
    }
}

/// A column of a table the caller is registering: the name it goes by, the
/// schema field name a user-written table expression references it by, and the
/// field it stores.
#[napi(object)]
pub struct ColumnSpecInput {
    pub name: String,
    /// Omitted when it matches `name`, which it does unless a column rename is
    /// configured.
    pub field_name: Option<String>,
    /// One of `Table.fieldType`'s tags.
    pub field_type: String,
    pub is_nullable: Option<bool>,
    pub is_array: Option<bool>,
    /// A `BigInt`'s digit count or a `BigDecimal`'s precision.
    pub precision: Option<u32>,
    /// A `BigDecimal`'s scale.
    pub scale: Option<u32>,
    /// An `Enum`'s variants, in the order their numbering follows.
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

/// One entity as the sink needs it: the table its history goes to, the columns
/// it declares, and the layout options its `@storage` directive asked for.
#[napi(object)]
pub struct EntitySpecInput {
    pub name: String,
    pub history_table: String,
    pub columns: Vec<ColumnSpecInput>,
    /// Set when the entity is per-chain, which the current-state view dedups on.
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

/// Everything `initialize` creates, in one crossing.
#[napi(object)]
pub struct InitializeInput {
    pub entities: Vec<EntitySpecInput>,
    pub checkpoint_columns: Vec<ColumnSpecInput>,
    /// `ENVIO_CLICKHOUSE_REPLICATED`.
    pub replicated: bool,
    /// `ENVIO_CLICKHOUSE_DATABASE_ENGINE`.
    pub database_engine: Option<String>,
}

/// What a caller needs back to feed a registered table: the handle every batch
/// quotes, and the wire kind each column must be sent as.
#[napi(object)]
#[derive(Debug)]
pub struct RegisteredTable {
    pub handle: u32,
    /// Every column the table declares, in the order a batch must send them.
    /// A history table carries the checkpoint id and change columns this side
    /// appends, so the list runs past the entity's own.
    pub names: Vec<String>,
    pub kinds: Vec<u8>,
    /// Whether each column accepts NULL. A batch that has no value for a column
    /// that does not is refused rather than stored as the type's zero.
    pub nullable: Vec<bool>,
}

/// One column's values as they cross the napi boundary. Exactly one of the
/// value fields is set, and which one is settled by the registered type rather
/// than sent alongside every batch.
#[napi(object)]
pub struct ColumnValuesInput {
    /// Int32, UInt32, Float64, Bool (0/1), DateTime64 (ticks).
    pub numbers: Option<Float64Array>,
    /// UInt64, which loses precision as an f64.
    pub unsigned64: Option<BigUint64Array>,
    /// Int64.
    pub signed64: Option<BigInt64Array>,
    /// String, Decimal, Enum, and the JSON of an Array column.
    pub texts: Option<Vec<String>>,
    /// `1` marks a NULL. Omitted when the column has none.
    pub nulls: Option<Uint8Array>,
}

/// A registered column: the parsed type, plus the kind a batch must send it as.
struct ColumnSchema {
    name: String,
    ch_type: ChType,
    kind: ColumnKind,
}

/// A table's shape, parsed once at registration. The insert statement is built
/// here too — the column list never changes, so a batch pays for neither the
/// parse nor the statement.
struct TableSchema {
    table: String,
    columns: Vec<ColumnSchema>,
    insert_query: String,
}

/// One column's staged values, owned by Rust so they can leave the JS thread.
/// The name and type live in the table's schema rather than being re-sent.
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

/// Where a degradation notice goes. Retries happen while a `flush` is still in
/// flight, so handing them back at the end would leave an operator staring at
/// silence for the whole episode — they have to leave Rust as they occur.
type WarningSink = Arc<dyn Fn(&str) + Send + Sync>;

#[napi(object)]
pub struct ClickHouseSinkOptions {
    pub url: String,
    pub username: String,
    pub password: String,
    pub database: String,
    /// `"Int32"` or `"Int64"`, which every chain-scoped column follows.
    pub chain_id_mode: String,
    /// The column and table names the runtime's history format fixes.
    pub history: ddl::HistorySchema,
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
            // The sink writes continuously; keeping sockets warm avoids a TLS
            // handshake per batch against a remote cluster.
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

    /// Registers an entity's history table and keeps its columns under a
    /// handle, which every batch quotes instead of re-sending the shape.
    ///
    /// Separate from `initialize` because an indexer resuming an existing
    /// storage never runs it, so the write path registers on demand instead of
    /// depending on that.
    #[napi]
    pub fn register_entity_table(&self, entity: EntitySpecInput) -> napi::Result<RegisteredTable> {
        let entity: ddl::EntitySpec = entity.into();
        let columns = entity
            .history_columns(&self.history, self.chain_id_mode)
            .map_err(to_napi)?;
        self.register(entity.history_table.clone(), columns)
    }

    /// Registers the checkpoints table, whose columns the runtime supplies the
    /// same way an entity's are supplied.
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

    /// Creates the database, every entity's history table, and the current-state
    /// views over them.
    #[napi]
    pub async fn initialize(&self, input: InitializeInput) -> napi::Result<()> {
        self.initialize_inner(input).await.map_err(to_napi)
    }

    /// Drops everything written past `checkpoint_id`, which is how a restart
    /// rewinds ClickHouse to the checkpoint Postgres committed.
    #[napi]
    pub async fn resume(&self, checkpoint_id: String) -> napi::Result<()> {
        self.resume_inner(&checkpoint_id).await.map_err(to_napi)
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

    /// Inserts every staged batch, then the checkpoints that cover them.
    ///
    /// The order is the visibility rule the current-state views depend on: they
    /// read up to `max(id)` of the checkpoints table, so a checkpoint landing
    /// before the rows it covers would expose a half-written batch. Keeping it
    /// here rather than in the caller means the one thing that must not be
    /// reordered sits next to the code that could reorder it.
    ///
    /// Every handle is consumed, so a failed write never leaves a batch behind.
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

    /// Drops staged batches without sending them, for a caller that fails to
    /// stage the rest of a write: nothing else consumes those handles, so they
    /// would sit in the staging map for the life of the process.
    #[napi]
    pub fn discard(&self, handles: Vec<u32>) {
        let mut staged = self.staged.lock().unwrap();
        for handle in handles {
            staged.remove(&handle);
        }
    }
}

impl ClickHouseSink {
    /// Keeps a table's columns under a fresh handle and builds the insert its
    /// batches are sent with.
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

    /// The checkpoints table's columns as the DDL declares them and the encoder
    /// writes them — one derivation feeding both.
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
        // The `ddl` helpers quote the database name themselves, so they take
        // `self.database` and only the statements written inline take this.
        let database_ident = quoted(&self.database);

        if let Some(engine_spec) = &database_engine {
            let expected = ddl::database_engine_name(engine_spec);
            let existing = self
                .post_statement(format!(
                    "SELECT engine FROM system.databases WHERE name = {} \
                     FORMAT TabSeparated",
                    literal(&self.database)
                ))
                .await?;
            match existing.trim() {
                "" => {}
                engine if engine != expected => bail!(
                    "ClickHouse database \"{}\" exists with engine \"{engine}\" but \
                     ENVIO_CLICKHOUSE_DATABASE_ENGINE specifies \"{expected}\" (from \
                     \"{engine_spec}\"). Drop the database manually to change its engine.",
                    self.database
                ),
                _ => {}
            }
        }

        // Rendered before anything destructive runs: deriving a column type is
        // where a field this encoder cannot hold is refused, and the database
        // must not already be gone when that happens.
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

    async fn resume_inner(&self, checkpoint_id: &str) -> Result<()> {
        // Interpolated into every statement below, so it has to be the number it
        // claims to be rather than trusted for being internal.
        if checkpoint_id.is_empty() || !checkpoint_id.bytes().all(|b| b.is_ascii_digit()) {
            bail!("`{checkpoint_id}` is not a checkpoint id");
        }
        let database_ident = quoted(&self.database);
        self.post_statement(format!("USE {database_ident}"))
            .await
            .with_context(|| {
                format!(
                    "ClickHouse storage database \"{}\" not found. Please run \
                     'envio start -r' to reinitialize the indexer (it'll also drop Postgres \
                     database).",
                    self.database
                )
            })?;

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

    /// Removes every handle from the staging map before any of them is sent, so
    /// an unknown handle cannot leave the batches beside it stranded there. The
    /// checkpoints come back separately because they are sent separately —
    /// after the rows they cover.
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

    /// Statements go in the body rather than the query string: DDL runs long and
    /// a URL has a length limit. No `database` parameter — `initialize` creates
    /// the database, so scoping to it would fail before it exists, and every
    /// statement names its database anyway.
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
        // On the blocking pool rather than in place: `write_batch` drives every
        // table's insert from one task, and blocking that task would serialize
        // the encodes and stall the round trips already in flight beside them.
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
    }

    /// Sends the batch, retrying what fails. What goes back depends on the
    /// failure ([`retry_for`]): a batch the server could not take is replaced by
    /// its two halves, down to a single row, while a server or cluster that
    /// briefly cannot take writes gets the same rows again after the wait. The
    /// delay grows from 100ms to 1s as retries run down.
    ///
    /// Only a failure another attempt could answer differently is retried at
    /// all. A server that read the rows and rejected them gives the same verdict
    /// however few of them come back, so retrying one costs a batch's worth of
    /// doomed requests and every backoff between them before the error surfaces.
    async fn insert_with_retry(
        &self,
        table: &str,
        query: &str,
        encoded: &EncodedRows,
    ) -> Result<()> {
        let mut failures = 0usize;
        // Ranges still to send, most recent first; a failed range is replaced by
        // its two halves so the retry never re-sends rows that already landed.
        let mut pending = vec![(0usize, encoded.rows(), self.tuning.attempts)];
        while let Some((start, end, retries)) = pending.pop() {
            match self.post_rows(query, encoded.slice(start, end)).await {
                Ok(()) => continue,
                Err(failure) if retries == 0 || failure.retry == Retry::Never => {
                    // Every attempt behind this one already left through `warn`
                    // as it happened; what the terminal error still owes the
                    // reader is how many there were.
                    return Err(match failures {
                        0 => failure.error,
                        n => failure
                            .error
                            .context(format!("after {n} failed attempt(s)")),
                    });
                }
                Err(failure) => {
                    failures += 1;
                    let rows = end - start;
                    (self.warn)(&format!(
                        "ClickHouse insert of {rows} row(s) into `{table}` failed, \
                         {} retries left: {:#}",
                        retries - 1,
                        failure.error
                    ));
                    tokio::time::sleep(self.tuning.delay(retries)).await;
                    match failure.retry {
                        Retry::Halved if rows > 1 => {
                            let mid = start + rows / 2;
                            pending.push((mid, end, retries - 1));
                            pending.push((start, mid, retries - 1));
                        }
                        // Either the rows are not what failed, or halving has
                        // bottomed out at a single row and only the wait is left.
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
                    error: anyhow::Error::new(err).context("ClickHouse insert request failed"),
                    // The request never reached a verdict, so nothing about the
                    // rows has been decided. Halved rather than whole because a
                    // batch big enough to outrun the client deadline is one of
                    // the ways to get here, and it is the way a retry can fix.
                    retry: Retry::Halved,
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

/// A failed insert, and what another attempt could do about it.
struct InsertFailure {
    error: anyhow::Error,
    retry: Retry,
}

/// What a retry should send after a failure.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Retry {
    /// Nothing. Either the rows were read and rejected — the same verdict
    /// however few of them come back — or the answer came from in front of
    /// ClickHouse and names something no batch of any size changes, like a
    /// credential or a route.
    Never,
    /// The same rows. The condition belongs to the server or the cluster rather
    /// than to the batch, so a smaller batch meets it identically — and the two
    /// requests halving makes would only lean harder on whatever is struggling.
    SameRows,
    /// The rows in halves. The batch itself is what could not be taken, so a
    /// smaller one is the thing that might land.
    Halved,
}

/// Error codes where the batch is what the server could not take, so halving is
/// the retry that changes the answer. The three timeout-shaped ones are here
/// together: a body too large to read, encode or ship inside the deadline is a
/// batch a smaller one gets past, whichever layer reports the deadline.
const HALVED_ERROR_CODES: &[u32] = &[
    159,  // TIMEOUT_EXCEEDED
    209,  // SOCKET_TIMEOUT — the deadline tripped mid-body
    210,  // NETWORK_ERROR — a peer that gave up on an oversized body
    241,  // MEMORY_LIMIT_EXCEEDED — the one the halving is actually for
    319,  // UNKNOWN_STATUS_OF_INSERT
    425,  // SYSTEM_ERROR
    1002, // UNKNOWN_EXCEPTION
];

/// Error codes for a server or cluster that briefly cannot take writes. The rows
/// are not what it is objecting to, and for the crowding ones (202, 203, 252,
/// which come of too many requests rather than too large a one) halving is worse
/// than useless: it answers an overloaded server by making two requests where
/// one already failed. Waiting is the whole remedy.
const SAME_ROWS_ERROR_CODES: &[u32] = &[
    202, // TOO_MANY_SIMULTANEOUS_QUERIES
    203, // NO_FREE_CONNECTION
    236, // ABORTED — a replica on its way down or back up
    242, // TABLE_IS_READ_ONLY — a replicated table that has lost its Keeper session
    252, // TOO_MANY_PARTS
    285, // TOO_FEW_LIVE_REPLICAS
    999, // KEEPER_EXCEPTION
];

/// Whitelisted rather than blacklisted so a code nobody has thought about ends a
/// write with the server's own message instead of a batch's worth of doomed
/// requests.
fn retry_for(status: reqwest::StatusCode, body: &str) -> Retry {
    match clickhouse_error_code(body) {
        Some(code) if HALVED_ERROR_CODES.contains(&code) => Retry::Halved,
        Some(code) if SAME_ROWS_ERROR_CODES.contains(&code) => Retry::SameRows,
        Some(_) => Retry::Never,
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

/// The `N` of the `Code: N. DB::Exception: ...` a ClickHouse error body opens
/// with.
fn clickhouse_error_code(body: &str) -> Option<u32> {
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

    /// A column spec with everything optional left out.
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
            chain_id_mode: "Int32".to_string(),
            history: ddl::HistorySchema {
                id_column: "id".to_string(),
                checkpoint_id_column: "envio_checkpoint_id".to_string(),
                change_column: "envio_change".to_string(),
                change_variants: vec!["SET".to_string(), "DELETE".to_string()],
                set_variant: "SET".to_string(),
                checkpoints_table: "envio_checkpoints".to_string(),
                history_table_prefix: "envio_history_".to_string(),
            },
        }
    }

    /// Every one of these round-trips back to the input through ClickHouse's own
    /// parser. A trailing backslash is the case that matters: unescaped, it
    /// escapes the closing quote and the rest of the statement becomes SQL.
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

    /// A field type the derivation does not cover is refused when the table is
    /// registered — at startup, against no rows — rather than when a live batch
    /// first reaches the column.
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

    /// A sink pointed at `server`, holding on to the warnings it emitted so a
    /// test can assert on what an operator would have seen.
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

    fn sink_with(server: &mock_server::MockClickHouse, tuning: Tuning) -> TestSink {
        let warnings = Arc::new(Mutex::new(Vec::new()));
        let collected = warnings.clone();
        let sink = ClickHouseSink::build(
            options(server.url.clone()),
            tuning,
            Arc::new(move |message: &str| collected.lock().unwrap().push(message.to_string())),
        )
        .unwrap();
        TestSink { sink, warnings }
    }

    fn sink_for(server: &mock_server::MockClickHouse, attempts: u32) -> TestSink {
        sink_with(
            server,
            Tuning {
                attempts,
                // The waits are the policy's, not the encoder's; skipping them
                // keeps the test at milliseconds.
                max_retry_delay: Duration::ZERO,
                ..Tuning::default()
            },
        )
    }

    /// Stages `values` as a single `String` column named `id`, registering the
    /// table it belongs to.
    fn stage_ids(sink: &ClickHouseSink, values: &[&str]) -> u32 {
        let table = sink
            .register_checkpoints_table(vec![spec("id", "String")])
            .unwrap();
        sink.stage(table.handle, values.len() as u32, vec![text_values(values)])
            .unwrap()
    }

    /// Sends one staged batch, which is what a write with no checkpoints does.
    async fn write(sink: &ClickHouseSink, handle: u32) -> napi::Result<()> {
        sink.write_batch(vec![handle], None).await
    }

    // An unknown handle fails the write, and every batch named beside it is
    // freed rather than left staged for the life of the process.
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

        assert!(
            err.reason.contains("Unknown staged ClickHouse batch"),
            "expected an unknown-handle error, got: {}",
            err.reason
        );
        assert_eq!(sink.staged.lock().unwrap().len(), 0);
    }

    // A rejected insert is replaced by its two halves, so the rows in the half
    // that already landed must not be sent again.
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
            // One rejection, then the two halves; four rows, each exactly once.
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

    // A cluster that is briefly unable to take writes — a Keeper session lost,
    // a replica restarting — is not a verdict on the batch, and halving it makes
    // two requests where one already failed. The rows go back whole.
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
            // Two rejections, then all four rows in one insert — never split.
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

    // A proxy's body-size limit is the one verdict from in front of ClickHouse
    // that a smaller batch meets differently, so this is the case halving is for
    // even though nothing in the body names a ClickHouse code.
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

    // A proxy that is merely overloaded gets waited out, not fanned out to: the
    // two requests halving would make are what it is already struggling with.
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

    // Anything else a proxy answers is a deployment's own misconfiguration —
    // credentials, a route — which no number of smaller batches talks it out of.
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

    // Halving bottoms out at a single row, which is then retried whole.
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
                server.accepted_strings()
            ),
            (true, Vec::<String>::new()),
            "expected the server's message, got: {}",
            err.reason
        );
    }

    // Halving a batch is for a server that could not take the rows, not for one
    // that read them and said no: a verdict on the rows themselves is the same
    // verdict however few of them are sent again.
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

    // A peer that accepts the connection and then goes silent sends nothing to
    // react to, so only a client-side deadline ends the request. Without one the
    // flush — and the write batch behind it — never resolves at all.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_server_that_never_answers_times_out_rather_than_hanging() {
        let server = mock_server::MockClickHouse::start_unresponsive().await;
        let sink = sink_with(
            &server,
            Tuning {
                attempts: 1,
                max_retry_delay: Duration::ZERO,
                request_timeout: Duration::from_millis(150),
                statement_timeout: Duration::from_millis(150),
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

    // Types come from the caller, so an insert is the only request the sink ever
    // makes — no `system.columns` round trip in front of a table it has not seen.
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

    // A header value may only carry visible ASCII, so credentials sent as
    // X-ClickHouse-User/Key fail to build the request at all for a password no
    // stricter than a deployment is free to choose.
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
        // base64("défaut:pässwörd"), which is what a Basic credential carries.
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
