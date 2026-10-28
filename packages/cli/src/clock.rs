//! Where the source layer reads time from and sleeps.
//!
//! A test runs on a [`VirtualClock`]: time only moves when the test advances
//! it, so no timer can land between two steps of a test however busy the runner
//! is, and the jitter comes from a seeded generator so a run replays from its
//! seed. Rust code that sleeps takes a [`Clock`] rather than calling tokio
//! directly, so the same tests drive it.
//!
//! The virtual clock holds one queue for timers armed from both sides of the
//! addon. ReScript arms a timer by id and keeps the callback, which the test's
//! advance loop runs when [`VirtualClock::fire_next`] hands the id back; Rust
//! code awaits [`Clock::sleep`], whose future is woken when its timer fires.
//! Both share the timeline and the ordering, which is what keeps virtual time
//! meaningful while the source layer moves from one side to the other.

use std::{
    future::Future,
    pin::Pin,
    sync::{Arc, Mutex, MutexGuard},
    task::{Context, Poll, Waker},
};

use napi_derive::napi;

// The Rust side of the queue has no caller outside the tests until the first
// source code that sleeps moves here; it is built now so that code lands on the
// same timeline as the ReScript timers rather than on tokio's.
#[cfg_attr(not(test), allow(dead_code))]
pub type Sleep = Pin<Box<dyn Future<Output = ()> + Send>>;

pub trait Clock: Send + Sync {
    fn now_ms(&self) -> f64;
    /// `label` names the timer in a virtual clock's timeline.
    #[cfg_attr(not(test), allow(dead_code))]
    fn sleep(&self, label: &str, millis: u64) -> Sleep;
    /// Uniform in `[0, 1)`.
    fn random(&self) -> f64;
}

/// mulberry32: small, and the same sequence on every platform, so a seed means
/// the same run wherever it is replayed.
fn mulberry32(state: &mut u32) -> f64 {
    *state = state.wrapping_add(0x6d2b_79f5);
    let mut t = *state;
    t = (t ^ (t >> 15)).wrapping_mul(t | 1);
    t ^= t.wrapping_add((t ^ (t >> 7)).wrapping_mul(t | 61));
    f64::from(t ^ (t >> 14)) / 4_294_967_296.
}

enum Owner {
    /// Armed from ReScript, which runs the callback once `fire_next` names it.
    Js,
    /// A Rust `sleep`, woken in place when it fires.
    #[cfg_attr(not(test), allow(dead_code))]
    Rust(Option<Waker>),
}

struct Timer {
    id: u32,
    label: String,
    armed_at: f64,
    due: f64,
    owner: Owner,
}

struct State {
    now: f64,
    timers: Vec<Timer>,
    next_id: u32,
    seed: u32,
    random_state: u32,
    timeline: Vec<String>,
}

fn format_ms(ms: f64) -> String {
    format!("{}ms", ms as i64)
}

impl State {
    fn record(&mut self, event: String) {
        let line = format!("t={} {event}", format_ms(self.now));
        self.timeline.push(line);
    }

    fn arm(&mut self, label: &str, millis: f64, owner: Owner) -> u32 {
        self.next_id += 1;
        let id = self.next_id;
        let due = self.now + millis.max(0.);
        self.timers.push(Timer {
            id,
            label: label.to_string(),
            armed_at: self.now,
            due,
            owner,
        });
        self.record(format!("armed {label} for t={}", format_ms(due)));
        id
    }

    fn clear(&mut self, id: u32) {
        if let Some(position) = self.timers.iter().position(|timer| timer.id == id) {
            let timer = self.timers.remove(position);
            self.record(format!("cleared {}", timer.label));
        }
    }

    /// The earliest timer due by `until`, ties in the order they were armed.
    fn next_due(&self, until: f64) -> Option<usize> {
        self.timers
            .iter()
            .enumerate()
            .filter(|(_, timer)| timer.due <= until)
            .min_by(|(_, a), (_, b)| a.due.total_cmp(&b.due).then(a.id.cmp(&b.id)))
            .map(|(position, _)| position)
    }
}

const TIMELINE_TAIL: usize = 40;

/// A test's clock. Cloning shares it, so the Rust code under test and the
/// ReScript shim read and arm the same queue.
#[derive(Clone)]
pub struct VirtualClock {
    state: Arc<Mutex<State>>,
}

impl VirtualClock {
    pub fn new(seed: u32) -> Self {
        VirtualClock {
            state: Arc::new(Mutex::new(State {
                now: 0.,
                timers: Vec::new(),
                next_id: 0,
                seed,
                random_state: seed,
                timeline: Vec::new(),
            })),
        }
    }

    fn state(&self) -> MutexGuard<'_, State> {
        // A panic while holding the lock can only come from a bug in this
        // module, and the state it left is still the best account of the run.
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn seed(&self) -> u32 {
        self.state().seed
    }

    pub fn arm_js(&self, label: &str, millis: f64) -> u32 {
        self.state().arm(label, millis, Owner::Js)
    }

    pub fn clear(&self, id: u32) {
        self.state().clear(id);
    }

    pub fn begin_advance(&self, millis: f64) -> f64 {
        let mut state = self.state();
        state.record(format!("advance {}", format_ms(millis)));
        state.now + millis
    }

    /// Takes the next timer due by `until` off the queue and moves time to it.
    /// A Rust sleep is woken here; a ReScript timer comes back for its caller to
    /// run, since only that side holds the callback.
    pub fn fire_next(&self, until: f64) -> Option<FiredTimer> {
        let timer = {
            let mut state = self.state();
            let position = state.next_due(until)?;
            let timer = state.timers.remove(position);
            state.now = timer.due;
            state.record(format!("fired {}", timer.label));
            timer
        };
        // Woken with the lock released: an executor that polls on wake would
        // otherwise re-enter it from the sleep's own poll.
        let js = match timer.owner {
            Owner::Js => true,
            Owner::Rust(waker) => {
                if let Some(waker) = waker {
                    waker.wake();
                }
                false
            }
        };
        Some(FiredTimer {
            id: timer.id,
            label: timer.label,
            js,
        })
    }

    pub fn end_advance(&self, until: f64) {
        let mut state = self.state();
        state.now = state.now.max(until);
    }

    pub fn note(&self, event: String) {
        self.state().record(event);
    }

    pub fn describe(&self) -> String {
        let state = self.state();
        let mut pending: Vec<&Timer> = state.timers.iter().collect();
        pending.sort_by(|a, b| a.due.total_cmp(&b.due).then(a.id.cmp(&b.id)));
        let pending = if pending.is_empty() {
            " none".to_string()
        } else {
            pending
                .iter()
                .map(|timer| {
                    format!(
                        "\n    {} due t={} (in {}), armed t={}",
                        timer.label,
                        format_ms(timer.due),
                        format_ms(timer.due - state.now),
                        format_ms(timer.armed_at)
                    )
                })
                .collect()
        };
        let skipped = state.timeline.len().saturating_sub(TIMELINE_TAIL);
        let timeline: String = state.timeline[skipped..]
            .iter()
            .map(|line| format!("\n    {line}"))
            .collect();
        let hint = match state.next_due(f64::INFINITY) {
            Some(position) => {
                let timer = &state.timers[position];
                format!(
                    "\n  Nothing the indexer schedules runs until the test advances time: `await indexer.advanceTime({})` fires the next timer ({}).",
                    (timer.due - state.now).ceil() as i64,
                    timer.label
                )
            }
            None => String::new(),
        };
        format!(
            "Virtual time at the failure: t={}, seed {seed} (ENVIO_TEST_SEED={seed} replays it)\n  pending timers:{pending}\n  timeline{}:{timeline}{hint}",
            format_ms(state.now),
            if skipped > 0 {
                format!(" (last {TIMELINE_TAIL})")
            } else {
                String::new()
            },
            seed = state.seed,
        )
    }
}

impl Clock for VirtualClock {
    fn now_ms(&self) -> f64 {
        self.state().now
    }

    fn sleep(&self, label: &str, millis: u64) -> Sleep {
        // No time passes, so there is nothing for a test to advance. The
        // ReScript side runs its zero-delay timers on the next turn the same way.
        if millis == 0 {
            self.note(format!("ran {label} with no delay"));
            return Box::pin(std::future::ready(()));
        }
        let id = self.state().arm(label, millis as f64, Owner::Rust(None));
        Box::pin(VirtualSleep {
            clock: self.clone(),
            id,
        })
    }

    fn random(&self) -> f64 {
        mulberry32(&mut self.state().random_state)
    }
}

#[cfg_attr(not(test), allow(dead_code))]
struct VirtualSleep {
    clock: VirtualClock,
    id: u32,
}

impl Future for VirtualSleep {
    type Output = ();

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        let mut state = self.clock.state();
        match state.timers.iter_mut().find(|timer| timer.id == self.id) {
            // Off the queue means fired: a sleep is only cleared by dropping it.
            None => Poll::Ready(()),
            Some(timer) => {
                timer.owner = Owner::Rust(Some(cx.waker().clone()));
                Poll::Pending
            }
        }
    }
}

impl Drop for VirtualSleep {
    fn drop(&mut self) {
        self.clock.clear(self.id);
    }
}

#[napi(object)]
pub struct FiredTimer {
    pub id: u32,
    pub label: String,
    /// Whether the ReScript side holds this timer's callback.
    pub js: bool,
}

/// The test-facing handle on a [`VirtualClock`].
#[napi(js_name = "VirtualClock")]
pub struct VirtualClockHandle {
    clock: VirtualClock,
}

#[napi]
impl VirtualClockHandle {
    #[napi(factory)]
    pub fn new(seed: u32) -> Self {
        VirtualClockHandle {
            clock: VirtualClock::new(seed),
        }
    }

    #[napi]
    pub fn now(&self) -> f64 {
        self.clock.now_ms()
    }

    #[napi]
    pub fn seed(&self) -> u32 {
        self.clock.seed()
    }

    #[napi]
    pub fn random(&self) -> f64 {
        self.clock.random()
    }

    #[napi]
    pub fn arm(&self, label: String, millis: f64) -> u32 {
        self.clock.arm_js(&label, millis)
    }

    #[napi]
    pub fn clear(&self, id: u32) {
        self.clock.clear(id);
    }

    #[napi]
    pub fn begin_advance(&self, millis: f64) -> f64 {
        self.clock.begin_advance(millis)
    }

    #[napi]
    pub fn fire_next(&self, until: f64) -> Option<FiredTimer> {
        self.clock.fire_next(until)
    }

    #[napi]
    pub fn end_advance(&self, until: f64) {
        self.clock.end_advance(until);
    }

    #[napi]
    pub fn note(&self, event: String) {
        self.clock.note(event);
    }

    #[napi]
    pub fn describe(&self) -> String {
        self.clock.describe()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fire_all(clock: &VirtualClock, millis: f64) -> Vec<String> {
        let until = clock.begin_advance(millis);
        let mut fired = Vec::new();
        while let Some(timer) = clock.fire_next(until) {
            fired.push(timer.label);
        }
        clock.end_advance(until);
        fired
    }

    #[test]
    fn fires_due_timers_in_order_and_nothing_past_the_window() {
        let clock = VirtualClock::new(1);
        clock.arm_js("late", 300.);
        clock.arm_js("second", 100.);
        clock.arm_js("first", 50.);
        clock.arm_js("tie", 100.);
        assert_eq!(
            (fire_all(&clock, 100.), clock.now_ms()),
            (
                vec!["first".to_string(), "second".to_string(), "tie".to_string()],
                100.
            )
        );
    }

    #[test]
    fn replays_the_same_randomness_from_the_same_seed() {
        let sample = |seed| {
            let clock = VirtualClock::new(seed);
            (0..5).map(|_| clock.random()).collect::<Vec<_>>()
        };
        let first = sample(7);
        assert_eq!(
            (
                first.clone() == sample(7),
                first != sample(8),
                first.iter().all(|value| (0.0..1.0).contains(value))
            ),
            (true, true, true)
        );
    }

    #[tokio::test]
    async fn wakes_a_rust_sleep_only_when_time_reaches_it() {
        let clock = VirtualClock::new(1);
        let woke = Arc::new(Mutex::new(Vec::new()));
        let task = tokio::spawn({
            let clock = clock.clone();
            let woke = woke.clone();
            async move {
                clock.sleep("rust retry", 200).await;
                woke.lock().unwrap().push(clock.now_ms());
            }
        });
        tokio::task::yield_now().await;
        let fired_early = fire_all(&clock, 199.);
        tokio::task::yield_now().await;
        let early = woke.lock().unwrap().clone();
        let fired = fire_all(&clock, 1.);
        task.await.unwrap();
        assert_eq!(
            (fired_early, early, fired, woke.lock().unwrap().clone()),
            (
                Vec::<String>::new(),
                Vec::<f64>::new(),
                vec!["rust retry".to_string()],
                vec![200.]
            )
        );
    }

    #[tokio::test]
    async fn runs_a_zero_delay_sleep_without_advancing() {
        let clock = VirtualClock::new(1);
        clock.sleep("retry", 0).await;
        assert_eq!(
            (clock.now_ms(), fire_all(&clock, 0.)),
            (0., Vec::<String>::new())
        );
    }

    #[test]
    fn a_dropped_sleep_leaves_the_queue() {
        let clock = VirtualClock::new(1);
        drop(clock.sleep("abandoned", 10));
        assert_eq!(fire_all(&clock, 10.), Vec::<String>::new());
    }
}
