//! A local HyperSync server for tests.
//!
//! The query path never touches JS: the Rust `hypersync_client` builds the
//! query, POSTs it, and decodes the response, so nothing on the JS side can
//! observe or fake it. This server sits at the far end of that stack — real
//! HTTP, real wire format — so a test can assert on the query the client
//! actually sent and hand back a page the client actually decodes.
//!
//! Requests are captured verbatim as JSON text (the client's `Json`
//! serialization format; the Cap'n Proto request format is not accepted).
//! Responses are supplied as JSON row tables and encoded into the response wire
//! format: a packed Cap'n Proto message carrying one Arrow IPC file per table.
//!
//! EVM only.

use std::collections::VecDeque;
use std::net::TcpListener as StdTcpListener;
use std::str::FromStr;
use std::sync::{Arc, Mutex};

use anyhow::{bail, Context, Result};
use arrow::array::{
    ArrayRef, BinaryBuilder, BooleanBuilder, RecordBatch, UInt64Builder, UInt8Builder,
};
use arrow::datatypes::{DataType, Field, Schema};
use arrow::ipc::writer::FileWriter;
use hypersync_net_types::hypersync_net_types_capnp;
use hypersync_net_types::{BlockField, LogField, TransactionField};
use napi_derive::napi;
use serde_json::Value;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::watch;

const QUERY_PATH: &str = "/query/arrow-ipc";
const HEIGHT_PATH: &str = "/height";
const HEIGHT_SSE_PATH: &str = "/height/sse";

#[derive(Default)]
struct State {
    height: u64,
    /// Raw JSON bodies POSTed to the query endpoint, oldest first.
    queries: Vec<String>,
    /// Response specs, one per query. An exhausted queue serves an empty page
    /// covering the queried range, so a test only has to pin the pages it
    /// cares about.
    responses: VecDeque<Value>,
}

/// A HyperSync server bound to an ephemeral localhost port.
#[napi]
pub struct MockHyperSyncServer {
    url: String,
    state: Arc<Mutex<State>>,
    shutdown: watch::Sender<bool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

fn err(e: impl std::fmt::Display) -> napi::Error {
    napi::Error::from_reason(format!("{e}"))
}

#[napi]
impl MockHyperSyncServer {
    #[napi(factory)]
    pub fn new(height: Option<i64>) -> napi::Result<Self> {
        let listener = StdTcpListener::bind(("127.0.0.1", 0))
            .context("bind mock hypersync server")
            .map_err(err)?;
        listener
            .set_nonblocking(true)
            .context("set nonblocking")
            .map_err(err)?;
        let port = listener
            .local_addr()
            .context("read local addr")
            .map_err(err)?
            .port();

        let state = Arc::new(Mutex::new(State {
            height: height.unwrap_or(0).max(0) as u64,
            ..Default::default()
        }));
        let (shutdown, shutdown_rx) = watch::channel(false);

        let thread = std::thread::spawn({
            let state = state.clone();
            move || {
                let rt = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .expect("build mock hypersync runtime");
                rt.block_on(serve(listener, state, shutdown_rx));
            }
        });

        Ok(Self {
            url: format!("http://127.0.0.1:{port}"),
            state,
            shutdown,
            thread: Some(thread),
        })
    }

    #[napi]
    pub fn url(&self) -> String {
        self.url.clone()
    }

    #[napi]
    pub fn set_height(&self, height: i64) {
        self.state.lock().unwrap().height = height.max(0) as u64;
    }

    /// Queue the page the next query is answered with. See `build_page` for the
    /// spec shape.
    #[napi]
    pub fn push_response(&self, spec: String) -> napi::Result<()> {
        let value: Value = serde_json::from_str(&spec)
            .context("parse mock hypersync response spec")
            .map_err(err)?;
        self.state.lock().unwrap().responses.push_back(value);
        Ok(())
    }

    /// Drain the query bodies received so far, oldest first.
    #[napi]
    pub fn take_queries(&self) -> Vec<String> {
        std::mem::take(&mut self.state.lock().unwrap().queries)
    }

    #[napi]
    pub fn close(&mut self) {
        let _ = self.shutdown.send(true);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for MockHyperSyncServer {
    fn drop(&mut self) {
        self.close();
    }
}

async fn serve(
    listener: StdTcpListener,
    state: Arc<Mutex<State>>,
    shutdown: watch::Receiver<bool>,
) {
    let listener = match tokio::net::TcpListener::from_std(listener) {
        Ok(listener) => listener,
        Err(e) => {
            eprintln!("mock hypersync server failed to start: {e}");
            return;
        }
    };
    loop {
        let mut stop = shutdown.clone();
        tokio::select! {
            _ = stop.changed() => break,
            accepted = listener.accept() => {
                let Ok((stream, _)) = accepted else { break };
                let state = state.clone();
                let shutdown = shutdown.clone();
                tokio::spawn(async move {
                    let _ = handle_connection(stream, state, shutdown).await;
                });
            }
        }
    }
}

struct Request {
    method: String,
    path: String,
    body: String,
}

/// Parse one request out of the buffer, returning how many bytes it consumed.
/// `None` means the buffer doesn't hold a complete request yet.
fn parse_request(buf: &[u8]) -> Option<(usize, Request)> {
    let head_end = buf.windows(4).position(|w| w == b"\r\n\r\n")?;
    let head = String::from_utf8_lossy(&buf[..head_end]);
    let mut lines = head.split("\r\n");
    let mut request_line = lines.next().unwrap_or_default().split_whitespace();
    let method = request_line.next().unwrap_or_default().to_string();
    let path = request_line.next().unwrap_or_default().to_string();

    let content_length = lines
        .filter_map(|line| line.split_once(':'))
        .find(|(name, _)| name.eq_ignore_ascii_case("content-length"))
        .and_then(|(_, value)| value.trim().parse::<usize>().ok())
        .unwrap_or(0);

    let total = head_end + 4 + content_length;
    if buf.len() < total {
        return None;
    }
    let body = String::from_utf8_lossy(&buf[head_end + 4..total]).to_string();
    Some((total, Request { method, path, body }))
}

async fn handle_connection(
    mut stream: TcpStream,
    state: Arc<Mutex<State>>,
    shutdown: watch::Receiver<bool>,
) -> Result<()> {
    let mut buf: Vec<u8> = Vec::new();
    loop {
        let request = loop {
            if let Some((consumed, request)) = parse_request(&buf) {
                buf.drain(..consumed);
                break request;
            }
            let mut chunk = [0u8; 8192];
            let read = stream.read(&mut chunk).await?;
            if read == 0 {
                return Ok(());
            }
            buf.extend_from_slice(&chunk[..read]);
        };

        let path = request.path.split('?').next().unwrap_or_default();
        match (request.method.as_str(), path) {
            ("GET", HEIGHT_PATH) => {
                let height = state.lock().unwrap().height;
                write_response(
                    &mut stream,
                    200,
                    "application/json",
                    format!("{{\"height\":{height}}}").as_bytes(),
                )
                .await?;
            }
            ("GET", HEIGHT_SSE_PATH) => {
                stream_heights(&mut stream, state, shutdown).await?;
                return Ok(());
            }
            ("POST", QUERY_PATH) => {
                let (spec, height) = {
                    let mut state = state.lock().unwrap();
                    state.queries.push(request.body.clone());
                    (state.responses.pop_front(), state.height)
                };
                // A Cap'n Proto query body lands here too, and reads as a
                // malformed JSON one — the source has to be built with the
                // `Json` serialization format.
                match spec.as_ref().and_then(raw_reply) {
                    // A spec carrying a status answers at the HTTP level
                    // instead of with a page: rate limiting and
                    // payload-too-large are statuses the client acts on.
                    Some(raw) => {
                        write_response_with(
                            &mut stream,
                            raw.status,
                            &raw.headers,
                            raw.body.as_bytes(),
                        )
                        .await?
                    }
                    None => {
                        let page = serde_json::from_str(&request.body)
                            .context("expected a JSON query body")
                            .and_then(|query: Value| build_page(spec.as_ref(), &query, height));
                        match page {
                            Ok(body) => {
                                write_response(&mut stream, 200, "application/octet-stream", &body)
                                    .await?
                            }
                            Err(e) => {
                                write_response(
                                    &mut stream,
                                    400,
                                    "text/plain",
                                    format!("{e:#}").as_bytes(),
                                )
                                .await?
                            }
                        }
                    }
                }
            }
            _ => write_response(&mut stream, 404, "text/plain", b"not found").await?,
        }
    }
}

/// A response spec that answers at the HTTP level: `{"status": 429, "headers":
/// {"x-ratelimit-reset": "3"}, "body": "..."}`.
struct RawReply {
    status: u16,
    headers: Vec<(String, String)>,
    body: String,
}

fn raw_reply(spec: &Value) -> Option<RawReply> {
    let status = spec.get("status")?.as_u64()? as u16;
    let headers = spec
        .get("headers")
        .and_then(Value::as_object)
        .map(|headers| {
            headers
                .iter()
                .map(|(name, value)| {
                    (
                        name.clone(),
                        value
                            .as_str()
                            .map(str::to_string)
                            .unwrap_or_else(|| value.to_string()),
                    )
                })
                .collect()
        })
        .unwrap_or_default();
    Some(RawReply {
        status,
        headers,
        body: spec
            .get("body")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
    })
}

async fn write_response(
    stream: &mut TcpStream,
    status: u16,
    content_type: &str,
    body: &[u8],
) -> Result<()> {
    write_response_with(
        stream,
        status,
        &[("Content-Type".to_string(), content_type.to_string())],
        body,
    )
    .await
}

async fn write_response_with(
    stream: &mut TcpStream,
    status: u16,
    headers: &[(String, String)],
    body: &[u8],
) -> Result<()> {
    let mut head = format!(
        "HTTP/1.1 {status} {}\r\nContent-Length: {}\r\n",
        if status == 200 { "OK" } else { "ERROR" },
        body.len()
    );
    for (name, value) in headers {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(body).await?;
    stream.flush().await?;
    Ok(())
}

/// The height stream the source subscribes to at the head. Emits the current
/// height on connect and on every change, with the keep-alive pings the client
/// uses to tell a live connection from a stale one.
async fn stream_heights(
    stream: &mut TcpStream,
    state: Arc<Mutex<State>>,
    mut shutdown: watch::Receiver<bool>,
) -> Result<()> {
    stream
        .write_all(
            b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n",
        )
        .await?;

    let mut sent: Option<u64> = None;
    loop {
        let height = state.lock().unwrap().height;
        let frame = if sent == Some(height) {
            "event: ping\ndata: \n\n".to_string()
        } else {
            sent = Some(height);
            format!("event: height\ndata: {height}\n\n")
        };
        stream.write_all(frame.as_bytes()).await?;
        stream.flush().await?;

        tokio::select! {
            _ = shutdown.changed() => return Ok(()),
            _ = tokio::time::sleep(std::time::Duration::from_millis(50)) => {}
        }
    }
}

/// Encode one query response.
///
/// The spec is JSON, with every field optional:
/// ```json
/// {
///   "archiveHeight": 100,
///   "nextBlock": 11,
///   "blocks": [{"number": 10, "hash": "0x..", "timestamp": 1700000000}],
///   "transactions": [{"block_number": 10, "transaction_index": 0, "hash": "0x.."}],
///   "logs": [{"block_number": 10, "log_index": 0, "address": "0x..", "topic0": "0x.."}],
///   "rollbackGuard": {"blockNumber": 10, "timestamp": 0, "hash": "0x..",
///                     "firstBlockNumber": 5, "firstParentHash": "0x.."}
/// }
/// ```
/// Row keys are HyperSync field names (`snake_case`, as in the query's
/// `field_selection`). Values are `0x` hex strings, or numbers for the
/// numeric fields. A key the row omits comes back null, which is how a test
/// makes the server withhold a field the query asked for.
fn build_page(spec: Option<&Value>, query: &Value, height: u64) -> Result<Vec<u8>> {
    let empty = Value::Null;
    let spec = spec.unwrap_or(&empty);

    let from_block = query.get("from_block").and_then(Value::as_u64).unwrap_or(0);
    let next_block = match spec.get("nextBlock").and_then(Value::as_u64) {
        Some(next_block) => next_block,
        // `to_block` is exclusive on the wire, so it is already the next block.
        None => query
            .get("to_block")
            .and_then(Value::as_u64)
            .unwrap_or(from_block),
    };
    let archive_height = spec
        .get("archiveHeight")
        .and_then(Value::as_i64)
        .unwrap_or(height as i64);

    let blocks = encode_table(spec.get("blocks"), block_kind).context("encode blocks")?;
    let transactions =
        encode_table(spec.get("transactions"), transaction_kind).context("encode transactions")?;
    let logs = encode_table(spec.get("logs"), log_kind).context("encode logs")?;

    let mut message = capnp::message::Builder::new_default();
    {
        let mut response =
            message.init_root::<hypersync_net_types_capnp::query_response::Builder>();
        response.set_archive_height(archive_height);
        response.set_next_block(next_block);
        response.set_total_execution_time(0);

        if let Some(guard) = spec.get("rollbackGuard").filter(|g| !g.is_null()) {
            let mut builder = response.reborrow().init_rollback_guard();
            builder.set_block_number(field_u64(guard, "blockNumber")?);
            builder.set_timestamp(guard.get("timestamp").and_then(Value::as_i64).unwrap_or(0));
            builder.set_first_block_number(field_u64(guard, "firstBlockNumber")?);
            builder.set_hash(&hex_bytes(guard.get("hash"), "rollbackGuard.hash")?);
            builder.set_first_parent_hash(&hex_bytes(
                guard.get("firstParentHash"),
                "rollbackGuard.firstParentHash",
            )?);
        }

        // `traces` is left unset on purpose: the client only reads it when the
        // field is present, and an unset Data field would decode as zero bytes
        // — not a valid Arrow IPC file.
        let mut data = response.init_data();
        data.set_blocks(&blocks);
        data.set_transactions(&transactions);
        data.set_logs(&logs);
    }

    let mut out = Vec::new();
    capnp::serialize_packed::write_message(&mut out, &message).context("write capnp message")?;
    Ok(out)
}

fn field_u64(value: &Value, name: &str) -> Result<u64> {
    value
        .get(name)
        .and_then(Value::as_u64)
        .with_context(|| format!("expected '{name}' to be a number"))
}

fn hex_bytes(value: Option<&Value>, name: &str) -> Result<Vec<u8>> {
    match value {
        Some(Value::String(s)) => decode_hex(s, name),
        _ => bail!("expected '{name}' to be a 0x-prefixed hex string"),
    }
}

fn decode_hex(s: &str, name: &str) -> Result<Vec<u8>> {
    let digits = s.strip_prefix("0x").unwrap_or(s);
    let padded;
    let digits = if digits.len() % 2 == 1 {
        padded = format!("0{digits}");
        padded.as_str()
    } else {
        digits
    };
    let mut out = vec![0u8; digits.len() / 2];
    faster_hex::hex_decode(digits.as_bytes(), &mut out)
        .with_context(|| format!("'{name}' value '{s}' is not valid hex"))?;
    Ok(out)
}

/// How a field's values are laid out in the Arrow response. The client reads
/// each column at a fixed type, so a mismatch decodes as a missing field.
#[derive(Clone, Copy, PartialEq)]
enum Kind {
    U64,
    U8,
    Bool,
    /// Fixed-width binary (hashes, addresses) and opaque data, verbatim.
    Bytes,
    /// Big-endian integer with no leading zero bytes — the encoding the client
    /// requires of every numeric binary column.
    Quantity,
}

fn block_kind(name: &str) -> Result<Kind> {
    let field = BlockField::from_str(name).map_err(|_| unknown_field("block", name))?;
    Ok(match field {
        BlockField::Number | BlockField::L1BlockNumber => Kind::U64,
        BlockField::Difficulty
        | BlockField::TotalDifficulty
        | BlockField::Size
        | BlockField::GasLimit
        | BlockField::GasUsed
        | BlockField::Timestamp
        | BlockField::BaseFeePerGas
        | BlockField::BlobGasUsed
        | BlockField::ExcessBlobGas
        | BlockField::SendCount => Kind::Quantity,
        _ => Kind::Bytes,
    })
}

fn log_kind(name: &str) -> Result<Kind> {
    let field = LogField::from_str(name).map_err(|_| unknown_field("log", name))?;
    Ok(match field {
        LogField::BlockNumber | LogField::LogIndex | LogField::TransactionIndex => Kind::U64,
        LogField::Removed => Kind::Bool,
        _ => Kind::Bytes,
    })
}

fn transaction_kind(name: &str) -> Result<Kind> {
    let field = TransactionField::from_str(name).map_err(|_| unknown_field("transaction", name))?;
    Ok(match field {
        TransactionField::BlockNumber | TransactionField::TransactionIndex => Kind::U64,
        TransactionField::Status | TransactionField::Type => Kind::U8,
        TransactionField::BlockHash
        | TransactionField::Hash
        | TransactionField::Input
        | TransactionField::From
        | TransactionField::To
        | TransactionField::ContractAddress
        | TransactionField::Root
        | TransactionField::SourceHash
        | TransactionField::LogsBloom
        | TransactionField::AccessList
        | TransactionField::AuthorizationList
        | TransactionField::BlobVersionedHashes
        | TransactionField::Sighash => Kind::Bytes,
        _ => Kind::Quantity,
    })
}

fn unknown_field(table: &str, name: &str) -> anyhow::Error {
    anyhow::anyhow!("'{name}' is not a HyperSync {table} field")
}

/// Encode one table as a single-batch Arrow IPC file. Columns are the union of
/// the rows' keys, in first-seen order; a row that omits a column is null there.
fn encode_table(rows: Option<&Value>, kind_of: fn(&str) -> Result<Kind>) -> Result<Vec<u8>> {
    let rows = match rows {
        None | Some(Value::Null) => &[][..],
        Some(Value::Array(rows)) => rows.as_slice(),
        Some(_) => bail!("expected an array of rows"),
    };

    let mut names: Vec<String> = Vec::new();
    for row in rows {
        let row = row
            .as_object()
            .context("expected every row to be an object")?;
        for name in row.keys() {
            if !names.iter().any(|seen| seen == name) {
                names.push(name.clone());
            }
        }
    }

    let mut fields = Vec::with_capacity(names.len());
    let mut columns: Vec<ArrayRef> = Vec::with_capacity(names.len());
    for name in &names {
        let kind = kind_of(name).with_context(|| format!("column '{name}'"))?;
        let values = rows.iter().map(|row| row.get(name));
        let (data_type, array) =
            build_column(kind, values).with_context(|| format!("column '{name}'"))?;
        fields.push(Field::new(name, data_type, true));
        columns.push(array);
    }

    let schema = Arc::new(Schema::new(fields));
    let mut out = Vec::new();
    {
        let mut writer =
            FileWriter::try_new(&mut out, &schema).context("create arrow ipc writer")?;
        if !columns.is_empty() {
            let batch = RecordBatch::try_new(schema.clone(), columns)
                .context("build arrow record batch")?;
            writer.write(&batch).context("write arrow record batch")?;
        }
        writer.finish().context("finish arrow ipc file")?;
    }
    Ok(out)
}

fn build_column<'a>(
    kind: Kind,
    values: impl Iterator<Item = Option<&'a Value>>,
) -> Result<(DataType, ArrayRef)> {
    Ok(match kind {
        Kind::U64 => {
            let mut builder = UInt64Builder::new();
            for value in values {
                match value {
                    None | Some(Value::Null) => builder.append_null(),
                    Some(value) => builder.append_value(as_u64(value)?),
                }
            }
            (DataType::UInt64, Arc::new(builder.finish()) as ArrayRef)
        }
        Kind::U8 => {
            let mut builder = UInt8Builder::new();
            for value in values {
                match value {
                    None | Some(Value::Null) => builder.append_null(),
                    Some(value) => builder.append_value(as_u64(value)?.try_into()?),
                }
            }
            (DataType::UInt8, Arc::new(builder.finish()) as ArrayRef)
        }
        Kind::Bool => {
            let mut builder = BooleanBuilder::new();
            for value in values {
                match value {
                    None | Some(Value::Null) => builder.append_null(),
                    Some(Value::Bool(value)) => builder.append_value(*value),
                    Some(value) => bail!("expected a boolean, got {value}"),
                }
            }
            (DataType::Boolean, Arc::new(builder.finish()) as ArrayRef)
        }
        Kind::Bytes | Kind::Quantity => {
            let mut builder = BinaryBuilder::new();
            for value in values {
                match value {
                    None | Some(Value::Null) => builder.append_null(),
                    Some(value) => {
                        let bytes = as_bytes(value, kind)?;
                        builder.append_value(&bytes)
                    }
                }
            }
            (DataType::Binary, Arc::new(builder.finish()) as ArrayRef)
        }
    })
}

fn as_u64(value: &Value) -> Result<u64> {
    match value {
        Value::Number(n) => n.as_u64().context("expected a non-negative integer"),
        Value::String(s) => {
            let bytes = decode_hex(s, "value")?;
            let mut out: u64 = 0;
            for byte in bytes {
                out = out
                    .checked_mul(256)
                    .and_then(|out| out.checked_add(byte as u64))
                    .context("hex value doesn't fit in 64 bits")?;
            }
            Ok(out)
        }
        _ => bail!("expected a number or a hex string, got {value}"),
    }
}

fn as_bytes(value: &Value, kind: Kind) -> Result<Vec<u8>> {
    let bytes = match value {
        Value::String(s) => decode_hex(s, "value")?,
        Value::Number(n) => {
            if kind == Kind::Bytes {
                bail!("expected a hex string, got {n}");
            }
            let n = n.as_u64().context("expected a non-negative integer")?;
            n.to_be_bytes().to_vec()
        }
        _ => bail!("expected a hex string, got {value}"),
    };
    Ok(match kind {
        // The client rejects a leading zero byte on a quantity, and an empty
        // one; zero itself is a single zero byte.
        Kind::Quantity => match bytes.iter().position(|byte| *byte != 0) {
            Some(start) => bytes[start..].to_vec(),
            None => vec![0],
        },
        _ => bytes,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use hypersync_client::format::Hex;
    use hypersync_client::simple_types;

    /// Decode a page the way the client does: unpack the capnp message, read
    /// each table's Arrow IPC file, convert to the client's row types.
    struct Decoded {
        next_block: u64,
        archive_height: i64,
        blocks: Vec<simple_types::Block>,
        transactions: Vec<simple_types::Transaction>,
        logs: Vec<simple_types::Log>,
    }

    fn read_batches(bytes: &[u8]) -> Vec<RecordBatch> {
        arrow::ipc::reader::FileReader::try_new(std::io::Cursor::new(bytes.to_vec()), None)
            .expect("arrow ipc file")
            .map(|batch| batch.expect("arrow batch"))
            .collect()
    }

    fn decode(spec: Value, query: Value) -> Decoded {
        let bytes = build_page(Some(&spec), &query, 100).expect("build page");
        let message = capnp::serialize_packed::read_message(
            bytes.as_slice(),
            capnp::message::ReaderOptions::new(),
        )
        .expect("read capnp message");
        let response = message
            .get_root::<hypersync_net_types_capnp::query_response::Reader>()
            .expect("query response root");
        let data = response.get_data().expect("data");
        Decoded {
            next_block: response.get_next_block(),
            archive_height: response.get_archive_height(),
            blocks: read_batches(data.get_blocks().expect("blocks"))
                .iter()
                .flat_map(|batch| simple_types::Block::from_arrow(batch).expect("blocks"))
                .collect(),
            transactions: read_batches(data.get_transactions().expect("transactions"))
                .iter()
                .flat_map(|batch| {
                    simple_types::Transaction::from_arrow(batch).expect("transactions")
                })
                .collect(),
            logs: read_batches(data.get_logs().expect("logs"))
                .iter()
                .flat_map(|batch| simple_types::Log::from_arrow(batch).expect("logs"))
                .collect(),
        }
    }

    #[test]
    fn empty_page_decodes_with_no_rows() {
        let decoded = decode(
            serde_json::json!({}),
            serde_json::json!({"from_block": 5, "to_block": 8}),
        );
        assert_eq!(
            (
                decoded.next_block,
                decoded.archive_height,
                decoded.blocks.len(),
                decoded.transactions.len(),
                decoded.logs.len()
            ),
            (8, 100, 0, 0, 0)
        );
    }

    #[test]
    fn rows_decode_into_the_client_row_types() {
        let decoded = decode(
            serde_json::json!({
                "blocks": [{"number": 10, "timestamp": 1700000000, "hash": "0x000000000000000000000000000000000000000000000000000000000000000a"}],
                "logs": [{
                    "block_number": 10,
                    "log_index": 3,
                    "transaction_index": 1,
                    "address": "0x00000000000000000000000000000000000000aa",
                    "data": "0x1234",
                    "removed": false,
                }],
                "transactions": [{"block_number": 10, "transaction_index": 1, "gas_used": 21000}],
            }),
            serde_json::json!({"from_block": 10, "to_block": 11}),
        );

        assert_eq!(
            (
                decoded.blocks[0].number.map(u64::from),
                decoded.blocks[0].timestamp.as_ref().map(Hex::encode_hex),
                decoded.logs[0].log_index.map(u64::from),
                decoded.logs[0].address.as_ref().map(Hex::encode_hex),
                decoded.transactions[0]
                    .gas_used
                    .as_ref()
                    .map(Hex::encode_hex),
            ),
            (
                Some(10),
                Some("0x6553f100".to_string()),
                Some(3),
                Some("0x00000000000000000000000000000000000000aa".to_string()),
                Some("0x5208".to_string()),
            )
        );
    }

    #[test]
    fn an_unselected_column_decodes_as_a_missing_field() {
        let decoded = decode(
            serde_json::json!({"blocks": [{"number": 10}]}),
            serde_json::json!({}),
        );
        assert_eq!(
            (
                decoded.blocks[0].number.map(u64::from),
                decoded.blocks[0].hash.as_ref().map(Hex::encode_hex)
            ),
            (Some(10), None)
        );
    }

    #[test]
    fn a_key_a_single_row_omits_decodes_as_null() {
        let decoded = decode(
            serde_json::json!({"transactions": [
                {"transaction_index": 0, "to": "0x00000000000000000000000000000000000000aa"},
                {"transaction_index": 1},
            ]}),
            serde_json::json!({}),
        );
        assert_eq!(
            decoded
                .transactions
                .iter()
                .map(|transaction| transaction.to.as_ref().map(Hex::encode_hex))
                .collect::<Vec<_>>(),
            vec![
                Some("0x00000000000000000000000000000000000000aa".to_string()),
                None
            ]
        );
    }

    #[test]
    fn unknown_field_is_rejected() {
        let error = build_page(
            Some(&serde_json::json!({"logs": [{"nope": 1}]})),
            &serde_json::json!({}),
            0,
        )
        .unwrap_err();
        assert!(format!("{error:#}").contains("'nope' is not a HyperSync log field"));
    }
}
