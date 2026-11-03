use std::{collections::HashMap, time::Instant};

use serde_json::Value;

use super::feed::Feed;

pub type TimerId = u32;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SourceFor {
    Sync,
    Fallback,
    Realtime,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Role {
    Primary,
    Secondary,
}

/// Backfill: Sync is primary, Fallback secondary, Realtime unused. Realtime
/// with a Realtime source: it is primary, Sync and Fallback secondary. Realtime
/// without one: as backfill.
pub fn source_role(source_for: SourceFor, is_realtime: bool, has_realtime: bool) -> Option<Role> {
    match (is_realtime, source_for) {
        (false, SourceFor::Sync) => Some(Role::Primary),
        (false, SourceFor::Fallback) => Some(Role::Secondary),
        (false, SourceFor::Realtime) => None,
        (true, SourceFor::Realtime) => Some(Role::Primary),
        (true, SourceFor::Sync) if has_realtime => Some(Role::Secondary),
        (true, SourceFor::Sync) => Some(Role::Primary),
        (true, SourceFor::Fallback) => Some(Role::Secondary),
    }
}

pub struct SourceSpec {
    pub name: String,
    pub source_for: SourceFor,
    pub polling_interval: u32,
    pub can_stream: bool,
}

#[derive(Clone, Copy)]
pub struct HeightRetry {
    pub initial_millis: u32,
    pub multiplier: u32,
    pub max_millis: u32,
}

impl HeightRetry {
    pub fn millis_for_retry(&self, retry: u32) -> u32 {
        let backoff = if retry == 0 {
            1
        } else {
            retry.saturating_mul(self.multiplier)
        };
        self.initial_millis
            .saturating_mul(backoff)
            .min(self.max_millis)
    }
}

#[derive(Clone, Copy)]
pub struct Timing {
    pub new_block_stall_timeout: u32,
    pub new_block_stall_timeout_realtime: u32,
    pub stalled_polling_interval: u32,
    pub reduced_polling_interval: u32,
    pub recovery_timeout: f64,
    pub height_retry: HeightRetry,
    pub height_poll_timeout: u32,
}

impl Default for Timing {
    fn default() -> Self {
        Timing {
            new_block_stall_timeout: 60_000,
            new_block_stall_timeout_realtime: 20_000,
            stalled_polling_interval: 5_000,
            reduced_polling_interval: 60_000,
            recovery_timeout: 60_000.,
            height_retry: HeightRetry {
                initial_millis: 1_000,
                multiplier: 2,
                max_millis: 60_000,
            },
            height_poll_timeout: 60_000,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Level {
    Trace,
    Info,
    Warn,
    Error,
}

impl Level {
    pub fn as_str(self) -> &'static str {
        match self {
            Level::Trace => "trace",
            Level::Info => "info",
            Level::Warn => "warn",
            Level::Error => "error",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    /// `fields` are bound to the chain's logger for this line; `params` is null
    /// for a line without any. `err` names a failure the caller reported,
    /// which only it can render.
    Log {
        fields: Option<Value>,
        level: Level,
        message: String,
        params: Value,
        err: Option<u32>,
    },
    ArmTimer {
        timer: TimerId,
        label: &'static str,
        millis: u32,
        /// Spread across the delay by the clock, so indexers sharing a
        /// provider don't act in lockstep.
        jitter: bool,
    },
    ClearTimer {
        timer: TimerId,
    },
    /// Report `token` back as fired from a microtask: after the reactions the
    /// effects before it queued, before anything that waits for time.
    Defer {
        token: TimerId,
    },
    RequestHeight {
        request: u32,
        source: usize,
    },
    SubscribeStream {
        source: usize,
    },
    CloseStream {
        source: usize,
    },
    ResolveWait {
        wait: u32,
        height: i64,
    },
    /// The source's own state may describe an orphaned chain.
    Reorg {
        source: usize,
    },
    Attempt {
        request: u32,
        source: usize,
        to_block: Option<i64>,
        retry: u32,
        fields: Value,
    },
    Resolve {
        request: u32,
    },
    Reject {
        request: u32,
        message: String,
    },
}

#[derive(Default, Clone, Debug, PartialEq)]
pub struct RequestStatAgg {
    pub count: u32,
    pub seconds: f64,
    pub response_blocks: Option<i64>,
    pub empty_response_count: u32,
}

pub struct RequestStat {
    pub method: String,
    pub seconds: f64,
    pub response_blocks: Option<i64>,
}

pub struct SourceState {
    pub spec: SourceSpec,
    pub disabled: bool,
    /// When this source last failed a request, on the caller's clock. Decides
    /// when it is tried again.
    pub last_failed_at: Option<f64>,
    /// In the order methods were first seen, which is the order they render.
    pub request_stats: Vec<(String, RequestStatAgg)>,
    pub feed: Feed,
}

impl SourceState {
    pub fn record_request_stats(&mut self, stats: &[RequestStat]) {
        for stat in stats {
            let agg = match self
                .request_stats
                .iter_mut()
                .position(|(method, _)| *method == stat.method)
            {
                Some(position) => &mut self.request_stats[position].1,
                None => {
                    self.request_stats
                        .push((stat.method.clone(), RequestStatAgg::default()));
                    &mut self.request_stats.last_mut().expect("just pushed").1
                }
            };
            agg.count += 1;
            agg.seconds += stat.seconds;
            if let Some(blocks) = stat.response_blocks {
                agg.response_blocks = Some(agg.response_blocks.unwrap_or(0) + blocks);
                if blocks == 0 {
                    agg.empty_response_count += 1;
                }
            }
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Status {
    Idle,
    WaitingForNewBlock,
    Querying,
}

#[derive(Debug)]
pub enum TimerPurpose {
    PollSleep { source: usize },
    PollSettled { source: usize },
    PollResume { source: usize },
    PollTimeout { request: u32 },
    StallPoke { wait: u32 },
    StallTimeout { wait: u32 },
    RetryBackoff { request: u32 },
    RateLimitReset { request: u32 },
}

#[derive(Default)]
struct RateLimit {
    committed_ms: f64,
    waiters: u32,
    /// When the current window started, while one is being waited out.
    active_start_ms: Option<f64>,
    /// The latest reset any concurrent waiter expects, so a countdown shows
    /// when the indexer actually retries.
    active_reset_at_ms: Option<f64>,
}

pub struct Core {
    pub sources: Vec<SourceState>,
    pub timing: Timing,
    pub active: usize,
    pub has_realtime: bool,
    /// Why a source was last disabled for good. A disabled source is never
    /// retried, so once none is left this is the only thing that tells the
    /// operator what to change.
    pub disable_reason: Option<String>,
    status: Status,
    status_start: Instant,
    idle_seconds: f64,
    waiting_seconds: f64,
    querying_seconds: f64,
    waiting_for_new_block_state_id: Option<i64>,
    /// Keeps the "waiting for new blocks" trace to once per contiguous wait,
    /// rather than once per epoch that re-enters it before a block is found.
    pub waiting_logged: bool,
    /// Counts queries started for states before a rollback too.
    in_flight: u32,
    rate_limit: RateLimit,
    next_id: u32,
    pub timers: HashMap<TimerId, TimerPurpose>,
    pub height_requests: HashMap<u32, super::feed::HeightRequest>,
    pub waits: HashMap<u32, super::wait::Wait>,
    pub requests: HashMap<u32, super::query::Request>,
    pub effects: std::collections::VecDeque<Effect>,
}

pub const NO_PRIMARY_SOURCE: &str =
    "Invalid configuration, no data-source for historical sync provided";

impl Core {
    pub fn new(specs: Vec<SourceSpec>, is_realtime: bool, timing: Timing) -> Result<Self, String> {
        let has_realtime = specs
            .iter()
            .any(|spec| spec.source_for == SourceFor::Realtime);
        let active = specs
            .iter()
            .position(|spec| {
                source_role(spec.source_for, is_realtime, has_realtime) == Some(Role::Primary)
            })
            .ok_or_else(|| NO_PRIMARY_SOURCE.to_string())?;
        Ok(Core {
            sources: specs
                .into_iter()
                .map(|spec| SourceState {
                    spec,
                    disabled: false,
                    last_failed_at: None,
                    request_stats: Vec::new(),
                    feed: Feed::default(),
                })
                .collect(),
            timing,
            active,
            has_realtime,
            disable_reason: None,
            status: Status::Idle,
            status_start: Instant::now(),
            idle_seconds: 0.,
            waiting_seconds: 0.,
            querying_seconds: 0.,
            waiting_for_new_block_state_id: None,
            waiting_logged: false,
            in_flight: 0,
            rate_limit: RateLimit::default(),
            next_id: 0,
            timers: HashMap::new(),
            height_requests: HashMap::new(),
            waits: HashMap::new(),
            requests: HashMap::new(),
            effects: std::collections::VecDeque::new(),
        })
    }

    pub fn next_id(&mut self) -> u32 {
        self.next_id += 1;
        self.next_id
    }

    pub fn emit(&mut self, effect: Effect) {
        self.effects.push_back(effect);
    }

    pub fn log(&mut self, fields: Option<Value>, level: Level, message: String, params: Value) {
        self.log_with_err(fields, level, message, params, None);
    }

    pub fn log_with_err(
        &mut self,
        fields: Option<Value>,
        level: Level,
        message: String,
        params: Value,
        err: Option<u32>,
    ) {
        self.emit(Effect::Log {
            fields,
            level,
            message,
            params,
            err,
        });
    }

    pub fn arm_timer(
        &mut self,
        purpose: TimerPurpose,
        label: &'static str,
        millis: u32,
        jitter: bool,
    ) -> TimerId {
        let timer = self.next_id();
        self.timers.insert(timer, purpose);
        self.emit(Effect::ArmTimer {
            timer,
            label,
            millis,
            jitter,
        });
        timer
    }

    /// Clearing a timer and forgetting it are one action, so a spent timer
    /// never reads as one still pending.
    pub fn clear_timer(&mut self, timer: &mut Option<TimerId>) {
        if let Some(id) = timer.take() {
            if self.timers.remove(&id).is_some() {
                self.emit(Effect::ClearTimer { timer: id });
            }
        }
    }

    pub fn timer_fired(&mut self, timer: TimerId, now: f64) {
        let Some(purpose) = self.timers.remove(&timer) else {
            return;
        };
        match purpose {
            TimerPurpose::PollSleep { source } => self.poll_sleep_ended(source),
            TimerPurpose::PollSettled { source } => self.poll_settled(source),
            TimerPurpose::PollResume { source } => self.resume_poll_loop(source),
            TimerPurpose::PollTimeout { request } => self.height_request_timed_out(request),
            TimerPurpose::StallPoke { wait } => self.stall_poke(wait),
            TimerPurpose::StallTimeout { wait } => self.stall_timeout(wait),
            TimerPurpose::RetryBackoff { request } => self.retry_backoff_ended(request, now),
            TimerPurpose::RateLimitReset { request } => self.rate_limit_reset(request, now),
        }
    }

    /// Comes back through `timer_fired` from a microtask.
    pub fn defer(&mut self, purpose: TimerPurpose) {
        let token = self.next_id();
        self.timers.insert(token, purpose);
        self.emit(Effect::Defer { token });
    }

    pub fn take_effect(&mut self) -> Option<Effect> {
        self.effects.pop_front()
    }

    // --- Selection ---

    pub fn role_of(&self, source: usize, is_realtime: bool) -> Option<Role> {
        source_role(
            self.sources[source].spec.source_for,
            is_realtime,
            self.has_realtime,
        )
    }

    pub fn is_working(&self, source: usize, now: f64) -> bool {
        match self.sources[source].last_failed_at {
            Some(failed_at) => now - failed_at >= self.timing.recovery_timeout,
            None => true,
        }
    }

    /// Working primaries, else working secondaries, else every primary with the
    /// one closest to recovery first. Secondaries take that last place only
    /// once no primary is left at all: a recovering source is still one that
    /// can answer, and having none would stop the indexer.
    pub fn next_sources(&self, is_realtime: bool, excluded: &[usize], now: f64) -> Vec<usize> {
        let mut working_primaries = Vec::new();
        let mut all_primaries = Vec::new();
        let mut working_secondaries = Vec::new();
        let mut all_secondaries = Vec::new();
        for (index, source) in self.sources.iter().enumerate() {
            if source.disabled || excluded.contains(&index) {
                continue;
            }
            let working = self.is_working(index, now);
            match self.role_of(index, is_realtime) {
                Some(Role::Primary) => {
                    all_primaries.push(index);
                    if working {
                        working_primaries.push(index);
                    }
                }
                Some(Role::Secondary) => {
                    all_secondaries.push(index);
                    if working {
                        working_secondaries.push(index);
                    }
                }
                None => {}
            }
        }
        if !working_primaries.is_empty() {
            working_primaries
        } else if !working_secondaries.is_empty() {
            working_secondaries
        } else {
            let mut recovering = if all_primaries.is_empty() {
                all_secondaries
            } else {
                all_primaries
            };
            // Every one of them is recovering, so each has a failure to order
            // by; a source without one would have been working.
            let failed_at = |source: &usize| self.sources[*source].last_failed_at.unwrap_or(0.);
            recovering.sort_by(|a, b| failed_at(a).total_cmp(&failed_at(b)));
            recovering
        }
    }

    /// The active source when it is a candidate, so a working source is not
    /// abandoned for an equally good one.
    pub fn next_source(&self, is_realtime: bool, excluded: &[usize], now: f64) -> Option<usize> {
        let candidates = self.next_sources(is_realtime, excluded, now);
        if candidates.contains(&self.active) {
            Some(self.active)
        } else {
            candidates.first().copied()
        }
    }

    pub fn disable_source(&mut self, source: usize) -> bool {
        if self.sources[source].disabled {
            return false;
        }
        self.sources[source].disabled = true;
        self.stop_feed(source);
        if self.sources[source].spec.source_for == SourceFor::Realtime {
            self.has_realtime = self.sources.iter().enumerate().any(|(index, other)| {
                index != source && !other.disabled && other.spec.source_for == SourceFor::Realtime
            });
        }
        true
    }

    // --- Status time ---

    fn track_status(&mut self, status: Status) {
        let elapsed = self.status_start.elapsed().as_secs_f64();
        match self.status {
            Status::Idle => self.idle_seconds += elapsed,
            Status::WaitingForNewBlock => self.waiting_seconds += elapsed,
            Status::Querying => self.querying_seconds += elapsed,
        }
        self.status_start = Instant::now();
        self.status = status;
    }

    /// Includes the interval in progress, so a scrape during a long wait isn't
    /// stale until the next transition.
    pub fn seconds_in(&self, status: Status) -> f64 {
        let committed = match status {
            Status::Idle => self.idle_seconds,
            Status::WaitingForNewBlock => self.waiting_seconds,
            Status::Querying => self.querying_seconds,
        };
        if self.status == status {
            committed + self.status_start.elapsed().as_secs_f64()
        } else {
            committed
        }
    }

    pub fn in_flight(&self) -> u32 {
        self.in_flight
    }

    /// Whether the caller should start waiting for a new block for `state_id`.
    /// A wait already running for this state or a later one covers it; one for
    /// an earlier state, from before a rollback, does not.
    pub fn begin_waiting(&mut self, state_id: i64) -> bool {
        match self.waiting_for_new_block_state_id {
            Some(waiting) if waiting >= state_id => false,
            _ => {
                self.track_status(Status::WaitingForNewBlock);
                self.waiting_for_new_block_state_id = Some(state_id);
                true
            }
        }
    }

    /// Whether the wait that just ended is still the one for `state_id`, and so
    /// whether its height should be acted on.
    pub fn finish_waiting(&mut self, state_id: i64) -> bool {
        if self.waiting_for_new_block_state_id == Some(state_id) {
            self.track_status(Status::Idle);
            self.waiting_for_new_block_state_id = None;
            true
        } else {
            false
        }
    }

    pub fn queries_started(&mut self, count: u32) {
        self.in_flight += count;
        self.track_status(Status::Querying);
    }

    pub fn query_finished(&mut self) {
        self.in_flight = self.in_flight.saturating_sub(1);
        if self.in_flight == 0 {
            self.track_status(Status::Idle);
        }
    }

    // --- Rate limits ---

    pub fn rate_limit_time_ms(&self, now: f64) -> f64 {
        self.rate_limit.committed_ms
            + self
                .rate_limit
                .active_start_ms
                .map_or(0., |start| now - start)
    }

    pub fn rate_limit_reset_in_ms(&self, now: f64) -> Option<f64> {
        let remaining = self.rate_limit.active_reset_at_ms? - now;
        (remaining > 0.).then_some(remaining)
    }

    pub fn start_rate_limit(&mut self, reset_ms: u32, now: f64) {
        if self.rate_limit.waiters == 0 {
            self.rate_limit.active_start_ms = Some(now);
        }
        let reset_at = now + f64::from(reset_ms);
        self.rate_limit.active_reset_at_ms = Some(
            self.rate_limit
                .active_reset_at_ms
                .map_or(reset_at, |existing| existing.max(reset_at)),
        );
        self.rate_limit.waiters += 1;
    }

    pub fn stop_rate_limit(&mut self, now: f64) {
        self.rate_limit.waiters = self.rate_limit.waiters.saturating_sub(1);
        if self.rate_limit.waiters == 0 {
            if let Some(start) = self.rate_limit.active_start_ms.take() {
                self.rate_limit.committed_ms += now - start;
            }
            self.rate_limit.active_reset_at_ms = None;
        }
    }
}
