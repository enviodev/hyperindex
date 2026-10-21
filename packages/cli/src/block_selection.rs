//! The block table as a query selects it: the block handlers that read fields
//! beyond the block's key, each running on every `interval`-th block of its
//! range. Every source routes the blocks it fetched to them the way it routes
//! logs to event registrations, so which handler runs on which block is decided
//! here once.

use std::collections::HashMap;
use std::ops::Range;

use anyhow::{ensure, Context, Result};
use napi_derive::napi;

/// A block handler selecting fields, as a client is built with it.
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

/// A block handler run on one block of the response.
#[napi(object)]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BlockItem {
    pub block_number: i64,
    pub on_block_registration_index: i64,
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

/// The chain's block handlers that select fields, by index.
#[derive(Default)]
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
        Ok(BlockSelection {
            registrations,
            from_block,
        })
    }
}

/// The block handlers a query runs, all of which run on some block of its
/// range.
#[derive(Default)]
pub(crate) struct BlockSelection {
    registrations: Vec<Registration>,
    from_block: u64,
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
    pub(crate) fn range_end(&self, to_block: u64, max_blocks: usize) -> u64 {
        let mut matched = 0;
        for block_number in self.from_block..=to_block {
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
    /// then registration order. A block some handler runs on that `is_present`
    /// says the response lacks is returned as the error.
    pub(crate) fn route(
        &self,
        covered: Range<u64>,
        is_present: impl Fn(u64) -> bool,
    ) -> std::result::Result<Vec<BlockItem>, u64> {
        let mut items = Vec::new();
        if self.is_empty() {
            return Ok(items);
        }
        for block_number in covered {
            let mut running = self
                .registrations
                .iter()
                .filter(|r| r.runs_on(block_number))
                .peekable();
            if running.peek().is_none() {
                continue;
            }
            if !is_present(block_number) {
                return Err(block_number);
            }
            items.extend(running.map(|r| BlockItem {
                block_number: block_number as i64,
                on_block_registration_index: r.index,
            }));
        }
        Ok(items)
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
            selection.route(9..13, |_| true),
            Ok(vec![
                item(9, 1),
                item(10, 0),
                item(10, 1),
                item(11, 1),
                item(12, 0)
            ])
        );
    }

    #[test]
    fn reports_a_missing_block_a_handler_runs_on() {
        let selection = select(&[input(0, 0, None, 2)], 0, Some(4));
        assert_eq!(selection.route(0..5, |n| n != 2 && n != 3), Err(2));
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
            (selection.range_end(100, 2), selection.range_end(5, 2)),
            (6, 5)
        );
    }

    #[test]
    fn rejects_an_interval_that_matches_nothing() {
        assert!(BlockRegistrations::new(&[input(0, 0, None, 0)]).is_err());
    }
}
