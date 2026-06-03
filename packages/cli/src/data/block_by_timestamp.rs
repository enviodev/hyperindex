use std::future::Future;

use anyhow::{anyhow, Context, Result};
use arrow::array::{Array, AsArray};
use arrow::datatypes::DataType;
use hypersync_client::net_types::block::BlockField;
use hypersync_client::net_types::{FieldSelection, Query};
use hypersync_client::{ArrowResponse, Client};

use super::where_filter::{CmpOp, TimestampBounds, WhereFilter};

/// Blocks fetched per probe. Larger windows trade query size for fewer
/// round-trips: when the interpolated guess lands within this many blocks of the
/// crossover, a single probe finds it. Doubled on a miss so a poor guess on a
/// chain with clustered block times still converges quickly.
const PROBE_WINDOW: u64 = 1024;
const MAX_PROBE_WINDOW: u64 = 1 << 20;

/// Resolves every `block.timestamp` comparison into a block number and folds it
/// into the filter's scan window. Comparisons stay on the filter as client-side
/// polish, so this only ever tightens `from_block`/`to_block_exclusive`.
pub async fn apply(filter: &mut WhereFilter, client: &Client) -> Result<()> {
    if filter.timestamp.is_empty() {
        return Ok(());
    }

    let fetch = |from: u64, to_excl: u64| async move {
        let response = client
            .get_arrow(&block_window_query(from, to_excl))
            .await
            .with_context(|| format!("Failed fetching blocks [{from}, {to_excl}) by timestamp"))?;
        decode_blocks(&response)
    };

    let height = client
        .get_height()
        .await
        .context("Failed fetching chain height for timestamp lookup")?;
    let mut search = Search::new(height, fetch).await?;

    let (from, to_excl) = resolve_bounds(&mut search, &filter.timestamp).await?;
    if let Some(from) = from {
        filter.narrow_from(from);
    }
    if let Some(to_excl) = to_excl {
        filter.narrow_to_excl(to_excl);
    }

    Ok(())
}

/// Resolves a set of timestamp filters into a `(from_block, to_block_exclusive)`
/// window. Every operator reduces to `lower_bound` — "first block whose timestamp
/// is >= target":
/// - `_gte T`/`_gt T` push `from`; `_lte T`/`_lt T` push `to_excl`.
/// - an `_eq`/`_in` set spans `[lower_bound(min), lower_bound(max + 1))`.
async fn resolve_bounds<F, Fut>(
    search: &mut Search<F>,
    bounds: &TimestampBounds,
) -> Result<(Option<u64>, Option<u64>)>
where
    F: FnMut(u64, u64) -> Fut,
    Fut: Future<Output = Result<Vec<(u64, u64)>>>,
{
    let mut from: Option<u64> = None;
    let mut to_excl: Option<u64> = None;

    for &(op, secs) in &bounds.conds {
        let target = match op {
            CmpOp::Gte | CmpOp::Lt => secs,
            CmpOp::Gt | CmpOp::Lte => secs.saturating_add(1),
        };
        let block = search.lower_bound(target).await?;
        match op {
            CmpOp::Gte | CmpOp::Gt => narrow_max(&mut from, block),
            CmpOp::Lte | CmpOp::Lt => narrow_min(&mut to_excl, block),
        }
    }

    let span = bounds
        .eq_targets
        .iter()
        .min()
        .copied()
        .zip(bounds.eq_targets.iter().max().copied());
    if let Some((min, max)) = span {
        narrow_max(&mut from, search.lower_bound(min).await?);
        narrow_min(
            &mut to_excl,
            search.lower_bound(max.saturating_add(1)).await?,
        );
    }

    Ok((from, to_excl))
}

fn narrow_max(slot: &mut Option<u64>, n: u64) {
    *slot = Some(slot.map_or(n, |cur| cur.max(n)));
}

fn narrow_min(slot: &mut Option<u64>, n: u64) {
    *slot = Some(slot.map_or(n, |cur| cur.min(n)));
}

fn block_window_query(from: u64, to_excl: u64) -> Query {
    let mut field_selection = FieldSelection::default();
    field_selection.block.insert(BlockField::Number);
    field_selection.block.insert(BlockField::Timestamp);

    let mut query = Query::new()
        .from_block(from)
        .to_block_excl(to_excl)
        .include_all_blocks();
    query.field_selection = field_selection;
    query
}

fn decode_blocks(response: &ArrowResponse) -> Result<Vec<(u64, u64)>> {
    let mut pairs = Vec::new();
    for batch in &response.data.blocks {
        let numbers = batch
            .column_by_name("number")
            .ok_or_else(|| anyhow!("block response missing `number` column"))?;
        let timestamps = batch
            .column_by_name("timestamp")
            .ok_or_else(|| anyhow!("block response missing `timestamp` column"))?;
        for row in 0..batch.num_rows() {
            pairs.push((column_u64(numbers, row)?, column_u64(timestamps, row)?));
        }
    }
    pairs.sort_unstable_by_key(|(block, _)| *block);
    Ok(pairs)
}

fn column_u64(col: &dyn Array, row: usize) -> Result<u64> {
    match col.data_type() {
        DataType::UInt64 => Ok(col
            .as_primitive::<arrow::datatypes::UInt64Type>()
            .value(row)),
        DataType::UInt32 => Ok(col
            .as_primitive::<arrow::datatypes::UInt32Type>()
            .value(row) as u64),
        DataType::Binary => {
            let bytes = col.as_binary::<i32>().value(row);
            let mut out = 0u64;
            for &b in bytes {
                out = (out << 8) | b as u64;
            }
            Ok(out)
        }
        dt => Err(anyhow!(
            "unexpected arrow data type {dt:?} for block number/timestamp"
        )),
    }
}

/// Interpolation search over block timestamps, anchored on the chain's first and
/// latest blocks. The anchors are fetched once and shared across every bound.
struct Search<F> {
    top: u64,
    genesis_ts: u64,
    head_ts: u64,
    fetch: F,
}

impl<F, Fut> Search<F>
where
    F: FnMut(u64, u64) -> Fut,
    Fut: Future<Output = Result<Vec<(u64, u64)>>>,
{
    async fn new(height: u64, mut fetch: F) -> Result<Self> {
        // `get_height` can report a block that isn't yet downloadable, so take the
        // newest block actually returned in a small window at the tip as the head
        // anchor. Genesis is block 0.
        let head_window = fetch(height.saturating_sub(PROBE_WINDOW), height + 1).await?;
        let &(top, head_ts) = head_window
            .last()
            .ok_or_else(|| anyhow!("chain returned no blocks near height {height}"))?;
        let genesis = fetch(0, 1).await?;
        let &(_, genesis_ts) = genesis
            .first()
            .ok_or_else(|| anyhow!("chain returned no genesis block"))?;
        Ok(Search {
            top,
            genesis_ts,
            head_ts,
            fetch,
        })
    }

    /// Smallest block in `[0, top]` whose timestamp is `>= target`, or `top + 1`
    /// when every block is older than `target`.
    async fn lower_bound(&mut self, target: u64) -> Result<u64> {
        if target <= self.genesis_ts {
            return Ok(0);
        }
        if target > self.head_ts {
            return Ok(self.top + 1);
        }

        // Invariant: ts(lo) < target <= ts(hi).
        let (mut lo, mut lo_ts) = (0u64, self.genesis_ts);
        let (mut hi, mut hi_ts) = (self.top, self.head_ts);
        let mut window = PROBE_WINDOW;

        while hi - lo > 1 {
            let est = interpolate(lo, lo_ts, hi, hi_ts, target).clamp(lo + 1, hi - 1);
            let from = est.saturating_sub(window / 2).max(lo + 1);
            // `hi` is a known anchor, so never refetch it; keeping `to_excl <= hi`
            // also guarantees each probe strictly narrows `[lo, hi]`.
            let to_excl = (est + window / 2 + 1).clamp(from + 1, hi);

            let pairs = (self.fetch)(from, to_excl).await?;
            let (&(first_block, first_ts), &(last_block, last_ts)) = (
                pairs
                    .first()
                    .ok_or_else(|| anyhow!("empty block window [{from}, {to_excl})"))?,
                pairs.last().expect("non-empty checked above"),
            );

            if first_ts >= target {
                (hi, hi_ts) = (first_block, first_ts);
            } else if last_ts < target {
                (lo, lo_ts) = (last_block, last_ts);
            } else {
                let (block, _) = pairs
                    .iter()
                    .find(|(_, ts)| *ts >= target)
                    .expect("crossover lies inside the window");
                return Ok(*block);
            }
            window = (window * 2).min(MAX_PROBE_WINDOW);
        }
        Ok(hi)
    }
}

fn interpolate(lo: u64, lo_ts: u64, hi: u64, hi_ts: u64, target: u64) -> u64 {
    let span_ts = hi_ts.saturating_sub(lo_ts);
    if span_ts == 0 {
        return lo + (hi - lo) / 2;
    }
    let into = u128::from(target - lo_ts);
    let span_blocks = u128::from(hi - lo);
    (u128::from(lo) + into * span_blocks / u128::from(span_ts)) as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;
    use std::cell::Cell;

    /// Strictly increasing timeline: block `b` has timestamp `base + b * step`
    /// plus a deterministic jitter that stays within `step`, so the sequence is
    /// monotonic but not perfectly linear.
    #[derive(Clone, Copy)]
    struct Timeline {
        base: u64,
        step: u64,
        top: u64,
    }

    impl Timeline {
        fn ts(self, block: u64) -> u64 {
            self.base + block * self.step + (block % 7) * (self.step / 8)
        }

        fn first_at_least(self, target: u64) -> u64 {
            (0..=self.top)
                .find(|&b| self.ts(b) >= target)
                .unwrap_or(self.top + 1)
        }
    }

    /// Builds a `Search` whose probes walk `timeline`, counting fetches in `probes`.
    fn search<'a>(
        timeline: Timeline,
        probes: &'a Cell<u32>,
    ) -> Search<impl FnMut(u64, u64) -> std::future::Ready<Result<Vec<(u64, u64)>>> + 'a> {
        Search {
            top: timeline.top,
            genesis_ts: timeline.ts(0),
            head_ts: timeline.ts(timeline.top),
            fetch: move |from: u64, to_excl: u64| {
                probes.set(probes.get() + 1);
                let to_excl = to_excl.min(timeline.top + 1);
                std::future::ready(Ok((from..to_excl).map(|b| (b, timeline.ts(b))).collect()))
            },
        }
    }

    #[tokio::test]
    async fn lower_bound_matches_linear_scan_across_targets() {
        let timeline = Timeline {
            base: 1_000_000,
            step: 12,
            top: 5_000_000,
        };
        let probes = Cell::new(0);
        let mut search = search(timeline, &probes);
        for target in [0, 1_000_000, 1_000_006, 1_500_007, 31_000_001, u64::MAX] {
            assert_eq!(
                search.lower_bound(target).await.unwrap(),
                timeline.first_at_least(target),
            );
        }
    }

    #[tokio::test]
    async fn below_genesis_and_above_head_clamp_without_probing() {
        let timeline = Timeline {
            base: 1_000_000,
            step: 12,
            top: 5_000_000,
        };
        let probes = Cell::new(0);
        let mut search = search(timeline, &probes);
        let below = search.lower_bound(0).await.unwrap();
        let above = search.lower_bound(u64::MAX).await.unwrap();
        assert_eq!((below, above, probes.get()), (0, 5_000_001, 0));
    }

    #[tokio::test]
    async fn converges_in_few_probes() {
        let timeline = Timeline {
            base: 1_700_000_000,
            step: 12,
            top: 100_000_000,
        };
        let probes = Cell::new(0);
        let mut search = search(timeline, &probes);
        let block = search.lower_bound(timeline.ts(73_421_900)).await.unwrap();
        assert_eq!((block, probes.get() <= 3), (73_421_900, true));
    }

    fn timeline() -> Timeline {
        Timeline {
            base: 1_000_000,
            step: 12,
            top: 5_000_000,
        }
    }

    #[tokio::test]
    async fn resolve_comparisons_map_to_from_and_to() {
        let timeline = timeline();
        let (lo, hi) = (timeline.ts(1_000_000), timeline.ts(3_000_000));
        let probes = Cell::new(0);
        let mut search = search(timeline, &probes);
        let bounds = TimestampBounds {
            conds: vec![(CmpOp::Gte, lo), (CmpOp::Lt, hi)],
            eq_targets: vec![],
        };
        assert_eq!(
            resolve_bounds(&mut search, &bounds).await.unwrap(),
            (
                Some(timeline.first_at_least(lo)),
                Some(timeline.first_at_least(hi)),
            ),
        );
    }

    #[tokio::test]
    async fn resolve_eq_set_spans_min_to_max() {
        let timeline = timeline();
        let (a, b) = (timeline.ts(2_000_000), timeline.ts(4_000_000));
        let probes = Cell::new(0);
        let mut search = search(timeline, &probes);
        // Order and a comparison that's wider than the set must not loosen it.
        let bounds = TimestampBounds {
            conds: vec![(CmpOp::Gte, timeline.ts(0))],
            eq_targets: vec![b, a],
        };
        assert_eq!(
            resolve_bounds(&mut search, &bounds).await.unwrap(),
            (
                Some(timeline.first_at_least(a)),
                Some(timeline.first_at_least(b + 1)),
            ),
        );
    }
}
