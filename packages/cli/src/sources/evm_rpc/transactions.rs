//! A transaction page over RPC. No provider filters transactions, so every
//! block of the page is read in full and matched here. A receipt is read only
//! for a transaction its call already matched, and only when a `status`
//! filter or a field only the receipt carries asks for one.

use std::collections::HashMap;
use std::sync::Arc;

use futures_util::future::join_all;
use hypersync_client::format::{self, Hex};
use hypersync_client::simple_types::Transaction;
use serde_json::Value as Json;

use super::client::JsonRpcClient;
use super::enrich::{collect_worst, require, EnrichError, FetchKey, Fetches};
use crate::chain_buffer::matching::transactions::{
    bit, OnTransactionRegistration, TransactionView,
};
use crate::chain_buffer::page::PageData;
use crate::chain_buffer::tables::evm::push_transaction;
use crate::ecosystems::evm::fields::EvmTxField;
use crate::ecosystems::evm::rpc_fields::{parse_hex_u64, tx_fields_in, tx_mask_of, Carrier};
use crate::ecosystems::evm::rpc_responses as responses;

/// The transaction fields a registration needs a row to hold: what its
/// handler reads and what its filter compares.
fn fields_needed(registration: &OnTransactionRegistration) -> u64 {
    registration.transaction_mask | registration.filter.fields_read()
}

/// The transaction registrations a page reads for.
pub(crate) struct TransactionRead<'a> {
    registrations: Vec<&'a OnTransactionRegistration>,
    transaction_mask: u64,
    pub(crate) block_mask: u64,
}

impl<'a> TransactionRead<'a> {
    pub(crate) fn new(registrations: Vec<&'a OnTransactionRegistration>) -> Option<Self> {
        if registrations.is_empty() {
            return None;
        }
        let (transaction_mask, block_mask) =
            registrations
                .iter()
                .fold((0, 0), |(transactions, blocks), registration| {
                    (
                        transactions | fields_needed(registration),
                        blocks | registration.block_mask,
                    )
                });
        Some(TransactionRead {
            registrations,
            transaction_mask,
            block_mask,
        })
    }

    /// The needed fields the transaction's own response fills.
    fn transaction_fields(&self) -> u64 {
        self.transaction_mask & !tx_mask_of(Carrier::Receipt)
    }

    /// The needed fields a receipt fills, when one of `matched` needs any:
    /// `status` to filter on, or a field only the receipt carries.
    fn receipt_fields(&self, matched: &[&OnTransactionRegistration]) -> Option<u64> {
        let receipt = tx_mask_of(Carrier::Receipt);
        matched
            .iter()
            .any(|registration| fields_needed(registration) & receipt != 0)
            .then_some(self.transaction_mask & receipt)
    }
}

/// A transaction of a full block, as the block's response spells it.
struct Call<'r> {
    response: &'r Json,
    index: u32,
    hash: format::Hash,
    from: Vec<u8>,
    to: Option<Vec<u8>>,
}

fn malformed(block_number: u64, message: impl std::fmt::Display) -> EnrichError {
    EnrichError::Transient(format!(
        "The RPC gave an unusable answer while reading the transactions of block \
         {block_number}: {message}. Indexing continues once the query is retried."
    ))
}

/// An address field: `None` when the transaction has none (null or absent),
/// an error when it has one that isn't 20 bytes, which would otherwise match
/// no filter and silently drop the transaction.
fn address_field(
    block_number: u64,
    response: &Json,
    name: &str,
) -> Result<Option<Vec<u8>>, EnrichError> {
    match response.get(name) {
        None | Some(Json::Null) => Ok(None),
        Some(Json::String(text)) => match crate::hex::decode_prefixed(text, name) {
            Ok(bytes) if bytes.len() == 20 => Ok(Some(bytes)),
            Ok(bytes) => Err(malformed(
                block_number,
                format!("a transaction's \"{name}\" is {} bytes", bytes.len()),
            )),
            Err(error) => Err(malformed(block_number, format!("{error:#}"))),
        },
        Some(other) => Err(malformed(
            block_number,
            format!("a transaction's \"{name}\" is {other}"),
        )),
    }
}

fn calls_of(block_number: u64, block: &Json) -> Result<Vec<Call<'_>>, EnrichError> {
    let transactions = block
        .get("transactions")
        .and_then(Json::as_array)
        .ok_or_else(|| malformed(block_number, "the block carries no transactions list"))?;
    transactions
        .iter()
        .map(|response| {
            if !response.is_object() {
                return Err(malformed(
                    block_number,
                    "a transaction came back as a hash rather than in full",
                ));
            }
            let index = response
                .get("transactionIndex")
                .and_then(Json::as_str)
                .and_then(|index| parse_hex_u64(index).ok())
                .and_then(|index| u32::try_from(index).ok())
                .ok_or_else(|| malformed(block_number, "a transaction has no transactionIndex"))?;
            let hash = response
                .get("hash")
                .and_then(Json::as_str)
                .and_then(|hash| format::Hash::decode_hex(hash).ok())
                .ok_or_else(|| malformed(block_number, "a transaction has no hash"))?;
            let from = address_field(block_number, response, "from")?
                .ok_or_else(|| malformed(block_number, "a transaction has no sender"))?;
            Ok(Call {
                response,
                index,
                hash,
                from,
                to: address_field(block_number, response, "to")?,
            })
        })
        .collect()
}

/// Reads the transactions of `blocks` the registrations run on into `page`,
/// and returns the blocks holding one.
pub(crate) async fn read(
    client: &Arc<JsonRpcClient>,
    fetches: &Fetches,
    read: &TransactionRead<'_>,
    blocks: &HashMap<u64, Arc<Json>>,
    page: &mut PageData,
) -> Result<Vec<u64>, EnrichError> {
    let mut candidates = Vec::new();
    let mut block_numbers: Vec<&u64> = blocks.keys().collect();
    block_numbers.sort_unstable();
    for &block_number in block_numbers {
        for call in calls_of(block_number, &blocks[&block_number])? {
            let view = TransactionView {
                from: Some(&call.from),
                to: call.to.as_deref(),
                status: None,
            };
            let matched: Vec<&OnTransactionRegistration> = read
                .registrations
                .iter()
                .copied()
                .filter(|registration| registration.filter.matches_call(&view))
                .collect();
            if !matched.is_empty() {
                let receipt_fields = read.receipt_fields(&matched);
                candidates.push((block_number, call, matched, receipt_fields));
            }
        }
    }

    let read_transactions = join_all(candidates.into_iter().map(
        |(block_number, call, matched, receipt_fields)| async move {
            let receipt = match receipt_fields {
                Some(_) => {
                    let receipt = require(
                        client,
                        fetches,
                        FetchKey::Receipt(**call.hash),
                        block_number,
                    )
                    .await?;
                    // Read after the block, so the chain may have moved: a
                    // receipt from another block would decide a status filter
                    // on another fork's outcome.
                    let hash_at = |response: &Json, key: &str| {
                        response
                            .get(key)
                            .and_then(Json::as_str)
                            .map(str::to_ascii_lowercase)
                    };
                    if hash_at(&receipt, "blockHash") != hash_at(&blocks[&block_number], "hash") {
                        return Err(malformed(
                            block_number,
                            format!(
                                "the receipt of transaction {} names another block than the one it was read from",
                                call.hash.encode_hex()
                            ),
                        ));
                    }
                    Some(receipt)
                }
                None => None,
            };
            let fetched = read.transaction_fields() | receipt_fields.unwrap_or(0);
            let fields = tx_fields_in(fetched);
            let mut transaction = responses::build_transaction(
                block_number,
                call.index,
                &call.hash,
                Some(call.response),
                receipt.as_deref(),
                &fields,
            )
            .map_err(|error| EnrichError::from_response(block_number, error))?;
            if responses::needs_effective_gas_price(&transaction, &fields) {
                responses::fill_effective_gas_price(&mut transaction, call.response)
                    .map_err(|error| EnrichError::from_response(block_number, error))?;
            }
            responses::check_transaction(&transaction, &fields)
                .map_err(|error| EnrichError::from_response(block_number, error))?;
            let status_read = receipt_fields.is_some_and(|fields| fields & bit(EvmTxField::Status) != 0);
            // A node serves pre-Byzantium receipts with `root` and no `status`.
            // Matching none would silently skip every transaction of those
            // blocks, and asking again gets the same receipt.
            if status_read
                && transaction.status.is_none()
                && matched.iter().any(|registration| registration.filter.status.is_some())
            {
                return Err(EnrichError::FieldSelection {
                    block_number,
                    error: anyhow::anyhow!(
                        "the RPC receipt of transaction {} in block {block_number} has no \
                         status (blocks before Byzantium have none), so an onTransaction \
                         `status` filter can't be decided over RPC. Index these blocks \
                         with HyperSync, or list `status: [0, 1]` to run on every transaction.",
                        call.hash.encode_hex()
                    ),
                });
            }
            let status = transaction
                .status
                .filter(|_| status_read)
                .map(|status| status.to_u8() as u64);
            let runs = matched
                .iter()
                .any(|registration| registration.filter.matches_status(status));
            Ok(runs.then_some((block_number, transaction, fetched)))
        },
    ))
    .await;

    let kept: Vec<(u64, Transaction, u64)> = collect_worst(read_transactions)?
        .into_iter()
        .flatten()
        .collect();
    let mut rows = page.transactions.builder();
    let mut kept_blocks = Vec::with_capacity(kept.len());
    for (block_number, transaction, fetched) in &kept {
        push_transaction(&mut rows, transaction, *fetched)
            .map_err(|error| EnrichError::Transient(format!("{error:#}")))?;
        kept_blocks.push(*block_number);
    }
    page.add_transactions(rows.finish());
    kept_blocks.dedup();
    Ok(kept_blocks)
}
