//! Which of a chain's sources answers each request, and what happens when one
//! doesn't: failover, retry schedules, rate-limit windows, the height feeds
//! and the waits for a new block.
//!
//! Nothing here performs IO or keeps time. ReScript makes every call to a
//! source and arms every timer on the clock it was given, reports how each
//! went, and carries out the effects this leaves in return, in order. That
//! keeps the sources themselves (and the test doubles standing in for them)
//! on the JavaScript side, and every timer on the one timeline a test moves.

mod core;
mod feed;
mod query;
mod wait;

use napi_derive::napi;

use self::{
    core::{Core, Effect, HeightRetry, RequestStat, SourceSpec, Status, Timing},
    query::{HashesFailure, Inconsistent, ItemsFailure},
};
use crate::block_store::BlockStore;

#[napi(string_enum)]
pub enum SourceFor {
    Sync,
    Fallback,
    Realtime,
}

#[napi(object)]
pub struct SourceManagerSource {
    pub name: String,
    pub source_for: SourceFor,
    pub polling_interval: u32,
    /// Whether the source can push heights over a subscription.
    pub can_stream: bool,
}

/// Every field defaults to the production value. Only tests set them, to reach
/// a stall, a recovery or a retry schedule without waiting out the real window.
#[napi(object)]
#[derive(Default)]
pub struct SourceManagerTiming {
    pub new_block_stall_timeout: Option<u32>,
    pub new_block_stall_timeout_realtime: Option<u32>,
    pub stalled_polling_interval: Option<u32>,
    pub reduced_polling_interval: Option<u32>,
    pub recovery_timeout: Option<f64>,
    /// The height poll's backoff: the initial delay, multiplied by the retry
    /// count from the second retry on, up to the max.
    pub height_retry_initial_millis: Option<u32>,
    pub height_retry_multiplier: Option<u32>,
    pub height_retry_max_millis: Option<u32>,
    pub height_poll_timeout: Option<u32>,
}

impl From<SourceManagerTiming> for Timing {
    fn from(timing: SourceManagerTiming) -> Self {
        let default = Timing::default();
        Timing {
            new_block_stall_timeout: timing
                .new_block_stall_timeout
                .unwrap_or(default.new_block_stall_timeout),
            new_block_stall_timeout_realtime: timing
                .new_block_stall_timeout_realtime
                .unwrap_or(default.new_block_stall_timeout_realtime),
            stalled_polling_interval: timing
                .stalled_polling_interval
                .unwrap_or(default.stalled_polling_interval),
            reduced_polling_interval: timing
                .reduced_polling_interval
                .unwrap_or(default.reduced_polling_interval),
            recovery_timeout: timing.recovery_timeout.unwrap_or(default.recovery_timeout),
            height_retry: HeightRetry {
                initial_millis: timing
                    .height_retry_initial_millis
                    .unwrap_or(default.height_retry.initial_millis),
                multiplier: timing
                    .height_retry_multiplier
                    .unwrap_or(default.height_retry.multiplier),
                max_millis: timing
                    .height_retry_max_millis
                    .unwrap_or(default.height_retry.max_millis),
            },
            height_poll_timeout: timing
                .height_poll_timeout
                .unwrap_or(default.height_poll_timeout),
        }
    }
}

/// One backend request a source method made, with the time it took and how
/// much it brought back.
#[napi(object)]
pub struct SourceRequestStat {
    pub method: String,
    pub seconds: f64,
    pub response_blocks: Option<i64>,
}

fn to_request_stats(stats: Vec<SourceRequestStat>) -> Vec<RequestStat> {
    stats
        .into_iter()
        .map(|stat| RequestStat {
            method: stat.method,
            seconds: stat.seconds,
            response_blocks: stat.response_blocks,
        })
        .collect()
}

#[napi(discriminant = "kind")]
pub enum SourceManagerEffect {
    /// `err` names the failure the call that led here reported.
    Log {
        fields_json: Option<String>,
        level: String,
        message: String,
        params_json: Option<String>,
        err: Option<u32>,
    },
    ArmTimer {
        timer: u32,
        label: String,
        millis: u32,
        jitter: bool,
    },
    ClearTimer {
        timer: u32,
    },
    /// Hand `token` back to `timer_fired` from a microtask.
    Defer {
        token: u32,
    },
    RequestHeight {
        request: u32,
        source: u32,
    },
    SubscribeStream {
        source: u32,
    },
    CloseStream {
        source: u32,
    },
    ResolveWait {
        wait: u32,
        height: i64,
    },
    Reorg {
        source: u32,
    },
    Attempt {
        request: u32,
        source: u32,
        to_block: Option<i64>,
        retry: u32,
        fields_json: String,
    },
    Resolve {
        request: u32,
    },
    Reject {
        request: u32,
        message: String,
    },
}

impl From<Effect> for SourceManagerEffect {
    fn from(effect: Effect) -> Self {
        match effect {
            Effect::Log {
                fields,
                level,
                message,
                params,
                err,
            } => SourceManagerEffect::Log {
                fields_json: fields.map(|fields| fields.to_string()),
                level: level.as_str().to_string(),
                message,
                params_json: (!params.is_null()).then(|| params.to_string()),
                err,
            },
            Effect::ArmTimer {
                timer,
                label,
                millis,
                jitter,
            } => SourceManagerEffect::ArmTimer {
                timer,
                label: label.to_string(),
                millis,
                jitter,
            },
            Effect::ClearTimer { timer } => SourceManagerEffect::ClearTimer { timer },
            Effect::Defer { token } => SourceManagerEffect::Defer { token },
            Effect::RequestHeight { request, source } => SourceManagerEffect::RequestHeight {
                request,
                source: source as u32,
            },
            Effect::SubscribeStream { source } => SourceManagerEffect::SubscribeStream {
                source: source as u32,
            },
            Effect::CloseStream { source } => SourceManagerEffect::CloseStream {
                source: source as u32,
            },
            Effect::ResolveWait { wait, height } => {
                SourceManagerEffect::ResolveWait { wait, height }
            }
            Effect::Reorg { source } => SourceManagerEffect::Reorg {
                source: source as u32,
            },
            Effect::Attempt {
                request,
                source,
                to_block,
                retry,
                fields,
            } => SourceManagerEffect::Attempt {
                request,
                source: source as u32,
                to_block,
                retry,
                fields_json: fields.to_string(),
            },
            Effect::Resolve { request } => SourceManagerEffect::Resolve { request },
            Effect::Reject { request, message } => SourceManagerEffect::Reject { request, message },
        }
    }
}

#[napi(discriminant = "kind")]
pub enum SourceItemsFailure {
    RateLimited {
        reset_ms: u32,
    },
    BehindHead {
        block_number: i64,
    },
    UnsupportedSelection {
        message: String,
    },
    FieldSelection {
        message: String,
        block_number: i64,
    },
    SuggestedToBlock {
        to_block: i64,
        attempted_to_block: i64,
    },
    Impossible {
        message: String,
        attempted_to_block: i64,
    },
    Backoff {
        message: String,
        backoff_millis: u32,
        attempted_to_block: i64,
    },
}

impl From<SourceItemsFailure> for ItemsFailure {
    fn from(failure: SourceItemsFailure) -> Self {
        match failure {
            SourceItemsFailure::RateLimited { reset_ms } => ItemsFailure::RateLimited { reset_ms },
            SourceItemsFailure::BehindHead { block_number } => {
                ItemsFailure::BehindHead { block_number }
            }
            SourceItemsFailure::UnsupportedSelection { message } => {
                ItemsFailure::UnsupportedSelection { message }
            }
            SourceItemsFailure::FieldSelection {
                message,
                block_number,
            } => ItemsFailure::FieldSelection {
                message,
                block_number,
            },
            SourceItemsFailure::SuggestedToBlock {
                to_block,
                attempted_to_block,
            } => ItemsFailure::SuggestedToBlock {
                to_block,
                attempted_to_block,
            },
            SourceItemsFailure::Impossible {
                message,
                attempted_to_block,
            } => ItemsFailure::Impossible {
                message,
                attempted_to_block,
            },
            SourceItemsFailure::Backoff {
                message,
                backoff_millis,
                attempted_to_block,
            } => ItemsFailure::Backoff {
                message,
                backoff_millis,
                attempted_to_block,
            },
        }
    }
}

/// A (source, method) aggregate for the envio_source_request_* and
/// envio_source_response_* metrics.
#[napi(object)]
pub struct RequestStatSample {
    pub source: u32,
    pub method: String,
    pub count: u32,
    pub seconds: f64,
    pub response_blocks: Option<i64>,
    pub empty_response_count: u32,
}

#[napi(object)]
pub struct SourceHeightSample {
    pub source: u32,
    pub height: i64,
}

#[napi(object)]
pub struct HeightStreamSample {
    pub source: u32,
    pub connect_count: u32,
    /// Sorted by reason, so the rendered order doesn't depend on which reasons
    /// a stream happened to hit first.
    pub disconnect_reasons: Vec<String>,
    pub disconnect_counts: Vec<u32>,
}

#[napi]
pub struct SourceManager {
    core: Core,
}

#[napi]
impl SourceManager {
    #[napi(factory)]
    pub fn make(
        sources: Vec<SourceManagerSource>,
        is_realtime: bool,
        timing: Option<SourceManagerTiming>,
    ) -> napi::Result<Self> {
        let specs = sources
            .into_iter()
            .map(|source| SourceSpec {
                name: source.name,
                source_for: match source.source_for {
                    SourceFor::Sync => core::SourceFor::Sync,
                    SourceFor::Fallback => core::SourceFor::Fallback,
                    SourceFor::Realtime => core::SourceFor::Realtime,
                },
                polling_interval: source.polling_interval,
                can_stream: source.can_stream,
            })
            .collect();
        Core::new(specs, is_realtime, timing.unwrap_or_default().into())
            .map(|core| SourceManager { core })
            .map_err(napi::Error::from_reason)
    }

    /// The next thing the caller has to do, in the order it is owed.
    #[napi]
    pub fn take_effect(&mut self) -> Option<SourceManagerEffect> {
        self.core.take_effect().map(SourceManagerEffect::from)
    }

    #[napi]
    pub fn timer_fired(&mut self, timer: u32, now: f64) {
        self.core.timer_fired(timer, now);
    }

    /// Resolves through a `ResolveWait` effect, which can already be queued
    /// when this returns.
    #[napi]
    pub fn wait_for_new_block(
        &mut self,
        known_height: i64,
        is_realtime: bool,
        reduced_polling: bool,
        now: f64,
    ) -> u32 {
        self.core
            .wait_for_new_block(known_height, is_realtime, reduced_polling, now)
    }

    #[napi]
    pub fn height_answered(&mut self, request: u32, height: i64, stats: Vec<SourceRequestStat>) {
        self.core
            .height_answered(request, height, &to_request_stats(stats));
    }

    #[napi]
    pub fn height_failed(&mut self, request: u32, stats: Vec<SourceRequestStat>, err: Option<u32>) {
        self.core
            .height_failed(request, &to_request_stats(stats), err);
    }

    #[napi]
    pub fn stream_height(&mut self, source: u32, height: i64) {
        self.core.stream_height(source as usize, height);
    }

    #[napi]
    pub fn stream_live(&mut self, source: u32) {
        self.core.stream_live(source as usize);
    }

    #[napi]
    pub fn stream_down(&mut self, source: u32, reason: String, detail: Option<String>) {
        self.core.stream_down(source as usize, &reason, detail);
    }

    #[napi]
    pub fn start_items_query(
        &mut self,
        from_block: i64,
        to_block: Option<i64>,
        partition_id: String,
        addresses: u32,
        is_realtime: bool,
        now: f64,
    ) -> u32 {
        self.core.start_items_query(
            from_block,
            to_block,
            partition_id,
            addresses,
            is_realtime,
            now,
        )
    }

    /// A response is trusted only once its page has proved internally coherent.
    #[napi]
    pub fn items_answered(
        &mut self,
        request: u32,
        block_store: &BlockStore,
        known_height: i64,
        stats: Vec<SourceRequestStat>,
        now: f64,
    ) {
        let inconsistent = Inconsistent::check(block_store.response_conflict(), Vec::new());
        self.core.items_answered(
            request,
            known_height,
            &to_request_stats(stats),
            inconsistent,
            now,
        );
    }

    #[napi]
    pub fn items_failed(
        &mut self,
        request: u32,
        failure: SourceItemsFailure,
        stats: Vec<SourceRequestStat>,
        err: Option<u32>,
        now: f64,
    ) {
        self.core
            .items_failed(request, failure.into(), &to_request_stats(stats), err, now);
    }

    #[napi]
    pub fn start_block_hashes(
        &mut self,
        block_numbers: Vec<i64>,
        is_realtime: bool,
        now: f64,
    ) -> u32 {
        self.core
            .start_block_hashes(block_numbers, is_realtime, now)
    }

    /// Also rejects a response that simply omitted one of the requested hashes.
    #[napi]
    pub fn hashes_answered(
        &mut self,
        request: u32,
        block_store: &BlockStore,
        stats: Vec<SourceRequestStat>,
        now: f64,
    ) {
        let required = self.core.requested_block_numbers(request);
        let inconsistent = Inconsistent::check(
            block_store.response_conflict(),
            block_store.missing_hashes(required),
        );
        self.core
            .hashes_answered(request, &to_request_stats(stats), inconsistent, now);
    }

    /// A failure that is neither rate-limiting nor a source behind the head is
    /// retried on the shared schedule.
    #[napi]
    pub fn hashes_failed(
        &mut self,
        request: u32,
        rate_limit_reset_ms: Option<u32>,
        behind_head_block: Option<i64>,
        stats: Vec<SourceRequestStat>,
        err: Option<u32>,
        now: f64,
    ) {
        let failure = match (rate_limit_reset_ms, behind_head_block) {
            (Some(reset_ms), _) => HashesFailure::RateLimited { reset_ms },
            (None, Some(block_number)) => HashesFailure::BehindHead { block_number },
            (None, None) => HashesFailure::Other,
        };
        self.core
            .hashes_failed(request, failure, &to_request_stats(stats), err, now);
    }

    /// The attempt failed in a way nothing here can retry, and the caller
    /// raises it.
    #[napi]
    pub fn abandon_request(&mut self, request: u32) {
        self.core.abandon_request(request);
    }

    #[napi]
    pub fn begin_waiting(&mut self, state_id: i64) -> bool {
        self.core.begin_waiting(state_id)
    }

    #[napi]
    pub fn finish_waiting(&mut self, state_id: i64) -> bool {
        self.core.finish_waiting(state_id)
    }

    #[napi]
    pub fn queries_started(&mut self, count: u32) {
        self.core.queries_started(count);
    }

    #[napi]
    pub fn query_finished(&mut self) {
        self.core.query_finished();
    }

    #[napi]
    pub fn active_source(&self) -> u32 {
        self.core.active as u32
    }

    /// Partition queries in flight on this chain's sources. Summed across
    /// chains to enforce the indexer-wide concurrency budget.
    #[napi]
    pub fn in_flight(&self) -> u32 {
        self.core.in_flight()
    }

    #[napi]
    pub fn idle_seconds(&self) -> f64 {
        self.core.seconds_in(Status::Idle)
    }

    #[napi]
    pub fn waiting_for_new_block_seconds(&self) -> f64 {
        self.core.seconds_in(Status::WaitingForNewBlock)
    }

    #[napi]
    pub fn querying_seconds(&self) -> f64 {
        self.core.seconds_in(Status::Querying)
    }

    /// Total time spent waiting on rate limits, including a window in progress.
    #[napi]
    pub fn rate_limit_time_ms(&self, now: f64) -> f64 {
        self.core.rate_limit_time_ms(now)
    }

    /// Until the longest active rate-limit window resets.
    #[napi]
    pub fn rate_limit_reset_in_ms(&self, now: f64) -> Option<f64> {
        self.core.rate_limit_reset_in_ms(now)
    }

    #[napi]
    pub fn request_stat_samples(&self) -> Vec<RequestStatSample> {
        self.core
            .sources
            .iter()
            .enumerate()
            .flat_map(|(source, state)| {
                state
                    .request_stats
                    .iter()
                    .map(move |(method, agg)| RequestStatSample {
                        source: source as u32,
                        method: method.clone(),
                        count: agg.count,
                        seconds: agg.seconds,
                        response_blocks: agg.response_blocks,
                        empty_response_count: agg.empty_response_count,
                    })
            })
            .collect()
    }

    /// Per-source known heights. A source with none observed yet is left out.
    #[napi]
    pub fn source_height_samples(&self) -> Vec<SourceHeightSample> {
        self.core
            .sources
            .iter()
            .enumerate()
            .filter(|(_, state)| state.feed.known_height > 0)
            .map(|(source, state)| SourceHeightSample {
                source: source as u32,
                height: state.feed.known_height,
            })
            .collect()
    }

    /// Every source a wait has asked for a stream, including one whose stream
    /// never came up. One never asked is left out, so a chain that only polls
    /// renders none of it rather than sitting at zero.
    #[napi]
    pub fn height_stream_samples(&self) -> Vec<HeightStreamSample> {
        self.core
            .sources
            .iter()
            .enumerate()
            .filter(|(_, state)| state.feed.stream != feed::Stream::NeverEnabled)
            .map(|(source, state)| HeightStreamSample {
                source: source as u32,
                connect_count: state.feed.connects,
                disconnect_reasons: state.feed.disconnects.keys().cloned().collect(),
                disconnect_counts: state.feed.disconnects.values().copied().collect(),
            })
            .collect()
    }
}
