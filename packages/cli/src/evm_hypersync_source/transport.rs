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
    let block_bytes = |block: &arrow::ipc::Block| {
        let length = block.bodyLength() as usize + block.metaDataLength() as usize;
        file.slice_with_length(block.offset() as usize, length)
    };
    for block in footer.dictionaries().iter().flatten() {
        decoder
            .read_dictionary(block, &block_bytes(block))
            .context("read IPC dictionary")?;
    }
    let mut batches = Vec::new();
    for block in footer.recordBatches().iter().flatten() {
        if let Some(batch) = decoder
            .read_record_batch(block, &block_bytes(block))
            .context("read IPC record batch")?
        {
            batches.push(batch);
        }
    }
    Ok(batches)
}
