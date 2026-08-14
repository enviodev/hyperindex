//! The ClickHouse insert path.
//!
//! Everything but inserts stays in ReScript: DDL, the current-state views and
//! the reorg cleanup run once or rarely, and reusing the JS client for them keeps
//! one place that knows how envio's tables are shaped. Inserts are the hot path,
//! so they run here instead — column values cross the boundary columnar, get
//! encoded as RowBinary, and are sent from a tokio task rather than the Node main
//! thread.
//!
//! Splitting `stage` from `flush` is what makes the second half off-thread work:
//! a JS value can only be read while holding the isolate, so `stage` copies the
//! batch into owned Rust memory on the JS thread and `flush` does the encoding
//! and the HTTP round trip on the tokio pool.
//!
//! Column types come with the values. The caller creates these tables, so it
//! knows their shape, and asking the server to describe them back would only add
//! a round trip and a second answer to keep in step. The insert names every
//! column it sends, which is what keeps that safe: the table's own column order
//! stops mattering, and anything envio does not write — a column a user added, a
//! DEFAULT or MATERIALIZED expression, a type this encoder has never heard of —
//! is left for the server to fill.

pub mod ch_type;
#[cfg(test)]
mod mock_server;
pub mod row_binary;

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{bail, Context, Result};
use bytes::Bytes;
use napi::bindgen_prelude::{BigInt64Array, BigUint64Array, Float64Array, Uint32Array, Uint8Array};
use napi::threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode};
use napi::{Env, Status};
use napi_derive::napi;

use row_binary::{Column, EncodedRows, StagedValues};

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

/// How hard to retry a failed insert. Only the tests vary it, to skip the waits.
#[derive(Debug, Clone, Copy)]
struct RetryPolicy {
    attempts: u32,
    wait: bool,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            attempts: MAX_RETRIES,
            wait: true,
        }
    }
}

/// Knobs the tests turn down so a run takes milliseconds: the retry waits and
/// the request timeout a hanging server has to trip.
#[derive(Debug, Clone, Copy)]
struct Tuning {
    retry: RetryPolicy,
    request_timeout: Duration,
}

impl Default for Tuning {
    fn default() -> Self {
        Self {
            retry: RetryPolicy::default(),
            request_timeout: REQUEST_TIMEOUT,
        }
    }
}

impl RetryPolicy {
    /// Grows from 100ms to 1s as the remaining retries run down.
    fn delay(&self, retries_left: u32) -> Duration {
        if !self.wait || self.attempts < 2 {
            return Duration::ZERO;
        }
        Duration::from_millis(
            (100 + 900 * u64::from(self.attempts - retries_left) / u64::from(self.attempts - 1))
                .min(1000),
        )
    }
}

/// One column of a batch as it crosses the napi boundary. Exactly one of the
/// value fields is set, chosen from the column's ClickHouse type so both sides
/// agree without deriving the type twice.
#[napi(object)]
pub struct ColumnInput {
    pub name: String,
    /// The column's ClickHouse type, the same string the DDL declared it with.
    /// The caller creates these tables, so it already knows the shape; reading
    /// it back from `system.columns` would only add a round trip and a second
    /// place for the answer to come from.
    pub ch_type: String,
    /// Int8/16/32, UInt8/16/32, Float32/64, Bool (0/1), Date, DateTime,
    /// DateTime64 (ticks).
    pub numbers: Option<Float64Array>,
    /// UInt64, which loses precision as an f64.
    pub unsigned64: Option<BigUint64Array>,
    /// Int64.
    pub signed64: Option<BigInt64Array>,
    /// String, Decimal, Enum, Int128/UInt128 and JSON for Array columns: every
    /// value concatenated, split by `lengths`.
    pub text: Option<String>,
    /// UTF-16 code-unit length of each value in `text` — a JS string's own
    /// `.length`, so the caller never has to measure UTF-8.
    pub lengths: Option<Uint32Array>,
    /// `1` marks a NULL. Omitted when the column has none.
    pub nulls: Option<Uint8Array>,
}

/// A staged column, owned by Rust so it can leave the JS thread.
struct StagedColumn {
    name: String,
    /// The column's ClickHouse type, exactly as the DDL declared it.
    ch_type: String,
    values: StagedValues,
    nulls: Vec<u8>,
}

impl StagedColumn {
    /// Parses the declared type and resolves the text spans — the work that
    /// needs neither the isolate nor the network, so it runs off the JS thread.
    fn resolve(self) -> Result<Column> {
        let ch_type = ch_type::parse(&self.ch_type)
            .with_context(|| format!("Column `{}` has type `{}`", self.name, self.ch_type))?;
        let values = self
            .values
            .resolve()
            .with_context(|| format!("Column `{}`", self.name))?;
        let kind = ch_type.column_kind();
        if values.kind() != kind {
            bail!(
                "Column `{}` is {ch_type:?} and must be sent as {kind:?}, got {:?}",
                self.name,
                values.kind()
            );
        }
        Ok(Column {
            name: self.name,
            ch_type,
            values,
            nulls: self.nulls,
        })
    }
}

struct Staged {
    table: String,
    rows: usize,
    columns: Vec<StagedColumn>,
}

#[napi]
pub struct ClickHouseSink {
    client: reqwest::Client,
    url: String,
    username: String,
    password: String,
    database: String,
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
            .pool_idle_timeout(Duration::from_secs(90))
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
            staged: Mutex::new(HashMap::new()),
            next_handle: AtomicU32::new(1),
            tuning,
            warn,
        })
    }

    /// Copies a batch into Rust memory and returns a handle to pass to `flush`.
    /// Synchronous by necessity: reading a JS value needs the isolate.
    #[napi]
    pub fn stage(&self, table: String, rows: u32, columns: Vec<ColumnInput>) -> napi::Result<u32> {
        let rows = rows as usize;
        let mut staged_columns = Vec::with_capacity(columns.len());
        for column in columns {
            let ColumnInput {
                name,
                ch_type,
                numbers,
                unsigned64,
                signed64,
                text,
                lengths,
                nulls,
            } = column;
            let values = match (numbers, unsigned64, signed64, text) {
                (Some(v), None, None, None) => StagedValues::F64(v.to_vec()),
                (None, Some(v), None, None) => StagedValues::U64(v.to_vec()),
                (None, None, Some(v), None) => StagedValues::I64(v.to_vec()),
                (None, None, None, Some(data)) => {
                    let lengths = lengths.ok_or_else(|| {
                        napi::Error::from_reason(format!(
                            "Column `{name}` carries text without per-row lengths"
                        ))
                    })?;
                    StagedValues::Text {
                        data,
                        bounds: lengths.to_vec(),
                    }
                }
                _ => {
                    return Err(napi::Error::from_reason(format!(
                        "Column `{name}` must carry exactly one of numbers/unsigned64/signed64/text"
                    )))
                }
            };
            staged_columns.push(StagedColumn {
                name,
                ch_type,
                values,
                nulls: nulls.map(|n| n.to_vec()).unwrap_or_default(),
            });
        }
        let handle = self.next_handle.fetch_add(1, Ordering::Relaxed);
        self.staged.lock().unwrap().insert(
            handle,
            Staged {
                table,
                rows,
                columns: staged_columns,
            },
        );
        Ok(handle)
    }

    /// Encodes the staged batch as RowBinary and inserts it, retrying by halving
    /// the batch. The handle is consumed either way, so a failed flush never
    /// leaves the batch behind. Degradation notices go to the warning callback as
    /// they happen rather than coming back at the end.
    #[napi]
    pub async fn flush(&self, handle: u32) -> napi::Result<()> {
        let staged =
            self.staged.lock().unwrap().remove(&handle).ok_or_else(|| {
                napi::Error::from_reason(format!("Unknown staged batch {handle}"))
            })?;
        self.insert_staged(staged).await.map_err(to_napi)
    }
}

impl ClickHouseSink {
    async fn insert_staged(&self, staged: Staged) -> Result<()> {
        let table = staged.table;
        let encoded = tokio::task::block_in_place(|| {
            let columns = staged
                .columns
                .into_iter()
                .map(StagedColumn::resolve)
                .collect::<Result<Vec<_>>>()?;
            row_binary::encode(&columns, staged.rows).map(|encoded| (encoded, columns))
        })
        .with_context(|| format!("Failed encoding rows for ClickHouse table `{table}`"))?;
        let (encoded, columns) = encoded;
        if encoded.rows() == 0 {
            return Ok(());
        }
        self.insert_with_retry(&table, &columns, &encoded).await
    }

    /// Mirrors the JS client's policy: on a transient failure halve the range and
    /// retry each half; with a single row left, wait and retry it. The delay
    /// grows from 100ms to 1s as retries run down.
    async fn insert_with_retry(
        &self,
        table: &str,
        columns: &[Column],
        encoded: &EncodedRows,
    ) -> Result<()> {
        let query = insert_query(&self.database, table, columns);
        let mut attempted: Vec<String> = Vec::new();
        // Ranges still to send, most recent first; a failed range is replaced by
        // its two halves so the retry never re-sends rows that already landed.
        let mut pending = vec![(0usize, encoded.rows(), self.tuning.retry.attempts)];
        while let Some((start, end, retries)) = pending.pop() {
            match self.post_rows(&query, encoded.slice(start, end)).await {
                Ok(()) => continue,
                Err(err) if retries == 0 => {
                    // The attempts leading here are the diagnosis; returning the
                    // last error alone would drop them.
                    return Err(match attempted.is_empty() {
                        true => err,
                        false => err.context(format!("after {}", attempted.join("; "))),
                    });
                }
                Err(err) => {
                    let rows = end - start;
                    let warning = format!(
                        "ClickHouse insert of {rows} row(s) into `{table}` failed, \
                         {} retries left: {err:#}",
                        retries - 1
                    );
                    (self.warn)(&warning);
                    attempted.push(warning);
                    tokio::time::sleep(self.tuning.retry.delay(retries)).await;
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

    async fn post_rows(&self, query: &str, body: Bytes) -> Result<()> {
        let response = self
            .client
            .post(&self.url)
            .query(&[("query", query)])
            .header("X-ClickHouse-User", &self.username)
            .header("X-ClickHouse-Key", &self.password)
            .header("X-ClickHouse-Database", &self.database)
            .header("Content-Type", "application/octet-stream")
            .body(body)
            .send()
            .await
            .context("ClickHouse insert request failed")?;
        let status = response.status();
        if !status.is_success() {
            let text = response.text().await.unwrap_or_default();
            bail!("ClickHouse returned {status}: {text}");
        }
        Ok(())
    }
}

/// The wire kind a column of this ClickHouse type must be sent as. Exposed so
/// the JS side can pick a column's typed array from the same derivation the
/// encoder uses, instead of mapping envio's own field types to a kind a second
/// time — a mismatch there would only surface as a wrongly encoded column.
#[napi]
pub fn clickhouse_column_kind(ch_type: String) -> napi::Result<u8> {
    ch_type::parse(&ch_type)
        .map(|parsed| parsed.column_kind() as u8)
        .map_err(to_napi)
}

/// Names every column the body carries, so the table's own column order stops
/// mattering and anything envio does not write — an extra column a user added, a
/// MATERIALIZED or DEFAULT expression — is left for the server to fill.
fn insert_query(database: &str, table: &str, columns: &[Column]) -> String {
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

    /// A staged column of text values, declared as `ty`.
    fn column(name: &str, ty: &str, values: &[&str]) -> Column {
        StagedColumn {
            name: name.to_string(),
            ch_type: ty.to_string(),
            values: StagedValues::Text {
                data: values.concat(),
                bounds: values.iter().map(|v| v.len() as u32).collect(),
            },
            nulls: Vec::new(),
        }
        .resolve()
        .unwrap()
    }

    // The caller declares each column's type, so a value that cannot travel as
    // that type is caught before anything is encoded.
    #[test]
    fn rejects_values_that_do_not_match_the_declared_type() {
        let err = StagedColumn {
            name: "n".to_string(),
            ch_type: "String".to_string(),
            values: StagedValues::F64(vec![1.0]),
            nulls: Vec::new(),
        }
        .resolve()
        .unwrap_err();
        assert_eq!(
            format!("{err:#}"),
            "Column `n` is String and must be sent as Text, got F64"
        );
    }

    #[test]
    fn rejects_a_type_it_cannot_encode() {
        let err = StagedColumn {
            name: "t".to_string(),
            ch_type: "Tuple(String, UInt8)".to_string(),
            values: StagedValues::Text {
                data: String::new(),
                bounds: vec![0],
            },
            nulls: Vec::new(),
        }
        .resolve()
        .unwrap_err();
        assert_eq!(
            format!("{err:#}"),
            "Column `t` has type `Tuple(String, UInt8)`: unsupported ClickHouse type `Tuple`"
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
                retry: RetryPolicy {
                    attempts,
                    // The waits are the policy's, not the encoder's; skipping
                    // them keeps the test at milliseconds.
                    wait: false,
                },
                ..Tuning::default()
            },
        )
    }

    /// Stages `values` as a single `String` column named `id`.
    fn stage_ids(sink: &ClickHouseSink, values: &[&str]) -> u32 {
        sink.stage(
            "t".to_string(),
            values.len() as u32,
            vec![ColumnInput {
                name: "id".to_string(),
                ch_type: "String".to_string(),
                numbers: None,
                unsigned64: None,
                signed64: None,
                text: Some(values.concat()),
                lengths: Some(
                    values
                        .iter()
                        .map(|v| v.len() as u32)
                        .collect::<Vec<u32>>()
                        .into(),
                ),
                nulls: None,
            }],
        )
        .unwrap()
    }

    // A rejected insert is replaced by its two halves, so the rows in the half
    // that already landed must not be sent again.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_rejected_insert_is_retried_as_halves_and_every_row_lands_once() {
        let server = mock_server::MockClickHouse::start(1).await;
        let sink = sink_for(&server, 4);
        let handle = stage_ids(&sink, &["a", "b", "c", "d"]);

        sink.flush(handle).await.unwrap();

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

        sink.flush(handle).await.unwrap();

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

        let err = sink.flush(handle).await.unwrap_err();

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

    // A peer that accepts the connection and then goes silent sends nothing to
    // react to, so only a client-side deadline ends the request. Without one the
    // flush — and the write batch behind it — never resolves at all.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_server_that_never_answers_times_out_rather_than_hanging() {
        let server = mock_server::MockClickHouse::start_unresponsive().await;
        let sink = sink_with(
            &server,
            Tuning {
                retry: RetryPolicy {
                    attempts: 1,
                    wait: false,
                },
                request_timeout: Duration::from_millis(150),
            },
        );
        let handle = stage_ids(&sink, &["a"]);

        let err = sink.flush(handle).await.unwrap_err();

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
            sink.flush(handle).await.unwrap();
        }
        assert_eq!((server.inserts_seen(), server.queries_seen()), (3, 0));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_value_the_column_cannot_hold_fails_before_anything_is_sent() {
        let server = mock_server::MockClickHouse::start(0).await;
        let sink = sink_for(&server, 4);
        let handle = sink
            .stage(
                "t".to_string(),
                1,
                vec![ColumnInput {
                    name: "e".to_string(),
                    ch_type: "Enum8('SET' = 1)".to_string(),
                    numbers: None,
                    unsigned64: None,
                    signed64: None,
                    text: Some("NOPE".to_string()),
                    lengths: Some(vec![4u32].into()),
                    nulls: None,
                }],
            )
            .unwrap();

        let err = sink.flush(handle).await.unwrap_err();

        assert_eq!(
            (err.reason.contains("not a variant"), server.inserts_seen()),
            (true, 0),
            "expected the encoder's message, got: {}",
            err.reason
        );
    }

    #[test]
    fn the_insert_names_every_column_it_sends() {
        let columns = vec![
            column("id", "String", &["a"]),
            column("n`quoted", "String", &["1"]),
        ];
        assert_eq!(
            insert_query("db", "envio_history_A`B", &columns),
            "INSERT INTO `db`.`envio_history_A``B` (`id`, `n``quoted`) FORMAT RowBinary"
        );
    }
}
