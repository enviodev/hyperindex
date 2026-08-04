//! Per-chain block store: a merge-on-insert `Table` keyed by number (slot on
//! SVM), holding only the selected fields' columns. Large values never cross
//! the napi boundary until read. At batch preparation the fields a chain's
//! events selected are gathered under the store lock and decoded in bulk, off
//! the JS thread, into columnar form; the main thread zips the columns into
//! plain JS objects. The store lives on the ReScript `ChainState`; fetch
//! responses merge in, and rows are pruned or rolled back by block.

use std::sync::Mutex;

use anyhow::{Context, Result};
use hypersync_client::format::{Hash, Hex, Quantity};
use hypersync_client::simple_types;
use hypersync_client_solana::simple_types as solana_simple;
use napi_derive::napi;
use strum::VariantArray;

use crate::evm_hypersync_source::map_err;
use crate::evm_hypersync_source::types::{encode_address, map_bigint, map_i64};
use crate::field_columns::{build_columns, bytes, field_names, Column, Columns, Ecosystem};
use crate::field_table::{
    bytes_cells, fixed_from, hash_list_cells, hash_list_from, hex_full, hex_quantity, i64_cells,
    i64_from, str_cells, str_from, u64_cells, u64_from, var_from, AnyCol, Table,
};

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

/// Fuel block field codes, mirroring `Fuel.res` `blockFields` by ordinal (the
/// bit position in the selection mask). Keep the two in sync.
#[derive(Clone, Copy, PartialEq, Eq, Debug, VariantArray)]
#[repr(i32)]
pub enum FuelBlockField {
    Height = 0,
    Id = 1,
    Time = 2,
}

impl FuelBlockField {
    /// JS property name; must match `Fuel.res` `blockFields`.
    pub fn name(self) -> &'static str {
        use FuelBlockField::*;
        match self {
            Height => "height",
            Id => "id",
            Time => "time",
        }
    }
}

/// Build one EVM field's column from a response's blocks. `None` for the
/// key-derived `number` and for fields no block carries. Exhaustive match:
/// adding an `EvmBlockField` variant fails to compile until it is filled here
/// and decoded below.
fn evm_block_col(field: EvmBlockField, blocks: &[simple_types::Block]) -> Option<AnyCol> {
    use EvmBlockField::*;
    match field {
        // The block number is the table key, not a column.
        Number => None,
        Timestamp => var_from(blocks, |b| b.timestamp.as_ref().map(bytes)),
        // The hash is the reorg-detection comparison key: a fixed 32-byte block
        // hash, whether fetched or supplied via `fromJsEvm`.
        Hash => fixed_from(blocks, 32, |b| b.hash.as_ref().map(bytes)),
        ParentHash => fixed_from(blocks, 32, |b| b.parent_hash.as_ref().map(bytes)),
        Nonce => fixed_from(blocks, 8, |b| b.nonce.as_ref().map(bytes)),
        Sha3Uncles => fixed_from(blocks, 32, |b| b.sha3_uncles.as_ref().map(bytes)),
        LogsBloom => var_from(blocks, |b| b.logs_bloom.as_ref().map(bytes)),
        TransactionsRoot => fixed_from(blocks, 32, |b| b.transactions_root.as_ref().map(bytes)),
        StateRoot => fixed_from(blocks, 32, |b| b.state_root.as_ref().map(bytes)),
        ReceiptsRoot => fixed_from(blocks, 32, |b| b.receipts_root.as_ref().map(bytes)),
        Miner => fixed_from(blocks, 20, |b| b.miner.as_ref().map(bytes)),
        Difficulty => var_from(blocks, |b| b.difficulty.as_ref().map(bytes)),
        TotalDifficulty => var_from(blocks, |b| b.total_difficulty.as_ref().map(bytes)),
        ExtraData => var_from(blocks, |b| b.extra_data.as_ref().map(bytes)),
        Size => var_from(blocks, |b| b.size.as_ref().map(bytes)),
        GasLimit => var_from(blocks, |b| b.gas_limit.as_ref().map(bytes)),
        GasUsed => var_from(blocks, |b| b.gas_used.as_ref().map(bytes)),
        Uncles => hash_list_from(blocks, |b| {
            b.uncles.as_ref().map(|v| {
                v.iter()
                    .map(|h| <[u8; 32]>::try_from(h.as_ref()).expect("uncle hash width"))
                    .collect()
            })
        }),
        BaseFeePerGas => var_from(blocks, |b| b.base_fee_per_gas.as_ref().map(bytes)),
        BlobGasUsed => var_from(blocks, |b| b.blob_gas_used.as_ref().map(bytes)),
        ExcessBlobGas => var_from(blocks, |b| b.excess_blob_gas.as_ref().map(bytes)),
        ParentBeaconBlockRoot => fixed_from(blocks, 32, |b| {
            b.parent_beacon_block_root.as_ref().map(bytes)
        }),
        WithdrawalsRoot => fixed_from(blocks, 32, |b| b.withdrawals_root.as_ref().map(bytes)),
        L1BlockNumber => u64_from(blocks, |b| b.l1_block_number.map(u64::from)),
        SendCount => var_from(blocks, |b| b.send_count.as_ref().map(bytes)),
        SendRoot => fixed_from(blocks, 32, |b| b.send_root.as_ref().map(bytes)),
        MixHash => fixed_from(blocks, 32, |b| b.mix_hash.as_ref().map(bytes)),
    }
}

/// Decode one EVM field from its gathered scratch column, already masked
/// per-row by the gather.
fn decode_evm_block_field(
    field: EvmBlockField,
    scratch: &[Option<AnyCol>],
    block_numbers: &[i64],
    masks: &[u64],
    should_checksum: bool,
) -> Result<Column> {
    use EvmBlockField::*;
    let bit = 1u64 << (field as u32);
    let col = scratch[field as usize].as_ref();
    let len = block_numbers.len();
    Ok(match field {
        // The block number is the store key, so it's always available regardless
        // of whether the block row was fetched.
        Number => Column::I64(
            block_numbers
                .iter()
                .zip(masks)
                .map(|(&n, &m)| (m & bit != 0).then_some(n))
                .collect(),
        ),
        Timestamp => Column::I64(bytes_cells(col, len, |b| map_i64(&Some(b)))?),
        Hash
        | ParentHash
        | Sha3Uncles
        | LogsBloom
        | TransactionsRoot
        | StateRoot
        | ReceiptsRoot
        | ExtraData
        | ParentBeaconBlockRoot
        | WithdrawalsRoot
        | SendRoot
        | MixHash => Column::Str(bytes_cells(col, len, |b| Ok(Some(hex_full(b))))?),
        Nonce | Difficulty | TotalDifficulty | Size | GasLimit | GasUsed | BaseFeePerGas
        | BlobGasUsed | ExcessBlobGas => {
            Column::Big(bytes_cells(col, len, |b| Ok(map_bigint(&Some(b))))?)
        }
        Miner => Column::Str(bytes_cells(col, len, |b| {
            let address = <[u8; 20]>::try_from(b).expect("miner cell width");
            Ok(Some(encode_address(&address.into(), should_checksum)))
        })?),
        Uncles => Column::StrVec(hash_list_cells(col, len, |h| hex_full(h))),
        L1BlockNumber => Column::I64(u64_cells(col, len, |v| {
            i64::try_from(v).map(Some).context("l1BlockNumber overflow")
        })?),
        SendCount => Column::Str(bytes_cells(col, len, |b| Ok(Some(hex_quantity(b))))?),
    })
}

fn decode_evm_block_columns(
    scratch: &[Option<AnyCol>],
    block_numbers: &[i64],
    masks: &[u64],
    should_checksum: bool,
) -> Result<Columns> {
    build_columns(
        EvmBlockField::VARIANTS,
        masks,
        block_numbers.len(),
        |f| f as u32,
        |f| f.name(),
        |f| decode_evm_block_field(f, scratch, block_numbers, masks, should_checksum),
    )
}

/// Build one SVM field's column from a response's blocks; `None` for the
/// key-derived `slot`.
fn svm_block_col(field: SvmBlockField, blocks: &[solana_simple::Block]) -> Option<AnyCol> {
    use SvmBlockField::*;
    match field {
        // The slot is the table key, not a column.
        Slot => None,
        Time => i64_from(blocks, |b| b.block_time),
        Hash => str_from(blocks, |b| Some(b.blockhash.as_str())),
        Height => u64_from(blocks, |b| b.block_height),
        ParentSlot => u64_from(blocks, |b| b.parent_slot),
        ParentHash => str_from(blocks, |b| b.parent_blockhash.as_deref()),
    }
}

fn decode_svm_block_field(
    field: SvmBlockField,
    scratch: &[Option<AnyCol>],
    block_numbers: &[i64],
    masks: &[u64],
) -> Result<Column> {
    use SvmBlockField::*;
    let bit = 1u64 << (field as u32);
    let col = scratch[field as usize].as_ref();
    let len = block_numbers.len();
    Ok(match field {
        // The slot is the store key, so it's always available regardless of
        // whether the block row was fetched.
        Slot => Column::I64(
            block_numbers
                .iter()
                .zip(masks)
                .map(|(&n, &m)| (m & bit != 0).then_some(n))
                .collect(),
        ),
        Time => Column::I64(i64_cells(col, len)),
        Hash | ParentHash => Column::Str(str_cells(col, len)),
        Height => Column::I64(u64_cells(col, len, |v| {
            i64::try_from(v).map(Some).context("height overflow")
        })?),
        ParentSlot => Column::I64(u64_cells(col, len, |v| {
            i64::try_from(v).map(Some).context("parentSlot overflow")
        })?),
    })
}

fn decode_svm_block_columns(
    scratch: &[Option<AnyCol>],
    block_numbers: &[i64],
    masks: &[u64],
) -> Result<Columns> {
    build_columns(
        SvmBlockField::VARIANTS,
        masks,
        block_numbers.len(),
        |f| f as u32,
        |f| f.name(),
        |f| decode_svm_block_field(f, scratch, block_numbers, masks),
    )
}

/// One Fuel block's decoded cells: the insert-side row shape shared by the
/// Rust client path and `fromJsFuel`.
pub struct FuelBlockRow {
    pub height: u64,
    pub id: Option<Vec<u8>>,
    pub time: Option<i64>,
}

/// Build one Fuel field's column; `None` for the key-derived `height`.
fn fuel_block_col(field: FuelBlockField, blocks: &[FuelBlockRow]) -> Option<AnyCol> {
    use FuelBlockField::*;
    match field {
        // The height is the table key, not a column.
        Height => None,
        Id => var_from(blocks, |b| b.id.as_deref()),
        Time => i64_from(blocks, |b| b.time),
    }
}

fn decode_fuel_block_field(
    field: FuelBlockField,
    scratch: &[Option<AnyCol>],
    block_numbers: &[i64],
    masks: &[u64],
) -> Result<Column> {
    use FuelBlockField::*;
    let bit = 1u64 << (field as u32);
    let col = scratch[field as usize].as_ref();
    let len = block_numbers.len();
    Ok(match field {
        // The height is the store key, so it's always available regardless of
        // whether the block row was fetched.
        Height => Column::I64(
            block_numbers
                .iter()
                .zip(masks)
                .map(|(&n, &m)| (m & bit != 0).then_some(n))
                .collect(),
        ),
        Id => Column::Str(bytes_cells(col, len, |b| Ok(Some(hex_full(b))))?),
        Time => Column::I64(i64_cells(col, len)),
    })
}

fn decode_fuel_block_columns(
    scratch: &[Option<AnyCol>],
    block_numbers: &[i64],
    masks: &[u64],
) -> Result<Columns> {
    build_columns(
        FuelBlockField::VARIANTS,
        masks,
        block_numbers.len(),
        |f| f as u32,
        |f| f.name(),
        |f| decode_fuel_block_field(f, scratch, block_numbers, masks),
    )
}

/// A sparse EVM block from JS for `fromJsEvm`. Only the reorg-relevant fields
/// the JS callers actually send (RPC/simulate observations, seeded checkpoints):
/// the key, its hash, and the timestamp. `hash` is a full 32-byte block hash.
#[napi(object)]
pub struct EvmBlockInput {
    pub number: i64,
    pub timestamp: Option<i64>,
    pub hash: Option<String>,
}

/// A sparse SVM block from JS for `fromJsSvm`.
#[napi(object)]
pub struct SvmBlockInput {
    pub slot: i64,
    pub time: Option<i64>,
    pub hash: Option<String>,
}

/// A sparse Fuel block from JS for `fromJsFuel`.
#[napi(object)]
pub struct FuelBlockInput {
    pub height: i64,
    pub id: Option<String>,
    pub time: Option<i64>,
}

/// Strictly decode a 0x-prefixed even-length hex string into bytes; anything
/// else (e.g. an arbitrary marker string) is a validation error.
pub(crate) fn decode_hex_bytes(s: &str, name: &str) -> Result<Vec<u8>> {
    let hex = s
        .strip_prefix("0x")
        .with_context(|| format!("{name} '{s}' must be a 0x-prefixed hex string"))?;
    if !hex.len().is_multiple_of(2) {
        anyhow::bail!("{name} '{s}' must have an even number of hex digits");
    }
    let mut out = vec![0u8; hex.len() / 2];
    faster_hex::hex_decode(hex.as_bytes(), &mut out)
        .with_context(|| format!("{name} '{s}' is not valid hex"))?;
    Ok(out)
}

/// Left-pad a `fromJsEvm` hash into the fixed 32-byte comparison key the store
/// stores. Real observations (RPC blocks, seeded checkpoints) are already 32
/// bytes, so this is a no-op for them; shorter values (test markers) are
/// zero-extended to the canonical width. Anything wider than 32 bytes is a
/// validation error.
fn evm_input_hash(s: &str) -> Result<Hash> {
    let bytes = decode_hex_bytes(s, "block.hash")?;
    if bytes.len() > 32 {
        anyhow::bail!("block.hash '{s}' exceeds 32 bytes");
    }
    let mut buf = [0u8; 32];
    buf[32 - bytes.len()..].copy_from_slice(&bytes);
    Ok(Hash::from(buf))
}

/// Rebuild a `simple_types::Block` from the JS observation, so `fromJsEvm` rows
/// go through the same column fill as fetched blocks.
fn evm_input_to_simple(b: EvmBlockInput) -> Result<simple_types::Block> {
    Ok(simple_types::Block {
        number: Some(u64::try_from(b.number).context("block.number negative")?),
        hash: b.hash.as_deref().map(evm_input_hash).transpose()?,
        timestamp: b
            .timestamp
            .map(|t| Quantity::try_from(t).context("block.timestamp negative"))
            .transpose()?,
        ..Default::default()
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct SvmCoveredRange {
    from: u64,
    to_exclusive: u64,
}

fn add_svm_covered_range(ranges: &mut Vec<SvmCoveredRange>, mut incoming: SvmCoveredRange) {
    if incoming.from >= incoming.to_exclusive {
        return;
    }

    let mut insert_at = 0;
    while insert_at < ranges.len() && ranges[insert_at].to_exclusive < incoming.from {
        insert_at += 1;
    }
    while insert_at < ranges.len() && ranges[insert_at].from <= incoming.to_exclusive {
        let current = ranges.remove(insert_at);
        incoming.from = incoming.from.min(current.from);
        incoming.to_exclusive = incoming.to_exclusive.max(current.to_exclusive);
    }
    ranges.insert(insert_at, incoming);
}

fn svm_slot_is_covered(ranges: &[SvmCoveredRange], slot: u64) -> bool {
    ranges
        .iter()
        .any(|range| range.from <= slot && slot < range.to_exclusive)
}

/// The response-only state a page accumulates while it is built and validated:
/// a within-response hash conflict, and (SVM) the cursor coverage proving which
/// missing slots were legitimately skipped. It belongs to a fetch-response page
/// and is never persisted — `merge` resets it so it can't outlive the queried
/// fork once the page's rows join the chain store. A persistent store simply
/// leaves it empty.
#[derive(Default)]
struct ResponsePage {
    conflict: Option<HashMismatch>,
    svm_covered_ranges: Vec<SvmCoveredRange>,
}

/// The store's lock-guarded state: the persistent table plus, for a
/// fetch-response page, its response-only validation metadata.
struct Inner {
    table: Table<u64>,
    page: ResponsePage,
}

#[napi]
pub struct BlockStore {
    inner: Mutex<Inner>,
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

    /// Fuel store. Used for both fetch-response pages and the persistent store.
    #[napi(factory)]
    pub fn new_fuel() -> Self {
        Self::with_ecosystem(Ecosystem::Fuel)
    }

    /// Page built from JS block objects (sparse fields), for sources that fetch
    /// blocks in JS (RPC, simulate) and for seeding stored reorg checkpoints on
    /// resume.
    #[napi(factory)]
    pub fn from_js_evm(blocks: Vec<EvmBlockInput>, should_checksum: bool) -> napi::Result<Self> {
        let store = Self::with_ecosystem(Ecosystem::Evm { should_checksum });
        let simple = blocks
            .into_iter()
            .map(evm_input_to_simple)
            .collect::<Result<Vec<_>>>()
            .map_err(map_err)?;
        store.insert_evm_blocks(simple);
        Ok(store)
    }

    #[napi(factory)]
    pub fn from_js_svm(blocks: Vec<SvmBlockInput>) -> napi::Result<Self> {
        let store = Self::with_ecosystem(Ecosystem::Svm);
        store.insert_svm_inputs(blocks)?;
        Ok(store)
    }

    #[napi(factory)]
    pub fn from_js_fuel(blocks: Vec<FuelBlockInput>) -> napi::Result<Self> {
        let store = Self::with_ecosystem(Ecosystem::Fuel);
        let rows = blocks
            .into_iter()
            .map(|b| {
                Ok(FuelBlockRow {
                    height: u64::try_from(b.height).context("block.height negative")?,
                    id: b
                        .id
                        .as_deref()
                        .map(|s| decode_hex_bytes(s, "block.id"))
                        .transpose()?,
                    time: b.time,
                })
            })
            .collect::<Result<Vec<_>>>()
            .map_err(map_err)?;
        store.insert_fuel_block_rows(rows);
        Ok(store)
    }

    /// Move every row from `page` into the persistent store, comparing hashes
    /// on the way: the lowest page block at or above `from_block` whose hash
    /// differs from the stored one is reported as a reorg. A block without a
    /// hash on either side is skipped. The source manager validates that `page`
    /// has no response-internal conflict before calling this method. On a
    /// mismatch nothing is merged — the stored (scanned) hashes stay intact for
    /// rollback — unless `report_only` is set (detect-only mode), which merges
    /// anyway so the overwritten hash doesn't re-report on every response.
    #[napi]
    pub fn merge(
        &self,
        page: &BlockStore,
        from_block: i64,
        report_only: bool,
    ) -> Option<HashMismatch> {
        // Merging a store into itself would lock the same Mutex twice (deadlock).
        if std::ptr::eq(self, page) {
            return None;
        }
        // A page and its persistent store are the same per-chain ecosystem, so
        // the decoder is unaffected by the merge. Only the kind matters: the
        // EVM checksum flag lives on the persistent store's decoder and may
        // differ on a page built via `fromJs`.
        debug_assert_eq!(
            std::mem::discriminant(&self.ecosystem),
            std::mem::discriminant(&page.ecosystem)
        );
        let mut dst = self.inner.lock().unwrap();
        let mut src = page.inner.lock().unwrap();
        let field = self.hash_field();
        let from = u64::try_from(from_block).unwrap_or(0);
        let cross = dst
            .table
            .first_field_mismatch(&src.table, field, from)
            .map(|key| HashMismatch {
                block_number: key as i64,
                stored_hash: self.hash_display(dst.table.field_bytes(&key, field).unwrap()),
                received_hash: self.hash_display(src.table.field_bytes(&key, field).unwrap()),
            });
        debug_assert!(
            src.page.conflict.is_none(),
            "response stores must be validated before persistent merge"
        );
        if cross.is_none() || report_only {
            dst.table.append_from(&mut src.table);
            // The page's response-only state validates this response only. It
            // must not become persistent chain data, where the cursor coverage
            // could outlive the queried fork.
            src.page = ResponsePage::default();
        }
        cross
    }

    /// Append a backend page to a logical response store. Unlike `merge`, this
    /// always appends rows: an internal conflict invalidates the complete
    /// response, so the caller will discard the aggregate and retry it. The
    /// lowest conflict is retained only for diagnostics.
    #[napi]
    pub fn append_page(&self, page: &BlockStore) {
        if std::ptr::eq(self, page) {
            return;
        }
        debug_assert_eq!(
            std::mem::discriminant(&self.ecosystem),
            std::mem::discriminant(&page.ecosystem)
        );
        let mut dst = self.inner.lock().unwrap();
        let mut src = page.inner.lock().unwrap();
        let field = self.hash_field();
        let cross = dst
            .table
            .first_field_mismatch(&src.table, field, 0)
            .map(|key| HashMismatch {
                block_number: key as i64,
                stored_hash: self.hash_display(dst.table.field_bytes(&key, field).unwrap()),
                received_hash: self.hash_display(src.table.field_bytes(&key, field).unwrap()),
            });
        let conflict = lowest_conflict(cross, src.page.conflict.take());
        if let Some(conflict) = conflict {
            record_conflict(&mut dst.page.conflict, conflict);
        }
        dst.table.append_from(&mut src.table);
        for range in src.page.svm_covered_ranges.drain(..) {
            add_svm_covered_range(&mut dst.page.svm_covered_ranges, range);
        }
    }

    /// Return the response-internal conflict, if one was recorded while this
    /// store was built. This is non-consuming so callers can log it before
    /// discarding the complete response.
    #[napi]
    pub fn response_conflict(&self) -> Option<HashMismatch> {
        self.inner.lock().unwrap().page.conflict.clone()
    }

    /// Return requested block numbers that are not covered by this response.
    /// EVM/Fuel require an exact block hash. SVM also accepts a missing slot
    /// when the HyperSync cursor proved that its range was fully processed.
    #[napi]
    pub fn missing_hashes(&self, block_numbers: Vec<i64>) -> Vec<i64> {
        let inner = self.inner.lock().unwrap();
        let field = self.hash_field();
        block_numbers
            .into_iter()
            .filter(|n| {
                let Some(key) = u64::try_from(*n).ok() else {
                    return true;
                };
                if inner.table.field_bytes(&key, field).is_some() {
                    return false;
                }
                match self.ecosystem {
                    Ecosystem::Svm => !svm_slot_is_covered(&inner.page.svm_covered_ranges, key),
                    _ => true,
                }
            })
            .collect()
    }

    /// Compare a validated response store with the persistent store in request
    /// order, stopping at the first mismatch. The highest matching requested
    /// block is the rollback target.
    #[napi]
    pub fn latest_valid_block_from_store(
        &self,
        response: &BlockStore,
        block_numbers: Vec<i64>,
    ) -> Option<i64> {
        if std::ptr::eq(self, response) {
            return block_numbers.into_iter().max();
        }
        let persistent = self.inner.lock().unwrap();
        let received = response.inner.lock().unwrap();
        let field = self.hash_field();
        let mut requested = block_numbers;
        requested.sort_unstable();
        requested.dedup();
        let mut previous = None;
        for block_number in requested {
            let key = match u64::try_from(block_number) {
                Ok(key) => key,
                Err(_) => return previous,
            };
            let stored = persistent.table.field_bytes(&key, field);
            let fetched = received.table.field_bytes(&key, field);
            match (stored, fetched) {
                (Some(stored), Some(fetched)) if stored == fetched => previous = Some(block_number),
                _ => return previous,
            }
        }
        previous
    }

    /// Hash of a stored block, if the store still holds it. Feeds the persisted
    /// reorg checkpoints.
    #[napi]
    pub fn get_hash(&self, block_number: i64) -> Option<String> {
        let key = u64::try_from(block_number).ok()?;
        let inner = self.inner.lock().unwrap();
        inner
            .table
            .field_bytes(&key, self.hash_field())
            .map(|b| self.hash_display(b))
    }

    /// Block numbers in `[from_block, below_block)` with a stored hash,
    /// ascending — the rollback candidates to re-fetch and compare.
    #[napi]
    pub fn get_hashed_block_numbers(&self, from_block: i64, below_block: i64) -> Vec<i64> {
        let from = u64::try_from(from_block).unwrap_or(0);
        let below = match u64::try_from(below_block) {
            Ok(v) => v,
            Err(_) => return Vec::new(),
        };
        self.inner
            .lock()
            .unwrap()
            .table
            .keys_with_field(from, below, self.hash_field())
            .into_iter()
            .map(|k| k as i64)
            .collect()
    }

    /// Bulk-materialise blocks in columnar form, one row per `block_numbers[i]`
    /// key, decoding only the fields whose bit is set in that row's own
    /// `masks[i]`. Each mask is a JS number (`f64`) carrying a selection bitmask
    /// over field codes. The lock is held only to gather the requested cells;
    /// decoding runs after it is released, off the JS thread via
    /// `block_in_place`. Missing keys yield an empty object. Result is aligned
    /// with input.
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
                let scratch = self.gather(&block_numbers, &masks);
                tokio::task::block_in_place(|| {
                    decode_evm_block_columns(&scratch, &block_numbers, &masks, should_checksum)
                })
                .map_err(map_err)
            }
            Ecosystem::Svm => {
                let scratch = self.gather(&block_numbers, &masks);
                tokio::task::block_in_place(|| {
                    decode_svm_block_columns(&scratch, &block_numbers, &masks)
                })
                .map_err(map_err)
            }
            Ecosystem::Fuel => {
                let scratch = self.gather(&block_numbers, &masks);
                tokio::task::block_in_place(|| {
                    decode_fuel_block_columns(&scratch, &block_numbers, &masks)
                })
                .map_err(map_err)
            }
        }
    }

    /// Drop blocks at or below `up_to_block` (already processed), except that
    /// blocks at or above `keep_hashes_from` keep their hash — still needed for
    /// reorg detection until they leave the reorg threshold.
    #[napi]
    pub fn prune(&self, up_to_block: i64, keep_hashes_from: i64) {
        if let Ok(up_to) = u64::try_from(up_to_block) {
            let keep_from = u64::try_from(keep_hashes_from).unwrap_or(0);
            self.inner.lock().unwrap().table.prune_keeping_field(
                up_to,
                keep_from,
                self.hash_field(),
            );
        }
    }

    /// Drop all blocks above `target_block` (rolled back), hashes included. The
    /// rolled-back range is refetched, so its stale hashes must not linger for
    /// reorg detection.
    #[napi]
    pub fn rollback(&self, target_block: i64) {
        let mut inner = self.inner.lock().unwrap();
        match u64::try_from(target_block) {
            Ok(target) => inner.table.rollback(target),
            Err(_) => inner.table.clear(),
        }
    }
}

impl BlockStore {
    /// Mark a half-open SVM range as completely processed by HyperSync. Missing
    /// rows inside it are verified skipped slots.
    pub(crate) fn mark_svm_coverage(&self, from_slot: i64, to_slot_exclusive: i64) -> Result<()> {
        if !matches!(self.ecosystem, Ecosystem::Svm) {
            anyhow::bail!("SVM coverage can only be recorded on an SVM block store");
        }
        let from = u64::try_from(from_slot).context("SVM coverage start is negative")?;
        let to_exclusive =
            u64::try_from(to_slot_exclusive).context("SVM coverage end is negative")?;
        if from >= to_exclusive {
            anyhow::bail!(
                "SVM coverage must advance: from_slot={from_slot}, to_slot_exclusive={to_slot_exclusive}"
            );
        }

        let mut inner = self.inner.lock().unwrap();
        add_svm_covered_range(
            &mut inner.page.svm_covered_ranges,
            SvmCoveredRange { from, to_exclusive },
        );
        Ok(())
    }

    fn with_ecosystem(ecosystem: Ecosystem) -> Self {
        let n_fields = match ecosystem {
            Ecosystem::Evm { .. } => EvmBlockField::VARIANTS.len(),
            Ecosystem::Svm => SvmBlockField::VARIANTS.len(),
            Ecosystem::Fuel => FuelBlockField::VARIANTS.len(),
        };
        Self {
            inner: Mutex::new(Inner {
                table: Table::new(n_fields),
                page: ResponsePage::default(),
            }),
            ecosystem,
        }
    }

    /// The ecosystem's block-hash field code — the field reorg detection
    /// compares and the threshold prune retains.
    fn hash_field(&self) -> usize {
        match self.ecosystem {
            Ecosystem::Evm { .. } => EvmBlockField::Hash as usize,
            Ecosystem::Svm => SvmBlockField::Hash as usize,
            Ecosystem::Fuel => FuelBlockField::Id as usize,
        }
    }

    /// A stored hash cell in the shape JS knows it by: hex for the byte-backed
    /// EVM/Fuel hashes, the raw base58 string for SVM.
    fn hash_display(&self, bytes: &[u8]) -> String {
        match self.ecosystem {
            Ecosystem::Svm => String::from_utf8_lossy(bytes).into_owned(),
            _ => hex_full(bytes),
        }
    }

    fn gather(&self, block_numbers: &[i64], masks: &[u64]) -> Vec<Option<AnyCol>> {
        let keys: Vec<Option<u64>> = block_numbers
            .iter()
            .map(|&n| u64::try_from(n).ok())
            .collect();
        self.inner
            .lock()
            .unwrap()
            .table
            .gather_scratch(&keys, masks)
    }

    /// Merge one response's EVM blocks into the table (called by the HyperSync
    /// source while building a page). One block per number, so overlapping
    /// partition re-fetches overwrite in place instead of duplicating. Not
    /// exposed to JS.
    pub(crate) fn insert_evm_blocks(&self, mut blocks: Vec<simple_types::Block>) {
        blocks.retain(|b| b.number.is_some());
        if blocks.is_empty() {
            return;
        }
        let keys: Vec<u64> = blocks.iter().map(|b| b.number.unwrap()).collect();
        let cols: Vec<Option<AnyCol>> = EvmBlockField::VARIANTS
            .iter()
            .map(|&f| evm_block_col(f, &blocks))
            .collect();
        self.insert_watching_hash(keys, cols);
    }

    /// Merge a batch, first recording any hash conflict it introduces (against
    /// the table or within the batch itself), keeping the lowest block number.
    fn insert_watching_hash(&self, keys: Vec<u64>, cols: Vec<Option<AnyCol>>) {
        let field = self.hash_field();
        let mut inner = self.inner.lock().unwrap();
        let conflict = inner
            .table
            .detect_field_conflict(&keys, cols[field].as_ref(), field);
        inner.table.merge_batch(keys, cols);
        if let Some((key, stored, received)) = conflict {
            record_conflict(
                &mut inner.page.conflict,
                HashMismatch {
                    block_number: key as i64,
                    stored_hash: self.hash_display(&stored),
                    received_hash: self.hash_display(&received),
                },
            );
        }
    }

    /// Merge one response's SVM blocks into the table, keyed by slot. Not
    /// exposed to JS.
    pub(crate) fn insert_svm_blocks(&self, blocks: Vec<solana_simple::Block>) {
        if blocks.is_empty() {
            return;
        }
        let keys = blocks.iter().map(|b| b.slot).collect();
        let cols = SvmBlockField::VARIANTS
            .iter()
            .map(|&f| svm_block_col(f, &blocks))
            .collect();
        self.insert_watching_hash(keys, cols);
    }

    /// Merge a response's rollback-guard blocks into the page as hash-only
    /// rows: the guard's head block and the parent of the first in-memory
    /// block. Not exposed to JS.
    pub(crate) fn insert_rollback_guard_blocks(
        &self,
        guard: &crate::evm_hypersync_source::types::RollbackGuard,
    ) -> Result<()> {
        let mut rows = vec![simple_types::Block {
            number: Some(u64::try_from(guard.block_number).context("guard block_number negative")?),
            hash: Some(Hash::decode_hex(&guard.hash).context("decoding guard hash")?),
            ..Default::default()
        }];
        if guard.first_block_number > 0 {
            rows.push(simple_types::Block {
                number: Some((guard.first_block_number - 1) as u64),
                hash: Some(
                    Hash::decode_hex(&guard.first_parent_hash)
                        .context("decoding guard parent hash")?,
                ),
                ..Default::default()
            });
        }
        self.insert_evm_blocks(rows);
        Ok(())
    }

    /// Merge one response's Fuel blocks into the table, keyed by height.
    pub(crate) fn insert_fuel_block_rows(&self, blocks: Vec<FuelBlockRow>) {
        if blocks.is_empty() {
            return;
        }
        let keys = blocks.iter().map(|b| b.height).collect();
        let cols = FuelBlockField::VARIANTS
            .iter()
            .map(|&f| fuel_block_col(f, &blocks))
            .collect();
        self.insert_watching_hash(keys, cols);
    }

    /// Merge sparse JS SVM blocks into the table, keyed by slot.
    fn insert_svm_inputs(&self, blocks: Vec<SvmBlockInput>) -> napi::Result<()> {
        if blocks.is_empty() {
            return Ok(());
        }
        let keys = blocks
            .iter()
            .map(|b| u64::try_from(b.slot).context("block.slot negative"))
            .collect::<Result<Vec<_>>>()
            .map_err(map_err)?;
        let cols = SvmBlockField::VARIANTS
            .iter()
            .map(|&f| {
                use SvmBlockField::*;
                match f {
                    Slot => None,
                    Time => i64_from(&blocks, |b| b.time),
                    Hash => str_from(&blocks, |b| b.hash.as_deref()),
                    // JS only observes slot/time/hash for reorg tracking.
                    Height | ParentSlot | ParentHash => None,
                }
            })
            .collect();
        self.insert_watching_hash(keys, cols);
        Ok(())
    }
}

/// A block-hash conflict recorded while building a response or comparing it
/// with the persistent store.
#[derive(Clone)]
#[napi(object)]
pub struct HashMismatch {
    pub block_number: i64,
    pub stored_hash: String,
    pub received_hash: String,
}

fn lowest_conflict(
    first: Option<HashMismatch>,
    second: Option<HashMismatch>,
) -> Option<HashMismatch> {
    match (first, second) {
        (Some(a), Some(b)) => Some(if a.block_number <= b.block_number {
            a
        } else {
            b
        }),
        (a, b) => a.or(b),
    }
}

fn record_conflict(target: &mut Option<HashMismatch>, conflict: HashMismatch) {
    if target
        .as_ref()
        .is_none_or(|existing| conflict.block_number < existing.block_number)
    {
        *target = Some(conflict);
    }
}

/// Ordered EVM block-field names — the single source of truth the ReScript
/// `Evm.res blockFields` array is tested against. The order is the bit position
/// in the selection mask, so the two must not drift.
#[napi]
pub fn evm_block_field_names() -> Vec<String> {
    field_names(EvmBlockField::VARIANTS, EvmBlockField::name)
}

/// Ordered SVM block-field names; `Svm.res blockFields` is tested against this.
#[napi]
pub fn svm_block_field_names() -> Vec<String> {
    field_names(SvmBlockField::VARIANTS, SvmBlockField::name)
}

/// Ordered Fuel block-field names; `Fuel.res blockFields` is tested against this.
#[napi]
pub fn fuel_block_field_names() -> Vec<String> {
    field_names(FuelBlockField::VARIANTS, FuelBlockField::name)
}

#[cfg(test)]
mod tests {
    use super::*;
    use hypersync_client::format::{Hash, Quantity};

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

    fn bit(field: EvmBlockField) -> u64 {
        1u64 << (field as u32)
    }

    // `materialize` uses `block_in_place`, which needs a multi-thread runtime.
    #[tokio::test(flavor = "multi_thread")]
    async fn materialize_decodes_only_masked_fields() {
        let store = BlockStore::new_evm(false);
        let mut block = raw_evm_block(1);
        block.gas_used = Some(Quantity::from(99u64));
        store.insert_evm_blocks(vec![block]);

        let mask = bit(EvmBlockField::GasUsed) as f64;
        let cols = store
            .materialize(vec![1], vec![mask])
            .await
            .expect("materialize");

        // Exactly one column (gasUsed) is present; number (resolvable from the
        // key but unselected) and hash are absent.
        let summary = (
            column(&cols, "gasUsed").is_some(),
            column(&cols, "number").is_some(),
            column(&cols, "hash").is_some(),
        );
        assert_eq!(summary, (true, false, false));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn number_comes_from_key_even_on_miss() {
        // A missing row still materialises the requested key as `number`, so it
        // never depends on a fetched block row.
        let store = BlockStore::new_evm(false);
        store.insert_evm_blocks(vec![raw_evm_block(3)]);

        let mask = bit(EvmBlockField::Number) as f64;
        let cols = store
            .materialize(vec![7, 3], vec![mask, mask])
            .await
            .expect("materialize");
        match column(&cols, "number") {
            Some(Column::I64(v)) => assert_eq!(v, &vec![Some(7), Some(3)]),
            other => panic!(
                "expected number i64 column, got present={}",
                other.is_some()
            ),
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn decode_applies_each_rows_own_mask() {
        // Both rows have a stored gasUsed, but only row 0 selects it — proving
        // the per-row mask, not the stored data, gates materialisation.
        let store = BlockStore::new_evm(false);
        let mut block1 = raw_evm_block(1);
        block1.gas_used = Some(Quantity::from(100u64));
        let mut block2 = raw_evm_block(2);
        block2.gas_used = Some(Quantity::from(200u64));
        store.insert_evm_blocks(vec![block1, block2]);

        let mask = bit(EvmBlockField::GasUsed) as f64;
        let cols = store
            .materialize(vec![1, 2], vec![mask, 0.])
            .await
            .expect("materialize");
        match column(&cols, "gasUsed") {
            Some(Column::Big(v)) => assert_eq!((v[0].is_some(), v[1].is_some()), (true, false)),
            other => panic!("expected gasUsed column, got present={}", other.is_some()),
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn materialize_returns_stored_extra_fields_via_store() {
        let store = BlockStore::new_evm(false);
        let mut block = raw_evm_block(10);
        block.timestamp = Some(Quantity::from(999u64));
        block.hash = Some(Hash::from([0xabu8; 32]));
        block.gas_used = Some(Quantity::from(555u64));
        store.insert_evm_blocks(vec![block]);

        // A production-shaped mask: the config-extended trio plus a selected
        // extra field, all decoded from the one stored row.
        let mask = (bit(EvmBlockField::Number)
            | bit(EvmBlockField::Timestamp)
            | bit(EvmBlockField::Hash)
            | bit(EvmBlockField::GasUsed)) as f64;
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
                vec![Some(format!("0x{}", "ab".repeat(32)))]
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn field_union_across_batches_resolves_both_fields() {
        // The same block arrives twice with different populated fields (e.g. a
        // hash-only observation later enriched by a full fetch): reads union
        // them.
        let store = BlockStore::new_evm(false);
        let mut with_hash = raw_evm_block(20);
        with_hash.hash = Some(Hash::from([0x11u8; 32]));
        store.insert_evm_blocks(vec![with_hash]);
        let mut with_gas = raw_evm_block(20);
        with_gas.gas_used = Some(Quantity::from(42u64));
        store.insert_evm_blocks(vec![with_gas]);

        let mask = (bit(EvmBlockField::Hash) | bit(EvmBlockField::GasUsed)) as f64;
        let cols = store
            .materialize(vec![20], vec![mask])
            .await
            .expect("materialize");
        let summary = (
            match column(&cols, "hash") {
                Some(Column::Str(v)) => v.clone(),
                _ => panic!("expected hash column"),
            },
            column(&cols, "gasUsed").is_some(),
        );
        assert_eq!(
            summary,
            (vec![Some(format!("0x{}", "11".repeat(32)))], true)
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn svm_materialize_decodes_selected_fields() {
        let store = BlockStore::new_svm();
        let mut block = raw_svm_block(9);
        block.block_height = Some(777);
        store.insert_svm_blocks(vec![block]);

        let mask = ((1u64 << (SvmBlockField::Slot as u32))
            | (1u64 << (SvmBlockField::Hash as u32))
            | (1u64 << (SvmBlockField::Time as u32))
            | (1u64 << (SvmBlockField::Height as u32))) as f64;
        let cols = store
            .materialize(vec![9], vec![mask])
            .await
            .expect("materialize");
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
            match column(&cols, "height") {
                Some(Column::I64(v)) => v.clone(),
                _ => panic!("expected height column"),
            },
            column(&cols, "parentSlot").is_some(),
        );
        assert_eq!(
            summary,
            (
                vec![Some(9)],
                vec![Some("hash".to_string())],
                vec![Some(123)],
                vec![Some(777)],
                false
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn prune_and_rollback_drop_by_block() {
        let store = BlockStore::new_evm(false);
        let blocks = [10u64, 20, 30]
            .into_iter()
            .map(|n| {
                let mut b = raw_evm_block(n);
                b.timestamp = Some(Quantity::from(n));
                b
            })
            .collect();
        store.insert_evm_blocks(blocks);

        let mask = bit(EvmBlockField::Timestamp) as f64;
        store.prune(10, 11);
        let after_prune = store
            .materialize(vec![10, 20, 30], vec![mask, mask, mask])
            .await
            .expect("materialize");
        store.rollback(20);
        let after_rollback = store
            .materialize(vec![10, 20, 30], vec![mask, mask, mask])
            .await
            .expect("materialize");

        let timestamps = |cols: &Columns| match column(cols, "timestamp") {
            Some(Column::I64(v)) => v.clone(),
            _ => panic!("expected timestamp column"),
        };
        assert_eq!(
            (timestamps(&after_prune), timestamps(&after_rollback)),
            (vec![None, Some(20), Some(30)], vec![None, Some(20), None])
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn merge_resolves_re_fetched_block_to_newest() {
        // A rolled-back block re-fetched with different content must resolve to
        // the fresh copy — the sequence a chain reorg drives through
        // `ChainState`: merge a page, then merge a later page for the same
        // (re-fetched) block number.
        let persistent = BlockStore::new_evm(false);

        let page1 = BlockStore::new_evm(false);
        let mut first = raw_evm_block(20);
        first.timestamp = Some(Quantity::from(100u64));
        page1.insert_evm_blocks(vec![first]);
        persistent.merge(&page1, 0, false);

        let page2 = BlockStore::new_evm(false);
        let mut second = raw_evm_block(20);
        second.timestamp = Some(Quantity::from(200u64));
        page2.insert_evm_blocks(vec![second]);
        persistent.merge(&page2, 0, false);

        let mask = bit(EvmBlockField::Timestamp) as f64;
        let cols = persistent
            .materialize(vec![20], vec![mask])
            .await
            .expect("materialize");
        match column(&cols, "timestamp") {
            Some(Column::I64(v)) => assert_eq!(v, &vec![Some(200)]),
            other => panic!("expected timestamp column, got present={}", other.is_some()),
        }
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

        let fuel_codes: Vec<i32> = FuelBlockField::VARIANTS.iter().map(|&f| f as i32).collect();
        assert_eq!(
            fuel_codes,
            Vec::from_iter(0..FuelBlockField::VARIANTS.len() as i32)
        );
        let fuel_names: Vec<&str> = FuelBlockField::VARIANTS.iter().map(|f| f.name()).collect();
        assert_eq!(fuel_names, vec!["height", "id", "time"]);
    }

    fn hashed_evm_block(number: u64, byte: u8) -> simple_types::Block {
        let mut b = raw_evm_block(number);
        b.hash = Some(Hash::from([byte; 32]));
        b
    }

    fn evm_page(blocks: Vec<simple_types::Block>) -> BlockStore {
        let page = BlockStore::new_evm(false);
        page.insert_evm_blocks(blocks);
        page
    }

    #[test]
    fn merge_reports_lowest_hash_mismatch_and_discards_page() {
        let persistent = evm_page(vec![
            hashed_evm_block(10, 0x10),
            hashed_evm_block(11, 0x11),
            hashed_evm_block(12, 0x12),
        ]);

        // Two conflicting blocks: the lowest one is reported.
        let page = evm_page(vec![hashed_evm_block(11, 0xbb), hashed_evm_block(12, 0xcc)]);
        let mismatch = persistent.merge(&page, 0, false).expect("mismatch");
        assert_eq!(
            (
                mismatch.block_number,
                mismatch.stored_hash,
                mismatch.received_hash
            ),
            (
                11,
                format!("0x{}", "11".repeat(32)),
                format!("0x{}", "bb".repeat(32))
            )
        );
        // Rollback mode: nothing merged, the stored hash is unchanged.
        assert_eq!(
            persistent.get_hash(11),
            Some(format!("0x{}", "11".repeat(32)))
        );
    }

    #[test]
    fn merge_report_only_still_overwrites() {
        let persistent = evm_page(vec![hashed_evm_block(11, 0x11)]);
        let page = evm_page(vec![hashed_evm_block(11, 0xbb)]);
        let mismatch = persistent.merge(&page, 0, true).expect("mismatch");
        assert_eq!(mismatch.block_number, 11);
        // Detect-only mode converges to the received hash, so the same
        // mismatch doesn't re-report on the next page.
        assert_eq!(
            persistent.get_hash(11),
            Some(format!("0x{}", "bb".repeat(32)))
        );
    }

    #[test]
    fn merge_skips_mismatches_below_from_block_and_hashless_blocks() {
        let persistent = evm_page(vec![hashed_evm_block(10, 0x10), hashed_evm_block(20, 0x20)]);
        // Block 10 conflicts but is below the reorg threshold; block 20 has no
        // hash on the incoming side (the Fuel-style hashless merge).
        let mut no_hash = raw_evm_block(20);
        no_hash.timestamp = Some(Quantity::from(7u64));
        let page = evm_page(vec![hashed_evm_block(10, 0xaa), no_hash]);
        assert!(persistent.merge(&page, 15, false).is_none());
        // The page merged: the overwrite applied below the threshold too.
        assert_eq!(
            persistent.get_hash(10),
            Some(format!("0x{}", "aa".repeat(32)))
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn prune_keeps_hashes_in_threshold() {
        let store = evm_page(vec![
            hashed_evm_block(10, 0x10),
            hashed_evm_block(20, 0x20),
            hashed_evm_block(30, 0x30),
        ]);

        // Everything up to 30 is processed; hashes from 20 stay for reorg
        // detection.
        store.prune(30, 20);

        assert_eq!(
            (
                store.get_hash(10),
                store.get_hash(20),
                store.get_hash(30),
                store.get_hashed_block_numbers(0, 100),
            ),
            (
                None,
                Some(format!("0x{}", "20".repeat(32))),
                Some(format!("0x{}", "30".repeat(32))),
                vec![20, 30],
            )
        );

        // The kept rows are hash-only: timestamp no longer materialises.
        let mask = (bit(EvmBlockField::Timestamp) | bit(EvmBlockField::Hash)) as f64;
        let cols = store
            .materialize(vec![20], vec![mask])
            .await
            .expect("materialize");
        assert_eq!(
            (
                match column(&cols, "timestamp") {
                    Some(Column::I64(v)) => v.iter().any(|c| c.is_some()),
                    None => false,
                    _ => panic!("expected timestamp column"),
                },
                {
                    match column(&cols, "hash") {
                        Some(Column::Str(v)) => v.clone(),
                        _ => panic!("expected hash column"),
                    }
                }
            ),
            (false, vec![Some(format!("0x{}", "20".repeat(32)))])
        );
    }

    #[test]
    fn response_conflict_is_not_a_reorg() {
        // The same block observed twice with different hashes inside one page
        // (e.g. a rollback guard disagreeing with a returned block) invalidates
        // the response even though the page dedupes on insert.
        let page = BlockStore::new_evm(false);
        page.insert_evm_blocks(vec![hashed_evm_block(11, 0x11)]);
        page.insert_evm_blocks(vec![hashed_evm_block(11, 0xbb)]);

        let mismatch = page.response_conflict().expect("response conflict");
        assert_eq!(
            (
                mismatch.block_number,
                mismatch.stored_hash,
                mismatch.received_hash
            ),
            (
                11,
                format!("0x{}", "11".repeat(32)),
                format!("0x{}", "bb".repeat(32))
            )
        );

        // The aggregate retains conflicts across backend pages too.
        let aggregate = BlockStore::new_evm(false);
        aggregate.append_page(&page);
        assert!(aggregate.response_conflict().is_some());

        // The same duplicate with an identical hash is fine.
        let page = BlockStore::new_evm(false);
        page.insert_evm_blocks(vec![hashed_evm_block(11, 0x11)]);
        page.insert_evm_blocks(vec![hashed_evm_block(11, 0x11)]);
        assert!(page.response_conflict().is_none());
    }

    #[test]
    fn response_store_comparison_and_coverage_stay_in_rust() {
        let persistent = evm_page(vec![
            hashed_evm_block(10, 0x10),
            hashed_evm_block(11, 0x11),
            hashed_evm_block(12, 0x12),
        ]);
        let response = evm_page(vec![hashed_evm_block(10, 0x10), hashed_evm_block(11, 0xbb)]);

        assert_eq!(response.missing_hashes(vec![10, 11, 12]), vec![12]);
        assert_eq!(
            persistent.latest_valid_block_from_store(&response, vec![10, 11, 12]),
            Some(10)
        );

        let response = evm_page(vec![hashed_evm_block(12, 0x12)]);
        assert_eq!(
            persistent.latest_valid_block_from_store(&response, vec![10, 11, 12]),
            None
        );
    }

    #[test]
    fn svm_cursor_coverage_accepts_skipped_slots() {
        // Cursor coverage proves every slot in [10, 15) was processed, so the
        // missing interior slots and the missing upper slot are valid skips.
        let response = BlockStore::new_svm();
        response.insert_svm_blocks(vec![raw_svm_block(10), raw_svm_block(13)]);
        assert_eq!(
            response.missing_hashes(vec![10, 11, 12, 13, 14]),
            vec![11, 12, 14]
        );
        response.mark_svm_coverage(10, 15).unwrap();
        assert!(response.missing_hashes(vec![10, 11, 12, 13, 14]).is_empty());
        assert!(response.response_conflict().is_none());
    }

    #[test]
    fn svm_coverage_aggregates_across_pages_but_is_not_persisted() {
        let first_page = BlockStore::new_svm();
        first_page.mark_svm_coverage(10, 12).unwrap();
        let second_page = BlockStore::new_svm();
        second_page.mark_svm_coverage(12, 15).unwrap();

        let response = BlockStore::new_svm();
        response.append_page(&first_page);
        response.append_page(&second_page);
        assert!(response.missing_hashes(vec![10, 11, 12, 13, 14]).is_empty());

        let persistent = BlockStore::new_svm();
        assert!(persistent.merge(&response, 0, false).is_none());
        assert_eq!(
            persistent.missing_hashes(vec![10, 11, 12, 13, 14]),
            vec![10, 11, 12, 13, 14]
        );
        assert_eq!(
            response.missing_hashes(vec![10, 11, 12, 13, 14]),
            vec![10, 11, 12, 13, 14]
        );
    }

    #[test]
    fn append_page_detects_cross_page_conflict_but_keeps_rows() {
        let aggregate = evm_page(vec![hashed_evm_block(10, 0x10)]);
        let next = evm_page(vec![hashed_evm_block(10, 0xaa), hashed_evm_block(11, 0x11)]);

        aggregate.append_page(&next);

        assert_eq!(
            aggregate.get_hash(11),
            Some(format!("0x{}", "11".repeat(32)))
        );
        let conflict = aggregate.response_conflict().expect("cross-page conflict");
        assert_eq!(
            (
                conflict.block_number,
                conflict.stored_hash,
                conflict.received_hash
            ),
            (
                10,
                format!("0x{}", "10".repeat(32)),
                format!("0x{}", "aa".repeat(32))
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn fuel_store_materializes_and_detects() {
        let page = BlockStore::new_fuel();
        page.insert_fuel_block_rows(vec![FuelBlockRow {
            height: 5,
            id: Some([0xee_u8; 32].to_vec()),
            time: Some(123),
        }]);

        let persistent = BlockStore::new_fuel();
        assert!(persistent.merge(&page, 0, false).is_none());

        let mask = ((1u64 << (FuelBlockField::Height as u32))
            | (1u64 << (FuelBlockField::Time as u32))
            | (1u64 << (FuelBlockField::Id as u32))) as f64;
        let cols = persistent
            .materialize(vec![5], vec![mask])
            .await
            .expect("materialize");
        let summary = (
            match column(&cols, "height") {
                Some(Column::I64(v)) => v.clone(),
                _ => panic!("expected height column"),
            },
            match column(&cols, "time") {
                Some(Column::I64(v)) => v.clone(),
                _ => panic!("expected time column"),
            },
            match column(&cols, "id") {
                Some(Column::Str(v)) => v.clone(),
                _ => panic!("expected id column"),
            },
        );
        assert_eq!(
            summary,
            (
                vec![Some(5)],
                vec![Some(123)],
                vec![Some(format!("0x{}", "ee".repeat(32)))]
            )
        );

        // A conflicting id on a later page is a reorg.
        let conflicting = BlockStore::new_fuel();
        conflicting.insert_fuel_block_rows(vec![FuelBlockRow {
            height: 5,
            id: Some([0xdd_u8; 32].to_vec()),
            time: Some(124),
        }]);
        let mismatch = persistent.merge(&conflicting, 0, false).expect("mismatch");
        assert_eq!(mismatch.block_number, 5);

        // A hashless fuel row merges without detection.
        let hashless = BlockStore::new_fuel();
        hashless.insert_fuel_block_rows(vec![FuelBlockRow {
            height: 5,
            id: None,
            time: Some(125),
        }]);
        assert!(persistent.merge(&hashless, 0, false).is_none());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn from_js_evm_round_trips_sparse_blocks() {
        let store = BlockStore::from_js_evm(
            vec![
                EvmBlockInput {
                    number: 7,
                    timestamp: Some(999),
                    hash: Some(format!("0x{}", "ab".repeat(32))),
                },
                // A hash-only guard row (no timestamp).
                EvmBlockInput {
                    number: 8,
                    timestamp: None,
                    hash: Some(format!("0x{}", "cd".repeat(32))),
                },
            ],
            false,
        )
        .expect("fromJs");

        let mask = (bit(EvmBlockField::Number)
            | bit(EvmBlockField::Timestamp)
            | bit(EvmBlockField::Hash)) as f64;
        let cols = store
            .materialize(vec![7], vec![mask])
            .await
            .expect("materialize");
        let summary = (
            match column(&cols, "timestamp") {
                Some(Column::I64(v)) => v.clone(),
                _ => panic!("expected timestamp column"),
            },
            match column(&cols, "hash") {
                Some(Column::Str(v)) => v.clone(),
                _ => panic!("expected hash column"),
            },
            store.get_hash(8),
        );
        assert_eq!(
            summary,
            (
                vec![Some(999)],
                vec![Some(format!("0x{}", "ab".repeat(32)))],
                Some(format!("0x{}", "cd".repeat(32)))
            )
        );
    }

    #[test]
    fn from_js_svm_stores_hashes() {
        let store = BlockStore::from_js_svm(vec![SvmBlockInput {
            slot: 42,
            time: Some(1),
            hash: Some("base58hash".to_string()),
        }])
        .expect("fromJs");
        assert_eq!(store.get_hash(42), Some("base58hash".to_string()));
    }

    #[test]
    fn from_js_fuel_stores_hashes() {
        let store = BlockStore::from_js_fuel(vec![FuelBlockInput {
            height: 9,
            id: Some(format!("0x{}", "ee".repeat(32))),
            time: Some(3),
        }])
        .expect("fromJs");
        assert_eq!(store.get_hash(9), Some(format!("0x{}", "ee".repeat(32))));
    }
}
