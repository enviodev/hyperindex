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

use super::client::{parse_hex_u64, JsonRpcClient};
use super::enrich::{collect_worst, require, EnrichError, FetchKey, Fetches};
use super::fields::{tx_fields_in, tx_mask_of, Carrier};
use super::responses;
use crate::chain_buffer::evm::{push_transaction, EvmTxField, SELECTOR_BIT};
use crate::chain_buffer::matching_transactions::{
    Held, OnTransactionRegistration, TransactionView,
};
use crate::chain_buffer::page::PageData;

const FROM_TO: u64 = (1 << EvmTxField::From as u32) | (1 << EvmTxField::To as u32);
const STATUS_BIT: u64 = 1 << EvmTxField::Status as u32;

/// The transaction registrations a page reads for.
pub(crate) struct TransactionRead<'a> {
    pub(crate) registrations: Vec<&'a OnTransactionRegistration>,
    /// The union of the registrations' transaction fields.
    transaction_mask: u64,
    /// The union of the registrations' block fields.
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
                        transactions | registration.transaction_mask,
                        blocks | registration.block_mask,
                    )
                });
        Some(TransactionRead {
            registrations,
            transaction_mask,
            block_mask,
        })
    }

    /// The fields a transaction's own response fills: what the handlers read
    /// of it, and the call fields matching reads.
    fn transaction_fields(&self) -> u64 {
        (self.transaction_mask
            & (tx_mask_of(Carrier::Log)
                | tx_mask_of(Carrier::Transaction)
                | tx_mask_of(Carrier::Either)))
            | FROM_TO
            | SELECTOR_BIT
    }

    /// What a receipt read for `matched` adds.
    fn receipt_fields(&self, matched: &[&OnTransactionRegistration]) -> Option<u64> {
        let filters_status = matched
            .iter()
            .any(|registration| registration.filter.status.is_some());
        let receipt_fields = self.transaction_mask & tx_mask_of(Carrier::Receipt);
        let reads_receipt_fields = matched
            .iter()
            .any(|registration| registration.transaction_mask & tx_mask_of(Carrier::Receipt) != 0);
        (filters_status || reads_receipt_fields)
            .then_some(receipt_fields | if filters_status { STATUS_BIT } else { 0 })
    }
}

/// A transaction of a full block, as the block's response spells it.
struct Call<'r> {
    response: &'r Json,
    index: u32,
    hash: format::Hash,
    from: Vec<u8>,
    to: Option<Vec<u8>>,
    selector: Option<Vec<u8>>,
}

fn malformed(block_number: u64, message: impl std::fmt::Display) -> EnrichError {
    EnrichError::Transient(format!(
        "The RPC gave an unusable answer while reading the transactions of block \
         {block_number}: {message}. Indexing continues once the query is retried."
    ))
}

fn hex_field(response: &Json, name: &str) -> Option<Vec<u8>> {
    let text = response.get(name)?.as_str()?;
    crate::hex::decode_prefixed(text, name).ok()
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
            let from = hex_field(response, "from")
                .ok_or_else(|| malformed(block_number, "a transaction has no sender"))?;
            Ok(Call {
                response,
                index,
                hash,
                from,
                to: hex_field(response, "to"),
                selector: hex_field(response, "input")
                    .and_then(|input| input.get(..4).map(<[u8]>::to_vec)),
            })
        })
        .collect()
}

fn held(value: &Option<Vec<u8>>) -> Held<&[u8]> {
    match value {
        Some(value) => Held::Value(value),
        None => Held::Absent,
    }
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
                from: Held::Value(&call.from),
                to: held(&call.to),
                selector: held(&call.selector),
                status: Held::Unheld,
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
                Some(_) => Some(
                    require(
                        client,
                        fetches,
                        FetchKey::Receipt(**call.hash),
                        block_number,
                    )
                    .await?,
                ),
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
            transaction.sighash = call.selector.clone().map(format::Data::from);
            let status = match receipt_fields {
                // A receipt from before status existed holds none.
                Some(fields) if fields & STATUS_BIT != 0 => {
                    Held::new(true, transaction.status.map(|status| status.to_u8() as u64))
                }
                _ => Held::Unheld,
            };
            let view = TransactionView {
                from: Held::Value(&call.from),
                to: held(&call.to),
                selector: held(&call.selector),
                status,
            };
            let runs = matched
                .iter()
                .any(|registration| registration.filter.matches_status(view.status));
            Ok(runs.then_some((transaction, fetched)))
        },
    ))
    .await;

    let kept: Vec<(Transaction, u64)> = collect_worst(read_transactions)?
        .into_iter()
        .flatten()
        .collect();
    let mut rows = page.transactions.builder();
    let mut kept_blocks = Vec::with_capacity(kept.len());
    for (transaction, fetched) in &kept {
        push_transaction(&mut rows, transaction, *fetched)
            .map_err(|error| EnrichError::Transient(format!("{error:#}")))?;
        if let Some(block_number) = transaction.block_number {
            kept_blocks.push(u64::from(block_number));
        }
    }
    page.add_transactions(rows.finish());
    kept_blocks.dedup();
    Ok(kept_blocks)
}
