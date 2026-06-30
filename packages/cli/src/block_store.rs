//! Per-chain block store. Blocks are kept as raw upstream structs (their large
//! fields never cross the napi boundary until they are read), keyed by block
//! number (slot on SVM). One block per number — many logs/instructions share it —
//! so a plain insert deduplicates. At batch preparation the fields a chain's
//! events selected are decoded in bulk, off the JS thread, into columnar form;
//! the main thread zips the columns into plain JS objects. The store lives on the
//! ReScript `ChainState`; fetch responses merge in, and entries are pruned/rolled
//! back by block.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use hypersync_client::format::Hex;
use hypersync_client::simple_types;
use hypersync_client_solana::simple_types as solana_simple;
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

/// SVM block field codes, mirroring `Svm.res` `blockFields` by ordinal (the bit
/// position in the selection mask). Keep the two in sync.
#[derive(Clone, Copy, PartialEq, Eq, Debug, VariantArray)]
#[repr(i32)]
pub enum SvmBlockField {
    Slot = 0,
    Time = 1,
    Hash = 2,
    Height = 3,
    ParentSlot = 4,
    ParentHash = 5,
}

impl SvmBlockField {
    /// JS property name; must match `Svm.res` `blockFields`.
    pub fn name(self) -> &'static str {
        use SvmBlockField::*;
        match self {
            Slot => "slot",
            Time => "time",
            Hash => "hash",
            Height => "height",
            ParentSlot => "parentSlot",
            ParentHash => "parentHash",
        }
    }
}

/// Decode the per-row mask-selected fields of the given EVM blocks into columns.
/// `block_numbers` is the requested key per row, so `number` resolves from the
/// key (always known) rather than a stored record.
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

/// Decode the per-row mask-selected fields of the given SVM blocks into columns.
/// `block_numbers` is the requested slot per row, so `slot` resolves from the key
/// (always known) rather than a stored record.
fn decode_svm_block_columns(
    records: &[Option<Arc<solana_simple::Block>>],
    block_numbers: &[i64],
    masks: &[u64],
) -> Result<Columns> {
    let union = masks.iter().fold(0u64, |acc, &m| acc | m);
    build_columns(
        SvmBlockField::VARIANTS,
        union,
        records.len(),
        |f| f as u32,
        |f| f.name(),
        |f| decode_svm_block_field(f, records, block_numbers, masks),
    )
}

/// Decode a single SVM block field, materialising it only on the rows whose mask
/// has the field's bit set. Exhaustive match: adding an `SvmBlockField` variant
/// fails to compile until it is decoded here.
fn decode_svm_block_field(
    field: SvmBlockField,
    records: &[Option<Arc<solana_simple::Block>>],
    block_numbers: &[i64],
    masks: &[u64],
) -> Result<Column> {
    let bit = 1u64 << (field as u32);
    Ok(match field {
        // The slot is the store key, so it's always available regardless of
        // whether the block row was fetched.
        SvmBlockField::Slot => Column::I64(
            block_numbers
                .iter()
                .zip(masks)
                .map(|(&n, &m)| (m & bit != 0).then_some(n))
                .collect(),
        ),
        SvmBlockField::Time => Column::I64(fill_masked(records, masks, bit, |b| Ok(b.block_time))?),
        SvmBlockField::Hash => Column::Str(fill_masked(records, masks, bit, |b| {
            Ok(Some(b.blockhash.clone()))
        })?),
        SvmBlockField::Height => Column::I64(fill_masked(records, masks, bit, |b| {
            b.block_height
                .map(i64::try_from)
                .transpose()
                .context("height overflow")
        })?),
        SvmBlockField::ParentSlot => Column::I64(fill_masked(records, masks, bit, |b| {
            b.parent_slot
                .map(i64::try_from)
                .transpose()
                .context("parentSlot overflow")
        })?),
        SvmBlockField::ParentHash => Column::Str(fill_masked(records, masks, bit, |b| {
            Ok(b.parent_blockhash.clone())
        })?),
    })
}

/// One stored block, kept in its ecosystem's compact raw form.
enum StoredBlock {
    Evm(Arc<simple_types::Block>),
    Svm(Arc<solana_simple::Block>),
}

/// Blocks keyed by number (slot on SVM). One block per number deduplicates the
/// many logs/instructions that share it; the `BTreeMap` keeps prune and rollback
/// cheap range splits.
#[derive(Default)]
struct Blocks {
    map: BTreeMap<u64, StoredBlock>,
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
/// missing numbers (or a record `pick` rejects) yield `None`. Shared by both
/// ecosystems — only the `pick` closure differs.
fn collect<T>(
    store: &Blocks,
    block_numbers: &[i64],
    pick: impl Fn(&StoredBlock) -> Option<T>,
) -> Vec<Option<T>> {
    block_numbers
        .iter()
        .map(|n| {
            let n = u64::try_from(*n).ok()?;
            store.map.get(&n).and_then(&pick)
        })
        .collect()
}

// Ecosystem tag selecting `materialize`'s decoder. A store is per-chain, hence
// single-ecosystem; the tag is set on the first insert/merge so an empty store
// never falls back to the wrong decoder.
const ECO_UNKNOWN: u8 = 0;
const ECO_EVM: u8 = 1;
const ECO_SVM: u8 = 2;

#[napi]
pub struct BlockStore {
    inner: Mutex<Blocks>,
    // Set on the first insert/merge; drives the decoder in `materialize`.
    ecosystem: AtomicU8,
    // Address checksumming is a per-chain EVM setting (only `miner` uses it),
    // learned once on the first merge. SVM ignores it.
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
            ecosystem: AtomicU8::new(ECO_UNKNOWN),
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
        // Ecosystem + checksum are per-chain constants; learn them once from the
        // first page that carries them.
        if self.ecosystem.load(Ordering::Relaxed) == ECO_UNKNOWN {
            let page_ecosystem = page.ecosystem.load(Ordering::Relaxed);
            if page_ecosystem != ECO_UNKNOWN {
                self.ecosystem.store(page_ecosystem, Ordering::Relaxed);
                self.should_checksum.store(
                    page.should_checksum.load(Ordering::Relaxed),
                    Ordering::Relaxed,
                );
            }
        }
    }

    /// Bulk-materialise blocks in columnar form, one row per `block_numbers[i]`
    /// key, decoding only the fields whose bit is set in that row's own
    /// `masks[i]`. Each mask is a JS number (`f64`) carrying a selection bitmask
    /// over field codes. Async + `block_in_place` so the bulk decode runs off the
    /// JS thread without monopolising an async worker; the brief lock only clones
    /// `Arc`s. Missing keys yield an empty object. Result is aligned with input.
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

        match self.ecosystem.load(Ordering::Relaxed) {
            ECO_EVM => {
                let records = self.collect_locked(&block_numbers, |stored| match stored {
                    StoredBlock::Evm(b) => Some(b.clone()),
                    _ => None,
                });
                let should_checksum = self.should_checksum.load(Ordering::Relaxed);
                tokio::task::block_in_place(|| {
                    decode_evm_block_columns(&records, &block_numbers, &masks, should_checksum)
                })
                .map_err(map_err)
            }
            ECO_SVM => {
                let records = self.collect_locked(&block_numbers, |stored| match stored {
                    StoredBlock::Svm(b) => Some(b.clone()),
                    _ => None,
                });
                tokio::task::block_in_place(|| {
                    decode_svm_block_columns(&records, &block_numbers, &masks)
                })
                .map_err(map_err)
            }
            // Empty store (no ecosystem learned yet): every key is a miss, so the
            // result is `len` empty objects regardless of the decoder.
            _ => Ok(Columns {
                len: block_numbers.len(),
                columns: Vec::new(),
            }),
        }
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
    /// Lock the store and gather the records for the requested keys. The lock is
    /// held only for the `Arc` clones; decoding runs after it is released.
    fn collect_locked<T>(
        &self,
        block_numbers: &[i64],
        pick: impl Fn(&StoredBlock) -> Option<T>,
    ) -> Vec<Option<T>> {
        let inner = self.inner.lock().unwrap();
        collect(&inner, block_numbers, pick)
    }

    /// Create a page store for an EVM source, carrying that chain's
    /// address-checksumming setting (copied into the persistent store on merge).
    pub(crate) fn with_checksum(should_checksum: bool) -> Self {
        let store = Self::new();
        store.ecosystem.store(ECO_EVM, Ordering::Relaxed);
        store
            .should_checksum
            .store(should_checksum, Ordering::Relaxed);
        store
    }

    /// Create an SVM page store. The ecosystem is tagged here (not inferred from
    /// records) so even an empty page selects the SVM decoder after merge.
    pub(crate) fn new_svm() -> Self {
        let store = Self::new();
        store.ecosystem.store(ECO_SVM, Ordering::Relaxed);
        store
    }

    /// Insert a raw EVM block (called by the HyperSync source while building a
    /// page). One block per number, so a plain insert deduplicates the many logs
    /// that share it. Not exposed to JS.
    pub(crate) fn insert_evm_raw(&self, number: u64, block: Arc<simple_types::Block>) {
        self.ecosystem.store(ECO_EVM, Ordering::Relaxed);
        self.inner
            .lock()
            .unwrap()
            .map
            .insert(number, StoredBlock::Evm(block));
    }

    /// Insert a raw SVM block keyed by slot (called by the SVM HyperSync source
    /// while building a page). Not exposed to JS.
    pub(crate) fn insert_svm_raw(&self, slot: u64, block: Arc<solana_simple::Block>) {
        self.ecosystem.store(ECO_SVM, Ordering::Relaxed);
        self.inner
            .lock()
            .unwrap()
            .map
            .insert(slot, StoredBlock::Svm(block));
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

/// Ordered SVM block-field names; `Svm.res blockFields` is tested against this.
#[napi]
pub fn svm_block_field_names() -> Vec<String> {
    SvmBlockField::VARIANTS
        .iter()
        .map(|f| f.name().to_string())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw_evm_block(number: u64) -> simple_types::Block {
        simple_types::Block {
            number: Some(number),
            ..Default::default()
        }
    }

    fn raw_svm_block(slot: u64) -> solana_simple::Block {
        solana_simple::Block {
            slot,
            blockhash: "hash".to_string(),
            block_time: Some(123),
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
        let cols =
            decode_evm_block_columns(&[Some(Arc::new(raw_evm_block(1)))], &[1], &[mask], false)
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
            &[None, Some(Arc::new(raw_evm_block(3)))],
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
            &[
                Some(Arc::new(raw_evm_block(1))),
                Some(Arc::new(raw_evm_block(2))),
            ],
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
    fn svm_decode_selected_only_materialises_masked_fields() {
        // Select slot (from key) + hash + time; height stays absent.
        let mask = (1u64 << (SvmBlockField::Slot as u32))
            | (1u64 << (SvmBlockField::Hash as u32))
            | (1u64 << (SvmBlockField::Time as u32));
        let cols = decode_svm_block_columns(&[Some(Arc::new(raw_svm_block(9)))], &[9], &[mask])
            .expect("decode columns");

        let summary = (
            match column(&cols, "slot") {
                Some(Column::I64(v)) => v.clone(),
                _ => panic!("expected slot column"),
            },
            match column(&cols, "hash") {
                Some(Column::Str(v)) => v.clone(),
                _ => panic!("expected hash column"),
            },
            match column(&cols, "time") {
                Some(Column::I64(v)) => v.clone(),
                _ => panic!("expected time column"),
            },
            column(&cols, "height").is_some(),
        );
        assert_eq!(
            summary,
            (
                vec![Some(9)],
                vec![Some("hash".to_string())],
                vec![Some(123)],
                false
            )
        );
    }

    #[test]
    fn prune_and_rollback_drop_by_block() {
        let store = BlockStore::new();
        for block in [10u64, 20, 30] {
            store.insert_evm_raw(block, Arc::new(raw_evm_block(block)));
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
        // `VARIANTS`, and the names must match the ReScript `blockFields` arrays in
        // that same order. Pin both so a reordered or misnumbered variant fails
        // here rather than silently corrupting the shared mask.
        let evm_codes: Vec<i32> = EvmBlockField::VARIANTS.iter().map(|&f| f as i32).collect();
        assert_eq!(
            evm_codes,
            Vec::from_iter(0..EvmBlockField::VARIANTS.len() as i32)
        );
        let evm_names: Vec<&str> = EvmBlockField::VARIANTS.iter().map(|f| f.name()).collect();
        assert_eq!(
            evm_names,
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

        let svm_codes: Vec<i32> = SvmBlockField::VARIANTS.iter().map(|&f| f as i32).collect();
        assert_eq!(
            svm_codes,
            Vec::from_iter(0..SvmBlockField::VARIANTS.len() as i32)
        );
        let svm_names: Vec<&str> = SvmBlockField::VARIANTS.iter().map(|f| f.name()).collect();
        assert_eq!(
            svm_names,
            vec!["slot", "time", "hash", "height", "parentSlot", "parentHash"]
        );
    }
}
