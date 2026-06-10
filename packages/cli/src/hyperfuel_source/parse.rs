use std::sync::Arc;

use anyhow::{Context, Result};
use hyperfuel_client::net_types::hyperfuel_net_types_capnp;
use hyperfuel_client::ArrowBatch;
use polars_arrow::io::ipc;

pub struct ParsedResponse {
    pub archive_height: Option<i64>,
    pub next_block: u64,
    pub total_execution_time: u64,
    pub receipts: Vec<ArrowBatch>,
    pub blocks: Vec<ArrowBatch>,
}

fn read_chunks(bytes: &[u8]) -> Result<Vec<ArrowBatch>> {
    let mut reader = std::io::Cursor::new(bytes);

    let metadata = ipc::read::read_file_metadata(&mut reader).context("read metadata")?;
    let schema = metadata.schema.clone();
    let reader = ipc::read::FileReader::new(reader, metadata, None, None);

    reader
        .map(|chunk| {
            chunk.context("read chunk").map(|chunk| ArrowBatch {
                chunk: Arc::new(chunk),
                schema: schema.clone(),
            })
        })
        .collect()
}

pub fn parse_query_response(bytes: &[u8]) -> Result<ParsedResponse> {
    let mut opts = capnp::message::ReaderOptions::new();
    // Bounded limits for untrusted network input; the traversal cap is raised
    // to 512 MiB (64M words) to fit large paginated arrow payloads.
    opts.nesting_limit(64)
        .traversal_limit_in_words(Some(64 * 1024 * 1024));
    let message_reader =
        capnp::serialize_packed::read_message(bytes, opts).context("create message reader")?;

    let query_response = message_reader
        .get_root::<hyperfuel_net_types_capnp::query_response::Reader>()
        .context("get root")?;

    let archive_height = match query_response.get_archive_height() {
        -1 => None,
        h => Some(h),
    };

    let data = query_response.get_data().context("read data")?;
    let receipts =
        read_chunks(data.get_receipts().context("get receipts")?).context("parse receipt data")?;
    let blocks =
        read_chunks(data.get_blocks().context("get blocks")?).context("parse block data")?;

    Ok(ParsedResponse {
        archive_height,
        next_block: query_response.get_next_block(),
        total_execution_time: query_response.get_total_execution_time(),
        receipts,
        blocks,
    })
}
