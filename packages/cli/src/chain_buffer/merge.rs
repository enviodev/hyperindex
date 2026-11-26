//! A page joins the buffer: its block hashes are checked against the stored
//! ones first, and on a mismatch nothing of it is merged.

use napi_derive::napi;

use super::matching_transactions::TransactionView;
use super::page::PageData;
use super::table::{make_key, Table, LAST_BLOCK};
use super::{Ecosystem, Shared, Tables};

/// The lowest block whose received hash differs from the stored one.
#[napi(object)]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HashMismatch {
    pub block_number: i64,
    pub stored_hash: String,
    pub received_hash: String,
}

/// The lowest block at or above `from_block` both tables hold a hash for,
/// where they differ.
pub(crate) fn first_hash_mismatch(
    stored: &Table,
    incoming: &Table,
    from_block: u64,
    ecosystem: Ecosystem,
) -> Option<HashMismatch> {
    let column = ecosystem.hash_column();
    incoming
        .rows_in_block_range(from_block, LAST_BLOCK)
        .find_map(|row| {
            let received = row.bytes_at(column)?;
            let stored = stored.find(make_key(row.block_number(), 0), 0)?;
            let stored = stored.bytes_at(column)?;
            (stored != received).then(|| HashMismatch {
                block_number: row.block_number() as i64,
                stored_hash: ecosystem.hash_text(stored),
                received_hash: ecosystem.hash_text(received),
            })
        })
}

/// The page's transactions a transaction handler runs on that the store holds
/// no running copy of yet: rows like any other for the density a partition is
/// priced by, counted once however many pages bring them.
fn count_newly_matched_transactions(shared: &Shared, stored: &Table, incoming: &Table) -> usize {
    let matcher = &shared.transaction_matcher;
    if matcher.is_empty() {
        return 0;
    }
    incoming
        .rows_in_block_range(0, LAST_BLOCK)
        .filter(|row| {
            matcher.matches_any(&TransactionView::of_row(row))
                && !stored
                    .find(row.key(), 0)
                    .is_some_and(|stored| matcher.matches_any(&TransactionView::of_row(&stored)))
        })
        .count()
}

/// The blocks `incoming` holds under a hash other than the stored one: a
/// different block at the same number, whose row replaces the stored one.
fn blocks_with_other_hash(stored: &Table, incoming: &Table, ecosystem: Ecosystem) -> Vec<u64> {
    let column = ecosystem.hash_column();
    incoming
        .rows_in_block_range(0, LAST_BLOCK)
        .filter(|row| {
            let Some(received) = row.bytes_at(column) else {
                return false;
            };
            stored
                .find(make_key(row.block_number(), 0), 0)
                .and_then(|stored| stored.bytes_at(column))
                .is_some_and(|stored| stored != received)
        })
        .map(|row| row.block_number())
        .collect()
}

pub(crate) struct Merged {
    pub(crate) mismatch: Option<HashMismatch>,
    pub(crate) rows_kept: usize,
    pub(crate) registering_blocks: Vec<u64>,
}

/// Merges `page` into `tables` unless its hashes at or above
/// `reorg_threshold` disagree with the stored ones; `report_only` merges it
/// even then.
pub(crate) fn merge_page(
    shared: &Shared,
    tables: &mut Tables,
    mut page: PageData,
    reorg_threshold: u64,
    report_only: bool,
) -> Merged {
    let mismatch = first_hash_mismatch(
        &tables.blocks,
        &page.blocks,
        reorg_threshold,
        page.ecosystem,
    );
    if mismatch.is_some() && !report_only {
        return Merged {
            mismatch,
            rows_kept: 0,
            registering_blocks: Vec::new(),
        };
    }
    let rows_kept = tables.events.merge_table(&page.events)
        + tables.decoded.merge(&page.decoded)
        + count_newly_matched_transactions(shared, &tables.transactions, &page.transactions);
    tables.transactions.merge_table(&page.transactions);
    for block_number in blocks_with_other_hash(&tables.blocks, &page.blocks, page.ecosystem) {
        tables.blocks.remove_block_range(block_number, block_number);
    }
    tables.blocks.merge_table(&page.blocks);
    let mut registering_blocks = std::mem::take(&mut page.registering_blocks);
    registering_blocks.extend(
        page.decoded
            .registering_blocks(|registration| shared.has_contract_register(registration)),
    );
    registering_blocks.sort_unstable();
    registering_blocks.dedup();
    Merged {
        mismatch,
        rows_kept,
        registering_blocks,
    }
}
