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
/// the overlapping block when the page is appended. A page requested from the
/// cursor that leaves the cursor where it was means the instance serving it has
/// not reached the range, which is the caller's cue to back off and retry or
/// fail over.
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
        aggregate.append_page(&page.store);
        if page.next >= to_exclusive {
            return Ok(request_stats);
        }
        if page.next <= cursor {
            if request_from < cursor && page.next > request_from {
                // Rewinding to the overlap block covered no ground the cursor
                // had not already passed, yet the page still moved past where
                // it was asked to start. That is this loop's own anchor failing
                // to advance, not an instance stuck behind the head, so drop
                // the anchor and ask again from the cursor.
                overlap = None;
                continue;
            }
            // The page stopped at or before its own start block: the instance
            // has not reached this range. Reported without re-asking from the
            // cursor, which would only repeat the same answer.
            return Err(error_with_request_stats(
                source_behind_head_err(cursor),
                &request_stats,
            ));
        }
        cursor = page.next;
        // The seam is the block this page ended on. A page that returned no
        // rows has none, and keeping an older anchor would rewind behind the
        // cursor and replay the same window on every request.
        overlap = page.last_returned;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hypersync_client::format::Hash;
    use hypersync_client::simple_types;
    use std::cell::RefCell;

    fn block(number: u64) -> simple_types::Block {
        simple_types::Block {
            number: Some(number),
            hash: Some(Hash::from([(number % 251) as u8; 32])),
            ..Default::default()
        }
    }

    /// One canned backend response: the blocks it returns and where it stopped.
    struct Canned {
        next: i64,
        blocks: Vec<u64>,
    }

    /// Drive the paginator against a backend that answers by the block it was
    /// asked to start from, recording every request it received.
    async fn run(
        block_numbers: &[i64],
        responses: Vec<(i64, Canned)>,
    ) -> (napi::Result<()>, Vec<i64>, Vec<i64>) {
        let aggregate = BlockStore::new_evm(false);
        let requested = RefCell::new(Vec::new());
        let result = paginate_block_hashes(
            block_numbers,
            &aggregate,
            "block numbers",
            |request_from, _to_exclusive| {
                requested.borrow_mut().push(request_from);
                let canned = responses
                    .iter()
                    .find(|(from, _)| *from == request_from)
                    .map(|(_, canned)| canned)
                    .unwrap_or_else(|| {
                        panic!("no canned response for request_from={request_from}")
                    });
                let store = BlockStore::new_evm(false);
                store.insert_evm_blocks(canned.blocks.iter().copied().map(block).collect());
                let page = HashPage {
                    next: canned.next,
                    last_returned: canned.blocks.last().map(|b| *b as i64),
                    store,
                };
                async move { Ok(page) }
            },
        )
        .await
        .map(|_| ());
        let requested = requested.into_inner();
        let collected = aggregate.get_hashed_block_numbers(0, i64::MAX);
        (result, requested, collected)
    }

    #[tokio::test]
    async fn follow_up_pages_re_request_the_last_returned_block() {
        // The overlap is the whole point of the seam: page two starts on the
        // block page one ended with, so a fork switch between the two requests
        // lands as a hash conflict on that block.
        let (result, requested, collected) = run(
            &[100, 300],
            vec![
                (
                    100,
                    Canned {
                        next: 200,
                        blocks: vec![100, 150],
                    },
                ),
                (
                    150,
                    Canned {
                        next: 301,
                        blocks: vec![150, 300],
                    },
                ),
            ],
        )
        .await;

        assert_eq!(
            (result.is_ok(), requested, collected),
            (true, vec![100, 150], vec![100, 150, 300])
        );
    }

    #[tokio::test]
    async fn an_empty_page_does_not_re_anchor_to_a_stale_overlap() {
        // A page covering only skipped slots returns nothing. Re-anchoring to
        // the previous page's last block would rewind behind the cursor and
        // replay the same empty window forever.
        let (result, requested, collected) = run(
            &[100, 400],
            vec![
                (
                    100,
                    Canned {
                        next: 200,
                        blocks: vec![100, 150],
                    },
                ),
                (
                    150,
                    Canned {
                        next: 300,
                        blocks: vec![],
                    },
                ),
                (
                    300,
                    Canned {
                        next: 401,
                        blocks: vec![400],
                    },
                ),
            ],
        )
        .await;

        assert_eq!(
            (result.is_ok(), requested, collected),
            (true, vec![100, 150, 300], vec![100, 150, 400])
        );
    }

    #[tokio::test]
    async fn a_rewound_page_covering_no_new_ground_resumes_from_the_cursor() {
        // The overlap request can come back capped at the block it re-requested.
        // That is our own rewind failing to advance, not a source stuck behind
        // the head — drop the anchor and ask again from the cursor.
        let (result, requested, collected) = run(
            &[100, 400],
            vec![
                (
                    100,
                    Canned {
                        next: 200,
                        blocks: vec![100, 199],
                    },
                ),
                (
                    199,
                    Canned {
                        next: 200,
                        blocks: vec![199],
                    },
                ),
                (
                    200,
                    Canned {
                        next: 401,
                        blocks: vec![400],
                    },
                ),
            ],
        )
        .await;

        assert_eq!(
            (result.is_ok(), requested, collected),
            (true, vec![100, 199, 200], vec![100, 199, 400])
        );
    }

    #[tokio::test]
    async fn a_source_that_never_advances_the_cursor_errors() {
        // No rewind involved: the instance serving the request has not reached
        // the range, which is the caller's cue to back off or fail over.
        let (result, requested, _) = run(
            &[100, 400],
            vec![(
                100,
                Canned {
                    next: 100,
                    blocks: vec![],
                },
            )],
        )
        .await;

        assert_eq!((result.is_err(), requested), (true, vec![100]));
    }

    #[tokio::test]
    async fn a_behind_head_source_errors_on_the_overlap_request() {
        // The EVM anchor is always `cursor - 1`, so a behind-head instance is
        // first met on a rewound request. The page stopped before its own start
        // block, which settles it without spending a second request from the
        // cursor.
        let (result, requested, _) = run(
            &[100, 400],
            vec![
                (
                    100,
                    Canned {
                        next: 200,
                        blocks: vec![100, 199],
                    },
                ),
                (
                    199,
                    Canned {
                        next: 150,
                        blocks: vec![],
                    },
                ),
            ],
        )
        .await;

        assert_eq!((result.is_err(), requested), (true, vec![100, 199]));
    }

    #[tokio::test]
    async fn an_empty_range_makes_no_request() {
        let (result, requested, collected) = run(&[], vec![]).await;
        assert_eq!(
            (result.is_ok(), requested, collected),
            (true, vec![], vec![])
        );
    }
}
