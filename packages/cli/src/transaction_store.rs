//! Per-chain transaction store shared across ecosystems. Transactions are kept
//! as raw upstream structs (their large fields, e.g. EVM `input`, never cross
//! the napi boundary until they are read). At batch preparation the fields a
//! chain's config selected are decoded in bulk, off the JS thread, into a
//! columnar form; the main thread then zips the columns into plain JS objects,
//! setting only the selected fields. The store lives on the ReScript
//! `ChainState`; fetch responses are merged in, and entries are pruned/rolled
//! back by block.

use std::collections::{BTreeMap, HashMap};
use std::ffi::{CStr, CString};
use std::sync::{Arc, Mutex};

use anyhow::Result;
use hypersync_client::format::Hex;
use hypersync_client::simple_types;
use hypersync_client_solana::simple_types as solana_simple;
use napi::bindgen_prelude::{BigInt, ToNapiValue};
use napi::sys;
use napi_derive::napi;

use crate::evm_hypersync_source::map_err;
use crate::evm_hypersync_source::types::{
    map_address_string, map_bigint, map_hex_string, AccessList as AccessListItem,
    Authorization as AuthorizationItem,
};

fn bigint_u64(v: u64) -> BigInt {
    BigInt {
        sign_bit: false,
        words: vec![v],
    }
}

/// Transaction field codes shared with ReScript by ordinal value. The order is
/// the contract: it mirrors `Evm.res` `transactionFields`, and the ordinal is
/// the bit position in the selection mask. Keep the two in sync — guarded by a
/// test.
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

    /// JS property name; must match `Evm.res` `transactionFields`. Used as the
    /// object key when zipping columns into JS objects.
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

/// SVM transaction field codes, mirroring `Svm.res` `transactionFields` by
/// ordinal (the bit position in the selection mask). Keep the two in sync.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(i32)]
pub enum SvmTxField {
    Signatures = 0,
    FeePayer = 1,
    Success = 2,
    Err = 3,
    Fee = 4,
    ComputeUnitsConsumed = 5,
    AccountKeys = 6,
    RecentBlockhash = 7,
    Version = 8,
    TokenBalances = 9,
}

impl SvmTxField {
    #[allow(dead_code)]
    pub const ALL: [SvmTxField; 10] = [
        SvmTxField::Signatures,
        SvmTxField::FeePayer,
        SvmTxField::Success,
        SvmTxField::Err,
        SvmTxField::Fee,
        SvmTxField::ComputeUnitsConsumed,
        SvmTxField::AccountKeys,
        SvmTxField::RecentBlockhash,
        SvmTxField::Version,
        SvmTxField::TokenBalances,
    ];

    #[allow(dead_code)]
    pub fn from_i32(code: i32) -> Option<SvmTxField> {
        SvmTxField::ALL.get(code as usize).copied()
    }

    /// JS property name; must match `Svm.res` `transactionFields`.
    pub fn name(self) -> &'static str {
        use SvmTxField::*;
        match self {
            Signatures => "signatures",
            FeePayer => "feePayer",
            Success => "success",
            Err => "err",
            Fee => "fee",
            ComputeUnitsConsumed => "computeUnitsConsumed",
            AccountKeys => "accountKeys",
            RecentBlockhash => "recentBlockhash",
            Version => "version",
            TokenBalances => "tokenBalances",
        }
    }
}

/// The materialised SVM token balance, matching the public `svmTokenBalance`
/// shape (napi camel-cases the field names).
#[napi(object)]
#[derive(Clone)]
pub struct SvmTokenBalanceOut {
    pub account: Option<String>,
    pub mint: Option<String>,
    pub owner: Option<String>,
    pub pre_amount: Option<String>,
    pub post_amount: Option<String>,
}

/// One materialised field across all rows: struct-of-arrays, one entry per row,
/// `None` where the row is missing or the value is absent. The cell type is
/// concrete per column (no per-cell sum type); every variant's element type is
/// `Send` and `ToNapiValue`, so decode runs off-thread and only the object zip
/// touches the JS thread. New ecosystems extend the type set as needed.
enum Column {
    I64(Vec<Option<i64>>),
    F64(Vec<Option<f64>>),
    Bool(Vec<Option<bool>>),
    Big(Vec<Option<BigInt>>),
    Str(Vec<Option<String>>),
    StrVec(Vec<Option<Vec<String>>>),
    AccessList(Vec<Option<Vec<AccessListItem>>>),
    AuthList(Vec<Option<Vec<AuthorizationItem>>>),
    TokenBalances(Vec<Option<Vec<SvmTokenBalanceOut>>>),
}

impl Column {
    /// Set this column's value on each object under `key`, skipping `None` cells
    /// so unselected/absent fields stay absent on the JS object.
    unsafe fn set_on(
        self,
        env: sys::napi_env,
        objs: &[sys::napi_value],
        key: &CStr,
    ) -> napi::Result<()> {
        match self {
            Column::I64(v) => set_col(env, objs, key, v),
            Column::F64(v) => set_col(env, objs, key, v),
            Column::Bool(v) => set_col(env, objs, key, v),
            Column::Big(v) => set_col(env, objs, key, v),
            Column::Str(v) => set_col(env, objs, key, v),
            Column::StrVec(v) => set_col(env, objs, key, v),
            Column::AccessList(v) => set_col(env, objs, key, v),
            Column::AuthList(v) => set_col(env, objs, key, v),
            Column::TokenBalances(v) => set_col(env, objs, key, v),
        }
    }
}

unsafe fn set_col<T: ToNapiValue>(
    env: sys::napi_env,
    objs: &[sys::napi_value],
    key: &CStr,
    values: Vec<Option<T>>,
) -> napi::Result<()> {
    for (obj, cell) in objs.iter().zip(values) {
        if let Some(v) = cell {
            let js = T::to_napi_value(env, v)?;
            if sys::napi_set_named_property(env, *obj, key.as_ptr(), js) != sys::Status::napi_ok {
                return Err(napi::Error::from_reason("napi_set_named_property failed"));
            }
        }
    }
    Ok(())
}

/// A page of materialised transactions in columnar form. `ToNapiValue` zips it
/// into a JS array of objects on the main thread; each object carries only the
/// selected fields.
pub struct Columns {
    len: usize,
    columns: Vec<(&'static str, Column)>,
}

impl ToNapiValue for Columns {
    unsafe fn to_napi_value(env: sys::napi_env, val: Self) -> napi::Result<sys::napi_value> {
        let mut arr = std::ptr::null_mut();
        if sys::napi_create_array_with_length(env, val.len, &mut arr) != sys::Status::napi_ok {
            return Err(napi::Error::from_reason(
                "napi_create_array_with_length failed",
            ));
        }

        let mut objs = Vec::with_capacity(val.len);
        for _ in 0..val.len {
            let mut obj = std::ptr::null_mut();
            if sys::napi_create_object(env, &mut obj) != sys::Status::napi_ok {
                return Err(napi::Error::from_reason("napi_create_object failed"));
            }
            objs.push(obj);
        }

        for (name, col) in val.columns {
            let key =
                CString::new(name).map_err(|_| napi::Error::from_reason("invalid field name"))?;
            col.set_on(env, &objs, &key)?;
        }

        for (i, obj) in objs.iter().enumerate() {
            if sys::napi_set_element(env, arr, i as u32, *obj) != sys::Status::napi_ok {
                return Err(napi::Error::from_reason("napi_set_element failed"));
            }
        }

        Ok(arr)
    }
}

/// Build one column by extracting a field from each record. `None` rows (a key
/// missing from the store) yield `None` cells.
fn fill<T>(
    records: &[Option<(Arc<simple_types::Transaction>, bool)>],
    extract: impl Fn(&simple_types::Transaction, bool) -> Result<Option<T>>,
) -> Result<Vec<Option<T>>> {
    records
        .iter()
        .map(|rec| match rec {
            Some((tx, cs)) => extract(tx.as_ref(), *cs),
            None => Ok(None),
        })
        .collect()
}

/// Decode the mask-selected fields of the given EVM transactions into columns.
/// Large fields (e.g. `input`) are only touched when their bit is set, and the
/// whole thing runs off the JS thread.
fn decode_evm_columns(
    records: &[Option<(Arc<simple_types::Transaction>, bool)>],
    mask: u64,
) -> Result<Columns> {
    let len = records.len();
    let has = |f: EvmTxField| mask & (1u64 << (f as u32)) != 0;
    let mut columns: Vec<(&'static str, Column)> = Vec::new();

    use EvmTxField::*;

    macro_rules! col {
        ($field:expr, $variant:ident, $extract:expr) => {{
            if has($field) {
                columns.push(($field.name(), Column::$variant(fill(records, $extract)?)));
            }
        }};
    }

    col!(TransactionIndex, I64, |tx, _| Ok(tx
        .transaction_index
        .map(|n| i64::try_from(u64::from(n)))
        .transpose()?));
    col!(Hash, Str, |tx, _| Ok(map_hex_string(&tx.hash)));
    col!(From, Str, |tx, cs| Ok(map_address_string(&tx.from, cs)));
    col!(To, Str, |tx, cs| Ok(map_address_string(&tx.to, cs)));
    col!(Gas, Big, |tx, _| Ok(map_bigint(&tx.gas)));
    col!(GasPrice, Big, |tx, _| Ok(map_bigint(&tx.gas_price)));
    col!(MaxPriorityFeePerGas, Big, |tx, _| Ok(map_bigint(
        &tx.max_priority_fee_per_gas
    )));
    col!(MaxFeePerGas, Big, |tx, _| Ok(map_bigint(
        &tx.max_fee_per_gas
    )));
    col!(CumulativeGasUsed, Big, |tx, _| Ok(map_bigint(
        &tx.cumulative_gas_used
    )));
    col!(EffectiveGasPrice, Big, |tx, _| Ok(map_bigint(
        &tx.effective_gas_price
    )));
    col!(GasUsed, Big, |tx, _| Ok(map_bigint(&tx.gas_used)));
    col!(Input, Str, |tx, _| Ok(map_hex_string(&tx.input)));
    col!(Nonce, Big, |tx, _| Ok(map_bigint(&tx.nonce)));
    col!(Value, Big, |tx, _| Ok(map_bigint(&tx.value)));
    col!(V, Str, |tx, _| Ok(map_hex_string(&tx.v)));
    col!(R, Str, |tx, _| Ok(map_hex_string(&tx.r)));
    col!(S, Str, |tx, _| Ok(map_hex_string(&tx.s)));
    col!(ContractAddress, Str, |tx, cs| Ok(map_address_string(
        &tx.contract_address,
        cs
    )));
    col!(LogsBloom, Str, |tx, _| Ok(map_hex_string(&tx.logs_bloom)));
    col!(Root, Str, |tx, _| Ok(map_hex_string(&tx.root)));
    col!(Status, I64, |tx, _| Ok(tx.status.map(|v| v.to_u8() as i64)));
    col!(YParity, Str, |tx, _| Ok(map_hex_string(&tx.y_parity)));
    col!(ChainId, I64, |tx, _| Ok(tx
        .chain_id
        .as_ref()
        .map(|n| i64::try_from(ruint::aliases::U256::from_be_slice(n)))
        .transpose()?));
    col!(MaxFeePerBlobGas, Big, |tx, _| Ok(map_bigint(
        &tx.max_fee_per_blob_gas
    )));
    col!(BlobVersionedHashes, StrVec, |tx, _| Ok(tx
        .blob_versioned_hashes
        .as_ref()
        .map(|arr| arr.iter().map(|h| h.encode_hex()).collect())));
    col!(Type, I64, |tx, _| Ok(tx.type_.map(|v| u8::from(v) as i64)));
    col!(L1Fee, Big, |tx, _| Ok(map_bigint(&tx.l1_fee)));
    col!(L1GasPrice, Big, |tx, _| Ok(map_bigint(&tx.l1_gas_price)));
    col!(L1GasUsed, Big, |tx, _| Ok(map_bigint(&tx.l1_gas_used)));
    col!(L1FeeScalar, F64, |tx, _| Ok(tx.l1_fee_scalar));
    col!(GasUsedForL1, Big, |tx, _| Ok(map_bigint(
        &tx.gas_used_for_l1
    )));
    col!(AccessList, AccessList, |tx, _| Ok(tx
        .access_list
        .as_ref()
        .map(|arr| arr.iter().map(AccessListItem::from).collect())));
    col!(AuthorizationList, AuthList, |tx, _| tx
        .authorization_list
        .as_ref()
        .map(|al| al
            .iter()
            .map(AuthorizationItem::try_from)
            .collect::<Result<_>>())
        .transpose());

    Ok(Columns { len, columns })
}

/// A stored SVM transaction: the raw upstream transaction plus the token
/// balances joined to it (a separate upstream table, materialised as one field).
pub struct SvmStored {
    tx: solana_simple::Transaction,
    token_balances: Vec<solana_simple::TokenBalance>,
}

/// Build one SVM column by extracting a field from each record.
fn fill_svm<T>(
    records: &[Option<Arc<SvmStored>>],
    extract: impl Fn(&SvmStored) -> Option<T>,
) -> Vec<Option<T>> {
    records
        .iter()
        .map(|rec| rec.as_ref().and_then(|r| extract(r)))
        .collect()
}

/// Decode the mask-selected fields of the given SVM transactions into columns.
/// Large fields (e.g. `accountKeys`) are only cloned when their bit is set.
fn decode_svm_columns(records: &[Option<Arc<SvmStored>>], mask: u64) -> Columns {
    let len = records.len();
    let has = |f: SvmTxField| mask & (1u64 << (f as u32)) != 0;
    let mut columns: Vec<(&'static str, Column)> = Vec::new();

    use SvmTxField::*;

    macro_rules! col {
        ($field:expr, $variant:ident, $extract:expr) => {{
            if has($field) {
                columns.push(($field.name(), Column::$variant(fill_svm(records, $extract))));
            }
        }};
    }

    col!(Signatures, StrVec, |r| Some(r.tx.signatures.clone()));
    col!(FeePayer, Str, |r| r.tx.fee_payer.clone());
    col!(Success, Bool, |r| r.tx.success);
    col!(Err, Str, |r| r.tx.err.clone());
    col!(Fee, Big, |r| r.tx.fee.map(bigint_u64));
    col!(ComputeUnitsConsumed, Big, |r| r
        .tx
        .compute_units_consumed
        .map(bigint_u64));
    col!(AccountKeys, StrVec, |r| Some(r.tx.account_keys.clone()));
    col!(RecentBlockhash, Str, |r| r.tx.recent_blockhash.clone());
    col!(Version, Str, |r| r.tx.version.clone());
    col!(TokenBalances, TokenBalances, |r| Some(
        r.token_balances
            .iter()
            .map(|tb| SvmTokenBalanceOut {
                account: tb.account.clone(),
                mint: tb.mint.clone(),
                owner: tb.owner.clone(),
                pre_amount: tb.pre_amount.clone(),
                post_amount: tb.post_amount.clone(),
            })
            .collect()
    ));

    Columns { len, columns }
}

/// One stored transaction, kept in its ecosystem's compact raw form.
enum StoredTx {
    /// HyperSync: raw upstream transaction, selected fields decoded at batch prep.
    EvmRaw {
        tx: Arc<simple_types::Transaction>,
        checksum: bool,
    },
    /// SVM HyperSync: raw upstream transaction (+ joined token balances).
    Svm { rec: Arc<SvmStored> },
}

/// A per-block bucket. Generic so the block-keyed container below can host other
/// record types later (e.g. one block per block number) without change.
trait Bucket: Default {
    fn absorb(&mut self, other: Self);
}

/// Transactions for one block, keyed by the numeric transaction index.
#[derive(Default)]
struct TxBucket(HashMap<u32, StoredTx>);

impl Bucket for TxBucket {
    fn absorb(&mut self, other: Self) {
        self.0.extend(other.0);
    }
}

/// Block-keyed container: `blockNumber -> bucket`. The outer `BTreeMap` makes
/// prune and rollback cheap range operations; the bucket shape varies by record
/// type (transactions now; blocks could reuse this with a single-record bucket).
struct BlockKeyed<B> {
    map: BTreeMap<u64, B>,
}

impl<B: Bucket> BlockKeyed<B> {
    fn new() -> Self {
        Self {
            map: BTreeMap::new(),
        }
    }

    /// Drain every entry from `self` into `dst` (merging buckets per block).
    fn drain_into(&mut self, dst: &mut Self) {
        for (block, bucket) in std::mem::take(&mut self.map) {
            dst.map.entry(block).or_default().absorb(bucket);
        }
    }

    /// Drop blocks at or below `up_to` (already processed).
    fn prune(&mut self, up_to: u64) {
        self.map = self.map.split_off(&(up_to + 1));
    }

    /// Drop blocks above `target` (rolled back).
    fn rollback(&mut self, target: u64) {
        self.map.split_off(&(target + 1));
    }
}

#[napi]
pub struct TransactionStore {
    inner: Mutex<BlockKeyed<TxBucket>>,
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
            inner: Mutex::new(BlockKeyed::new()),
        }
    }

    /// Move every entry from `page` into this store (merging a fetch-response
    /// page into the persistent per-chain store).
    #[napi]
    pub fn merge(&self, page: &TransactionStore) {
        let mut dst = self.inner.lock().unwrap();
        let mut src = page.inner.lock().unwrap();
        src.drain_into(&mut dst);
    }

    /// Bulk-materialise the selected fields (one bit per `EvmTxField` code in
    /// `mask`) of the given transactions, returned in columnar form. The mask is
    /// a JS number (`f64`): its exact-integer range (2^53) dwarfs the field
    /// count, and the ReScript side builds it arithmetically to dodge 32-bit JS
    /// bitwise ops. Async so the decode runs off the JS thread; the brief lock
    /// only collects `Arc`s. Missing keys yield an empty object. Result is
    /// aligned with the input.
    #[napi(ts_return_type = "Promise<object[]>")]
    pub async fn materialize(
        &self,
        block_numbers: Vec<i64>,
        transaction_indices: Vec<u32>,
        mask: f64,
    ) -> napi::Result<Columns> {
        let mask = mask as u64;

        // A store is per-chain, hence single-ecosystem; pick the decoder from the
        // first stored record and collect the matching raw refs under the lock.
        enum Plan {
            Evm(Vec<Option<(Arc<simple_types::Transaction>, bool)>>),
            Svm(Vec<Option<Arc<SvmStored>>>),
        }

        let plan = {
            let inner = self.inner.lock().unwrap();
            let is_svm = inner
                .map
                .values()
                .flat_map(|b| b.0.values())
                .next()
                .is_some_and(|tx| matches!(tx, StoredTx::Svm { .. }));

            if is_svm {
                Plan::Svm(
                    block_numbers
                        .iter()
                        .zip(transaction_indices.iter())
                        .map(|(block, idx)| {
                            let block = u64::try_from(*block).ok()?;
                            match inner.map.get(&block).and_then(|b| b.0.get(idx)) {
                                Some(StoredTx::Svm { rec }) => Some(rec.clone()),
                                _ => None,
                            }
                        })
                        .collect(),
                )
            } else {
                Plan::Evm(
                    block_numbers
                        .iter()
                        .zip(transaction_indices.iter())
                        .map(|(block, idx)| {
                            let block = u64::try_from(*block).ok()?;
                            match inner.map.get(&block).and_then(|b| b.0.get(idx)) {
                                Some(StoredTx::EvmRaw { tx, checksum }) => {
                                    Some((tx.clone(), *checksum))
                                }
                                _ => None,
                            }
                        })
                        .collect(),
                )
            }
        };

        match plan {
            Plan::Evm(records) => decode_evm_columns(&records, mask).map_err(map_err),
            Plan::Svm(records) => Ok(decode_svm_columns(&records, mask)),
        }
    }

    /// Drop transactions for blocks at or below `up_to_block` (already processed).
    #[napi]
    pub fn prune(&self, up_to_block: i64) {
        if let Ok(up_to) = u64::try_from(up_to_block) {
            self.inner.lock().unwrap().prune(up_to);
        }
    }

    /// Drop transactions for blocks above `target_block` (rolled back).
    #[napi]
    pub fn rollback(&self, target_block: i64) {
        let mut inner = self.inner.lock().unwrap();
        match u64::try_from(target_block) {
            Ok(target) => inner.rollback(target),
            Err(_) => inner.map.clear(),
        }
    }
}

impl TransactionStore {
    /// Insert a raw EVM transaction (called by the HyperSync source while
    /// building a page). Not exposed to JS.
    pub(crate) fn insert_evm_raw(
        &self,
        block_number: u64,
        transaction_index: u32,
        tx: Arc<simple_types::Transaction>,
        checksum: bool,
    ) {
        self.inner
            .lock()
            .unwrap()
            .map
            .entry(block_number)
            .or_default()
            .0
            .insert(transaction_index, StoredTx::EvmRaw { tx, checksum });
    }

    /// Insert a raw SVM transaction with its joined token balances (called by the
    /// SVM HyperSync source while building a page). Not exposed to JS.
    pub(crate) fn insert_svm_raw(&self, slot: u64, transaction_index: u32, rec: Arc<SvmStored>) {
        self.inner
            .lock()
            .unwrap()
            .map
            .entry(slot)
            .or_default()
            .0
            .insert(transaction_index, StoredTx::Svm { rec });
    }

    /// Build a stored SVM record from a raw transaction and its token balances.
    pub(crate) fn make_svm_stored(
        tx: solana_simple::Transaction,
        token_balances: Vec<solana_simple::TokenBalance>,
    ) -> SvmStored {
        SvmStored { tx, token_balances }
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

    fn column<'a>(cols: &'a Columns, name: &str) -> Option<&'a Column> {
        cols.columns
            .iter()
            .find(|(n, _)| *n == name)
            .map(|(_, c)| c)
    }

    #[test]
    fn decode_selected_only_materialises_masked_fields() {
        // Select only `input` via the bitmask.
        let mask = 1u64 << (EvmTxField::Input as u32);
        let cols =
            decode_evm_columns(&[Some((Arc::new(raw_tx()), false))], mask).expect("decode columns");

        // Exactly one column (input) is present; transactionIndex (present on the
        // raw tx but unselected) and gas are absent.
        match column(&cols, "input") {
            Some(Column::Str(v)) => assert_eq!(v, &vec![Some("0xabcd".to_string())]),
            other => panic!(
                "expected input string column, got present={}",
                other.is_some()
            ),
        }
        assert!(column(&cols, "transactionIndex").is_none());
        assert!(column(&cols, "gas").is_none());
    }

    #[test]
    fn field_codes_match_names_in_order() {
        for (idx, field) in EvmTxField::ALL.iter().enumerate() {
            assert_eq!(EvmTxField::from_i32(idx as i32), Some(*field));
        }
        assert_eq!(EvmTxField::from_i32(EvmTxField::ALL.len() as i32), None);
        assert_eq!(EvmTxField::Input.name(), "input");

        for (idx, field) in SvmTxField::ALL.iter().enumerate() {
            assert_eq!(SvmTxField::from_i32(idx as i32), Some(*field));
        }
        assert_eq!(SvmTxField::from_i32(SvmTxField::ALL.len() as i32), None);
        assert_eq!(SvmTxField::AccountKeys.name(), "accountKeys");
    }

    #[test]
    fn svm_decode_selected_only_materialises_masked_fields() {
        let tx = solana_simple::Transaction {
            account_keys: vec!["key1".to_string(), "key2".to_string()],
            fee: Some(5000),
            signatures: vec!["sig".to_string()],
            ..Default::default()
        };
        let rec = Arc::new(SvmStored {
            tx,
            token_balances: vec![],
        });

        // Select only accountKeys.
        let mask = 1u64 << (SvmTxField::AccountKeys as u32);
        let cols = decode_svm_columns(&[Some(rec)], mask);

        match column(&cols, "accountKeys") {
            Some(Column::StrVec(v)) => {
                assert_eq!(v, &vec![Some(vec!["key1".to_string(), "key2".to_string()])])
            }
            other => panic!(
                "expected accountKeys column, got present={}",
                other.is_some()
            ),
        }
        // fee and signatures are present on the raw tx but unselected.
        assert!(column(&cols, "fee").is_none());
        assert!(column(&cols, "signatures").is_none());
    }

    #[test]
    fn prune_and_rollback_drop_by_block() {
        let store = TransactionStore::new();
        for block in [10u64, 20, 30] {
            store.insert_evm_raw(
                block,
                0,
                Arc::new(simple_types::Transaction::default()),
                false,
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
}
