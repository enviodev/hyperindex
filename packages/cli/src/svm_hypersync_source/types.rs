use anyhow::{anyhow, Context, Result};
use hypersync_client_solana::simple_types as simple;
use napi::bindgen_prelude::BigInt;
use napi_derive::napi;

use super::decode::DecodedInstructionJson;

/// Lean per-slot block header the response carries to ReScript, used for reorg
/// detection and each item's slot/time. Selectable fields (height, parents) are
/// kept raw in the `BlockStore` and materialised on demand, so they aren't
/// duplicated here.
#[napi(object)]
#[derive(Default, Clone)]
pub struct Block {
    pub slot: i64,
    pub blockhash: String,
    pub block_time: Option<i64>,
}

/// Owned, base58-decoded SVM block row retained in the `BlockStore`. Upstream
/// responses carry byte newtypes behind `Option`s; converting once here keeps
/// the store's column builders borrowing plain strings.
#[derive(Default, Clone)]
pub struct SvmBlockRow {
    pub slot: u64,
    pub blockhash: String,
    pub block_time: Option<i64>,
    pub block_height: Option<u64>,
    pub parent_slot: Option<u64>,
    pub parent_blockhash: Option<String>,
}

impl TryFrom<simple::Block> for SvmBlockRow {
    type Error = anyhow::Error;
    fn try_from(b: simple::Block) -> Result<Self> {
        Ok(Self {
            // Slot and blockhash are always selected (reorg detection needs
            // them), so their absence is a malformed response.
            slot: b.slot.ok_or_else(|| anyhow!("block.slot missing"))?,
            blockhash: b
                .blockhash
                .ok_or_else(|| anyhow!("block.blockhash missing"))?
                .to_string(),
            block_time: b.block_time,
            block_height: b.block_height,
            parent_slot: b.parent_slot,
            parent_blockhash: b.parent_blockhash.map(|h| h.to_string()),
        })
    }
}

/// Owned SVM transaction row for the `TransactionStore`. Rows without the
/// (slot, transaction_index) key are dropped at conversion.
#[derive(Default, Clone)]
pub struct SvmTxRow {
    pub slot: u64,
    pub transaction_index: u32,
    pub signatures: Vec<String>,
    pub fee_payer: Option<String>,
    pub success: Option<bool>,
    pub err: Option<String>,
    pub fee: Option<u64>,
    pub compute_units_consumed: Option<u64>,
    pub account_keys: Vec<String>,
    pub recent_blockhash: Option<String>,
    pub version: Option<String>,
}

impl SvmTxRow {
    pub(crate) fn from_simple(t: simple::Transaction) -> Option<Self> {
        Some(Self {
            slot: t.slot?,
            transaction_index: t.transaction_index?,
            signatures: t
                .signatures
                .map(|v| v.iter().map(ToString::to_string).collect())
                .unwrap_or_default(),
            fee_payer: t.fee_payer.map(|a| a.to_string()),
            success: t.success,
            err: t.err,
            fee: t.fee,
            compute_units_consumed: t.compute_units_consumed,
            account_keys: t
                .account_keys
                .map(|v| v.iter().map(ToString::to_string).collect())
                .unwrap_or_default(),
            recent_blockhash: t.recent_blockhash.map(|h| h.to_string()),
            version: t.version,
        })
    }
}

/// One token-side `account_activity` row shaped for the store's token-balance
/// companion table (the public `tokenBalances` transaction field). Native-only
/// rows and rows missing the (slot, transaction_index, account) key are
/// dropped at conversion.
#[derive(Default, Clone)]
pub struct SvmTokenBalanceRow {
    pub slot: u64,
    pub transaction_index: u32,
    pub account: String,
    pub mint: String,
    pub owner: Option<String>,
    pub pre_amount: Option<String>,
    pub post_amount: Option<String>,
}

/// The owner the public `tokenBalances` field reports: the post-transaction
/// owner, falling back to the pre-transaction owner for a token account
/// closed during the transaction (post_owner is null on a closed account).
fn owner_at_transaction_end(
    pre_owner: Option<simple::Address>,
    post_owner: Option<simple::Address>,
) -> Option<String> {
    post_owner.or(pre_owner).map(|o| o.to_string())
}

impl SvmTokenBalanceRow {
    pub(crate) fn from_activity(a: simple::AccountActivity) -> Option<Self> {
        // Mint presence is the token-side discriminant of the unified
        // account_activity row (only token rows carry one), so a native-only
        // row drops out here without paying for the derived token_state
        // column. `mint` is always selected by the query builder.
        let mint = a.mint?;
        Some(Self {
            slot: a.slot?,
            transaction_index: a.transaction_index?,
            account: a.account?.to_string(),
            mint: mint.to_string(),
            owner: owner_at_transaction_end(a.pre_owner, a.post_owner),
            pre_amount: a.pre_token_balance.map(|v| v.to_string()),
            post_amount: a.post_token_balance.map(|v| v.to_string()),
        })
    }
}

#[napi(object)]
#[derive(Default, Clone)]
pub struct Instruction {
    pub slot: i64,
    pub transaction_index: i64,
    /// Path through the call tree: outer instructions have a single-element
    /// path `[outer_index]`; inner instructions append child indices.
    pub instruction_address: Vec<i64>,
    /// The invoked program's account (renamed from `program_id` in the Wave 2
    /// HyperSync API).
    pub executing_account: String,
    /// The instruction's account arguments (renamed from `accounts`).
    pub account_arguments: Vec<String>,
    /// Raw instruction data, `0x`-prefixed hex.
    pub data: String,
    /// Discriminator prefix views, `0x`-prefixed hex. Each is `Some` only when
    /// the instruction data is at least that long.
    pub d1: Option<String>,
    pub d2: Option<String>,
    pub d4: Option<String>,
    pub d8: Option<String>,
    // Positional account shortcuts. Upstream supports `a0`..`a9`; we expose
    // `a0`..`a5` for now and extend later if a handler needs higher positions.
    pub a0: Option<String>,
    pub a1: Option<String>,
    pub a2: Option<String>,
    pub a3: Option<String>,
    pub a4: Option<String>,
    pub a5: Option<String>,
    pub is_inner: bool,
    /// True when the parent transaction succeeded (renamed from
    /// `is_committed`). Queries filter on `tx_success: true`, so this is a
    /// belt-and-braces flag rather than the primary exclusion mechanism.
    pub tx_success: bool,
    /// Borsh-decoded view, populated by `get` when a matching program schema
    /// was supplied in the query. `None` when no schema applies or decode failed.
    pub decoded: Option<DecodedInstructionJson>,
}

#[napi(object)]
#[derive(Default, Clone)]
pub struct Log {
    pub slot: i64,
    pub transaction_index: Option<i64>,
    pub instruction_address: Option<Vec<i64>>,
    pub program_id: Option<String>,
    pub kind: Option<String>,
    pub message: Option<String>,
}

#[napi(object)]
#[derive(Default, Clone)]
pub struct Reward {
    pub slot: i64,
    pub pubkey: Option<String>,
    pub lamports: Option<i64>,
    pub post_balance: Option<BigInt>,
    pub reward_type: Option<String>,
    pub commission: Option<i64>,
}

#[napi(object)]
#[derive(Default, Clone)]
pub struct QueryResponseData {
    pub blocks: Vec<Block>,
    pub instructions: Vec<Instruction>,
    pub logs: Vec<Log>,
    pub rewards: Vec<Reward>,
}

#[napi(object)]
#[derive(Default, Clone)]
pub struct QueryResponse {
    pub next_slot: i64,
    pub response_bytes: i64,
    pub data: QueryResponseData,
}

pub(crate) fn to_hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(2 + bytes.len() * 2);
    s.push_str("0x");
    for b in bytes {
        s.push_str(&format!("{:02x}", b));
    }
    s
}

pub(crate) fn opt_hex(bytes: &Option<Vec<u8>>) -> Option<String> {
    bytes.as_deref().map(to_hex)
}

fn opt_addr(a: &Option<simple::Address>) -> Option<String> {
    a.as_ref().map(ToString::to_string)
}

pub(crate) fn bigint_u64(v: u64) -> BigInt {
    BigInt {
        sign_bit: false,
        words: vec![v],
    }
}

fn u64_to_i64(v: u64, field: &str) -> Result<i64> {
    i64::try_from(v).with_context(|| format!("{field} = {v} does not fit in i64"))
}

fn u32_to_i64(v: u32) -> i64 {
    // u32 -> i64 is always lossless; helper keeps the call sites readable.
    v as i64
}

impl Block {
    /// Build the lean header from a borrowed row, without taking ownership —
    /// the row itself is retained (owned) in the `BlockStore` for on-demand
    /// field materialisation, so only the header's own fields are cloned.
    pub(crate) fn from_row(b: &SvmBlockRow) -> Result<Self> {
        Ok(Self {
            slot: u64_to_i64(b.slot, "block.slot")?,
            blockhash: b.blockhash.clone(),
            block_time: b.block_time,
        })
    }
}

impl TryFrom<simple::InstructionCall> for Instruction {
    type Error = anyhow::Error;
    fn try_from(i: simple::InstructionCall) -> Result<Self> {
        Ok(Self {
            // The identity and routing columns are always selected (the query
            // builder never projects the instruction_call table), so their
            // absence is a malformed response.
            slot: u64_to_i64(
                i.slot.ok_or_else(|| anyhow!("instruction.slot missing"))?,
                "instruction.slot",
            )?,
            transaction_index: u32_to_i64(
                i.transaction_index
                    .ok_or_else(|| anyhow!("instruction.transaction_index missing"))?,
            ),
            instruction_address: i
                .instruction_address
                .ok_or_else(|| anyhow!("instruction.instruction_address missing"))?
                .into_iter()
                .map(u32_to_i64)
                .collect(),
            executing_account: i
                .executing_account
                .ok_or_else(|| anyhow!("instruction.executing_account missing"))?
                .to_string(),
            account_arguments: i
                .account_arguments
                .map(|v| v.iter().map(ToString::to_string).collect())
                .unwrap_or_default(),
            data: to_hex(&i.data.unwrap_or_default()),
            d1: opt_hex(&i.d1),
            d2: opt_hex(&i.d2),
            d4: opt_hex(&i.d4),
            d8: opt_hex(&i.d8),
            a0: opt_addr(&i.a0),
            a1: opt_addr(&i.a1),
            a2: opt_addr(&i.a2),
            a3: opt_addr(&i.a3),
            a4: opt_addr(&i.a4),
            a5: opt_addr(&i.a5),
            is_inner: i.is_inner.unwrap_or(false),
            // Queries always send `tx_success: true`, so a row missing the
            // flag (never expected: the column is always selected) can only
            // be from a successful transaction.
            tx_success: i.tx_success.unwrap_or(true),
            decoded: None,
        })
    }
}

impl TryFrom<simple::Log> for Log {
    type Error = anyhow::Error;
    fn try_from(l: simple::Log) -> Result<Self> {
        Ok(Self {
            slot: u64_to_i64(
                l.slot.ok_or_else(|| anyhow!("log.slot missing"))?,
                "log.slot",
            )?,
            transaction_index: l.transaction_index.map(u32_to_i64),
            instruction_address: l
                .instruction_address
                .map(|v| v.into_iter().map(u32_to_i64).collect()),
            program_id: opt_addr(&l.program_id),
            kind: l.kind.map(|k| k.to_string()),
            message: l.message,
        })
    }
}

impl TryFrom<simple::Reward> for Reward {
    type Error = anyhow::Error;
    fn try_from(r: simple::Reward) -> Result<Self> {
        Ok(Self {
            slot: u64_to_i64(
                r.slot.ok_or_else(|| anyhow!("reward.slot missing"))?,
                "reward.slot",
            )?,
            pubkey: opt_addr(&r.pubkey),
            lamports: r.lamports,
            post_balance: r.post_balance.map(bigint_u64),
            reward_type: r.reward_type,
            commission: r.commission.map(|v| v as i64),
        })
    }
}

fn try_map<T, U>(items: Vec<T>) -> Result<Vec<U>>
where
    U: TryFrom<T, Error = anyhow::Error>,
{
    items.into_iter().map(U::try_from).collect()
}

impl TryFrom<simple::SolanaResponse> for QueryResponse {
    type Error = anyhow::Error;
    fn try_from(r: simple::SolanaResponse) -> Result<Self> {
        Ok(Self {
            next_slot: u64_to_i64(r.next_slot, "response.next_slot")?,
            response_bytes: i64::try_from(r.response_bytes)
                .with_context(|| format!("response_bytes {} overflows i64", r.response_bytes))?,
            data: QueryResponseData {
                // The caller takes `r.blocks` before this conversion runs (the
                // raw blocks go into the `BlockStore`) and fills this in
                // afterwards from `Block::from_row`, so it's always empty here.
                blocks: Vec::new(),
                instructions: try_map(r.instruction_calls)?,
                logs: try_map(r.logs)?,
                rewards: try_map(r.rewards)?,
            },
        })
    }
}
