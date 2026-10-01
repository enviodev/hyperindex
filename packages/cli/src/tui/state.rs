use std::collections::VecDeque;

#[napi_derive::napi(object)]
#[derive(Clone, Debug, Default)]
pub struct TuiInfo {
    /// `"Block"`, or `"Slot"` on SVM.
    pub block_unit: String,
    /// Indexer start, in epoch milliseconds.
    pub start_time: f64,
    pub graphql_url: String,
    /// Shown next to the GraphQL link, only while it is the default password.
    pub graphql_password: Option<String>,
    pub dev_console_url: Option<String>,
    pub clickhouse_url: Option<String>,
}

#[napi_derive::napi(object)]
#[derive(Clone, Debug, Default)]
pub struct TuiChain {
    pub chain_id: String,
    pub powered_by_hyper_sync: bool,
    pub start_block: i64,
    pub end_block: Option<i64>,
    pub first_event_block_number: Option<i64>,
    /// Committed progress; -1 before the first batch.
    pub progress_block_number: i64,
    pub latest_fetched_block_number: i64,
    /// Clamped to the end block once the chain has processed to it.
    pub known_height: i64,
    /// Raw source height, unlike `known_height`.
    pub source_block_number: i64,
    /// Epoch milliseconds.
    pub timestamp_caught_up_to_head_or_endblock: Option<f64>,
    pub num_events_processed: f64,
    pub rate_limit_time_ms: f64,
    pub rate_limit_reset_in_ms: Option<f64>,
}

#[napi_derive::napi(object)]
#[derive(Clone, Debug, PartialEq)]
pub struct TuiMessage {
    /// One of primary, secondary, info, danger, success, white, gray.
    pub color: String,
    pub content: String,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Messages {
    Loading,
    Loaded(Vec<TuiMessage>),
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Progress {
    SearchingForEvents,
    Syncing {
        first_event_block: i64,
        latest_processed_block: i64,
    },
    Synced {
        first_event_block: i64,
        latest_processed_block: i64,
        caught_up_at: f64,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct Chain {
    pub chain_id: String,
    pub events_processed: f64,
    /// Clamped into `[start_block, to_block]`: the source height is 0 until the
    /// first height fetch lands, and the buffer starts one block below the start
    /// block, so raw values can fall outside the range the bar counts up to.
    pub progress_block: i64,
    pub buffer_block: i64,
    pub to_block: i64,
    pub start_block: i64,
    pub end_block: Option<i64>,
    pub powered_by_hyper_sync: bool,
    pub progress: Progress,
    pub latest_fetched_block_number: i64,
    pub known_height: i64,
    pub rate_limit_time_ms: f64,
    pub rate_limit_reset_in_ms: Option<f64>,
}

impl Chain {
    pub fn from_metrics(m: &TuiChain, now: f64) -> Self {
        let first_event_block = m.first_event_block_number.unwrap_or(0);
        let latest_processed_block = m.progress_block_number;
        let synced = |caught_up_at| Progress::Synced {
            first_event_block,
            latest_processed_block,
            caught_up_at,
        };
        // Mirrors `ChainState.hasProcessedToEndblock`. A chain can reach its end
        // block without ever matching an event, so it still renders as synced.
        let processed_to_end = m.end_block.is_some_and(|end| latest_processed_block >= end);
        let progress = if processed_to_end {
            synced(m.timestamp_caught_up_to_head_or_endblock.unwrap_or(now))
        } else {
            match (
                m.first_event_block_number,
                m.timestamp_caught_up_to_head_or_endblock,
            ) {
                (Some(_), Some(caught_up_at)) => synced(caught_up_at),
                (Some(_), None) => Progress::Syncing {
                    first_event_block,
                    latest_processed_block,
                },
                (None, _) => Progress::SearchingForEvents,
            }
        };
        let to_block = m
            .end_block
            .map_or(m.source_block_number, |end| m.source_block_number.min(end))
            .max(m.start_block);
        let clamp = |block: i64| block.max(m.start_block).min(to_block);
        Chain {
            chain_id: m.chain_id.clone(),
            events_processed: m.num_events_processed,
            progress_block: clamp(m.progress_block_number),
            buffer_block: clamp(m.latest_fetched_block_number),
            to_block,
            start_block: m.start_block,
            end_block: m.end_block,
            powered_by_hyper_sync: m.powered_by_hyper_sync,
            progress,
            latest_fetched_block_number: m.latest_fetched_block_number,
            known_height: m.known_height,
            rate_limit_time_ms: m.rate_limit_time_ms,
            rate_limit_reset_in_ms: m.rate_limit_reset_in_ms,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Eta {
    Calculating,
    Syncing(String),
    Synced(String),
}

const EVENTS_PER_SECOND_WINDOW_MS: f64 = 60_000.;

#[derive(Clone, Debug)]
pub struct State {
    pub info: TuiInfo,
    pub chains: Vec<Chain>,
    pub messages: Messages,
    /// `(time, total events)` over the last minute.
    samples: VecDeque<(f64, f64)>,
    /// Once every chain has a height and fetched something, the ETA stays on
    /// rather than flickering back to "calculating".
    eta_ready: bool,
}

impl State {
    pub fn new(info: TuiInfo) -> Self {
        State {
            info,
            chains: Vec::new(),
            messages: Messages::Loading,
            samples: VecDeque::new(),
            eta_ready: false,
        }
    }

    pub fn update(&mut self, chains: &[TuiChain], now: f64) {
        self.chains = chains
            .iter()
            .map(|chain| Chain::from_metrics(chain, now))
            .collect();
        if !self.eta_ready {
            self.eta_ready = self
                .chains
                .iter()
                .all(|chain| chain.known_height > 0 && chain.latest_fetched_block_number > 0);
        }
        while self
            .samples
            .front()
            .is_some_and(|(time, _)| *time < now - EVENTS_PER_SECOND_WINDOW_MS)
        {
            self.samples.pop_front();
        }
        self.samples.push_back((now, self.total_events()));
    }

    pub fn total_events(&self) -> f64 {
        self.chains.iter().map(|chain| chain.events_processed).sum()
    }

    pub fn events_per_second(&self) -> Option<f64> {
        match (self.samples.front(), self.samples.back()) {
            (Some(first), Some(last)) if last.0 > first.0 => {
                Some((last.1 - first.1) / ((last.0 - first.0) / 1000.))
            }
            _ => None,
        }
    }

    /// A supervised run draws before any worker has reported, and a run with
    /// nothing to report hasn't finished syncing.
    pub fn is_fully_synced(&self) -> bool {
        !self.chains.is_empty()
            && self
                .chains
                .iter()
                .all(|chain| matches!(chain.progress, Progress::Synced { .. }))
    }

    fn remaining_blocks(&self) -> i64 {
        self.chains
            .iter()
            .map(|chain| {
                let final_block = chain.end_block.unwrap_or(chain.known_height);
                match chain.progress {
                    Progress::Syncing {
                        latest_processed_block,
                        ..
                    }
                    | Progress::Synced {
                        latest_processed_block,
                        ..
                    } => final_block - latest_processed_block,
                    Progress::SearchingForEvents => final_block - chain.latest_fetched_block_number,
                }
            })
            .sum()
    }

    fn processed_blocks(&self) -> i64 {
        self.chains
            .iter()
            .map(|chain| match chain.progress {
                Progress::Syncing {
                    first_event_block,
                    latest_processed_block,
                }
                | Progress::Synced {
                    first_event_block,
                    latest_processed_block,
                    ..
                } => latest_processed_block - first_event_block,
                Progress::SearchingForEvents => chain.latest_fetched_block_number,
            })
            .sum()
    }

    pub fn eta(&self, now: f64) -> Eta {
        if self.is_fully_synced() {
            let caught_up_at = self
                .chains
                .iter()
                .filter_map(|chain| match chain.progress {
                    Progress::Synced { caught_up_at, .. } => Some(caught_up_at),
                    _ => None,
                })
                .fold(0., f64::max);
            return Eta::Synced(super::format::distance(self.info.start_time, caught_up_at));
        }
        let processed = self.processed_blocks();
        if !self.eta_ready || processed <= 0 {
            return Eta::Calculating;
        }
        let elapsed = now - self.info.start_time;
        let remaining_ms = elapsed / processed as f64 * self.remaining_blocks() as f64;
        Eta::Syncing(super::format::duration(remaining_ms))
    }

    /// The slowest chain's accumulated rate-limit wait, once it passes a second,
    /// with the longest time until any chain's limit resets.
    pub fn rate_limit(&self) -> Option<(f64, f64)> {
        let time_ms = self
            .chains
            .iter()
            .map(|chain| chain.rate_limit_time_ms)
            .fold(0., f64::max);
        let reset_in_ms = self
            .chains
            .iter()
            .filter_map(|chain| chain.rate_limit_reset_in_ms)
            .fold(0., f64::max);
        (time_ms > 1000.).then_some((time_ms, reset_in_ms))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    pub fn chain_metrics() -> TuiChain {
        TuiChain {
            chain_id: "1".to_string(),
            powered_by_hyper_sync: true,
            start_block: 100,
            end_block: None,
            first_event_block_number: None,
            progress_block_number: -1,
            latest_fetched_block_number: 99,
            known_height: 0,
            source_block_number: 0,
            timestamp_caught_up_to_head_or_endblock: None,
            num_events_processed: 0.,
            rate_limit_time_ms: 0.,
            rate_limit_reset_in_ms: None,
        }
    }

    fn state(chains: &[TuiChain], now: f64) -> State {
        let mut state = State::new(TuiInfo::default());
        state.update(chains, now);
        state
    }

    #[test]
    fn clamps_blocks_into_the_bar_range_before_the_first_height() {
        let chain = Chain::from_metrics(&chain_metrics(), 0.);
        assert_eq!(
            chain,
            Chain {
                chain_id: "1".to_string(),
                events_processed: 0.,
                progress_block: 100,
                buffer_block: 100,
                to_block: 100,
                start_block: 100,
                end_block: None,
                powered_by_hyper_sync: true,
                progress: Progress::SearchingForEvents,
                latest_fetched_block_number: 99,
                known_height: 0,
                rate_limit_time_ms: 0.,
                rate_limit_reset_in_ms: None,
            }
        );
    }

    // The source height is unknown until the first height fetch lands, so a
    // resumed chain would otherwise render progress beyond the block it counts up to.
    #[test]
    fn keeps_resumed_progress_inside_the_bar_range() {
        let chain = Chain::from_metrics(
            &TuiChain {
                first_event_block_number: Some(150),
                progress_block_number: 400,
                latest_fetched_block_number: 450,
                ..chain_metrics()
            },
            0.,
        );
        assert_eq!(
            (chain.progress_block, chain.buffer_block, chain.to_block),
            (100, 100, 100)
        );
    }

    #[test]
    fn caps_the_bar_at_the_end_block() {
        let chain = Chain::from_metrics(
            &TuiChain {
                end_block: Some(500),
                first_event_block_number: Some(150),
                progress_block_number: 400,
                latest_fetched_block_number: 600,
                known_height: 500,
                source_block_number: 1000,
                ..chain_metrics()
            },
            0.,
        );
        assert_eq!(
            (
                chain.progress_block,
                chain.buffer_block,
                chain.to_block,
                chain.progress
            ),
            (
                400,
                500,
                500,
                Progress::Syncing {
                    first_event_block: 150,
                    latest_processed_block: 400
                }
            )
        );
    }

    #[test]
    fn a_chain_at_its_end_block_without_events_is_synced() {
        let chain = Chain::from_metrics(
            &TuiChain {
                end_block: Some(500),
                progress_block_number: 500,
                ..chain_metrics()
            },
            42.,
        );
        assert_eq!(
            chain.progress,
            Progress::Synced {
                first_event_block: 0,
                latest_processed_block: 500,
                caught_up_at: 42.,
            }
        );
    }

    #[test]
    fn a_chain_caught_up_to_head_is_synced() {
        let chain = Chain::from_metrics(
            &TuiChain {
                first_event_block_number: Some(150),
                progress_block_number: 900,
                timestamp_caught_up_to_head_or_endblock: Some(7.),
                ..chain_metrics()
            },
            42.,
        );
        assert_eq!(
            chain.progress,
            Progress::Synced {
                first_event_block: 150,
                latest_processed_block: 900,
                caught_up_at: 7.,
            }
        );
    }

    #[test]
    fn no_chains_is_not_synced() {
        assert_eq!(state(&[], 0.).eta(0.), Eta::Calculating);
    }

    #[test]
    fn calculates_until_every_chain_has_a_height() {
        let syncing = TuiChain {
            first_event_block_number: Some(100),
            progress_block_number: 200,
            latest_fetched_block_number: 300,
            known_height: 1100,
            source_block_number: 1100,
            ..chain_metrics()
        };
        let waiting = TuiChain {
            chain_id: "2".to_string(),
            ..chain_metrics()
        };
        assert_eq!(
            state(&[syncing, waiting], 0.).eta(10_000.),
            Eta::Calculating
        );
    }

    #[test]
    fn projects_the_eta_from_the_pace_so_far() {
        let syncing = TuiChain {
            first_event_block_number: Some(100),
            progress_block_number: 200,
            latest_fetched_block_number: 300,
            known_height: 1100,
            source_block_number: 1100,
            ..chain_metrics()
        };
        // 100 blocks in 10s, 900 to go.
        assert_eq!(
            state(&[syncing], 10_000.).eta(10_000.),
            Eta::Syncing("1 minute 30 seconds".to_string())
        );
    }

    #[test]
    fn reports_the_time_to_the_last_chain_caught_up() {
        let synced = |chain_id: &str, caught_up_at| TuiChain {
            chain_id: chain_id.to_string(),
            first_event_block_number: Some(100),
            progress_block_number: 900,
            timestamp_caught_up_to_head_or_endblock: Some(caught_up_at),
            ..chain_metrics()
        };
        assert_eq!(
            state(&[synced("1", 30_000.), synced("2", 150_000.)], 0.).eta(0.),
            Eta::Synced("3 minutes".to_string())
        );
    }

    #[test]
    fn measures_events_per_second_over_the_last_minute() {
        let at = |events| TuiChain {
            num_events_processed: events,
            ..chain_metrics()
        };
        let mut state = state(&[at(0.)], 0.);
        assert_eq!(state.events_per_second(), None);
        state.update(&[at(1000.)], 10_000.);
        state.update(&[at(7000.)], 70_000.);
        // The first sample fell out of the window: 6000 events over 60s.
        assert_eq!(state.events_per_second(), Some(100.));
    }

    #[test]
    fn surfaces_rate_limits_over_a_second() {
        let limited = |time_ms, reset_in_ms| TuiChain {
            rate_limit_time_ms: time_ms,
            rate_limit_reset_in_ms: reset_in_ms,
            ..chain_metrics()
        };
        assert_eq!(
            (
                state(&[limited(1000., Some(5.))], 0.).rate_limit(),
                state(&[limited(2500., None), limited(10., Some(3000.))], 0.).rate_limit(),
            ),
            (None, Some((2500., 3000.)))
        );
    }
}
