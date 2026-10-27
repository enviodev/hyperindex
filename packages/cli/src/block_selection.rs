use std::collections::HashMap;
use std::ops::Range;

use anyhow::{ensure, Context, Result};
use napi_derive::napi;

#[napi(object)]
#[derive(Clone, Debug)]
pub struct OnBlockRegistrationInput {
    pub index: i64,
    /// Where the interval counts from: the handler's own start, or the
    /// chain's.
    pub start_block: i64,
    pub end_block: Option<i64>,
    pub interval: i64,
    /// The selected fields as the block store's bitmask, key included.
    pub block_field_mask: f64,
}

#[napi(object)]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BlockItem {
    pub block_number: i64,
    pub on_block_registration_index: i64,
    /// The chain produced no block at this number: an SVM skipped slot. The
    /// handler still runs on it, without a block.
    pub skipped: bool,
}

#[derive(Clone)]
struct Registration {
    index: i64,
    start_block: u64,
    /// Inclusive. Negative when the handler ends before it starts.
    end_block: Option<i64>,
    interval: u64,
    mask: u64,
}

impl Registration {
    fn ends_before(&self, block_number: u64) -> bool {
        self.end_block.is_some_and(|end| end < block_number as i64)
    }

    fn runs_on(&self, block_number: u64) -> bool {
        block_number >= self.start_block
            && !self.ends_before(block_number)
            && (block_number - self.start_block).is_multiple_of(self.interval)
    }

    /// The first block at or after `block_number` the handler runs on.
    fn first_from(&self, block_number: u64) -> Option<u64> {
        let from = block_number.max(self.start_block);
        let offset = (from - self.start_block) % self.interval;
        let first = if offset == 0 {
            from
        } else {
            from.checked_add(self.interval - offset)?
        };
        (!self.ends_before(first)).then_some(first)
    }
}

pub(crate) struct BlockRegistrations(HashMap<i64, Registration>);

impl BlockRegistrations {
    pub(crate) fn new(inputs: &[OnBlockRegistrationInput]) -> Result<Self> {
        let mut registrations = HashMap::new();
        for input in inputs {
            ensure!(
                input.start_block >= 0 && input.interval > 0,
                "block handler {} has start block {} and interval {}",
                input.index,
                input.start_block,
                input.interval,
            );
            registrations.insert(
                input.index,
                Registration {
                    index: input.index,
                    start_block: input.start_block as u64,
                    end_block: input.end_block,
                    interval: input.interval as u64,
                    mask: input.block_field_mask as u64,
                },
            );
        }
        Ok(BlockRegistrations(registrations))
    }

    /// The query's handlers that run on a block of `[from_block, to_block]`
    /// (`to_block` unbounded when absent): one ended or not yet started has
    /// nothing to fetch.
    pub(crate) fn select(
        &self,
        indexes: &[i64],
        from_block: u64,
        to_block: Option<u64>,
    ) -> Result<BlockSelection> {
        let mut registrations = Vec::new();
        for index in indexes {
            let registration = self.0.get(index).with_context(|| {
                format!("Unknown block handler index {index} in query selection")
            })?;
            if registration
                .first_from(from_block)
                .is_some_and(|first| to_block.is_none_or(|to| first <= to))
            {
                registrations.push(registration.clone());
            }
        }
        registrations.sort_unstable_by_key(|r| r.index);
        Ok(BlockSelection { registrations })
    }

    /// How a HyperSync query over `[from_block, to_block]` reads the block
    /// table. A query selecting no other table starts at the first block a
    /// handler runs on and, outside realtime, reads that block by itself when
    /// the next is over `SPARSE_GAP` blocks further. In realtime every block's
    /// hash is kept for reorg detection, so the whole range is read.
    pub(crate) fn plan(
        &self,
        indexes: &[i64],
        from_block: i64,
        to_block: Option<i64>,
        blocks_only: bool,
        realtime: bool,
        items_target: Option<i64>,
    ) -> Result<BlockQuery> {
        let from_block = u64::try_from(from_block).context("from_block must be >= 0")?;
        let to_block = to_block
            .map(|to| u64::try_from(to).context("to_block must be >= 0"))
            .transpose()?;
        let selection = self.select(indexes, from_block, to_block)?;
        let read = match to_block {
            Some(to_block) if blocks_only && !realtime => selection.read(from_block, to_block),
            _ => None,
        };
        let (from_block, to_block, claimed_to_block) = match read {
            Some((from, to, claimed)) => (from, Some(to), Some(claimed)),
            None => (from_block, to_block, None),
        };
        let max_blocks = items_target
            .filter(|_| blocks_only && !selection.is_empty() && to_block != Some(from_block))
            .and_then(|target| u64::try_from(target).ok())
            .map(|target| target.saturating_mul(selection.min_interval()));
        Ok(BlockQuery {
            selection,
            blocks_only,
            realtime,
            from_block,
            to_block,
            max_blocks,
            claimed_to_block,
        })
    }
}

/// Past this many blocks to the next one a handler runs on, a request for the
/// one block costs less than reading every block up to it.
const SPARSE_GAP: u64 = 1000;

pub(crate) struct BlockQuery {
    pub(crate) selection: BlockSelection,
    blocks_only: bool,
    realtime: bool,
    pub(crate) from_block: u64,
    /// Inclusive.
    pub(crate) to_block: Option<u64>,
    /// Caps a page reading every block for its handlers at the blocks its
    /// item target needs: the target counts handler runs, not blocks.
    pub(crate) max_blocks: Option<u64>,
    /// A query reading less than its range answers for the rest of it up to
    /// here, where no handler runs.
    claimed_to_block: Option<u64>,
}

impl BlockQuery {
    /// The end (exclusive) of a range a query for blocks alone has nothing to
    /// read in, which it answers for without a request: on SVM a query
    /// selecting nothing would return every instruction of the range. Not in
    /// realtime, where the page's hashes feed reorg detection.
    pub(crate) fn unread_until(&self) -> Option<u64> {
        if self.blocks_only && !self.realtime && self.selection.is_empty() {
            self.to_block?.checked_add(1)
        } else {
            None
        }
    }

    /// A block handler runs on blocks no log or instruction landed on, so a
    /// query selecting the block table asks for every block of its range.
    pub(crate) fn include_all_blocks(&self) -> bool {
        self.realtime || !self.selection.is_empty()
    }

    /// Where the fetched range ends (exclusive), for a page that read up to
    /// `next_block` (exclusive).
    pub(crate) fn fetched_until(&self, next_block: u64) -> u64 {
        match (self.to_block, self.claimed_to_block) {
            (Some(to_block), Some(claimed_to_block)) if next_block > to_block => {
                claimed_to_block + 1
            }
            _ => next_block,
        }
    }
}

/// The block handlers a query runs, all of which run on some block of its
/// range.
pub(crate) struct BlockSelection {
    registrations: Vec<Registration>,
}

impl BlockSelection {
    pub(crate) fn is_empty(&self) -> bool {
        self.registrations.is_empty()
    }

    /// Every block field some handler selected, as the block store's bitmask.
    pub(crate) fn mask(&self) -> u64 {
        self.registrations.iter().fold(0, |acc, r| acc | r.mask)
    }

    /// The highest block up to `to_block` keeping at most `max_blocks` blocks
    /// some handler runs on in `[from_block, ..]`: for a source paying a
    /// request per block, the end of a range it can afford.
    pub(crate) fn range_end(&self, from_block: u64, to_block: u64, max_blocks: usize) -> u64 {
        if self.is_empty() {
            return to_block;
        }
        let mut matched = 0;
        for block_number in from_block..=to_block {
            if self.runs_any(block_number) {
                matched += 1;
                if matched == max_blocks {
                    return block_number;
                }
            }
        }
        to_block
    }

    /// An item for every handler running on a block of `covered`, in block
    /// then registration order.
    pub(crate) fn route(&self, covered: Range<u64>) -> Vec<BlockItem> {
        if self.is_empty() {
            return Vec::new();
        }
        covered
            .flat_map(|block_number| {
                self.registrations
                    .iter()
                    .filter(move |r| r.runs_on(block_number))
                    .map(move |r| BlockItem {
                        block_number: block_number as i64,
                        on_block_registration_index: r.index,
                        skipped: false,
                    })
            })
            .collect()
    }

    /// The blocks a query for blocks alone reads of `[from_block, to_block]`,
    /// and how far it answers for: `None` when no handler runs in the range.
    fn read(&self, from_block: u64, to_block: u64) -> Option<(u64, u64, u64)> {
        let first = self.first_from(from_block).filter(|&b| b <= to_block)?;
        let next = first
            .checked_add(1)
            .and_then(|b| self.first_from(b))
            .filter(|&b| b <= to_block);
        Some(match next {
            Some(next) if next - first <= SPARSE_GAP => (first, to_block, to_block),
            _ => (first, first, next.map_or(to_block, |next| next - 1)),
        })
    }

    fn min_interval(&self) -> u64 {
        self.registrations
            .iter()
            .map(|r| r.interval)
            .min()
            .unwrap_or(1)
    }

    fn first_from(&self, block_number: u64) -> Option<u64> {
        self.registrations
            .iter()
            .filter_map(|r| r.first_from(block_number))
            .min()
    }

    fn runs_any(&self, block_number: u64) -> bool {
        self.registrations.iter().any(|r| r.runs_on(block_number))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(
        index: i64,
        start_block: i64,
        end_block: Option<i64>,
        interval: i64,
    ) -> OnBlockRegistrationInput {
        OnBlockRegistrationInput {
            index,
            start_block,
            end_block,
            interval,
            block_field_mask: 0b11 as f64,
        }
    }

    fn select(
        inputs: &[OnBlockRegistrationInput],
        from_block: u64,
        to_block: Option<u64>,
    ) -> BlockSelection {
        let indexes: Vec<i64> = inputs.iter().map(|i| i.index).collect();
        BlockRegistrations::new(inputs)
            .unwrap()
            .select(&indexes, from_block, to_block)
            .unwrap()
    }

    fn item(block_number: i64, on_block_registration_index: i64) -> BlockItem {
        BlockItem {
            block_number,
            on_block_registration_index,
            skipped: false,
        }
    }

    #[test]
    fn routes_each_block_to_the_handlers_running_on_it() {
        let selection = select(
            &[input(0, 10, None, 2), input(1, 0, Some(11), 1)],
            9,
            Some(12),
        );
        assert_eq!(
            selection.route(9..13),
            vec![
                item(9, 1),
                item(10, 0),
                item(10, 1),
                item(11, 1),
                item(12, 0)
            ]
        );
    }

    #[test]
    fn selects_only_the_handlers_running_in_the_range() {
        let inputs = [
            input(0, 0, Some(5), 1),
            input(1, 100, None, 1),
            input(2, 0, None, 1000),
            input(3, 0, None, 3),
            input(4, 0, Some(-1), 1),
        ];
        let selection = select(&inputs, 10, Some(20));
        assert_eq!(
            selection
                .registrations
                .iter()
                .map(|r| r.index)
                .collect::<Vec<_>>(),
            vec![3]
        );
    }

    #[test]
    fn ends_a_range_at_the_last_block_it_can_afford() {
        let selection = select(&[input(0, 0, None, 3)], 1, Some(100));
        assert_eq!(
            (selection.range_end(1, 100, 2), selection.range_end(1, 5, 2)),
            (6, 5)
        );
    }

    fn planned(
        inputs: &[OnBlockRegistrationInput],
        range: (i64, Option<i64>),
        blocks_only: bool,
        realtime: bool,
        items_target: Option<i64>,
    ) -> BlockQuery {
        let indexes: Vec<i64> = inputs.iter().map(|i| i.index).collect();
        BlockRegistrations::new(inputs)
            .unwrap()
            .plan(
                &indexes,
                range.0,
                range.1,
                blocks_only,
                realtime,
                items_target,
            )
            .unwrap()
    }

    fn read_of(query: &BlockQuery, next_block: u64) -> (u64, Option<u64>, Option<u64>, u64) {
        (
            query.from_block,
            query.to_block,
            query.max_blocks,
            query.fetched_until(next_block),
        )
    }

    #[test]
    fn reads_every_block_between_handler_blocks_a_short_gap_apart() {
        let query = planned(
            &[input(0, 10, None, 1000)],
            (0, Some(5000)),
            true,
            false,
            Some(3),
        );
        assert_eq!(read_of(&query, 5001), (10, Some(5000), Some(3000), 5001));
    }

    #[test]
    fn reads_a_handler_block_alone_when_the_next_is_far() {
        let sparse = [input(0, 10, None, 5000)];
        let first = planned(&sparse, (0, Some(20_000)), true, false, Some(3));
        let last = planned(&sparse, (15_000, Some(16_000)), true, false, None);
        assert_eq!(
            (
                read_of(&first, 11),
                first.fetched_until(10),
                read_of(&last, 15_011)
            ),
            (
                (10, Some(10), None, 5010),
                10,
                (15_010, Some(15_010), None, 16_001)
            )
        );
    }

    #[test]
    fn reads_the_whole_range_in_realtime_or_beside_other_tables() {
        let sparse = [input(0, 10, None, 5000)];
        assert_eq!(
            (
                read_of(
                    &planned(&sparse, (0, Some(20_000)), true, true, None),
                    20_001
                ),
                read_of(
                    &planned(&sparse, (0, Some(20_000)), false, false, Some(3)),
                    20_001
                ),
            ),
            (
                (0, Some(20_000), None, 20_001),
                (0, Some(20_000), None, 20_001)
            )
        );
    }

    #[test]
    fn reads_nothing_when_no_handler_runs_in_the_range() {
        let ended = [input(0, 10, Some(4000), 5000)];
        assert_eq!(
            (
                planned(&ended, (11, Some(5009)), true, false, Some(3)).unread_until(),
                planned(&ended, (11, None), true, false, Some(3)).unread_until(),
                planned(&ended, (11, Some(5009)), false, false, Some(3)).unread_until(),
                planned(&ended, (11, Some(5009)), true, true, Some(3)).unread_until(),
            ),
            (Some(5010), None, None, None)
        );
    }

    #[test]
    fn caps_blocks_by_the_densest_handler() {
        let query = planned(
            &[input(0, 0, None, 5), input(1, 0, None, 2)],
            (0, Some(100)),
            true,
            false,
            Some(3),
        );
        assert_eq!(query.max_blocks, Some(6));
    }

    #[test]
    fn rejects_an_interval_that_matches_nothing() {
        assert!(BlockRegistrations::new(&[input(0, 0, None, 0)]).is_err());
    }
}
