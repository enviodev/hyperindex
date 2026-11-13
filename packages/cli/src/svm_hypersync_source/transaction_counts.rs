//! A slot's transaction counts. No table carries them, so a query asks for
//! every transaction's slot and outcome and the rows are tallied off the
//! response's Arrow columns: a slot holds hundreds of transactions, too many
//! to decode a row for each.

use std::collections::HashMap;

use anyhow::{anyhow, ensure, Result};
use arrow::array::{Array, BooleanArray, UInt64Array};
use arrow::record_batch::RecordBatch;
use hypersync_solana_net_types::field_selection::{
    BlockField, SolanaFieldSelection, TransactionField,
};
use hypersync_solana_net_types::query::{SolanaQuery, TransactionSelection};

use crate::block_store::SvmTransactionCounts;

/// Left unset, the server ends a page at about 10,000 transactions, some 25
/// slots. A transaction costs this query two narrow columns, so the cap is
/// raised past what the server returns anyway: it ended a page at 486 slots
/// and 197,000 transactions when measured.
const MAX_NUM_TRANSACTIONS: usize = 1_000_000;

/// Every block of `[from_slot, to_slot)` beside every transaction's slot and
/// outcome. It selects no other table: joined to a selection matching every
/// transaction, the instruction table would return each one's instructions.
pub(super) fn query(
    from_slot: u64,
    to_slot: Option<u64>,
    block: Vec<BlockField>,
    max_num_blocks: Option<usize>,
) -> SolanaQuery {
    SolanaQuery {
        from_slot,
        to_slot,
        transactions: vec![TransactionSelection::default()],
        include_all_blocks: true,
        field_selection: SolanaFieldSelection {
            block,
            transaction: vec![TransactionField::Slot, TransactionField::Success],
            ..Default::default()
        },
        max_num_blocks,
        max_num_transactions: Some(MAX_NUM_TRANSACTIONS),
        ..Default::default()
    }
}

fn column<'a, T: 'static>(batch: &'a RecordBatch, name: &str) -> Result<&'a T> {
    batch
        .column_by_name(name)
        .ok_or_else(|| anyhow!("transactions table has no {name} column"))?
        .as_any()
        .downcast_ref::<T>()
        .ok_or_else(|| anyhow!("transactions column {name} has an unexpected arrow type"))
}

/// A transaction whose outcome the source could not tell counts as a
/// transaction, not as a failed one.
pub(super) fn count_by_slot(
    transactions: &RecordBatch,
) -> Result<HashMap<u64, SvmTransactionCounts>> {
    let mut counts: HashMap<u64, SvmTransactionCounts> = HashMap::new();
    if transactions.num_rows() == 0 {
        return Ok(counts);
    }
    let slots = column::<UInt64Array>(transactions, "slot")?;
    let successes = column::<BooleanArray>(transactions, "success")?;
    for row in 0..transactions.num_rows() {
        ensure!(slots.is_valid(row), "transaction row {row} has no slot");
        let slot = counts.entry(slots.value(row)).or_default();
        slot.total += 1;
        if successes.is_valid(row) && !successes.value(row) {
            slot.failed += 1;
        }
    }
    Ok(counts)
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use arrow::datatypes::{DataType, Field, Schema};

    use super::*;

    #[test]
    fn tallies_transactions_and_failures_per_slot() {
        let batch = RecordBatch::try_new(
            Arc::new(Schema::new(vec![
                Field::new("slot", DataType::UInt64, true),
                Field::new("success", DataType::Boolean, true),
            ])),
            vec![
                Arc::new(UInt64Array::from(vec![7, 7, 7, 9, 9])),
                Arc::new(BooleanArray::from(vec![
                    Some(true),
                    Some(false),
                    None,
                    Some(false),
                    Some(false),
                ])),
            ],
        )
        .unwrap();

        let mut counts: Vec<_> = count_by_slot(&batch).unwrap().into_iter().collect();
        counts.sort_unstable_by_key(|(slot, _)| *slot);

        assert_eq!(
            counts,
            vec![
                (
                    7,
                    SvmTransactionCounts {
                        total: 3,
                        failed: 1
                    }
                ),
                (
                    9,
                    SvmTransactionCounts {
                        total: 2,
                        failed: 2
                    }
                ),
            ]
        );
    }
}
