//! The current height of one source, however it arrives: pushed by a height
//! stream while one is connected, polled while one isn't. Waits register
//! interest and get answered; they never learn which path answered.
//!
//! One invariant carries this: while anybody is waiting, either a stream
//! connection this has seen deliver is covering the source, or the poll loop
//! is running. `should_poll` states it, and `sync_polling` is the only thing
//! that acts on it, so no caller has to work out which of its changes needs a
//! loop started.

use std::collections::BTreeMap;

use serde_json::json;

use super::core::{Core, Effect, Level, RequestStat, TimerId, TimerPurpose};

pub struct Waiter {
    pub wait: u32,
    /// The height this waiter has to beat.
    pub known_height: i64,
    /// The wait sat out a whole window hearing nothing from a stream that says
    /// it is connected. Per waiter, because two waits can overlap on one source
    /// after a rollback, and one giving up on the stream is not the other
    /// doing so.
    pub distrusts_stream: bool,
}

/// `Connected` is the transport's claim; `proven` is this feed having seen the
/// connection account for the head it came up on. A connect only ever
/// delivers the next block, so until a height arrives on it, or a request made
/// after it came up answers, polling has to stay.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Stream {
    /// Never asked for: the source cannot push heights, or its chain has not
    /// reached realtime. Nothing about it is worth reporting.
    NeverEnabled,
    Disconnected,
    Connected {
        proven: bool,
    },
}

/// A cadence is a choice about how often to ask a working endpoint, so
/// anything that needs an answer sooner may end it. A backoff is the wait a
/// failing endpoint earned, and ending it early is how a provider already in
/// trouble gets asked harder by the very events its trouble causes.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SleepKind {
    Cadence,
    Backoff,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Poll {
    Idle,
    Requesting {
        request: u32,
    },
    Sleeping {
        kind: SleepKind,
        timer: TimerId,
    },
    /// Its sleep ended or was cut short; the loop carries on a microtask later.
    Woken,
    /// A poll just settled. Whether to sleep `millis` or stop is decided a
    /// microtask later, behind the caller of any wait the answer settled: if
    /// that caller starts its next wait straight away, the wait joins this loop
    /// rather than starting another poll on the spot.
    Settled {
        kind: SleepKind,
        millis: u32,
    },
}

pub struct Feed {
    pub known_height: i64,
    pub waiters: Vec<Waiter>,
    pub stream: Stream,
    /// Bumped for every connection seen coming up. A height request made for
    /// one connection can land after another replaced it, and what it said
    /// about the one that asked is no longer about the one in place.
    pub generation: u32,
    pub stream_open: bool,
    pub poll: Poll,
    /// Outlives a single wait on purpose: restarting the ramp with each wait
    /// would keep an endpoint that fails every time pinned near the base delay.
    /// A poll that answers clears it.
    pub poll_retry: u32,
    pub connects: u32,
    pub disconnects: BTreeMap<String, u32>,
    /// A stopped feed never subscribes again: stopping is the verdict that
    /// benched its source.
    pub stopped: bool,
    /// Whether an operator has been told once about a stream condition that
    /// never heals on its own.
    pub unreadable_warned: bool,
    pub subscribe_rejected_warned: bool,
}

impl Default for Feed {
    fn default() -> Self {
        Feed {
            known_height: 0,
            waiters: Vec::new(),
            stream: Stream::NeverEnabled,
            generation: 0,
            stream_open: false,
            poll: Poll::Idle,
            poll_retry: 0,
            connects: 0,
            disconnects: BTreeMap::new(),
            stopped: false,
            unreadable_warned: false,
            subscribe_rejected_warned: false,
        }
    }
}

impl Feed {
    pub fn should_poll(&self) -> bool {
        !self.waiters.is_empty()
            && match self.stream {
                Stream::NeverEnabled | Stream::Disconnected => true,
                Stream::Connected { proven } => {
                    !proven || self.waiters.iter().any(|waiter| waiter.distrusts_stream)
                }
            }
    }

    fn trust_stream_again(&mut self) {
        for waiter in &mut self.waiters {
            waiter.distrusts_stream = false;
        }
    }

    /// The source answered, so the wait its failures earned is no longer owed,
    /// including one being slept.
    fn clear_backoff(&mut self) {
        self.poll_retry = 0;
        if let Poll::Sleeping { kind, .. } = &mut self.poll {
            *kind = SleepKind::Cadence;
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum HeightPurpose {
    Poll,
    /// The one request made with nobody waiting: a connect leaves the heights
    /// emitted before it unaccounted for, and an idle chain would otherwise sit
    /// on a stale head until the next block.
    CatchUp,
}

pub struct HeightRequest {
    pub source: usize,
    pub purpose: HeightPurpose,
    pub generation: u32,
    pub timeout: Option<TimerId>,
    /// The caller stopped waiting. The request itself is not cancelled and a
    /// late answer is still the head the endpoint had.
    pub timed_out: bool,
}

impl Core {
    fn feed_log_fields(&self, source: usize) -> serde_json::Value {
        json!({ "source": self.sources[source].spec.name })
    }

    /// Registers a wait's interest in a height above `known_height`, or answers
    /// it on the spot from a height the source already knows.
    pub fn add_waiter(&mut self, source: usize, wait: u32, known_height: i64) {
        let height = self.sources[source].feed.known_height;
        if height > known_height {
            self.settle_wait(wait, source, height);
        } else {
            self.sources[source].feed.waiters.push(Waiter {
                wait,
                known_height,
                distrusts_stream: false,
            });
            self.sync_polling(source);
        }
    }

    /// Idempotent, so a wait can drop all of its waiters, including one already
    /// answered.
    pub fn remove_waiters_of(&mut self, source: usize, wait: u32) {
        self.sources[source]
            .feed
            .waiters
            .retain(|waiter| waiter.wait != wait);
        self.wake_cadence(source);
    }

    /// Stop taking a connected stream's word for it and poll alongside it until
    /// it delivers. A transport whose keep-alives flow while its heights stop
    /// is the one failure its own staleness detector cannot see.
    pub fn distrust_stream(&mut self, source: usize, wait: u32) {
        let feed = &mut self.sources[source].feed;
        if !matches!(feed.stream, Stream::Connected { .. }) {
            return;
        }
        let mut changed = false;
        for waiter in feed.waiters.iter_mut().filter(|w| w.wait == wait) {
            if !waiter.distrusts_stream {
                waiter.distrusts_stream = true;
                changed = true;
            }
        }
        if changed {
            self.sync_polling(source);
        }
    }

    /// The only thing that acts on `should_poll`.
    pub fn sync_polling(&mut self, source: usize) {
        let feed = &self.sources[source].feed;
        if feed.should_poll() && feed.poll == Poll::Idle {
            self.poll_now(source);
        } else {
            // Either there is less to do and the loop should notice, or more and
            // it should stop sleeping through it.
            self.wake_cadence(source);
        }
    }

    /// Ends a sleep that is only a cadence and leaves a backoff alone.
    pub fn wake_cadence(&mut self, source: usize) {
        if let Poll::Sleeping {
            kind: SleepKind::Cadence,
            timer,
        } = self.sources[source].feed.poll
        {
            self.clear_timer(&mut Some(timer));
            self.poll_sleep_ended(source);
        }
    }

    pub fn resume_poll_loop(&mut self, source: usize) {
        if self.sources[source].feed.poll != Poll::Woken {
            return;
        }
        if self.sources[source].feed.should_poll() {
            self.poll_now(source);
        } else {
            self.sources[source].feed.poll = Poll::Idle;
        }
    }

    pub fn poll_sleep_ended(&mut self, source: usize) {
        self.sources[source].feed.poll = Poll::Woken;
        self.defer(TimerPurpose::PollResume { source });
    }

    fn poll_now(&mut self, source: usize) {
        let request = self.request_height(source, HeightPurpose::Poll);
        self.sources[source].feed.poll = Poll::Requesting { request };
    }

    fn request_height(&mut self, source: usize, purpose: HeightPurpose) -> u32 {
        let request = self.next_id();
        self.height_requests.insert(
            request,
            HeightRequest {
                source,
                purpose,
                generation: self.sources[source].feed.generation,
                timeout: None,
                timed_out: false,
            },
        );
        self.emit(Effect::RequestHeight { request, source });
        // A call that never settles would otherwise stop the height moving for
        // the rest of the process: one loop covers the feed, one request at a
        // time.
        let timeout = self.arm_timer(
            TimerPurpose::PollTimeout { request },
            "height poll timeout",
            self.timing.height_poll_timeout,
            false,
        );
        if let Some(entry) = self.height_requests.get_mut(&request) {
            entry.timeout = Some(timeout);
        }
        request
    }

    fn sleep_poll_loop(&mut self, source: usize, kind: SleepKind, millis: u32) {
        let label = match kind {
            SleepKind::Cadence => "height poll cadence",
            SleepKind::Backoff => "height poll backoff",
        };
        let timer = self.arm_timer(TimerPurpose::PollSleep { source }, label, millis, false);
        self.sources[source].feed.poll = Poll::Sleeping { kind, timer };
    }

    /// After a poll: the source's own cadence after an answer, the escalating
    /// backoff a failing endpoint earned otherwise.
    fn continue_poll_loop(&mut self, source: usize, kind: SleepKind, millis: u32) {
        self.sources[source].feed.poll = Poll::Settled { kind, millis };
        self.defer(TimerPurpose::PollSettled { source });
    }

    pub fn poll_settled(&mut self, source: usize) {
        let Poll::Settled { kind, millis } = self.sources[source].feed.poll else {
            return;
        };
        if self.sources[source].feed.should_poll() {
            self.sleep_poll_loop(source, kind, millis);
        } else {
            self.sources[source].feed.poll = Poll::Idle;
        }
    }

    fn wait_interval(&self, wait: u32, source: usize) -> u32 {
        match self.waits.get(&wait) {
            Some(wait) if wait.reduced_polling => self.timing.reduced_polling_interval,
            Some(wait) if wait.stalled => self.timing.stalled_polling_interval,
            _ => self.sources[source].spec.polling_interval,
        }
    }

    /// The shortest cadence any waiter asked for, so a wait that only needs a
    /// slow poll doesn't stretch the one a faster wait is sitting on.
    fn current_interval(&self, source: usize) -> u32 {
        self.sources[source]
            .feed
            .waiters
            .iter()
            .map(|waiter| self.wait_interval(waiter.wait, source))
            .min()
            .unwrap_or(self.sources[source].spec.polling_interval)
    }

    fn back_off(&mut self, source: usize, what: String, err: Option<u32>) -> u32 {
        let feed = &mut self.sources[source].feed;
        let retry_interval = self.timing.height_retry.millis_for_retry(feed.poll_retry);
        feed.poll_retry += 1;
        let message = format!(
            "Height retrieval from {} source {what}. Retrying in {retry_interval}ms.",
            self.sources[source].spec.name
        );
        self.log_with_err(
            Some(self.feed_log_fields(source)),
            Level::Trace,
            message,
            json!({}),
            err,
        );
        retry_interval
    }

    pub fn record_height(&mut self, source: usize, height: i64) {
        let feed = &mut self.sources[source].feed;
        if height <= feed.known_height {
            return;
        }
        feed.known_height = height;
        let (satisfied, rest): (Vec<Waiter>, Vec<Waiter>) = std::mem::take(&mut feed.waiters)
            .into_iter()
            .partition(|waiter| height > waiter.known_height);
        feed.waiters = rest;
        if satisfied.is_empty() {
            return;
        }
        for waiter in satisfied {
            self.settle_wait(waiter.wait, source, height);
        }
        self.wake_cadence(source);
    }

    /// What an answer means for the feed, whoever asked for it: the endpoint
    /// responded, and with the head.
    fn record_answer(&mut self, source: usize, generation: u32, height: i64) {
        let feed = &mut self.sources[source].feed;
        feed.clear_backoff();
        // Closes a connect's gap too, as long as it was asked after the
        // connection in place came up.
        if matches!(feed.stream, Stream::Connected { .. }) && generation == feed.generation {
            feed.stream = Stream::Connected { proven: true };
        }
        self.record_height(source, height);
        self.wake_cadence(source);
    }

    pub fn height_answered(&mut self, request: u32, height: i64, stats: &[RequestStat]) {
        let Some(mut entry) = self.height_requests.remove(&request) else {
            return;
        };
        let source = entry.source;
        self.sources[source].record_request_stats(stats);
        if entry.timed_out {
            // Paid for and real, but taking longer than the whole timeout is the
            // endpoint being unwell, so it doesn't clear the ramp.
            self.record_height(source, height);
            return;
        }
        self.clear_timer(&mut entry.timeout);
        self.record_answer(source, entry.generation, height);
        if entry.purpose == HeightPurpose::Poll {
            let interval = self.current_interval(source);
            self.continue_poll_loop(source, SleepKind::Cadence, interval);
        }
    }

    /// `stats` are the requests the failed call did make: billed whether or
    /// not it answered.
    pub fn height_failed(&mut self, request: u32, stats: &[RequestStat], err: Option<u32>) {
        let Some(mut entry) = self.height_requests.remove(&request) else {
            return;
        };
        if entry.timed_out {
            return;
        }
        self.clear_timer(&mut entry.timeout);
        let source = entry.source;
        if entry.purpose == HeightPurpose::Poll {
            self.sources[source].record_request_stats(stats);
            let interval = self.back_off(source, "failed".to_string(), err);
            self.continue_poll_loop(source, SleepKind::Backoff, interval);
        }
    }

    pub fn height_request_timed_out(&mut self, request: u32) {
        let Some(entry) = self.height_requests.get_mut(&request) else {
            return;
        };
        entry.timed_out = true;
        entry.timeout = None;
        let (source, purpose) = (entry.source, entry.purpose);
        if purpose == HeightPurpose::Poll {
            let what = format!(
                "did not answer within {}s",
                self.timing.height_poll_timeout / 1000
            );
            let interval = self.back_off(source, what, None);
            self.continue_poll_loop(source, SleepKind::Backoff, interval);
        }
    }

    pub fn stream_height(&mut self, source: usize, height: i64) {
        let feed = &mut self.sources[source].feed;
        let advances = height > feed.known_height;
        self.sources[source].record_request_stats(&[RequestStat {
            method: if advances {
                "heightPush"
            } else {
                "heightPushIgnored"
            }
            .to_string(),
            seconds: 0.,
            response_blocks: None,
        }]);
        let feed = &mut self.sources[source].feed;
        // A height that advances accounts for a connect's gap. One that doesn't
        // is the head a stream re-emits on reconnect, but either way it is the
        // stream delivering and the source answering at all.
        feed.clear_backoff();
        if advances && matches!(feed.stream, Stream::Connected { .. }) {
            feed.stream = Stream::Connected { proven: true };
        }
        feed.trust_stream_again();
        self.record_height(source, height);
        self.wake_cadence(source);
    }

    /// Everything a connection going away means, whether the stream reported
    /// it or this feed closed it.
    fn mark_stream_down(&mut self, source: usize, reason: &str) {
        let feed = &mut self.sources[source].feed;
        let had_connection = matches!(feed.stream, Stream::Connected { .. });
        feed.stream = Stream::Disconnected;
        // A stream that is down stays down through every failed retry, and each
        // reports Down again: counting those would measure how long an outage
        // lasted rather than how many there were.
        if had_connection {
            *feed.disconnects.entry(reason.to_string()).or_insert(0) += 1;
            feed.trust_stream_again();
            self.sync_polling(source);
        }
    }

    pub fn stream_live(&mut self, source: usize) {
        let feed = &mut self.sources[source].feed;
        if matches!(feed.stream, Stream::Connected { .. }) {
            return;
        }
        feed.stream = Stream::Connected { proven: false };
        feed.generation += 1;
        feed.connects += 1;
        // Live is a claim, not a delivery: polling keeps covering the source
        // until the head this connection came up above is accounted for. A loop
        // sleeping off a backoff stays asleep: the endpoint that just accepted a
        // socket is the one whose height calls are failing.
        self.sync_polling(source);
        if self.sources[source].feed.poll == Poll::Idle {
            self.request_height(source, HeightPurpose::CatchUp);
        }
    }

    /// `reason` is the transport's bounded label for why the connection ended.
    pub fn stream_down(&mut self, source: usize, reason: &str, detail: Option<String>) {
        self.mark_stream_down(source, reason);
        let feed = &mut self.sources[source].feed;
        // An outage is the indexer's to absorb, so these go out at trace, except
        // the two that never heal on their own, once each.
        let level = match reason {
            "unreadable" if !feed.unreadable_warned => {
                feed.unreadable_warned = true;
                Level::Warn
            }
            // Refused before a connection was ever accepted: the url cannot
            // serve heights, and retrying won't change that.
            "subscribe-rejected" if !feed.subscribe_rejected_warned && feed.connects == 0 => {
                feed.subscribe_rejected_warned = true;
                Level::Warn
            }
            _ => Level::Trace,
        };
        let message = format!(
            "Height subscription for {} source went down ({reason}). Polling for the height until it reconnects.",
            self.sources[source].spec.name
        );
        let mut params = json!({ "reason": reason });
        if let Some(detail) = detail {
            params["detail"] = json!(detail);
        }
        self.log(Some(self.feed_log_fields(source)), level, message, params);
    }

    /// Lazy: subscribes when a realtime wait starts wanting heights. Idempotent,
    /// because after a rollback two waits reach this for the same source.
    pub fn enable_stream(&mut self, source: usize) {
        let state = &mut self.sources[source];
        if !state.spec.can_stream || state.feed.stream_open || state.feed.stopped {
            return;
        }
        if state.feed.stream == Stream::NeverEnabled {
            state.feed.stream = Stream::Disconnected;
        }
        state.feed.stream_open = true;
        self.emit(Effect::SubscribeStream { source });
    }

    pub fn stop_feed(&mut self, source: usize) {
        let feed = &mut self.sources[source].feed;
        feed.stopped = true;
        if feed.stream_open {
            feed.stream_open = false;
            self.emit(Effect::CloseStream { source });
            // Counted like any other disconnect, or the source would report a
            // stream still delivering. Whoever is still waiting keeps being
            // polled for: the source can still answer a height poll.
            self.mark_stream_down(source, "unsubscribed");
        }
    }
}
