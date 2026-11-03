//! Reconnect driver shared by every height subscription transport. A transport
//! connects a socket and reports what it sees; this owns retries, staleness
//! detection and status reporting, so SSE and WebSocket streams behave
//! identically. Like the source manager, it performs no IO and keeps no time:
//! the caller connects, closes and arms timers when told to.
//!
//! Nothing here logs. A height stream failing is not something an operator has
//! to act on — the indexer polls for the height instead — so a failure travels
//! out as a status, where its reason becomes a metric label.

use std::collections::VecDeque;

use napi_derive::napi;

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
/// put there. In UTF-16 units, as the JavaScript that reports it counts.
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

/// Why a connection ended, by the name of `Source.heightSubscriptionDownReason`'s
/// constructor; `code` carries the status of an `Http` one.
#[napi(object)]
#[derive(Clone)]
pub struct HeightStreamDownReason {
    pub name: String,
    pub code: Option<u32>,
}

impl HeightStreamDownReason {
    fn named(name: &str) -> Self {
        HeightStreamDownReason {
            name: name.to_string(),
            code: None,
        }
    }
}

#[napi(discriminant = "kind")]
pub enum HeightStreamEffect {
    /// Open a connection whose reports carry `generation`.
    Connect {
        generation: u32,
    },
    /// Close the connection in place, `generation` being the one that ended.
    Close {
        generation: u32,
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
    Height {
        height: i64,
    },
    /// Live when `down` is absent.
    Status {
        down: Option<HeightStreamDownReason>,
        detail: Option<String>,
    },
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Pending {
    Stale,
    Retry,
}

#[napi]
pub struct HeightStream {
    stale_timeout: u32,
    /// Bumped on every failure, reconnect and unsubscribe. Reports from a
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
    effects: VecDeque<HeightStreamEffect>,
}

#[napi]
impl HeightStream {
    #[napi(factory)]
    pub fn make(stale_timeout: u32) -> Self {
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

    #[napi]
    pub fn take_effect(&mut self) -> Option<HeightStreamEffect> {
        self.effects.pop_front()
    }

    #[napi]
    pub fn is_current(&self, generation: u32) -> bool {
        generation == self.generation
    }

    #[napi]
    pub fn start(&mut self) {
        self.generation += 1;
        self.unreadable_detail = None;
        self.live_at = None;
        // Armed before connecting, so it covers a connect that never reports
        // anything, and a failure inside connect replaces it with the retry.
        self.arm(Pending::Stale);
        self.effects.push_back(HeightStreamEffect::Connect {
            generation: self.generation,
        });
    }

    #[napi]
    pub fn unsubscribe(&mut self) {
        self.generation += 1;
        self.clear_pending();
        self.effects.push_back(HeightStreamEffect::Close {
            generation: self.generation,
        });
    }

    /// The stream is usable: for SSE the connection opened, for WebSocket the
    /// subscription was confirmed.
    #[napi]
    pub fn connected(&mut self, generation: u32, now: f64) {
        if self.is_current(generation) {
            self.go_live(now);
        }
    }

    /// Stops counting once anything unreadable has arrived: a stream whose
    /// heights are all malformed is otherwise held open by the keep-alives
    /// between them, never failing and so never reporting anything.
    #[napi]
    pub fn keep_alive(&mut self, generation: u32) {
        if self.is_current(generation) && self.unreadable_detail.is_none() {
            self.arm(Pending::Stale);
        }
    }

    /// A height is proof the stream is delivering, so it reports live as
    /// connecting does, and proves the shape readable again.
    #[napi]
    pub fn height(&mut self, generation: u32, height: i64, now: f64) {
        if self.is_current(generation) {
            self.unreadable_detail = None;
            self.go_live(now);
            self.effects
                .push_back(HeightStreamEffect::Height { height });
        }
    }

    #[napi]
    pub fn unreadable(&mut self, generation: u32, detail: String) {
        if self.is_current(generation) {
            self.unreadable_detail = Some(detail);
        }
    }

    #[napi]
    pub fn failure(
        &mut self,
        generation: u32,
        reason: HeightStreamDownReason,
        detail: Option<String>,
        now: f64,
    ) {
        if self.is_current(generation) {
            self.fail(reason, detail, now);
        }
    }

    /// A transport that throws while connecting, which is the only account of
    /// why its url can't be connected to.
    #[napi]
    pub fn connect_failed(&mut self, generation: u32, detail: Option<String>, now: f64) {
        if self.is_current(generation) {
            self.fail(HeightStreamDownReason::named("ConnectFailed"), detail, now);
        }
    }

    #[napi]
    pub fn timer_fired(&mut self, timer: u32, now: f64) {
        let Some((pending_timer, pending)) = self.pending else {
            return;
        };
        if pending_timer != timer {
            return;
        }
        self.pending = None;
        match pending {
            // Tells a provider whose messages we don't understand apart from a
            // chain that simply has nothing to report.
            Pending::Stale => match self.unreadable_detail.clone() {
                Some(detail) => self.fail(
                    HeightStreamDownReason::named("Unreadable"),
                    Some(detail),
                    now,
                ),
                None => self.fail(HeightStreamDownReason::named("Stale"), None, now),
            },
            Pending::Retry => self.start(),
        }
    }
}

impl HeightStream {
    fn clear_pending(&mut self) {
        if let Some((timer, _)) = self.pending.take() {
            self.effects
                .push_back(HeightStreamEffect::ClearTimer { timer });
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
        self.effects.push_back(HeightStreamEffect::ArmTimer {
            timer,
            label: label.to_string(),
            millis,
            jitter,
        });
    }

    fn go_live(&mut self, now: f64) {
        self.arm(Pending::Stale);
        if self.live_at.is_none() {
            self.live_at = Some(now);
            self.effects.push_back(HeightStreamEffect::Status {
                down: None,
                detail: None,
            });
        }
    }

    fn fail(&mut self, reason: HeightStreamDownReason, detail: Option<String>, now: f64) {
        self.generation += 1;
        self.clear_pending();
        self.effects.push_back(HeightStreamEffect::Close {
            generation: self.generation,
        });

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
        let reason = if reason.name == "Closed" && proven {
            HeightStreamDownReason::named("Rotated")
        } else {
            reason
        };
        self.effects.push_back(HeightStreamEffect::Status {
            down: Some(reason),
            detail: detail.map(truncate_detail),
        });
    }
}
