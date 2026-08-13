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

pub mod ch_type;
#[cfg(test)]
mod mock_server;
pub mod row_binary;

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use napi::bindgen_prelude::{BigInt64Array, BigUint64Array, Float64Array, Uint32Array, Uint8Array};
use napi_derive::napi;

use ch_type::ChType;

/// A table's columns in position order, as ClickHouse reports them.
type TableSchema = Arc<Vec<(String, ChType)>>;
use row_binary::{Column, ColumnValues, EncodedRows};

/// Retries an insert this many times before giving up, matching the JS client's
/// policy: halve the batch while more than one row remains, otherwise wait.
const MAX_RETRIES: u32 = 8;

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
enum StagedValues {
    F64(Vec<f64>),
    U64(Vec<u64>),
    I64(Vec<i64>),
    Text { data: String, lengths: Vec<u32> },
}

struct StagedColumn {
    name: String,
    values: StagedValues,
    nulls: Vec<u8>,
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
    /// Column name and type per table, read from `system.columns` on first use.
    schemas: Mutex<HashMap<String, TableSchema>>,
    staged: Mutex<HashMap<u32, Staged>>,
    next_handle: AtomicU32,
    retry: RetryPolicy,
}

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
    pub fn new(options: ClickHouseSinkOptions) -> napi::Result<Self> {
        Self::build(options, RetryPolicy::default())
    }

    fn build(options: ClickHouseSinkOptions, retry: RetryPolicy) -> napi::Result<Self> {
        let client = reqwest::Client::builder()
            // The sink writes continuously; keeping sockets warm avoids a TLS
            // handshake per batch against a remote cluster.
            .pool_idle_timeout(Duration::from_secs(90))
            .pool_max_idle_per_host(8)
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
            schemas: Mutex::new(HashMap::new()),
            staged: Mutex::new(HashMap::new()),
            next_handle: AtomicU32::new(1),
            retry,
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
                        lengths: lengths.to_vec(),
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
    /// leaves the batch behind. Returns one message per retry, for the caller to
    /// put through the indexer's own logger.
    #[napi]
    pub async fn flush(&self, handle: u32) -> napi::Result<Vec<String>> {
        let staged =
            self.staged.lock().unwrap().remove(&handle).ok_or_else(|| {
                napi::Error::from_reason(format!("Unknown staged batch {handle}"))
            })?;
        self.insert_staged(staged).await.map_err(to_napi)
    }

    /// Forgets the cached column types for `table`, so the next insert re-reads
    /// them. Called after DDL recreates a table.
    #[napi]
    pub fn invalidate_schema(&self, table: String) {
        self.schemas.lock().unwrap().remove(&table);
    }
}

impl ClickHouseSink {
    async fn insert_staged(&self, staged: Staged) -> Result<Vec<String>> {
        let schema = self.table_schema(&staged.table).await?;
        let (encoded, mut warnings) = tokio::task::block_in_place(|| {
            let (columns, warnings) = align_to_schema(&schema, staged.columns, staged.rows)?;
            row_binary::encode(&columns, staged.rows).map(|encoded| (encoded, warnings))
        })
        .with_context(|| {
            format!(
                "Failed encoding rows for ClickHouse table `{}`",
                staged.table
            )
        })?;
        if encoded.rows() == 0 {
            return Ok(warnings);
        }
        warnings.extend(self.insert_with_retry(&staged.table, &encoded).await?);
        Ok(warnings)
    }

    /// Reads a table's column types from the server. Doing this instead of
    /// deriving them from envio's schema keeps the encoder honest about a table
    /// that already existed — an `Enum8` reports the numeric value RowBinary
    /// needs, which nothing on the JS side knows.
    async fn table_schema(&self, table: &str) -> Result<TableSchema> {
        if let Some(cached) = self.schemas.lock().unwrap().get(table) {
            return Ok(cached.clone());
        }
        let query = format!(
            "SELECT name, type FROM system.columns WHERE database = {} AND table = {} ORDER BY position FORMAT TSVRaw",
            quote_literal(&self.database),
            quote_literal(table)
        );
        let text = self.run_query(&query).await?;
        let mut columns = Vec::new();
        for line in text.lines().filter(|l| !l.is_empty()) {
            let (name, ty) = line
                .split_once('\t')
                .ok_or_else(|| anyhow!("Malformed system.columns row `{line}`"))?;
            let parsed = ch_type::parse(ty)
                .with_context(|| format!("Column `{table}`.`{name}` has type `{ty}`"))?;
            columns.push((name.to_string(), parsed));
        }
        if columns.is_empty() {
            bail!(
                "ClickHouse table `{}`.`{table}` has no columns — was it created?",
                self.database
            );
        }
        let schema = Arc::new(columns);
        self.schemas
            .lock()
            .unwrap()
            .insert(table.to_string(), schema.clone());
        Ok(schema)
    }

    async fn run_query(&self, query: &str) -> Result<String> {
        let response = self
            .client
            .post(&self.url)
            .header("X-ClickHouse-User", &self.username)
            .header("X-ClickHouse-Key", &self.password)
            .header("X-ClickHouse-Database", &self.database)
            .body(query.to_string())
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

    /// Mirrors the JS client's policy: on a transient failure halve the range and
    /// retry each half; with a single row left, wait and retry it. The delay
    /// grows from 100ms to 1s as retries run down.
    async fn insert_with_retry(&self, table: &str, encoded: &EncodedRows) -> Result<Vec<String>> {
        let mut warnings: Vec<String> = Vec::new();
        // Ranges still to send, most recent first; a failed range is replaced by
        // its two halves so the retry never re-sends rows that already landed.
        let mut pending = vec![(0usize, encoded.rows(), self.retry.attempts)];
        while let Some((start, end, retries)) = pending.pop() {
            let body = encoded.slice(start, end).to_vec();
            match self.post_rows(table, body).await {
                Ok(()) => continue,
                Err(err) if retries == 0 => return Err(err),
                Err(err) => {
                    let rows = end - start;
                    warnings.push(format!(
                        "ClickHouse insert of {rows} row(s) into `{table}` failed, \
                         {} retries left: {err:#}",
                        retries - 1
                    ));
                    tokio::time::sleep(self.retry.delay(retries)).await;
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
        Ok(warnings)
    }

    async fn post_rows(&self, table: &str, body: Vec<u8>) -> Result<()> {
        let query = format!(
            "INSERT INTO {}.{} FORMAT RowBinary",
            quote_identifier(&self.database),
            quote_identifier(table)
        );
        let response = self
            .client
            .post(&self.url)
            .query(&[("query", query.as_str())])
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

/// The wire kind a column of this ClickHouse type must be sent as. Exposed so a
/// test can pin ReScript's `ClickHouseSink.kindOfField` to it: the two derive the
/// kind from different inputs (a `Table.fieldType` there, the type text here) and
/// a mismatch would only surface as a wrongly encoded column.
#[napi]
pub fn clickhouse_column_kind(ch_type: String) -> napi::Result<u8> {
    ch_type::parse(&ch_type)
        .map(|parsed| parsed.column_kind() as u8)
        .map_err(to_napi)
}

fn quote_identifier(name: &str) -> String {
    format!("`{}`", name.replace('`', "``"))
}

fn quote_literal(value: &str) -> String {
    format!("'{}'", value.replace('\\', "\\\\").replace('\'', "\\'"))
}

/// Puts the staged columns in the target table's column order and pairs each
/// with its type.
///
/// A table column the caller has no values for takes the type's default for
/// every row, which is what omitting it from a JSONEachRow row used to do — a
/// table carrying a column envio no longer writes must keep working. It is still
/// reported, since for an envio-created table the columns cannot legitimately
/// diverge from the DDL. The reverse is an error: a value with no column to go in
/// would shift every following column on the wire.
fn align_to_schema(
    schema: &[(String, ChType)],
    columns: Vec<StagedColumn>,
    rows: usize,
) -> Result<(Vec<Column>, Vec<String>)> {
    let mut by_name: HashMap<String, StagedColumn> = columns
        .into_iter()
        .map(|column| (column.name.clone(), column))
        .collect();
    let mut aligned = Vec::with_capacity(schema.len());
    let mut defaulted = Vec::new();
    for (name, ch_type) in schema {
        let staged = match by_name.remove(name) {
            Some(staged) => staged,
            None => {
                defaulted.push(name.clone());
                aligned.push(Column {
                    name: name.clone(),
                    ch_type: ch_type.clone(),
                    values: default_values(ch_type, rows),
                    nulls: vec![1; rows],
                });
                continue;
            }
        };
        let values = match staged.values {
            StagedValues::F64(v) => ColumnValues::F64(v),
            StagedValues::U64(v) => ColumnValues::U64(v),
            StagedValues::I64(v) => ColumnValues::I64(v),
            StagedValues::Text { data, lengths } => {
                if lengths.len() != rows {
                    bail!(
                        "Column `{name}` has {} lengths but the batch has {rows} rows",
                        lengths.len()
                    );
                }
                let spans = row_binary::spans_from_utf16_lengths(&data, &lengths)
                    .with_context(|| format!("Column `{name}`"))?;
                ColumnValues::Text { data, spans }
            }
        };
        let expected = ch_type.column_kind();
        if values.kind() != expected {
            bail!(
                "Column `{name}` is {ch_type:?} and must be sent as {expected:?}, got {:?}",
                values.kind()
            );
        }
        aligned.push(Column {
            name: name.clone(),
            ch_type: ch_type.clone(),
            values,
            nulls: staged.nulls,
        });
    }
    if let Some(extra) = by_name.keys().next() {
        bail!("Column `{extra}` is not part of the target table");
    }
    let warnings = if defaulted.is_empty() {
        Vec::new()
    } else {
        vec![format!(
            "No values supplied for ClickHouse column(s) {}; every row took the column's default",
            defaulted.join(", ")
        )]
    };
    Ok((aligned, warnings))
}

/// Placeholder values for a column with nothing to write. Every row is masked as
/// null, so the encoder never reads them — only the kind has to match the type.
fn default_values(ch_type: &ChType, rows: usize) -> ColumnValues {
    match ch_type.column_kind() {
        ch_type::ColumnKind::F64 => ColumnValues::F64(vec![0.0; rows]),
        ch_type::ColumnKind::U64 => ColumnValues::U64(vec![0; rows]),
        ch_type::ColumnKind::I64 => ColumnValues::I64(vec![0; rows]),
        ch_type::ColumnKind::Text => ColumnValues::Text {
            data: String::new(),
            spans: vec![(0, 0); rows],
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    fn schema() -> Vec<(String, ChType)> {
        vec![
            ("id".to_string(), ch_type::parse("String").unwrap()),
            ("n".to_string(), ch_type::parse("Int32").unwrap()),
        ]
    }

    fn text(name: &str, values: &[&str]) -> StagedColumn {
        StagedColumn {
            name: name.to_string(),
            values: StagedValues::Text {
                data: values.concat(),
                lengths: values.iter().map(|v| v.len() as u32).collect(),
            },
            nulls: Vec::new(),
        }
    }

    #[test]
    fn aligns_columns_into_table_order() {
        let columns = vec![
            StagedColumn {
                name: "n".to_string(),
                values: StagedValues::F64(vec![1.0]),
                nulls: Vec::new(),
            },
            text("id", &["a"]),
        ];
        let (aligned, warnings) = align_to_schema(&schema(), columns, 1).unwrap();
        assert_eq!(
            (
                aligned.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(),
                warnings
            ),
            (vec!["id", "n"], Vec::<String>::new())
        );
    }

    // A table carrying a column envio does not write — an older version's field,
    // or one a user added — kept working under JSONEachRow because an omitted
    // column takes its default. RowBinary has no way to omit one, so the encoder
    // has to fill it, and say so.
    #[test]
    fn defaults_a_table_column_with_no_values_and_reports_it() {
        let (aligned, warnings) = align_to_schema(&schema(), vec![text("id", &["a"])], 1).unwrap();
        let encoded = row_binary::encode(&aligned, 1).unwrap();
        assert_eq!(
            (encoded.body, warnings),
            (
                vec![1, b'a', 0, 0, 0, 0],
                vec![
                    "No values supplied for ClickHouse column(s) n; every row took the column's \
                     default"
                        .to_string()
                ]
            )
        );
    }

    #[test]
    fn rejects_a_column_the_table_does_not_have() {
        let columns = vec![
            text("id", &["a"]),
            StagedColumn {
                name: "n".to_string(),
                values: StagedValues::F64(vec![1.0]),
                nulls: Vec::new(),
            },
            text("surprise", &["x"]),
        ];
        let err = align_to_schema(&schema(), columns, 1).unwrap_err();
        assert_eq!(
            format!("{err:#}"),
            "Column `surprise` is not part of the target table"
        );
    }

    fn sink_for(server: &mock_server::MockClickHouse, attempts: u32) -> ClickHouseSink {
        ClickHouseSink::build(
            ClickHouseSinkOptions {
                url: server.url.clone(),
                username: "default".to_string(),
                password: String::new(),
                database: "mock".to_string(),
            },
            RetryPolicy {
                attempts,
                // The waits are the policy's, not the encoder's; skipping them
                // keeps the test at milliseconds.
                wait: false,
            },
        )
        .unwrap()
    }

    /// Stages `values` as a single `String` column named `id`.
    fn stage_ids(sink: &ClickHouseSink, values: &[&str]) -> u32 {
        sink.stage(
            "t".to_string(),
            values.len() as u32,
            vec![ColumnInput {
                name: "id".to_string(),
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
        let server = mock_server::MockClickHouse::start(&[("id", "String")], 1).await;
        let sink = sink_for(&server, 4);
        let handle = stage_ids(&sink, &["a", "b", "c", "d"]);

        let warnings = sink.flush(handle).await.unwrap();

        assert_eq!(
            (
                server.accepted_strings(),
                server.inserts_seen(),
                warnings.len()
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
        let server = mock_server::MockClickHouse::start(&[("id", "String")], 2).await;
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
        let server = mock_server::MockClickHouse::start(&[("id", "String")], usize::MAX).await;
        let sink = sink_for(&server, 2);
        let handle = stage_ids(&sink, &["a", "b"]);

        let err = sink.flush(handle).await.unwrap_err();

        assert!(
            err.reason.contains("mock rejection"),
            "expected the server's message, got: {}",
            err.reason
        );
        assert_eq!(server.accepted_strings(), Vec::<String>::new());
    }

    // The column types come from the server, so a table the sink has never seen
    // costs one lookup and no more.
    #[tokio::test(flavor = "multi_thread")]
    async fn the_column_types_are_read_once_per_table() {
        let server = mock_server::MockClickHouse::start(&[("id", "String")], 0).await;
        let sink = sink_for(&server, 4);
        for _ in 0..3 {
            let handle = stage_ids(&sink, &["x"]);
            sink.flush(handle).await.unwrap();
        }
        let cached = sink.schemas.lock().unwrap();
        assert_eq!(
            (
                cached.len(),
                cached["t"]
                    .iter()
                    .map(|(name, _)| name.as_str())
                    .collect::<Vec<_>>(),
                server.column_types().len()
            ),
            (1, vec!["id"], 1)
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_value_the_column_cannot_hold_fails_before_anything_is_sent() {
        let server = mock_server::MockClickHouse::start(&[("e", "Enum8('SET' = 1)")], 0).await;
        let sink = sink_for(&server, 4);
        let handle = sink
            .stage(
                "t".to_string(),
                1,
                vec![ColumnInput {
                    name: "e".to_string(),
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

        assert!(
            err.reason.contains("not a variant"),
            "expected the encoder's message, got: {}",
            err.reason
        );
        assert_eq!(server.inserts_seen(), 0);
    }

    #[test]
    fn quotes_identifiers_and_literals() {
        assert_eq!(
            quote_identifier("envio_history_A`B"),
            "`envio_history_A``B`"
        );
        assert_eq!(quote_literal("it's"), "'it\\'s'");
    }
}
