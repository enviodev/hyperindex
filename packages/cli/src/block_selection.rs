use std::ops::Range;

use anyhow::{Context, Result};

use crate::chain_buffer::schedule::{BlockHandler, Schedule};

impl Schedule {
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
            let registration = u32::try_from(*index)
                .ok()
                .and_then(|index| self.handler(index))
                .with_context(|| {
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
    /// handler runs on that `holds` says the buffer lacks the selected fields
    /// of, and reads that block by itself when the next such block is over
    /// `SPARSE_GAP` blocks further, leaving the gap unread. A range reaching
    /// `reorgable_from` is read whole instead: each page there must link to
    /// the one before it for reorg detection, which an unread gap breaks.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn plan(
        &self,
        indexes: &[i64],
        from_block: i64,
        to_block: Option<i64>,
        blocks_only: bool,
        reorgable_from: Option<i64>,
        holds: impl Fn(u64, u64) -> bool,
    ) -> Result<BlockQuery> {
        let read_every_block =
            reorgable_from.is_some_and(|from| to_block.is_none_or(|to| to >= from));
        let from_block = u64::try_from(from_block).context("from_block must be >= 0")?;
        let to_block = to_block
            .map(|to| u64::try_from(to).context("to_block must be >= 0"))
            .transpose()?;
        let selection = self.select(indexes, from_block, to_block)?;
        let reads_some_blocks = blocks_only && !read_every_block && to_block.is_some();
        let read = match to_block {
            Some(to_block) if reads_some_blocks => {
                let mask = selection.mask();
                selection.read(from_block, to_block, |block| holds(block, mask))
            }
            _ => None,
        };
        let reads_nothing = reads_some_blocks && read.is_none();
        let (from_block, to_block, claimed_to_block) = match read {
            Some((from, to, claimed)) => (from, Some(to), Some(claimed)),
            None => (from_block, to_block, None),
        };
        let (to_block, claimed_to_block) = if blocks_only
            && !reads_nothing
            && !selection.is_empty()
            && to_block != Some(from_block)
        {
            let page_end = selection.page_end(from_block);
            let to_block = to_block.map_or(page_end, |to| to.min(page_end));
            (
                Some(to_block),
                claimed_to_block.map(|claimed| claimed.min(to_block)),
            )
        } else {
            (to_block, claimed_to_block)
        };
        Ok(BlockQuery {
            selection,
            reads_nothing,
            read_every_block,
            from_block,
            to_block,
            claimed_to_block,
        })
    }
}

/// Past this many blocks to the next one a handler runs on, a request for the
/// one block costs less than reading every block up to it.
const SPARSE_GAP: u64 = 1000;

/// Handler runs a read of every block covers at most. The blocks they run on
/// are known exactly, so the range ends the read where a block count sent to
/// the server would only be checked between its batches and overshot.
const PAGE_RUNS: u64 = 5000;

pub(crate) struct BlockQuery {
    pub(crate) selection: BlockSelection,
    /// A query for blocks alone whose range holds no block it needs to read.
    reads_nothing: bool,
    read_every_block: bool,
    pub(crate) from_block: u64,
    /// Inclusive.
    pub(crate) to_block: Option<u64>,
    /// A query reading less than its range answers for the rest of it up to
    /// here, where no handler runs.
    claimed_to_block: Option<u64>,
}

impl BlockQuery {
    /// The end (exclusive) of a range a query for blocks alone has nothing to
    /// read in, which it answers for without a request: no handler runs there,
    /// or the buffer holds every block one runs on. On SVM a query selecting
    /// nothing would return every instruction of the range. Not where the
    /// range can still be reorged, whose hashes feed reorg detection.
    pub(crate) fn unread_until(&self) -> Option<u64> {
        if self.reads_nothing {
            self.to_block?.checked_add(1)
        } else {
            None
        }
    }

    /// A block handler runs on blocks no log or instruction landed on, so a
    /// query selecting the block table asks for every block of its range, as
    /// does one reaching blocks that can still be reorged: its hashes feed
    /// reorg detection, and its last block's time is the progress block's.
    pub(crate) fn include_all_blocks(&self) -> bool {
        self.read_every_block || !self.selection.is_empty()
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
    registrations: Vec<BlockHandler>,
}

impl BlockSelection {
    pub(crate) fn is_empty(&self) -> bool {
        self.registrations.is_empty()
    }

    /// Every block field some handler selected, as the blocks table's bitmask.
    pub(crate) fn mask(&self) -> u64 {
        self.registrations
            .iter()
            .fold(0, |acc, r| acc | r.block_field_mask.unwrap_or(0))
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

    /// The blocks of `covered` some handler runs on, ascending.
    pub(crate) fn blocks_run_on(&self, covered: Range<u64>) -> Vec<u64> {
        if self.is_empty() {
            return Vec::new();
        }
        covered.filter(|block| self.runs_any(*block)).collect()
    }

    /// The blocks a query for blocks alone reads of `[from_block, to_block]`,
    /// and how far it answers for: `None` when no handler runs on a block of
    /// the range that `holds` says the buffer lacks.
    fn read(
        &self,
        from_block: u64,
        to_block: u64,
        holds: impl Fn(u64) -> bool,
    ) -> Option<(u64, u64, u64)> {
        let first_lacking_from = |from: u64| {
            let mut block = from;
            loop {
                let next = self.first_from(block).filter(|&b| b <= to_block)?;
                if !holds(next) {
                    return Some(next);
                }
                block = next.checked_add(1)?;
            }
        };
        let first = first_lacking_from(from_block)?;
        let next = first.checked_add(1).and_then(first_lacking_from);
        Some(match next {
            Some(next) if next - first <= SPARSE_GAP => (first, to_block, to_block),
            _ => (first, first, next.map_or(to_block, |next| next - 1)),
        })
    }

    /// The last block of a page from `from_block` holding `PAGE_RUNS` handler
    /// runs: each handler runs once every `interval` blocks, so together they
    /// run `Σ 1/interval` times a block. A handler can run rarely enough for
    /// the page to span past the last block a u64 holds.
    fn page_end(&self, from_block: u64) -> u64 {
        let runs_per_block: f64 = self
            .registrations
            .iter()
            .map(|r| 1.0 / r.interval as f64)
            .sum();
        let blocks = ((PAGE_RUNS as f64 / runs_per_block) as u64).max(1);
        from_block.saturating_add(blocks - 1)
    }

    pub(crate) fn first_from(&self, block_number: u64) -> Option<u64> {
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
    use crate::chain_buffer::schedule::BlockHandlerInput;

    fn input(
        index: i64,
        start_block: i64,
        end_block: Option<i64>,
        interval: i64,
    ) -> BlockHandlerInput {
        BlockHandlerInput {
            index,
            start_block,
            end_block,
            interval,
            block_field_mask: Some(0b11 as f64),
        }
    }

    fn select(
        inputs: &[BlockHandlerInput],
        from_block: u64,
        to_block: Option<u64>,
    ) -> BlockSelection {
        let indexes: Vec<i64> = inputs.iter().map(|i| i.index).collect();
        Schedule::new(inputs)
            .unwrap()
            .select(&indexes, from_block, to_block)
            .unwrap()
    }

    #[test]
    fn lists_the_blocks_some_handler_runs_on() {
        let selection = select(
            &[input(0, 10, None, 2), input(1, 0, Some(10), 1)],
            9,
            Some(13),
        );
        assert_eq!(selection.blocks_run_on(9..14), vec![9, 10, 12]);
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
        inputs: &[BlockHandlerInput],
        range: (i64, Option<i64>),
        blocks_only: bool,
        reorgable_from: Option<i64>,
    ) -> BlockQuery {
        planned_holding(inputs, range, blocks_only, reorgable_from, &[])
    }

    /// Planned beside a buffer holding `held` with every field selected.
    fn planned_holding(
        inputs: &[BlockHandlerInput],
        range: (i64, Option<i64>),
        blocks_only: bool,
        reorgable_from: Option<i64>,
        held: &[u64],
    ) -> BlockQuery {
        let indexes: Vec<i64> = inputs.iter().map(|i| i.index).collect();
        Schedule::new(inputs)
            .unwrap()
            .plan(
                &indexes,
                range.0,
                range.1,
                blocks_only,
                reorgable_from,
                |block, _mask| held.contains(&block),
            )
            .unwrap()
    }

    fn read_of(query: &BlockQuery, next_block: u64) -> (u64, Option<u64>, u64) {
        (
            query.from_block,
            query.to_block,
            query.fetched_until(next_block),
        )
    }

    #[test]
    fn reads_every_block_between_handler_blocks_a_short_gap_apart() {
        let query = planned(&[input(0, 10, None, 1000)], (0, Some(5000)), true, None);
        assert_eq!(read_of(&query, 5001), (10, Some(5000), 5001));
    }

    #[test]
    fn reads_a_handler_block_alone_when_the_next_is_far() {
        let sparse = [input(0, 10, None, 5000)];
        let first = planned(&sparse, (0, Some(20_000)), true, None);
        let last = planned(&sparse, (15_000, Some(16_000)), true, None);
        assert_eq!(
            (
                read_of(&first, 11),
                first.fetched_until(10),
                read_of(&last, 15_011)
            ),
            ((10, Some(10), 5010), 10, (15_010, Some(15_010), 16_001))
        );
    }

    #[test]
    fn reads_the_whole_range_where_it_can_be_reorged_or_beside_other_tables() {
        let sparse = [input(0, 10, None, 5000)];
        assert_eq!(
            (
                read_of(
                    &planned(&sparse, (0, Some(20_000)), true, Some(19_800)),
                    20_001
                ),
                read_of(&planned(&sparse, (0, None), true, Some(19_800)), 20_001),
                read_of(&planned(&sparse, (0, Some(20_000)), false, None), 20_001),
                // Every block of the range is final, so the gap may stay unread.
                read_of(&planned(&sparse, (0, Some(20_000)), true, Some(20_001)), 11),
            ),
            (
                (0, Some(20_000), 20_001),
                (0, Some(24_999_999), 20_001),
                (0, Some(20_000), 20_001),
                (10, Some(10), 5010)
            )
        );
    }

    #[test]
    fn reads_nothing_when_no_handler_runs_in_the_range() {
        let ended = [input(0, 10, Some(4000), 5000)];
        assert_eq!(
            (
                planned(&ended, (11, Some(5009)), true, None).unread_until(),
                planned(&ended, (11, None), true, None).unread_until(),
                planned(&ended, (11, Some(5009)), false, None).unread_until(),
                planned(&ended, (11, Some(5009)), true, Some(4800)).unread_until(),
            ),
            (Some(5010), None, None, None)
        );
    }

    #[test]
    fn reads_only_the_handler_blocks_the_buffer_lacks() {
        let sparse = [input(0, 10, None, 5000)];
        let dense = [input(0, 0, None, 1)];
        assert_eq!(
            (
                read_of(
                    &planned_holding(&sparse, (0, Some(20_000)), true, None, &[10]),
                    5011
                ),
                planned_holding(&sparse, (0, Some(12_000)), true, None, &[10, 5010, 10_010])
                    .unread_until(),
                read_of(
                    &planned_holding(&dense, (0, Some(100)), true, None, &[0, 1, 2]),
                    101
                ),
                // Where the range can be reorged every block is read.
                read_of(
                    &planned_holding(&sparse, (0, Some(20_000)), true, Some(0), &[10]),
                    20_001
                ),
            ),
            (
                (5010, Some(5010), 10_010),
                Some(12_001),
                (3, Some(100), 101),
                (0, Some(20_000), 20_001),
            )
        );
    }

    // A range the buffer already holds is answered without a request, all of
    // it: the page bound is for what a request reads.
    #[test]
    fn answers_a_held_range_whole_past_a_page_of_handler_runs() {
        let dense = [input(0, 0, None, 1)];
        let held: Vec<u64> = (0..=20_000).collect();
        assert_eq!(
            planned_holding(&dense, (0, Some(20_000)), true, None, &held).unread_until(),
            Some(20_001)
        );
    }

    #[test]
    fn ends_a_read_of_every_block_after_a_page_of_handler_runs() {
        let to_block = |inputs: &[BlockHandlerInput], range, reorgable_from| {
            planned(inputs, range, true, reorgable_from).to_block
        };
        // Every 5 and every 2 blocks run 0.7 times a block, so 7,142 blocks
        // hold a page's 5,000 runs; one handler every 1000 needs 5,000,000.
        assert_eq!(
            (
                to_block(
                    &[input(0, 0, None, 5), input(1, 0, None, 2)],
                    (0, Some(100_000)),
                    None
                ),
                to_block(&[input(0, 0, None, 1000)], (0, Some(100_000)), None),
                to_block(&[input(0, 0, None, 2)], (0, None), Some(50)),
            ),
            (Some(7141), Some(100_000), Some(9999))
        );
    }

    // A page spanning past the last block a u64 holds still ends at the range.
    #[test]
    fn ends_a_read_at_its_range_when_a_page_spans_past_the_last_block() {
        let rare = [input(0, 100, None, 4_000_000_000_000_000)];
        assert_eq!(
            planned(&rare, (100, Some(200)), true, Some(150)).to_block,
            Some(200)
        );
    }

    // A read cut short at its page claims no further than it read.
    #[test]
    fn claims_no_further_than_a_page_of_handler_runs() {
        let query = planned(&[input(0, 0, None, 2)], (0, Some(100_000)), true, None);
        assert_eq!(read_of(&query, 10_000), (0, Some(9999), 10_000));
    }

    #[test]
    fn rejects_an_interval_that_matches_nothing() {
        assert!(Schedule::new(&[input(0, 0, None, 0)]).is_err());
    }
}
