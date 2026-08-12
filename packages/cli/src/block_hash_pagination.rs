use std::future::Future;
use std::time::Instant;

use anyhow::Context;

use crate::block_store::BlockStore;
use crate::evm_hypersync_source::map_err;
use crate::request_stats::{
    error_with_request_stats, source_behind_head_err, RequestStat, QUERY_BLOCK_HASHES_METHOD,
};

/// One page of a block-hash query.
pub(crate) struct HashPage {
    /// Where the backend stopped: the first block it has not processed.
    pub next: i64,
    /// The last block the page actually returned, if any. Not always
    /// `next - 1`: SVM slots can be skipped, and a page can return nothing.
    pub last_returned: Option<i64>,
    pub store: BlockStore,
}

/// Drive a block-hash query across pages into one response store.
///
/// Follow-up pages re-request the last block the previous page returned: one
/// backend response is internally consistent, so a fork switch between two
/// paginated requests is the only seam, and it surfaces as a hash collision on
/// the overlapping block when the page is appended. A page that leaves the
/// cursor where it was means the instance serving it has not reached the range,
/// which is the caller's cue to back off and retry or fail over.
///
/// `fetch_page` receives the block to request from and the exclusive upper
/// bound, and appends whatever bookkeeping its ecosystem needs to the page.
pub(crate) async fn paginate_block_hashes<Fetch, Fut>(
    block_numbers: &[i64],
    aggregate: &BlockStore,
    unit: &str,
    mut fetch_page: Fetch,
) -> napi::Result<Vec<RequestStat>>
where
    Fetch: FnMut(i64, i64) -> Fut,
    Fut: Future<Output = napi::Result<HashPage>>,
{
    let Some(from) = block_numbers.iter().copied().min() else {
        return Ok(Vec::new());
    };
    if from < 0 {
        return Err(map_err(anyhow::anyhow!("{unit} must be non-negative")));
    }
    let to_exclusive = block_numbers
        .iter()
        .copied()
        .max()
        .unwrap_or(from)
        .checked_add(1)
        .context("range upper bound overflow")
        .map_err(map_err)?;

    let mut request_stats = Vec::new();
    let mut cursor = from;
    let mut overlap = None;
    loop {
        let request_from = overlap.unwrap_or(cursor);
        let started = Instant::now();
        let page = fetch_page(request_from, to_exclusive).await;
        request_stats.push(RequestStat {
            method: QUERY_BLOCK_HASHES_METHOD.to_string(),
            seconds: started.elapsed().as_secs_f64(),
        });
        let page = page.map_err(|error| error_with_request_stats(error, &request_stats))?;
        if page.next <= cursor {
            return Err(error_with_request_stats(
                source_behind_head_err(cursor),
                &request_stats,
            ));
        }
        aggregate.append_page(&page.store);
        if page.next >= to_exclusive {
            return Ok(request_stats);
        }
        cursor = page.next;
        // A page that returned no rows leaves the seam where it was, so the
        // next request still overlaps a block the aggregate already holds.
        overlap = page.last_returned.or(overlap);
    }
}
