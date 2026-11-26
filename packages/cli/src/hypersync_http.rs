//! What the HyperSync servers share over HTTP, whatever the chain: one HTTP
//! client per source, a response's status read the same way, and Arrow IPC
//! tables read in place from the response's memory.
//!
//! Nothing here retries or sleeps: a failure goes straight back to the caller,
//! which owns backoff.

use std::io::{BufRead, Read};
use std::ptr::NonNull;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use arrow::array::RecordBatch;
use arrow::buffer::Buffer;
use capnp::serialize::OwnedSegments;
use hypersync_client::RateLimitInfo;
use reqwest::{Method, StatusCode, Url};

/// Pools never go idle while a source polls, so their connections never
/// expire and DNS is never looked up again: a failover to new addresses would
/// go unseen. Rebuilding the client this often bounds that.
const MAX_CONNECTION_AGE: Duration = Duration::from_secs(60);

pub(crate) const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// How many downloaded chunks may wait for the unpacker.
const CHUNKS_IN_FLIGHT: usize = 4;

pub(crate) struct HttpClient {
    url: Url,
    api_token: Option<String>,
    user_agent: String,
    timeout: Duration,
    http: Mutex<(reqwest::Client, Instant)>,
}

impl HttpClient {
    pub(crate) fn new(
        url: &str,
        api_token: Option<String>,
        user_agent: String,
        timeout: Duration,
    ) -> Result<Self> {
        let url = Url::parse(url).context("url is malformed")?;
        let http = build_http_client(&user_agent)?;
        Ok(HttpClient {
            url,
            api_token,
            user_agent,
            timeout,
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

    pub(crate) fn request(&self, method: Method, path: &[&str]) -> Result<reqwest::RequestBuilder> {
        let mut url = self.url.clone();
        url.path_segments_mut()
            .map_err(|()| anyhow!("url can't take a path"))?
            .extend(path);
        let request = self
            .http_client()?
            .request(method, url)
            .timeout(self.timeout);
        Ok(match &self.api_token {
            Some(token) => request.bearer_auth(token),
            None => request,
        })
    }

    /// A successful GET of `path`.
    pub(crate) async fn get(&self, path: &[&str]) -> Result<reqwest::Response> {
        let response = self
            .request(Method::GET, path)?
            .send()
            .await
            .context("execute http req")?;
        let status = response.status();
        if !status.is_success() {
            bail!("http response status code {status}");
        }
        Ok(response)
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

/// What a query's response status means.
pub(crate) enum Reply {
    Success(reqwest::Response),
    RateLimited(RateLimitInfo),
    PayloadTooLarge,
}

/// The reply to a query; any other failed status is an error carrying the
/// server's message.
pub(crate) async fn reply_of(response: reqwest::Response) -> Result<Reply> {
    let status = response.status();
    if status == StatusCode::PAYLOAD_TOO_LARGE {
        return Ok(Reply::PayloadTooLarge);
    }
    if status == StatusCode::TOO_MANY_REQUESTS {
        return Ok(Reply::RateLimited(rate_limit_info(&response)));
    }
    if !status.is_success() {
        let text = response.text().await.context("read text to see error")?;
        bail!("http response status code {status}, err body: {text}");
    }
    Ok(Reply::Success(response))
}

pub(crate) fn rate_limit_info(response: &reqwest::Response) -> RateLimitInfo {
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

/// Unpacks a packed Cap'n Proto body while it downloads, so the packed body
/// is never held whole: only the unpacked message, in one allocation.
pub(crate) async fn read_packed_message(
    mut response: reqwest::Response,
    options: capnp::message::ReaderOptions,
) -> Result<capnp::message::Reader<OwnedSegments>> {
    let (sender, chunks) = tokio::sync::mpsc::channel(CHUNKS_IN_FLIGHT);
    let unpack = tokio::task::spawn_blocking(move || {
        let reader = ChunkReader {
            current: bytes::Bytes::new(),
            chunks,
        };
        capnp::serialize_packed::read_message(reader, options)
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

/// The whole body in one buffer, sized up front when the server says how
/// long it is.
#[allow(dead_code)]
pub(crate) async fn read_body(mut response: reqwest::Response) -> Result<Buffer> {
    let mut body = Vec::with_capacity(response.content_length().unwrap_or(0) as usize);
    while let Some(chunk) = response.chunk().await.context("read response body bytes")? {
        body.extend_from_slice(&chunk);
    }
    Ok(Buffer::from_vec(body))
}

/// Where a table's Arrow IPC file sits in a message's memory.
pub(crate) struct FileSpan {
    start: NonNull<u8>,
    length: usize,
}

pub(crate) fn file_span(bytes: &[u8]) -> FileSpan {
    FileSpan {
        start: NonNull::from(bytes).cast(),
        length: bytes.len(),
    }
}

/// Reads the IPC files at `spans`, named for errors, in place in the memory
/// `segments` own.
pub(crate) fn read_files_in_message<const N: usize>(
    segments: OwnedSegments,
    spans: [(FileSpan, &str); N],
) -> Result<[Vec<RecordBatch>; N]> {
    // The spans point into the one allocation the segments own, which stays
    // where it is when the reader gives the segments up.
    let segments = Arc::new(segments);
    let mut tables = Vec::with_capacity(N);
    for (span, table) in spans {
        // SAFETY: the span lies inside the segments' allocation, which the
        // buffer keeps alive through its `Arc`.
        let file =
            unsafe { Buffer::from_custom_allocation(span.start, span.length, segments.clone()) };
        tables.push(read_ipc_file(&file).with_context(|| format!("parse {table} data"))?);
    }
    Ok(tables
        .try_into()
        .unwrap_or_else(|_| unreachable!("one table per span")))
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
/// without copying wherever a buffer is stored uncompressed.
pub(crate) fn read_ipc_file(file: &Buffer) -> Result<Vec<RecordBatch>> {
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
        let client = HttpClient::new(
            &format!("http://{address}"),
            None,
            "test".to_string(),
            Duration::from_secs(60),
        )
        .unwrap();
        // The paused clock jumps to whichever timeout fires first, so the
        // elapsed time names the timer.
        let start = tokio::time::Instant::now();
        let result = client.get(&["height"]).await.map(|_| ());
        let elapsed = start.elapsed();
        assert!(
            result.is_err()
                && elapsed >= CONNECT_TIMEOUT
                && elapsed < CONNECT_TIMEOUT + Duration::from_secs(1),
            "{result:?} after {elapsed:?}"
        );
    }
}
