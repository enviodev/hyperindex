use std::future::Future;

use anyhow::{anyhow, Context, Result};
use arrow::array::{Array, AsArray};
use arrow::datatypes::DataType;
use hypersync_client::net_types::block::BlockField;
use hypersync_client::net_types::{FieldSelection, Query};
use hypersync_client::{ArrowResponse, Client};

use serde_json::Value;

use super::mapping::TypedField;
use super::where_filter::{ClientFilter, CmpOp, Cond, TimestampBounds, WhereFilter};

/// Blocks fetched per probe. Larger windows trade query size for fewer
/// round-trips: when the interpolated guess lands within this many blocks of the
/// crossover, a single probe finds it. Doubled on a miss so a poor guess on a
/// chain with clustered block times still converges quickly.
const PROBE_WINDOW: u64 = 1024;
const MAX_PROBE_WINDOW: u64 = 1 << 20;

/// Resolves the filter's `block.timestamp` conditions into block numbers and
/// folds them into the scan window. Range comparisons keep their timestamp polish
/// on the filter; `_eq`/`_in` targets each map to a single nearest block, and a
/// `block.number` filter drops the blocks the spanning scan also returns.
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

    let resolved = resolve_bounds(&mut search, &filter.timestamp).await?;
    if let Some(from) = resolved.from {
        filter.narrow_from(from);
    }
    if let Some(to_excl) = resolved.to_excl {
        filter.narrow_to_excl(to_excl);
    }
    // A single target is already an exact one-block range; a set needs the
    // in-between blocks the [min, max] scan returns dropped client-side.
    if resolved.eq_blocks.len() > 1 {
        filter.client_filters.push(ClientFilter {
            field: TypedField::Block(BlockField::Number),
            conds: vec![Cond::In(
                resolved
                    .eq_blocks
                    .iter()
                    .copied()
                    .map(Value::from)
                    .collect(),
            )],
        });
    }

    Ok(())
}

#[derive(Default)]
struct Resolved {
    from: Option<u64>,
    to_excl: Option<u64>,
    /// Blocks `_eq`/`_in` targets resolved to, sorted and deduplicated.
    eq_blocks: Vec<u64>,
}

/// Resolves a set of timestamp filters into a block window:
/// - range comparisons map via `lower_bound` ("first block whose timestamp >= T"):
///   `_gte T`/`_gt T` push `from`; `_lte T`/`_lt T` push `to_excl` (half-open).
/// - each `_eq`/`_in` target resolves to the block "at" it (latest block <= T);
///   the window spans those blocks and a `block.number` filter drops the rest.
async fn resolve_bounds<F, Fut>(
    search: &mut Search<F>,
    bounds: &TimestampBounds,
) -> Result<Resolved>
where
    F: FnMut(u64, u64) -> Fut,
    Fut: Future<Output = Result<Vec<(u64, u64)>>>,
{
    let mut out = Resolved::default();

    for &(op, secs) in &bounds.conds {
        let target = match op {
            CmpOp::Gte | CmpOp::Lt => secs,
            CmpOp::Gt | CmpOp::Lte => secs.saturating_add(1),
        };
        let block = search.lower_bound(target).await?;
        match op {
            CmpOp::Gte | CmpOp::Gt => narrow_max(&mut out.from, block),
            CmpOp::Lte | CmpOp::Lt => narrow_min(&mut out.to_excl, block),
        }
    }

    for &secs in &bounds.eq_targets {
        out.eq_blocks.push(search.block_at(secs).await?);
    }
    out.eq_blocks.sort_unstable();
    out.eq_blocks.dedup();
    if let (Some(&min), Some(&max)) = (out.eq_blocks.first(), out.eq_blocks.last()) {
        narrow_max(&mut out.from, min);
        narrow_min(&mut out.to_excl, max.saturating_add(1));
    }

    Ok(out)
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

    /// The block "at" `target` — the latest block whose timestamp is `<= target`,
    /// matching the prevailing `closest=before` convention (Etherscan, QuickNode).
    /// Clamps into `[0, top]`: a future `target` yields the tip, one before genesis
    /// yields block 0.
    async fn block_at(&mut self, target: u64) -> Result<u64> {
        // First block with timestamp > target, minus one.
        Ok(self
            .lower_bound(target.saturating_add(1))
            .await?
            .saturating_sub(1))
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
        let resolved = resolve_bounds(&mut search, &bounds).await.unwrap();
        assert_eq!(
            (resolved.from, resolved.to_excl, resolved.eq_blocks),
            (
                Some(timeline.first_at_least(lo)),
                Some(timeline.first_at_least(hi)),
                vec![],
            ),
        );
    }

    #[tokio::test]
    async fn block_at_returns_the_block_before_a_between_timestamp() {
        let timeline = timeline();
        let probes = Cell::new(0);
        let mut search = search(timeline, &probes);
        // A timestamp strictly between block 1000 and 1001 resolves to 1000.
        let between = timeline.ts(1000) + 1;
        assert!(between < timeline.ts(1001));
        assert_eq!(search.block_at(between).await.unwrap(), 1000);
        // An exact block timestamp resolves to that same block.
        assert_eq!(search.block_at(timeline.ts(1000)).await.unwrap(), 1000);
    }

    #[tokio::test]
    async fn resolve_eq_set_maps_to_nearest_blocks_and_spans_them() {
        let timeline = timeline();
        let (a, b) = (timeline.ts(4_000_000), timeline.ts(2_000_000));
        let probes = Cell::new(0);
        let mut search = search(timeline, &probes);
        // Out of order, and a comparison wider than the set must not loosen it.
        let bounds = TimestampBounds {
            conds: vec![(CmpOp::Gte, timeline.ts(0))],
            eq_targets: vec![a, b],
        };
        let resolved = resolve_bounds(&mut search, &bounds).await.unwrap();
        assert_eq!(
            (resolved.from, resolved.to_excl, resolved.eq_blocks),
            (Some(2_000_000), Some(4_000_001), vec![2_000_000, 4_000_000]),
        );
    }
}
