//! The blocks each block handler runs on, from its interval, start and end.

use anyhow::{ensure, Result};
use napi_derive::napi;

#[napi(object)]
#[derive(Clone, Debug)]
pub struct BlockHandlerInput {
    pub index: i64,
    /// Where the interval counts from: the handler's own start, or the
    /// chain's.
    pub start_block: i64,
    pub end_block: Option<i64>,
    pub interval: i64,
    /// The block fields the handler selects, as the blocks table's bitmask;
    /// absent when it reads none beyond the number.
    pub block_field_mask: Option<f64>,
}

#[derive(Clone, Debug)]
pub(crate) struct BlockHandler {
    pub(crate) index: u32,
    start_block: u64,
    /// Inclusive. Negative when the handler ends before it starts.
    end_block: Option<i64>,
    interval: u64,
    pub(crate) block_field_mask: Option<u64>,
}

impl BlockHandler {
    fn ends_before(&self, block_number: u64) -> bool {
        self.end_block.is_some_and(|end| end < block_number as i64)
    }

    pub(crate) fn runs_on(&self, block_number: u64) -> bool {
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

/// Every block handler of a chain, in registration order.
#[derive(Clone, Debug, Default)]
pub(crate) struct Schedule {
    handlers: Vec<BlockHandler>,
}

impl Schedule {
    pub(crate) fn new(inputs: &[BlockHandlerInput]) -> Result<Self> {
        let mut handlers = inputs
            .iter()
            .map(|input| {
                ensure!(
                    input.start_block >= 0 && input.interval > 0 && input.index >= 0,
                    "block handler {} has start block {} and interval {}",
                    input.index,
                    input.start_block,
                    input.interval,
                );
                Ok(BlockHandler {
                    index: input.index as u32,
                    start_block: input.start_block as u64,
                    end_block: input.end_block,
                    interval: input.interval as u64,
                    block_field_mask: input.block_field_mask.map(|mask| mask as u64),
                })
            })
            .collect::<Result<Vec<_>>>()?;
        handlers.sort_by_key(|handler| handler.index);
        Ok(Schedule { handlers })
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.handlers.is_empty()
    }

    /// The first block at or after `block_number` some handler runs on.
    pub(crate) fn first_from(&self, block_number: u64) -> Option<u64> {
        self.handlers
            .iter()
            .filter_map(|handler| handler.first_from(block_number))
            .min()
    }

    /// The handlers running on `block_number`, in registration order.
    pub(crate) fn handlers_on(&self, block_number: u64) -> impl Iterator<Item = &BlockHandler> {
        self.handlers
            .iter()
            .filter(move |handler| handler.runs_on(block_number))
    }

    pub(crate) fn handler(&self, index: u32) -> Option<&BlockHandler> {
        self.handlers.iter().find(|handler| handler.index == index)
    }

    /// How many runs of the handlers `counts` accepts land on blocks
    /// `[from_block, to_block]`.
    pub(crate) fn count_runs(
        &self,
        from_block: u64,
        to_block: u64,
        counts: impl Fn(u32) -> bool,
    ) -> u64 {
        if from_block > to_block {
            return 0;
        }
        self.handlers
            .iter()
            .filter(|handler| counts(handler.index))
            .map(|handler| match handler.first_from(from_block) {
                Some(first) if first <= to_block => {
                    let last = match handler.end_block {
                        Some(end) if end >= 0 => to_block.min(end as u64),
                        Some(_) => return 0,
                        None => to_block,
                    };
                    if first > last {
                        0
                    } else {
                        (last - first) / handler.interval + 1
                    }
                }
                _ => 0,
            })
            .sum()
    }

    /// The scheduled blocks of `[from_block, to_block]` the handlers selecting
    /// fields run on, ascending.
    pub(crate) fn fetched_blocks(&self, from_block: u64, to_block: u64) -> Vec<u64> {
        let mut blocks = Vec::new();
        let mut block = from_block;
        while block <= to_block {
            let Some(next) = self
                .handlers
                .iter()
                .filter(|handler| handler.block_field_mask.is_some())
                .filter_map(|handler| handler.first_from(block))
                .min()
                .filter(|next| *next <= to_block)
            else {
                break;
            };
            blocks.push(next);
            block = next + 1;
        }
        blocks
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn handler(
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
            block_field_mask: None,
        }
    }

    #[test]
    fn walks_runs_and_counts_them() {
        let schedule =
            Schedule::new(&[handler(1, 10, Some(40), 10), handler(0, 0, None, 7)]).unwrap();
        let on = |block| {
            schedule
                .handlers_on(block)
                .map(|handler| handler.index)
                .collect::<Vec<_>>()
        };
        assert_eq!(
            (
                schedule.first_from(15),
                on(70),
                on(20),
                schedule.count_runs(0, 50, |_| true),
                schedule.count_runs(41, 41, |_| true),
                schedule.count_runs(0, 50, |index| index == 1),
            ),
            (Some(20), vec![0], vec![1], 8 + 4, 0, 4)
        );
    }
}
