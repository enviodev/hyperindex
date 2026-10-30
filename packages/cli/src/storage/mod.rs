//! The indexer's storage, in three layers:
//!
//! - the domain: the [`schema`] of what is stored, the [`changes`] a batch
//!   makes to it and the [`batch`] that carries them, and where an
//!   [`effect_cache`] is kept between runs, none of it knowing a database;
//! - the [`service`], which keeps every configured store in step: Postgres as
//!   the store of record, ClickHouse beside it;
//! - the stores themselves, in `crate::postgres` and `crate::clickhouse`, each
//!   reading what it keeps off the same domain values.
//!
//! JavaScript reaches all of it through [`js`], which only converts.

pub mod batch;
pub mod changes;
pub mod effect_cache;
pub mod handoff;
pub mod rows;
pub mod schema;
pub mod service;
pub mod types;

// The addon registers these; a test build has no registration and would see
// every export as dead.
#[cfg_attr(test, allow(dead_code))]
mod js;
#[cfg(test)]
mod live_tests;

pub use batch::{Batch, RollbackWrite};
pub use handoff::{Failure, Handoff, WriteError};
pub use service::Storage;

use rows::ResultSet;
use types::{Addresses, ChainConfig, ResumedChain};

#[napi_derive::napi(string_enum)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Store {
    Postgres,
    ClickHouse,
}

/// What the stores hold before anything is initialized or resumed.
#[napi_derive::napi(string_enum)]
#[derive(Debug, PartialEq, Eq)]
pub enum Holding {
    Nothing,
    Initialized,
    /// ClickHouse holds indexed data Postgres has none of.
    Stranded,
    /// Postgres holds indexed data the ClickHouse beside it doesn't.
    Diverged,
    /// Postgres was built by an older envio, which kept no instance to pair
    /// it with the ClickHouse beside it.
    Outdated,
}

/// What a new storage starts out with besides the schema's tables.
pub struct Initialize {
    pub chains: Vec<ChainConfig>,
    pub envio_info: String,
    pub contract_names: Vec<String>,
    pub addresses: Addresses,
}

pub struct AddChain {
    pub chain: ChainConfig,
    pub addresses: Addresses,
}

/// What ClickHouse resumes to: what Postgres committed for the chains this run
/// drives. Only their rows are trimmed: a sibling process driving another
/// chain may be mid-write above its frontier.
pub struct Resume {
    pub committed: Vec<ResumedChain>,
}

pub struct Resumed {
    pub chains: Vec<ResumedChain>,
    pub addresses: ResultSet,
    pub reorg_checkpoints: Vec<types::ReorgCheckpoint>,
}

pub struct StoredConfigRead {
    pub config: types::StoredConfig,
    /// The addresses the config declared, as the stored rows hold them.
    pub config_addresses: ResultSet,
}
