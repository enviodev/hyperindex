use anyhow::{Context, Result};
use hypersync_client_solana::simple_types as simple;
use napi::bindgen_prelude::BigInt;
use napi_derive::napi;

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

pub(crate) fn bigint_u64(v: u64) -> BigInt {
    BigInt {
        sign_bit: false,
        words: vec![v],
    }
}

fn u64_to_i64(v: u64, field: &str) -> Result<i64> {
    i64::try_from(v).with_context(|| format!("{field} = {v} does not fit in i64"))
}

pub(crate) fn required<T>(value: Option<T>, field: &str) -> Result<T> {
    value.with_context(|| format!("{field} missing from the response"))
}

/// Pubkeys, hashes and signatures arrive as byte newtypes whose `Display` is
/// their base58 form, which is what every consumer of this boundary reads.
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
