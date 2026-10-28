//! What one write carries, whichever stores take it. Each store reads the part
//! it keeps: Postgres everything, ClickHouse the entities it keeps, the
//! checkpoints mapping them to blocks and the frontier making them readable.

use std::sync::Arc;

use super::changes::ChangeSet;
use super::types::{Addresses, Bounds, ChainMeta, Checkpoints, DiffCheckpoint, Frontier, Progress};
use crate::columnar::Arena;

pub struct RollbackWrite {
    pub bounds: Bounds,
    /// Where the rollback left each chain it moved.
    pub progress: Vec<Progress>,
    /// Registrations the rollback dropped.
    pub removed_addresses: Addresses,
    /// The checkpoint each chain the rollback moved stamps its diff with.
    pub diff_checkpoints: Vec<DiffCheckpoint>,
}

pub struct EffectCacheWrite {
    pub table: String,
    /// The first write to a cache creates its table.
    pub create: bool,
    pub rows: Arena,
}

/// An empty list is nothing to write.
#[derive(Default)]
pub struct Batch {
    pub rollback: Option<RollbackWrite>,
    pub progress: Vec<Progress>,
    pub raw_events: Option<Arena>,
    pub changes: Vec<Arc<ChangeSet>>,
    pub chain_meta: Vec<ChainMeta>,
    /// Addresses the batch registered, with the checkpoint covering each.
    pub addresses: Addresses,
    pub frontier: Frontier,
    pub checkpoints: Checkpoints,
    pub effect_caches: Vec<EffectCacheWrite>,
}

impl Batch {
    /// The checkpoint a rollback stamped a scope's diff with. A cross-chain
    /// scope exists only under one shared sequence, where the diff's ids were
    /// handed out in a single run and the scope's is the last of them.
    pub fn diff_checkpoint(&self, chain_id: Option<i64>) -> Option<i64> {
        let diffs = &self.rollback.as_ref()?.diff_checkpoints;
        match chain_id {
            Some(chain_id) => diffs
                .iter()
                .find(|diff| diff.chain_id == chain_id)
                .map(|diff| diff.checkpoint_id),
            None => diffs.iter().map(|diff| diff.checkpoint_id).max(),
        }
    }

    /// The checkpoints ClickHouse maps its history rows to blocks with: the
    /// batch's, and the diff's a rollback wrote rows at.
    pub fn checkpoints_with_diff(&self) -> Checkpoints {
        let mut checkpoints = self.checkpoints.clone();
        for diff in self
            .rollback
            .iter()
            .flat_map(|rollback| &rollback.diff_checkpoints)
        {
            checkpoints.ids.push(diff.checkpoint_id);
            checkpoints.chain_ids.push(diff.chain_id);
            checkpoints.block_numbers.push(diff.block_number);
            checkpoints.block_hashes.push(None);
            checkpoints.events_processed.push(0);
            checkpoints.keeps_history.push(false);
        }
        checkpoints
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::types::Sequence;
    use pretty_assertions::assert_eq;

    fn with_diffs(diffs: &[(i64, i64)]) -> Batch {
        Batch {
            rollback: Some(RollbackWrite {
                bounds: Bounds {
                    sequence: Sequence::PerChain,
                    chain_ids: vec![1],
                    checkpoint_ids: vec![1],
                },
                progress: Vec::new(),
                removed_addresses: Addresses::default(),
                diff_checkpoints: diffs
                    .iter()
                    .map(|&(chain_id, checkpoint_id)| DiffCheckpoint {
                        chain_id,
                        checkpoint_id,
                        block_number: 15,
                    })
                    .collect(),
            }),
            checkpoints: Checkpoints {
                ids: vec![5],
                chain_ids: vec![1],
                block_numbers: vec![16],
                block_hashes: vec![Some("0x10".to_string())],
                events_processed: vec![2],
                keeps_history: vec![true],
            },
            ..Batch::default()
        }
    }

    #[test]
    fn a_rollback_reaches_clickhouse_as_the_checkpoints_of_its_diff() {
        assert_eq!(
            with_diffs(&[(1, 4)]).checkpoints_with_diff(),
            Checkpoints {
                ids: vec![5, 4],
                chain_ids: vec![1, 1],
                block_numbers: vec![16, 15],
                block_hashes: vec![Some("0x10".to_string()), None],
                events_processed: vec![2, 0],
                keeps_history: vec![true, false],
            }
        );
    }

    #[test]
    fn a_scope_finds_its_diff_among_the_chains_the_rollback_moved() {
        let batch = with_diffs(&[(1, 4), (137, 5)]);
        assert_eq!(
            (
                batch.diff_checkpoint(Some(137)),
                batch.diff_checkpoint(Some(10)),
                batch.diff_checkpoint(None),
                Batch::default().diff_checkpoint(None),
            ),
            (Some(5), None, Some(5), None)
        );
    }
}
