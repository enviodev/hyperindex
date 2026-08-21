//! Per-chain transaction store: a merge-on-insert `Table` keyed by
//! (blockNumber, transactionIndex), holding only the selected fields'
//! columns — a large field (e.g. EVM `input`) never crosses the napi boundary
//! until an event that selected it is materialised, and never duplicates
//! across overlapping partition re-fetches since a key's cell overwrites in
//! place. SVM account activity lives in a companion table keyed by (slot,
//! transactionIndex, account) and gathered by (slot, transactionIndex) range.
//! The store lives on the ReScript `ChainState`; fetch responses merge in,
//! and rows are pruned/rolled back by block.

use std::sync::Mutex;

use anyhow::Result;
use hypersync_client::simple_types;
use hypersync_client_solana::simple_types as solana_simple;
use napi::bindgen_prelude::BigInt;
use napi_derive::napi;
use strum::VariantArray;

use crate::evm_hypersync_source::map_err;
use crate::evm_hypersync_source::types::{
    encode_address, map_bigint, AccessList as AccessListItem, Authorization as AuthorizationItem,
};
use crate::field_columns::{
    build_columns, bytes, field_names, Column, Columns, Ecosystem, SvmAccountActivityOut,
    SvmAccountTokenOut, SvmLamportsOut,
};
use crate::field_table::{
    access_lists_cells, access_lists_from, auth_lists_cells, auth_lists_from, bool_cells,
    bool_from, bytes_cells, f64_cells, f64_from, fixed_from, hash_list_cells, hash_list_from,
    hex_full, hex_quantity, str_list_cells, str_list_from, u64_cells, u64_from, utf8, var_from,
    AnyCol, Table,
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
    Signature = 1,
    FeePayer = 2,
    Success = 3,
    Err = 4,
    Fee = 5,
    ComputeUnitsConsumed = 6,
    AccountKeys = 7,
    RecentBlockhash = 8,
    Version = 9,
    AllSignatures = 10,
    AccountActivities = 11,
}

impl SvmTxField {
    /// JS property name; must match `Svm.res` `transactionFields`.
    pub fn name(self) -> &'static str {
        use SvmTxField::*;
        match self {
            TransactionIndex => "transactionIndex",
            Signature => "signature",
            FeePayer => "feePayer",
            Success => "success",
            Err => "err",
            Fee => "fee",
            ComputeUnitsConsumed => "computeUnitsConsumed",
            AccountKeys => "accountKeys",
            RecentBlockhash => "recentBlockhash",
            Version => "version",
            AllSignatures => "allSignatures",
            AccountActivities => "accountActivities",
        }
    }
}

/// Build one EVM field's column from a response's transactions. `None` for the
/// key-derived `transactionIndex` and for fields no transaction carries.
/// Exhaustive match: adding an `EvmTxField` variant fails to compile until it
/// is filled here and decoded below.
fn evm_tx_col(field: EvmTxField, txs: &[simple_types::Transaction]) -> Option<AnyCol> {
    use EvmTxField::*;
    match field {
        // The within-block index is part of the table key, not a column.
        TransactionIndex => None,
        Hash => fixed_from(txs, 32, |t| t.hash.as_ref().map(bytes)),
        From => fixed_from(txs, 20, |t| t.from.as_ref().map(bytes)),
        To => fixed_from(txs, 20, |t| t.to.as_ref().map(bytes)),
        Gas => var_from(txs, |t| t.gas.as_ref().map(bytes)),
        GasPrice => var_from(txs, |t| t.gas_price.as_ref().map(bytes)),
        MaxPriorityFeePerGas => var_from(txs, |t| t.max_priority_fee_per_gas.as_ref().map(bytes)),
        MaxFeePerGas => var_from(txs, |t| t.max_fee_per_gas.as_ref().map(bytes)),
        CumulativeGasUsed => var_from(txs, |t| t.cumulative_gas_used.as_ref().map(bytes)),
        EffectiveGasPrice => var_from(txs, |t| t.effective_gas_price.as_ref().map(bytes)),
        GasUsed => var_from(txs, |t| t.gas_used.as_ref().map(bytes)),
        Input => var_from(txs, |t| t.input.as_ref().map(bytes)),
        Nonce => var_from(txs, |t| t.nonce.as_ref().map(bytes)),
        Value => var_from(txs, |t| t.value.as_ref().map(bytes)),
        V => var_from(txs, |t| t.v.as_ref().map(bytes)),
        R => var_from(txs, |t| t.r.as_ref().map(bytes)),
        S => var_from(txs, |t| t.s.as_ref().map(bytes)),
        ContractAddress => fixed_from(txs, 20, |t| t.contract_address.as_ref().map(bytes)),
        LogsBloom => var_from(txs, |t| t.logs_bloom.as_ref().map(bytes)),
        Root => fixed_from(txs, 32, |t| t.root.as_ref().map(bytes)),
        Status => u64_from(txs, |t| t.status.map(|v| v.to_u8() as u64)),
        YParity => var_from(txs, |t| t.y_parity.as_ref().map(bytes)),
        MaxFeePerBlobGas => var_from(txs, |t| t.max_fee_per_blob_gas.as_ref().map(bytes)),
        BlobVersionedHashes => hash_list_from(txs, |t| {
            t.blob_versioned_hashes.as_ref().map(|v| {
                v.iter()
                    .map(|h| <[u8; 32]>::try_from(h.as_ref()).expect("blob hash width"))
                    .collect()
            })
        }),
        Type => u64_from(txs, |t| t.type_.map(|v| u8::from(v) as u64)),
        L1Fee => var_from(txs, |t| t.l1_fee.as_ref().map(bytes)),
        L1GasPrice => var_from(txs, |t| t.l1_gas_price.as_ref().map(bytes)),
        L1GasUsed => var_from(txs, |t| t.l1_gas_used.as_ref().map(bytes)),
        L1FeeScalar => f64_from(txs, |t| t.l1_fee_scalar),
        GasUsedForL1 => var_from(txs, |t| t.gas_used_for_l1.as_ref().map(bytes)),
        AccessList => access_lists_from(txs, |t| t.access_list.clone()),
        AuthorizationList => auth_lists_from(txs, |t| t.authorization_list.clone()),
    }
}

/// Decode one EVM field from its gathered scratch column, already masked
/// per-row by the gather.
fn decode_evm_field(
    field: EvmTxField,
    scratch: &[Option<AnyCol>],
    transaction_indices: &[u32],
    masks: &[u64],
    should_checksum: bool,
) -> Result<Column> {
    use EvmTxField::*;
    let bit = 1u64 << (field as u32);
    let col = scratch[field as usize].as_ref();
    let len = transaction_indices.len();
    Ok(match field {
        // The within-block index is the store key, so it's always available
        // regardless of whether the transaction row was fetched.
        TransactionIndex => Column::I64(
            transaction_indices
                .iter()
                .zip(masks)
                .map(|(&i, &m)| (m & bit != 0).then_some(i as i64))
                .collect(),
        ),
        Hash | Input | LogsBloom | Root => {
            Column::Str(bytes_cells(col, len, |b| Ok(Some(hex_full(b))))?)
        }
        From | To | ContractAddress => Column::Str(bytes_cells(col, len, |b| {
            let address = <[u8; 20]>::try_from(b).expect("address cell width");
            Ok(Some(encode_address(&address.into(), should_checksum)))
        })?),
        Gas | GasPrice | MaxPriorityFeePerGas | MaxFeePerGas | CumulativeGasUsed
        | EffectiveGasPrice | GasUsed | Nonce | Value | MaxFeePerBlobGas | L1Fee | L1GasPrice
        | L1GasUsed | GasUsedForL1 => {
            Column::Big(bytes_cells(col, len, |b| Ok(map_bigint(&Some(b))))?)
        }
        V | R | S | YParity => Column::Str(bytes_cells(col, len, |b| Ok(Some(hex_quantity(b))))?),
        Status | Type => Column::I64(u64_cells(col, len, |v| Ok(Some(v as i64)))?),
        BlobVersionedHashes => Column::StrVec(hash_list_cells(col, len, |h| hex_full(h))),
        L1FeeScalar => Column::F64(f64_cells(col, len)),
        AccessList => Column::AccessList(access_lists_cells(col, len, |a| AccessListItem::from(a))),
        AuthorizationList => Column::AuthList(auth_lists_cells(col, len, |a| {
            AuthorizationItem::try_from(a)
        })?),
    })
}

fn decode_evm_columns(
    scratch: &[Option<AnyCol>],
    transaction_indices: &[u32],
    masks: &[u64],
    should_checksum: bool,
) -> Result<Columns> {
    build_columns(
        EvmTxField::VARIANTS,
        masks,
        transaction_indices.len(),
        |f| f as u32,
        |f| f.name(),
        |f| decode_evm_field(f, scratch, transaction_indices, masks, should_checksum),
    )
}

/// Build one SVM field's column from a response's transactions. `None` for the
/// key-derived `transactionIndex` and for `accountActivities`, which lives in
/// the companion duplicate-key table.
fn svm_tx_col(field: SvmTxField, txs: &[solana_simple::Transaction]) -> Option<AnyCol> {
    use SvmTxField::*;
    match field {
        TransactionIndex => None,
        Signature => base58_col(txs, |t| t.transaction_id),
        AllSignatures => str_list_from(txs, |t| {
            t.signatures
                .as_ref()
                .map(|signatures| signatures.iter().map(|s| s.to_string()).collect())
        }),
        FeePayer => base58_col(txs, |t| t.fee_payer),
        Success => bool_from(txs, |t| t.success),
        Err => var_from(txs, |t| t.err.as_ref().map(|s| s.as_bytes())),
        Fee => u64_from(txs, |t| t.fee),
        ComputeUnitsConsumed => u64_from(txs, |t| t.compute_units_consumed),
        AccountKeys => str_list_from(txs, |t| {
            t.account_keys
                .as_ref()
                .map(|keys| keys.iter().map(|key| key.to_string()).collect())
        }),
        RecentBlockhash => base58_col(txs, |t| t.recent_blockhash),
        Version => var_from(txs, |t| t.version.as_ref().map(|s| s.as_bytes())),
        AccountActivities => None,
    }
}

/// Column of base58-rendered byte newtypes (pubkeys, hashes), which the client
/// hands over as bytes.
fn base58_col<T: std::fmt::Display>(
    txs: &[solana_simple::Transaction],
    f: impl Fn(&solana_simple::Transaction) -> Option<T>,
) -> Option<AnyCol> {
    let rendered: Vec<Option<String>> = txs.iter().map(|t| f(t).map(|v| v.to_string())).collect();
    var_from(&rendered, |v| v.as_deref().map(str::as_bytes))
}

/// Decode one SVM field. `accountActivities` come pre-gathered from
/// the companion table (they aren't part of the transaction scratch).
fn decode_svm_field(
    field: SvmTxField,
    scratch: &[Option<AnyCol>],
    account_activities: &[Option<Vec<SvmAccountActivityOut>>],
    transaction_indices: &[u32],
    masks: &[u64],
) -> Result<Column> {
    use SvmTxField::*;
    let bit = 1u64 << (field as u32);
    let col = scratch[field as usize].as_ref();
    let len = transaction_indices.len();
    Ok(match field {
        // The within-block index is the store key, so it's always available
        // regardless of whether the transaction row was fetched.
        TransactionIndex => Column::I64(
            transaction_indices
                .iter()
                .zip(masks)
                .map(|(&i, &m)| (m & bit != 0).then_some(i as i64))
                .collect(),
        ),
        AllSignatures | AccountKeys => Column::StrVec(str_list_cells(col, len)),
        Signature | FeePayer | Err | RecentBlockhash | Version => {
            Column::Str(bytes_cells(col, len, |b| Ok(Some(utf8(b))))?)
        }
        Success => Column::Bool(bool_cells(col, len)),
        Fee | ComputeUnitsConsumed => {
            Column::Big(u64_cells(col, len, |v| Ok(Some(bigint_u64(v))))?)
        }
        AccountActivities => Column::AccountActivities(account_activities.to_vec()),
    })
}

fn decode_svm_columns(
    scratch: &[Option<AnyCol>],
    account_activities: &[Option<Vec<SvmAccountActivityOut>>],
    transaction_indices: &[u32],
    masks: &[u64],
) -> Result<Columns> {
    build_columns(
        SvmTxField::VARIANTS,
        masks,
        transaction_indices.len(),
        |f| f as u32,
        |f| f.name(),
        |f| decode_svm_field(f, scratch, account_activities, transaction_indices, masks),
    )
}

/// Account-activity column order in the companion table. `account` is the
/// key's third component (see `insert_svm_account_activity`), not a column.
const AA_MINT: usize = 0;
const AA_OWNER: usize = 1;
const AA_DECIMALS: usize = 2;
const AA_PRE_AMOUNT: usize = 3;
const AA_POST_AMOUNT: usize = 4;
const AA_PRE_LAMPORTS: usize = 5;
const AA_POST_LAMPORTS: usize = 6;
/// Position in the transaction's resolved key list (`account_keys` ++ the
/// lookup tables' writable then readonly addresses).
const AA_ACCOUNT_INDEX: usize = 7;
const AA_IS_SIGNER: usize = 8;
const AA_IS_WRITABLE: usize = 9;
const ACCOUNT_ACTIVITY_FIELDS: usize = 10;

/// The token side of an activity row, read directly by slot off the companion
/// table's columns. `None` on an account that holds no token balance — the mint
/// is what makes a row a token row.
fn account_token(table: &Table<(u64, u32, Box<str>)>, slot: u32) -> Option<SvmAccountTokenOut> {
    let mint = table.var_cell(AA_MINT, slot).map(utf8)?;
    Some(SvmAccountTokenOut {
        mint,
        owner: table.var_cell(AA_OWNER, slot).map(utf8),
        decimals: table.u64_cell(AA_DECIMALS, slot).map(|v| v as u8),
        pre_amount: table.u64_cell(AA_PRE_AMOUNT, slot).map(bigint_u64),
        post_amount: table.u64_cell(AA_POST_AMOUNT, slot).map(bigint_u64),
    })
}

fn activity_row(
    table: &Table<(u64, u32, Box<str>)>,
    key: &(u64, u32, Box<str>),
    slot: u32,
) -> SvmAccountActivityOut {
    let pre = table.u64_cell(AA_PRE_LAMPORTS, slot).map(bigint_u64);
    let post = table.u64_cell(AA_POST_LAMPORTS, slot).map(bigint_u64);
    let lamports = match (pre, post) {
        (None, None) => None,
        (pre, post) => Some(SvmLamportsOut { pre, post }),
    };
    SvmAccountActivityOut {
        address: key.2.to_string(),
        transaction_account_index: table.u64_cell(AA_ACCOUNT_INDEX, slot).map(|v| v as i64),
        is_signer: table.bool_cell(AA_IS_SIGNER, slot),
        is_writable: table.bool_cell(AA_IS_WRITABLE, slot),
        lamports,
        token: account_token(table, slot),
    }
}

/// Gather each selected row's activity: every account_activity row for that
/// (slot, transactionIndex), ordered by `transactionAccountIndex`. No key-list
/// join — a row exists only where something moved.
fn gather_account_activities(
    table: &Table<(u64, u32, Box<str>)>,
    keys: &[Option<(u64, u32)>],
    masks: &[u64],
) -> Vec<Option<Vec<SvmAccountActivityOut>>> {
    let bit = 1u64 << (SvmTxField::AccountActivities as u32);
    keys.iter()
        .zip(masks)
        .map(|(key, &m)| {
            if m & bit == 0 {
                return None;
            }
            let Some(key) = key else {
                return Some(Vec::new());
            };
            let mut rows: Vec<_> = table.range_slots(key.0, key.1).collect();
            rows.sort_by(|(a_key, a_slot), (b_key, b_slot)| {
                table
                    .u64_cell(AA_ACCOUNT_INDEX, *a_slot)
                    .unwrap_or(u64::MAX)
                    .cmp(
                        &table
                            .u64_cell(AA_ACCOUNT_INDEX, *b_slot)
                            .unwrap_or(u64::MAX),
                    )
                    .then_with(|| a_key.2.cmp(&b_key.2))
            });
            Some(
                rows.into_iter()
                    .map(|(k, slot)| activity_row(table, k, slot))
                    .collect(),
            )
        })
        .collect()
}

/// The transaction table plus SVM's account-activity companion (empty on other
/// ecosystems), guarded together so merges and gathers stay atomic.
struct Stores {
    txs: Table<(u64, u32)>,
    account_activity: Table<(u64, u32, Box<str>)>,
}

#[napi(object)]
pub struct SvmTxInput {
    pub slot: i64,
    pub transaction_index: u32,
    pub signature: Option<String>,
    pub all_signatures: Option<Vec<String>>,
    pub fee_payer: Option<String>,
    pub success: Option<bool>,
    pub err: Option<String>,
    pub fee: Option<BigInt>,
    pub compute_units_consumed: Option<BigInt>,
    pub account_keys: Option<Vec<String>>,
    pub recent_blockhash: Option<String>,
    pub version: Option<String>,
}

#[napi(object)]
pub struct SvmActivityInput {
    pub slot: i64,
    pub transaction_index: u32,
    pub account: String,
    pub account_index: Option<u32>,
    pub is_signer: Option<bool>,
    pub is_writable: Option<bool>,
    pub pre_balance: Option<BigInt>,
    pub post_balance: Option<BigInt>,
    pub mint: Option<String>,
    pub owner: Option<String>,
    pub decimals: Option<u8>,
    pub pre_amount: Option<BigInt>,
    pub post_amount: Option<BigInt>,
}

fn parse_one_base58<T: std::str::FromStr>(value: &str, field: &str) -> napi::Result<T>
where
    T::Err: std::fmt::Display,
{
    value.parse::<T>().map_err(|e| {
        napi::Error::from_reason(format!("{field} {value:?} is not valid base58: {e}"))
    })
}

/// Base58 field from a JS simulate input. `None` stays `None` so an unset field
/// reads back as "not selected" rather than as a zeroed key.
fn parse_base58<T: std::str::FromStr>(value: Option<&str>, field: &str) -> napi::Result<Option<T>>
where
    T::Err: std::fmt::Display,
{
    value.map(|v| parse_one_base58(v, field)).transpose()
}

fn parse_base58_list<T: std::str::FromStr>(
    values: Option<&[String]>,
    field: &str,
) -> napi::Result<Option<Vec<T>>>
where
    T::Err: std::fmt::Display,
{
    values
        .map(|vs| {
            vs.iter()
                .map(|v| parse_one_base58(v, field))
                .collect::<napi::Result<Vec<T>>>()
        })
        .transpose()
}

fn bigint_to_u64(value: BigInt, field: &str) -> napi::Result<u64> {
    if value.sign_bit {
        return Err(napi::Error::from_reason(format!(
            "{field} must be non-negative"
        )));
    }
    match value.words.as_slice() {
        [] => Ok(0),
        [word] => Ok(*word),
        _ => Err(napi::Error::from_reason(format!(
            "{field} does not fit in u64"
        ))),
    }
}

#[napi]
pub struct TransactionStore {
    inner: Mutex<Stores>,
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

    /// Move every row from `page` into this store (merging a fetch-response
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
        dst.txs.append_from(&mut src.txs);
        dst.account_activity.append_from(&mut src.account_activity);
    }

    /// Bulk-materialise transactions in columnar form, one row per
    /// `(block_numbers[i], transaction_indices[i])` key, decoding only the fields
    /// whose bit is set in that row's own `masks[i]`. Per-row masks let each event
    /// pull just the transaction fields it selected, so a large field (e.g.
    /// `input`) is materialised only on the rows that asked for it. Each mask is a
    /// JS number (`f64`) carrying a selection bitmask over field codes 0..31 (so
    /// it fits in 32 bits). The lock is held only to gather the requested cells;
    /// decoding runs after it is released, off the JS thread via
    /// `block_in_place`. Missing keys yield an empty object. Result is aligned
    /// with input.
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
                "materialize column length mismatch: block_numbers={}, transaction_indices={}, \
                 masks={}",
                block_numbers.len(),
                transaction_indices.len(),
                masks.len()
            )));
        }
        let masks: Vec<u64> = masks.iter().map(|&m| m as u64).collect();
        let keys: Vec<Option<(u64, u32)>> = block_numbers
            .iter()
            .zip(&transaction_indices)
            .map(|(&bn, &ti)| u64::try_from(bn).ok().map(|bn| (bn, ti)))
            .collect();

        match self.ecosystem {
            Ecosystem::Evm { should_checksum } => {
                let scratch = self.inner.lock().unwrap().txs.gather_scratch(&keys, &masks);
                tokio::task::block_in_place(|| {
                    decode_evm_columns(&scratch, &transaction_indices, &masks, should_checksum)
                })
                .map_err(map_err)
            }
            Ecosystem::Svm => {
                let (scratch, account_activities) = {
                    let stores = self.inner.lock().unwrap();
                    (
                        stores.txs.gather_scratch(&keys, &masks),
                        gather_account_activities(&stores.account_activity, &keys, &masks),
                    )
                };
                tokio::task::block_in_place(|| {
                    decode_svm_columns(&scratch, &account_activities, &transaction_indices, &masks)
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
            let mut stores = self.inner.lock().unwrap();
            stores.txs.prune((up_to, u32::MAX));
            stores
                .account_activity
                .prune((up_to, u32::MAX, Box::from("")));
        }
    }

    /// Drop transactions for blocks above `target_block` (rolled back).
    #[napi]
    pub fn rollback(&self, target_block: i64) {
        let mut stores = self.inner.lock().unwrap();
        match u64::try_from(target_block) {
            Ok(target) => {
                stores.txs.rollback((target, u32::MAX));
                stores
                    .account_activity
                    .rollback((target, u32::MAX, Box::from("")));
            }
            Err(_) => {
                stores.txs.clear();
                stores.account_activity.clear();
            }
        }
    }

    /// Page built from JS transaction and account-activity objects, for sources
    /// that construct SVM pages in JS (simulate) the way HyperSync does in Rust.
    #[napi(factory)]
    pub fn from_js_svm(
        transactions: Vec<SvmTxInput>,
        activities: Vec<SvmActivityInput>,
    ) -> napi::Result<Self> {
        let store = Self::with_ecosystem(Ecosystem::Svm);
        let txs = transactions
            .into_iter()
            .map(|t| {
                Ok(solana_simple::Transaction {
                    slot: Some(
                        u64::try_from(t.slot)
                            .map_err(|_| napi::Error::from_reason("slot must be non-negative"))?,
                    ),
                    transaction_index: Some(t.transaction_index),
                    transaction_id: parse_base58(t.signature.as_deref(), "signature")?,
                    signatures: parse_base58_list(t.all_signatures.as_deref(), "allSignatures")?,
                    fee_payer: parse_base58(t.fee_payer.as_deref(), "feePayer")?,
                    success: t.success,
                    err: t.err,
                    fee: t.fee.map(|v| bigint_to_u64(v, "fee")).transpose()?,
                    compute_units_consumed: t
                        .compute_units_consumed
                        .map(|v| bigint_to_u64(v, "computeUnitsConsumed"))
                        .transpose()?,
                    account_keys: parse_base58_list(t.account_keys.as_deref(), "accountKeys")?,
                    recent_blockhash: parse_base58(
                        t.recent_blockhash.as_deref(),
                        "recentBlockhash",
                    )?,
                    version: t.version,
                    ..Default::default()
                })
            })
            .collect::<napi::Result<Vec<_>>>()?;
        store.insert_svm_txs(txs);

        let rows = activities
            .into_iter()
            .map(|a| {
                let parse_key = |value: &str, field: &str| {
                    value.parse::<solana_simple::Address>().map_err(|e| {
                        napi::Error::from_reason(format!("{field} {value:?} is not a pubkey: {e}"))
                    })
                };
                let to_u64 =
                    |v: Option<BigInt>, field: &str| v.map(|n| bigint_to_u64(n, field)).transpose();
                Ok(solana_simple::AccountActivity {
                    slot: Some(
                        u64::try_from(a.slot)
                            .map_err(|_| napi::Error::from_reason("slot must be non-negative"))?,
                    ),
                    transaction_index: Some(a.transaction_index),
                    account: Some(parse_key(&a.account, "account")?),
                    account_index: a.account_index,
                    is_signer: a.is_signer,
                    is_writable: a.is_writable,
                    pre_balance: to_u64(a.pre_balance, "preBalance")?,
                    post_balance: to_u64(a.post_balance, "postBalance")?,
                    mint: a
                        .mint
                        .as_deref()
                        .map(|m| parse_key(m, "mint"))
                        .transpose()?,
                    pre_owner: a
                        .owner
                        .as_deref()
                        .map(|o| parse_key(o, "owner"))
                        .transpose()?,
                    post_owner: a
                        .owner
                        .as_deref()
                        .map(|o| parse_key(o, "owner"))
                        .transpose()?,
                    token_decimals: a.decimals,
                    pre_token_balance: to_u64(a.pre_amount, "preAmount")?,
                    post_token_balance: to_u64(a.post_amount, "postAmount")?,
                    ..Default::default()
                })
            })
            .collect::<napi::Result<Vec<_>>>()?;
        store.insert_svm_account_activity(rows);
        Ok(store)
    }
}

impl TransactionStore {
    fn with_ecosystem(ecosystem: Ecosystem) -> Self {
        let n_fields = match ecosystem {
            Ecosystem::Evm { .. } => EvmTxField::VARIANTS.len(),
            Ecosystem::Svm => SvmTxField::VARIANTS.len(),
            Ecosystem::Fuel => 0,
        };
        Self {
            inner: Mutex::new(Stores {
                txs: Table::new(n_fields),
                account_activity: Table::new(ACCOUNT_ACTIVITY_FIELDS),
            }),
            ecosystem,
        }
    }

    /// Merge one response's EVM transactions into the table (called by the
    /// HyperSync source while building a page). Rows without a (block, index)
    /// key are dropped. Not exposed to JS.
    pub(crate) fn insert_evm_txs(&self, mut txs: Vec<simple_types::Transaction>) {
        txs.retain(|t| t.block_number.is_some() && t.transaction_index.is_some());
        if txs.is_empty() {
            return;
        }
        let key = |t: &simple_types::Transaction| {
            (
                u64::from(t.block_number.unwrap()),
                u64::from(t.transaction_index.unwrap()) as u32,
            )
        };
        let keys = txs.iter().map(key).collect();
        let cols = EvmTxField::VARIANTS
            .iter()
            .map(|&f| evm_tx_col(f, &txs))
            .collect();
        self.inner.lock().unwrap().txs.merge_batch(keys, cols);
    }

    /// Merge one response's SVM transactions into the table, keyed by
    /// (slot, transactionIndex). Not exposed to JS.
    pub(crate) fn insert_svm_txs(&self, txs: Vec<solana_simple::Transaction>) {
        if txs.is_empty() {
            return;
        }
        // A transaction row without its key has nothing to merge under; the
        // query always selects both, so this only drops a malformed row.
        let txs: Vec<_> = txs
            .into_iter()
            .filter(|t| t.slot.is_some() && t.transaction_index.is_some())
            .collect();
        if txs.is_empty() {
            return;
        }
        let keys = txs
            .iter()
            .map(|t| (t.slot.unwrap(), t.transaction_index.unwrap()))
            .collect();
        let cols = SvmTxField::VARIANTS
            .iter()
            .map(|&f| svm_tx_col(f, &txs))
            .collect();
        self.inner.lock().unwrap().txs.merge_batch(keys, cols);
    }

    /// Merge one response's SVM account activity into the companion table,
    /// keyed by (slot, transactionIndex, account). Rows missing any key part
    /// are dropped; the SVM query forces `account` into the field selection
    /// whenever account activity is requested, so a real response row always
    /// carries one. Not exposed to JS.
    pub(crate) fn insert_svm_account_activity(
        &self,
        mut rows: Vec<solana_simple::AccountActivity>,
    ) {
        rows.retain(|r| r.slot.is_some() && r.transaction_index.is_some() && r.account.is_some());
        if rows.is_empty() {
            return;
        }
        let pubkey_col =
            |f: fn(&solana_simple::AccountActivity) -> Option<String>| -> Option<AnyCol> {
                let values: Vec<Option<String>> = rows.iter().map(f).collect();
                crate::field_table::var_from(&values, |v| v.as_deref().map(str::as_bytes))
            };
        let u64_col = |f: fn(&solana_simple::AccountActivity) -> Option<u64>| {
            crate::field_table::u64_from(&rows, f)
        };
        let mut cols: Vec<Option<AnyCol>> = (0..ACCOUNT_ACTIVITY_FIELDS).map(|_| None).collect();
        cols[AA_MINT] = pubkey_col(|r| r.mint.map(|mint| mint.to_string()));
        // The wire splits the owner so an in-transaction `SetAuthority` stays
        // visible; the payload carries the owner the account ended with, falling
        // back to the one it entered with when the account was closed during the
        // transaction.
        cols[AA_OWNER] =
            pubkey_col(|r| r.post_owner.or(r.pre_owner).map(|owner| owner.to_string()));
        cols[AA_DECIMALS] =
            crate::field_table::u64_from(&rows, |r| r.token_decimals.map(u64::from));
        cols[AA_PRE_AMOUNT] = u64_col(|r| r.pre_token_balance);
        cols[AA_POST_AMOUNT] = u64_col(|r| r.post_token_balance);
        cols[AA_PRE_LAMPORTS] = u64_col(|r| r.pre_balance);
        cols[AA_POST_LAMPORTS] = u64_col(|r| r.post_balance);
        cols[AA_ACCOUNT_INDEX] = u64_col(|r| r.account_index.map(u64::from));
        cols[AA_IS_SIGNER] = crate::field_table::bool_from(&rows, |r| r.is_signer);
        cols[AA_IS_WRITABLE] = crate::field_table::bool_from(&rows, |r| r.is_writable);
        let keys = rows
            .into_iter()
            .map(|r| {
                (
                    r.slot.unwrap(),
                    r.transaction_index.unwrap(),
                    r.account.unwrap().to_string().into_boxed_str(),
                )
            })
            .collect();
        self.inner
            .lock()
            .unwrap()
            .account_activity
            .merge_batch(keys, cols);
    }
}

/// Ordered EVM transaction-field names — the single source of truth the ReScript
/// `Evm.res transactionFields` array is tested against. The order is the bit
/// position in the selection mask, so the two must not drift.
#[napi]
pub fn evm_transaction_field_names() -> Vec<String> {
    field_names(EvmTxField::VARIANTS, EvmTxField::name)
}

/// Ordered SVM transaction-field names; `Svm.res transactionFields` is tested
/// against this.
#[napi]
pub fn svm_transaction_field_names() -> Vec<String> {
    field_names(SvmTxField::VARIANTS, SvmTxField::name)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw_tx(block: u64, index: u64) -> simple_types::Transaction {
        simple_types::Transaction {
            block_number: Some(block.into()),
            transaction_index: Some(index.into()),
            ..Default::default()
        }
    }

    fn raw_svm_tx(slot: u64, index: u32) -> solana_simple::Transaction {
        solana_simple::Transaction {
            slot: Some(slot),
            transaction_index: Some(index),
            ..Default::default()
        }
    }

    /// Deterministic 32-byte pubkey; the client hands them over as bytes, so a
    /// test value has to be a real key rather than a readable label.
    fn svm_key(tag: u8) -> solana_simple::Address {
        solana_simple::Address([tag; 32])
    }

    use crate::field_columns::test_support::column;

    fn bit(field: EvmTxField) -> u64 {
        1u64 << (field as u32)
    }

    fn svm_mask(field: SvmTxField) -> f64 {
        (1u64 << (field as u32)) as f64
    }

    type TokenView = (String, Option<String>, Option<u8>, Option<u64>, Option<u64>);
    type ActivityView = (
        String,
        Option<i64>,
        Option<bool>,
        Option<bool>,
        Option<(Option<u64>, Option<u64>)>,
        Option<TokenView>,
    );

    fn activity_views(cols: &Columns) -> Vec<Option<Vec<ActivityView>>> {
        let amount = |v: &Option<BigInt>| v.as_ref().map(|b| b.clone().get_u64().1);
        match column(cols, "accountActivities") {
            Some(Column::AccountActivities(rows)) => rows
                .iter()
                .map(|row| {
                    row.as_ref().map(|activities| {
                        activities
                            .iter()
                            .map(|a| {
                                (
                                    a.address.clone(),
                                    a.transaction_account_index,
                                    a.is_signer,
                                    a.is_writable,
                                    a.lamports
                                        .as_ref()
                                        .map(|l| (amount(&l.pre), amount(&l.post))),
                                    a.token.as_ref().map(|t| {
                                        (
                                            t.mint.clone(),
                                            t.owner.clone(),
                                            t.decimals,
                                            amount(&t.pre_amount),
                                            amount(&t.post_amount),
                                        )
                                    }),
                                )
                            })
                            .collect()
                    })
                })
                .collect(),
            other => panic!(
                "expected accountActivities column, got present={}",
                other.is_some()
            ),
        }
    }

    // `materialize` uses `block_in_place`, which needs a multi-thread runtime.
    #[tokio::test(flavor = "multi_thread")]
    async fn decode_selected_only_materialises_masked_fields() {
        let store = TransactionStore::new_evm(false);
        let mut tx = raw_tx(1, 0);
        tx.input = Some(hypersync_client::format::Data::from(
            vec![0xab, 0xcd].into_boxed_slice(),
        ));
        store.insert_evm_txs(vec![tx]);

        // Select only `input` via the bitmask.
        let mask = bit(EvmTxField::Input) as f64;
        let cols = store
            .materialize(vec![1], vec![0], vec![mask])
            .await
            .expect("materialize");

        let summary = (
            match column(&cols, "input") {
                Some(Column::Str(v)) => v.clone(),
                _ => panic!("expected input column"),
            },
            column(&cols, "transactionIndex").is_some(),
            column(&cols, "gas").is_some(),
        );
        assert_eq!(summary, (vec![Some("0xabcd".to_string())], false, false));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn decode_applies_each_rows_own_mask() {
        // Row 0 selects `input`; row 1 selects only `transactionIndex`. The union
        // builds both columns, but each field is present only on its row.
        let store = TransactionStore::new_evm(false);
        let mut tx0 = raw_tx(1, 0);
        tx0.input = Some(hypersync_client::format::Data::from(
            vec![0xab, 0xcd].into_boxed_slice(),
        ));
        let mut tx1 = raw_tx(1, 1);
        tx1.input = Some(hypersync_client::format::Data::from(
            vec![0xee].into_boxed_slice(),
        ));
        store.insert_evm_txs(vec![tx0, tx1]);

        let cols = store
            .materialize(
                vec![1, 1],
                vec![0, 1],
                vec![
                    bit(EvmTxField::Input) as f64,
                    bit(EvmTxField::TransactionIndex) as f64,
                ],
            )
            .await
            .expect("materialize");

        let summary = (
            match column(&cols, "input") {
                Some(Column::Str(v)) => v.clone(),
                _ => panic!("expected input column"),
            },
            match column(&cols, "transactionIndex") {
                Some(Column::I64(v)) => v.clone(),
                _ => panic!("expected transactionIndex column"),
            },
        );
        assert_eq!(
            summary,
            (vec![Some("0xabcd".to_string()), None], vec![None, Some(1)])
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn evm_transaction_index_comes_from_key_even_on_miss() {
        // A missing row still materialises the requested key as
        // `transactionIndex`, so it never depends on a fetched transaction row.
        let store = TransactionStore::new_evm(false);
        store.insert_evm_txs(vec![raw_tx(1, 3)]);

        let mask = bit(EvmTxField::TransactionIndex) as f64;
        let cols = store
            .materialize(vec![9, 1], vec![7, 3], vec![mask, mask])
            .await
            .expect("materialize");
        match column(&cols, "transactionIndex") {
            Some(Column::I64(v)) => assert_eq!(v, &vec![Some(7), Some(3)]),
            other => panic!(
                "expected transactionIndex i64 column, got present={}",
                other.is_some()
            ),
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn svm_decode_selected_only_materialises_masked_fields() {
        let store = TransactionStore::new_svm();
        let mut tx = raw_svm_tx(5, 0);
        tx.account_keys = Some(vec![svm_key(1), svm_key(2)]);
        tx.fee = Some(5000);
        tx.signatures = Some(vec![solana_simple::Signature([9; 64])]);
        store.insert_svm_txs(vec![tx]);

        // Select only accountKeys.
        let mask = (1u64 << (SvmTxField::AccountKeys as u32)) as f64;
        let cols = store
            .materialize(vec![5], vec![0], vec![mask])
            .await
            .expect("materialize");

        let summary = (
            match column(&cols, "accountKeys") {
                Some(Column::StrVec(v)) => v.clone(),
                _ => panic!("expected accountKeys column"),
            },
            column(&cols, "fee").is_some(),
            column(&cols, "signatures").is_some(),
        );
        assert_eq!(
            summary,
            (
                vec![Some(vec![svm_key(1).to_string(), svm_key(2).to_string()])],
                false,
                false
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn account_activities_gather_by_key_range_and_index_order() {
        let store = TransactionStore::new_svm();
        store.insert_svm_txs(vec![raw_svm_tx(5, 0)]);
        let row = |account: u8, index: u32, mint: Option<u8>| solana_simple::AccountActivity {
            slot: Some(5),
            transaction_index: Some(0),
            account: Some(svm_key(account)),
            account_index: Some(index),
            mint: mint.map(svm_key),
            ..Default::default()
        };
        store.insert_svm_account_activity(vec![
            row(3, 2, Some(0xA3)),
            row(1, 0, None),
            row(2, 1, Some(0xA2)),
        ]);
        let mut other_tx = row(9, 0, Some(0xA9));
        other_tx.slot = Some(5);
        other_tx.transaction_index = Some(1);
        store.insert_svm_account_activity(vec![other_tx]);

        let mask = svm_mask(SvmTxField::AccountActivities);
        let cols = store
            .materialize(vec![5, 5, 5], vec![0, 1, 2], vec![mask, mask, mask])
            .await
            .expect("materialize");

        let addresses = activity_views(&cols)
            .into_iter()
            .map(|row| {
                row.map(|acts| {
                    acts.into_iter()
                        .map(|(address, index, _, _, _, _)| (address, index))
                        .collect::<Vec<_>>()
                })
            })
            .collect::<Vec<_>>();
        assert_eq!(
            addresses,
            vec![
                Some(vec![
                    (svm_key(1).to_string(), Some(0)),
                    (svm_key(2).to_string(), Some(1)),
                    (svm_key(3).to_string(), Some(2)),
                ]),
                Some(vec![(svm_key(9).to_string(), Some(0))]),
                Some(vec![]),
            ]
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn account_activity_nested_sides_and_open_close() {
        let store = TransactionStore::new_svm();
        store.insert_svm_txs(vec![raw_svm_tx(5, 0)]);
        store.insert_svm_account_activity(vec![
            solana_simple::AccountActivity {
                slot: Some(5),
                transaction_index: Some(0),
                account: Some(svm_key(1)),
                account_index: Some(0),
                is_signer: Some(true),
                is_writable: Some(true),
                pre_balance: Some(1_000_000),
                post_balance: Some(900_000),
                ..Default::default()
            },
            solana_simple::AccountActivity {
                slot: Some(5),
                transaction_index: Some(0),
                account: Some(svm_key(2)),
                account_index: Some(1),
                is_signer: Some(false),
                is_writable: Some(true),
                mint: Some(svm_key(0xA1)),
                post_owner: Some(svm_key(0xB1)),
                token_decimals: Some(6),
                post_token_balance: Some(500),
                ..Default::default()
            },
            solana_simple::AccountActivity {
                slot: Some(5),
                transaction_index: Some(0),
                account: Some(svm_key(3)),
                account_index: Some(2),
                is_signer: Some(false),
                is_writable: Some(true),
                mint: Some(svm_key(0xA2)),
                pre_owner: Some(svm_key(0xB2)),
                post_owner: Some(svm_key(0xB3)),
                token_decimals: Some(9),
                pre_token_balance: Some(700),
                post_token_balance: Some(u64::MAX),
                ..Default::default()
            },
        ]);

        let cols = store
            .materialize(
                vec![5],
                vec![0],
                vec![svm_mask(SvmTxField::AccountActivities)],
            )
            .await
            .expect("materialize");

        assert_eq!(
            activity_views(&cols),
            vec![Some(vec![
                (
                    svm_key(1).to_string(),
                    Some(0),
                    Some(true),
                    Some(true),
                    Some((Some(1_000_000), Some(900_000))),
                    None,
                ),
                (
                    svm_key(2).to_string(),
                    Some(1),
                    Some(false),
                    Some(true),
                    None,
                    Some((
                        svm_key(0xA1).to_string(),
                        Some(svm_key(0xB1).to_string()),
                        Some(6),
                        None,
                        Some(500)
                    )),
                ),
                (
                    svm_key(3).to_string(),
                    Some(2),
                    Some(false),
                    Some(true),
                    None,
                    Some((
                        svm_key(0xA2).to_string(),
                        Some(svm_key(0xB3).to_string()),
                        Some(9),
                        Some(700),
                        Some(u64::MAX)
                    )),
                ),
            ])]
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn account_activities_of_a_missing_transaction_is_empty() {
        let store = TransactionStore::new_svm();
        let cols = store
            .materialize(
                vec![5],
                vec![0],
                vec![svm_mask(SvmTxField::AccountActivities)],
            )
            .await
            .expect("materialize");
        assert_eq!(activity_views(&cols), vec![Some(vec![])]);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn prune_and_rollback_drop_by_block() {
        let store = TransactionStore::new_evm(false);
        let txs = [10u64, 20, 30]
            .into_iter()
            .map(|block| {
                let mut tx = raw_tx(block, 0);
                tx.nonce = Some(hypersync_client::format::Quantity::from(block));
                tx
            })
            .collect();
        store.insert_evm_txs(txs);

        let mask = bit(EvmTxField::Nonce) as f64;
        store.prune(10);
        let after_prune = store
            .materialize(vec![10, 20, 30], vec![0, 0, 0], vec![mask, mask, mask])
            .await
            .expect("materialize");
        store.rollback(20);
        let after_rollback = store
            .materialize(vec![10, 20, 30], vec![0, 0, 0], vec![mask, mask, mask])
            .await
            .expect("materialize");

        let nonces = |cols: &Columns| match column(cols, "nonce") {
            Some(Column::Big(v)) => v.iter().map(|c| c.is_some()).collect::<Vec<_>>(),
            _ => panic!("expected nonce column"),
        };
        assert_eq!(
            (nonces(&after_prune), nonces(&after_rollback)),
            (vec![false, true, true], vec![false, true, false])
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn merge_resolves_re_fetched_transaction_to_newest() {
        // The same (block, index) is re-fetched with a different `input` (an
        // overlapping-partition or reorg re-fetch): the persistent store must
        // resolve to the fresh copy, not accumulate both.
        let persistent = TransactionStore::new_evm(false);

        let page1 = TransactionStore::new_evm(false);
        let mut first = raw_tx(1, 0);
        first.input = Some(hypersync_client::format::Data::from(
            vec![0xaa].into_boxed_slice(),
        ));
        page1.insert_evm_txs(vec![first]);
        persistent.merge(&page1);

        let page2 = TransactionStore::new_evm(false);
        let mut second = raw_tx(1, 0);
        second.input = Some(hypersync_client::format::Data::from(
            vec![0xbb].into_boxed_slice(),
        ));
        page2.insert_evm_txs(vec![second]);
        persistent.merge(&page2);

        let mask = bit(EvmTxField::Input) as f64;
        let cols = persistent
            .materialize(vec![1], vec![0], vec![mask])
            .await
            .expect("materialize");
        match column(&cols, "input") {
            Some(Column::Str(v)) => assert_eq!(v, &vec![Some("0xbb".to_string())]),
            other => panic!("expected input column, got present={}", other.is_some()),
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
                "signature",
                "feePayer",
                "success",
                "err",
                "fee",
                "computeUnitsConsumed",
                "accountKeys",
                "recentBlockhash",
                "version",
                "allSignatures",
                "accountActivities",
            ]
        );
    }
}
