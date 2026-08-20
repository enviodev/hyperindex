//! The ClickHouse write path.
//!
//! Everything the runtime sends ClickHouse goes through here: the DDL and the
//! reorg cleanup as plain statements, and the batch inserts as RowBinary. The
//! hot path never touches the Node main thread — column values cross the
//! boundary columnar, get encoded in Rust, and are sent from a tokio task.
//!
//! A table is registered once, before any batch. Registration parses each
//! column's declared type and builds the insert statement, so a batch carries
//! nothing but values and a handle, and a type this encoder cannot hold is
//! refused at startup rather than against a live table.
//!
//! Splitting `stage` from `write_batch` is what makes the second half
//! off-thread work: a JS value can only be read while holding the isolate, so
//! `stage` copies the batch into owned Rust memory on the JS thread and
//! `write_batch` does the encoding and the HTTP round trips on the tokio pool.
//!
//! Column types come from the caller, which is what creates these tables;
//! asking the server to describe them back would only add a round trip and a
//! second answer to keep in step. The insert names every column it sends, so
//! the table's own column order stops mattering and anything envio does not
//! write — a column a user added, a DEFAULT or MATERIALIZED expression — is
//! left for the server to fill.

pub mod ch_type;
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

use ch_type::{ChType, ColumnKind};
use row_binary::{Column, ColumnValues, EncodedRows};

/// Retries an insert this many times before giving up, matching the JS client's
/// policy: halve the batch while more than one row remains, otherwise wait.
const MAX_RETRIES: u32 = 8;

/// `@clickhouse/client`'s `request_timeout` default, which the JS insert path
/// ran under. Without it a peer that accepts a connection and then goes silent
/// — a black-holed socket through a load balancer sends neither RST nor FIN —
/// leaves the request hanging forever, and with it the whole write batch.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
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

/// A column of a table the caller is registering: the name it goes by and the
/// ClickHouse type the DDL declared it with.
#[napi(object)]
pub struct ColumnSpec {
    pub name: String,
    pub ch_type: String,
}

/// What a caller needs back to feed a registered table: the handle every batch
/// quotes, and the wire kind each column must be sent as — derived from the
/// type parsed here, so the JS side never maps envio's own field types to a
/// kind a second time.
#[napi(object)]
#[derive(Debug)]
pub struct RegisteredTable {
    pub handle: u32,
    pub kinds: Vec<u8>,
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
        })
    }

    /// Parses a table's column types and keeps them under a handle. Every batch
    /// quotes that handle instead of re-sending the shape, and a type this
    /// encoder cannot hold is refused here — at startup, against no rows —
    /// rather than when a live batch first reaches the column.
    #[napi]
    pub fn register_table(
        &self,
        table: String,
        columns: Vec<ColumnSpec>,
    ) -> napi::Result<RegisteredTable> {
        if columns.is_empty() {
            return Err(napi::Error::from_reason(format!(
                "ClickHouse table `{table}` was registered with no columns"
            )));
        }
        let mut parsed = Vec::with_capacity(columns.len());
        for ColumnSpec { name, ch_type } in columns {
            let parsed_type = ch_type::parse(&ch_type)
                .with_context(|| {
                    format!("Column `{name}` of ClickHouse table `{table}` has type `{ch_type}`")
                })
                .map_err(to_napi)?;
            parsed.push(ColumnSchema {
                kind: parsed_type.column_kind(),
                ch_type: parsed_type,
                name,
            });
        }
        let kinds = parsed.iter().map(|column| column.kind as u8).collect();
        let insert_query = insert_query(&self.database, &table, &parsed);
        let handle = self.next_handle.fetch_add(1, Ordering::Relaxed);
        self.tables.lock().unwrap().insert(
            handle,
            Arc::new(TableSchema {
                table,
                columns: parsed,
                insert_query,
            }),
        );
        Ok(RegisteredTable { handle, kinds })
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
        let mut handles = entities;
        handles.extend(checkpoints);
        let mut staged = self.take_staged(&handles).map_err(to_napi)?;
        // Taken last above, so it comes off the end.
        let checkpoints = checkpoints.and_then(|_| staged.pop());

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

    /// Runs a statement that returns nothing — the DDL and the reorg cleanup.
    #[napi]
    pub async fn exec(&self, query: String) -> napi::Result<()> {
        self.post_statement(query)
            .await
            .map(|_| ())
            .map_err(to_napi)
    }

    /// Runs a statement and hands back the server's response body verbatim, so
    /// the caller picks the `FORMAT` it wants to parse.
    #[napi]
    pub async fn query(&self, query: String) -> napi::Result<String> {
        self.post_statement(query).await.map_err(to_napi)
    }
}

impl ClickHouseSink {
    fn table_schema(&self, handle: u32) -> Result<Arc<TableSchema>> {
        self.tables
            .lock()
            .unwrap()
            .get(&handle)
            .cloned()
            .with_context(|| format!("Unknown ClickHouse table handle {handle}"))
    }

    /// Removes every handle from the staging map before any of them is sent, so
    /// an unknown handle cannot leave the batches beside it stranded there.
    fn take_staged(&self, handles: &[u32]) -> Result<Vec<Staged>> {
        let taken: Vec<Option<Staged>> = {
            let mut staged = self.staged.lock().unwrap();
            handles.iter().map(|handle| staged.remove(handle)).collect()
        };
        taken
            .into_iter()
            .zip(handles)
            .map(|(staged, handle)| {
                staged.with_context(|| format!("Unknown staged ClickHouse batch {handle}"))
            })
            .collect()
    }

    /// Statements go in the body rather than the query string: DDL runs long and
    /// a URL has a length limit. No `database` parameter — `initialize` creates
    /// the database, so scoping to it would fail before it exists, and every
    /// statement names its database anyway.
    async fn post_statement(&self, query: String) -> Result<String> {
        let response = self
            .client
            .post(&self.url)
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

    /// Halves a failed range and retries each half; with a single row left, waits
    /// and retries it. The delay grows from 100ms to 1s as retries run down.
    ///
    /// Only a failure another attempt could answer differently is retried. A
    /// server that read the rows and rejected them gives the same verdict however
    /// few of them come back, so retrying one costs a batch's worth of doomed
    /// requests and every backoff between them before the error surfaces.
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
                Err(failure) if retries == 0 || !failure.retriable => {
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
                    if rows > 1 {
                        let mid = start + rows / 2;
                        pending.push((mid, end, retries - 1));
                        pending.push((start, mid, retries - 1));
                    } else {
                        pending.push((start, end, retries - 1));
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
            // The request never reached a verdict, so nothing about the rows has
            // been decided and another attempt is worth making.
            Err(err) => {
                return Err(InsertFailure {
                    error: anyhow::Error::new(err).context("ClickHouse insert request failed"),
                    retriable: true,
                })
            }
        };
        let status = response.status();
        if status.is_success() {
            return Ok(());
        }
        let text = response.text().await.unwrap_or_default();
        Err(InsertFailure {
            retriable: is_retriable(status, &text),
            error: anyhow!("ClickHouse returned {status}: {text}"),
        })
    }
}

/// A failed insert, and whether another attempt could answer differently.
struct InsertFailure {
    error: anyhow::Error,
    retriable: bool,
}

/// ClickHouse error codes worth another attempt: the server was busy, lost a
/// peer, or could not say what happened — none of which is a verdict on the rows.
/// Whitelisted rather than blacklisted so a code nobody has thought about ends a
/// write with the server's own message instead of a batch's worth of doomed
/// requests.
const RETRIABLE_ERROR_CODES: &[u32] = &[
    159,  // TIMEOUT_EXCEEDED
    202,  // TOO_MANY_SIMULTANEOUS_QUERIES
    203,  // NO_FREE_CONNECTION
    209,  // SOCKET_TIMEOUT
    210,  // NETWORK_ERROR
    241,  // MEMORY_LIMIT_EXCEEDED — the one the halving is actually for
    252,  // TOO_MANY_PARTS
    285,  // TOO_FEW_LIVE_REPLICAS
    319,  // UNKNOWN_STATUS_OF_INSERT
    425,  // SYSTEM_ERROR
    999,  // KEEPER_EXCEPTION
    1002, // UNKNOWN_EXCEPTION
];

fn is_retriable(status: reqwest::StatusCode, body: &str) -> bool {
    match clickhouse_error_code(body) {
        Some(code) => RETRIABLE_ERROR_CODES.contains(&code),
        // No ClickHouse verdict in the body, so something in front of it
        // answered — a proxy or load balancer — and only its status says
        // whether the rows ever got as far as being judged.
        None => status.is_server_error() || status == reqwest::StatusCode::TOO_MANY_REQUESTS,
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

/// Names every column the body carries, so the table's own column order stops
/// mattering and anything envio does not write — an extra column a user added, a
/// MATERIALIZED or DEFAULT expression — is left for the server to fill.
fn insert_query(database: &str, table: &str, columns: &[ColumnSchema]) -> String {
    let names = columns
        .iter()
        .map(|column| quote_identifier(&column.name))
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "INSERT INTO {}.{} ({names}) FORMAT RowBinary",
        quote_identifier(database),
        quote_identifier(table)
    )
}

fn quote_identifier(name: &str) -> String {
    format!("`{}`", name.replace('`', "``"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    /// A column of text values as `insert_query` sees it, declared as `ty`.
    fn column(name: &str, ty: &str) -> ColumnSchema {
        let ch_type = ch_type::parse(ty).unwrap();
        ColumnSchema {
            name: name.to_string(),
            kind: ch_type.column_kind(),
            ch_type,
        }
    }

    fn text_values(values: &[&str]) -> ColumnValuesInput {
        ColumnValuesInput {
            numbers: None,
            unsigned64: None,
            signed64: None,
            texts: Some(values.iter().map(|v| v.to_string()).collect()),
            nulls: None,
        }
    }

    fn spec(name: &str, ty: &str) -> ColumnSpec {
        ColumnSpec {
            name: name.to_string(),
            ch_type: ty.to_string(),
        }
    }

    // A column's type is parsed when the table is registered, so a type this
    // encoder cannot hold is refused at startup rather than by the first batch
    // that reaches the column.
    #[test]
    fn registering_rejects_a_type_it_cannot_encode() {
        let server_less = ClickHouseSink::build(
            ClickHouseSinkOptions {
                url: "http://127.0.0.1:1".to_string(),
                username: "default".to_string(),
                password: String::new(),
                database: "mock".to_string(),
            },
            Tuning::default(),
            Arc::new(|_: &str| {}),
        )
        .unwrap();

        let err = server_less
            .register_table("t".to_string(), vec![spec("t", "Tuple(String, UInt8)")])
            .unwrap_err();

        assert_eq!(
            err.reason,
            "Column `t` of ClickHouse table `t` has type `Tuple(String, UInt8)`: \
             unsupported ClickHouse type `Tuple`"
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
            ClickHouseSinkOptions {
                url: server.url.clone(),
                username: "default".to_string(),
                password: String::new(),
                database: "mock".to_string(),
            },
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
            .register_table("t".to_string(), vec![spec("id", "String")])
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
            .register_table("t".to_string(), vec![spec("e", "Enum8('SET' = 1)")])
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
                url: server.url.clone(),
                username: "défaut".to_string(),
                password: "pässwörd".to_string(),
                database: "mock".to_string(),
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

    #[test]
    fn the_insert_names_every_column_it_sends() {
        let columns = vec![column("id", "String"), column("n`quoted", "String")];
        assert_eq!(
            insert_query("db", "envio_history_A`B", &columns),
            "INSERT INTO `db`.`envio_history_A``B` (`id`, `n``quoted`) FORMAT RowBinary"
        );
    }
}
