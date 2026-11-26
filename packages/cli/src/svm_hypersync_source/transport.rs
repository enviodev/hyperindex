//! Solana HyperSync's query and height endpoints. The query goes as JSON and
//! the response comes framed:
//!
//! ```text
//! [next_slot: u64 LE][guard_len: u32 LE][guard: JSON, guard_len bytes]
//! [num_tables: u32 LE]
//! per table: [name_len: u32 LE][name: UTF-8][ipc_len: u64 LE][Arrow IPC file]
//! ```
//!
//! `guard_len` is 0 when the server has no in-memory window to report. Each
//! table's IPC file is read in place in the body.

use anyhow::{bail, Context, Result};
use arrow::array::RecordBatch;
use arrow::buffer::Buffer;
use hypersync_client::RateLimitInfo;
use hypersync_solana_net_types::query::SolanaQuery;
use hypersync_solana_net_types::RollbackGuard;
use reqwest::Method;

use crate::hypersync_http::{read_body, read_ipc_file, reply_of, HttpClient, Reply};

pub(super) struct SvmResponse {
    pub(super) next_slot: u64,
    pub(super) rollback_guard: Option<RollbackGuard>,
    pub(super) response_bytes: usize,
    pub(super) tables: Vec<(String, Vec<RecordBatch>)>,
}

impl SvmResponse {
    pub(super) fn table(&self, name: &str) -> &[RecordBatch] {
        self.tables
            .iter()
            .find(|(table, _)| table == name)
            .map_or(&[], |(_, batches)| batches.as_slice())
    }
}

pub(super) enum QueryOutcome {
    Response(SvmResponse),
    RateLimited(RateLimitInfo),
}

pub(super) async fn height(http: &HttpClient) -> Result<u64> {
    let text = http
        .get(&["height"])
        .await
        .context("get height")?
        .text()
        .await
        .context("read height response")?;
    text.trim()
        .parse()
        .with_context(|| format!("parse height '{}'", text.trim()))
}

pub(super) async fn query(http: &HttpClient, query: &SolanaQuery) -> Result<QueryOutcome> {
    let response = http
        .request(Method::POST, &["query", "arrow"])?
        .json(query)
        .send()
        .await
        .context("execute http req")?;
    match reply_of(response).await? {
        Reply::Success(response) => {
            let body = read_body(response).await?;
            Ok(QueryOutcome::Response(
                decode_frame(&body).context("decode arrow response")?,
            ))
        }
        Reply::RateLimited(info) => Ok(QueryOutcome::RateLimited(info)),
        Reply::PayloadTooLarge => bail!("http response status code 413 Payload Too Large"),
    }
}

/// Reads the frame's fields in order, each checked to lie inside the body.
struct Frame<'a> {
    body: &'a Buffer,
    position: usize,
}

impl Frame<'_> {
    fn take(&mut self, length: usize, what: &str) -> Result<std::ops::Range<usize>> {
        let end = self
            .position
            .checked_add(length)
            .filter(|end| *end <= self.body.len())
            .with_context(|| format!("truncated {what}"))?;
        let range = self.position..end;
        self.position = end;
        Ok(range)
    }

    fn u32(&mut self, what: &str) -> Result<usize> {
        let range = self.take(4, what)?;
        Ok(u32::from_le_bytes(self.body[range].try_into().expect("4 bytes")) as usize)
    }

    fn u64(&mut self, what: &str) -> Result<u64> {
        let range = self.take(8, what)?;
        Ok(u64::from_le_bytes(
            self.body[range].try_into().expect("8 bytes"),
        ))
    }
}

fn decode_frame(body: &Buffer) -> Result<SvmResponse> {
    let mut frame = Frame { body, position: 0 };
    let next_slot = frame.u64("next slot")?;
    let guard_length = frame.u32("rollback guard length")?;
    let rollback_guard = match guard_length {
        0 => None,
        length => {
            let range = frame.take(length, "rollback guard")?;
            Some(serde_json::from_slice(&body[range]).context("parse rollback guard")?)
        }
    };
    let table_count = frame.u32("table count")?;
    let mut tables = Vec::with_capacity(table_count.min(16));
    for _ in 0..table_count {
        let name_length = frame.u32("table name length")?;
        let name_range = frame.take(name_length, "table name")?;
        let name = std::str::from_utf8(&body[name_range])
            .context("invalid table name")?
            .to_string();
        let file_length = usize::try_from(frame.u64("IPC length")?).context("IPC length")?;
        let file_range = frame.take(file_length, "IPC data")?;
        let file = body.slice_with_length(file_range.start, file_range.len());
        let batches = read_ipc_file(&file).with_context(|| format!("read {name} table"))?;
        tables.push((name, batches));
    }
    Ok(SvmResponse {
        next_slot,
        rollback_guard,
        response_bytes: body.len(),
        tables,
    })
}

#[cfg(test)]
pub(super) mod test_support {
    use arrow::array::RecordBatch;

    /// A response framed the way Solana HyperSync frames one, every table's
    /// buffers ZSTD compressed.
    pub(crate) fn frame(next_slot: u64, tables: &[(&str, &RecordBatch)]) -> Vec<u8> {
        let mut out = next_slot.to_le_bytes().to_vec();
        out.extend(0u32.to_le_bytes());
        out.extend((tables.len() as u32).to_le_bytes());
        for (name, batch) in tables {
            let options = arrow::ipc::writer::IpcWriteOptions::default()
                .try_with_compression(Some(arrow::ipc::CompressionType::ZSTD))
                .unwrap();
            let mut file = Vec::new();
            let mut writer = arrow::ipc::writer::FileWriter::try_new_with_options(
                &mut file,
                &batch.schema(),
                options,
            )
            .unwrap();
            writer.write(batch).unwrap();
            writer.finish().unwrap();
            drop(writer);
            out.extend((name.len() as u32).to_le_bytes());
            out.extend(name.as_bytes());
            out.extend((file.len() as u64).to_le_bytes());
            out.extend(file);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use arrow::array::UInt64Array;

    use super::*;

    fn blocks(slots: std::ops::Range<u64>) -> RecordBatch {
        RecordBatch::try_from_iter([(
            "slot",
            Arc::new(UInt64Array::from_iter_values(slots)) as arrow::array::ArrayRef,
        )])
        .unwrap()
    }

    #[test]
    fn a_frame_reads_back_its_tables() {
        let body = Buffer::from_vec(test_support::frame(
            11,
            &[("blocks", &blocks(0..3)), ("logs", &blocks(5..6))],
        ));
        let response = decode_frame(&body).unwrap();
        assert_eq!(
            (
                response.next_slot,
                response.table("blocks").to_vec(),
                response.table("logs").to_vec(),
                response.table("rewards").len(),
            ),
            (11, vec![blocks(0..3)], vec![blocks(5..6)], 0)
        );
    }

    #[test]
    fn a_truncated_frame_is_an_error() {
        let valid = test_support::frame(11, &[("blocks", &blocks(0..3))]);
        let errors: Vec<String> = [
            &valid[..6],
            &valid[..14],
            &valid[..20],
            &valid[..valid.len() - 1],
        ]
        .into_iter()
        .map(|body| {
            format!(
                "{:#}",
                decode_frame(&Buffer::from_slice_ref(body)).err().unwrap()
            )
        })
        .collect();
        assert_eq!(
            errors,
            vec![
                "truncated next slot".to_string(),
                "truncated table count".to_string(),
                "truncated table name".to_string(),
                "truncated IPC data".to_string(),
            ]
        );
    }
}
