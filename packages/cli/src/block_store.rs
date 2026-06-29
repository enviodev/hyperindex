//! Per-chain block store. Blocks are kept as raw upstream structs (their large
//! fields, e.g. `logsBloom`/`extraData`, never cross the napi boundary until
//! they are read), keyed by block number. One block per number — many logs share
//! it — so a plain insert deduplicates. At batch preparation the fields a chain's
//! events selected are decoded in bulk, off the JS thread, into columnar form;
//! the main thread zips the columns into plain JS objects. The store lives on the
//! ReScript `ChainState`; fetch responses merge in, and entries are pruned/rolled
//! back by block.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use hypersync_client::format::Hex;
use hypersync_client::simple_types;
use napi_derive::napi;
use strum::VariantArray;

use crate::evm_hypersync_source::map_err;
use crate::evm_hypersync_source::types::{map_address_string, map_bigint, map_hex_string, map_i64};
use crate::field_columns::{build_columns, fill_masked, Column, Columns};

/// EVM block field codes shared with ReScript by ordinal value. The order is the
/// contract: it mirrors `Evm.res` `blockFields`, and the ordinal is the bit
/// position in the selection mask. Keep the two in sync — guarded by a test.
#[derive(Clone, Copy, PartialEq, Eq, Debug, VariantArray)]
#[repr(i32)]
pub enum EvmBlockField {
    Number = 0,
    Timestamp = 1,
    Hash = 2,
    ParentHash = 3,
    Nonce = 4,
    Sha3Uncles = 5,
    LogsBloom = 6,
    TransactionsRoot = 7,
    StateRoot = 8,
    ReceiptsRoot = 9,
    Miner = 10,
    Difficulty = 11,
    TotalDifficulty = 12,
    ExtraData = 13,
    Size = 14,
    GasLimit = 15,
    GasUsed = 16,
    Uncles = 17,
    BaseFeePerGas = 18,
    BlobGasUsed = 19,
    ExcessBlobGas = 20,
    ParentBeaconBlockRoot = 21,
    WithdrawalsRoot = 22,
    L1BlockNumber = 23,
    SendCount = 24,
    SendRoot = 25,
    MixHash = 26,
}

impl EvmBlockField {
    /// JS property name; must match `Evm.res` `blockFields`. Used as the object
    /// key when zipping columns into JS objects.
    pub fn name(self) -> &'static str {
        use EvmBlockField::*;
        match self {
            Number => "number",
            Timestamp => "timestamp",
            Hash => "hash",
            ParentHash => "parentHash",
            Nonce => "nonce",
            Sha3Uncles => "sha3Uncles",
            LogsBloom => "logsBloom",
            TransactionsRoot => "transactionsRoot",
            StateRoot => "stateRoot",
            ReceiptsRoot => "receiptsRoot",
            Miner => "miner",
            Difficulty => "difficulty",
            TotalDifficulty => "totalDifficulty",
            ExtraData => "extraData",
            Size => "size",
            GasLimit => "gasLimit",
            GasUsed => "gasUsed",
            Uncles => "uncles",
            BaseFeePerGas => "baseFeePerGas",
            BlobGasUsed => "blobGasUsed",
            ExcessBlobGas => "excessBlobGas",
            ParentBeaconBlockRoot => "parentBeaconBlockRoot",
            WithdrawalsRoot => "withdrawalsRoot",
            L1BlockNumber => "l1BlockNumber",
            SendCount => "sendCount",
            SendRoot => "sendRoot",
            MixHash => "mixHash",
        }
    }
}

/// Decode the per-row mask-selected fields of the given EVM blocks into columns.
/// A field's column is built when any row selects it (the union of `masks`);
/// within it a row whose own mask lacks the field gets a `None` cell, so a large
/// field (e.g. `logsBloom`) is only touched on the rows that asked for it. Runs
/// off the JS thread. `block_numbers` is the requested key per row, so `number`
/// resolves from the key (always known) rather than a stored record.
fn decode_evm_block_columns(
    records: &[Option<Arc<simple_types::Block>>],
    block_numbers: &[i64],
    masks: &[u64],
    should_checksum: bool,
) -> Result<Columns> {
    let union = masks.iter().fold(0u64, |acc, &m| acc | m);
    build_columns(
        EvmBlockField::VARIANTS,
        union,
        records.len(),
        |f| f as u32,
        |f| f.name(),
        |f| decode_evm_block_field(f, records, block_numbers, masks, should_checksum),
    )
}

/// Decode a single EVM block field, materialising it only on the rows whose mask
/// has the field's bit set. Exhaustive match: adding an `EvmBlockField` variant
/// fails to compile until it is decoded here.
fn decode_evm_block_field(
    field: EvmBlockField,
    records: &[Option<Arc<simple_types::Block>>],
    block_numbers: &[i64],
    masks: &[u64],
    should_checksum: bool,
) -> Result<Column> {
    let bit = 1u64 << (field as u32);
    Ok(match field {
        // The block number is the store key, so it's always available regardless
        // of whether the block row was fetched.
        EvmBlockField::Number => Column::I64(
            block_numbers
                .iter()
                .zip(masks)
                .map(|(&n, &m)| (m & bit != 0).then_some(n))
                .collect(),
        ),
        EvmBlockField::Timestamp => {
            Column::I64(fill_masked(records, masks, bit, |b| map_i64(&b.timestamp))?)
        }
        EvmBlockField::Hash => Column::Str(fill_masked(records, masks, bit, |b| {
            Ok(map_hex_string(&b.hash))
        })?),
        EvmBlockField::ParentHash => Column::Str(fill_masked(records, masks, bit, |b| {
            Ok(map_hex_string(&b.parent_hash))
        })?),
        EvmBlockField::Nonce => Column::Big(fill_masked(records, masks, bit, |b| {
            Ok(map_bigint(&b.nonce))
        })?),
        EvmBlockField::Sha3Uncles => Column::Str(fill_masked(records, masks, bit, |b| {
            Ok(map_hex_string(&b.sha3_uncles))
        })?),
        EvmBlockField::LogsBloom => Column::Str(fill_masked(records, masks, bit, |b| {
            Ok(map_hex_string(&b.logs_bloom))
        })?),
        EvmBlockField::TransactionsRoot => Column::Str(fill_masked(records, masks, bit, |b| {
            Ok(map_hex_string(&b.transactions_root))
        })?),
        EvmBlockField::StateRoot => Column::Str(fill_masked(records, masks, bit, |b| {
            Ok(map_hex_string(&b.state_root))
        })?),
        EvmBlockField::ReceiptsRoot => Column::Str(fill_masked(records, masks, bit, |b| {
            Ok(map_hex_string(&b.receipts_root))
        })?),
        EvmBlockField::Miner => Column::Str(fill_masked(records, masks, bit, |b| {
            Ok(map_address_string(&b.miner, should_checksum))
        })?),
        EvmBlockField::Difficulty => Column::Big(fill_masked(records, masks, bit, |b| {
            Ok(map_bigint(&b.difficulty))
        })?),
        EvmBlockField::TotalDifficulty => Column::Big(fill_masked(records, masks, bit, |b| {
            Ok(map_bigint(&b.total_difficulty))
        })?),
        EvmBlockField::ExtraData => Column::Str(fill_masked(records, masks, bit, |b| {
            Ok(map_hex_string(&b.extra_data))
        })?),
        EvmBlockField::Size => Column::Big(fill_masked(records, masks, bit, |b| {
            Ok(map_bigint(&b.size))
        })?),
        EvmBlockField::GasLimit => Column::Big(fill_masked(records, masks, bit, |b| {
            Ok(map_bigint(&b.gas_limit))
        })?),
        EvmBlockField::GasUsed => Column::Big(fill_masked(records, masks, bit, |b| {
            Ok(map_bigint(&b.gas_used))
        })?),
        EvmBlockField::Uncles => Column::StrVec(fill_masked(records, masks, bit, |b| {
            Ok(b.uncles
                .as_ref()
                .map(|arr| arr.iter().map(|u| u.encode_hex()).collect()))
        })?),
        EvmBlockField::BaseFeePerGas => Column::Big(fill_masked(records, masks, bit, |b| {
            Ok(map_bigint(&b.base_fee_per_gas))
        })?),
        EvmBlockField::BlobGasUsed => Column::Big(fill_masked(records, masks, bit, |b| {
            Ok(map_bigint(&b.blob_gas_used))
        })?),
        EvmBlockField::ExcessBlobGas => Column::Big(fill_masked(records, masks, bit, |b| {
            Ok(map_bigint(&b.excess_blob_gas))
        })?),
        EvmBlockField::ParentBeaconBlockRoot => {
            Column::Str(fill_masked(records, masks, bit, |b| {
                Ok(map_hex_string(&b.parent_beacon_block_root))
            })?)
        }
        EvmBlockField::WithdrawalsRoot => Column::Str(fill_masked(records, masks, bit, |b| {
            Ok(map_hex_string(&b.withdrawals_root))
        })?),
        EvmBlockField::L1BlockNumber => Column::I64(fill_masked(records, masks, bit, |b| {
            b.l1_block_number
                .map(|n| i64::try_from(u64::from(n)))
                .transpose()
                .context("l1BlockNumber overflow")
        })?),
        EvmBlockField::SendCount => Column::Str(fill_masked(records, masks, bit, |b| {
            Ok(map_hex_string(&b.send_count))
        })?),
        EvmBlockField::SendRoot => Column::Str(fill_masked(records, masks, bit, |b| {
            Ok(map_hex_string(&b.send_root))
        })?),
        EvmBlockField::MixHash => Column::Str(fill_masked(records, masks, bit, |b| {
            Ok(map_hex_string(&b.mix_hash))
        })?),
    })
}

/// Blocks keyed by number. One block per number deduplicates the many logs that
/// share it; the `BTreeMap` keeps prune and rollback cheap range splits.
#[derive(Default)]
struct Blocks {
    map: BTreeMap<u64, Arc<simple_types::Block>>,
}

impl Blocks {
    fn new() -> Self {
        Self::default()
    }

    /// Drain every entry from `self` into `dst`.
    fn drain_into(&mut self, dst: &mut Self) {
        for (number, block) in std::mem::take(&mut self.map) {
            dst.map.insert(number, block);
        }
    }

    /// Drop blocks at or below `up_to` (already processed). `split_off` returns
    /// the `>= up_to + 1` tail, which becomes the new map.
    fn prune(&mut self, up_to: u64) {
        self.map = self.map.split_off(&(up_to + 1));
    }

    /// Drop blocks above `target` (rolled back). `split_off` removes the
    /// `>= target + 1` tail and we discard it, leaving `<= target` in place.
    fn rollback(&mut self, target: u64) {
        self.map.split_off(&(target + 1));
    }
}

/// Gather the stored blocks matching the requested numbers, in input order;
/// missing numbers yield `None`.
fn collect(store: &Blocks, block_numbers: &[i64]) -> Vec<Option<Arc<simple_types::Block>>> {
    block_numbers
        .iter()
        .map(|n| {
            let n = u64::try_from(*n).ok()?;
            store.map.get(&n).cloned()
        })
        .collect()
}

#[napi]
pub struct BlockStore {
    inner: Mutex<Blocks>,
    // Address checksumming is a per-chain EVM setting (only `miner` uses it), so
    // it lives on the store rather than on every block; learned once on the first
    // merge.
    should_checksum: AtomicBool,
}

impl Default for BlockStore {
    fn default() -> Self {
        Self::new()
    }
}

#[napi]
impl BlockStore {
    #[napi(factory)]
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(Blocks::new()),
            should_checksum: AtomicBool::new(false),
        }
    }

    /// Move every entry from `page` into this store (merging a fetch-response
    /// page into the persistent per-chain store).
    #[napi]
    pub fn merge(&self, page: &BlockStore) {
        // Merging a store into itself would lock the same Mutex twice (deadlock).
        if std::ptr::eq(self, page) {
            return;
        }
        {
            let mut dst = self.inner.lock().unwrap();
            let mut src = page.inner.lock().unwrap();
            src.drain_into(&mut dst);
        }
        self.should_checksum.store(
            page.should_checksum.load(Ordering::Relaxed),
            Ordering::Relaxed,
        );
    }

    /// Bulk-materialise blocks in columnar form, one row per `block_numbers[i]`
    /// key, decoding only the fields whose bit is set in that row's own
    /// `masks[i]`. Per-row masks let each event pull just the block fields it
    /// selected, so a large field (e.g. `logsBloom`) is materialised only on the
    /// rows that asked for it. Each mask is a JS number (`f64`) carrying a
    /// selection bitmask over field codes. Async + `block_in_place` so the bulk
    /// decode runs off the JS thread without monopolising an async worker; the
    /// brief lock only clones `Arc`s. Missing keys yield an empty object. Result
    /// is aligned with input.
    #[napi(ts_return_type = "Promise<object[]>")]
    pub async fn materialize(
        &self,
        block_numbers: Vec<i64>,
        masks: Vec<f64>,
    ) -> napi::Result<Columns> {
        // The two columns are zipped row-wise; a length mismatch would silently
        // truncate and misalign the result with the caller's items.
        if block_numbers.len() != masks.len() {
            return Err(napi::Error::from_reason(format!(
                "materialize column length mismatch: block_numbers={}, masks={}",
                block_numbers.len(),
                masks.len()
            )));
        }
        let masks: Vec<u64> = masks.iter().map(|&m| m as u64).collect();

        let records = {
            let inner = self.inner.lock().unwrap();
            collect(&inner, &block_numbers)
        };
        let should_checksum = self.should_checksum.load(Ordering::Relaxed);
        tokio::task::block_in_place(|| {
            decode_evm_block_columns(&records, &block_numbers, &masks, should_checksum)
        })
        .map_err(map_err)
    }

    /// Drop blocks at or below `up_to_block` (already processed).
    #[napi]
    pub fn prune(&self, up_to_block: i64) {
        if let Ok(up_to) = u64::try_from(up_to_block) {
            self.inner.lock().unwrap().prune(up_to);
        }
    }

    /// Drop blocks above `target_block` (rolled back).
    #[napi]
    pub fn rollback(&self, target_block: i64) {
        let mut inner = self.inner.lock().unwrap();
        match u64::try_from(target_block) {
            Ok(target) => inner.rollback(target),
            Err(_) => inner.map.clear(),
        }
    }
}

impl BlockStore {
    /// Create a page store for an EVM source, carrying that chain's
    /// address-checksumming setting (copied into the persistent store on merge).
    pub(crate) fn with_checksum(should_checksum: bool) -> Self {
        let store = Self::new();
        store
            .should_checksum
            .store(should_checksum, Ordering::Relaxed);
        store
    }

    /// Insert a raw EVM block (called by the HyperSync source while building a
    /// page). One block per number, so a plain insert deduplicates the many logs
    /// that share it. Not exposed to JS.
    pub(crate) fn insert_evm_raw(&self, number: u64, block: Arc<simple_types::Block>) {
        self.inner.lock().unwrap().map.insert(number, block);
    }
}

/// Ordered EVM block-field names — the single source of truth the ReScript
/// `Evm.res blockFields` array is tested against. The order is the bit position
/// in the selection mask, so the two must not drift.
#[napi]
pub fn evm_block_field_names() -> Vec<String> {
    EvmBlockField::VARIANTS
        .iter()
        .map(|f| f.name().to_string())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw_block(number: u64) -> simple_types::Block {
        simple_types::Block {
            number: Some(number),
            ..Default::default()
        }
    }

    fn column<'a>(cols: &'a Columns, name: &str) -> Option<&'a Column> {
        cols.columns
            .iter()
            .find(|(n, _)| *n == name)
            .map(|(_, c)| c)
    }

    #[test]
    fn decode_selected_only_materialises_masked_fields() {
        // Select only `logsBloom` via the bitmask.
        let mask = 1u64 << (EvmBlockField::LogsBloom as u32);
        let cols = decode_evm_block_columns(&[Some(Arc::new(raw_block(1)))], &[1], &[mask], false)
            .expect("decode columns");

        // Exactly one column (logsBloom) is present; number (resolvable from the
        // key but unselected) and gasUsed are absent.
        assert!(column(&cols, "logsBloom").is_some());
        assert!(column(&cols, "number").is_none());
        assert!(column(&cols, "gasUsed").is_none());
    }

    #[test]
    fn number_comes_from_key_even_on_miss() {
        // A missing record (None) still materialises the requested key as
        // `number`, so it never depends on a fetched block row.
        let mask = 1u64 << (EvmBlockField::Number as u32);
        let cols = decode_evm_block_columns(
            &[None, Some(Arc::new(raw_block(3)))],
            &[7, 3],
            &[mask, mask],
            false,
        )
        .expect("decode columns");
        match column(&cols, "number") {
            Some(Column::I64(v)) => assert_eq!(v, &vec![Some(7), Some(3)]),
            other => panic!(
                "expected number i64 column, got present={}",
                other.is_some()
            ),
        }
    }

    #[test]
    fn decode_applies_each_rows_own_mask() {
        // Row 0 selects `number`; row 1 selects nothing. The key-derived `number`
        // column is present only on the row whose own mask has the bit set.
        let number_mask = 1u64 << (EvmBlockField::Number as u32);
        let cols = decode_evm_block_columns(
            &[Some(Arc::new(raw_block(1))), Some(Arc::new(raw_block(2)))],
            &[1, 2],
            &[number_mask, 0],
            false,
        )
        .expect("decode columns");

        match column(&cols, "number") {
            Some(Column::I64(v)) => assert_eq!(v, &vec![Some(1), None]),
            other => panic!("expected number column, got present={}", other.is_some()),
        }
    }

    #[test]
    fn prune_and_rollback_drop_by_block() {
        let store = BlockStore::new();
        for block in [10u64, 20, 30] {
            store.insert_evm_raw(block, Arc::new(raw_block(block)));
        }

        store.prune(10);
        assert!(!store.inner.lock().unwrap().map.contains_key(&10));

        store.rollback(20);
        // Block 30 dropped by rollback; block 20 survives.
        assert_eq!(
            store
                .inner
                .lock()
                .unwrap()
                .map
                .keys()
                .copied()
                .collect::<Vec<_>>(),
            vec![20]
        );
    }

    #[test]
    fn field_codes_match_names_in_order() {
        // The bit position (`field as i32`) must equal the field's index in
        // `VARIANTS`, and the names must match the ReScript `blockFields` array in
        // that same order. Pin both so a reordered or misnumbered variant fails
        // here rather than silently corrupting the shared mask.
        let codes: Vec<i32> = EvmBlockField::VARIANTS.iter().map(|&f| f as i32).collect();
        assert_eq!(
            codes,
            Vec::from_iter(0..EvmBlockField::VARIANTS.len() as i32)
        );
        let names: Vec<&str> = EvmBlockField::VARIANTS.iter().map(|f| f.name()).collect();
        assert_eq!(
            names,
            vec![
                "number",
                "timestamp",
                "hash",
                "parentHash",
                "nonce",
                "sha3Uncles",
                "logsBloom",
                "transactionsRoot",
                "stateRoot",
                "receiptsRoot",
                "miner",
                "difficulty",
                "totalDifficulty",
                "extraData",
                "size",
                "gasLimit",
                "gasUsed",
                "uncles",
                "baseFeePerGas",
                "blobGasUsed",
                "excessBlobGas",
                "parentBeaconBlockRoot",
                "withdrawalsRoot",
                "l1BlockNumber",
                "sendCount",
                "sendRoot",
                "mixHash",
            ]
        );
    }
}
