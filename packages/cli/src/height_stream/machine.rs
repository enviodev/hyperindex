//! Retries, staleness detection and status reporting for one height
//! subscription. A transport connects a socket and reports what it sees; this
//! decides what happens next, so SSE and WebSocket streams behave identically.
//! It performs no IO and keeps no time: the driver connects, closes and arms
//! timers when told to.
//!
//! Nothing here logs. A height stream failing is not something an operator has
//! to act on — the indexer polls for the height instead — so a failure travels
//! out as a status, where its reason becomes a metric label.

use std::collections::VecDeque;

/// While a stream is down its consumer polls instead, so the retry delay is
/// what that fallback costs: a load balancer rotating a connection heals on
/// the first retry. Small first step, doubling to protect an endpoint that is
/// genuinely in trouble.
const BASE_RETRY_MILLIS: u32 = 250;
const MAX_RETRY_MILLIS: u32 = 60_000;
/// How long a connection has to serve to have been worth making, as a
/// fraction of the staleness window. Both transports deliver something the
/// moment they connect, so an endpoint that accepts and drops produces
/// everything a working one would have by then, and only staying up tells them
/// apart.
const PROVEN_STALE_FRACTION: u32 = 4;
/// A frame nobody could read ends up in a log line, so cap what a provider can
/// put there. In UTF-16 units, as the JavaScript that reads it counts.
const MAX_DETAIL_LENGTH: usize = 200;

/// The wait that follows `count` consecutive failures. Deterministic: the bar a
/// connection has to clear to count as proven is derived from it, and a
/// jittered bar would make the rotated/closed split depend on a coin flip.
fn retry_delay_for_failures(count: u32) -> u32 {
    if count == 0 {
        return 0;
    }
    let factor = 2u64.saturating_pow(count - 1);
    (u64::from(BASE_RETRY_MILLIS).saturating_mul(factor)).min(u64::from(MAX_RETRY_MILLIS)) as u32
}

fn truncate_detail(detail: String) -> String {
    let units: Vec<u16> = detail.encode_utf16().collect();
    if units.len() > MAX_DETAIL_LENGTH {
        String::from_utf16_lossy(&units[..MAX_DETAIL_LENGTH]) + "..."
    } else {
        detail
    }
}

/// Why a connection ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DownReason {
    /// Ended cleanly after serving long enough to have been worth making: a
    /// load balancer moving a connection, and routine.
    Rotated,
    /// Ended cleanly without having served.
    Closed,
    /// Delivered nothing at all for a whole staleness window.
    Stale,
    /// Sent frames nobody could read. Alone among these it never heals on its
    /// own.
    Unreadable,
    /// No connection was established to begin with.
    ConnectFailed,
    /// The provider refused the subscription.
    SubscribeRejected,
    /// The socket itself reported an error.
    TransportError,
    /// Refused with an HTTP status, which is all an SSE stream is told.
    Http(u16),
}

impl DownReason {
    /// Bounded, so it is safe as a metric label.
    pub fn label(self) -> String {
        match self {
            DownReason::Rotated => "rotated".into(),
            DownReason::Closed => "closed".into(),
            DownReason::Stale => "stale".into(),
            DownReason::Unreadable => "unreadable".into(),
            DownReason::ConnectFailed => "connect-failed".into(),
            DownReason::SubscribeRejected => "subscribe-rejected".into(),
            DownReason::TransportError => "error".into(),
            DownReason::Http(code) => format!("http-{code}"),
        }
    }
}

#[derive(Debug, PartialEq)]
pub enum Effect {
    /// Open a connection whose reports carry `generation`.
    Connect {
        generation: u32,
    },
    /// Close the connection in place.
    Close,
    ArmTimer {
        timer: u32,
        label: &'static str,
        millis: u32,
        jitter: bool,
    },
    ClearTimer {
        timer: u32,
    },
    Height(i64),
    /// Live when `down` is absent.
    Status {
        down: Option<DownReason>,
        detail: Option<String>,
    },
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Pending {
    Stale,
    Retry,
}

pub struct HeightStream {
    stale_timeout: u32,
    /// Bumped on every failure and reconnect. Reports from a
    /// superseded connection carry an older one and are ignored, so a socket
    /// that errors and then closes counts as one failure.
    generation: u32,
    failure_count: u32,
    /// When the current connection reported itself live. Time before that is
    /// not service: a handshake that takes seconds to fail would otherwise look
    /// like a connection that worked.
    live_at: Option<f64>,
    /// The frame that stopped this connection being readable, kept for the
    /// failure it will eventually be named after.
    unreadable_detail: Option<String>,
    /// A connection is either waiting for traffic or waiting to be retried,
    /// never both, so one slot holds whichever timer is pending.
    pending: Option<(u32, Pending)>,
    next_timer: u32,
    effects: VecDeque<Effect>,
}

impl HeightStream {
    pub fn new(stale_timeout: u32) -> Self {
        HeightStream {
            stale_timeout,
            generation: 0,
            failure_count: 0,
            live_at: None,
            unreadable_detail: None,
            pending: None,
            next_timer: 0,
            effects: VecDeque::new(),
        }
    }

    pub fn take_effect(&mut self) -> Option<Effect> {
        self.effects.pop_front()
    }

    pub fn is_current(&self, generation: u32) -> bool {
        generation == self.generation
    }

    pub fn start(&mut self) {
        self.generation += 1;
        self.unreadable_detail = None;
        self.live_at = None;
        // Armed before connecting, so it covers a connect that never reports
        // anything, and a failure inside connect replaces it with the retry.
        self.arm(Pending::Stale);
        self.effects.push_back(Effect::Connect {
            generation: self.generation,
        });
    }

    /// The stream is usable: for SSE the connection opened, for WebSocket the
    /// subscription was confirmed.
    pub fn connected(&mut self, generation: u32, now: f64) {
        if self.is_current(generation) {
            self.go_live(now);
        }
    }

    /// Stops counting once anything unreadable has arrived: a stream whose
    /// heights are all malformed is otherwise held open by the keep-alives
    /// between them, never failing and so never reporting anything.
    pub fn keep_alive(&mut self, generation: u32) {
        if self.is_current(generation) && self.unreadable_detail.is_none() {
            self.arm(Pending::Stale);
        }
    }

    /// A height is proof the stream is delivering, so it reports live as
    /// connecting does, and proves the shape readable again.
    pub fn height(&mut self, generation: u32, height: i64, now: f64) {
        if self.is_current(generation) {
            self.unreadable_detail = None;
            self.go_live(now);
            self.effects.push_back(Effect::Height(height));
        }
    }

    pub fn unreadable(&mut self, generation: u32, detail: String) {
        if self.is_current(generation) {
            self.unreadable_detail = Some(detail);
        }
    }

    pub fn failure(
        &mut self,
        generation: u32,
        reason: DownReason,
        detail: Option<String>,
        now: f64,
    ) {
        if self.is_current(generation) {
            self.fail(reason, detail, now);
        }
    }

    /// A url the transport can't even try, which is the only account of why.
    pub fn connect_failed(&mut self, generation: u32, detail: Option<String>, now: f64) {
        if self.is_current(generation) {
            self.fail(DownReason::ConnectFailed, detail, now);
        }
    }

    pub fn timer_fired(&mut self, timer: u32, now: f64) {
        // Every timer this replaces is cleared on the clock, so the one that
        // fires is the one pending.
        let (pending_timer, pending) = self
            .pending
            .take()
            .expect("a fired stream timer is the pending one");
        debug_assert_eq!(pending_timer, timer);
        match pending {
            // Tells a provider whose messages we don't understand apart from a
            // chain that simply has nothing to report.
            Pending::Stale => match self.unreadable_detail.clone() {
                Some(detail) => self.fail(DownReason::Unreadable, Some(detail), now),
                None => self.fail(DownReason::Stale, None, now),
            },
            Pending::Retry => self.start(),
        }
    }

    fn clear_pending(&mut self) {
        if let Some((timer, _)) = self.pending.take() {
            self.effects.push_back(Effect::ClearTimer { timer });
        }
    }

    fn arm(&mut self, pending: Pending) {
        self.clear_pending();
        self.arm_after(pending, self.stale_timeout, false);
    }

    fn arm_after(&mut self, pending: Pending, millis: u32, jitter: bool) {
        self.next_timer += 1;
        let timer = self.next_timer;
        self.pending = Some((timer, pending));
        let label = match pending {
            Pending::Stale => "height stream stale",
            Pending::Retry => "height stream retry",
        };
        self.effects.push_back(Effect::ArmTimer {
            timer,
            label,
            millis,
            jitter,
        });
    }

    fn go_live(&mut self, now: f64) {
        self.arm(Pending::Stale);
        if self.live_at.is_none() {
            self.live_at = Some(now);
            self.effects.push_back(Effect::Status {
                down: None,
                detail: None,
            });
        }
    }

    fn fail(&mut self, reason: DownReason, detail: Option<String>, now: f64) {
        self.generation += 1;
        self.clear_pending();
        self.effects.push_back(Effect::Close);

        // A connection that served longer than the wait it cost was worth
        // making, whatever ended it, so the backoff starts over. The bar rises
        // with the backoff, so an endpoint that always dies at the same age
        // keeps escalating rather than settling into a loop at a fixed delay.
        // Judged against the schedule, not the jittered wait actually served,
        // so the rotated/closed split an operator reads has no coin flip in it.
        let served_millis = self.live_at.map_or(0., |since| (now - since).trunc());
        let proven_millis = retry_delay_for_failures(self.failure_count)
            .max(self.stale_timeout / PROVEN_STALE_FRACTION);
        let proven = served_millis >= f64::from(proven_millis);
        self.failure_count = if proven { 1 } else { self.failure_count + 1 };

        // Scheduled before reporting, so a consumer that throws can't be what
        // makes the stream give up. Spread, so indexers sharing a provider don't
        // reconnect in lockstep.
        let retry_millis = retry_delay_for_failures(self.failure_count);
        self.arm_after(Pending::Retry, retry_millis, true);

        // A clean end to a connection that had proven itself is a rotation:
        // routine, unlike the same clean end arriving early.
        let reason = if reason == DownReason::Closed && proven {
            DownReason::Rotated
        } else {
            reason
        };
        self.effects.push_back(Effect::Status {
            down: Some(reason),
            detail: detail.map(truncate_detail),
        });
    }
}
