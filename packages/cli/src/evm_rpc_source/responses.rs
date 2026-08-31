//! Turns JSON-RPC block, transaction and receipt responses into the
//! `simple_types` rows the stores already know how to hold.
//!
//! Only the selected fields are read, so an unselected `input` never reaches
//! the store. A selected field the provider omits is an error naming the
//! field, judged by the same nullability rules the HyperSync path validates
//! against — one source of truth for which fields a chain may legitimately not
//! have.

use anyhow::{anyhow, Context, Result};
use hypersync_client::format;
use hypersync_client::simple_types::{Block, Transaction};
use serde_json::Value as Json;

use super::fields::{
    block_field_column, set_block_field, set_tx_field, tx_carrier, tx_field_column, Carrier,
};
use crate::evm_hypersync_source::query::{BlockField, TransactionField};
use crate::evm_hypersync_source::{block_field_missing, transaction_field_missing};
use crate::transaction_store::EvmTxField;

/// A response value that is present and not null. JSON-RPC omits some fields
/// and nulls others for the same "this chain has none" meaning, so both read
/// the same way here and the nullability rules decide whether that is allowed.
fn present<'a>(response: &'a Json, key: &str) -> Option<&'a Json> {
    response.get(key).filter(|value| !value.is_null())
}

fn unsupported(kind: &str, field: impl std::fmt::Debug) -> anyhow::Error {
    anyhow!("the RPC source cannot supply the {kind} field {field:?}")
}

/// Build a block row from an `eth_getBlockByNumber` response. `number` is
/// always read: it keys the row, whether or not the user selected it, and it
/// must be the block that was asked for — a row keyed by some other number
/// would leave the requested block silently absent from the page, and with it
/// a hole in the chain of reorg checkpoints.
pub(crate) fn build_block(
    response: &Json,
    requested: u64,
    selection: &[BlockField],
) -> Result<Block> {
    let mut block = Block::default();
    let number = present(response, "number")
        .ok_or_else(|| anyhow!("block response carries no \"number\""))?;
    set_block_field(
        &mut block,
        crate::block_store::EvmBlockField::Number,
        number,
    )?;
    if block.number != Some(requested) {
        return Err(anyhow!(
            "asked the RPC for block {requested} and it answered with block {}",
            block
                .number
                .map_or_else(|| "none".to_string(), |n| n.to_string()),
        ));
    }

    for &requested in selection {
        let field = block_field_column(requested).ok_or_else(|| unsupported("block", requested))?;
        if let Some(raw) = present(response, field.name()) {
            set_block_field(&mut block, field, raw)?;
        }
    }

    let missing: Vec<&str> = selection
        .iter()
        .filter_map(|&requested| block_field_missing(&block, requested))
        .collect();
    if !missing.is_empty() {
        return Err(missing_error("block", &missing));
    }
    Ok(block)
}

/// Build a transaction row from whichever of the two responses were fetched.
/// The key and hash come from the log that referenced it, so they hold even
/// when neither response is read.
pub(crate) fn build_transaction(
    block_number: u64,
    transaction_index: u32,
    hash: &format::Hash,
    transaction: Option<&Json>,
    receipt: Option<&Json>,
    selection: &[TransactionField],
) -> Result<Transaction> {
    let mut tx = Transaction {
        block_number: Some(block_number.into()),
        transaction_index: Some(u64::from(transaction_index).into()),
        hash: Some(hash.clone()),
        ..Default::default()
    };

    for &requested in selection {
        let field =
            tx_field_column(requested).ok_or_else(|| unsupported("transaction", requested))?;
        // The log already supplied these two, and reading them back from a
        // response would only risk disagreeing with the log they are keyed by.
        let source = match tx_carrier(field) {
            Carrier::Log => continue,
            Carrier::Transaction => transaction,
            Carrier::Receipt => receipt,
            Carrier::Either => transaction.or(receipt),
        };
        if let Some(raw) = source.and_then(|response| present(response, field.name())) {
            set_tx_field(&mut tx, field, raw)?;
        }
    }
    Ok(tx)
}

/// Pre-EIP-1559 receipts carry no `effectiveGasPrice` — every Optimism block
/// below the Bedrock migration at 105235063, for one. Those chains price every
/// transaction the legacy way, so the transaction's `gasPrice` is the effective
/// price, the same substitution HyperSync serves for those blocks. Only the
/// chains that omit it pay for the extra request, and only once the receipt has
/// come back without it.
pub(crate) fn needs_effective_gas_price(tx: &Transaction, selection: &[TransactionField]) -> bool {
    tx.effective_gas_price.is_none() && selection.contains(&TransactionField::EffectiveGasPrice)
}

pub(crate) fn fill_effective_gas_price(tx: &mut Transaction, transaction: &Json) -> Result<()> {
    let gas_price = present(transaction, EvmTxField::GasPrice.name()).ok_or_else(|| {
        anyhow!(
            "neither \"effectiveGasPrice\" nor \"gasPrice\" is present in the RPC response for \
             the transaction. Remove \"effectiveGasPrice\" from the field selection, or index \
             this chain via HyperSync."
        )
    })?;
    set_tx_field(tx, EvmTxField::EffectiveGasPrice, gas_price)
        .context("filling effectiveGasPrice from gasPrice")
}

/// Report the selected transaction fields the responses did not supply, judged
/// by the same nullability rules the HyperSync path uses.
pub(crate) fn check_transaction(tx: &Transaction, selection: &[TransactionField]) -> Result<()> {
    let missing: Vec<&str> = selection
        .iter()
        .filter_map(|&requested| transaction_field_missing(tx, requested))
        .collect();
    if missing.is_empty() {
        Ok(())
    } else {
        Err(missing_error("transaction", &missing))
    }
}

fn missing_error(kind: &str, missing: &[&str]) -> anyhow::Error {
    anyhow!(
        "the RPC response is missing the selected {kind} {}: {}. Please double-check your RPC \
         provider returns correct data.",
        if missing.len() == 1 {
            "field"
        } else {
            "fields"
        },
        missing.join(", "),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use hypersync_client::format::Hex;
    use serde_json::json;

    fn hash(byte: u8) -> format::Hash {
        format::Hash::from([byte; 32])
    }

    #[test]
    fn a_block_reads_only_the_selected_fields() {
        let response = json!({
            "number": "0x10",
            "timestamp": "0x20",
            "hash": "0x".to_string() + &"11".repeat(32),
            "gasUsed": "0x30",
        });
        let block = build_block(&response, 16, &[BlockField::Timestamp]).unwrap();
        assert_eq!(
            (
                block.number,
                block.timestamp.as_ref().map(Hex::encode_hex),
                block.gas_used.is_some(),
                block.hash.is_some(),
            ),
            (Some(16), Some("0x20".into()), false, false)
        );
    }

    #[test]
    fn a_block_missing_a_selected_non_nullable_field_is_rejected() {
        // The provider answered, but not with what the selection needs; serving
        // undefined for it would surface as a silently empty handler field.
        let response = json!({ "number": "0x10" });
        let err = build_block(&response, 16, &[BlockField::Timestamp])
            .unwrap_err()
            .to_string();
        assert!(err.contains("timestamp"), "{err}");
    }

    #[test]
    fn a_block_missing_a_nullable_field_is_accepted() {
        // Pre-London blocks have no baseFeePerGas; that is the chain's answer,
        // not a broken provider.
        let response = json!({ "number": "0x10", "baseFeePerGas": Json::Null });
        let block = build_block(&response, 16, &[BlockField::BaseFeePerGas]).unwrap();
        assert_eq!((block.number, block.base_fee_per_gas), (Some(16), None));
    }

    #[test]
    fn a_block_response_for_another_number_is_rejected() {
        // A node answering with a different block would key the row elsewhere,
        // leaving the requested block absent from the page while the range
        // still advanced past it.
        let response = json!({ "number": "0x11", "timestamp": "0x20" });
        let err = build_block(&response, 16, &[BlockField::Timestamp])
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("block 16") && err.contains("block 17"),
            "{err}"
        );
    }

    #[test]
    fn a_transaction_takes_its_key_and_hash_from_the_log() {
        let tx = build_transaction(7, 3, &hash(0xab), None, None, &[]).unwrap();
        assert_eq!(
            (
                tx.block_number.map(u64::from),
                tx.transaction_index.map(u64::from),
                tx.hash.as_ref().map(Hex::encode_hex),
            ),
            (Some(7), Some(3), Some(format!("0x{}", "ab".repeat(32))))
        );
    }

    #[test]
    fn each_field_reads_from_the_response_that_carries_it() {
        // `gas` is only on the transaction, `gasUsed` only on the receipt, and
        // `from` on both — so a wrong carrier would silently read a null.
        let transaction = json!({ "gas": "0x1", "from": "0x".to_string() + &"22".repeat(20) });
        let receipt = json!({ "gasUsed": "0x2", "from": "0x".to_string() + &"33".repeat(20) });
        let tx = build_transaction(
            1,
            0,
            &hash(1),
            Some(&transaction),
            Some(&receipt),
            &[
                TransactionField::Gas,
                TransactionField::GasUsed,
                TransactionField::From,
            ],
        )
        .unwrap();
        assert_eq!(
            (
                tx.gas.as_ref().map(Hex::encode_hex),
                tx.gas_used.as_ref().map(Hex::encode_hex),
                tx.from.as_ref().map(Hex::encode_hex),
            ),
            (
                Some("0x1".into()),
                Some("0x2".into()),
                // `from` is on both, so it comes from the transaction.
                Some(format!("0x{}", "22".repeat(20)))
            )
        );
    }

    #[test]
    fn a_receipt_without_effective_gas_price_falls_back_to_the_transactions_gas_price() {
        let receipt = json!({ "gasUsed": "0x2" });
        let selection = [TransactionField::EffectiveGasPrice];
        let mut tx = build_transaction(1, 0, &hash(1), None, Some(&receipt), &selection).unwrap();
        assert!(needs_effective_gas_price(&tx, &selection));

        let transaction = json!({ "gasPrice": "0x7" });
        fill_effective_gas_price(&mut tx, &transaction).unwrap();
        assert_eq!(
            (
                tx.effective_gas_price.as_ref().map(Hex::encode_hex),
                needs_effective_gas_price(&tx, &selection),
            ),
            (Some("0x7".into()), false)
        );
    }

    #[test]
    fn a_transaction_with_neither_effective_gas_price_nor_gas_price_is_rejected() {
        let mut tx = Transaction::default();
        let err = fill_effective_gas_price(&mut tx, &json!({}))
            .unwrap_err()
            .to_string();
        assert!(err.contains("effectiveGasPrice"), "{err}");
    }

    #[test]
    fn a_null_to_is_accepted_as_the_contract_creation_it_marks() {
        let transaction = json!({ "to": Json::Null, "gas": "0x1" });
        let selection = [TransactionField::To, TransactionField::Gas];
        let tx = build_transaction(1, 0, &hash(1), Some(&transaction), None, &selection).unwrap();
        check_transaction(&tx, &selection).unwrap();
        assert_eq!((tx.to.is_some(), tx.gas.is_some()), (false, true));
    }

    #[test]
    fn a_transaction_without_signature_fields_is_accepted() {
        // A ZKSync EIP-712 transaction (type 0x71) carries no v/r/s/yParity.
        // They are absent by the shape of the transaction, not by a gap in the
        // response, so requiring them would fail the whole page.
        let transaction = json!({
            "gas": "0x1",
            "gasPrice": "0x2",
            "nonce": "0x3",
            "value": "0x4",
            "type": "0x71",
        });
        let selection = [
            TransactionField::V,
            TransactionField::R,
            TransactionField::S,
            TransactionField::YParity,
            TransactionField::Type,
            TransactionField::Gas,
        ];
        let tx = build_transaction(1, 0, &hash(1), Some(&transaction), None, &selection).unwrap();
        check_transaction(&tx, &selection).unwrap();
        assert_eq!(
            (
                tx.v.is_some(),
                tx.r.is_some(),
                tx.s.is_some(),
                tx.y_parity.is_some(),
                tx.type_.map(u8::from),
            ),
            (false, false, false, false, Some(113))
        );
    }

    #[test]
    fn a_legacy_transaction_without_an_access_list_is_accepted() {
        // Only typed transactions carry one, so requiring it would fail on the
        // first legacy transaction a page touches — and a field-selection
        // failure disables the source.
        let selection = [TransactionField::AccessList, TransactionField::Gas];
        let tx = build_transaction(
            1,
            0,
            &hash(1),
            Some(&json!({ "gas": "0x1" })),
            None,
            &selection,
        )
        .unwrap();
        check_transaction(&tx, &selection).unwrap();
        assert_eq!((tx.access_list.is_some(), tx.gas.is_some()), (false, true));
    }

    #[test]
    fn a_transaction_missing_a_selected_non_nullable_field_is_rejected() {
        let selection = [TransactionField::Gas];
        let tx = build_transaction(1, 0, &hash(1), Some(&json!({})), None, &selection).unwrap();
        let err = check_transaction(&tx, &selection).unwrap_err().to_string();
        assert!(err.contains("gas"), "{err}");
    }
}
