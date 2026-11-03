//! Resolves at the first height above `known_height` that any eligible source
//! reports. A waiter is registered per source and the first to fire wins,
//! cancelling the rest.

use serde_json::{json, Value};

use super::core::{Core, Effect, Level, TimerId, TimerPurpose};

pub struct Wait {
    known_height: i64,
    is_realtime: bool,
    pub reduced_polling: bool,
    /// Ran out its stall window. Only changes the cadence its sources poll at
    /// and the level the closing line is logged at.
    pub stalled: bool,
    main_sources: Vec<usize>,
    /// Every source holding a waiter for this wait.
    watched: Vec<usize>,
    stall_timeout: u32,
    poke: Option<TimerId>,
    stall: Option<TimerId>,
}

impl Core {
    fn wait_log_fields(known_height: i64) -> serde_json::Value {
        json!({ "knownHeight": known_height })
    }

    pub fn wait_for_new_block(
        &mut self,
        known_height: i64,
        is_realtime: bool,
        reduced_polling: bool,
        now: f64,
    ) -> u32 {
        if !self.waiting_logged {
            let message = if reduced_polling {
                format!(
                    "Waiting for new blocks with reduced polling ({}s) until the indexer enters realtime mode.",
                    self.timing.reduced_polling_interval / 1000
                )
            } else {
                "Initiating check for new blocks.".to_string()
            };
            self.log(
                Some(Self::wait_log_fields(known_height)),
                Level::Trace,
                message,
                Value::Null,
            );
            self.waiting_logged = true;
        }

        let main_sources = self.next_sources(is_realtime, &[], now);
        // Much longer with reduced polling, so a chain deliberately asking
        // rarely doesn't report itself stalled between polls.
        let stall_timeout = if reduced_polling {
            self.timing.reduced_polling_interval.saturating_mul(2)
        } else if is_realtime {
            self.timing.new_block_stall_timeout_realtime
        } else {
            self.timing.new_block_stall_timeout
        };

        let wait = self.next_id();
        self.waits.insert(
            wait,
            Wait {
                known_height,
                is_realtime,
                reduced_polling,
                stalled: false,
                main_sources: main_sources.clone(),
                watched: Vec::new(),
                stall_timeout,
                poke: None,
                stall: None,
            },
        );

        let still_waiting = main_sources
            .iter()
            .all(|&source| self.watch(wait, source, is_realtime));
        if still_waiting {
            self.arm_stall_poke(wait);
            let stall = self.arm_timer(
                TimerPurpose::StallTimeout { wait },
                "stall timeout",
                stall_timeout,
                false,
            );
            self.wait_mut(wait).stall = Some(stall);
        }
        wait
    }

    /// A wait's timers are cleared when it settles, so one that fires is for a
    /// wait still open.
    fn wait_mut(&mut self, wait: u32) -> &mut Wait {
        self.waits
            .get_mut(&wait)
            .expect("only an open wait is acted on")
    }

    /// Whether the wait is still open afterwards. Registering is the one step
    /// that can answer it on the spot, from a height the source already knew;
    /// the callers stop registering once it has.
    fn watch(&mut self, wait: u32, source: usize, with_stream: bool) -> bool {
        let known_height = self.waits[&wait].known_height;
        if with_stream {
            // A stream outlives the wait that asked for it, so only the sources a
            // wait was built on ask for one. A source recruited because another
            // stalled is here to poll, and would otherwise hold a connection open
            // for the life of the process on the strength of one stall.
            self.enable_stream(source);
        }
        self.add_waiter(source, wait, known_height);
        match self.waits.get_mut(&wait) {
            Some(entry) => {
                entry.watched.push(source);
                true
            }
            None => false,
        }
    }

    /// Spread across the window, and re-spread on every repeat: every indexer on
    /// one provider goes quiet in the same instant that provider does.
    /// Re-armed, because distrusting a stream is a one-shot: the next height it
    /// delivers takes it back at its word.
    fn arm_stall_poke(&mut self, wait: u32) {
        let stall_timeout = self.waits[&wait].stall_timeout;
        let poke = self.arm_timer(
            TimerPurpose::StallPoke { wait },
            "stall poke",
            stall_timeout,
            true,
        );
        self.wait_mut(wait).poke = Some(poke);
    }

    /// Distrusting only starts a poll, whose answer comes later, so it never
    /// answers the wait itself.
    fn distrust_streams_of(&mut self, wait: u32) {
        for source in self.waits[&wait].watched.clone() {
            self.distrust_stream(source, wait);
        }
    }

    pub fn stall_poke(&mut self, wait: u32) {
        self.wait_mut(wait).poke = None;
        self.distrust_streams_of(wait);
        self.arm_stall_poke(wait);
    }

    /// Punctual, unlike the poke: the stall timeout is a promise to the operator
    /// about when they hear about a quiet chain. Fires once per wait, and a
    /// fallback stays recruited.
    pub fn stall_timeout(&mut self, wait: u32) {
        let entry = self.wait_mut(wait);
        entry.stall = None;
        entry.stalled = true;
        let (is_realtime, stall_timeout) = (entry.is_realtime, entry.stall_timeout);
        let main_sources = entry.main_sources.clone();

        let fallbacks: Vec<usize> = (0..self.sources.len())
            .filter(|source| {
                !self.sources[*source].disabled
                    && !main_sources.contains(source)
                    && self.role_of(*source, is_realtime).is_some()
            })
            .collect();

        let message = if fallbacks.is_empty() {
            format!(
                "No new blocks detected within {}s. Polling will continue at a reduced rate. For better reliability, refer to our RPC fallback guide: https://docs.envio.dev/docs/HyperIndex/rpc-sync",
                stall_timeout / 1000
            )
        } else {
            format!(
                "No new blocks detected within {}s. Continuing polling with secondary RPC sources from the configuration.",
                stall_timeout / 1000
            )
        };
        let known_height = self.waits[&wait].known_height;
        self.log(
            Some(Self::wait_log_fields(known_height)),
            Level::Warn,
            message,
            Value::Null,
        );

        let still_waiting = fallbacks
            .iter()
            .all(|&source| self.watch(wait, source, false));

        // A fallback can still hold a stream from an earlier wait that made it a
        // primary, and a live stream is not polled behind. It inherits the
        // verdict the primaries earned, or it would sit silent behind that
        // stream until the next poke.
        if still_waiting {
            self.distrust_streams_of(wait);
        }
    }

    pub fn settle_wait(&mut self, wait: u32, source: usize, height: i64) {
        // A source holds one waiter per wait, and answering removes the wait,
        // so a wait settles once.
        let mut entry = self.waits.remove(&wait).expect("a wait settles once");
        // Before anything else: the sources still watching have no reason to
        // keep polling for a height this wait already has.
        for watched in std::mem::take(&mut entry.watched) {
            self.remove_waiters_of(watched, wait);
        }
        self.clear_timer(&mut entry.poke);
        self.clear_timer(&mut entry.stall);
        self.active = source;
        let level = if entry.stalled {
            Level::Info
        } else {
            Level::Trace
        };
        self.log(
            Some(Self::wait_log_fields(entry.known_height)),
            level,
            "New blocks successfully found.".to_string(),
            json!({
                "source": self.sources[source].spec.name,
                "newBlockHeight": height,
            }),
        );
        self.waiting_logged = false;
        self.emit(Effect::ResolveWait { wait, height });
    }
}
