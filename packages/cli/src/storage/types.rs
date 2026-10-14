//! What a storage reads and writes, independent of which database holds it.

use anyhow::{bail, Result};

/// The names both stores give the indexer's own tables and the columns an
/// entity's history adds to its fields. Tests and tools on the JavaScript side
/// read them by these names too.
pub const CHECKPOINT_ID_COLUMN: &str = "envio_checkpoint_id";
pub const CHANGE_COLUMN: &str = "envio_change";
pub const SET: &str = "SET";
pub const DELETE: &str = "DELETE";
pub const CHAINS_TABLE: &str = "envio_chains";
pub const INFO_TABLE: &str = "envio_info";
pub const CONTRACTS_TABLE: &str = "envio_contracts";
pub const ADDRESSES_TABLE: &str = "envio_addresses";
pub const CHECKPOINTS_TABLE: &str = "envio_checkpoints";
pub const RAW_EVENTS_TABLE: &str = "raw_events";

/// How checkpoint ids are handed out. Under one shared counter a row's id is
/// comparable with any other chain's, so a bound is a single id; with a counter
/// per chain ids are only comparable within a chain, and every bound names one.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Sequence {
    SharedAcrossChains,
    PerChain,
}

impl Sequence {
    pub fn parse(value: &str) -> Result<Self> {
        match value {
            "SharedAcrossChains" => Ok(Sequence::SharedAcrossChains),
            "PerChain" => Ok(Sequence::PerChain),
            other => bail!("`{other}` is not a checkpoint sequence"),
        }
    }
}

/// Which rows a bounded operation reaches: the chains and the checkpoint each
/// is held to.
#[derive(Clone, Debug)]
pub struct Bounds {
    pub sequence: Sequence,
    pub chain_ids: Vec<i64>,
    pub checkpoint_ids: Vec<i64>,
}

impl Bounds {
    /// Under one shared sequence every chain is held to the lowest of the ids:
    /// a higher one would leave another chain's rows above its own bound.
    pub fn shared_id(&self) -> i64 {
        self.checkpoint_ids.iter().min().copied().unwrap_or(0)
    }

    pub fn by_chain(&self) -> impl Iterator<Item = (i64, i64)> + '_ {
        self.chain_ids
            .iter()
            .copied()
            .zip(self.checkpoint_ids.iter().copied())
    }
}

/// What a chain starts out as.
#[derive(Clone, Debug)]
pub struct ChainConfig {
    pub id: i64,
    pub ecosystem: String,
    pub start_block: i32,
    pub end_block: Option<i32>,
    pub max_reorg_depth: i32,
}

#[derive(Clone, Debug)]
pub struct Progress {
    pub chain_id: i64,
    pub progress_block: i32,
    /// Unix seconds, as a block header carries them.
    pub progress_block_time: Option<f64>,
    pub events_processed: f64,
    pub source_block: i32,
}

#[derive(Clone, Debug)]
pub struct ChainMeta {
    pub chain_id: i64,
    pub first_event_block: Option<i32>,
    pub buffer_block: i32,
    /// Unix milliseconds.
    pub ready_at: Option<f64>,
    pub is_hyper_sync: bool,
}

/// Address rows, column by column. A key leaves the registration blocks out.
#[derive(Clone, Debug, Default)]
pub struct Addresses {
    pub chain_ids: Vec<i64>,
    pub addresses: Vec<Vec<u8>>,
    pub contract_ids: Vec<i32>,
    pub registration_blocks: Vec<i32>,
    /// The checkpoint each registration belongs to. Only a store that keeps
    /// addresses as a history of changes reads it.
    pub checkpoint_ids: Vec<i64>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Checkpoints {
    pub ids: Vec<i64>,
    pub chain_ids: Vec<i64>,
    pub block_numbers: Vec<i32>,
    pub block_hashes: Vec<Option<String>>,
    pub events_processed: Vec<i64>,
    /// Whether each checkpoint anchors history its chain keeps. A store that
    /// only keeps the checkpoints a rollback can reach writes just these.
    pub keeps_history: Vec<bool>,
}

impl Checkpoints {
    pub fn len(&self) -> usize {
        self.ids.len()
    }

    /// The ones anchoring history, in the same order.
    pub fn keeping_history(&self) -> Checkpoints {
        let picked = |index: &usize| self.keeps_history.get(*index).copied().unwrap_or(true);
        let indexes = (0..self.len()).filter(picked).collect::<Vec<_>>();
        Checkpoints {
            ids: indexes.iter().map(|&index| self.ids[index]).collect(),
            chain_ids: indexes.iter().map(|&index| self.chain_ids[index]).collect(),
            block_numbers: indexes
                .iter()
                .map(|&index| self.block_numbers[index])
                .collect(),
            block_hashes: indexes
                .iter()
                .map(|&index| self.block_hashes[index].clone())
                .collect(),
            events_processed: indexes
                .iter()
                .map(|&index| self.events_processed[index])
                .collect(),
            keeps_history: vec![true; indexes.len()],
        }
    }
}

/// Where a write leaves each chain's checkpoint sequence.
#[derive(Clone, Debug, Default)]
pub struct Frontier {
    pub chain_ids: Vec<i64>,
    pub checkpoint_ids: Vec<i64>,
}

impl Frontier {
    pub fn entries(&self) -> impl Iterator<Item = (i64, i64)> + '_ {
        self.chain_ids
            .iter()
            .copied()
            .zip(self.checkpoint_ids.iter().copied())
    }
}

/// The checkpoint a rollback's diff rows are stamped with, one per chain the
/// rollback moved.
#[derive(Clone, Debug)]
pub struct DiffCheckpoint {
    pub chain_id: i64,
    pub checkpoint_id: i64,
    /// Where the rollback left the chain.
    pub block_number: i32,
}

pub struct StoredChain {
    pub id: i64,
    pub ecosystem: String,
    pub start_block: i32,
    pub end_block: Option<i32>,
    pub max_reorg_depth: i32,
}

pub struct StoredConfig {
    /// None for a schema an older envio wrote, without the record.
    pub envio_info: Option<String>,
    pub contract_names: Option<Vec<String>>,
    pub chains: Vec<StoredChain>,
}

#[derive(Clone, Debug)]
pub struct ResumedChain {
    pub id: i64,
    pub ecosystem: String,
    pub start_block: i32,
    pub end_block: Option<i32>,
    pub max_reorg_depth: i32,
    pub first_event_block: Option<i32>,
    /// Unix milliseconds.
    pub ready_at: Option<f64>,
    pub events_processed: f64,
    pub progress_block: i32,
    /// Unix seconds.
    pub progress_block_time: Option<f64>,
    pub source_block: i32,
    pub checkpoint_id: i64,
}

pub struct ReorgCheckpoint {
    pub id: i64,
    pub chain_id: i64,
    pub block_number: i32,
    pub block_hash: String,
}

pub struct ProgressDiff {
    pub chain_id: i64,
    pub events_processed: i64,
    pub progress_block: i32,
}

pub struct CacheTable {
    pub table_name: String,
    pub rows: i32,
}

/// The registration block a config-declared address is stored with, which
/// tells it apart from one a handler registered.
pub const CONFIG_REGISTRATION_BLOCK: i32 = -1;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checkpoints_keeping_history_keep_their_order() {
        let checkpoints = Checkpoints {
            ids: vec![1, 2, 3],
            chain_ids: vec![1, 137, 1],
            block_numbers: vec![10, 20, 30],
            block_hashes: vec![None, Some("0xb".to_string()), Some("0xc".to_string())],
            events_processed: vec![1, 2, 3],
            keeps_history: vec![false, true, true],
        };
        assert_eq!(
            checkpoints.keeping_history(),
            Checkpoints {
                ids: vec![2, 3],
                chain_ids: vec![137, 1],
                block_numbers: vec![20, 30],
                block_hashes: vec![Some("0xb".to_string()), Some("0xc".to_string())],
                events_processed: vec![2, 3],
                keeps_history: vec![true, true],
            }
        );
    }
}
