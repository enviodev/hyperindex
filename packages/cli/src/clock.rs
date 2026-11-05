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
    collections::HashSet,
    future::Future,
    pin::Pin,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex, MutexGuard, OnceLock,
    },
    task::{Context, Poll, Waker},
    time::{Duration, Instant},
};

use napi_derive::napi;

/// Rust work a test's advance has to wait out: a sleep the virtual clock woke,
/// until the code it woke has done what it does, or a call on its way to
/// JavaScript. Dropping it says the work is done. On the real clock it counts
/// nothing.
pub struct Hold(Option<Arc<AtomicUsize>>);

impl Drop for Hold {
    fn drop(&mut self) {
        if let Some(busy) = &self.0 {
            busy.fetch_sub(1, Ordering::SeqCst);
        }
    }
}

/// Resolves with the hold on what the timer woke, which the sleeper keeps until
/// it has reacted.
pub type Sleep = Pin<Box<dyn Future<Output = Hold> + Send>>;

pub trait Clock: Send + Sync {
    fn now_ms(&self) -> f64;
    /// `label` names the timer in a virtual clock's timeline.
    fn sleep(&self, label: &str, millis: u64) -> Sleep;
    /// Uniform in `[0, 1)`.
    fn random(&self) -> f64;
    /// Held for as long as a call to JavaScript is on its way.
    fn hold(&self) -> Hold;
}

/// The clock outside tests: tokio's timers, and time measured from when the
/// process first asked.
pub struct RealClock {
    start: Instant,
    random_state: Mutex<u32>,
}

impl RealClock {
    pub fn shared() -> Arc<dyn Clock> {
        static CLOCK: OnceLock<Arc<dyn Clock>> = OnceLock::new();
        CLOCK
            .get_or_init(|| {
                #[allow(
                    clippy::disallowed_methods,
                    reason = "seeding the real clock's jitter, which no test replays"
                )]
                let seed = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_or(1, |since| since.subsec_nanos());
                Arc::new(RealClock {
                    start: Instant::now(),
                    random_state: Mutex::new(seed),
                })
            })
            .clone()
    }
}

impl Clock for RealClock {
    fn now_ms(&self) -> f64 {
        self.start.elapsed().as_secs_f64() * 1000.
    }

    fn sleep(&self, _label: &str, millis: u64) -> Sleep {
        Box::pin(async move {
            #[allow(clippy::disallowed_methods, reason = "the real clock's own timer")]
            tokio::time::sleep(Duration::from_millis(millis)).await;
            Hold(None)
        })
    }

    fn random(&self) -> f64 {
        let mut state = self
            .random_state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        mulberry32(&mut state)
    }

    fn hold(&self) -> Hold {
        Hold(None)
    }
}

/// Half the delay fixed, half spread across it. Every indexer pointed at one
/// provider loses its stream, or gives up on a quiet chain, in the same instant
/// that provider blinks, and putting them all back on the same schedule is how
/// a blip becomes a stampede.
pub fn jittered(millis: u32, random: f64) -> u32 {
    let half = millis / 2;
    half + (random * f64::from(half)) as u32
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
    /// Rust sleeps that fired and whose sleeper hasn't taken its hold yet.
    woken: HashSet<u32>,
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
    /// Kept outside `state` so a hold can be dropped from inside a poll that
    /// holds the lock.
    busy: Arc<AtomicUsize>,
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
                woken: HashSet::new(),
            })),
            busy: Arc::new(AtomicUsize::new(0)),
        }
    }

    /// How much Rust work a test still has to wait out before its advance has
    /// settled: sleeps woken and not yet reacted to, and calls to JavaScript
    /// not yet delivered.
    pub fn busy(&self) -> usize {
        self.busy.load(Ordering::SeqCst)
    }

    fn state(&self) -> MutexGuard<'_, State> {
        // A panic while holding the lock can only come from a bug in this
        // module, and the state it left is still the best account of the run.
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
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
            if matches!(timer.owner, Owner::Rust(_)) {
                // Counted before the sleeper wakes, so the advance that woke it
                // can't see it idle in between.
                self.busy.fetch_add(1, Ordering::SeqCst);
                state.woken.insert(timer.id);
            }
            timer
        };
        // Woken with the lock released: an executor that polls on wake would
        // otherwise re-enter it from the sleep's own poll.
        if let Owner::Rust(Some(waker)) = timer.owner {
            waker.wake();
        }
        Some(FiredTimer {
            id: timer.id,
            label: timer.label,
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
            return Box::pin(std::future::ready(Hold(None)));
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

    fn hold(&self) -> Hold {
        self.busy.fetch_add(1, Ordering::SeqCst);
        Hold(Some(self.busy.clone()))
    }
}

struct VirtualSleep {
    clock: VirtualClock,
    id: u32,
}

impl Future for VirtualSleep {
    type Output = Hold;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Hold> {
        let mut state = self.clock.state();
        match state.timers.iter_mut().find(|timer| timer.id == self.id) {
            // Off the queue means fired: a sleep is only cleared by dropping it.
            // The hold `fire_next` counted passes to the sleeper.
            None => Poll::Ready(if state.woken.remove(&self.id) {
                Hold(Some(self.clock.busy.clone()))
            } else {
                Hold(None)
            }),
            Some(timer) => {
                timer.owner = Owner::Rust(Some(cx.waker().clone()));
                Poll::Pending
            }
        }
    }
}

impl Drop for VirtualSleep {
    fn drop(&mut self) {
        // Fired but never polled again: nobody is left to react, so the hold
        // `fire_next` counted is given back here.
        let woken = self.clock.state().woken.remove(&self.id);
        if woken {
            self.clock.busy.fetch_sub(1, Ordering::SeqCst);
        } else {
            self.clock.clear(self.id);
        }
    }
}

#[napi(object)]
pub struct FiredTimer {
    /// Names a callback only when ReScript armed the timer; a Rust sleep is
    /// woken in place.
    pub id: u32,
    pub label: String,
}

/// The test-facing handle on a [`VirtualClock`].
#[napi(js_name = "VirtualClock")]
pub struct VirtualClockHandle {
    clock: VirtualClock,
}

impl VirtualClockHandle {
    /// The clock for Rust code a test runs on this handle's time.
    pub fn shared(&self) -> Arc<dyn Clock> {
        Arc::new(self.clock.clone())
    }
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

    #[napi]
    pub fn busy(&self) -> u32 {
        self.clock.busy() as u32
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

    #[tokio::test]
    async fn counts_a_woken_sleeper_busy_until_it_drops_its_hold() {
        let clock = VirtualClock::new(1);
        let sleep = clock.sleep("retry", 10);
        let before = clock.busy();
        fire_all(&clock, 10.);
        let woken = clock.busy();
        let hold = sleep.await;
        let held = clock.busy();
        drop(hold);
        assert_eq!((before, woken, held, clock.busy()), (0, 1, 1, 0));
    }

    #[test]
    fn gives_back_the_hold_of_a_sleep_dropped_after_it_fired() {
        let clock = VirtualClock::new(1);
        let sleep = clock.sleep("raced", 10);
        fire_all(&clock, 10.);
        let woken = clock.busy();
        drop(sleep);
        assert_eq!((woken, clock.busy()), (1, 0));
    }

    #[test]
    fn counts_a_call_on_its_way_until_delivered() {
        let clock = VirtualClock::new(1);
        let hold = clock.hold();
        let held = clock.busy();
        drop(hold);
        assert_eq!((held, clock.busy()), (1, 0));
    }

    #[test]
    fn a_dropped_sleep_leaves_the_queue() {
        let clock = VirtualClock::new(1);
        drop(clock.sleep("abandoned", 10));
        assert_eq!(fire_all(&clock, 10.), Vec::<String>::new());
    }
}
