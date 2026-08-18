use anyhow::{Context, Result};
use hypersync_client_solana::simple_types as simple;
use napi::bindgen_prelude::BigInt;
use napi_derive::napi;

use super::borsh_decoder::DecodedInstructionJson;

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

#[napi(object)]
#[derive(Default, Clone)]
pub struct InstructionCall {
    pub slot: i64,
    pub transaction_index: i64,
    /// Path through the call tree: outer instructions have a single-element
    /// path `[outer_index]`; inner instructions append child indices.
    pub instruction_address: Vec<i64>,
    /// The invoked program's account.
    pub executing_account: String,
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
    /// Success of the PARENT transaction, not of this invocation.
    pub tx_success: bool,
    /// Per-invocation failure reason (e.g. "custom program error: 0x1").
    pub error: Option<String>,
    /// Per-invocation compute units, when the source recorded them.
    pub compute_units_consumed: Option<BigInt>,
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

/// One account's activity in one transaction: the native SOL change, the SPL
/// token balance, or both.
#[napi(object)]
#[derive(Default, Clone)]
pub struct AccountActivity {
    pub slot: i64,
    pub transaction_index: Option<i64>,
    pub account: Option<String>,
    pub pre_balance: Option<BigInt>,
    pub post_balance: Option<BigInt>,
    pub mint: Option<String>,
    /// Token-account owner before the tx; absent when it was opened during it.
    pub pre_owner: Option<String>,
    /// Token-account owner after the tx; absent when it was closed during it.
    pub post_owner: Option<String>,
    pub token_decimals: Option<u8>,
    pub pre_token_balance: Option<BigInt>,
    pub post_token_balance: Option<BigInt>,
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
    pub instruction_calls: Vec<InstructionCall>,
    pub logs: Vec<Log>,
    pub account_activity: Vec<AccountActivity>,
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

/// Every response column is optional since the client models field selection
/// as `Option`. A column this crate always selects is missing only on a
/// malformed response, so the conversion says which one rather than defaulting.
pub(crate) fn required<T>(value: Option<T>, field: &str) -> Result<T> {
    value.with_context(|| format!("{field} missing from the response"))
}

/// Pubkeys, hashes and signatures arrive as byte newtypes whose `Display` is
/// their base58 form, which is what every consumer of this boundary reads.
fn base58_opt<T: std::fmt::Display>(value: &Option<T>) -> Option<String> {
    value.as_ref().map(T::to_string)
}

impl Block {
    /// Build the lean header from a borrowed raw block, without taking
    /// ownership — used when the raw block is also retained (owned) in the
    /// `BlockStore` for on-demand field materialisation, so only the header's
    /// own fields are cloned rather than the whole raw struct.
    pub(crate) fn from_raw(b: &simple::Block) -> Result<Self> {
        Ok(Self {
            slot: u64_to_i64(required(b.slot, "block.slot")?, "block.slot")?,
            blockhash: required(b.blockhash.as_ref(), "block.blockhash")?.to_string(),
            block_time: b.block_time,
        })
    }
}

impl TryFrom<simple::InstructionCall> for InstructionCall {
    type Error = anyhow::Error;
    fn try_from(i: simple::InstructionCall) -> Result<Self> {
        let data = required(i.data, "instruction.data")?;
        Ok(Self {
            slot: u64_to_i64(required(i.slot, "instruction.slot")?, "instruction.slot")?,
            transaction_index: u32_to_i64(required(
                i.transaction_index,
                "instruction.transaction_index",
            )?),
            instruction_address: required(
                i.instruction_address,
                "instruction.instruction_address",
            )?
            .into_iter()
            .map(u32_to_i64)
            .collect(),
            executing_account: required(i.executing_account, "instruction.executing_account")?
                .to_string(),
            account_arguments: required(i.account_arguments, "instruction.account_arguments")?
                .iter()
                .map(|account| account.to_string())
                .collect(),
            data: to_hex(&data),
            d1: opt_hex(&i.d1),
            d2: opt_hex(&i.d2),
            d4: opt_hex(&i.d4),
            d8: opt_hex(&i.d8),
            a0: base58_opt(&i.a0),
            a1: base58_opt(&i.a1),
            a2: base58_opt(&i.a2),
            a3: base58_opt(&i.a3),
            a4: base58_opt(&i.a4),
            a5: base58_opt(&i.a5),
            is_inner: required(i.is_inner, "instruction.is_inner")?,
            tx_success: required(i.tx_success, "instruction.tx_success")?,
            error: i.error,
            compute_units_consumed: i.compute_units_consumed.map(bigint_u64),
            decoded: None,
        })
    }
}

impl TryFrom<simple::Log> for Log {
    type Error = anyhow::Error;
    fn try_from(l: simple::Log) -> Result<Self> {
        Ok(Self {
            slot: u64_to_i64(required(l.slot, "log.slot")?, "log.slot")?,
            transaction_index: l.transaction_index.map(u32_to_i64),
            instruction_address: l
                .instruction_address
                .map(|v| v.into_iter().map(u32_to_i64).collect()),
            program_id: base58_opt(&l.program_id),
            kind: l.kind.map(|kind| kind.as_str().to_string()),
            message: l.message,
        })
    }
}

impl TryFrom<simple::AccountActivity> for AccountActivity {
    type Error = anyhow::Error;
    fn try_from(a: simple::AccountActivity) -> Result<Self> {
        Ok(Self {
            slot: u64_to_i64(
                required(a.slot, "account_activity.slot")?,
                "account_activity.slot",
            )?,
            transaction_index: a.transaction_index.map(u32_to_i64),
            account: base58_opt(&a.account),
            pre_balance: a.pre_balance.map(bigint_u64),
            post_balance: a.post_balance.map(bigint_u64),
            mint: base58_opt(&a.mint),
            pre_owner: base58_opt(&a.pre_owner),
            post_owner: base58_opt(&a.post_owner),
            token_decimals: a.token_decimals,
            pre_token_balance: a.pre_token_balance.map(bigint_u64),
            post_token_balance: a.post_token_balance.map(bigint_u64),
        })
    }
}

impl TryFrom<simple::Reward> for Reward {
    type Error = anyhow::Error;
    fn try_from(r: simple::Reward) -> Result<Self> {
        Ok(Self {
            slot: u64_to_i64(required(r.slot, "reward.slot")?, "reward.slot")?,
            pubkey: base58_opt(&r.pubkey),
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
                // afterwards from `Block::from_raw`, so it's always empty here.
                blocks: Vec::new(),
                instruction_calls: try_map(r.instruction_calls)?,
                logs: try_map(r.logs)?,
                account_activity: try_map(r.account_activity)?,
                rewards: try_map(r.rewards)?,
            },
        })
    }
}
