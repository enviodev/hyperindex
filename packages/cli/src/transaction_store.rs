//! Per-chain transaction store shared across ecosystems. Transactions are kept
//! as raw upstream structs (their large fields, e.g. EVM `input`, never cross
//! the napi boundary until they are read). At batch preparation the fields a
//! chain's config selected are materialised in bulk, off the JS thread. The
//! store lives on the ReScript `ChainState`; fetch responses are merged in, and
//! entries are pruned/rolled back by block.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use anyhow::Result;
use hypersync_client::format::Hex;
use hypersync_client::simple_types;
use napi_derive::napi;

use crate::evm_hypersync_source::types::{
    map_address_string, map_bigint, map_hex_string, AccessList as AccessListItem,
    Authorization as AuthorizationItem, Transaction as EvmReadyTx,
};

/// Transaction field codes shared with ReScript by ordinal value. The order is
/// the contract: it mirrors `Evm.res` `transactionFields`, which the ReScript
/// getter prototype indexes into. Keep the two in sync — guarded by a test.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(i32)]
pub enum EvmTxField {
    TransactionIndex = 0,
    Hash = 1,
    From = 2,
    To = 3,
    Gas = 4,
    GasPrice = 5,
    MaxPriorityFeePerGas = 6,
    MaxFeePerGas = 7,
    CumulativeGasUsed = 8,
    EffectiveGasPrice = 9,
    GasUsed = 10,
    Input = 11,
    Nonce = 12,
    Value = 13,
    V = 14,
    R = 15,
    S = 16,
    ContractAddress = 17,
    LogsBloom = 18,
    Root = 19,
    Status = 20,
    YParity = 21,
    ChainId = 22,
    MaxFeePerBlobGas = 23,
    BlobVersionedHashes = 24,
    Type = 25,
    L1Fee = 26,
    L1GasPrice = 27,
    L1GasUsed = 28,
    L1FeeScalar = 29,
    GasUsedForL1 = 30,
    AccessList = 31,
    AuthorizationList = 32,
}

impl EvmTxField {
    // Used by the ordinal-contract test; the lib build decodes via `as u32`.
    #[allow(dead_code)]
    pub const ALL: [EvmTxField; 33] = [
        EvmTxField::TransactionIndex,
        EvmTxField::Hash,
        EvmTxField::From,
        EvmTxField::To,
        EvmTxField::Gas,
        EvmTxField::GasPrice,
        EvmTxField::MaxPriorityFeePerGas,
        EvmTxField::MaxFeePerGas,
        EvmTxField::CumulativeGasUsed,
        EvmTxField::EffectiveGasPrice,
        EvmTxField::GasUsed,
        EvmTxField::Input,
        EvmTxField::Nonce,
        EvmTxField::Value,
        EvmTxField::V,
        EvmTxField::R,
        EvmTxField::S,
        EvmTxField::ContractAddress,
        EvmTxField::LogsBloom,
        EvmTxField::Root,
        EvmTxField::Status,
        EvmTxField::YParity,
        EvmTxField::ChainId,
        EvmTxField::MaxFeePerBlobGas,
        EvmTxField::BlobVersionedHashes,
        EvmTxField::Type,
        EvmTxField::L1Fee,
        EvmTxField::L1GasPrice,
        EvmTxField::L1GasUsed,
        EvmTxField::L1FeeScalar,
        EvmTxField::GasUsedForL1,
        EvmTxField::AccessList,
        EvmTxField::AuthorizationList,
    ];

    #[allow(dead_code)]
    pub fn from_i32(code: i32) -> Option<EvmTxField> {
        EvmTxField::ALL.get(code as usize).copied()
    }

    /// The JS property name. Must match `Evm.res` `transactionFields`. Used by
    /// the order-contract test; kept as the documented field↔name mapping.
    #[allow(dead_code)]
    pub fn name(self) -> &'static str {
        use EvmTxField::*;
        match self {
            TransactionIndex => "transactionIndex",
            Hash => "hash",
            From => "from",
            To => "to",
            Gas => "gas",
            GasPrice => "gasPrice",
            MaxPriorityFeePerGas => "maxPriorityFeePerGas",
            MaxFeePerGas => "maxFeePerGas",
            CumulativeGasUsed => "cumulativeGasUsed",
            EffectiveGasPrice => "effectiveGasPrice",
            GasUsed => "gasUsed",
            Input => "input",
            Nonce => "nonce",
            Value => "value",
            V => "v",
            R => "r",
            S => "s",
            ContractAddress => "contractAddress",
            LogsBloom => "logsBloom",
            Root => "root",
            Status => "status",
            YParity => "yParity",
            ChainId => "chainId",
            MaxFeePerBlobGas => "maxFeePerBlobGas",
            BlobVersionedHashes => "blobVersionedHashes",
            Type => "type",
            L1Fee => "l1Fee",
            L1GasPrice => "l1GasPrice",
            L1GasUsed => "l1GasUsed",
            L1FeeScalar => "l1FeeScalar",
            GasUsedForL1 => "gasUsedForL1",
            AccessList => "accessList",
            AuthorizationList => "authorizationList",
        }
    }
}

/// Decode the fields selected by `mask` (bit `code` ⇔ `EvmTxField`) into the
/// public `Transaction` shape. Unselected fields stay `None`, so large fields
/// like `input` are only decoded when their bit is set.
fn decode_selected_evm(
    tx: &simple_types::Transaction,
    mask: u64,
    checksum: bool,
) -> Result<EvmReadyTx> {
    let has = |f: EvmTxField| mask & (1u64 << (f as u32)) != 0;
    use EvmTxField::*;
    let mut out = EvmReadyTx::default();
    if has(TransactionIndex) {
        out.transaction_index = tx
            .transaction_index
            .map(|n| i64::try_from(u64::from(n)))
            .transpose()?;
    }
    if has(Hash) {
        out.hash = map_hex_string(&tx.hash);
    }
    if has(From) {
        out.from = map_address_string(&tx.from, checksum);
    }
    if has(To) {
        out.to = map_address_string(&tx.to, checksum);
    }
    if has(Gas) {
        out.gas = map_bigint(&tx.gas);
    }
    if has(GasPrice) {
        out.gas_price = map_bigint(&tx.gas_price);
    }
    if has(MaxPriorityFeePerGas) {
        out.max_priority_fee_per_gas = map_bigint(&tx.max_priority_fee_per_gas);
    }
    if has(MaxFeePerGas) {
        out.max_fee_per_gas = map_bigint(&tx.max_fee_per_gas);
    }
    if has(CumulativeGasUsed) {
        out.cumulative_gas_used = map_bigint(&tx.cumulative_gas_used);
    }
    if has(EffectiveGasPrice) {
        out.effective_gas_price = map_bigint(&tx.effective_gas_price);
    }
    if has(GasUsed) {
        out.gas_used = map_bigint(&tx.gas_used);
    }
    if has(Input) {
        out.input = map_hex_string(&tx.input);
    }
    if has(Nonce) {
        out.nonce = map_bigint(&tx.nonce);
    }
    if has(Value) {
        out.value = map_bigint(&tx.value);
    }
    if has(V) {
        out.v = map_hex_string(&tx.v);
    }
    if has(R) {
        out.r = map_hex_string(&tx.r);
    }
    if has(S) {
        out.s = map_hex_string(&tx.s);
    }
    if has(ContractAddress) {
        out.contract_address = map_address_string(&tx.contract_address, checksum);
    }
    if has(LogsBloom) {
        out.logs_bloom = map_hex_string(&tx.logs_bloom);
    }
    if has(Root) {
        out.root = map_hex_string(&tx.root);
    }
    if has(Status) {
        out.status = tx.status.map(|v| v.to_u8() as i64);
    }
    if has(YParity) {
        out.y_parity = map_hex_string(&tx.y_parity);
    }
    if has(ChainId) {
        out.chain_id = tx
            .chain_id
            .as_ref()
            .map(|n| i64::try_from(ruint::aliases::U256::from_be_slice(n)))
            .transpose()?;
    }
    if has(MaxFeePerBlobGas) {
        out.max_fee_per_blob_gas = map_bigint(&tx.max_fee_per_blob_gas);
    }
    if has(BlobVersionedHashes) {
        out.blob_versioned_hashes = tx
            .blob_versioned_hashes
            .as_ref()
            .map(|arr| arr.iter().map(|h| h.encode_hex()).collect());
    }
    if has(Type) {
        out.type_ = tx.type_.map(|v| u8::from(v) as i64);
    }
    if has(L1Fee) {
        out.l1_fee = map_bigint(&tx.l1_fee);
    }
    if has(L1GasPrice) {
        out.l1_gas_price = map_bigint(&tx.l1_gas_price);
    }
    if has(L1GasUsed) {
        out.l1_gas_used = map_bigint(&tx.l1_gas_used);
    }
    if has(L1FeeScalar) {
        out.l1_fee_scalar = tx.l1_fee_scalar;
    }
    if has(GasUsedForL1) {
        out.gas_used_for_l1 = map_bigint(&tx.gas_used_for_l1);
    }
    if has(AccessList) {
        out.access_list = tx
            .access_list
            .as_ref()
            .map(|arr| arr.iter().map(AccessListItem::from).collect());
    }
    if has(AuthorizationList) {
        out.authorization_list = tx
            .authorization_list
            .as_ref()
            .map(|al| {
                al.iter()
                    .map(AuthorizationItem::try_from)
                    .collect::<Result<_>>()
            })
            .transpose()?;
    }
    Ok(out)
}

/// One stored transaction, kept in its ecosystem's compact raw form. More
/// variants (e.g. SVM raw) are added as those sources move to the Rust store.
enum StoredTx {
    /// HyperSync: raw upstream transaction, selected fields decoded in bulk at
    /// batch prep.
    EvmRaw {
        tx: Arc<simple_types::Transaction>,
        checksum: bool,
    },
}

/// `blockNumber -> (transactionId -> tx)`. Block-keyed outer map so prune and
/// rollback are cheap range operations.
type Inner = BTreeMap<u64, std::collections::HashMap<String, StoredTx>>;

#[napi]
pub struct TransactionStore {
    inner: Mutex<Inner>,
}

impl Default for TransactionStore {
    fn default() -> Self {
        Self::new()
    }
}

#[napi]
impl TransactionStore {
    #[napi(factory)]
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(BTreeMap::new()),
        }
    }

    /// Move every entry from `page` into this store (used to merge a fetch
    /// response's page into the persistent per-chain store).
    #[napi]
    pub fn merge(&self, page: &TransactionStore) {
        let mut dst = self.inner.lock().unwrap();
        let mut src = page.inner.lock().unwrap();
        for (block, txs) in std::mem::take(&mut *src) {
            dst.entry(block).or_default().extend(txs);
        }
    }

    /// Bulk-materialise the selected fields (one bit per `EvmTxField` code in
    /// `mask`) of the given transactions. The mask is a JS number (`f64`): its
    /// exact-integer range (2^53) dwarfs the field count, and the ReScript side
    /// builds it arithmetically to dodge 32-bit JS bitwise ops. Async so the
    /// decode runs off the JS thread; the brief lock only collects `Arc`s, the
    /// decode happens unlocked. Missing keys yield an empty transaction. Result
    /// is aligned with the input.
    #[napi]
    pub async fn materialize(
        &self,
        block_numbers: Vec<i64>,
        transaction_ids: Vec<String>,
        mask: f64,
    ) -> napi::Result<Vec<EvmReadyTx>> {
        let mask = mask as u64;

        let collected: Vec<Option<(Arc<simple_types::Transaction>, bool)>> = {
            let inner = self.inner.lock().unwrap();
            block_numbers
                .iter()
                .zip(transaction_ids.iter())
                .map(|(block, id)| {
                    let block = u64::try_from(*block).ok()?;
                    match inner.get(&block).and_then(|txs| txs.get(id)) {
                        Some(StoredTx::EvmRaw { tx, checksum }) => Some((tx.clone(), *checksum)),
                        _ => None,
                    }
                })
                .collect()
        };

        let mut out = Vec::with_capacity(collected.len());
        for entry in collected {
            out.push(match entry {
                Some((tx, checksum)) => decode_selected_evm(&tx, mask, checksum)
                    .map_err(crate::evm_hypersync_source::map_err)?,
                None => EvmReadyTx::default(),
            });
        }
        Ok(out)
    }

    /// Drop transactions for blocks at or below `up_to_block` (already processed).
    #[napi]
    pub fn prune(&self, up_to_block: i64) {
        let mut inner = self.inner.lock().unwrap();
        if let Ok(up_to) = u64::try_from(up_to_block) {
            *inner = inner.split_off(&(up_to + 1));
        }
    }

    /// Drop transactions for blocks above `target_block` (rolled back).
    #[napi]
    pub fn rollback(&self, target_block: i64) {
        let mut inner = self.inner.lock().unwrap();
        if let Ok(target) = u64::try_from(target_block) {
            inner.split_off(&(target + 1));
        } else {
            inner.clear();
        }
    }
}

impl TransactionStore {
    /// Insert a raw EVM transaction (called by the HyperSync source while
    /// building a page). Not exposed to JS.
    pub(crate) fn insert_evm_raw(
        &self,
        block_number: u64,
        transaction_id: String,
        tx: Arc<simple_types::Transaction>,
        checksum: bool,
    ) {
        let mut inner = self.inner.lock().unwrap();
        inner
            .entry(block_number)
            .or_default()
            .insert(transaction_id, StoredTx::EvmRaw { tx, checksum });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw_tx() -> simple_types::Transaction {
        let mut tx = simple_types::Transaction::default();
        tx.transaction_index = Some(3u64.into());
        tx.input = Some(hypersync_client::format::Data::from(vec![0xab, 0xcd]));
        tx
    }

    #[test]
    fn decode_selected_only_materialises_masked_fields() {
        // Select only `input` via the bitmask.
        let mask = 1u64 << (EvmTxField::Input as u32);
        let out = decode_selected_evm(&raw_tx(), mask, false).unwrap();
        assert_eq!(out.input.as_deref(), Some("0xabcd"));
        // transactionIndex is present on the raw tx but not selected → stays None.
        assert!(out.transaction_index.is_none());
        assert!(out.gas.is_none());
    }

    #[test]
    fn field_codes_match_names_in_order() {
        for (idx, field) in EvmTxField::ALL.iter().enumerate() {
            assert_eq!(EvmTxField::from_i32(idx as i32), Some(*field));
        }
        assert_eq!(EvmTxField::from_i32(EvmTxField::ALL.len() as i32), None);
        assert_eq!(EvmTxField::Input.name(), "input");
    }

    #[test]
    fn prune_and_rollback_drop_by_block() {
        let store = TransactionStore::new();
        for block in [10u64, 20, 30] {
            store.insert_evm_raw(
                block,
                "0".to_string(),
                Arc::new(simple_types::Transaction::default()),
                false,
            );
        }

        store.prune(10);
        assert!(!store.inner.lock().unwrap().contains_key(&10));

        store.rollback(20);
        // Block 30 dropped by rollback; block 20 survives.
        assert_eq!(
            store
                .inner
                .lock()
                .unwrap()
                .keys()
                .copied()
                .collect::<Vec<_>>(),
            vec![20]
        );
    }
}
