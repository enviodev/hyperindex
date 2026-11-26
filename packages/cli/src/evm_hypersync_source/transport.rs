//! HyperSync's query and height endpoints over HTTP, with each response read
//! straight into Arrow arrays over a single buffer.
//!
//! The packed Cap'n Proto body is unpacked while it downloads, into one
//! allocation that is never copied again: each table's Arrow IPC file is read
//! in place, its arrays pointing into that allocation. Nothing here retries or
//! sleeps; a failure goes straight back to the caller, which owns backoff.

use std::io::{BufRead, Read};
use std::ptr::NonNull;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use arrow::array::RecordBatch;
use arrow::buffer::Buffer;
use capnp::serialize::OwnedSegments;
use hypersync_client::RateLimitInfo;
use hypersync_net_types::hypersync_net_types_capnp::{cached_query_response, query_response};
use hypersync_net_types::{ArchiveHeight, Query, RollbackGuard};
use reqwest::{Method, StatusCode, Url};

/// Pools never go idle while a source polls, so their connections never
/// expire and DNS is never looked up again: a HyperSync failover to new
/// addresses would go unseen. Rebuilding the client this often bounds that.
const MAX_CONNECTION_AGE: Duration = Duration::from_secs(60);

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// How many downloaded chunks may wait for the unpacker.
const CHUNKS_IN_FLIGHT: usize = 4;

#[derive(Clone, Copy)]
pub(crate) enum Format {
    Json,
    CapnProto { should_cache_queries: bool },
}

pub(crate) struct Transport {
    url: Url,
    api_token: String,
    user_agent: String,
    timeout: Duration,
    format: Format,
    http: Mutex<(reqwest::Client, Instant)>,
}

/// One query response, its tables as Arrow record batches.
pub(crate) struct Response {
    pub(crate) archive_height: Option<u64>,
    pub(crate) next_block: u64,
    pub(crate) rollback_guard: Option<RollbackGuard>,
    pub(crate) blocks: Vec<RecordBatch>,
    pub(crate) transactions: Vec<RecordBatch>,
    pub(crate) logs: Vec<RecordBatch>,
}

pub(crate) enum QueryOutcome {
    Response(Response),
    RateLimited(RateLimitInfo),
}

enum Attempt {
    Response(Response),
    RateLimited(RateLimitInfo),
    PayloadTooLarge,
}

impl Transport {
    pub(crate) fn new(
        url: &str,
        api_token: String,
        user_agent: String,
        timeout: Duration,
        format: Format,
    ) -> Result<Self> {
        let url = Url::parse(url).context("url is malformed")?;
        let http = build_http_client(&user_agent)?;
        Ok(Transport {
            url,
            api_token,
            user_agent,
            timeout,
            format,
            http: Mutex::new((http, Instant::now())),
        })
    }

    fn http_client(&self) -> Result<reqwest::Client> {
        let mut http = self.http.lock().unwrap();
        // Real time on purpose: this ages TCP connections to the real server,
        // it isn't a timer the indexer waits on.
        if http.1.elapsed() > MAX_CONNECTION_AGE {
            *http = (build_http_client(&self.user_agent)?, Instant::now());
        }
        Ok(http.0.clone())
    }

    fn request(&self, method: Method, path: &[&str]) -> Result<reqwest::RequestBuilder> {
        let mut url = self.url.clone();
        url.path_segments_mut()
            .map_err(|()| anyhow!("url can't take a path"))?
            .extend(path);
        Ok(self
            .http_client()?
            .request(method, url)
            .timeout(self.timeout)
            .bearer_auth(&self.api_token))
    }

    pub(crate) async fn height(&self) -> Result<u64> {
        let response = self
            .request(Method::GET, &["height"])?
            .send()
            .await
            .context("execute http req")?;
        let status = response.status();
        if !status.is_success() {
            bail!("http response status code {status}");
        }
        let height: ArchiveHeight = response.json().await.context("read response body json")?;
        Ok(height.height.unwrap_or(0))
    }

    /// Runs `query`, halving its block range for as long as the server says
    /// the response would be too large.
    pub(crate) async fn query(&self, query: &Query) -> Result<QueryOutcome> {
        let mut query = query.clone();
        loop {
            let attempt = match self.format {
                Format::Json => self.query_json(&query).await?,
                Format::CapnProto {
                    should_cache_queries,
                } => self.query_capnp(&query, should_cache_queries).await?,
            };
            match attempt {
                Attempt::Response(response) => return Ok(QueryOutcome::Response(response)),
                Attempt::RateLimited(info) => return Ok(QueryOutcome::RateLimited(info)),
                Attempt::PayloadTooLarge => {
                    let block_range = match query.to_block {
                        Some(to_block) => {
                            let current = to_block - query.from_block;
                            if current < 2 {
                                bail!(
                                    "Payload is too large and query is using the minimum block \
                                     range."
                                );
                            }
                            current / 2
                        }
                        None => 200,
                    };
                    query.to_block = Some(query.from_block + block_range);
                }
            }
        }
    }

    async fn query_json(&self, query: &Query) -> Result<Attempt> {
        let response = self
            .request(Method::POST, &["query", "arrow-ipc"])?
            .json(query)
            .send()
            .await
            .context("execute http req")?;
        match status_attempt(response).await? {
            Ok(response) => {
                let message = read_message(response).await?;
                Ok(Attempt::Response(decode_query_response(message, false)?))
            }
            Err(attempt) => Ok(attempt),
        }
    }

    async fn query_capnp(&self, query: &Query, should_cache: bool) -> Result<Attempt> {
        let path = ["query", "arrow-ipc", "capnp"];
        if should_cache {
            let body = write_request(|request| request.build_query_id_from_query(query))?;
            let response = self
                .request(Method::POST, &path)?
                .body(body)
                .send()
                .await
                .context("execute http req")?;
            let status = response.status();
            match status {
                StatusCode::PAYLOAD_TOO_LARGE => return Ok(Attempt::PayloadTooLarge),
                StatusCode::TOO_MANY_REQUESTS => {
                    return Ok(Attempt::RateLimited(rate_limit_info(&response)))
                }
                status if status.is_success() => {
                    let message = read_message(response).await?;
                    if let Some(response) = decode_cached_query_response(message)? {
                        return Ok(Attempt::Response(response));
                    }
                }
                status => {
                    let text = response.text().await.context("read text to see error")?;
                    log::warn!(
                        "Failed cache query, will retry full query. {status}, err body: {text}"
                    );
                }
            }
        }

        let body =
            write_request(|request| request.build_full_query_from_query(query, should_cache))?;
        let response = self
            .request(Method::POST, &path)?
            .body(body)
            .send()
            .await
            .context("execute http req")?;
        match status_attempt(response).await? {
            Ok(response) => {
                let message = read_message(response).await?;
                Ok(Attempt::Response(decode_query_response(message, false)?))
            }
            Err(attempt) => Ok(attempt),
        }
    }
}

fn build_http_client(user_agent: &str) -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .user_agent(user_agent)
        // Without it a dead address holds the connection in SYN_SENT until the
        // request timeout. Hyper splits it across the resolved addresses and
        // moves on to the next.
        .connect_timeout(CONNECT_TIMEOUT)
        .build()
        .context("build http client")
}

fn write_request(
    build: impl FnOnce(
        &mut hypersync_net_types::hypersync_net_types_capnp::request::Builder,
    ) -> capnp::Result<()>,
) -> Result<Vec<u8>> {
    let mut message = capnp::message::Builder::new_default();
    let mut request =
        message.init_root::<hypersync_net_types::hypersync_net_types_capnp::request::Builder>();
    build(&mut request).context("build capnp request")?;
    let mut bytes = Vec::new();
    capnp::serialize_packed::write_message(&mut bytes, &message).context("write capnp request")?;
    Ok(bytes)
}

/// The response itself when it succeeded, otherwise what its status means.
async fn status_attempt(
    response: reqwest::Response,
) -> Result<std::result::Result<reqwest::Response, Attempt>> {
    let status = response.status();
    if status == StatusCode::PAYLOAD_TOO_LARGE {
        return Ok(Err(Attempt::PayloadTooLarge));
    }
    if status == StatusCode::TOO_MANY_REQUESTS {
        return Ok(Err(Attempt::RateLimited(rate_limit_info(&response))));
    }
    if !status.is_success() {
        let text = response.text().await.context("read text to see error")?;
        bail!("http response status code {status}, err body: {text}");
    }
    Ok(Ok(response))
}

fn rate_limit_info(response: &reqwest::Response) -> RateLimitInfo {
    let header = |name: &str| response.headers().get(name)?.to_str().ok();
    let number = |name: &str| header(name)?.trim().parse().ok();
    RateLimitInfo {
        // IETF draft format, "60, 60;w=60": the first number is the limit.
        limit: header("x-ratelimit-limit")
            .and_then(|value| value.split(',').next()?.trim().parse().ok()),
        remaining: number("x-ratelimit-remaining"),
        reset_secs: number("x-ratelimit-reset"),
        cost: number("x-ratelimit-cost"),
    }
}

fn reader_options() -> capnp::message::ReaderOptions {
    let mut options = capnp::message::ReaderOptions::new();
    options
        .nesting_limit(i32::MAX)
        .traversal_limit_in_words(None);
    options
}

/// A blocking reader over a body's chunks as they arrive, each dropped once
/// read.
struct ChunkReader {
    current: bytes::Bytes,
    chunks: tokio::sync::mpsc::Receiver<bytes::Bytes>,
}

impl Read for ChunkReader {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        let available = self.fill_buf()?;
        let length = available.len().min(out.len());
        out[..length].copy_from_slice(&available[..length]);
        self.consume(length);
        Ok(length)
    }
}

impl BufRead for ChunkReader {
    fn fill_buf(&mut self) -> std::io::Result<&[u8]> {
        while self.current.is_empty() {
            match self.chunks.blocking_recv() {
                Some(chunk) => self.current = chunk,
                None => break,
            }
        }
        Ok(&self.current)
    }

    fn consume(&mut self, length: usize) {
        bytes::Buf::advance(&mut self.current, length);
    }
}

/// Unpacks the body while it downloads, so the packed body is never held
/// whole: only the unpacked message, in one allocation.
async fn read_message(
    mut response: reqwest::Response,
) -> Result<capnp::message::Reader<OwnedSegments>> {
    let (sender, chunks) = tokio::sync::mpsc::channel(CHUNKS_IN_FLIGHT);
    let unpack = tokio::task::spawn_blocking(move || {
        let reader = ChunkReader {
            current: bytes::Bytes::new(),
            chunks,
        };
        capnp::serialize_packed::read_message(reader, reader_options())
    });
    let download = async {
        while let Some(chunk) = response.chunk().await.context("read response body bytes")? {
            // The unpacker stopped early: its own error says why.
            if sender.send(chunk).await.is_err() {
                break;
            }
        }
        anyhow::Ok(())
    }
    .await;
    drop(sender);
    let message = unpack.await.context("unpack response")?;
    download?;
    message.context("create message reader")
}

fn decode_cached_query_response(
    message: capnp::message::Reader<OwnedSegments>,
) -> Result<Option<Response>> {
    let root = message
        .get_root::<cached_query_response::Reader>()
        .context("get cached_query_response root")?;
    match root.get_either().which().context("get either")? {
        cached_query_response::either::Which::QueryResponse(_) => {
            decode_query_response(message, true).map(Some)
        }
        cached_query_response::either::Which::NotCached(()) => {
            log::trace!("query was not cached, retrying with full query");
            Ok(None)
        }
    }
}

/// Where a table's Arrow IPC file sits in the message's memory.
struct FileSpan {
    start: NonNull<u8>,
    length: usize,
}

fn file_span(bytes: &[u8]) -> FileSpan {
    FileSpan {
        start: NonNull::from(bytes).cast(),
        length: bytes.len(),
    }
}

fn decode_query_response(
    message: capnp::message::Reader<OwnedSegments>,
    cached: bool,
) -> Result<Response> {
    let (archive_height, next_block, rollback_guard, [blocks, transactions, logs]) = {
        let response = if cached {
            match message
                .get_root::<cached_query_response::Reader>()
                .context("get cached_query_response root")?
                .get_either()
                .which()
                .context("get either")?
            {
                cached_query_response::either::Which::QueryResponse(response) => {
                    response.context("get query response")?
                }
                cached_query_response::either::Which::NotCached(()) => {
                    bail!("expected a cached query response")
                }
            }
        } else {
            message
                .get_root::<query_response::Reader>()
                .context("get root")?
        };
        let archive_height = match response.get_archive_height() {
            -1 => None,
            height => Some(
                height
                    .try_into()
                    .context("invalid archive height returned from server")?,
            ),
        };
        let data = response.get_data().context("read data")?;
        let files = [
            file_span(data.get_blocks().context("get block data")?),
            file_span(data.get_transactions().context("get transaction data")?),
            file_span(data.get_logs().context("get log data")?),
        ];
        (
            archive_height,
            response.get_next_block(),
            read_rollback_guard(&response)?,
            files,
        )
    };
    // The spans point into the one allocation the segments own, which stays
    // where it is when the reader gives the segments up.
    let segments = Arc::new(message.into_segments());
    let read = |span: FileSpan, table: &str| {
        // SAFETY: the span lies inside the segments' allocation, which the
        // buffer keeps alive through its `Arc`.
        let file =
            unsafe { Buffer::from_custom_allocation(span.start, span.length, segments.clone()) };
        read_ipc_file(&file).with_context(|| format!("parse {table} data"))
    };
    Ok(Response {
        archive_height,
        next_block,
        rollback_guard,
        blocks: read(blocks, "block")?,
        transactions: read(transactions, "tx")?,
        logs: read(logs, "log")?,
    })
}

fn read_rollback_guard(response: &query_response::Reader) -> Result<Option<RollbackGuard>> {
    if !response.has_rollback_guard() {
        return Ok(None);
    }
    let guard = response
        .get_rollback_guard()
        .context("get rollback guard")?;
    Ok(Some(RollbackGuard {
        block_number: guard.get_block_number(),
        timestamp: guard.get_timestamp(),
        hash: guard
            .get_hash()
            .context("get rollback guard hash")?
            .try_into()
            .context("hash size")?,
        first_block_number: guard.get_first_block_number(),
        first_parent_hash: guard
            .get_first_parent_hash()
            .context("get rollback guard first parent hash")?
            .try_into()
            .context("hash size")?,
    }))
}

/// The bytes of one block of an IPC file, checked to lie inside it.
///
/// This keeps arrow's own unchecked reads in bounds, but the server is
/// trusted: other corrupted lengths, such as a compressed buffer's
/// uncompressed-length prefix, can still make arrow allocate without bound,
/// as they could with its `FileReader`.
fn block_bytes(file: &Buffer, block: &arrow::ipc::Block) -> Result<Buffer> {
    let offset = usize::try_from(block.offset()).context("IPC block offset")?;
    let metadata_length =
        usize::try_from(block.metaDataLength()).context("IPC block metadata length")?;
    // arrow reads the continuation marker and metadata length, 8 bytes,
    // without checking the block holds them.
    anyhow::ensure!(metadata_length >= 8, "IPC block metadata is too short");
    let length = usize::try_from(block.bodyLength())
        .context("IPC block body length")?
        .checked_add(metadata_length)
        .context("IPC block length overflows")?;
    anyhow::ensure!(
        offset
            .checked_add(length)
            .is_some_and(|end| end <= file.len()),
        "IPC block is out of bounds"
    );
    Ok(file.slice_with_length(offset, length))
}

/// The record batches of an Arrow IPC file, their arrays laid over `file`
/// without copying.
fn read_ipc_file(file: &Buffer) -> Result<Vec<RecordBatch>> {
    const TRAILER_LENGTH: usize = 10;
    anyhow::ensure!(
        file.len() >= TRAILER_LENGTH,
        "not an Arrow IPC file: {} bytes",
        file.len()
    );
    let trailer_start = file.len() - TRAILER_LENGTH;
    let footer_length = arrow::ipc::reader::read_footer_length(
        file[trailer_start..]
            .try_into()
            .context("read IPC trailer")?,
    )
    .context("read IPC footer length")?;
    let footer_start = trailer_start
        .checked_sub(footer_length)
        .context("IPC footer longer than the file")?;
    let footer = arrow::ipc::root_as_footer(&file[footer_start..trailer_start])
        .map_err(|error| anyhow!("read IPC footer: {error}"))?;
    let schema = Arc::new(arrow::ipc::convert::fb_to_schema(
        footer.schema().context("IPC footer has no schema")?,
    ));
    let mut decoder = arrow::ipc::reader::FileDecoder::new(schema, footer.version());
    for block in footer.dictionaries().iter().flatten() {
        decoder
            .read_dictionary(block, &block_bytes(file, block)?)
            .context("read IPC dictionary")?;
    }
    // A footer without the list would read as an empty table: a corrupted
    // response silently losing its rows.
    let blocks = footer
        .recordBatches()
        .context("IPC footer has no record batches")?;
    let mut batches = Vec::new();
    for block in blocks.iter() {
        if let Some(batch) = decoder
            .read_record_batch(block, &block_bytes(file, block)?)
            .context("read IPC record batch")?
        {
            batches.push(batch);
        }
    }
    Ok(batches)
}

#[cfg(test)]
mod tests {
    use super::*;
    use arrow::array::{Array, ArrayData};

    fn bytes_in_range(data: &ArrayData, range: &std::ops::Range<usize>) -> (usize, usize) {
        let mut inside = 0;
        let mut outside = 0;
        let buffers = data
            .buffers()
            .iter()
            .chain(data.nulls().map(|nulls| nulls.buffer()));
        for buffer in buffers {
            if range.contains(&(buffer.as_ptr() as usize)) {
                inside += buffer.len();
            } else {
                outside += buffer.len();
            }
        }
        for child in data.child_data() {
            let (child_inside, child_outside) = bytes_in_range(child, range);
            inside += child_inside;
            outside += child_outside;
        }
        (inside, outside)
    }

    fn log_batch(rows: u64) -> RecordBatch {
        RecordBatch::try_from_iter([(
            "block_number",
            Arc::new(arrow::array::UInt64Array::from_iter_values(0..rows))
                as arrow::array::ArrayRef,
        )])
        .unwrap()
    }

    /// An IPC file as HyperSync writes one: every buffer ZSTD compressed.
    fn ipc_file(batch: &RecordBatch) -> Vec<u8> {
        let options = arrow::ipc::writer::IpcWriteOptions::default()
            .try_with_compression(Some(arrow::ipc::CompressionType::ZSTD))
            .unwrap();
        let mut out = Vec::new();
        let mut writer = arrow::ipc::writer::FileWriter::try_new_with_options(
            &mut out,
            &batch.schema(),
            options,
        )
        .unwrap();
        writer.write(batch).unwrap();
        writer.finish().unwrap();
        drop(writer);
        out
    }

    /// `valid` with its first record batch block's metadata length set to
    /// `metadata_length`.
    fn with_block_metadata_length(valid: &[u8], metadata_length: i32) -> Vec<u8> {
        let footer_length =
            arrow::ipc::reader::read_footer_length(valid[valid.len() - 10..].try_into().unwrap())
                .unwrap();
        let footer_start = valid.len() - 10 - footer_length;
        let footer = arrow::ipc::root_as_footer(&valid[footer_start..valid.len() - 10]).unwrap();
        let block = footer.recordBatches().unwrap().get(0);
        let mut needle = block.offset().to_le_bytes().to_vec();
        needle.extend(block.metaDataLength().to_le_bytes());
        let position = footer_start
            + valid[footer_start..]
                .windows(needle.len())
                .position(|window| window == needle)
                .unwrap();
        let mut out = valid.to_vec();
        out[position + 8..position + 12].copy_from_slice(&metadata_length.to_le_bytes());
        out
    }

    /// `valid` with its first block's body length grown past the end of the
    /// file.
    fn with_block_past_the_end(valid: &[u8]) -> Vec<u8> {
        let footer_length =
            arrow::ipc::reader::read_footer_length(valid[valid.len() - 10..].try_into().unwrap())
                .unwrap();
        let footer_start = valid.len() - 10 - footer_length;
        let footer = arrow::ipc::root_as_footer(&valid[footer_start..valid.len() - 10]).unwrap();
        let block = footer.recordBatches().unwrap().get(0);
        let mut needle = block.metaDataLength().to_le_bytes().to_vec();
        needle.extend([0; 4]);
        needle.extend(block.bodyLength().to_le_bytes());
        let position = footer_start
            + valid[footer_start..]
                .windows(needle.len())
                .position(|window| window == needle)
                .unwrap();
        let mut out = valid.to_vec();
        out[position + 8..position + 16].copy_from_slice(&(1i64 << 40).to_le_bytes());
        out
    }

    /// An IPC file whose footer has a schema but no record batch list.
    fn without_record_batches() -> Vec<u8> {
        let mut builder = flatbuffers::FlatBufferBuilder::new();
        let schema = arrow::ipc::convert::schema_to_fb_offset(&mut builder, &log_batch(1).schema());
        let mut footer = arrow::ipc::FooterBuilder::new(&mut builder);
        footer.add_version(arrow::ipc::MetadataVersion::V5);
        footer.add_schema(schema);
        let footer = footer.finish();
        builder.finish(footer, None);
        let footer = builder.finished_data();
        let mut out = b"ARROW1\0\0".to_vec();
        out.extend_from_slice(footer);
        out.extend((footer.len() as i32).to_le_bytes());
        out.extend(b"ARROW1");
        out
    }

    #[test]
    fn a_malformed_ipc_file_is_an_error() {
        let valid = ipc_file(&log_batch(100));
        let mut bad_footer_length = valid.clone();
        let trailer = bad_footer_length.len() - 10;
        bad_footer_length[trailer..trailer + 4].copy_from_slice(&i32::MAX.to_le_bytes());
        let cases = [
            ("empty", vec![]),
            ("magic only", b"ARROW1".to_vec()),
            ("second half", valid[valid.len() / 2..].to_vec()),
            ("footer length past the start", bad_footer_length),
            ("block past the end", with_block_past_the_end(&valid)),
            ("no metadata", with_block_metadata_length(&valid, 0)),
            (
                "metadata shorter than its prefix",
                with_block_metadata_length(&valid, 7),
            ),
            ("no record batch list", without_record_batches()),
        ];
        let outcomes: Vec<(&str, String)> = cases
            .into_iter()
            .map(|(case, file)| {
                let outcome = std::panic::catch_unwind(|| read_ipc_file(&Buffer::from_vec(file)));
                let described = match outcome {
                    Ok(Ok(batches)) => format!("read {} batches", batches.len()),
                    Ok(Err(error)) => format!("error: {error}"),
                    Err(_) => "panicked".to_string(),
                };
                (case, described)
            })
            .collect();
        assert_eq!(
            outcomes,
            vec![
                ("empty", "error: not an Arrow IPC file: 0 bytes".to_string()),
                (
                    "magic only",
                    "error: not an Arrow IPC file: 6 bytes".to_string()
                ),
                (
                    "second half",
                    "error: IPC block is out of bounds".to_string()
                ),
                (
                    "footer length past the start",
                    "error: IPC footer longer than the file".to_string()
                ),
                (
                    "block past the end",
                    "error: IPC block is out of bounds".to_string()
                ),
                (
                    "no metadata",
                    "error: IPC block metadata is too short".to_string()
                ),
                (
                    "metadata shorter than its prefix",
                    "error: IPC block metadata is too short".to_string()
                ),
                (
                    "no record batch list",
                    "error: IPC footer has no record batches".to_string()
                ),
            ]
        );
    }

    #[test]
    fn a_compressed_ipc_file_reads_back() {
        let batch = log_batch(100);
        assert_eq!(
            read_ipc_file(&Buffer::from_vec(ipc_file(&batch))).unwrap(),
            vec![batch]
        );
    }

    // https://github.com/enviodev/hyperindex/issues/1691
    #[cfg(target_os = "linux")]
    #[tokio::test(start_paused = true)]
    async fn an_unreachable_address_fails_at_the_connect_timeout() {
        // Linux drops SYNs once the accept queue is full, like a blackholed
        // address.
        let socket = tokio::net::TcpSocket::new_v4().unwrap();
        socket.bind("127.0.0.1:0".parse().unwrap()).unwrap();
        let listener = socket.listen(0).unwrap().into_std().unwrap();
        let address = listener.local_addr().unwrap();
        // Filled with blocking connects: the paused clock would expire a
        // timeout before a loopback handshake completed. It has to end on a
        // timed out connect, or the address refuses rather than drops and the
        // request below would fail without any timeout.
        let mut fillers = Vec::new();
        loop {
            match std::net::TcpStream::connect_timeout(&address, Duration::from_millis(50)) {
                Ok(stream) => fillers.push(stream),
                Err(error) if error.kind() == std::io::ErrorKind::TimedOut => break,
                Err(error) => panic!("filling the accept queue: {error}"),
            }
        }
        let transport = Transport::new(
            &format!("http://{address}"),
            "00000000-0000-0000-0000-000000000000".to_string(),
            "test".to_string(),
            Duration::from_secs(60),
            Format::Json,
        )
        .unwrap();
        // The paused clock jumps to whichever timeout fires first, so the
        // elapsed time names the timer.
        let start = tokio::time::Instant::now();
        let result = transport.height().await;
        let elapsed = start.elapsed();
        assert!(
            result.is_err()
                && elapsed >= CONNECT_TIMEOUT
                && elapsed < CONNECT_TIMEOUT + Duration::from_secs(1),
            "{result:?} after {elapsed:?}"
        );
    }

    /// What a real HyperSync response looks like on the wire and once read:
    /// the HTTP version, the body and unpacked sizes, and how much of each
    /// table's arrays stays in the message rather than being decompressed.
    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "live: needs ENVIO_API_TOKEN and network access to eth.hypersync.xyz"]
    async fn live_response_shape() {
        let query: Query = serde_json::from_value(serde_json::json!({
            "from_block": 20_000_000,
            "to_block": 20_000_200,
            "logs": [{"topics": [["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"]]}],
            "field_selection": {
                "block": ["number", "hash", "timestamp"],
                "transaction": ["block_number", "transaction_index", "hash"],
                "log": ["address", "data", "log_index", "topic0", "topic1", "topic2", "topic3",
                        "block_number", "transaction_index"],
            },
        }))
        .unwrap();
        let transport = Transport::new(
            "https://eth.hypersync.xyz",
            std::env::var("ENVIO_API_TOKEN").unwrap(),
            "hyperindex-live-test".to_string(),
            Duration::from_secs(60),
            Format::CapnProto {
                should_cache_queries: false,
            },
        )
        .unwrap();
        let body =
            write_request(|request| request.build_full_query_from_query(&query, false)).unwrap();
        let response = transport
            .request(Method::POST, &["query", "arrow-ipc", "capnp"])
            .unwrap()
            .body(body)
            .send()
            .await
            .unwrap();
        let http_version = format!("{:?}", response.version());
        let body = response.bytes().await.unwrap();
        let message = capnp::serialize_packed::read_message(&body[..], reader_options()).unwrap();
        let segments_bytes: usize = {
            use capnp::message::ReaderSegments;
            let segments = message.into_segments();
            (0..segments.len())
                .map(|index| segments.get_segment(index as u32).unwrap().len())
                .sum()
        };
        let message = capnp::serialize_packed::read_message(&body[..], reader_options()).unwrap();
        let data = message
            .get_root::<query_response::Reader>()
            .unwrap()
            .get_data()
            .unwrap();
        let mut report = vec![format!(
            "HTTP {http_version}, body {} bytes, unpacked {segments_bytes} bytes",
            body.len()
        )];
        for (table, file) in [
            ("blocks", data.get_blocks().unwrap()),
            ("transactions", data.get_transactions().unwrap()),
            ("logs", data.get_logs().unwrap()),
        ] {
            let buffer = Buffer::from_slice_ref(file);
            let range_of_copy =
                (buffer.as_ptr() as usize)..(buffer.as_ptr() as usize + buffer.len());
            let batches = read_ipc_file(&buffer).unwrap();
            let (mut inside, mut outside, mut rows) = (0, 0, 0);
            for batch in &batches {
                rows += batch.num_rows();
                for column in batch.columns() {
                    let (column_inside, column_outside) =
                        bytes_in_range(&column.to_data(), &range_of_copy);
                    inside += column_inside;
                    outside += column_outside;
                }
            }
            let footer_compression = {
                let trailer_start = file.len() - 10;
                let footer_length = arrow::ipc::reader::read_footer_length(
                    file[trailer_start..].try_into().unwrap(),
                )
                .unwrap();
                let footer =
                    arrow::ipc::root_as_footer(&file[trailer_start - footer_length..trailer_start])
                        .unwrap();
                let block = footer.recordBatches().unwrap().get(0);
                let message = arrow::ipc::root_as_message(
                    &file[block.offset() as usize + 8
                        ..block.offset() as usize + block.metaDataLength() as usize],
                )
                .unwrap();
                format!(
                    "{:?}",
                    message
                        .header_as_record_batch()
                        .and_then(|batch| batch.compression())
                        .map(|compression| compression.codec())
                )
            };
            report.push(format!(
                "{table}: {rows} rows, file {} bytes, {} batches, codec {footer_compression}, \
                 array bytes in the file {inside}, decompressed {outside}",
                file.len(),
                batches.len()
            ));
        }
        println!("\n{}\n", report.join("\n"));
    }
}
