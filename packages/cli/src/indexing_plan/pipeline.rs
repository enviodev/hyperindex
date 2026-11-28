use super::chain::{ChainPlan, Learned, Request};

/// Most requests a stream may have out at once. A slow request at the front
/// can't starve the stream: only requests still out count.
pub(crate) const MAX_IN_FLIGHT_PER_STREAM: usize = 12;

/// Most requests a chain may have out at once, across its streams.
pub(crate) const MAX_IN_FLIGHT_PER_CHAIN: usize = 100;

/// The items one response can bring back, which a probe reserves on a chain
/// with no density yet.
pub(crate) const PAGE_ITEMS: i64 = 5000;

/// Chunks span this much more than the smallest recent source range, so the
/// pipeline keeps probing for more capacity instead of locking in the first
/// measurement.
const CHUNK_RANGE_GROWTH: f64 = 1.8;

pub(crate) struct Tick {
    /// The soft horizon the chain's share of the budget reaches: it picks the
    /// streams in range and sizes an open-ended request, and is never a hard
    /// end.
    pub target_block: i64,
    pub target_items: f64,
    pub chain_density: Option<f64>,
    pub processing_block: i64,
}

pub(crate) enum Planned {
    WaitForNewBlock,
    NothingToDo,
    /// The requests started, as (slot, generation).
    Start(Vec<(u32, u32)>),
}

struct Stream {
    needs: Vec<u32>,
    head: bool,
    covered: i64,
    in_flight: usize,
    has_ahead: bool,
    query_end: Option<i64>,
    density: Option<f64>,
    chunk_range: Option<i64>,
}

struct Candidate {
    stream: usize,
    from_block: i64,
    to_block: Option<i64>,
    items: i64,
    chunk: bool,
}

struct FillState {
    stream: usize,
    cursor: i64,
    chunks_used: usize,
}

fn density_items_estimate(
    density: f64,
    from_block: i64,
    to_block: Option<i64>,
    target_block: i64,
) -> i64 {
    (((to_block.unwrap_or(target_block) - from_block + 1) as f64 * density).ceil() as i64).max(1)
}

fn min_option(a: Option<i64>, b: Option<i64>) -> Option<i64> {
    match (a, b) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (a, None) => a,
        (None, b) => b,
    }
}

fn learned_of<'a>(plan: &'a ChainPlan, needs: &[u32], head: bool) -> &'a Learned {
    if head {
        &plan.head_learned
    } else {
        &plan.needs.learned[needs[0] as usize]
    }
}

/// Candidates for a hole left between covered and requested ranges, which
/// sort ahead of forward work by their low start. Chunks only on a positive
/// density; without one, the stream's even share of the budget spread over
/// its range prices a single request, so a hole that may be dense is never
/// priced at nothing.
#[allow(clippy::too_many_arguments)]
fn push_gap(
    candidates: &mut Vec<Candidate>,
    stream: &Stream,
    stream_index: usize,
    range_from: i64,
    range_end: Option<i64>,
    head_block: i64,
    target_block: i64,
    max_chunks: usize,
    stream_budget: f64,
) {
    if range_from > head_block.min(target_block) || max_chunks == 0 {
        return;
    }
    if range_end.is_some_and(|end| range_from > end) {
        return;
    }
    let max_block = range_end.unwrap_or(target_block);
    let single = |candidates: &mut Vec<Candidate>, density: f64, chunk: bool| {
        candidates.push(Candidate {
            stream: stream_index,
            from_block: range_from,
            to_block: range_end,
            items: density_items_estimate(density, range_from, range_end, target_block),
            chunk,
        })
    };
    match (stream.density, stream.chunk_range) {
        (Some(density), Some(chunk_range)) if density > 0. => {
            let chunk_size = (chunk_range as f64 * CHUNK_RANGE_GROWTH).ceil() as i64;
            if range_from + chunk_size * 2 - 1 <= max_block {
                let mut from_block = range_from;
                let mut created = 0;
                while created < max_chunks && from_block + chunk_size - 1 <= max_block {
                    let to_block = from_block + chunk_size - 1;
                    candidates.push(Candidate {
                        stream: stream_index,
                        from_block,
                        to_block: Some(to_block),
                        items: density_items_estimate(
                            density,
                            from_block,
                            Some(to_block),
                            target_block,
                        ),
                        chunk: true,
                    });
                    from_block = to_block + 1;
                    created += 1;
                }
            } else {
                single(candidates, density, range_end.is_some());
            }
        }
        (Some(density), None) if density > 0. => single(candidates, density, false),
        _ => {
            let remaining = (target_block - range_from + 1).max(1);
            single(candidates, stream_budget / remaining as f64, false);
        }
    }
}

impl ChainPlan {
    fn stream_states(&self) -> Vec<Stream> {
        let head_block = self.known_height - self.block_lag;
        let mut streams: Vec<Stream> = self
            .streams()
            .into_iter()
            .map(|(needs, head)| {
                let in_flight = self
                    .requests
                    .in_flight()
                    .filter(|request| request.needs.iter().any(|need| needs.contains(need)))
                    .count();
                let covered = needs
                    .iter()
                    .map(|&need| self.needs.coverage[need as usize].covered_through)
                    .min()
                    .unwrap_or(i64::MAX);
                let has_ahead = needs
                    .iter()
                    .any(|&need| !self.needs.coverage[need as usize].ahead.is_empty());
                let mut query_end = self.end_block;
                if !head {
                    query_end = min_option(query_end, self.needs.to_block[needs[0] as usize]);
                }
                if self.block_lag != 0 {
                    // Bounded by the lagged head, or HyperSync may return past it.
                    query_end = min_option(Some(head_block), query_end);
                }
                let learned = learned_of(self, &needs, head);
                Stream {
                    density: learned.density,
                    chunk_range: learned.capacity_of(self.last_source).chunk_range(),
                    needs,
                    head,
                    covered,
                    in_flight,
                    has_ahead,
                    query_end,
                }
            })
            .collect();
        streams.sort_by_key(|stream| (stream.covered, stream.needs[0]));
        streams
    }

    /// Every candidate request of the tick, holes and each stream's chunks or
    /// probe toward the target, is generated with no budget check, then
    /// accepted lowest block first while the budget lasts, with one
    /// overshoot. In-flight requests draw the budget down in the same order,
    /// so a hole before one claims budget ahead of it and the buffer never
    /// waits on a hole it can't fund.
    pub fn plan_requests(&mut self, tick: &Tick) -> Planned {
        let head_block = self.known_height - self.block_lag;
        if head_block <= 0 {
            return Planned::WaitForNewBlock;
        }
        let caught_up = head_block - self.blocks_behind_head_allowed_by_throttle();
        let behind_generated_block_handlers =
            self.config.has_generated_block_handlers && tick.processing_block < caught_up;
        let mut should_wait = self
            .end_block
            .is_none_or(|end_block| head_block < end_block)
            && !behind_generated_block_handlers;

        let streams = self.stream_states();
        let reserved = self.reserved();
        let reservations: Vec<(i64, i64)> = self
            .requests
            .in_flight()
            .map(|request| (request.from_block, i64::from(request.items_estimate)))
            .collect();
        for stream in &streams {
            // Waits only once every stream reached the head: a response can
            // still move the known height, and a few small streams aren't
            // worth polling the head for while another is halfway.
            if stream.in_flight > 0 || stream.has_ahead || stream.covered < caught_up {
                should_wait = false;
            }
        }
        let available = MAX_IN_FLIGHT_PER_CHAIN.saturating_sub(reservations.len());
        let stream_count = if tick.target_items <= 0. || should_wait || available == 0 {
            0
        } else {
            streams.len()
        };

        let mut candidates: Vec<Candidate> = Vec::new();
        let stream_budget = if stream_count == 0 {
            0.
        } else {
            tick.target_items / stream_count as f64
        };
        let mut fill_states: Vec<FillState> = Vec::new();
        for (index, stream) in streams.iter().take(stream_count).enumerate() {
            let taken = self.taken_by_all(&stream.needs);
            let Some(&(_, first_end)) = taken.first() else {
                continue;
            };
            if first_end == i64::MAX {
                continue;
            }
            let mut cursor = first_end + 1;
            let mut chunks_used = 0;
            let mut blocked = false;
            for &(from, to) in &taken[1..] {
                if from > cursor {
                    let before = candidates.len();
                    push_gap(
                        &mut candidates,
                        stream,
                        index,
                        cursor,
                        min_option(Some(from - 1), stream.query_end),
                        head_block,
                        tick.target_block,
                        MAX_IN_FLIGHT_PER_STREAM.saturating_sub(stream.in_flight + chunks_used),
                        stream_budget,
                    );
                    chunks_used += candidates.len() - before;
                }
                if to == i64::MAX {
                    blocked = true;
                    break;
                }
                cursor = to + 1;
            }
            if !blocked {
                fill_states.push(FillState {
                    stream: index,
                    cursor,
                    chunks_used,
                });
            }
        }

        let fresh_budget = (tick.target_items - reserved).max(0.);
        let mut in_range: Vec<FillState> = fill_states
            .into_iter()
            .filter(|fill| {
                let stream = &streams[fill.stream];
                fill.cursor <= tick.target_block
                    && stream.query_end.is_none_or(|end| fill.cursor <= end)
                    && stream.in_flight + fill.chunks_used < MAX_IN_FLIGHT_PER_STREAM
            })
            .collect();
        let in_range_count = in_range.len();
        // A stream past the first `available` cursors could only offer
        // candidates behind that many earlier ones, which the chain's cap
        // stops acceptance from reaching. Sizing still divides by every
        // stream in range, so each probe keeps its honest share.
        if in_range_count > available {
            in_range.sort_by_key(|fill| fill.cursor);
            in_range.truncate(available);
        }
        push_forward(
            &mut candidates,
            &streams,
            &in_range,
            in_range_count,
            tick,
            fresh_budget,
        );

        let accepted = accept(candidates, &reservations, tick.target_items, streams.len());
        let mut started = Vec::new();
        for (stream_index, stream_candidates) in accepted.into_iter().enumerate() {
            let stream = &streams[stream_index];
            for candidate in stream_candidates {
                for &need in &stream.needs {
                    self.needs.ever_requested[need as usize] = true;
                }
                started.push(self.requests.insert(Request {
                    needs: stream.needs.clone(),
                    from_block: candidate.from_block,
                    to_block: candidate.to_block,
                    items_estimate: candidate.items.clamp(0, i64::from(u32::MAX)) as u32,
                    chunk: candidate.chunk,
                    head: stream.head,
                }));
            }
        }
        if started.is_empty() {
            if should_wait {
                Planned::WaitForNewBlock
            } else {
                Planned::NothingToDo
            }
        } else {
            Planned::Start(started)
        }
    }
}

/// Each stream in range offers chunks when both its capacity and a positive
/// density are known, else one open-ended probe. A zero density prices every
/// chunk at nothing, so a probe that takes the server's whole range in one
/// response beats chunks crawling up from the first measurement.
fn push_forward(
    candidates: &mut Vec<Candidate>,
    streams: &[Stream],
    in_range: &[FillState],
    in_range_count: usize,
    tick: &Tick,
    fresh_budget: f64,
) {
    let target_block = tick.target_block;
    let probe_share = if in_range_count == 0 {
        0.
    } else {
        fresh_budget / in_range_count as f64
    };
    let frontier_cursor = in_range
        .iter()
        .map(|fill| fill.cursor)
        .fold(target_block, i64::min);
    let range_to_target = target_block - frontier_cursor + 1;
    let range_target_density = if in_range_count > 0 && range_to_target > 0 {
        fresh_budget / range_to_target as f64
    } else {
        0.
    };
    for fill in in_range {
        let stream = &streams[fill.stream];
        let max_block = stream.query_end.unwrap_or(target_block);
        match (stream.chunk_range, stream.density) {
            (Some(chunk_range), Some(density)) if density > 0. => {
                let chunk_size = (chunk_range as f64 * CHUNK_RANGE_GROWTH).ceil() as i64;
                let max_chunks =
                    MAX_IN_FLIGHT_PER_STREAM.saturating_sub(stream.in_flight + fill.chunks_used);
                // A chunk starts no later than the target but keeps its full
                // span; only end blocks bound it hard.
                let start_ceiling = max_block.min(target_block);
                let mut created = 0;
                let mut from_block = fill.cursor;
                // Acceptance hands one stream at most the budget plus one
                // overshoot, so generating past that is wasted.
                let mut generated = 0.;
                while created < max_chunks
                    && from_block <= start_ceiling
                    && generated <= fresh_budget
                {
                    let to_block = (from_block + chunk_size - 1).min(max_block);
                    let items =
                        density_items_estimate(density, from_block, Some(to_block), target_block);
                    candidates.push(Candidate {
                        stream: fill.stream,
                        from_block,
                        to_block: Some(to_block),
                        items,
                        chunk: true,
                    });
                    generated += items as f64;
                    from_block = to_block + 1;
                    created += 1;
                }
            }
            _ => {
                // With nothing known, neither the stream's density nor the
                // chain's, a probe may come back a full page however small its
                // share, so it reserves one, but never more than the budget:
                // it is admitted alone either way, and charging more would
                // hold the other chains out of the pool until it answers.
                let items = match (stream.density, tick.chain_density) {
                    (None, None) => PAGE_ITEMS.min((fresh_budget.ceil() as i64).max(1)),
                    _ if range_to_target > 0 => ((range_target_density
                        * (target_block - fill.cursor + 1) as f64
                        / in_range_count as f64)
                        .round() as i64)
                        .max(1),
                    _ => (probe_share.round() as i64).max(1),
                };
                candidates.push(Candidate {
                    stream: fill.stream,
                    from_block: fill.cursor,
                    to_block: stream.query_end,
                    items,
                    chunk: false,
                });
            }
        }
    }
}

/// Candidates and in-flight reservations in block order; a reservation on
/// the same block is charged first, so only a strictly earlier hole borrows
/// ahead of one.
fn accept(
    candidates: Vec<Candidate>,
    reservations: &[(i64, i64)],
    target_items: f64,
    stream_count: usize,
) -> Vec<Vec<Candidate>> {
    let mut by_stream: Vec<Vec<Candidate>> = (0..stream_count).map(|_| Vec::new()).collect();
    let mut stream: Vec<(i64, i64, Option<Candidate>)> = candidates
        .into_iter()
        .map(|candidate| (candidate.from_block, candidate.items, Some(candidate)))
        .collect();
    stream.extend(
        reservations
            .iter()
            .map(|&(from, items)| (from, items, None)),
    );
    stream.sort_by(|(a_from, _, a), (b_from, _, b)| {
        a_from
            .cmp(b_from)
            .then_with(|| a.is_some().cmp(&b.is_some()))
    });
    let mut remaining = target_items;
    let mut used = reservations.len();
    for (_, items, candidate) in stream {
        if remaining <= 0. || used >= MAX_IN_FLIGHT_PER_CHAIN {
            break;
        }
        if let Some(candidate) = candidate {
            used += 1;
            by_stream[candidate.stream].push(candidate);
        }
        remaining -= items as f64;
    }
    by_stream
}
