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
pub struct Instruction {
    pub slot: i64,
    pub transaction_index: i64,
    /// Path through the call tree: outer instructions have a single-element
    /// path `[outer_index]`; inner instructions append child indices.
    pub instruction_address: Vec<i64>,
    pub program_id: String,
    pub accounts: Vec<String>,
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
    pub is_committed: bool,
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
pub struct Balance {
    pub slot: i64,
    pub transaction_index: Option<i64>,
    pub account: Option<String>,
    pub pre: Option<BigInt>,
    pub post: Option<BigInt>,
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
    pub balances: Vec<Balance>,
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

impl Block {
    /// Build the lean header from a borrowed raw block, without taking
    /// ownership — used when the raw block is also retained (owned) in the
    /// `BlockStore` for on-demand field materialisation, so only the header's
    /// own fields are cloned rather than the whole raw struct.
    pub(crate) fn from_raw(b: &simple::Block) -> Result<Self> {
        Ok(Self {
            slot: u64_to_i64(b.slot, "block.slot")?,
            blockhash: b.blockhash.clone(),
            block_time: b.block_time,
        })
    }
}

impl TryFrom<simple::Instruction> for Instruction {
    type Error = anyhow::Error;
    fn try_from(i: simple::Instruction) -> Result<Self> {
        Ok(Self {
            slot: u64_to_i64(i.slot, "instruction.slot")?,
            transaction_index: u32_to_i64(i.transaction_index),
            instruction_address: i.instruction_address.into_iter().map(u32_to_i64).collect(),
            program_id: i.program_id,
            accounts: i.accounts,
            data: to_hex(&i.data),
            d1: opt_hex(&i.d1),
            d2: opt_hex(&i.d2),
            d4: opt_hex(&i.d4),
            d8: opt_hex(&i.d8),
            a0: i.a0,
            a1: i.a1,
            a2: i.a2,
            a3: i.a3,
            a4: i.a4,
            a5: i.a5,
            is_inner: i.is_inner,
            is_committed: i.is_committed,
            decoded: None,
        })
    }
}

impl TryFrom<simple::Log> for Log {
    type Error = anyhow::Error;
    fn try_from(l: simple::Log) -> Result<Self> {
        Ok(Self {
            slot: u64_to_i64(l.slot, "log.slot")?,
            transaction_index: l.transaction_index.map(u32_to_i64),
            instruction_address: l
                .instruction_address
                .map(|v| v.into_iter().map(u32_to_i64).collect()),
            program_id: l.program_id,
            kind: l.kind,
            message: l.message,
        })
    }
}

impl TryFrom<simple::Balance> for Balance {
    type Error = anyhow::Error;
    fn try_from(b: simple::Balance) -> Result<Self> {
        Ok(Self {
            slot: u64_to_i64(b.slot, "balance.slot")?,
            transaction_index: b.transaction_index.map(u32_to_i64),
            account: b.account,
            pre: b.pre.map(bigint_u64),
            post: b.post.map(bigint_u64),
        })
    }
}

impl TryFrom<simple::Reward> for Reward {
    type Error = anyhow::Error;
    fn try_from(r: simple::Reward) -> Result<Self> {
        Ok(Self {
            slot: u64_to_i64(r.slot, "reward.slot")?,
            pubkey: r.pubkey,
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
                instructions: try_map(r.instructions)?,
                logs: try_map(r.logs)?,
                balances: try_map(r.balances)?,
                rewards: try_map(r.rewards)?,
            },
        })
    }
}
