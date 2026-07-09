use std::collections::HashMap;
use std::sync::Mutex;

/// The resolved (env-overridden, defaulted) sync-tuning knobs a `RpcSource`
/// passes in at construction — mirrors ReScript's `Config.sourceSync`, minus
/// the fields (`fallbackStallTimeout`, `pollingInterval`) that stay JS-side
/// scheduling concerns unrelated to paging.
#[derive(Clone, Copy)]
pub struct SyncConfig {
    pub initial_block_interval: u64,
    pub backoff_multiplicative: f64,
    pub acceleration_additive: u64,
    pub interval_ceiling: u64,
    pub backoff_millis: u64,
    pub query_timeout_millis: u64,
}

impl SyncConfig {
    pub const fn default_initial_block_interval() -> u64 {
        10_000
    }
    pub const fn default_backoff_multiplicative() -> f64 {
        0.8
    }
    pub const fn default_acceleration_additive() -> u64 {
        500
    }
    pub const fn default_interval_ceiling() -> u64 {
        10_000
    }
    pub const fn default_backoff_millis() -> u64 {
        2_000
    }
    pub const fn default_query_timeout_millis() -> u64 {
        20_000
    }
}

impl Default for SyncConfig {
    fn default() -> Self {
        Self {
            initial_block_interval: Self::default_initial_block_interval(),
            backoff_multiplicative: Self::default_backoff_multiplicative(),
            acceleration_additive: Self::default_acceleration_additive(),
            interval_ceiling: Self::default_interval_ceiling(),
            backoff_millis: Self::default_backoff_millis(),
            query_timeout_millis: Self::default_query_timeout_millis(),
        }
    }
}

/// Per-partition adaptive block interval (AIMD), keyed by partition id. The
/// `source_max` ceiling only ever tightens, set by structural provider limits
/// ("limited to N blocks"). A partition's own entry can go stale when
/// partitions merge/split — acceptable, it re-adapts.
/// See: <https://en.wikipedia.org/wiki/Additive_increase/multiplicative_decrease>
pub struct IntervalState {
    partitions: Mutex<HashMap<String, u64>>,
    source_max: Mutex<Option<u64>>,
}

impl IntervalState {
    pub fn new() -> Self {
        Self {
            partitions: Mutex::new(HashMap::new()),
            source_max: Mutex::new(None),
        }
    }

    fn source_max_interval(&self, ceiling: u64) -> u64 {
        self.source_max.lock().unwrap().unwrap_or(ceiling)
    }

    /// Reads this partition's suggested interval, clamped to the source-wide
    /// ceiling. Returns the clamped interval alongside the ceiling it was
    /// clamped to, so callers can reuse the ceiling without a second lock.
    pub fn suggested_interval(&self, partition_id: &str, cfg: &SyncConfig) -> (u64, u64) {
        let source_max = self.source_max_interval(cfg.interval_ceiling);
        let partition = self
            .partitions
            .lock()
            .unwrap()
            .get(partition_id)
            .copied()
            .unwrap_or(cfg.initial_block_interval);
        (partition.min(source_max), source_max)
    }

    /// Additive increase: grows this partition's interval, capped at `source_max`.
    pub fn grow(
        &self,
        partition_id: &str,
        executed_interval: u64,
        cfg: &SyncConfig,
        source_max: u64,
    ) {
        self.partitions.lock().unwrap().insert(
            partition_id.to_string(),
            (executed_interval + cfg.acceleration_additive).min(source_max),
        );
    }

    pub fn set_partition(&self, partition_id: &str, interval: u64) {
        self.partitions
            .lock()
            .unwrap()
            .insert(partition_id.to_string(), interval);
    }

    /// A provider reported a structural, source-wide cap — tighten (never
    /// loosen) the ceiling and return the resulting value.
    pub fn tighten_source_max(&self, current_source_max: u64, interval: u64) -> u64 {
        let capped = current_source_max.min(interval);
        *self.source_max.lock().unwrap() = Some(capped);
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
            initial_block_interval: 10_000,
            interval_ceiling: 5_000,
            ..SyncConfig::default()
        };
        assert_eq!(state.suggested_interval("0", &cfg), (5_000, 5_000));
    }

    #[test]
    fn grow_caps_at_source_max() {
        let state = IntervalState::new();
        let cfg = SyncConfig {
            acceleration_additive: 500,
            ..SyncConfig::default()
        };
        state.grow("0", 9_800, &cfg, 10_000);
        assert_eq!(state.suggested_interval("0", &cfg).0, 10_000);

        state.grow("0", 9_400, &cfg, 10_000);
        assert_eq!(state.suggested_interval("0", &cfg).0, 9_900);
    }

    #[test]
    fn tighten_source_max_only_ever_shrinks() {
        let state = IntervalState::new();
        assert_eq!(state.tighten_source_max(10_000, 1_000), 1_000);
        // A later, looser suggestion doesn't undo the earlier tightening.
        assert_eq!(state.tighten_source_max(1_000, 5_000), 1_000);
    }

    #[test]
    fn partitions_are_independent() {
        let state = IntervalState::new();
        let cfg = SyncConfig::default();
        state.set_partition("a", 2_000);
        state.set_partition("b", 3_000);
        assert_eq!(state.suggested_interval("a", &cfg).0, 2_000);
        assert_eq!(state.suggested_interval("b", &cfg).0, 3_000);
        assert_eq!(
            state.suggested_interval("c", &cfg).0,
            cfg.initial_block_interval
        );
    }
}
