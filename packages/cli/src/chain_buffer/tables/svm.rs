//! SVM tables: instructions, transactions and blocks, what fills them from a
//! source's rows, and how their cells read back as the fields handlers select.
//! An instruction's program logs and a transaction's account activity ride on
//! their rows as encoded cells, expanded when delivered.

use alloy_primitives::U256;
use anyhow::{Context, Result};
use hypersync_client_solana::simple_types as simple;
use serde::{Deserialize, Serialize};
use strum::VariantArray;

use super::table::{make_key, ChunkBuilder, ColumnKind, RowRef, Schema, MAX_POSITION};
use crate::chain_buffer::deliver::{
    build_columns, cells, utf8, Column, Columns, SvmAccountActivityOut, SvmAccountTokenOut,
    SvmLamportsOut,
};
use crate::svm::types::bigint_u64;

pub(crate) mod instruction_column {
    /// The program's id, base58: the bytes the address store keys it by.
    pub(crate) const PROGRAM_ID: usize = 0;
    /// Its account arguments, base58; null when the query didn't read them.
    pub(crate) const ACCOUNTS: usize = 1;
    pub(crate) const DATA: usize = 2;
    pub(crate) const IS_INNER: usize = 3;
    /// The logs it emitted as `(kind, message)` pairs; null when the query
    /// didn't read logs.
    pub(crate) const LOGS: usize = 4;
}

pub(crate) fn instructions_schema() -> Schema {
    Schema {
        columns: vec![
            ColumnKind::Var,
            ColumnKind::Var,
            ColumnKind::Var,
            ColumnKind::U32,
            ColumnKind::Var,
        ],
        has_tiebreak: true,
        has_fetched: false,
    }
}

const PATH_LEVELS: usize = 5;
const PATH_STEP_BITS: u32 = 12;

/// An instruction's place in its transaction's call tree as one word that
/// sorts like the path: each step plus one, so a parent sorts before its
/// children.
pub(crate) fn encode_path(path: &[u32]) -> Result<u64> {
    anyhow::ensure!(
        path.len() <= PATH_LEVELS,
        "instruction path {path:?} is deeper than {PATH_LEVELS} levels"
    );
    let mut word = 0u64;
    for (level, step) in path.iter().enumerate() {
        let step = u64::from(*step) + 1;
        anyhow::ensure!(
            step < 1 << PATH_STEP_BITS,
            "instruction path {path:?} has a step past {}",
            (1 << PATH_STEP_BITS) - 2
        );
        word |= step << (PATH_STEP_BITS * (PATH_LEVELS - 1 - level) as u32);
    }
    Ok(word)
}

pub(crate) fn decode_path(mut word: u64) -> Vec<i64> {
    let mut path = Vec::new();
    for level in 0..PATH_LEVELS {
        let shift = PATH_STEP_BITS * (PATH_LEVELS - 1 - level) as u32;
        let step = (word >> shift) & ((1 << PATH_STEP_BITS) - 1);
        if step == 0 {
            break;
        }
        path.push(step as i64 - 1);
        word &= !(((1 << PATH_STEP_BITS) - 1) << shift);
    }
    path
}

pub(crate) fn encode_strings<S: AsRef<str>>(values: &[S]) -> Vec<u8> {
    let mut bytes = Vec::new();
    for value in values {
        let value = value.as_ref().as_bytes();
        bytes.extend_from_slice(&(value.len() as u32).to_le_bytes());
        bytes.extend_from_slice(value);
    }
    bytes
}

pub(crate) fn decode_strings(mut bytes: &[u8]) -> Vec<String> {
    let mut values = Vec::new();
    while bytes.len() >= 4 {
        let len = u32::from_le_bytes(bytes[..4].try_into().unwrap()) as usize;
        let end = (4 + len).min(bytes.len());
        values.push(utf8(&bytes[4..end]));
        bytes = &bytes[end..];
    }
    values
}

/// An instruction call as the buffer keeps it.
pub(crate) struct InstructionRow<'a> {
    pub(crate) slot: u64,
    pub(crate) transaction_index: u32,
    pub(crate) path: &'a [u32],
    pub(crate) program_id: &'a str,
    pub(crate) accounts: Option<&'a [String]>,
    pub(crate) data: &'a [u8],
    pub(crate) is_inner: bool,
    /// `(kind, message)` pairs.
    pub(crate) logs: Option<&'a [(String, String)]>,
}

pub(crate) fn push_instruction(builder: &mut ChunkBuilder, row: &InstructionRow) -> Result<()> {
    anyhow::ensure!(
        u64::from(row.transaction_index) <= MAX_POSITION,
        "transaction index {} is past what the buffer keys hold",
        row.transaction_index
    );
    builder.push_row(
        make_key(row.slot, u64::from(row.transaction_index)),
        encode_path(row.path)?,
        0,
    );
    builder.set_bytes(instruction_column::PROGRAM_ID, row.program_id.as_bytes());
    if let Some(accounts) = row.accounts {
        builder.set_bytes(instruction_column::ACCOUNTS, &encode_strings(accounts));
    }
    builder.set_bytes(instruction_column::DATA, row.data);
    builder.set_u64(instruction_column::IS_INNER, u64::from(row.is_inner));
    if let Some(logs) = row.logs {
        let flat: Vec<&str> = logs
            .iter()
            .flat_map(|(kind, message)| [kind.as_str(), message.as_str()])
            .collect();
        builder.set_bytes(instruction_column::LOGS, &encode_strings(&flat));
    }
    Ok(())
}

/// An instruction row's fields as matching and decoding read them.
pub(crate) struct InstructionView<'a> {
    pub(crate) slot: u64,
    pub(crate) transaction_index: u32,
    pub(crate) path: u64,
    pub(crate) program_id: &'a str,
    pub(crate) accounts: Vec<String>,
    pub(crate) data: &'a [u8],
    pub(crate) is_inner: bool,
    pub(crate) logs: Option<Vec<(String, String)>>,
}

impl<'a> InstructionView<'a> {
    pub(crate) fn of_row(row: &RowRef<'a>) -> Option<InstructionView<'a>> {
        let row = *row;
        Some(InstructionView {
            slot: row.block_number(),
            transaction_index: row.position() as u32,
            path: row.tiebreak(),
            program_id: std::str::from_utf8(row.bytes_at(instruction_column::PROGRAM_ID)?).ok()?,
            accounts: row
                .bytes_at(instruction_column::ACCOUNTS)
                .map(decode_strings)
                .unwrap_or_default(),
            data: row.bytes_at(instruction_column::DATA).unwrap_or(&[]),
            is_inner: row.u64_at(instruction_column::IS_INNER) == Some(1),
            logs: row.bytes_at(instruction_column::LOGS).map(|bytes| {
                let flat = decode_strings(bytes);
                flat.chunks(2)
                    .map(|pair| (pair[0].clone(), pair.get(1).cloned().unwrap_or_default()))
                    .collect()
            }),
        })
    }
}

/// Block field codes shared with ReScript by ordinal: the order mirrors
/// `Svm.res` `blockFields`, and the ordinal is the field's bit in a selection
/// mask and its column in the blocks table.
#[derive(Clone, Copy, PartialEq, Eq, Debug, VariantArray)]
#[repr(i32)]
pub enum SvmBlockField {
    Slot = 0,
    Time = 1,
    Hash = 2,
    Height = 3,
    ParentSlot = 4,
    ParentHash = 5,
    TransactionCount = 6,
    FailedTransactionCount = 7,
}

impl SvmBlockField {
    /// The fields counting a slot's transactions. No block column a source
    /// returns carries them: a source tallies the slot's transaction rows.
    pub(crate) const TRANSACTION_COUNTS_MASK: u64 = (1 << SvmBlockField::TransactionCount as u32)
        | (1 << SvmBlockField::FailedTransactionCount as u32);

    pub fn name(self) -> &'static str {
        use SvmBlockField::*;
        match self {
            Slot => "slot",
            Time => "time",
            Hash => "hash",
            Height => "height",
            ParentSlot => "parentSlot",
            ParentHash => "parentHash",
            TransactionCount => "transactionCount",
            FailedTransactionCount => "failedTransactionCount",
        }
    }

    fn column_kind(self) -> ColumnKind {
        use SvmBlockField::*;
        match self {
            Hash | ParentHash => ColumnKind::Var,
            _ => ColumnKind::U64,
        }
    }
}

pub(crate) fn blocks_schema() -> Schema {
    Schema {
        columns: SvmBlockField::VARIANTS
            .iter()
            .map(|field| field.column_kind())
            .collect(),
        has_tiebreak: false,
        has_fetched: true,
    }
}

pub(crate) const BLOCK_HASH_COLUMN: usize = SvmBlockField::Hash as usize;
const BLOCK_TIME_COLUMN: usize = SvmBlockField::Time as usize;
const SLOT_BIT: u64 = 1 << SvmBlockField::Slot as u32;

/// How many transactions HyperSync stores for a slot, which leaves out votes,
/// and how many of those failed.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SvmTransactionCounts {
    pub total: u64,
    pub failed: u64,
}

fn present_bit(field: SvmBlockField, present: bool) -> u64 {
    if present {
        1 << field as u32
    } else {
        0
    }
}

/// Appends a HyperSync block, with its slot's transaction counts when the
/// query tallied them. A block without its slot is dropped.
pub(crate) fn push_block(
    builder: &mut ChunkBuilder,
    block: &simple::Block,
    counts: Option<SvmTransactionCounts>,
) {
    use SvmBlockField::*;
    let Some(slot) = block.slot else { return };
    let hash = block.blockhash.map(|hash| hash.to_string());
    let parent_hash = block.parent_blockhash.map(|hash| hash.to_string());
    let fetched = SLOT_BIT
        | present_bit(Time, block.block_time.is_some())
        | present_bit(Hash, hash.is_some())
        | present_bit(Height, block.block_height.is_some())
        | present_bit(ParentSlot, block.parent_slot.is_some())
        | present_bit(ParentHash, parent_hash.is_some())
        | if counts.is_some() {
            SvmBlockField::TRANSACTION_COUNTS_MASK
        } else {
            0
        };
    builder.push_row(make_key(slot, 0), 0, fetched);
    builder.set_optional_u64(Time as usize, block.block_time.map(|time| time as u64));
    builder.set_optional_bytes(Hash as usize, hash.as_deref().map(str::as_bytes));
    builder.set_optional_u64(Height as usize, block.block_height);
    builder.set_optional_u64(ParentSlot as usize, block.parent_slot);
    builder.set_optional_bytes(
        ParentHash as usize,
        parent_hash.as_deref().map(str::as_bytes),
    );
    if let Some(counts) = counts {
        builder.set_u64(TransactionCount as usize, counts.total);
        builder.set_u64(FailedTransactionCount as usize, counts.failed);
    }
}

/// Appends a slot known only by its hash and maybe its time.
pub(crate) fn push_observed_block(
    builder: &mut ChunkBuilder,
    slot: u64,
    hash: Option<&[u8]>,
    time: Option<u64>,
) {
    builder.push_row(
        make_key(slot, 0),
        0,
        SLOT_BIT
            | present_bit(SvmBlockField::Hash, hash.is_some())
            | present_bit(SvmBlockField::Time, time.is_some()),
    );
    builder.set_optional_bytes(BLOCK_HASH_COLUMN, hash);
    builder.set_optional_u64(BLOCK_TIME_COLUMN, time);
}

pub(crate) fn block_timestamp(row: &RowRef) -> Option<i64> {
    row.u64_at(BLOCK_TIME_COLUMN).map(|time| time as i64)
}

/// A hash as JS spells it: the base58 text the column holds.
pub(crate) fn hash_text(bytes: &[u8]) -> String {
    utf8(bytes)
}

pub(crate) fn hash_bytes(text: &str) -> Vec<u8> {
    text.as_bytes().to_vec()
}

fn block_column(
    field: SvmBlockField,
    rows: &[Option<RowRef>],
    numbers: &[u64],
    masks: &[u64],
) -> Result<Column> {
    use SvmBlockField::*;
    let bit = 1u64 << field as u32;
    let column = field as usize;
    Ok(match field {
        Slot => Column::I64(
            numbers
                .iter()
                .zip(masks)
                .map(|(number, mask)| (mask & bit != 0).then_some(*number as i64))
                .collect(),
        ),
        Time => Column::I64(cells(rows, masks, bit, |row| {
            Ok(row.u64_at(column).map(|time| time as i64))
        })?),
        Hash | ParentHash => Column::Str(cells(rows, masks, bit, |row| {
            Ok(row.bytes_at(column).map(utf8))
        })?),
        Height | ParentSlot | TransactionCount | FailedTransactionCount => {
            Column::I64(cells(rows, masks, bit, |row| {
                row.u64_at(column)
                    .map(|value| {
                        i64::try_from(value).with_context(|| format!("{} overflow", field.name()))
                    })
                    .transpose()
            })?)
        }
    })
}

pub(crate) fn block_columns(
    rows: &[Option<RowRef>],
    numbers: &[u64],
    masks: &[u64],
) -> Result<Columns> {
    build_columns(
        SvmBlockField::VARIANTS,
        masks,
        rows.len(),
        |field| field as u32,
        |field| field.name(),
        |field| block_column(field, rows, numbers, masks),
    )
}

/// Transaction field codes shared with ReScript by ordinal: the order mirrors
/// `Svm.res` `transactionFields`, and the ordinal is the field's bit in a
/// selection mask and its column in the transactions table.
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

    fn column_kind(self) -> ColumnKind {
        use SvmTxField::*;
        match self {
            TransactionIndex | Success | Fee | ComputeUnitsConsumed => ColumnKind::U64,
            _ => ColumnKind::Var,
        }
    }
}

pub(crate) fn transactions_schema() -> Schema {
    Schema {
        columns: SvmTxField::VARIANTS
            .iter()
            .map(|field| field.column_kind())
            .collect(),
        has_tiebreak: false,
        has_fetched: true,
    }
}

/// One account a transaction touched, as the transactions table encodes it.
#[derive(Serialize, Deserialize)]
struct StoredActivity {
    address: String,
    account_index: Option<u32>,
    is_signer: Option<bool>,
    is_writable: Option<bool>,
    pre_lamports: Option<u64>,
    post_lamports: Option<u64>,
    mint: Option<String>,
    owner: Option<String>,
    decimals: Option<u8>,
    pre_amount: Option<u64>,
    post_amount: Option<u64>,
}

impl StoredActivity {
    fn of(row: &simple::AccountActivity) -> Option<Self> {
        Some(StoredActivity {
            address: row.account?.to_string(),
            account_index: row.account_index,
            is_signer: row.is_signer,
            is_writable: row.is_writable,
            pre_lamports: row.pre_balance,
            post_lamports: row.post_balance,
            mint: row.mint.map(|mint| mint.to_string()),
            // The wire splits the owner so an in-transaction `SetAuthority`
            // stays visible; the payload carries the owner the account ended
            // with, falling back to the one it entered with when the account
            // was closed during the transaction.
            owner: row
                .post_owner
                .or(row.pre_owner)
                .map(|owner| owner.to_string()),
            decimals: row.token_decimals,
            pre_amount: row.pre_token_balance,
            post_amount: row.post_token_balance,
        })
    }

    fn into_out(self) -> SvmAccountActivityOut {
        let lamports = match (self.pre_lamports, self.post_lamports) {
            (None, None) => None,
            (pre, post) => Some(SvmLamportsOut {
                pre: pre.map(bigint_u64),
                post: post.map(bigint_u64),
            }),
        };
        SvmAccountActivityOut {
            address: self.address,
            transaction_account_index: self.account_index.map(i64::from),
            is_signer: self.is_signer,
            is_writable: self.is_writable,
            lamports,
            // The mint is what makes an activity a token one.
            token: self.mint.map(|mint| SvmAccountTokenOut {
                mint,
                owner: self.owner,
                decimals: self.decimals,
                pre_amount: self.pre_amount.map(bigint_u64),
                post_amount: self.post_amount.map(bigint_u64),
            }),
        }
    }
}

/// Appends a HyperSync transaction with the accounts it touched, ordered by
/// their place in the transaction's key list; `activities` is `None` when the
/// query didn't read account activity. A transaction without its key is
/// dropped.
pub(crate) fn push_transaction(
    builder: &mut ChunkBuilder,
    transaction: &simple::Transaction,
    activities: Option<&[&simple::AccountActivity]>,
) -> Result<()> {
    use SvmTxField::*;
    let (Some(slot), Some(index)) = (transaction.slot, transaction.transaction_index) else {
        return Ok(());
    };
    let t = transaction;
    // Solana's own account-resolution order: static keys, then the lookup
    // tables' writable then readonly addresses. A transaction's account
    // indexes address this resolved list.
    let key_parts = [
        t.account_keys.as_ref(),
        t.loaded_addresses_writable.as_ref(),
        t.loaded_addresses_readonly.as_ref(),
    ];
    let account_keys: Option<Vec<String>> = key_parts.iter().any(Option::is_some).then(|| {
        key_parts
            .into_iter()
            .flatten()
            .flatten()
            .map(|key| key.to_string())
            .collect()
    });
    let signature = t.transaction_id.map(|value| value.to_string());
    let all_signatures: Option<Vec<String>> = t
        .signatures
        .as_ref()
        .map(|values| values.iter().map(|value| value.to_string()).collect());
    let fee_payer = t.fee_payer.map(|value| value.to_string());
    let recent_blockhash = t.recent_blockhash.map(|value| value.to_string());
    let activities = activities
        .map(|rows| {
            let mut stored: Vec<StoredActivity> = rows
                .iter()
                .filter_map(|row| StoredActivity::of(row))
                .collect();
            stored.sort_by(|a, b| {
                a.account_index
                    .unwrap_or(u32::MAX)
                    .cmp(&b.account_index.unwrap_or(u32::MAX))
                    .then_with(|| a.address.cmp(&b.address))
            });
            serde_json::to_vec(&stored).context("encode account activity")
        })
        .transpose()?;
    let bit = |field: SvmTxField, present: bool| present_tx_bit(field, present);
    let fetched = bit(TransactionIndex, true)
        | bit(Signature, signature.is_some())
        | bit(FeePayer, fee_payer.is_some())
        | bit(Success, t.success.is_some())
        | bit(Err, t.err.is_some())
        | bit(Fee, t.fee.is_some())
        | bit(ComputeUnitsConsumed, t.compute_units_consumed.is_some())
        | bit(AccountKeys, account_keys.is_some())
        | bit(RecentBlockhash, recent_blockhash.is_some())
        | bit(Version, t.version.is_some())
        | bit(AllSignatures, all_signatures.is_some())
        | bit(AccountActivities, activities.is_some());
    builder.push_row(make_key(slot, u64::from(index)), 0, fetched);
    builder.set_optional_bytes(Signature as usize, signature.as_deref().map(str::as_bytes));
    builder.set_optional_bytes(FeePayer as usize, fee_payer.as_deref().map(str::as_bytes));
    builder.set_optional_u64(Success as usize, t.success.map(u64::from));
    builder.set_optional_bytes(Err as usize, t.err.as_deref().map(str::as_bytes));
    builder.set_optional_u64(Fee as usize, t.fee);
    builder.set_optional_u64(ComputeUnitsConsumed as usize, t.compute_units_consumed);
    if let Some(keys) = &account_keys {
        builder.set_bytes(AccountKeys as usize, &encode_strings(keys));
    }
    builder.set_optional_bytes(
        RecentBlockhash as usize,
        recent_blockhash.as_deref().map(str::as_bytes),
    );
    builder.set_optional_bytes(Version as usize, t.version.as_deref().map(str::as_bytes));
    if let Some(signatures) = &all_signatures {
        builder.set_bytes(AllSignatures as usize, &encode_strings(signatures));
    }
    builder.set_optional_bytes(AccountActivities as usize, activities.as_deref());
    Ok(())
}

fn present_tx_bit(field: SvmTxField, present: bool) -> u64 {
    if present {
        1 << field as u32
    } else {
        0
    }
}

fn transaction_column(
    field: SvmTxField,
    rows: &[Option<RowRef>],
    indexes: &[u32],
    masks: &[u64],
) -> Result<Column> {
    use SvmTxField::*;
    let bit = 1u64 << field as u32;
    let column = field as usize;
    Ok(match field {
        TransactionIndex => Column::I64(
            indexes
                .iter()
                .zip(masks)
                .map(|(index, mask)| (mask & bit != 0).then_some(*index as i64))
                .collect(),
        ),
        AllSignatures | AccountKeys => Column::StrVec(cells(rows, masks, bit, |row| {
            Ok(row.bytes_at(column).map(decode_strings))
        })?),
        Signature | FeePayer | Err | RecentBlockhash | Version => {
            Column::Str(cells(rows, masks, bit, |row| {
                Ok(row.bytes_at(column).map(utf8))
            })?)
        }
        Success => Column::Bool(cells(rows, masks, bit, |row| {
            Ok(row.u64_at(column).map(|value| value == 1))
        })?),
        Fee | ComputeUnitsConsumed => Column::Big(cells(rows, masks, bit, |row| {
            Ok(row.u64_at(column).map(U256::from))
        })?),
        // Selected, the field is a list even where nothing moved or the
        // transaction isn't held.
        AccountActivities => Column::AccountActivities(
            rows.iter()
                .zip(masks)
                .map(|(row, mask)| {
                    if mask & bit == 0 {
                        return Ok(None);
                    }
                    let Some(bytes) = row.as_ref().and_then(|row| row.bytes_at(column)) else {
                        return Ok(Some(Vec::new()));
                    };
                    let stored: Vec<StoredActivity> =
                        serde_json::from_slice(bytes).context("decode account activity")?;
                    Ok(Some(
                        stored.into_iter().map(StoredActivity::into_out).collect(),
                    ))
                })
                .collect::<Result<Vec<_>>>()?,
        ),
    })
}

pub(crate) fn transaction_columns(
    rows: &[Option<RowRef>],
    indexes: &[u32],
    masks: &[u64],
) -> Result<Columns> {
    build_columns(
        SvmTxField::VARIANTS,
        masks,
        rows.len(),
        |field| field as u32,
        |field| field.name(),
        |field| transaction_column(field, rows, indexes, masks),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_path_word_sorts_parents_before_children_and_reads_back() {
        let paths: [&[u32]; 5] = [&[0], &[0, 0], &[0, 1], &[1], &[1, 0, 4094]];
        let words: Vec<u64> = paths
            .iter()
            .map(|path| encode_path(path).unwrap())
            .collect();
        let read: Vec<Vec<i64>> = words.iter().map(|word| decode_path(*word)).collect();
        assert_eq!(
            (
                words.windows(2).all(|pair| pair[0] < pair[1]),
                read,
                encode_path(&[4095]).is_err(),
                encode_path(&[0, 0, 0, 0, 0, 0]).is_err(),
            ),
            (
                true,
                vec![vec![0], vec![0, 0], vec![0, 1], vec![1], vec![1, 0, 4094]],
                true,
                true
            )
        );
    }
}

/// A simulated SVM transaction, as a test describes it.
#[napi_derive::napi(object)]
pub struct SvmTxInput {
    pub slot: i64,
    pub transaction_index: u32,
    pub signature: Option<String>,
    pub all_signatures: Option<Vec<String>>,
    pub fee_payer: Option<String>,
    pub success: Option<bool>,
    pub err: Option<String>,
    pub fee: Option<napi::bindgen_prelude::BigInt>,
    pub compute_units_consumed: Option<napi::bindgen_prelude::BigInt>,
    pub account_keys: Option<Vec<String>>,
    pub recent_blockhash: Option<String>,
    pub version: Option<String>,
}

/// One account a simulated SVM transaction touched.
#[napi_derive::napi(object)]
pub struct SvmActivityInput {
    pub slot: i64,
    pub transaction_index: u32,
    pub account: String,
    pub account_index: Option<u32>,
    pub is_signer: Option<bool>,
    pub is_writable: Option<bool>,
    pub pre_balance: Option<napi::bindgen_prelude::BigInt>,
    pub post_balance: Option<napi::bindgen_prelude::BigInt>,
    pub mint: Option<String>,
    pub owner: Option<String>,
    pub decimals: Option<u8>,
    pub pre_amount: Option<napi::bindgen_prelude::BigInt>,
    pub post_amount: Option<napi::bindgen_prelude::BigInt>,
}

fn base58<T: std::str::FromStr>(value: Option<&str>, field: &str) -> Result<Option<T>>
where
    T::Err: std::fmt::Display,
{
    value
        .map(|value| {
            value
                .parse::<T>()
                .map_err(|e| anyhow::anyhow!("{field} {value:?} is not valid base58: {e}"))
        })
        .transpose()
}

fn base58_list<T: std::str::FromStr>(
    values: Option<&[String]>,
    field: &str,
) -> Result<Option<Vec<T>>>
where
    T::Err: std::fmt::Display,
{
    values
        .map(|values| {
            values
                .iter()
                .map(|value| base58(Some(value), field).map(Option::unwrap))
                .collect()
        })
        .transpose()
}

fn simulated_u64(value: Option<napi::bindgen_prelude::BigInt>, field: &str) -> Result<Option<u64>> {
    value
        .map(|value| {
            anyhow::ensure!(!value.sign_bit, "{field} must be non-negative");
            match value.words.as_slice() {
                [] => Ok(0),
                [word] => Ok(*word),
                _ => anyhow::bail!("{field} does not fit in u64"),
            }
        })
        .transpose()
}

fn slot_of(slot: i64) -> Result<u64> {
    u64::try_from(slot).map_err(|_| anyhow::anyhow!("slot must be non-negative"))
}

/// Simulated transactions with the accounts they touched, through the same
/// row fill as fetched ones.
pub(crate) fn push_simulated_transactions(
    builder: &mut ChunkBuilder,
    transactions: Vec<SvmTxInput>,
    activities: Vec<SvmActivityInput>,
) -> Result<()> {
    let activities = activities
        .into_iter()
        .map(|a| {
            Ok(simple::AccountActivity {
                slot: Some(slot_of(a.slot)?),
                transaction_index: Some(a.transaction_index),
                account: base58(Some(&a.account), "account")?,
                account_index: a.account_index,
                is_signer: a.is_signer,
                is_writable: a.is_writable,
                pre_balance: simulated_u64(a.pre_balance, "preBalance")?,
                post_balance: simulated_u64(a.post_balance, "postBalance")?,
                mint: base58(a.mint.as_deref(), "mint")?,
                pre_owner: base58(a.owner.as_deref(), "owner")?,
                post_owner: base58(a.owner.as_deref(), "owner")?,
                token_decimals: a.decimals,
                pre_token_balance: simulated_u64(a.pre_amount, "preAmount")?,
                post_token_balance: simulated_u64(a.post_amount, "postAmount")?,
                ..Default::default()
            })
        })
        .collect::<Result<Vec<_>>>()?;
    for t in transactions {
        let transaction = simple::Transaction {
            slot: Some(slot_of(t.slot)?),
            transaction_index: Some(t.transaction_index),
            transaction_id: base58(t.signature.as_deref(), "signature")?,
            signatures: base58_list(t.all_signatures.as_deref(), "allSignatures")?,
            fee_payer: base58(t.fee_payer.as_deref(), "feePayer")?,
            success: t.success,
            err: t.err,
            fee: simulated_u64(t.fee, "fee")?,
            compute_units_consumed: simulated_u64(
                t.compute_units_consumed,
                "computeUnitsConsumed",
            )?,
            account_keys: base58_list(t.account_keys.as_deref(), "accountKeys")?,
            recent_blockhash: base58(t.recent_blockhash.as_deref(), "recentBlockhash")?,
            version: t.version,
            ..Default::default()
        };
        let touched: Vec<&simple::AccountActivity> = activities
            .iter()
            .filter(|activity| {
                activity.slot == transaction.slot
                    && activity.transaction_index == transaction.transaction_index
            })
            .collect();
        push_transaction(builder, &transaction, Some(&touched))?;
    }
    Ok(())
}
