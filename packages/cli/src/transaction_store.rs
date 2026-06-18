//! Per-chain transaction store shared across ecosystems. Transactions are kept
//! as raw upstream structs (their large fields, e.g. EVM `input`, never cross
//! the napi boundary until a handler actually reads them) and materialised one
//! field at a time on demand. The store lives on the ReScript `ChainState`;
//! fetch responses are merged in, and entries are pruned/rolled back by block.

use std::collections::BTreeMap;
use std::sync::Mutex;

use anyhow::Result;
use hypersync_client::format::Hex;
use hypersync_client::simple_types;
use napi::bindgen_prelude::{BigInt, ToNapiValue};
use napi_derive::napi;

use crate::evm_hypersync_source::types::{
    map_address_string, map_bigint, map_hex_string, AccessList as AccessListItem,
    Authorization as AuthorizationItem,
};

/// A single transaction field materialised on demand. Variants cover exactly the
/// shapes the public EVM transaction exposes; `serde`-free so big integers keep
/// full precision across the boundary.
pub enum FieldValue {
    Str(String),
    Int(i64),
    Float(f64),
    Big(BigInt),
    StrVec(Vec<String>),
    AccessList(Vec<AccessListItem>),
    AuthList(Vec<AuthorizationItem>),
}

impl ToNapiValue for FieldValue {
    unsafe fn to_napi_value(
        env: napi::sys::napi_env,
        val: Self,
    ) -> napi::Result<napi::sys::napi_value> {
        match val {
            FieldValue::Str(v) => String::to_napi_value(env, v),
            FieldValue::Int(v) => i64::to_napi_value(env, v),
            FieldValue::Float(v) => f64::to_napi_value(env, v),
            FieldValue::Big(v) => BigInt::to_napi_value(env, v),
            FieldValue::StrVec(v) => Vec::<String>::to_napi_value(env, v),
            FieldValue::AccessList(v) => Vec::<AccessListItem>::to_napi_value(env, v),
            FieldValue::AuthList(v) => Vec::<AuthorizationItem>::to_napi_value(env, v),
        }
    }
}

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

    pub fn from_i32(code: i32) -> Option<EvmTxField> {
        EvmTxField::ALL.get(code as usize).copied()
    }

    /// The JS property name. Must match `Evm.res` `transactionFields`.
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

fn evm_get_field(
    tx: &simple_types::Transaction,
    field: EvmTxField,
    checksum: bool,
) -> Result<Option<FieldValue>> {
    use EvmTxField::*;
    Ok(match field {
        TransactionIndex => tx
            .transaction_index
            .map(|n| i64::try_from(u64::from(n)))
            .transpose()?
            .map(FieldValue::Int),
        Hash => map_hex_string(&tx.hash).map(FieldValue::Str),
        From => map_address_string(&tx.from, checksum).map(FieldValue::Str),
        To => map_address_string(&tx.to, checksum).map(FieldValue::Str),
        Gas => map_bigint(&tx.gas).map(FieldValue::Big),
        GasPrice => map_bigint(&tx.gas_price).map(FieldValue::Big),
        MaxPriorityFeePerGas => map_bigint(&tx.max_priority_fee_per_gas).map(FieldValue::Big),
        MaxFeePerGas => map_bigint(&tx.max_fee_per_gas).map(FieldValue::Big),
        CumulativeGasUsed => map_bigint(&tx.cumulative_gas_used).map(FieldValue::Big),
        EffectiveGasPrice => map_bigint(&tx.effective_gas_price).map(FieldValue::Big),
        GasUsed => map_bigint(&tx.gas_used).map(FieldValue::Big),
        Input => map_hex_string(&tx.input).map(FieldValue::Str),
        Nonce => map_bigint(&tx.nonce).map(FieldValue::Big),
        Value => map_bigint(&tx.value).map(FieldValue::Big),
        V => map_hex_string(&tx.v).map(FieldValue::Str),
        R => map_hex_string(&tx.r).map(FieldValue::Str),
        S => map_hex_string(&tx.s).map(FieldValue::Str),
        ContractAddress => map_address_string(&tx.contract_address, checksum).map(FieldValue::Str),
        LogsBloom => map_hex_string(&tx.logs_bloom).map(FieldValue::Str),
        Root => map_hex_string(&tx.root).map(FieldValue::Str),
        Status => tx.status.map(|v| FieldValue::Int(v.to_u8() as i64)),
        YParity => map_hex_string(&tx.y_parity).map(FieldValue::Str),
        ChainId => tx
            .chain_id
            .as_ref()
            .map(|n| i64::try_from(ruint::aliases::U256::from_be_slice(n)))
            .transpose()?
            .map(FieldValue::Int),
        MaxFeePerBlobGas => map_bigint(&tx.max_fee_per_blob_gas).map(FieldValue::Big),
        BlobVersionedHashes => tx
            .blob_versioned_hashes
            .as_ref()
            .map(|arr| FieldValue::StrVec(arr.iter().map(|h| h.encode_hex()).collect())),
        Type => tx.type_.map(|v| FieldValue::Int(u8::from(v) as i64)),
        L1Fee => map_bigint(&tx.l1_fee).map(FieldValue::Big),
        L1GasPrice => map_bigint(&tx.l1_gas_price).map(FieldValue::Big),
        L1GasUsed => map_bigint(&tx.l1_gas_used).map(FieldValue::Big),
        L1FeeScalar => tx.l1_fee_scalar.map(FieldValue::Float),
        GasUsedForL1 => map_bigint(&tx.gas_used_for_l1).map(FieldValue::Big),
        AccessList => tx
            .access_list
            .as_ref()
            .map(|arr| FieldValue::AccessList(arr.iter().map(AccessListItem::from).collect())),
        AuthorizationList => tx
            .authorization_list
            .as_ref()
            .map(|al| {
                al.iter()
                    .map(AuthorizationItem::try_from)
                    .collect::<Result<Vec<_>>>()
                    .map(FieldValue::AuthList)
            })
            .transpose()?,
    })
}

/// One stored transaction, kept in its ecosystem's compact form. More variants
/// (SVM raw, pre-built JS for RPC/Fuel/Simulate) are added as those sources are
/// wired in.
enum StoredTx {
    EvmRaw {
        tx: simple_types::Transaction,
        checksum: bool,
    },
}

impl StoredTx {
    fn get_field(&self, field: i32) -> Result<Option<FieldValue>> {
        match self {
            StoredTx::EvmRaw { tx, checksum } => match EvmTxField::from_i32(field) {
                Some(f) => evm_get_field(tx, f, *checksum),
                None => Ok(None),
            },
        }
    }
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
    #[napi(constructor)]
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

    /// Materialise a single field of one transaction. Returns `None` when the
    /// transaction or the field is absent (e.g. the field wasn't selected).
    #[napi]
    pub fn get_transaction_field(
        &self,
        block_number: i64,
        transaction_id: String,
        field: i32,
    ) -> napi::Result<Option<FieldValue>> {
        let inner = self.inner.lock().unwrap();
        let block = match u64::try_from(block_number) {
            Ok(b) => b,
            Err(_) => return Ok(None),
        };
        match inner.get(&block).and_then(|txs| txs.get(&transaction_id)) {
            Some(stored) => stored
                .get_field(field)
                .map_err(crate::evm_hypersync_source::map_err),
            None => Ok(None),
        }
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
        tx: simple_types::Transaction,
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
    fn field_codes_match_names_in_order() {
        for (idx, field) in EvmTxField::ALL.iter().enumerate() {
            assert_eq!(EvmTxField::from_i32(idx as i32), Some(*field));
        }
        assert_eq!(EvmTxField::from_i32(EvmTxField::ALL.len() as i32), None);
        assert_eq!(EvmTxField::Input.name(), "input");
    }

    #[test]
    fn store_returns_requested_field_only() {
        let store = TransactionStore::new();
        store.insert_evm_raw(100, "3".to_string(), raw_tx(), false);

        match store
            .get_transaction_field(100, "3".to_string(), EvmTxField::Input as i32)
            .unwrap()
        {
            Some(FieldValue::Str(s)) => assert_eq!(s, "0xabcd"),
            other => panic!("expected input string, got {:?}", other.is_some()),
        }

        // Missing block / tx / unselected field all resolve to None.
        assert!(store
            .get_transaction_field(999, "3".to_string(), EvmTxField::Input as i32)
            .unwrap()
            .is_none());
        assert!(store
            .get_transaction_field(100, "0".to_string(), EvmTxField::Input as i32)
            .unwrap()
            .is_none());
        assert!(store
            .get_transaction_field(100, "3".to_string(), EvmTxField::Gas as i32)
            .unwrap()
            .is_none());
    }

    #[test]
    fn prune_and_rollback_drop_by_block() {
        let store = TransactionStore::new();
        store.insert_evm_raw(
            10,
            "0".to_string(),
            simple_types::Transaction::default(),
            false,
        );
        store.insert_evm_raw(
            20,
            "0".to_string(),
            simple_types::Transaction::default(),
            false,
        );
        store.insert_evm_raw(
            30,
            "0".to_string(),
            simple_types::Transaction::default(),
            false,
        );

        store.prune(10);
        assert!(store
            .get_transaction_field(10, "0".to_string(), EvmTxField::Hash as i32)
            .unwrap()
            .is_none());

        store.rollback(20);
        // Block 30 dropped by rollback; block 20 survives (no hash set → None).
        assert_eq!(store.inner.lock().unwrap().len(), 1);
        assert!(store.inner.lock().unwrap().contains_key(&20));
    }
}
