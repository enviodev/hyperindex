//! Per-chain block store, chunk-columnar: every fetch response contributes one
//! chunk of blocks (keyed by number — slot on SVM) holding only the selected
//! fields' columns. Large values never cross the napi boundary until read. At
//! batch preparation the fields a chain's events selected are gathered under
//! the store lock and decoded in bulk, off the JS thread, into columnar form;
//! the main thread zips the columns into plain JS objects. The store lives on
//! the ReScript `ChainState`; fetch responses merge in, and rows are pruned or
//! rolled back by block via the chunk lifecycle.

use std::sync::Mutex;

use anyhow::{Context, Result};
use hypersync_client::simple_types;
use hypersync_client_solana::simple_types as solana_simple;
use napi_derive::napi;
use strum::VariantArray;

use crate::chunk_store::{
    bytes_cells, fixed_from, hash_list_cells, hash_list_from, hex_full, hex_quantity, i64_cells,
    i64_from, u64_cells, u64_from, utf8, var_from, AnyCol, Chunk, ChunkStore,
};
use crate::evm_hypersync_source::map_err;
use crate::evm_hypersync_source::types::{encode_address, map_bigint, map_i64};
use crate::field_columns::{build_columns, bytes, field_names, Column, Columns, Ecosystem};

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

/// Build one EVM field's column from a response's blocks. `None` for the
/// key-derived `number` and for fields no block carries. Exhaustive match:
/// adding an `EvmBlockField` variant fails to compile until it is filled here
/// and decoded below.
fn evm_block_col(field: EvmBlockField, blocks: &[simple_types::Block]) -> Option<AnyCol> {
    use EvmBlockField::*;
    match field {
        // The block number is the chunk key, not a column.
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
        // The slot is the chunk key, not a column.
        Slot => None,
        Time => i64_from(blocks, |b| b.block_time),
        Hash => var_from(blocks, |b| Some(b.blockhash.as_bytes())),
        Height => u64_from(blocks, |b| b.block_height),
        ParentSlot => u64_from(blocks, |b| b.parent_slot),
        ParentHash => var_from(blocks, |b| {
            b.parent_blockhash.as_ref().map(|s| s.as_bytes())
        }),
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
        Hash | ParentHash => Column::Str(bytes_cells(col, len, |b| Ok(Some(utf8(b))))?),
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

#[napi]
pub struct BlockStore {
    inner: Mutex<ChunkStore<u64>>,
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

    /// Move every chunk from `page` into this store (merging a fetch-response
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
        dst.append_from(&mut src);
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
            Err(_) => inner.clear(),
        }
    }
}

impl BlockStore {
    fn with_ecosystem(ecosystem: Ecosystem) -> Self {
        let n_fields = match ecosystem {
            Ecosystem::Evm { .. } => EvmBlockField::VARIANTS.len(),
            Ecosystem::Svm => SvmBlockField::VARIANTS.len(),
            Ecosystem::Fuel => 0,
        };
        Self {
            inner: Mutex::new(ChunkStore::new(n_fields, true)),
            ecosystem,
        }
    }

    fn gather(&self, block_numbers: &[i64], masks: &[u64]) -> Vec<Option<AnyCol>> {
        let keys: Vec<Option<u64>> = block_numbers
            .iter()
            .map(|&n| u64::try_from(n).ok())
            .collect();
        self.inner.lock().unwrap().gather_scratch(&keys, masks)
    }

    /// Add one response's EVM blocks as a chunk (called by the HyperSync source
    /// while building a page). One block per number, so overlapping partition
    /// re-fetches simply resolve newest-first at read. Not exposed to JS.
    pub(crate) fn insert_evm_blocks(&self, mut blocks: Vec<simple_types::Block>) {
        blocks.retain(|b| b.number.is_some());
        if blocks.is_empty() {
            return;
        }
        blocks.sort_unstable_by_key(|b| b.number.unwrap());
        let keys = blocks.iter().map(|b| b.number.unwrap()).collect();
        let cols = EvmBlockField::VARIANTS
            .iter()
            .map(|&f| evm_block_col(f, &blocks))
            .collect();
        self.inner
            .lock()
            .unwrap()
            .push_chunk(Chunk::new(keys, cols));
    }

    /// Add one response's SVM blocks as a chunk, keyed by slot. Not exposed to JS.
    pub(crate) fn insert_svm_blocks(&self, mut blocks: Vec<solana_simple::Block>) {
        if blocks.is_empty() {
            return;
        }
        blocks.sort_unstable_by_key(|b| b.slot);
        let keys = blocks.iter().map(|b| b.slot).collect();
        let cols = SvmBlockField::VARIANTS
            .iter()
            .map(|&f| svm_block_col(f, &blocks))
            .collect();
        self.inner
            .lock()
            .unwrap()
            .push_chunk(Chunk::new(keys, cols));
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
        // extra field, all decoded from the one stored chunk.
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
    async fn field_union_across_chunks_resolves_both_fields() {
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
        store.prune(10);
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
        persistent.merge(&page1);

        let page2 = BlockStore::new_evm(false);
        let mut second = raw_evm_block(20);
        second.timestamp = Some(Quantity::from(200u64));
        page2.insert_evm_blocks(vec![second]);
        persistent.merge(&page2);

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
    }
}
