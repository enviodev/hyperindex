//! Which of a chain's sources answers each request, and what happens when one
//! doesn't: failover, retry schedules, rate-limit windows, the height feeds
//! and the waits for a new block.
//!
//! The core decides and keeps no time. This module runs it: its timers sleep
//! on the manager's clock, and a source built in Rust is called from here and
//! reports straight back. Everything else it asks for (calling a ReScript
//! source, settling a wait or a query) waits in an outbox for ReScript, which
//! reports how each went.

mod core;
mod feed;
mod query;
pub(crate) mod source;
mod wait;

use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    sync::{Arc, Mutex, MutexGuard, Weak},
    task::{Poll, Waker},
};

use napi::bindgen_prelude::Function;
use napi::threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode};
use napi_derive::napi;
use tokio::sync::mpsc;

pub(crate) use self::query::{HashesFailure, Inconsistent, ItemsFailure};
use self::{
    core::{Core, Effect, HeightRetry, RequestStat, SourceSpec, Status, Timing},
    source::{
        EventRegistration, HashesOutcome, HeightOutcome, ItemsOutcome, ItemsQuery, JsPage,
        NativePage, NativeSource, Selection, Source,
    },
};
use crate::address_store::AddressSet;
use crate::block_store::BlockStore;
use crate::clock::{jittered, Clock, Hold, RealClock, Sleep, VirtualClockHandle};
use crate::height_stream::{
    driver::{self, Sink, Subscription},
    machine::DownReason,
};

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
#[napi(object)]
pub struct SourceRequestStat {
    pub method: String,
    pub seconds: f64,
    pub response_blocks: Option<i64>,
}

#[napi(object, object_to_js = false)]
pub struct SourceManagerEventRegistration {
    pub index: i64,
    pub start_block: Option<i64>,
}

#[napi(object, object_to_js = false)]
pub struct SourceManagerSelection {
    pub on_event_registrations: Vec<SourceManagerEventRegistration>,
    pub on_block_registration_indexes: Vec<i64>,
    pub client_filtered_contracts: Option<Vec<String>>,
}

impl From<SourceManagerSelection> for Selection {
    fn from(selection: SourceManagerSelection) -> Self {
        Selection {
            on_event_registrations: selection
                .on_event_registrations
                .into_iter()
                .map(|registration| EventRegistration {
                    index: registration.index,
                    start_block: registration.start_block,
                })
                .collect(),
            on_block_registration_indexes: selection.on_block_registration_indexes,
            client_filtered_contracts: selection.client_filtered_contracts,
        }
    }
}

/// Everything a source needs to answer any attempt at the query.
#[napi(object, object_to_js = false)]
pub struct SourceManagerItemsQuery {
    pub from_block: i64,
    pub to_block: Option<i64>,
    pub partition_id: String,
    pub known_height: i64,
    pub reorgable_from: Option<i64>,
    pub items_target: Option<u32>,
    pub selection: SourceManagerSelection,
}

impl From<ItemsFailure> for SourceItemsFailure {
    fn from(failure: ItemsFailure) -> Self {
        match failure {
            ItemsFailure::RateLimited { reset_ms } => SourceItemsFailure::RateLimited { reset_ms },
            ItemsFailure::BehindHead { block_number } => {
                SourceItemsFailure::BehindHead { block_number }
            }
            ItemsFailure::FieldSelection {
                message,
                block_number,
            } => SourceItemsFailure::FieldSelection {
                message,
                block_number,
            },
            ItemsFailure::SuggestedToBlock {
                to_block,
                attempted_to_block,
            } => SourceItemsFailure::SuggestedToBlock {
                to_block,
                attempted_to_block,
            },
            ItemsFailure::Impossible {
                message,
                attempted_to_block,
            } => SourceItemsFailure::Impossible {
                message,
                attempted_to_block,
            },
            ItemsFailure::Backoff {
                message,
                backoff_millis,
                attempted_to_block,
            } => SourceItemsFailure::Backoff {
                message,
                backoff_millis,
                attempted_to_block,
            },
        }
    }
}

fn from_request_stats(stats: Vec<RequestStat>) -> Vec<SourceRequestStat> {
    stats
        .into_iter()
        .map(|stat| SourceRequestStat {
            method: stat.method,
            seconds: stat.seconds,
            response_blocks: stat.response_blocks,
        })
        .collect()
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
    /// `err` names the failure the call that led here reported; a source built
    /// in Rust describes its own as `err_message`.
    Log {
        fields_json: Option<String>,
        level: String,
        message: String,
        params_json: Option<String>,
        err: Option<u32>,
        err_message: Option<String>,
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
    /// `native_source` is the source built in Rust whose page `take_items_page`
    /// or `take_hashes_page` hands over; absent when ReScript holds the answer.
    Resolve {
        request: u32,
        native_source: Option<u32>,
    },
    /// `cause` is what a source built in Rust failed with.
    Reject {
        request: u32,
        message: String,
        cause: Option<String>,
    },
}

impl SourceManagerEffect {
    /// Only for what ReScript carries out.
    fn from_core(effect: Effect) -> Self {
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
                err_message: None,
            },
            Effect::ArmTimer { .. } | Effect::ClearTimer { .. } => {
                unreachable!("timers run in Rust")
            }
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
            Effect::Resolve { request } => SourceManagerEffect::Resolve {
                request,
                native_source: None,
            },
            Effect::Reject { request, message } => SourceManagerEffect::Reject {
                request,
                message,
                cause: None,
            },
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

/// What an items query was started with, for a source built in Rust to answer
/// any of its attempts.
struct QueryContext {
    from_block: i64,
    known_height: i64,
    reorgable_from: Option<i64>,
    partition_id: String,
    selection: Arc<Selection>,
    items_target: Option<u32>,
    addresses: AddressSet,
}

enum RequestContext {
    Items(QueryContext),
    Hashes(Vec<i64>),
}

/// What a source built in Rust answered with, before JavaScript takes it.
enum Answer {
    Items(Box<dyn JsPage>),
    Hashes(BlockStore),
}

/// What a source built in Rust came back with, applied in the order it came.
enum Event {
    Height {
        request: u32,
        outcome: HeightOutcome,
    },
    Items {
        request: u32,
        source: usize,
        outcome: ItemsOutcome,
    },
    Hashes {
        request: u32,
        source: usize,
        outcome: HashesOutcome,
    },
    StreamHeight {
        source: usize,
        stream: u32,
        height: i64,
    },
    StreamStatus {
        source: usize,
        stream: u32,
        down: Option<DownReason>,
        detail: Option<String>,
    },
}

type Events = mpsc::UnboundedSender<(Event, Hold)>;

/// Ids for the failures a source built in Rust reports, clear of the ones
/// ReScript hands over.
const FIRST_NATIVE_ERROR: u32 = 1 << 31;

enum Queued {
    /// Carried out here once it reaches the front.
    Here(Effect),
    ForJs(SourceManagerEffect),
}

struct Inner {
    core: Core,
    clock: Arc<dyn Clock>,
    timers: Timers,
    /// What the core asked for and nobody has carried out yet, in the order it
    /// is owed. JavaScript drains it; what runs here waits behind whatever
    /// JavaScript has still to do, so the two sides act in the core's order.
    outbox: VecDeque<Queued>,
    /// Tells JavaScript there is something in the outbox, when it wasn't the
    /// one that just called in.
    poke: Callback,
    stopped: bool,
    natives: Vec<Option<Arc<dyn Source>>>,
    requests: HashMap<u32, RequestContext>,
    answers: HashMap<u32, (usize, Answer)>,
    /// Each open stream with the id its reports carry, so a closed stream's
    /// last reports can't pass for a newer one's.
    streams: HashMap<usize, (u32, Subscription)>,
    next_stream: u32,
    errors: HashMap<u32, String>,
    next_error: u32,
    events: Events,
}

/// Weak, so a manager nobody shut down doesn't keep the process alive.
type Callback = ThreadsafeFunction<(), (), (), napi::Status, false, true>;

impl Inner {
    /// Takes what the last call left. What runs here runs at once when nothing
    /// is waiting ahead of it; everything else waits for JavaScript.
    fn pump(&mut self) {
        while let Some(effect) = self.core.take_effect() {
            if self.runs_here(&effect) {
                if self.outbox.is_empty() {
                    self.run_here(effect);
                } else {
                    self.outbox.push_back(Queued::Here(effect));
                }
            } else {
                let effect = self.for_js(effect);
                self.outbox.push_back(Queued::ForJs(effect));
            }
        }
    }

    /// The next effect JavaScript has to carry out, running what is queued
    /// ahead of it here on the way.
    fn next_for_js(&mut self) -> Option<SourceManagerEffect> {
        while let Some(queued) = self.outbox.pop_front() {
            match queued {
                Queued::Here(effect) => self.run_here(effect),
                Queued::ForJs(effect) => return Some(effect),
            }
        }
        None
    }

    fn native(&self, source: usize) -> Option<Arc<dyn Source>> {
        self.natives.get(source).cloned().flatten()
    }

    fn runs_here(&self, effect: &Effect) -> bool {
        match effect {
            Effect::ArmTimer { .. } | Effect::ClearTimer { .. } => true,
            Effect::RequestHeight { source, .. }
            | Effect::SubscribeStream { source }
            | Effect::CloseStream { source }
            | Effect::Reorg { source }
            | Effect::Attempt { source, .. } => self.native(*source).is_some(),
            _ => false,
        }
    }

    /// Converted as it is queued, so a failure it names is described while it
    /// is still held.
    fn for_js(&mut self, effect: Effect) -> SourceManagerEffect {
        match effect {
            Effect::Log { err, .. } => {
                let err_message = err.and_then(|err| self.errors.get(&err).cloned());
                match SourceManagerEffect::from_core(effect) {
                    SourceManagerEffect::Log {
                        fields_json,
                        level,
                        message,
                        params_json,
                        ..
                    } if err_message.is_some() => SourceManagerEffect::Log {
                        fields_json,
                        level,
                        message,
                        params_json,
                        err: None,
                        err_message,
                    },
                    effect => effect,
                }
            }
            // An answer an earlier attempt left is not this one's.
            Effect::Attempt { request, .. } => {
                self.answers.remove(&request);
                SourceManagerEffect::from_core(effect)
            }
            Effect::Resolve { request } => {
                self.requests.remove(&request);
                SourceManagerEffect::Resolve {
                    request,
                    native_source: self.answers.get(&request).map(|(source, _)| *source as u32),
                }
            }
            Effect::Reject { request, .. } => {
                self.requests.remove(&request);
                self.answers.remove(&request);
                SourceManagerEffect::from_core(effect)
            }
            effect => SourceManagerEffect::from_core(effect),
        }
    }

    fn run_here(&mut self, effect: Effect) {
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
            Effect::RequestHeight { request, source } => {
                let call = self.native(source).expect("checked").get_height();
                self.deliver(async move {
                    Event::Height {
                        request,
                        outcome: call.await,
                    }
                });
            }
            Effect::SubscribeStream { source } => {
                let transport = self
                    .native(source)
                    .and_then(|native| native.height_transport())
                    .expect("the core streams only a source that can push heights");
                self.next_stream += 1;
                let stream = self.next_stream;
                let subscription = driver::subscribe(
                    transport,
                    self.clock.clone(),
                    Arc::new(ManagerSink {
                        source,
                        stream,
                        clock: self.clock.clone(),
                        events: self.events.clone(),
                    }),
                );
                self.streams.insert(source, (stream, subscription));
            }
            Effect::CloseStream { source } => {
                self.streams.remove(&source);
            }
            Effect::Reorg { source } => self.native(source).expect("checked").on_reorg(),
            Effect::Attempt {
                request,
                source,
                to_block,
                retry,
                ..
            } => {
                self.answers.remove(&request);
                let native = self.native(source).expect("checked");
                match self.requests.get(&request) {
                    Some(RequestContext::Items(context)) => {
                        let call = native.get_items(ItemsQuery {
                            from_block: context.from_block,
                            to_block,
                            known_height: context.known_height,
                            reorgable_from: context.reorgable_from,
                            partition_id: context.partition_id.clone(),
                            selection: context.selection.clone(),
                            items_target: context.items_target,
                            retry,
                            addresses: context.addresses.share(),
                        });
                        self.deliver(async move {
                            Event::Items {
                                request,
                                source,
                                outcome: call.await,
                            }
                        });
                    }
                    Some(RequestContext::Hashes(block_numbers)) => {
                        let call = native.get_block_hashes(block_numbers.clone());
                        self.deliver(async move {
                            Event::Hashes {
                                request,
                                source,
                                outcome: call.await,
                            }
                        });
                    }
                    None => unreachable!("an attempt is made only for a live request"),
                }
            }
            _ => unreachable!("only what runs here gets here"),
        }
    }

    /// Runs a source's call off the lock. Its answer counts as work in progress
    /// on the clock from the moment it arrives until the core has taken it.
    fn deliver(&self, call: impl std::future::Future<Output = Event> + Send + 'static) {
        let clock = self.clock.clone();
        let events = self.events.clone();
        napi::bindgen_prelude::spawn(async move {
            let event = call.await;
            let _ = events.send((event, clock.hold()));
        });
    }

    fn hold_error(&mut self, cause: String) -> u32 {
        let id = self.next_error;
        self.next_error = self.next_error.wrapping_add(1).max(FIRST_NATIVE_ERROR);
        self.errors.insert(id, cause);
        id
    }

    fn apply(&mut self, event: Event) {
        let now = self.now();
        match event {
            Event::Height { request, outcome } => {
                if !self.core.height_requests.contains_key(&request) {
                    return;
                }
                match outcome {
                    HeightOutcome::Answered { height, stats } => {
                        self.core.height_answered(request, height, &stats);
                    }
                    HeightOutcome::Failed {
                        stats,
                        cause,
                        alert,
                    } => {
                        if let Some(alert) = alert {
                            self.core
                                .log(None, core::Level::Error, alert, serde_json::Value::Null);
                        }
                        let err = self.hold_error(cause);
                        self.core.height_failed(request, &stats, Some(err));
                    }
                }
            }
            Event::Items {
                request,
                source,
                outcome,
            } => {
                if !self.core.requests.contains_key(&request) {
                    return;
                }
                match outcome {
                    ItemsOutcome::Answered {
                        known_height,
                        stats,
                        inconsistent,
                        page,
                    } => {
                        self.answers.insert(request, (source, Answer::Items(page)));
                        self.core
                            .items_answered(request, known_height, &stats, inconsistent, now);
                    }
                    ItemsOutcome::Failed {
                        failure,
                        stats,
                        cause,
                    } => {
                        let err = cause.map(|cause| self.hold_error(cause));
                        self.core.items_failed(request, failure, &stats, err, now);
                    }
                    ItemsOutcome::Unexpected { cause } => {
                        self.core.abandon_request(request);
                        self.requests.remove(&request);
                        self.pump();
                        self.outbox
                            .push_back(Queued::ForJs(SourceManagerEffect::Reject {
                                request,
                                message: "Failed to fetch block Range".to_string(),
                                cause: Some(cause),
                            }));
                    }
                }
            }
            Event::Hashes {
                request,
                source,
                outcome,
            } => {
                if !self.core.requests.contains_key(&request) {
                    return;
                }
                match outcome {
                    HashesOutcome::Answered {
                        stats,
                        inconsistent,
                        blocks,
                    } => {
                        self.answers
                            .insert(request, (source, Answer::Hashes(blocks)));
                        self.core
                            .hashes_answered(request, &stats, inconsistent, now);
                    }
                    HashesOutcome::Failed {
                        failure,
                        stats,
                        cause,
                    } => {
                        let err = self.hold_error(cause);
                        self.core
                            .hashes_failed(request, failure, &stats, Some(err), now);
                    }
                }
            }
            Event::StreamHeight {
                source,
                stream,
                height,
            } => {
                if self.is_current_stream(source, stream) {
                    self.core.stream_height(source, height);
                }
            }
            Event::StreamStatus {
                source,
                stream,
                down,
                detail,
            } => {
                if self.is_current_stream(source, stream) {
                    match down {
                        None => self.core.stream_live(source),
                        Some(reason) => self.core.stream_down(source, &reason.label(), detail),
                    }
                }
            }
        }
        self.pump();
        self.errors.clear();
    }

    fn is_current_stream(&self, source: usize, stream: u32) -> bool {
        self.streams
            .get(&source)
            .is_some_and(|(current, _)| *current == stream)
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

/// A stream's reports, queued for the manager like every other answer.
struct ManagerSink {
    source: usize,
    stream: u32,
    clock: Arc<dyn Clock>,
    events: Events,
}

impl Sink for ManagerSink {
    fn height(&self, height: i64) {
        let _ = self.events.send((
            Event::StreamHeight {
                source: self.source,
                stream: self.stream,
                height,
            },
            self.clock.hold(),
        ));
    }

    fn status(&self, down: Option<DownReason>, detail: Option<String>) {
        let _ = self.events.send((
            Event::StreamStatus {
                source: self.source,
                stream: self.stream,
                down,
                detail,
            },
            self.clock.hold(),
        ));
    }
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

/// Applies what sources built in Rust came back with, in the order it came.
async fn run_events(inner: Weak<Mutex<Inner>>, mut events: mpsc::UnboundedReceiver<(Event, Hold)>) {
    while let Some((event, hold)) = events.recv().await {
        let Some(inner) = inner.upgrade() else {
            return;
        };
        let mut inner = lock(&inner);
        if inner.stopped {
            return;
        }
        inner.apply(event);
        inner.poke();
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
        let specs: Vec<SourceSpec> = sources
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
        let source_count = specs.len();
        let core = Core::new(specs, is_realtime, timing.unwrap_or_default().into())
            .map_err(napi::Error::from_reason)?;
        let (events, received) = mpsc::unbounded_channel();
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
            natives: vec![None; source_count],
            requests: HashMap::new(),
            answers: HashMap::new(),
            streams: HashMap::new(),
            next_stream: 0,
            errors: HashMap::new(),
            next_error: FIRST_NATIVE_ERROR,
            events,
        }));
        napi::bindgen_prelude::spawn(run_timers(Arc::downgrade(&inner)));
        napi::bindgen_prelude::spawn(run_events(Arc::downgrade(&inner), received));
        Ok(SourceManager { inner })
    }

    /// Has the manager call the source at `index` itself. Made before any
    /// request, so every effect naming it runs here.
    #[napi(catch_unwind)]
    pub fn attach_source(&self, index: u32, source: &NativeSource) {
        lock(&self.inner).natives[index as usize] = Some(source.source.clone());
    }

    /// The page a source built in Rust answered `request` with.
    #[napi(catch_unwind)]
    pub fn take_items_page(&self, request: u32) -> Option<NativePage> {
        match lock(&self.inner).answers.remove(&request) {
            Some((_, Answer::Items(page))) => Some(NativePage(page)),
            _ => None,
        }
    }

    #[napi(catch_unwind)]
    pub fn take_hashes_page(&self, request: u32) -> Option<BlockStore> {
        match lock(&self.inner).answers.remove(&request) {
            Some((_, Answer::Hashes(blocks))) => Some(blocks),
            _ => None,
        }
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
        query: SourceManagerItemsQuery,
        addresses: &AddressSet,
        is_realtime: bool,
    ) -> u32 {
        let mut inner = lock(&self.inner);
        let now = inner.now();
        let SourceManagerItemsQuery {
            from_block,
            to_block,
            partition_id,
            known_height,
            reorgable_from,
            items_target,
            selection,
        } = query;
        // Known before the first attempt runs, which may be on a source here.
        let request = inner.core.next_request_id();
        inner.requests.insert(
            request,
            RequestContext::Items(QueryContext {
                from_block,
                known_height,
                reorgable_from,
                partition_id: partition_id.clone(),
                selection: Arc::new(selection.into()),
                items_target,
                addresses: addresses.share(),
            }),
        );
        let started = inner.core.start_items_query(
            from_block,
            to_block,
            partition_id,
            addresses.size() as u32,
            is_realtime,
            now,
        );
        debug_assert_eq!(started, request);
        inner.pump();
        request
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
    pub fn start_block_hashes(&self, block_numbers: Vec<i64>, is_realtime: bool) -> u32 {
        let mut inner = lock(&self.inner);
        let now = inner.now();
        let request = inner.core.next_request_id();
        inner
            .requests
            .insert(request, RequestContext::Hashes(block_numbers));
        let started = inner.core.start_block_hashes(is_realtime, now);
        debug_assert_eq!(started, request);
        inner.pump();
        request
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
        let mut inner = lock(&self.inner);
        inner.requests.remove(&request);
        inner.answers.remove(&request);
        inner.core.abandon_request(request);
        inner.pump();
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
        inner.streams.clear();
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
