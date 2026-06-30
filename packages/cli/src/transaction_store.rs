//! Per-chain transaction store shared across ecosystems. Transactions are kept
//! as raw upstream structs (their large fields, e.g. EVM `input`, never cross
//! the napi boundary until they are read). At batch preparation the fields a
//! chain's config selected are decoded in bulk, off the JS thread, into a
//! columnar form; the main thread then zips the columns into plain JS objects,
//! setting only the selected fields. The store lives on the ReScript
//! `ChainState`; fetch responses are merged in, and entries are pruned/rolled
//! back by block.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use hypersync_client::format::Hex;
use hypersync_client::simple_types;
use hypersync_client_solana::simple_types as solana_simple;
use napi::bindgen_prelude::{BigInt, ToNapiValue};
use napi::sys;
use napi_derive::napi;
use strum::VariantArray;

use crate::evm_hypersync_source::map_err;
use crate::evm_hypersync_source::types::{
    map_address_string, map_bigint, map_hex_string, AccessList as AccessListItem,
    Authorization as AuthorizationItem,
};
use crate::svm_hypersync_source::types::bigint_u64;

/// Transaction field codes shared with ReScript by ordinal value. The order is
/// the contract: it mirrors `Evm.res` `transactionFields`, and the ordinal is
/// the bit position in the selection mask. Keep the two in sync — guarded by a
/// test.
#[derive(Clone, Copy, PartialEq, Eq, Debug, VariantArray)]
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
    MaxFeePerBlobGas = 22,
    BlobVersionedHashes = 23,
    Type = 24,
    L1Fee = 25,
    L1GasPrice = 26,
    L1GasUsed = 27,
    L1FeeScalar = 28,
    GasUsedForL1 = 29,
    AccessList = 30,
    AuthorizationList = 31,
}

impl EvmTxField {
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
#[derive(Clone, Copy, PartialEq, Eq, Debug, VariantArray)]
#[repr(i32)]
pub enum SvmTxField {
    TransactionIndex = 0,
    Signatures = 1,
    FeePayer = 2,
    Success = 3,
    Err = 4,
    Fee = 5,
    ComputeUnitsConsumed = 6,
    AccountKeys = 7,
    RecentBlockhash = 8,
    Version = 9,
    TokenBalances = 10,
}

impl SvmTxField {
    /// JS property name; must match `Svm.res` `transactionFields`.
    pub fn name(self) -> &'static str {
        use SvmTxField::*;
        match self {
            TransactionIndex => "transactionIndex",
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
        key: sys::napi_value,
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
    key: sys::napi_value,
    values: Vec<Option<T>>,
) -> napi::Result<()> {
    for (obj, cell) in objs.iter().zip(values) {
        if let Some(v) = cell {
            let js = T::to_napi_value(env, v)?;
            if sys::napi_set_property(env, *obj, key, js) != sys::Status::napi_ok {
                return Err(napi::Error::from_reason("napi_set_property failed"));
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
            // Create the JS property-key string once per column and reuse it for
            // every row; `napi_set_named_property` would re-create it per cell.
            let mut key = std::ptr::null_mut();
            if sys::napi_create_string_utf8(
                env,
                name.as_ptr() as *const std::os::raw::c_char,
                name.len() as isize,
                &mut key,
            ) != sys::Status::napi_ok
            {
                return Err(napi::Error::from_reason("napi_create_string_utf8 failed"));
            }
            col.set_on(env, &objs, key)?;
        }

        for (i, obj) in objs.iter().enumerate() {
            if sys::napi_set_element(env, arr, i as u32, *obj) != sys::Status::napi_ok {
                return Err(napi::Error::from_reason("napi_set_element failed"));
            }
        }

        Ok(arr)
    }
}

/// Build one column by extracting a field from each record, but only for rows
/// whose per-row `mask` has `bit` set; every other row (or a key missing from
/// the store) yields a `None` cell. This is what lets a field be materialised on
/// exactly the rows that selected it, rather than on every row in the batch —
/// and it skips `extract` (e.g. hex-encoding a large `input`) on unselected rows.
fn fill_masked<R, T>(
    records: &[Option<Arc<R>>],
    masks: &[u64],
    bit: u64,
    extract: impl Fn(&R) -> Result<Option<T>>,
) -> Result<Vec<Option<T>>> {
    records
        .iter()
        .zip(masks)
        .map(|(rec, &m)| {
            if m & bit == 0 {
                return Ok(None);
            }
            match rec {
                Some(r) => extract(r.as_ref()),
                None => Ok(None),
            }
        })
        .collect()
}

/// Iterate an ecosystem's field variants and decode each whose mask bit is set,
/// collecting them into columns. Shared by both ecosystems; only the per-field
/// `decode` table differs. A decode error names the field so one bad row aborts
/// the batch's materialisation with an actionable message.
fn build_columns<F: Copy>(
    variants: &'static [F],
    mask: u64,
    len: usize,
    ordinal: impl Fn(F) -> u32,
    name: impl Fn(F) -> &'static str,
    decode: impl Fn(F) -> Result<Column>,
) -> Result<Columns> {
    let mut columns: Vec<(&'static str, Column)> = Vec::new();
    for &field in variants {
        if mask & (1u64 << ordinal(field)) == 0 {
            continue;
        }
        let field_name = name(field);
        let column =
            decode(field).with_context(|| format!("decoding transaction field '{field_name}'"))?;
        columns.push((field_name, column));
    }
    Ok(Columns { len, columns })
}

/// Decode the per-row mask-selected fields of the given EVM transactions into
/// columns. A field's column is built when any row selects it (the union of
/// `masks`); within that column a row whose own mask lacks the field gets a
/// `None` cell, so a large field (e.g. `input`) is only touched on the rows that
/// asked for it. Runs off the JS thread. `transaction_indices` is the requested
/// key per row, so `transactionIndex` resolves from the key (always known)
/// rather than a stored record.
fn decode_evm_columns(
    records: &[Option<Arc<simple_types::Transaction>>],
    transaction_indices: &[u32],
    masks: &[u64],
    should_checksum: bool,
) -> Result<Columns> {
    let union = masks.iter().fold(0u64, |acc, &m| acc | m);
    build_columns(
        EvmTxField::VARIANTS,
        union,
        records.len(),
        |f| f as u32,
        |f| f.name(),
        |f| decode_evm_field(f, records, transaction_indices, masks, should_checksum),
    )
}

/// Decode a single EVM field, materialising it only on the rows whose mask has
/// the field's bit set. Exhaustive match: adding an `EvmTxField` variant fails
/// to compile until it is decoded here.
fn decode_evm_field(
    field: EvmTxField,
    records: &[Option<Arc<simple_types::Transaction>>],
    transaction_indices: &[u32],
    masks: &[u64],
    should_checksum: bool,
) -> Result<Column> {
    let bit = 1u64 << (field as u32);
    Ok(match field {
        // The within-block index is the store key, so it's always available
        // regardless of whether the transaction row was fetched.
        EvmTxField::TransactionIndex => Column::I64(
            transaction_indices
                .iter()
                .zip(masks)
                .map(|(&i, &m)| (m & bit != 0).then_some(i as i64))
                .collect(),
        ),
        EvmTxField::Hash => Column::Str(fill_masked(records, masks, bit, |tx| {
            Ok(map_hex_string(&tx.hash))
        })?),
        EvmTxField::From => Column::Str(fill_masked(records, masks, bit, |tx| {
            Ok(map_address_string(&tx.from, should_checksum))
        })?),
        EvmTxField::To => Column::Str(fill_masked(records, masks, bit, |tx| {
            Ok(map_address_string(&tx.to, should_checksum))
        })?),
        EvmTxField::Gas => Column::Big(fill_masked(records, masks, bit, |tx| {
            Ok(map_bigint(&tx.gas))
        })?),
        EvmTxField::GasPrice => Column::Big(fill_masked(records, masks, bit, |tx| {
            Ok(map_bigint(&tx.gas_price))
        })?),
        EvmTxField::MaxPriorityFeePerGas => Column::Big(fill_masked(records, masks, bit, |tx| {
            Ok(map_bigint(&tx.max_priority_fee_per_gas))
        })?),
        EvmTxField::MaxFeePerGas => Column::Big(fill_masked(records, masks, bit, |tx| {
            Ok(map_bigint(&tx.max_fee_per_gas))
        })?),
        EvmTxField::CumulativeGasUsed => Column::Big(fill_masked(records, masks, bit, |tx| {
            Ok(map_bigint(&tx.cumulative_gas_used))
        })?),
        EvmTxField::EffectiveGasPrice => Column::Big(fill_masked(records, masks, bit, |tx| {
            Ok(map_bigint(&tx.effective_gas_price))
        })?),
        EvmTxField::GasUsed => Column::Big(fill_masked(records, masks, bit, |tx| {
            Ok(map_bigint(&tx.gas_used))
        })?),
        EvmTxField::Input => Column::Str(fill_masked(records, masks, bit, |tx| {
            Ok(map_hex_string(&tx.input))
        })?),
        EvmTxField::Nonce => Column::Big(fill_masked(records, masks, bit, |tx| {
            Ok(map_bigint(&tx.nonce))
        })?),
        EvmTxField::Value => Column::Big(fill_masked(records, masks, bit, |tx| {
            Ok(map_bigint(&tx.value))
        })?),
        EvmTxField::V => Column::Str(fill_masked(records, masks, bit, |tx| {
            Ok(map_hex_string(&tx.v))
        })?),
        EvmTxField::R => Column::Str(fill_masked(records, masks, bit, |tx| {
            Ok(map_hex_string(&tx.r))
        })?),
        EvmTxField::S => Column::Str(fill_masked(records, masks, bit, |tx| {
            Ok(map_hex_string(&tx.s))
        })?),
        EvmTxField::ContractAddress => Column::Str(fill_masked(records, masks, bit, |tx| {
            Ok(map_address_string(&tx.contract_address, should_checksum))
        })?),
        EvmTxField::LogsBloom => Column::Str(fill_masked(records, masks, bit, |tx| {
            Ok(map_hex_string(&tx.logs_bloom))
        })?),
        EvmTxField::Root => Column::Str(fill_masked(records, masks, bit, |tx| {
            Ok(map_hex_string(&tx.root))
        })?),
        EvmTxField::Status => Column::I64(fill_masked(records, masks, bit, |tx| {
            Ok(tx.status.map(|v| v.to_u8() as i64))
        })?),
        EvmTxField::YParity => Column::Str(fill_masked(records, masks, bit, |tx| {
            Ok(map_hex_string(&tx.y_parity))
        })?),
        EvmTxField::MaxFeePerBlobGas => Column::Big(fill_masked(records, masks, bit, |tx| {
            Ok(map_bigint(&tx.max_fee_per_blob_gas))
        })?),
        EvmTxField::BlobVersionedHashes => {
            Column::StrVec(fill_masked(records, masks, bit, |tx| {
                Ok(tx
                    .blob_versioned_hashes
                    .as_ref()
                    .map(|arr| arr.iter().map(|h| h.encode_hex()).collect()))
            })?)
        }
        EvmTxField::Type => Column::I64(fill_masked(records, masks, bit, |tx| {
            Ok(tx.type_.map(|v| u8::from(v) as i64))
        })?),
        EvmTxField::L1Fee => Column::Big(fill_masked(records, masks, bit, |tx| {
            Ok(map_bigint(&tx.l1_fee))
        })?),
        EvmTxField::L1GasPrice => Column::Big(fill_masked(records, masks, bit, |tx| {
            Ok(map_bigint(&tx.l1_gas_price))
        })?),
        EvmTxField::L1GasUsed => Column::Big(fill_masked(records, masks, bit, |tx| {
            Ok(map_bigint(&tx.l1_gas_used))
        })?),
        EvmTxField::L1FeeScalar => {
            Column::F64(fill_masked(records, masks, bit, |tx| Ok(tx.l1_fee_scalar))?)
        }
        EvmTxField::GasUsedForL1 => Column::Big(fill_masked(records, masks, bit, |tx| {
            Ok(map_bigint(&tx.gas_used_for_l1))
        })?),
        EvmTxField::AccessList => Column::AccessList(fill_masked(records, masks, bit, |tx| {
            Ok(tx
                .access_list
                .as_ref()
                .map(|arr| arr.iter().map(AccessListItem::from).collect()))
        })?),
        EvmTxField::AuthorizationList => {
            Column::AuthList(fill_masked(records, masks, bit, |tx| {
                tx.authorization_list
                    .as_ref()
                    .map(|al| {
                        al.iter()
                            .map(AuthorizationItem::try_from)
                            .collect::<Result<_>>()
                    })
                    .transpose()
            })?)
        }
    })
}

/// A stored SVM transaction: the raw upstream transaction plus the token
/// balances joined to it (a separate upstream table, materialised as one field).
pub struct SvmStored {
    tx: solana_simple::Transaction,
    token_balances: Vec<solana_simple::TokenBalance>,
}

/// Decode the per-row mask-selected fields of the given SVM transactions into
/// columns. A field's column is built when any row selects it (the union of
/// `masks`); within it a row whose own mask lacks the field gets a `None` cell,
/// so a large field (e.g. `accountKeys`) is only cloned for the rows that asked.
/// `transaction_indices` is the requested key per row, so `transactionIndex`
/// resolves from the key (always known) rather than a stored record.
fn decode_svm_columns(
    records: &[Option<Arc<SvmStored>>],
    transaction_indices: &[u32],
    masks: &[u64],
) -> Result<Columns> {
    let union = masks.iter().fold(0u64, |acc, &m| acc | m);
    build_columns(
        SvmTxField::VARIANTS,
        union,
        records.len(),
        |f| f as u32,
        |f| f.name(),
        |f| decode_svm_field(f, records, transaction_indices, masks),
    )
}

/// Decode a single SVM field, materialising it only on the rows whose mask has
/// the field's bit set. Exhaustive match: adding an `SvmTxField` variant fails
/// to compile until it is decoded here.
fn decode_svm_field(
    field: SvmTxField,
    records: &[Option<Arc<SvmStored>>],
    transaction_indices: &[u32],
    masks: &[u64],
) -> Result<Column> {
    let bit = 1u64 << (field as u32);
    Ok(match field {
        // The within-block index is the store key, so it's always available
        // regardless of whether the transaction row was fetched.
        SvmTxField::TransactionIndex => Column::I64(
            transaction_indices
                .iter()
                .zip(masks)
                .map(|(&i, &m)| (m & bit != 0).then_some(i as i64))
                .collect(),
        ),
        SvmTxField::Signatures => Column::StrVec(fill_masked(records, masks, bit, |r| {
            Ok(Some(r.tx.signatures.clone()))
        })?),
        SvmTxField::FeePayer => Column::Str(fill_masked(records, masks, bit, |r| {
            Ok(r.tx.fee_payer.clone())
        })?),
        SvmTxField::Success => {
            Column::Bool(fill_masked(records, masks, bit, |r| Ok(r.tx.success))?)
        }
        SvmTxField::Err => Column::Str(fill_masked(records, masks, bit, |r| Ok(r.tx.err.clone()))?),
        SvmTxField::Fee => Column::Big(fill_masked(records, masks, bit, |r| {
            Ok(r.tx.fee.map(bigint_u64))
        })?),
        SvmTxField::ComputeUnitsConsumed => Column::Big(fill_masked(records, masks, bit, |r| {
            Ok(r.tx.compute_units_consumed.map(bigint_u64))
        })?),
        SvmTxField::AccountKeys => Column::StrVec(fill_masked(records, masks, bit, |r| {
            Ok(Some(r.tx.account_keys.clone()))
        })?),
        SvmTxField::RecentBlockhash => Column::Str(fill_masked(records, masks, bit, |r| {
            Ok(r.tx.recent_blockhash.clone())
        })?),
        SvmTxField::Version => Column::Str(fill_masked(records, masks, bit, |r| {
            Ok(r.tx.version.clone())
        })?),
        // Always materialise an array on a selected row: a record absent from the
        // store (its transaction had no token balances, so it was never
        // inserted) means "no balances" → `[]`, not a missing field. A row that
        // didn't select the field still gets `None` (skipped on the JS object).
        SvmTxField::TokenBalances => Column::TokenBalances(
            records
                .iter()
                .zip(masks)
                .map(|(rec, &m)| {
                    if m & bit == 0 {
                        return None;
                    }
                    Some(match rec {
                        Some(r) => r
                            .token_balances
                            .iter()
                            .map(|tb| SvmTokenBalanceOut {
                                account: tb.account.clone(),
                                mint: tb.mint.clone(),
                                owner: tb.owner.clone(),
                                pre_amount: tb.pre_amount.clone(),
                                post_amount: tb.post_amount.clone(),
                            })
                            .collect(),
                        None => vec![],
                    })
                })
                .collect(),
        ),
    })
}

/// One stored transaction, kept in its ecosystem's compact raw form.
enum StoredTx {
    /// HyperSync: raw upstream transaction, selected fields decoded at batch prep.
    EvmRaw { tx: Arc<simple_types::Transaction> },
    /// SVM HyperSync: raw upstream transaction (+ joined token balances).
    Svm { rec: Arc<SvmStored> },
}

/// Transactions keyed by block number, then by within-block transaction index.
/// The outer `BTreeMap` keeps prune and rollback cheap range splits.
#[derive(Default)]
struct BlockTxs {
    map: BTreeMap<u64, HashMap<u32, StoredTx>>,
}

impl BlockTxs {
    fn new() -> Self {
        Self::default()
    }

    /// Drain every entry from `self` into `dst`, merging per-block buckets.
    fn drain_into(&mut self, dst: &mut Self) {
        for (block, bucket) in std::mem::take(&mut self.map) {
            dst.map.entry(block).or_default().extend(bucket);
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

/// Gather the stored records matching the requested keys, in input order;
/// missing keys (or a record `pick` rejects) yield `None`. Shared by both
/// ecosystems — only the `pick` closure (which `StoredTx` variant to take)
/// differs.
fn collect<T>(
    store: &BlockTxs,
    block_numbers: &[i64],
    transaction_indices: &[u32],
    pick: impl Fn(&StoredTx) -> Option<T>,
) -> Vec<Option<T>> {
    block_numbers
        .iter()
        .zip(transaction_indices)
        .map(|(block, idx)| {
            let block = u64::try_from(*block).ok()?;
            store
                .map
                .get(&block)
                .and_then(|b| b.get(idx))
                .and_then(&pick)
        })
        .collect()
}

/// Ecosystem selecting `materialize`'s decoder. A store is per-chain, hence
/// single-ecosystem, and is fixed at construction. `Evm` carries that chain's
/// address-checksumming setting — a per-chain EVM constant the decoder needs,
/// which the type ties to EVM so it can't be set without (or forgotten for) it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Ecosystem {
    Evm { should_checksum: bool },
    Svm,
    Fuel,
}

#[napi]
pub struct TransactionStore {
    inner: Mutex<BlockTxs>,
    // Fixed at construction; drives the decoder in `materialize`.
    ecosystem: Ecosystem,
}

#[napi]
impl TransactionStore {
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

    /// Fuel store. Fuel keeps transactions inline, so this store is never merged
    /// into or materialised through — it exists only because every chain holds one.
    #[napi(factory)]
    pub fn new_fuel() -> Self {
        Self::with_ecosystem(Ecosystem::Fuel)
    }

    /// Move every entry from `page` into this store (merging a fetch-response
    /// page into the persistent per-chain store).
    #[napi]
    pub fn merge(&self, page: &TransactionStore) {
        // Merging a store into itself would lock the same Mutex twice (deadlock).
        if std::ptr::eq(self, page) {
            return;
        }
        // A page and its persistent store are the same per-chain ecosystem (both
        // derive it from the one chain config), so the decoder is unaffected by the merge.
        debug_assert_eq!(self.ecosystem, page.ecosystem);
        let mut dst = self.inner.lock().unwrap();
        let mut src = page.inner.lock().unwrap();
        src.drain_into(&mut dst);
    }

    /// Bulk-materialise transactions in columnar form, one row per
    /// `(block_numbers[i], transaction_indices[i])` key, decoding only the fields
    /// whose bit is set in that row's own `masks[i]`. Per-row masks let each event
    /// pull just the transaction fields it selected, so a large field (e.g.
    /// `input`) is materialised only on the rows that asked for it. Each mask is a
    /// JS number (`f64`) carrying a selection bitmask over field codes 0..31 (so
    /// it fits in 32 bits). Async + `block_in_place` so the bulk decode runs off
    /// the JS thread without monopolising an async worker; the brief lock only
    /// clones `Arc`s. Missing keys yield an empty object. Result is aligned with
    /// input.
    #[napi(ts_return_type = "Promise<object[]>")]
    pub async fn materialize(
        &self,
        block_numbers: Vec<i64>,
        transaction_indices: Vec<u32>,
        masks: Vec<f64>,
    ) -> napi::Result<Columns> {
        // The three columns are zipped row-wise into the output; a length mismatch
        // would silently truncate and misalign the result with the caller's items.
        if block_numbers.len() != transaction_indices.len() || block_numbers.len() != masks.len() {
            return Err(napi::Error::from_reason(format!(
                "materialize column length mismatch: block_numbers={}, transaction_indices={}, masks={}",
                block_numbers.len(),
                transaction_indices.len(),
                masks.len()
            )));
        }
        let masks: Vec<u64> = masks.iter().map(|&m| m as u64).collect();

        match self.ecosystem {
            Ecosystem::Evm { should_checksum } => {
                let records =
                    self.collect_locked(
                        &block_numbers,
                        &transaction_indices,
                        |stored| match stored {
                            StoredTx::EvmRaw { tx } => Some(tx.clone()),
                            _ => None,
                        },
                    );
                tokio::task::block_in_place(|| {
                    decode_evm_columns(&records, &transaction_indices, &masks, should_checksum)
                })
                .map_err(map_err)
            }
            Ecosystem::Svm => {
                let records =
                    self.collect_locked(
                        &block_numbers,
                        &transaction_indices,
                        |stored| match stored {
                            StoredTx::Svm { rec } => Some(rec.clone()),
                            _ => None,
                        },
                    );
                tokio::task::block_in_place(|| {
                    decode_svm_columns(&records, &transaction_indices, &masks)
                })
                .map_err(map_err)
            }
            // Fuel keeps transactions inline, so its store is never materialised
            // through; should it be, every key is a miss → `len` empty objects.
            Ecosystem::Fuel => Ok(Columns {
                len: block_numbers.len(),
                columns: Vec::new(),
            }),
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
    /// Lock the store and gather the records for the requested keys. The lock is
    /// held only for the `Arc` clones; decoding runs after it is released.
    fn collect_locked<T>(
        &self,
        block_numbers: &[i64],
        transaction_indices: &[u32],
        pick: impl Fn(&StoredTx) -> Option<T>,
    ) -> Vec<Option<T>> {
        let inner = self.inner.lock().unwrap();
        collect(&inner, block_numbers, transaction_indices, pick)
    }

    fn with_ecosystem(ecosystem: Ecosystem) -> Self {
        Self {
            inner: Mutex::new(BlockTxs::new()),
            ecosystem,
        }
    }

    /// Insert a raw EVM transaction (called by the HyperSync source while
    /// building a page). The page's transactions arrive already deduplicated by
    /// the upstream response (one row per (block, index)), so a plain insert is
    /// enough — many logs sharing a transaction never reach here. Not exposed to
    /// JS.
    pub(crate) fn insert_evm_raw(
        &self,
        block_number: u64,
        transaction_index: u32,
        tx: Arc<simple_types::Transaction>,
    ) {
        self.inner
            .lock()
            .unwrap()
            .map
            .entry(block_number)
            .or_default()
            .insert(transaction_index, StoredTx::EvmRaw { tx });
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

/// Ordered EVM transaction-field names — the single source of truth the ReScript
/// `Evm.res transactionFields` array is tested against. The order is the bit
/// position in the selection mask, so the two must not drift.
#[napi]
pub fn evm_transaction_field_names() -> Vec<String> {
    EvmTxField::VARIANTS
        .iter()
        .map(|f| f.name().to_string())
        .collect()
}

/// Ordered SVM transaction-field names; `Svm.res transactionFields` is tested
/// against this.
#[napi]
pub fn svm_transaction_field_names() -> Vec<String> {
    SvmTxField::VARIANTS
        .iter()
        .map(|f| f.name().to_string())
        .collect()
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
        let cols = decode_evm_columns(&[Some(Arc::new(raw_tx()))], &[0], &[mask], false)
            .expect("decode columns");

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
    fn decode_applies_each_rows_own_mask() {
        // Row 0 selects `input`; row 1 selects only `transactionIndex`. The union
        // builds both columns, but each field is present only on its row.
        let input_mask = 1u64 << (EvmTxField::Input as u32);
        let index_mask = 1u64 << (EvmTxField::TransactionIndex as u32);
        let cols = decode_evm_columns(
            &[Some(Arc::new(raw_tx())), Some(Arc::new(raw_tx()))],
            &[0, 1],
            &[input_mask, index_mask],
            false,
        )
        .expect("decode columns");

        // `input` decoded only for row 0; row 1 is `None` (skipped on its object).
        match column(&cols, "input") {
            Some(Column::Str(v)) => assert_eq!(v, &vec![Some("0xabcd".to_string()), None]),
            other => panic!("expected input column, got present={}", other.is_some()),
        }
        // `transactionIndex` resolves from the key only for row 1.
        match column(&cols, "transactionIndex") {
            Some(Column::I64(v)) => assert_eq!(v, &vec![None, Some(1)]),
            other => panic!(
                "expected transactionIndex column, got present={}",
                other.is_some()
            ),
        }
    }

    #[test]
    fn evm_transaction_index_comes_from_key_even_on_miss() {
        // A missing record (None) still materialises the requested key as
        // `transactionIndex`, so it never depends on a fetched transaction row.
        let mask = 1u64 << (EvmTxField::TransactionIndex as u32);
        let cols = decode_evm_columns(
            &[None, Some(Arc::new(raw_tx()))],
            &[7, 3],
            &[mask, mask],
            false,
        )
        .expect("decode columns");
        match column(&cols, "transactionIndex") {
            Some(Column::I64(v)) => assert_eq!(v, &vec![Some(7), Some(3)]),
            other => panic!(
                "expected transactionIndex i64 column, got present={}",
                other.is_some()
            ),
        }
    }

    #[test]
    fn field_codes_match_names_in_order() {
        // The bit position (`field as u32`) must equal the field's index in
        // `VARIANTS`, and the names must match the ReScript `transactionFields`
        // arrays in that same order. Pin both so a reordered or misnumbered
        // variant fails here rather than silently corrupting the shared mask.
        let evm_codes: Vec<i32> = EvmTxField::VARIANTS.iter().map(|&f| f as i32).collect();
        assert_eq!(
            evm_codes,
            Vec::from_iter(0..EvmTxField::VARIANTS.len() as i32)
        );
        let evm_names: Vec<&str> = EvmTxField::VARIANTS.iter().map(|f| f.name()).collect();
        assert_eq!(
            evm_names,
            vec![
                "transactionIndex",
                "hash",
                "from",
                "to",
                "gas",
                "gasPrice",
                "maxPriorityFeePerGas",
                "maxFeePerGas",
                "cumulativeGasUsed",
                "effectiveGasPrice",
                "gasUsed",
                "input",
                "nonce",
                "value",
                "v",
                "r",
                "s",
                "contractAddress",
                "logsBloom",
                "root",
                "status",
                "yParity",
                "maxFeePerBlobGas",
                "blobVersionedHashes",
                "type",
                "l1Fee",
                "l1GasPrice",
                "l1GasUsed",
                "l1FeeScalar",
                "gasUsedForL1",
                "accessList",
                "authorizationList",
            ]
        );

        let svm_codes: Vec<i32> = SvmTxField::VARIANTS.iter().map(|&f| f as i32).collect();
        assert_eq!(
            svm_codes,
            Vec::from_iter(0..SvmTxField::VARIANTS.len() as i32)
        );
        let svm_names: Vec<&str> = SvmTxField::VARIANTS.iter().map(|f| f.name()).collect();
        assert_eq!(
            svm_names,
            vec![
                "transactionIndex",
                "signatures",
                "feePayer",
                "success",
                "err",
                "fee",
                "computeUnitsConsumed",
                "accountKeys",
                "recentBlockhash",
                "version",
                "tokenBalances",
            ]
        );
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
        let cols = decode_svm_columns(&[Some(rec)], &[0], &[mask]).expect("decode columns");

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
        let store = TransactionStore::new_evm(false);
        for block in [10u64, 20, 30] {
            store.insert_evm_raw(block, 0, Arc::new(simple_types::Transaction::default()));
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
