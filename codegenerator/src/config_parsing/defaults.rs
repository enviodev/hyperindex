pub struct SyncConfigDefaults {
    pub initial_block_interval: u32,
    pub backoff_multiplicative: f32,
    pub acceleration_additive: u32,
    pub interval_ceiling: u32,
    pub backoff_millis: u32,
    pub query_timeout_millis: u32,
}

pub const SYNC_CONFIG: SyncConfigDefaults = SyncConfigDefaults {
    initial_block_interval: 10_000,
    backoff_multiplicative: 0.8,
    acceleration_additive: 2_000,
    interval_ceiling: 10_000,
    backoff_millis: 5000,
    query_timeout_millis: 20_000,
};
