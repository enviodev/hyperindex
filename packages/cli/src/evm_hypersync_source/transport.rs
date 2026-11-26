//! HyperSync's EVM query and height endpoints: the query sent as JSON or as
//! Cap'n Proto, by its cached id where the server holds it, and each response
//! read straight into Arrow arrays over a single buffer.

use std::time::Duration;

use anyhow::{bail, Context, Result};
use arrow::array::RecordBatch;
use capnp::serialize::OwnedSegments;
use hypersync_client::RateLimitInfo;
use hypersync_net_types::hypersync_net_types_capnp::{cached_query_response, query_response};
use hypersync_net_types::{ArchiveHeight, Query, RollbackGuard};
use reqwest::Method;

use crate::hypersync_http::{
    file_span, read_files_in_message, read_packed_message, reply_of, HttpClient, Reply,
};

#[derive(Clone, Copy)]
pub(crate) enum Format {
    Json,
    CapnProto { should_cache_queries: bool },
}

pub(crate) struct Transport {
    http: HttpClient,
    format: Format,
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
    NotCached,
}

impl Transport {
    pub(crate) fn new(
        url: &str,
        api_token: String,
        user_agent: String,
        timeout: Duration,
        format: Format,
    ) -> Result<Self> {
        Ok(Transport {
            http: HttpClient::new(url, Some(api_token), user_agent, timeout)?,
            format,
        })
    }

    pub(crate) async fn height(&self) -> Result<u64> {
        let height: ArchiveHeight = self
            .http
            .get(&["height"])
            .await?
            .json()
            .await
            .context("read response body json")?;
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
                Attempt::NotCached => bail!("a full query can't be answered as not cached"),
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
            .http
            .request(Method::POST, &["query", "arrow-ipc"])?
            .json(query)
            .send()
            .await
            .context("execute http req")?;
        attempt_of(reply_of(response).await?, Root::Plain).await
    }

    async fn query_capnp(&self, query: &Query, should_cache: bool) -> Result<Attempt> {
        let path = ["query", "arrow-ipc", "capnp"];
        if should_cache {
            let body = write_request(|request| request.build_query_id_from_query(query))?;
            let response = self
                .http
                .request(Method::POST, &path)?
                .body(body)
                .send()
                .await
                .context("execute http req")?;
            match reply_of(response).await {
                Ok(reply) => match attempt_of(reply, Root::Cached).await? {
                    // The server doesn't hold the query under its id yet.
                    Attempt::NotCached => {}
                    attempt => return Ok(attempt),
                },
                Err(error) => {
                    log::warn!("Failed cache query, will retry full query. {error:#}")
                }
            }
        }

        let body =
            write_request(|request| request.build_full_query_from_query(query, should_cache))?;
        let response = self
            .http
            .request(Method::POST, &path)?
            .body(body)
            .send()
            .await
            .context("execute http req")?;
        attempt_of(reply_of(response).await?, Root::Plain).await
    }
}

/// Which message a response body carries: a query response, or the answer
/// to a query sent by its cached id.
#[derive(Clone, Copy)]
enum Root {
    Plain,
    Cached,
}

async fn attempt_of(reply: Reply, root: Root) -> Result<Attempt> {
    Ok(match reply {
        Reply::Success(response) => {
            let message = read_packed_message(response, reader_options()).await?;
            match decode_query_response(message, root)? {
                Some(response) => Attempt::Response(response),
                None => Attempt::NotCached,
            }
        }
        Reply::RateLimited(info) => Attempt::RateLimited(info),
        Reply::PayloadTooLarge => Attempt::PayloadTooLarge,
    })
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

fn reader_options() -> capnp::message::ReaderOptions {
    let mut options = capnp::message::ReaderOptions::new();
    options
        .nesting_limit(i32::MAX)
        .traversal_limit_in_words(None);
    options
}

/// The response `message` carries; `None` when it answers a cached id the
/// server doesn't hold.
fn decode_query_response(
    message: capnp::message::Reader<OwnedSegments>,
    root: Root,
) -> Result<Option<Response>> {
    let (archive_height, next_block, rollback_guard, [blocks, transactions, logs]) = {
        let response = match root {
            Root::Plain => message
                .get_root::<query_response::Reader>()
                .context("get root")?,
            Root::Cached => match message
                .get_root::<cached_query_response::Reader>()
                .context("get cached_query_response root")?
                .get_either()
                .which()
                .context("get either")?
            {
                cached_query_response::either::Which::QueryResponse(response) => {
                    response.context("get query response")?
                }
                cached_query_response::either::Which::NotCached(()) => return Ok(None),
            },
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
    let [blocks, transactions, logs] = read_files_in_message(
        message.into_segments(),
        [(blocks, "block"), (transactions, "tx"), (logs, "log")],
    )?;
    Ok(Some(Response {
        archive_height,
        next_block,
        rollback_guard,
        blocks,
        transactions,
        logs,
    }))
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hypersync_http::read_ipc_file;
    use arrow::array::{Array, ArrayData};
    use arrow::buffer::Buffer;

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
            .http
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
