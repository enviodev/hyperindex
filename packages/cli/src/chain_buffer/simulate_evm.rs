//! Simulated EVM transactions and their blocks as buffer rows, given as a
//! JSON-RPC node spells them, so a build matches and joins them as it does
//! fetched ones. A row holds the fields the test gave and no other.

use anyhow::{Context, Result};
use hypersync_client::format::{self, Hex};
use serde_json::{Map, Value};
use strum::VariantArray;

use super::tables::evm::{push_block, push_transaction};
use super::tables::table::ChunkBuilder;
use crate::ecosystems::evm::fields::{BlockField, EvmBlockField, EvmTxField};
use crate::ecosystems::evm::rpc_fields::{parse_hex_u64, tx_fields_in};
use crate::ecosystems::evm::rpc_responses;

/// The mask of the fields `object` names; a field's ordinal is its position
/// in `variants`. A key naming no field is a typo the test would otherwise
/// never see.
fn named_mask<F: Copy>(
    object: &Map<String, Value>,
    variants: &[F],
    name: impl Fn(F) -> &'static str,
    keys: &'static [&'static str],
    table: &str,
) -> Result<u64> {
    object.keys().try_fold(0, |mask, key| {
        if keys.contains(&key.as_str()) {
            return Ok(mask);
        }
        let ordinal = variants
            .iter()
            .position(|field| name(*field) == key)
            .with_context(|| format!("unknown {table} field \"{key}\""))?;
        Ok(mask | 1 << ordinal)
    })
}

fn required_text<'a>(object: &'a Map<String, Value>, key: &str) -> Result<&'a str> {
    object
        .get(key)
        .and_then(Value::as_str)
        .with_context(|| format!("\"{key}\" is required"))
}

fn quantity_at(object: &Map<String, Value>, key: &str) -> Result<u64> {
    parse_hex_u64(required_text(object, key)?).with_context(|| format!("\"{key}\""))
}

pub(crate) fn push_simulated_block(
    builder: &mut ChunkBuilder,
    block: &Map<String, Value>,
) -> Result<()> {
    let number = quantity_at(block, "number")?;
    let mask = named_mask(
        block,
        EvmBlockField::VARIANTS,
        EvmBlockField::name,
        &[],
        "block",
    )?;
    let decoded = rpc_responses::build_block(
        &Value::Object(block.clone()),
        number,
        &BlockField::in_store_mask(mask),
        &[],
    )
    .map_err(|error| anyhow::anyhow!("block {number}: {error}"))?;
    push_block(builder, &decoded, mask);
    Ok(())
}

/// A filter on a field the test left out matches nothing.
pub(crate) fn push_simulated_transaction(
    builder: &mut ChunkBuilder,
    transaction: &Map<String, Value>,
) -> Result<()> {
    let block_number = quantity_at(transaction, "blockNumber")?;
    let index = u32::try_from(quantity_at(transaction, "transactionIndex")?)
        .context("\"transactionIndex\" exceeds what a block holds")?;
    let hash = format::Hash::decode_hex(required_text(transaction, "hash")?).context("\"hash\"")?;
    let mask = named_mask(
        transaction,
        EvmTxField::VARIANTS,
        EvmTxField::name,
        &["blockNumber"],
        "transaction",
    )?;
    let response = Value::Object(transaction.clone());
    let decoded = rpc_responses::build_transaction(
        block_number,
        index,
        &hash,
        Some(&response),
        Some(&response),
        &tx_fields_in(mask),
    )
    .map_err(|error| anyhow::anyhow!("transaction {block_number}/{index}: {error}"))?;
    push_transaction(builder, &decoded, mask)
}
