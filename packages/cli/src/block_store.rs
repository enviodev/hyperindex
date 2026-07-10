//! Per-chain block store: a merge-on-insert `Table` keyed by number (slot on
//! SVM), holding only the selected fields' columns. Large values never cross
//! the napi boundary until read. At batch preparation the fields a chain's
//! events selected are gathered under the store lock and decoded in bulk, off
//! the JS thread, into columnar form; the main thread zips the columns into
//! plain JS objects. The store lives on the ReScript `ChainState`; fetch
//! responses merge in, and rows are pruned or rolled back by block.

use std::collections::BTreeMap;
use std::sync::Mutex;

use anyhow::{Context, Result};
use hypersync_client::format::{Address, Data, Hash, Hex, Nonce, Quantity};
use hypersync_client::simple_types;
use hypersync_client_solana::simple_types as solana_simple;
use napi::bindgen_prelude::BigInt;
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
    Time = 1,
    Id = 2,
}

impl FuelBlockField {
    /// JS property name; must match `Fuel.res` `blockFields`.
    pub fn name(self) -> &'static str {
        use FuelBlockField::*;
        match self {
            Height => "height",
            Time => "time",
            Id => "id",
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
    pub id: Option<[u8; 32]>,
    pub time: Option<i64>,
}

/// Build one Fuel field's column; `None` for the key-derived `height`.
fn fuel_block_col(field: FuelBlockField, blocks: &[FuelBlockRow]) -> Option<AnyCol> {
    use FuelBlockField::*;
    match field {
        // The height is the table key, not a column.
        Height => None,
        Time => i64_from(blocks, |b| b.time),
        Id => fixed_from(blocks, 32, |b| b.id.as_ref().map(|h| h.as_slice())),
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
        Time => Column::I64(i64_cells(col, len)),
        Id => Column::Str(bytes_cells(col, len, |b| Ok(Some(hex_full(b))))?),
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

/// A sparse EVM block from JS for `fromJsEvm`: every field optional except the
/// key. Field types mirror the materialised `Internal.eventBlock` shape, so a
/// block round-trips through the store unchanged.
#[napi(object)]
pub struct EvmBlockInput {
    pub number: i64,
    pub timestamp: Option<i64>,
    pub hash: Option<String>,
    pub parent_hash: Option<String>,
    pub nonce: Option<BigInt>,
    pub sha3_uncles: Option<String>,
    pub logs_bloom: Option<String>,
    pub transactions_root: Option<String>,
    pub state_root: Option<String>,
    pub receipts_root: Option<String>,
    pub miner: Option<String>,
    pub difficulty: Option<BigInt>,
    pub total_difficulty: Option<BigInt>,
    pub extra_data: Option<String>,
    pub size: Option<BigInt>,
    pub gas_limit: Option<BigInt>,
    pub gas_used: Option<BigInt>,
    pub uncles: Option<Vec<String>>,
    pub base_fee_per_gas: Option<BigInt>,
    pub blob_gas_used: Option<BigInt>,
    pub excess_blob_gas: Option<BigInt>,
    pub parent_beacon_block_root: Option<String>,
    pub withdrawals_root: Option<String>,
    pub l1_block_number: Option<i64>,
    pub send_count: Option<String>,
    pub send_root: Option<String>,
    pub mix_hash: Option<String>,
}

/// A sparse SVM block from JS for `fromJsSvm`.
#[napi(object)]
pub struct SvmBlockInput {
    pub slot: i64,
    pub time: Option<i64>,
    pub hash: Option<String>,
    pub height: Option<i64>,
    pub parent_slot: Option<i64>,
    pub parent_hash: Option<String>,
}

/// A sparse Fuel block from JS for `fromJsFuel`.
#[napi(object)]
pub struct FuelBlockInput {
    pub height: i64,
    pub id: Option<String>,
    pub time: Option<i64>,
}

/// A JS bigint's magnitude as minimal big-endian bytes (the `Quantity` wire
/// shape). Sign is ignored — chain quantities are non-negative.
fn bigint_be_bytes(b: &BigInt) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::with_capacity(b.words.len() * 8);
    for w in b.words.iter().rev() {
        out.extend_from_slice(&w.to_be_bytes());
    }
    match out.iter().position(|&x| x != 0) {
        Some(idx) => out[idx..].to_vec(),
        None => vec![0],
    }
}

fn bigint_quantity(v: &Option<BigInt>) -> Option<Quantity> {
    v.as_ref().map(|b| Quantity::from(bigint_be_bytes(b)))
}

fn decode_hex_opt<T: Hex>(v: &Option<String>, name: &str) -> Result<Option<T>> {
    v.as_ref()
        .map(|s| T::decode_hex(s).with_context(|| format!("decoding {name}")))
        .transpose()
}

pub(crate) fn decode_hash32(s: &str, name: &str) -> Result<[u8; 32]> {
    let hex = s.strip_prefix("0x").unwrap_or(s);
    let mut out = [0u8; 32];
    faster_hex::hex_decode(hex.as_bytes(), &mut out).with_context(|| format!("decoding {name}"))?;
    Ok(out)
}

/// Rebuild a `simple_types::Block` from JS field values, so `fromJsEvm` rows
/// go through the same column fill as fetched blocks.
fn evm_input_to_simple(b: EvmBlockInput) -> Result<simple_types::Block> {
    Ok(simple_types::Block {
        number: Some(u64::try_from(b.number).context("block.number negative")?),
        hash: decode_hex_opt(&b.hash, "block.hash")?,
        parent_hash: decode_hex_opt(&b.parent_hash, "block.parentHash")?,
        nonce: b
            .nonce
            .as_ref()
            .map(|n| Nonce::from(n.words.first().copied().unwrap_or(0).to_be_bytes())),
        sha3_uncles: decode_hex_opt(&b.sha3_uncles, "block.sha3Uncles")?,
        logs_bloom: decode_hex_opt(&b.logs_bloom, "block.logsBloom")?,
        transactions_root: decode_hex_opt(&b.transactions_root, "block.transactionsRoot")?,
        state_root: decode_hex_opt(&b.state_root, "block.stateRoot")?,
        receipts_root: decode_hex_opt(&b.receipts_root, "block.receiptsRoot")?,
        miner: decode_hex_opt::<Address>(&b.miner, "block.miner")?,
        difficulty: bigint_quantity(&b.difficulty),
        total_difficulty: bigint_quantity(&b.total_difficulty),
        extra_data: decode_hex_opt::<Data>(&b.extra_data, "block.extraData")?,
        size: bigint_quantity(&b.size),
        gas_limit: bigint_quantity(&b.gas_limit),
        gas_used: bigint_quantity(&b.gas_used),
        timestamp: b
            .timestamp
            .map(|t| Quantity::try_from(t).context("block.timestamp negative"))
            .transpose()?,
        uncles: b
            .uncles
            .map(|v| {
                v.iter()
                    .map(|s| Hash::decode_hex(s).context("decoding block.uncles"))
                    .collect::<Result<Vec<_>>>()
            })
            .transpose()?,
        base_fee_per_gas: bigint_quantity(&b.base_fee_per_gas),
        blob_gas_used: bigint_quantity(&b.blob_gas_used),
        excess_blob_gas: bigint_quantity(&b.excess_blob_gas),
        parent_beacon_block_root: decode_hex_opt(
            &b.parent_beacon_block_root,
            "block.parentBeaconBlockRoot",
        )?,
        withdrawals_root: decode_hex_opt(&b.withdrawals_root, "block.withdrawalsRoot")?,
        withdrawals: None,
        l1_block_number: b
            .l1_block_number
            .map(|v| u64::try_from(v).context("block.l1BlockNumber negative"))
            .transpose()?
            .map(Into::into),
        send_count: decode_hex_opt(&b.send_count, "block.sendCount")?,
        send_root: decode_hex_opt(&b.send_root, "block.sendRoot")?,
        mix_hash: decode_hex_opt(&b.mix_hash, "block.mixHash")?,
    })
}

#[napi]
pub struct BlockStore {
    inner: Mutex<Table<u64>>,
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
                        .map(|s| decode_hash32(s, "block.id"))
                        .transpose()?,
                    time: b.time,
                })
            })
            .collect::<Result<Vec<_>>>()
            .map_err(map_err)?;
        store.insert_fuel_block_rows(rows);
        Ok(store)
    }

    /// Move every row from `page` into this store (merging a fetch-response
    /// page into the persistent per-chain store), comparing hashes on the way:
    /// the lowest page block at or above `from_block` whose hash differs from
    /// the stored one is reported as a reorg. A block without a hash on either
    /// side is skipped by the comparison. On a mismatch nothing is merged — the
    /// stored (scanned) hashes stay intact for the rollback comparison — unless
    /// `report_only` is set (detect-only mode), which merges anyway so the
    /// overwritten hash doesn't re-report on every response.
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
        // A page and its persistent store are the same per-chain ecosystem (both
        // derive it from the one chain config), so the decoder is unaffected by
        // the merge.
        debug_assert_eq!(self.ecosystem, page.ecosystem);
        let mut dst = self.inner.lock().unwrap();
        let mut src = page.inner.lock().unwrap();
        let field = self.hash_field();
        let from = u64::try_from(from_block).unwrap_or(0);
        let mismatch = dst
            .first_field_mismatch(&src, field, from)
            .map(|key| HashMismatch {
                block_number: key as i64,
                stored_hash: self.hash_display(dst.field_bytes(&key, field).unwrap()),
                received_hash: self.hash_display(src.field_bytes(&key, field).unwrap()),
            });
        if mismatch.is_none() || report_only {
            dst.append_from(&mut src);
        }
        mismatch
    }

    /// Hash of a stored block, if the store still holds it. Feeds the persisted
    /// reorg checkpoints.
    #[napi]
    pub fn get_hash(&self, block_number: i64) -> Option<String> {
        let key = u64::try_from(block_number).ok()?;
        let inner = self.inner.lock().unwrap();
        inner
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
            .keys_with_field(from, below, self.hash_field())
            .into_iter()
            .map(|k| k as i64)
            .collect()
    }

    /// The highest of the given (number, hash) pairs that still matches the
    /// stored hash, walking them ascending and stopping at the first pair that
    /// mismatches or is no longer stored — the reorg rollback target.
    #[napi]
    pub fn latest_valid_block(
        &self,
        block_numbers: Vec<i64>,
        hashes: Vec<String>,
    ) -> napi::Result<Option<i64>> {
        if block_numbers.len() != hashes.len() {
            return Err(napi::Error::from_reason(format!(
                "latestValidBlock column length mismatch: block_numbers={}, hashes={}",
                block_numbers.len(),
                hashes.len()
            )));
        }
        let pairs: BTreeMap<i64, String> = block_numbers.into_iter().zip(hashes).collect();
        let inner = self.inner.lock().unwrap();
        let field = self.hash_field();
        let mut prev = None;
        for (n, h) in pairs {
            let stored = u64::try_from(n)
                .ok()
                .and_then(|k| inner.field_bytes(&k, field))
                .map(|b| self.hash_display(b));
            match stored {
                Some(s) if s == h => prev = Some(n),
                _ => return Ok(prev),
            }
        }
        Ok(prev)
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
            self.inner
                .lock()
                .unwrap()
                .prune_keeping_field(up_to, keep_from, self.hash_field());
        }
    }

    /// Drop blocks above `target_block` (rolled back).
    #[napi]
    pub fn rollback(&self, target_block: i64) {
        let mut inner = self.inner.lock().unwrap();
        match u64::try_from(target_block) {
            Ok(target) => inner.rollback(target),
            Err(_) => inner.clear(),
        }
    }
}

impl BlockStore {
    fn with_ecosystem(ecosystem: Ecosystem) -> Self {
        let n_fields = match ecosystem {
            Ecosystem::Evm { .. } => EvmBlockField::VARIANTS.len(),
            Ecosystem::Svm => SvmBlockField::VARIANTS.len(),
            Ecosystem::Fuel => FuelBlockField::VARIANTS.len(),
        };
        Self {
            inner: Mutex::new(Table::new(n_fields)),
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
        self.inner.lock().unwrap().gather_scratch(&keys, masks)
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
        let keys = blocks.iter().map(|b| b.number.unwrap()).collect();
        let cols = EvmBlockField::VARIANTS
            .iter()
            .map(|&f| evm_block_col(f, &blocks))
            .collect();
        self.inner.lock().unwrap().merge_batch(keys, cols);
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
        self.inner.lock().unwrap().merge_batch(keys, cols);
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
        self.inner.lock().unwrap().merge_batch(keys, cols);
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
                    Height => u64_from(&blocks, |b| b.height.and_then(|v| u64::try_from(v).ok())),
                    ParentSlot => u64_from(&blocks, |b| {
                        b.parent_slot.and_then(|v| u64::try_from(v).ok())
                    }),
                    ParentHash => str_from(&blocks, |b| b.parent_hash.as_deref()),
                }
            })
            .collect();
        self.inner.lock().unwrap().merge_batch(keys, cols);
        Ok(())
    }
}

/// A reorg detected while merging a page: the lowest in-threshold block whose
/// received hash differs from the stored (previously scanned) one.
#[napi(object)]
pub struct HashMismatch {
    pub block_number: i64,
    pub stored_hash: String,
    pub received_hash: String,
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
        assert_eq!(fuel_names, vec!["height", "time", "id"]);
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
    fn latest_valid_block_stops_at_first_mismatch() {
        let store = evm_page(vec![
            hashed_evm_block(10, 0x10),
            hashed_evm_block(11, 0x11),
            hashed_evm_block(12, 0x12),
        ]);
        let h = |b: &str| format!("0x{}", b.repeat(32));
        assert_eq!(
            (
                store
                    .latest_valid_block(vec![10, 11, 12], vec![h("10"), h("11"), h("12")])
                    .unwrap(),
                store
                    .latest_valid_block(vec![10, 11, 12], vec![h("10"), h("bb"), h("12")])
                    .unwrap(),
                store
                    .latest_valid_block(vec![10, 11], vec![h("aa"), h("11")])
                    .unwrap(),
                // A block the store no longer holds counts as a mismatch.
                store
                    .latest_valid_block(vec![10, 99], vec![h("10"), h("99")])
                    .unwrap(),
            ),
            (Some(12), Some(10), None, Some(10))
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn fuel_store_materializes_and_detects() {
        let page = BlockStore::new_fuel();
        page.insert_fuel_block_rows(vec![FuelBlockRow {
            height: 5,
            id: Some([0xee; 32]),
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
            id: Some([0xdd; 32]),
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
                    parent_hash: None,
                    nonce: Some(BigInt::from(5u64)),
                    sha3_uncles: None,
                    logs_bloom: None,
                    transactions_root: None,
                    state_root: None,
                    receipts_root: None,
                    miner: None,
                    difficulty: None,
                    total_difficulty: None,
                    extra_data: None,
                    size: None,
                    gas_limit: None,
                    gas_used: Some(BigInt::from(555u64)),
                    uncles: None,
                    base_fee_per_gas: None,
                    blob_gas_used: None,
                    excess_blob_gas: None,
                    parent_beacon_block_root: None,
                    withdrawals_root: None,
                    l1_block_number: None,
                    send_count: None,
                    send_root: None,
                    mix_hash: None,
                },
                // A hash-only guard row.
                EvmBlockInput {
                    number: 8,
                    timestamp: None,
                    hash: Some(format!("0x{}", "cd".repeat(32))),
                    parent_hash: None,
                    nonce: None,
                    sha3_uncles: None,
                    logs_bloom: None,
                    transactions_root: None,
                    state_root: None,
                    receipts_root: None,
                    miner: None,
                    difficulty: None,
                    total_difficulty: None,
                    extra_data: None,
                    size: None,
                    gas_limit: None,
                    gas_used: None,
                    uncles: None,
                    base_fee_per_gas: None,
                    blob_gas_used: None,
                    excess_blob_gas: None,
                    parent_beacon_block_root: None,
                    withdrawals_root: None,
                    l1_block_number: None,
                    send_count: None,
                    send_root: None,
                    mix_hash: None,
                },
            ],
            false,
        )
        .expect("fromJs");

        let mask = (bit(EvmBlockField::Number)
            | bit(EvmBlockField::Timestamp)
            | bit(EvmBlockField::Hash)
            | bit(EvmBlockField::GasUsed)) as f64;
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
            match column(&cols, "gasUsed") {
                Some(Column::Big(v)) => v
                    .iter()
                    .map(|b| b.as_ref().map(|b| b.get_u64().1))
                    .collect::<Vec<_>>(),
                _ => panic!("expected gasUsed column"),
            },
            store.get_hash(8),
        );
        assert_eq!(
            summary,
            (
                vec![Some(999)],
                vec![Some(format!("0x{}", "ab".repeat(32)))],
                vec![Some(555)],
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
            height: None,
            parent_slot: None,
            parent_hash: None,
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
