//! Per-chain block store. Blocks are kept as raw upstream structs (their large
//! fields never cross the napi boundary until they are read), keyed by block
//! number (slot on SVM). One block per number — many logs/instructions share it —
//! so a plain insert deduplicates. At batch preparation the fields a chain's
//! events selected are decoded in bulk, off the JS thread, into columnar form;
//! the main thread zips the columns into plain JS objects. The store lives on the
//! ReScript `ChainState`; fetch responses merge in, and entries are pruned/rolled
//! back by block.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use hypersync_client::format::Hex;
use hypersync_client::simple_types;
use hypersync_client_solana::simple_types as solana_simple;
use napi_derive::napi;
use strum::VariantArray;

use crate::evm_hypersync_source::map_err;
use crate::evm_hypersync_source::types::{map_address_string, map_bigint, map_hex_string};
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

/// Decode the per-row mask-selected fields of the given EVM blocks into
/// columns. ReScript builds the masks from the config's field selection, which
/// always includes number/timestamp/hash, so the trio's bits are set on every
/// production mask.
fn decode_evm_block_columns(
    records: &[Option<EvmRecord>],
    block_numbers: &[i64],
    masks: &[u64],
    should_checksum: bool,
) -> Result<Columns> {
    let raw: Vec<Option<Arc<simple_types::Block>>> = records
        .iter()
        .map(|r| r.as_ref().and_then(|(_, raw)| raw.clone()))
        .collect();

    build_columns(
        EvmBlockField::VARIANTS,
        masks,
        records.len(),
        |f| f as u32,
        |f| f.name(),
        |f| decode_evm_block_field(f, records, &raw, block_numbers, masks, should_checksum),
    )
}

/// Decode a single EVM block field, materialising it only on the rows whose mask
/// has the field's bit set. Number/timestamp/hash resolve from the key and the
/// stored header (known for every stored block); the rest decode from the raw
/// block, retained only when a field beyond those three was selected. Exhaustive
/// match: adding an `EvmBlockField` variant fails to compile until it is decoded
/// here.
fn decode_evm_block_field(
    field: EvmBlockField,
    records: &[Option<EvmRecord>],
    raw: &[Option<Arc<simple_types::Block>>],
    block_numbers: &[i64],
    masks: &[u64],
    should_checksum: bool,
) -> Result<Column> {
    let bit = 1u64 << (field as u32);
    Ok(match field {
        EvmBlockField::Number => Column::I64(
            block_numbers
                .iter()
                .zip(masks)
                .map(|(&n, &m)| (m & bit != 0).then_some(n))
                .collect(),
        ),
        EvmBlockField::Timestamp => Column::I64(
            records
                .iter()
                .zip(masks)
                .map(|(r, &m)| {
                    if m & bit == 0 {
                        None
                    } else {
                        r.as_ref().map(|(h, _)| h.timestamp)
                    }
                })
                .collect(),
        ),
        EvmBlockField::Hash => Column::Str(
            records
                .iter()
                .zip(masks)
                .map(|(r, &m)| {
                    if m & bit == 0 {
                        None
                    } else {
                        r.as_ref().map(|(h, _)| h.hash.clone())
                    }
                })
                .collect(),
        ),
        EvmBlockField::ParentHash => Column::Str(fill_masked(raw, masks, bit, |b| {
            Ok(map_hex_string(&b.parent_hash))
        })?),
        EvmBlockField::Nonce => {
            Column::Big(fill_masked(raw, masks, bit, |b| Ok(map_bigint(&b.nonce)))?)
        }
        EvmBlockField::Sha3Uncles => Column::Str(fill_masked(raw, masks, bit, |b| {
            Ok(map_hex_string(&b.sha3_uncles))
        })?),
        EvmBlockField::LogsBloom => Column::Str(fill_masked(raw, masks, bit, |b| {
            Ok(map_hex_string(&b.logs_bloom))
        })?),
        EvmBlockField::TransactionsRoot => Column::Str(fill_masked(raw, masks, bit, |b| {
            Ok(map_hex_string(&b.transactions_root))
        })?),
        EvmBlockField::StateRoot => Column::Str(fill_masked(raw, masks, bit, |b| {
            Ok(map_hex_string(&b.state_root))
        })?),
        EvmBlockField::ReceiptsRoot => Column::Str(fill_masked(raw, masks, bit, |b| {
            Ok(map_hex_string(&b.receipts_root))
        })?),
        EvmBlockField::Miner => Column::Str(fill_masked(raw, masks, bit, |b| {
            Ok(map_address_string(&b.miner, should_checksum))
        })?),
        EvmBlockField::Difficulty => Column::Big(fill_masked(raw, masks, bit, |b| {
            Ok(map_bigint(&b.difficulty))
        })?),
        EvmBlockField::TotalDifficulty => Column::Big(fill_masked(raw, masks, bit, |b| {
            Ok(map_bigint(&b.total_difficulty))
        })?),
        EvmBlockField::ExtraData => Column::Str(fill_masked(raw, masks, bit, |b| {
            Ok(map_hex_string(&b.extra_data))
        })?),
        EvmBlockField::Size => {
            Column::Big(fill_masked(raw, masks, bit, |b| Ok(map_bigint(&b.size)))?)
        }
        EvmBlockField::GasLimit => Column::Big(fill_masked(raw, masks, bit, |b| {
            Ok(map_bigint(&b.gas_limit))
        })?),
        EvmBlockField::GasUsed => Column::Big(fill_masked(raw, masks, bit, |b| {
            Ok(map_bigint(&b.gas_used))
        })?),
        EvmBlockField::Uncles => Column::StrVec(fill_masked(raw, masks, bit, |b| {
            Ok(b.uncles
                .as_ref()
                .map(|arr| arr.iter().map(|u| u.encode_hex()).collect()))
        })?),
        EvmBlockField::BaseFeePerGas => Column::Big(fill_masked(raw, masks, bit, |b| {
            Ok(map_bigint(&b.base_fee_per_gas))
        })?),
        EvmBlockField::BlobGasUsed => Column::Big(fill_masked(raw, masks, bit, |b| {
            Ok(map_bigint(&b.blob_gas_used))
        })?),
        EvmBlockField::ExcessBlobGas => Column::Big(fill_masked(raw, masks, bit, |b| {
            Ok(map_bigint(&b.excess_blob_gas))
        })?),
        EvmBlockField::ParentBeaconBlockRoot => Column::Str(fill_masked(raw, masks, bit, |b| {
            Ok(map_hex_string(&b.parent_beacon_block_root))
        })?),
        EvmBlockField::WithdrawalsRoot => Column::Str(fill_masked(raw, masks, bit, |b| {
            Ok(map_hex_string(&b.withdrawals_root))
        })?),
        EvmBlockField::L1BlockNumber => Column::I64(fill_masked(raw, masks, bit, |b| {
            b.l1_block_number
                .map(|n| i64::try_from(u64::from(n)))
                .transpose()
                .context("l1BlockNumber overflow")
        })?),
        EvmBlockField::SendCount => Column::Str(fill_masked(raw, masks, bit, |b| {
            Ok(map_hex_string(&b.send_count))
        })?),
        EvmBlockField::SendRoot => Column::Str(fill_masked(raw, masks, bit, |b| {
            Ok(map_hex_string(&b.send_root))
        })?),
        EvmBlockField::MixHash => Column::Str(fill_masked(raw, masks, bit, |b| {
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
    build_columns(
        SvmBlockField::VARIANTS,
        masks,
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
    raw: &[Option<Arc<solana_simple::Block>>],
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
        SvmBlockField::Time => Column::I64(fill_masked(raw, masks, bit, |b| Ok(b.block_time))?),
        SvmBlockField::Hash => Column::Str(fill_masked(raw, masks, bit, |b| {
            Ok(Some(b.blockhash.clone()))
        })?),
        SvmBlockField::Height => Column::I64(fill_masked(raw, masks, bit, |b| {
            b.block_height
                .map(i64::try_from)
                .transpose()
                .context("height overflow")
        })?),
        SvmBlockField::ParentSlot => Column::I64(fill_masked(raw, masks, bit, |b| {
            b.parent_slot
                .map(i64::try_from)
                .transpose()
                .context("parentSlot overflow")
        })?),
        SvmBlockField::ParentHash => Column::Str(fill_masked(raw, masks, bit, |b| {
            Ok(b.parent_blockhash.clone())
        })?),
    })
}

/// The lean header every fetched EVM block carries, independent of whether its
/// full raw form was also retained — timestamp/hash are always known from the
/// response, not just when an event selected a field beyond the trio.
/// `number` isn't duplicated here since it's already the map key.
#[derive(Clone)]
struct EvmHeader {
    timestamp: i64,
    hash: String,
}

/// One EVM row's stored data: the header is always known; the raw block is
/// only kept when an event selected a field beyond the trio.
type EvmRecord = (EvmHeader, Option<Arc<simple_types::Block>>);

/// One stored block, kept in its ecosystem's compact raw form.
enum StoredBlock {
    /// EVM: the header is always known (from the response); `raw` holds the
    /// full upstream struct only when an event selected a field beyond the
    /// always-available trio.
    Evm {
        header: EvmHeader,
        raw: Option<Arc<simple_types::Block>>,
    },
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

/// Ecosystem selecting `materialize`'s decoder. A store is per-chain, hence
/// single-ecosystem, and is fixed at construction. `Evm` carries that chain's
/// address-checksumming setting (only `miner` uses it) — a per-chain EVM
/// constant the decoder needs, tied to EVM so it can't be set without (or
/// forgotten for) it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Ecosystem {
    Evm { should_checksum: bool },
    Svm,
    Fuel,
}

#[napi]
pub struct BlockStore {
    inner: Mutex<Blocks>,
    // Fixed at construction; drives the decoder in `materialize`.
    ecosystem: Ecosystem,
}

#[napi]
impl BlockStore {
    /// EVM store, carrying that chain's address-checksumming setting. Used for
    /// both fetch-response pages and the persistent per-chain store.
    #[napi(factory)]
    pub fn new_evm(should_checksum: bool) -> Self {
        Self::with_ecosystem(Ecosystem::Evm { should_checksum })
    }

    /// SVM store. Used for both fetch-response pages and the persistent store.
    #[napi(factory)]
    pub fn new_svm() -> Self {
        Self::with_ecosystem(Ecosystem::Svm)
    }

    /// Fuel store. Fuel keeps the block inline, so this store is never merged
    /// into or materialised through — it exists only because every chain holds one.
    #[napi(factory)]
    pub fn new_fuel() -> Self {
        Self::with_ecosystem(Ecosystem::Fuel)
    }

    /// Move every entry from `page` into this store (merging a fetch-response
    /// page into the persistent per-chain store).
    #[napi]
    pub fn merge(&self, page: &BlockStore) {
        // Merging a store into itself would lock the same Mutex twice (deadlock).
        if std::ptr::eq(self, page) {
            return;
        }
        // A page and its persistent store are the same per-chain ecosystem (both
        // derive it from the one chain config), so the decoder is unaffected by
        // the merge.
        debug_assert_eq!(self.ecosystem, page.ecosystem);
        let mut dst = self.inner.lock().unwrap();
        let mut src = page.inner.lock().unwrap();
        src.drain_into(&mut dst);
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

        match self.ecosystem {
            Ecosystem::Evm { should_checksum } => {
                // The header (timestamp/hash) is always present for a stored EVM
                // block; `raw` is only `Some` when an event selected a field
                // beyond the trio.
                let records = self.collect_locked(&block_numbers, |stored| match stored {
                    StoredBlock::Evm { header, raw } => Some((header.clone(), raw.clone())),
                    _ => None,
                });
                tokio::task::block_in_place(|| {
                    decode_evm_block_columns(&records, &block_numbers, &masks, should_checksum)
                })
                .map_err(map_err)
            }
            Ecosystem::Svm => {
                let records = self.collect_locked(&block_numbers, |stored| match stored {
                    StoredBlock::Svm(b) => Some(b.clone()),
                    _ => None,
                });
                tokio::task::block_in_place(|| {
                    decode_svm_block_columns(&records, &block_numbers, &masks)
                })
                .map_err(map_err)
            }
            // Fuel keeps the block inline, so its store is never materialised
            // through; should it be, every key is a miss → `len` empty objects.
            Ecosystem::Fuel => Ok(Columns {
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

    fn with_ecosystem(ecosystem: Ecosystem) -> Self {
        Self {
            inner: Mutex::new(Blocks::new()),
            ecosystem,
        }
    }

    /// Insert an EVM block's header — always known from the response — and,
    /// optionally, its full raw form (only kept when an event selected a field
    /// beyond the always-available trio). Called once per response block while
    /// building a page; one block per number, so a plain insert deduplicates
    /// the many logs that share it. Not exposed to JS.
    pub(crate) fn insert_evm(
        &self,
        number: u64,
        timestamp: i64,
        hash: String,
        raw: Option<Arc<simple_types::Block>>,
    ) {
        self.inner.lock().unwrap().map.insert(
            number,
            StoredBlock::Evm {
                header: EvmHeader { timestamp, hash },
                raw,
            },
        );
    }

    /// Insert a raw SVM block keyed by slot (called by the SVM HyperSync source
    /// while building a page). Not exposed to JS.
    pub(crate) fn insert_svm_raw(&self, slot: u64, block: Arc<solana_simple::Block>) {
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
    use hypersync_client::format::Quantity;

    fn raw_evm_block(number: u64) -> simple_types::Block {
        simple_types::Block {
            number: Some(number),
            ..Default::default()
        }
    }

    fn evm_record(
        timestamp: i64,
        hash: &str,
        raw: Option<Arc<simple_types::Block>>,
    ) -> Option<EvmRecord> {
        Some((
            EvmHeader {
                timestamp,
                hash: hash.to_string(),
            },
            raw,
        ))
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
        let cols = decode_evm_block_columns(
            &[evm_record(11, "0x1", Some(Arc::new(raw_evm_block(1))))],
            &[1],
            &[mask],
            false,
        )
        .expect("decode columns");

        // Only the selected column is present — the trio is mask-gated like
        // every other field (production masks always carry its bits).
        let summary = (
            column(&cols, "logsBloom").is_some(),
            column(&cols, "gasUsed").is_some(),
            column(&cols, "number").is_some(),
            column(&cols, "timestamp").is_some(),
            column(&cols, "hash").is_some(),
        );
        assert_eq!(summary, (true, false, false, false, false));
    }

    #[test]
    fn trio_decodes_from_key_and_header_without_raw_record() {
        // The trio never needs the raw block: number resolves from the key and
        // timestamp/hash from the stored header, so rows without a raw record
        // (no field beyond the trio selected) still materialise it.
        let trio_mask = (1u64 << (EvmBlockField::Number as u32))
            | (1u64 << (EvmBlockField::Timestamp as u32))
            | (1u64 << (EvmBlockField::Hash as u32));
        let cols = decode_evm_block_columns(
            &[evm_record(70, "0x7", None), evm_record(30, "0x3", None)],
            &[7, 3],
            &[trio_mask, trio_mask],
            false,
        )
        .expect("decode columns");

        let summary = (
            match column(&cols, "number") {
                Some(Column::I64(v)) => v.clone(),
                _ => panic!("expected number column"),
            },
            match column(&cols, "timestamp") {
                Some(Column::I64(v)) => v.clone(),
                _ => panic!("expected timestamp column"),
            },
            match column(&cols, "hash") {
                Some(Column::Str(v)) => v.clone(),
                _ => panic!("expected hash column"),
            },
        );
        assert_eq!(
            summary,
            (
                vec![Some(7), Some(3)],
                vec![Some(70), Some(30)],
                vec![Some("0x7".to_string()), Some("0x3".to_string())],
            )
        );
    }

    #[test]
    fn decode_applies_each_rows_own_mask() {
        // Both rows have a real `gasUsed` value on their raw record, but only
        // row 0 selects it via its own mask — proving the mask, not the
        // record, gates whether a row's value materialises.
        let mut block1 = raw_evm_block(1);
        block1.gas_used = Some(Quantity::from(100u64));
        let mut block2 = raw_evm_block(2);
        block2.gas_used = Some(Quantity::from(200u64));

        let gas_used_mask = 1u64 << (EvmBlockField::GasUsed as u32);
        let cols = decode_evm_block_columns(
            &[
                evm_record(11, "0x1", Some(Arc::new(block1))),
                evm_record(22, "0x2", Some(Arc::new(block2))),
            ],
            &[1, 2],
            &[gas_used_mask, 0],
            false,
        )
        .expect("decode columns");

        match column(&cols, "gasUsed") {
            Some(Column::Big(v)) => assert_eq!((v[0].is_some(), v[1].is_some()), (true, false)),
            other => panic!("expected gasUsed column, got present={}", other.is_some()),
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
        let store = BlockStore::new_evm(false);
        for block in [10u64, 20, 30] {
            store.insert_evm(
                block,
                0,
                "0x0".to_string(),
                Some(Arc::new(raw_evm_block(block))),
            );
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

    // The tests above call `decode_evm_block_columns`/`decode_svm_block_columns`
    // directly; the ones below go through the public `materialize` method (as
    // ReScript does), so they also cover the lock, the `f64` mask cast, and the
    // ecosystem dispatch. `block_in_place` inside `materialize` panics without a
    // multi-thread runtime.
    #[tokio::test(flavor = "multi_thread")]
    async fn materialize_returns_stored_extra_fields_via_store() {
        let store = BlockStore::new_evm(false);
        let mut block = raw_evm_block(10);
        block.gas_used = Some(Quantity::from(555u64));
        store.insert_evm(10, 999, "0xhash".to_string(), Some(Arc::new(block)));

        // A production-shaped mask: the config-extended trio plus a selected
        // extra field. The trio resolves from the key/header, gasUsed from raw.
        let mask = ((1u64 << (EvmBlockField::Number as u32))
            | (1u64 << (EvmBlockField::Timestamp as u32))
            | (1u64 << (EvmBlockField::Hash as u32))
            | (1u64 << (EvmBlockField::GasUsed as u32))) as f64;
        let cols = store
            .materialize(vec![10], vec![mask])
            .await
            .expect("materialize");
        let summary = (
            column(&cols, "gasUsed").is_some(),
            match column(&cols, "number") {
                Some(Column::I64(v)) => v.clone(),
                _ => panic!("expected number column"),
            },
            match column(&cols, "timestamp") {
                Some(Column::I64(v)) => v.clone(),
                _ => panic!("expected timestamp column"),
            },
            match column(&cols, "hash") {
                Some(Column::Str(v)) => v.clone(),
                _ => panic!("expected hash column"),
            },
        );
        assert_eq!(
            summary,
            (
                true,
                vec![Some(10)],
                vec![Some(999)],
                vec![Some("0xhash".to_string())]
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn svm_materialize_returns_stored_extra_fields_via_store() {
        let store = BlockStore::new_svm();
        let mut block = raw_svm_block(9);
        block.block_height = Some(777);
        store.insert_svm_raw(9, Arc::new(block));

        let mask = (1u64 << (SvmBlockField::Height as u32)) as f64;
        let cols = store
            .materialize(vec![9], vec![mask])
            .await
            .expect("materialize");
        match column(&cols, "height") {
            Some(Column::I64(v)) => assert_eq!(v, &vec![Some(777)]),
            other => panic!("expected height column, got present={}", other.is_some()),
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn merge_overwrites_existing_block_for_same_number() {
        // A rolled-back block re-fetched with different content must replace the
        // stale entry rather than be shadowed by it — the sequence a chain
        // reorg drives through `ChainState`: merge a page, then merge a later
        // page for the same (re-fetched) block number. No raw block needed
        // here: the header alone (set directly via `insert_evm`) is enough to
        // prove the overwrite.
        let persistent = BlockStore::new_evm(false);

        let page1 = BlockStore::new_evm(false);
        page1.insert_evm(20, 100, "0x100".to_string(), None);
        persistent.merge(&page1);

        let page2 = BlockStore::new_evm(false);
        page2.insert_evm(20, 200, "0x200".to_string(), None);
        persistent.merge(&page2);

        let mask = (1u64 << (EvmBlockField::Timestamp as u32)) as f64;
        let cols = persistent
            .materialize(vec![20], vec![mask])
            .await
            .expect("materialize");
        match column(&cols, "timestamp") {
            Some(Column::I64(v)) => assert_eq!(v, &vec![Some(200)]),
            other => panic!("expected timestamp column, got present={}", other.is_some()),
        }
    }
}
