use super::chain::ChainPlan;
use super::pipeline::{Planned, Tick};

/// How far past the frontier a chain with no density targets while it takes
/// its first measurements.
const COLD_TARGET_RANGE: i64 = 20_000;

/// How far past the alignment anchor's progress a follower may fetch, as a
/// fraction of its own range. Chains tracking the anchor closely would
/// otherwise flap in and out of the clamp on every small move, and it is the
/// headroom a follower keeps buffered while the anchor is mid-fetch.
const ALIGNMENT_MARGIN: f64 = 0.2;

/// What the loop knows of a chain that the plan doesn't: where processing has
/// read to, and the items per block batches have measured.
pub(crate) struct ChainInput {
    pub processing_block: i64,
    pub processed_density: Option<f64>,
}

struct ChainReading {
    ready_through: i64,
    ready_count: u32,
    reserved: f64,
    density: Option<f64>,
    frontier_progress: f64,
}

impl ChainPlan {
    pub fn ready_count(&self, processing_block: i64) -> u32 {
        self.buffer
            .count_items_in_block_range(processing_block + 1, self.ready_through_block())
    }

    pub(super) fn reserved(&self) -> f64 {
        self.requests
            .in_flight()
            .map(|request| f64::from(request.items_estimate))
            .sum()
    }

    /// The last block the chain can fetch right now: the lagged head, or the
    /// end block below it.
    fn fetch_ceiling(&self) -> i64 {
        let head = (self.known_height - self.block_lag).max(0);
        self.end_block.map_or(head, |end_block| end_block.min(head))
    }

    /// Mapped from the static start block: anchored at a first event instead,
    /// two chains at the same block would read different fractions.
    fn progress_at(&self, block: i64) -> f64 {
        let (lower, upper) = (self.config.start_block, self.fetch_ceiling());
        if upper <= lower {
            1.
        } else {
            ((block - lower) as f64 / (upper - lower) as f64).clamp(0., 1.)
        }
    }

    fn block_at_progress(&self, progress: f64) -> i64 {
        let (lower, upper) = (self.config.start_block, self.fetch_ceiling());
        lower + (progress * (upper - lower) as f64).ceil() as i64
    }

    pub fn is_fetching_at_head(&self) -> bool {
        let ready_through = self.ready_through_block();
        self.known_height != 0
            && match self.end_block {
                Some(end_block) if ready_through >= end_block => true,
                _ => ready_through >= self.head_fetch_target(),
            }
    }

    fn reading(&self, input: &ChainInput) -> ChainReading {
        let ready_through = self.ready_through_block();
        let ready_count = self.ready_count(input.processing_block);
        let span = ready_through - input.processing_block;
        // The ready buffer reacts to what fetching just found, before batches
        // move the processed density, so the higher of the two sizes requests.
        let ready_density =
            (ready_count > 0 && span > 0).then(|| f64::from(ready_count) / span as f64);
        let density = match (input.processed_density, ready_density) {
            (Some(processed), Some(ready)) => Some(processed.max(ready)),
            (processed, None) => processed,
            (None, ready) => ready,
        };
        ChainReading {
            ready_through,
            ready_count,
            reserved: self.reserved(),
            density,
            frontier_progress: self.progress_at(ready_through),
        }
    }

    /// The chain's share of the budget as a soft target block. Decided by
    /// comparison, so no unbounded quotient is turned into a block number: at
    /// low densities it would overflow and wrap below the frontier.
    fn target_block(&self, reading: &ChainReading, target_items: f64) -> i64 {
        let ceiling = self.fetch_ceiling();
        match reading.density {
            Some(density) if density > 0. => {
                if density * (ceiling - reading.ready_through) as f64 <= target_items {
                    ceiling
                } else {
                    reading.ready_through + (target_items / density).ceil() as i64
                }
            }
            _ => (reading.ready_through + COLD_TARGET_RANGE).min(ceiling),
        }
    }
}

/// One pool of about `target_buffer_size` ready items for every chain, handed
/// out as a waterfall: the furthest behind chain first gets what remains plus
/// its own reservations, turns it into requests, and passes on the rest. New
/// work needs a tenth of the pool free. A chain with no density probes blind,
/// so it gets one such tenth. Until the indexer is realtime, no chain runs
/// past the furthest behind one's progress by more than the margin.
pub(crate) fn take_requests(
    chains: &mut [&mut ChainPlan],
    inputs: &[ChainInput],
    target_buffer_size: f64,
    is_realtime: bool,
) -> Vec<Planned> {
    let readings: Vec<ChainReading> = chains
        .iter()
        .zip(inputs)
        .map(|(chain, input)| chain.reading(input))
        .collect();
    let total_ready: f64 = readings.iter().map(|r| f64::from(r.ready_count)).sum();
    let total_reserved: f64 = readings.iter().map(|r| r.reserved).sum();
    let mut remaining = (target_buffer_size - total_ready - total_reserved).max(0.);
    let minimum_admission = target_buffer_size * 0.1;

    let mut order: Vec<usize> = (0..chains.len()).collect();
    order.sort_by(|&a, &b| {
        readings[a]
            .frontier_progress
            .total_cmp(&readings[b].frontier_progress)
    });
    let anchor = if is_realtime {
        None
    } else {
        order
            .iter()
            .copied()
            .find(|&index| chains[index].known_height != 0)
            .map(|index| (index, readings[index].frontier_progress))
    };

    let mut planned: Vec<Planned> = (0..chains.len()).map(|_| Planned::NothingToDo).collect();
    for index in order {
        let chain = &mut chains[index];
        let reading = &readings[index];
        if chain.known_height == 0 {
            // Nothing to size against yet, only a height to wait for, even
            // while other chains hold the whole pool.
            planned[index] = Planned::WaitForNewBlock;
            continue;
        }
        if remaining < minimum_admission {
            // A saturated pool means ready items or reservations somewhere, so
            // a batch or a response will tick again.
            continue;
        }
        let target_items = match reading.density {
            None => remaining.min(minimum_admission),
            Some(_) => remaining,
        } + reading.reserved;
        let mut target_block = chain.target_block(reading, target_items);
        if let Some((anchor, progress)) = anchor {
            if anchor != index {
                target_block =
                    target_block.min(chain.block_at_progress(progress + ALIGNMENT_MARGIN));
            }
        }
        // A clamped target can't use the whole share: the rest flows on to
        // the next chain this tick instead of sitting in an oversized probe.
        let target_items = match reading.density {
            Some(density) if density > 0. => target_items.min(
                (density * (target_block - reading.ready_through) as f64).ceil() + reading.reserved,
            ),
            _ => target_items,
        };
        let result = chain.plan_requests(&Tick {
            target_block,
            target_items,
            chain_density: reading.density,
            processing_block: inputs[index].processing_block,
        });
        planned[index] = match result {
            Planned::NothingToDo => {
                // Below its head with its share gone elsewhere or clamped to
                // nothing, a chain must keep polling for blocks: nothing else
                // would revisit it.
                if chain.is_fetching_at_head() || reading.reserved > 0. || reading.ready_count > 0 {
                    Planned::NothingToDo
                } else {
                    Planned::WaitForNewBlock
                }
            }
            Planned::Start(started) => {
                let consumed: f64 = started
                    .iter()
                    .filter_map(|&(slot, _)| chain.requests.slots[slot as usize].as_ref())
                    .map(|request| f64::from(request.items_estimate))
                    .sum();
                remaining = (remaining - consumed).max(0.);
                Planned::Start(started)
            }
            wait => wait,
        };
    }
    planned
}
