//! Which of a chain's sources answers each request, and what happens when one
//! doesn't: failover, retry schedules, rate-limit windows, the height feeds
//! and the waits for a new block.
//!
//! The core decides and keeps no time. This module runs it: its timers sleep
//! on the manager's clock, and everything else it asks for (calling a source,
//! settling a wait or a query) waits in an outbox for ReScript, which reports
//! how each went.

mod core;
mod feed;
mod query;
mod wait;

use std::{
    collections::{BTreeMap, VecDeque},
    sync::{Arc, Mutex, MutexGuard, Weak},
    task::{Poll, Waker},
};

use napi::bindgen_prelude::Function;
use napi::threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode};
use napi_derive::napi;

use self::{
    core::{Core, Effect, HeightRetry, RequestStat, SourceSpec, Status, Timing},
    query::{HashesFailure, Inconsistent, ItemsFailure},
};
use crate::block_store::BlockStore;
use crate::clock::{jittered, Clock, RealClock, Sleep, VirtualClockHandle};

#[napi(string_enum, object_to_js = false)]
pub enum SourceFor {
    Sync,
    Fallback,
    Realtime,
}

#[napi(object, object_to_js = false)]
pub struct SourceManagerSource {
    pub name: String,
    pub source_for: SourceFor,
    pub polling_interval: u32,
    /// Whether the source can push heights over a subscription.
    pub can_stream: bool,
}

/// Every field defaults to the production value. Only tests set them, to reach
/// a stall, a recovery or a retry schedule without waiting out the real window.
#[napi(object, object_to_js = false)]
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
#[napi(object, object_to_js = false)]
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

#[napi(discriminant = "kind", object_from_js = false)]
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

#[napi(discriminant = "kind", object_to_js = false)]
pub enum SourceItemsFailure {
    RateLimited {
        reset_ms: u32,
    },
    BehindHead {
        block_number: i64,
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
#[napi(object, object_from_js = false)]
pub struct RequestStatSample {
    pub source: u32,
    pub method: String,
    pub count: u32,
    pub seconds: f64,
    pub response_blocks: Option<i64>,
    pub empty_response_count: u32,
}

#[napi(object, object_from_js = false)]
pub struct SourceHeightSample {
    pub source: u32,
    pub height: i64,
}

#[napi(object, object_from_js = false)]
pub struct HeightStreamSample {
    pub source: u32,
    pub connect_count: u32,
    /// Sorted by reason, so the rendered order doesn't depend on which reasons
    /// a stream happened to hit first.
    pub disconnect_reasons: Vec<String>,
    pub disconnect_counts: Vec<u32>,
}

/// The timers the core armed, each sleeping on the manager's clock. Polled by
/// one task, so a cleared timer leaves the clock's queue the moment it is
/// cleared rather than whenever a task of its own would next run.
struct Timers {
    armed: BTreeMap<u32, Sleep>,
    waker: Option<Waker>,
}

struct Inner {
    core: Core,
    clock: Arc<dyn Clock>,
    timers: Timers,
    /// What the core asked for and nobody has carried out yet, in the order it
    /// is owed. JavaScript drains it; a timer waits here behind whatever
    /// JavaScript has still to do, so the two sides act in the core's order.
    outbox: VecDeque<Effect>,
    /// Tells JavaScript there is something in the outbox, when it wasn't the
    /// one that just called in.
    poke: Callback,
    stopped: bool,
}

/// Weak, so a manager nobody shut down doesn't keep the process alive.
type Callback = ThreadsafeFunction<(), (), (), napi::Status, false, true>;

impl Inner {
    /// Takes what the last call left. A timer is armed or cleared here as soon
    /// as nothing is waiting ahead of it; everything else waits for
    /// JavaScript.
    fn pump(&mut self) {
        while let Some(effect) = self.core.take_effect() {
            if self.outbox.is_empty() && is_timer(&effect) {
                self.run_timer_effect(effect);
            } else {
                self.outbox.push_back(effect);
            }
        }
    }

    /// The next effect JavaScript has to carry out, running the timers queued
    /// ahead of it on the way.
    fn next_for_js(&mut self) -> Option<SourceManagerEffect> {
        while let Some(effect) = self.outbox.pop_front() {
            if is_timer(&effect) {
                self.run_timer_effect(effect);
            } else {
                return Some(effect.into());
            }
        }
        None
    }

    fn run_timer_effect(&mut self, effect: Effect) {
        match effect {
            Effect::ArmTimer {
                timer,
                label,
                millis,
                jitter,
            } => {
                let millis = if jitter {
                    jittered(millis, self.clock.random())
                } else {
                    millis
                };
                self.timers
                    .armed
                    .insert(timer, self.clock.sleep(label, u64::from(millis)));
                if let Some(waker) = self.timers.waker.take() {
                    waker.wake();
                }
            }
            Effect::ClearTimer { timer } => {
                self.timers.armed.remove(&timer);
            }
            _ => unreachable!("only timer effects run here"),
        }
    }

    fn now(&self) -> f64 {
        self.clock.now_ms()
    }

    /// Held until JavaScript has drained the outbox, so a test's advance waits
    /// for what a timer set off.
    fn poke(&self) {
        if self.outbox.is_empty() {
            return;
        }
        let hold = self.clock.hold();
        self.poke.call_with_return_value(
            (),
            ThreadsafeFunctionCallMode::NonBlocking,
            move |_, _| {
                drop(hold);
                Ok(())
            },
        );
    }
}

fn is_timer(effect: &Effect) -> bool {
    matches!(effect, Effect::ArmTimer { .. } | Effect::ClearTimer { .. })
}

fn lock(inner: &Mutex<Inner>) -> MutexGuard<'_, Inner> {
    // A panic while holding the lock can only come from a bug in the core, and
    // what it left is still the best account of the sources.
    inner
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Fires the core's timers, one at a time, in the order they come due.
async fn run_timers(inner: Weak<Mutex<Inner>>) {
    loop {
        let fired = std::future::poll_fn(|cx| {
            let Some(inner) = inner.upgrade() else {
                return Poll::Ready(None);
            };
            let mut inner = lock(&inner);
            if inner.stopped {
                return Poll::Ready(None);
            }
            inner.timers.waker = Some(cx.waker().clone());
            let fired = inner.timers.armed.iter_mut().find_map(|(timer, sleep)| {
                match sleep.as_mut().poll(cx) {
                    Poll::Ready(hold) => Some((*timer, hold)),
                    Poll::Pending => None,
                }
            });
            match fired {
                Some((timer, hold)) => {
                    inner.timers.armed.remove(&timer);
                    Poll::Ready(Some((timer, hold)))
                }
                None => Poll::Pending,
            }
        })
        .await;
        let Some((timer, hold)) = fired else {
            return;
        };
        let Some(inner) = inner.upgrade() else {
            return;
        };
        let mut inner = lock(&inner);
        let now = inner.now();
        inner.core.timer_fired(timer, now);
        inner.pump();
        inner.poke();
        // Given back once JavaScript has been told, which holds its own.
        drop(hold);
    }
}

#[napi]
pub struct SourceManager {
    inner: Arc<Mutex<Inner>>,
}

impl SourceManager {
    /// Runs `call` on the core with the current time, then takes what it left.
    fn report<T>(&self, call: impl FnOnce(&mut Core, f64) -> T) -> T {
        let mut inner = lock(&self.inner);
        let now = inner.now();
        let result = call(&mut inner.core, now);
        inner.pump();
        result
    }

    fn read<T>(&self, read: impl FnOnce(&Core, f64) -> T) -> T {
        let inner = lock(&self.inner);
        read(&inner.core, inner.now())
    }
}

#[napi]
impl SourceManager {
    /// `clock` is a test's virtual clock; without one, real time. `on_effects`
    /// is called when a timer leaves work in the outbox.
    #[napi(factory, catch_unwind)]
    pub fn make(
        sources: Vec<SourceManagerSource>,
        is_realtime: bool,
        timing: Option<SourceManagerTiming>,
        clock: Option<&VirtualClockHandle>,
        on_effects: Function<(), ()>,
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
        let core = Core::new(specs, is_realtime, timing.unwrap_or_default().into())
            .map_err(napi::Error::from_reason)?;
        let inner = Arc::new(Mutex::new(Inner {
            core,
            clock: clock.map_or_else(RealClock::shared, VirtualClockHandle::shared),
            timers: Timers {
                armed: BTreeMap::new(),
                waker: None,
            },
            outbox: VecDeque::new(),
            poke: on_effects
                .build_threadsafe_function()
                .callee_handled::<false>()
                .weak::<true>()
                .build()?,
            stopped: false,
        }));
        napi::bindgen_prelude::spawn(run_timers(Arc::downgrade(&inner)));
        Ok(SourceManager { inner })
    }

    /// The next thing JavaScript has to do, in the order it is owed.
    #[napi(catch_unwind)]
    pub fn take_effect(&self) -> Option<SourceManagerEffect> {
        lock(&self.inner).next_for_js()
    }

    /// A `Defer` token coming back from its microtask.
    #[napi(catch_unwind)]
    pub fn timer_fired(&self, timer: u32) {
        self.report(|core, now| core.timer_fired(timer, now));
    }

    /// Resolves through a `ResolveWait` effect, which can already be queued
    /// when this returns.
    #[napi(catch_unwind)]
    pub fn wait_for_new_block(
        &self,
        known_height: i64,
        is_realtime: bool,
        reduced_polling: bool,
    ) -> u32 {
        self.report(|core, now| {
            core.wait_for_new_block(known_height, is_realtime, reduced_polling, now)
        })
    }

    #[napi(catch_unwind)]
    pub fn height_answered(&self, request: u32, height: i64, stats: Vec<SourceRequestStat>) {
        self.report(|core, _| core.height_answered(request, height, &to_request_stats(stats)));
    }

    /// The source's height call threw instead of returning a promise.
    #[napi(catch_unwind)]
    pub fn height_call_threw(&self, request: u32, err: Option<u32>) {
        self.report(|core, _| core.height_call_threw(request, err));
    }

    #[napi(catch_unwind)]
    pub fn height_failed(&self, request: u32, stats: Vec<SourceRequestStat>, err: Option<u32>) {
        self.report(|core, _| core.height_failed(request, &to_request_stats(stats), err));
    }

    #[napi(catch_unwind)]
    pub fn stream_height(&self, source: u32, height: i64) {
        self.report(|core, _| core.stream_height(source as usize, height));
    }

    #[napi(catch_unwind)]
    pub fn stream_live(&self, source: u32) {
        self.report(|core, _| core.stream_live(source as usize));
    }

    #[napi(catch_unwind)]
    pub fn stream_down(&self, source: u32, reason: String, detail: Option<String>) {
        self.report(|core, _| core.stream_down(source as usize, &reason, detail));
    }

    #[napi(catch_unwind)]
    pub fn start_items_query(
        &self,
        from_block: i64,
        to_block: Option<i64>,
        partition_id: String,
        addresses: u32,
        is_realtime: bool,
    ) -> u32 {
        self.report(|core, now| {
            core.start_items_query(
                from_block,
                to_block,
                partition_id,
                addresses,
                is_realtime,
                now,
            )
        })
    }

    /// A response is trusted only once its page has proved internally coherent.
    #[napi(catch_unwind)]
    pub fn items_answered(
        &self,
        request: u32,
        block_store: &BlockStore,
        known_height: i64,
        stats: Vec<SourceRequestStat>,
    ) {
        let inconsistent = Inconsistent::check(block_store.response_conflict(), Vec::new());
        self.report(|core, now| {
            core.items_answered(
                request,
                known_height,
                &to_request_stats(stats),
                inconsistent,
                now,
            )
        });
    }

    #[napi(catch_unwind)]
    pub fn items_failed(
        &self,
        request: u32,
        failure: SourceItemsFailure,
        stats: Vec<SourceRequestStat>,
        err: Option<u32>,
    ) {
        self.report(|core, now| {
            core.items_failed(request, failure.into(), &to_request_stats(stats), err, now)
        });
    }

    #[napi(catch_unwind)]
    pub fn start_block_hashes(&self, is_realtime: bool) -> u32 {
        self.report(|core, now| core.start_block_hashes(is_realtime, now))
    }

    /// Also rejects a response that simply omitted one of the requested hashes.
    #[napi(catch_unwind)]
    pub fn hashes_answered(
        &self,
        request: u32,
        block_store: &BlockStore,
        block_numbers: Vec<i64>,
        stats: Vec<SourceRequestStat>,
    ) {
        let inconsistent = Inconsistent::check(
            block_store.response_conflict(),
            block_store.missing_hashes(block_numbers),
        );
        self.report(|core, now| {
            core.hashes_answered(request, &to_request_stats(stats), inconsistent, now)
        });
    }

    /// A failure that is neither rate-limiting nor a source behind the head is
    /// retried on the shared schedule.
    #[napi(catch_unwind)]
    pub fn hashes_failed(
        &self,
        request: u32,
        rate_limit_reset_ms: Option<u32>,
        behind_head_block: Option<i64>,
        stats: Vec<SourceRequestStat>,
        err: Option<u32>,
    ) {
        let failure = match (rate_limit_reset_ms, behind_head_block) {
            (Some(reset_ms), _) => HashesFailure::RateLimited { reset_ms },
            (None, Some(block_number)) => HashesFailure::BehindHead { block_number },
            (None, None) => HashesFailure::Other,
        };
        self.report(|core, now| {
            core.hashes_failed(request, failure, &to_request_stats(stats), err, now)
        });
    }

    /// The attempt failed in a way nothing here can retry, and the caller
    /// raises it.
    #[napi(catch_unwind)]
    pub fn abandon_request(&self, request: u32) {
        self.report(|core, _| core.abandon_request(request));
    }

    #[napi(catch_unwind)]
    pub fn begin_waiting(&self, state_id: i64) -> bool {
        self.report(|core, _| core.begin_waiting(state_id))
    }

    #[napi(catch_unwind)]
    pub fn finish_waiting(&self, state_id: i64) -> bool {
        self.report(|core, _| core.finish_waiting(state_id))
    }

    #[napi(catch_unwind)]
    pub fn queries_started(&self, count: u32) {
        self.report(|core, _| core.queries_started(count));
    }

    #[napi(catch_unwind)]
    pub fn query_finished(&self) {
        self.report(|core, _| core.query_finished());
    }

    #[napi(catch_unwind)]
    pub fn shutdown(&self) {
        let mut inner = lock(&self.inner);
        inner.core.shut_down();
        inner.pump();
        inner.timers.armed.clear();
        inner.stopped = true;
        if let Some(waker) = inner.timers.waker.take() {
            waker.wake();
        }
    }

    #[napi(catch_unwind)]
    pub fn active_source(&self) -> u32 {
        self.read(|core, _| core.active as u32)
    }

    /// Partition queries in flight on this chain's sources. Summed across
    /// chains to enforce the indexer-wide concurrency budget.
    #[napi(catch_unwind)]
    pub fn in_flight(&self) -> u32 {
        self.read(|core, _| core.in_flight())
    }

    #[napi(catch_unwind)]
    pub fn idle_seconds(&self) -> f64 {
        self.read(|core, _| core.seconds_in(Status::Idle))
    }

    #[napi(catch_unwind)]
    pub fn waiting_for_new_block_seconds(&self) -> f64 {
        self.read(|core, _| core.seconds_in(Status::WaitingForNewBlock))
    }

    #[napi(catch_unwind)]
    pub fn querying_seconds(&self) -> f64 {
        self.read(|core, _| core.seconds_in(Status::Querying))
    }

    /// Total time spent waiting on rate limits, including a window in progress.
    #[napi(catch_unwind)]
    pub fn rate_limit_time_ms(&self) -> f64 {
        self.read(|core, now| core.rate_limit_time_ms(now))
    }

    /// Until the longest active rate-limit window resets.
    #[napi(catch_unwind)]
    pub fn rate_limit_reset_in_ms(&self) -> Option<f64> {
        self.read(|core, now| core.rate_limit_reset_in_ms(now))
    }

    #[napi(catch_unwind)]
    pub fn request_stat_samples(&self) -> Vec<RequestStatSample> {
        let inner = lock(&self.inner);
        inner
            .core
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
    #[napi(catch_unwind)]
    pub fn source_height_samples(&self) -> Vec<SourceHeightSample> {
        let inner = lock(&self.inner);
        inner
            .core
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
    #[napi(catch_unwind)]
    pub fn height_stream_samples(&self) -> Vec<HeightStreamSample> {
        let inner = lock(&self.inner);
        inner
            .core
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
