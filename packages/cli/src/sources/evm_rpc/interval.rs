use std::collections::HashMap;
use std::sync::Mutex;

/// The sync-tuning knobs of an RPC source (config.yaml's sync options, with
/// defaults filled in by `Source`), minus the fields that are not paging
/// concerns: `pollingInterval` is JS-side scheduling, and `queryTimeoutMillis`
/// bounds each request in the client rather than the range a page asks for.
#[derive(Clone, Copy)]
pub struct SyncConfig {
    pub initial_block_interval: u64,
    pub backoff_multiplicative: f64,
    pub acceleration_additive: u64,
    pub interval_ceiling: u64,
    pub backoff_millis: u64,
}

/// Adaptive block interval (AIMD) per request stream: a need's index, or the
/// head stream's key. The `source_max` ceiling only ever tightens, set by
/// structural provider limits ("limited to N blocks").
/// See: <https://en.wikipedia.org/wiki/Additive_increase/multiplicative_decrease>
pub struct IntervalState {
    by_stream: Mutex<HashMap<u32, u64>>,
    source_max: Mutex<Option<u64>>,
}

impl IntervalState {
    pub fn new() -> Self {
        Self {
            by_stream: Mutex::new(HashMap::new()),
            source_max: Mutex::new(None),
        }
    }

    fn source_max_interval(&self, ceiling: u64) -> u64 {
        self.source_max.lock().unwrap().unwrap_or(ceiling)
    }

    /// Reads this stream's suggested interval, clamped to the source-wide
    /// ceiling. Returns the clamped interval alongside the ceiling it was
    /// clamped to, so callers can reuse the ceiling without a second lock.
    pub fn suggested_interval(&self, stream: u32, cfg: &SyncConfig) -> (u64, u64) {
        let source_max = self.source_max_interval(cfg.interval_ceiling);
        let interval = self
            .by_stream
            .lock()
            .unwrap()
            .get(&stream)
            .copied()
            .unwrap_or(cfg.initial_block_interval);
        (interval.min(source_max), source_max)
    }

    /// Additive increase: grows this stream's interval, capped at `source_max`.
    pub fn grow(&self, stream: u32, executed_interval: u64, cfg: &SyncConfig, source_max: u64) {
        self.by_stream.lock().unwrap().insert(
            stream,
            (executed_interval + cfg.acceleration_additive).min(source_max),
        );
    }

    pub fn set(&self, stream: u32, interval: u64) {
        self.by_stream.lock().unwrap().insert(stream, interval);
    }

    /// A provider reported a structural, source-wide cap — tighten (never
    /// loosen) the ceiling and return the resulting value. The current ceiling
    /// is read under the same lock that writes it: streams fail
    /// concurrently, and one holding a copy read before another's write would
    /// otherwise raise a cap that was just lowered. `ceiling` is only the
    /// configured default, for when nothing has capped the source yet.
    pub fn tighten_source_max(&self, ceiling: u64, interval: u64) -> u64 {
        let mut source_max = self.source_max.lock().unwrap();
        let capped = source_max.unwrap_or(ceiling).min(interval);
        *source_max = Some(capped);
        capped
    }
}

/// Multiplicative decrease: shrink the executed interval, floored at 1 so a
/// failing single-block query can't wedge into a zero-width range.
pub fn shrink(executed_interval: u64, backoff_multiplicative: f64) -> u64 {
    ((executed_interval as f64) * backoff_multiplicative).max(1.0) as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_config() -> SyncConfig {
        SyncConfig {
            initial_block_interval: 10_000,
            backoff_multiplicative: 0.8,
            acceleration_additive: 500,
            interval_ceiling: 10_000,
            backoff_millis: 2_000,
        }
    }

    #[test]
    fn shrink_floors_at_one() {
        assert_eq!(shrink(10_000, 0.8), 8_000);
        assert_eq!(shrink(1, 0.8), 1);
        assert_eq!(shrink(0, 0.8), 1);
    }

    #[test]
    fn suggested_interval_defaults_to_initial_and_clamps_to_ceiling() {
        let state = IntervalState::new();
        let cfg = SyncConfig {
            interval_ceiling: 5_000,
            ..test_config()
        };
        assert_eq!(state.suggested_interval(0, &cfg), (5_000, 5_000));
    }

    #[test]
    fn grow_caps_at_source_max() {
        let state = IntervalState::new();
        let cfg = test_config();
        state.grow(0, 9_800, &cfg, 10_000);
        let capped = state.suggested_interval(0, &cfg).0;
        state.grow(0, 9_400, &cfg, 10_000);
        assert_eq!(
            (capped, state.suggested_interval(0, &cfg).0),
            (10_000, 9_900)
        );
    }

    #[test]
    fn tighten_source_max_never_loosens_under_a_stale_read() {
        // Requests of one chain fail concurrently, so both read the ceiling
        // before either wrote. The later write must not raise a cap the earlier
        // one already lowered — the caller's copy is stale by then.
        let state = IntervalState::new();
        let cfg = test_config();
        let (_, first_read) = state.suggested_interval(0, &cfg);
        let (_, second_read) = state.suggested_interval(1, &cfg);
        state.tighten_source_max(first_read, 1_000);
        assert_eq!(
            (
                state.tighten_source_max(second_read, 5_000),
                state.suggested_interval(0, &cfg).1
            ),
            (1_000, 1_000)
        );
    }

    #[test]
    fn tighten_source_max_only_ever_shrinks() {
        let state = IntervalState::new();
        assert_eq!(state.tighten_source_max(10_000, 1_000), 1_000);
        // A later, looser suggestion doesn't undo the earlier tightening.
        assert_eq!(state.tighten_source_max(1_000, 5_000), 1_000);
    }

    #[test]
    fn streams_are_independent() {
        let state = IntervalState::new();
        let cfg = test_config();
        state.set(0, 2_000);
        state.set(1, 3_000);
        assert_eq!(
            [0, 1, 2].map(|stream| state.suggested_interval(stream, &cfg).0),
            [2_000, 3_000, cfg.initial_block_interval]
        );
    }
}
