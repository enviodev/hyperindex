//! The block table as a query selects it: the block handlers that read fields
//! beyond the block's key, each running on every `interval`-th block of its
//! range. Every source routes the blocks it fetched to them the way it routes
//! logs to event registrations, so which handler runs on which block is decided
//! here once.

use anyhow::{ensure, Result};
use napi_derive::napi;

/// A block handler selecting fields, as a query carries it.
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

struct Registration {
    index: i64,
    start_block: u64,
    end_block: Option<u64>,
    interval: u64,
}

impl Registration {
    fn runs_on(&self, block_number: u64) -> bool {
        block_number >= self.start_block
            && self.end_block.is_none_or(|end| block_number <= end)
            && (block_number - self.start_block) % self.interval == 0
    }
}

#[derive(Default)]
pub(crate) struct BlockSelection {
    registrations: Vec<Registration>,
    mask: u64,
}

impl BlockSelection {
    pub(crate) fn new(inputs: &[OnBlockRegistrationInput]) -> Result<Self> {
        let mut selection = BlockSelection::default();
        for input in inputs {
            ensure!(
                input.start_block >= 0 && input.interval > 0,
                "block handler {} has start block {} and interval {}",
                input.index,
                input.start_block,
                input.interval,
            );
            selection.mask |= input.block_field_mask as u64;
            selection.registrations.push(Registration {
                index: input.index,
                start_block: input.start_block as u64,
                end_block: input.end_block.map(|end| end.max(0) as u64),
                interval: input.interval as u64,
            });
        }
        Ok(selection)
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.registrations.is_empty()
    }

    /// Every block field some handler selected, as the block store's bitmask.
    pub(crate) fn mask(&self) -> u64 {
        self.mask
    }

    /// Push an item for every handler running on `block_number`, in
    /// registration order. Returns whether any does.
    pub(crate) fn route(&self, block_number: u64, items: &mut Vec<BlockItem>) -> bool {
        let before = items.len();
        items.extend(
            self.registrations
                .iter()
                .filter(|registration| registration.runs_on(block_number))
                .map(|registration| BlockItem {
                    block_number: block_number as i64,
                    on_block_registration_index: registration.index,
                }),
        );
        items.len() > before
    }

    /// The highest block up to `to_block` keeping at most `max_blocks` blocks
    /// some handler runs on in `[from_block, ..]`: for a source paying a
    /// request per block, the end of a range it can afford.
    pub(crate) fn range_end(&self, from_block: u64, to_block: u64, max_blocks: usize) -> u64 {
        let mut matched = 0;
        for block_number in from_block..=to_block {
            if self.registrations.iter().any(|r| r.runs_on(block_number)) {
                matched += 1;
                if matched == max_blocks {
                    return block_number;
                }
            }
        }
        to_block
    }

    /// The blocks in `[from_block, to_block]` some handler runs on, ascending.
    pub(crate) fn block_numbers(&self, from_block: u64, to_block: u64) -> Vec<u64> {
        (from_block..=to_block)
            .filter(|&block_number| self.registrations.iter().any(|r| r.runs_on(block_number)))
            .collect()
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

    #[test]
    fn routes_each_block_to_the_handlers_running_on_it() {
        let selection =
            BlockSelection::new(&[input(0, 10, None, 2), input(1, 0, Some(11), 1)]).unwrap();
        let mut items = Vec::new();
        for block_number in 9..=12 {
            selection.route(block_number, &mut items);
        }
        let item = |block_number, on_block_registration_index| BlockItem {
            block_number,
            on_block_registration_index,
        };
        assert_eq!(
            items,
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
    fn lists_the_blocks_any_handler_runs_on() {
        let selection =
            BlockSelection::new(&[input(0, 0, None, 5), input(1, 3, Some(7), 4)]).unwrap();
        assert_eq!(selection.block_numbers(1, 12), vec![3, 5, 7, 10]);
    }

    #[test]
    fn ends_a_range_at_the_last_block_it_can_afford() {
        let selection = BlockSelection::new(&[input(0, 0, None, 3)]).unwrap();
        assert_eq!(
            (selection.range_end(1, 100, 2), selection.range_end(1, 5, 2),),
            (6, 5)
        );
    }

    #[test]
    fn rejects_an_interval_that_matches_nothing() {
        assert!(BlockSelection::new(&[input(0, 0, None, 0)]).is_err());
    }
}
