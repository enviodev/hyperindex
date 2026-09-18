//! Per-field RPC knowledge: which store column a requested field lands in,
//! which JSON-RPC response carries it, and how its raw value decodes.
//!
//! The store field enums are the single source of field identity — their
//! ordinal is the selection-mask bit and their `name()` is both the JS property
//! and, for every EVM field, the JSON-RPC response key. Decoding targets
//! `simple_types`, the same structs the HyperSync path fills, so both sources
//! share one column-fill and one materialisation path.
//!
//! Every match here is exhaustive: a new field cannot compile until its
//! carrier and its decoding are stated.

use anyhow::{anyhow, Context, Result};
use hypersync_client::format::{self, Hex};
use hypersync_client::simple_types::{Block, Transaction};
use serde_json::Value as Json;

use crate::block_store::EvmBlockField;
use crate::evm_hypersync_source::query::{BlockField, TransactionField};
use crate::transaction_store::EvmTxField;

/// Which JSON-RPC response carries a transaction field.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Carrier {
    /// Already known from the log that referenced the transaction, so it costs
    /// no request. `eth_getTransactionReceipt` spells the hash
    /// `transactionHash` rather than `hash`, which is one more reason not to
    /// read either from a response.
    Log,
    /// `eth_getTransactionByHash` only.
    Transaction,
    /// `eth_getTransactionReceipt` only.
    Receipt,
    /// Both carry it, so it comes from whichever is already being fetched.
    Either,
}

pub(crate) fn tx_carrier(field: EvmTxField) -> Carrier {
    use EvmTxField::*;
    match field {
        TransactionIndex | Hash => Carrier::Log,
        Gas | GasPrice | Input | Nonce | Value | V | R | S | YParity | MaxPriorityFeePerGas
        | MaxFeePerGas | MaxFeePerBlobGas | BlobVersionedHashes | AccessList
        | AuthorizationList => Carrier::Transaction,
        CumulativeGasUsed | EffectiveGasPrice | GasUsed | ContractAddress | LogsBloom | Root
        | Status | L1Fee | L1GasPrice | L1GasUsed | L1FeeScalar | GasUsedForL1 => Carrier::Receipt,
        From | To | Type => Carrier::Either,
    }
}

/// The store column a requested block field lands in. `None` for a field the
/// store holds no column for, which no user selection can reach — `Evm.res`
/// offers exactly the store's fields — so it can only mean a query built with a
/// field the store cannot serve.
pub(crate) fn block_field_column(field: BlockField) -> Option<EvmBlockField> {
    use BlockField as Q;
    Some(match field {
        Q::Number => EvmBlockField::Number,
        Q::Hash => EvmBlockField::Hash,
        Q::ParentHash => EvmBlockField::ParentHash,
        Q::Nonce => EvmBlockField::Nonce,
        Q::Sha3Uncles => EvmBlockField::Sha3Uncles,
        Q::LogsBloom => EvmBlockField::LogsBloom,
        Q::TransactionsRoot => EvmBlockField::TransactionsRoot,
        Q::StateRoot => EvmBlockField::StateRoot,
        Q::ReceiptsRoot => EvmBlockField::ReceiptsRoot,
        Q::Miner => EvmBlockField::Miner,
        Q::Difficulty => EvmBlockField::Difficulty,
        Q::TotalDifficulty => EvmBlockField::TotalDifficulty,
        Q::ExtraData => EvmBlockField::ExtraData,
        Q::Size => EvmBlockField::Size,
        Q::GasLimit => EvmBlockField::GasLimit,
        Q::GasUsed => EvmBlockField::GasUsed,
        Q::Timestamp => EvmBlockField::Timestamp,
        Q::Uncles => EvmBlockField::Uncles,
        Q::BaseFeePerGas => EvmBlockField::BaseFeePerGas,
        Q::BlobGasUsed => EvmBlockField::BlobGasUsed,
        Q::ExcessBlobGas => EvmBlockField::ExcessBlobGas,
        Q::ParentBeaconBlockRoot => EvmBlockField::ParentBeaconBlockRoot,
        Q::WithdrawalsRoot => EvmBlockField::WithdrawalsRoot,
        Q::L1BlockNumber => EvmBlockField::L1BlockNumber,
        Q::SendCount => EvmBlockField::SendCount,
        Q::SendRoot => EvmBlockField::SendRoot,
        Q::MixHash => EvmBlockField::MixHash,
        Q::Withdrawals => return None,
    })
}

/// The store column a requested transaction field lands in; see
/// `block_field_column` for what `None` means.
pub(crate) fn tx_field_column(field: TransactionField) -> Option<EvmTxField> {
    use TransactionField as Q;
    Some(match field {
        Q::TransactionIndex => EvmTxField::TransactionIndex,
        Q::Hash => EvmTxField::Hash,
        Q::From => EvmTxField::From,
        Q::To => EvmTxField::To,
        Q::Gas => EvmTxField::Gas,
        Q::GasPrice => EvmTxField::GasPrice,
        Q::MaxPriorityFeePerGas => EvmTxField::MaxPriorityFeePerGas,
        Q::MaxFeePerGas => EvmTxField::MaxFeePerGas,
        Q::CumulativeGasUsed => EvmTxField::CumulativeGasUsed,
        Q::EffectiveGasPrice => EvmTxField::EffectiveGasPrice,
        Q::GasUsed => EvmTxField::GasUsed,
        Q::Input => EvmTxField::Input,
        Q::Nonce => EvmTxField::Nonce,
        Q::Value => EvmTxField::Value,
        Q::V => EvmTxField::V,
        Q::R => EvmTxField::R,
        Q::S => EvmTxField::S,
        Q::ContractAddress => EvmTxField::ContractAddress,
        Q::LogsBloom => EvmTxField::LogsBloom,
        Q::Root => EvmTxField::Root,
        Q::Status => EvmTxField::Status,
        Q::YParity => EvmTxField::YParity,
        Q::MaxFeePerBlobGas => EvmTxField::MaxFeePerBlobGas,
        Q::BlobVersionedHashes => EvmTxField::BlobVersionedHashes,
        Q::Type => EvmTxField::Type,
        Q::L1Fee => EvmTxField::L1Fee,
        Q::L1GasPrice => EvmTxField::L1GasPrice,
        Q::L1GasUsed => EvmTxField::L1GasUsed,
        Q::L1FeeScalar => EvmTxField::L1FeeScalar,
        Q::GasUsedForL1 => EvmTxField::GasUsedForL1,
        Q::AccessList => EvmTxField::AccessList,
        Q::AuthorizationList => EvmTxField::AuthorizationList,
        Q::BlockHash
        | Q::BlockNumber
        | Q::ChainId
        | Q::L1BlockNumber
        | Q::L1BaseFeeScalar
        | Q::L1BlobBaseFee
        | Q::L1BlobBaseFeeScalar
        | Q::Sighash
        | Q::BlobGasPrice
        | Q::BlobGasUsed
        | Q::DepositNonce
        | Q::DepositReceiptVersion
        | Q::Mint
        | Q::SourceHash => return None,
    })
}

/// Selection mask over store field ordinals.
pub(crate) fn block_mask(fields: &[BlockField]) -> u64 {
    fields
        .iter()
        .filter_map(|&f| block_field_column(f))
        .fold(0, |acc, f| acc | 1u64 << (f as u32))
}

pub(crate) fn tx_mask(fields: &[TransactionField]) -> u64 {
    fields
        .iter()
        .filter_map(|&f| tx_field_column(f))
        .fold(0, |acc, f| acc | 1u64 << (f as u32))
}

/// The block field the store derives from its key, so a row always has it.
pub(crate) const BLOCK_KEY_MASK: u64 = 1u64 << (EvmBlockField::Number as u32);

/// The transaction fields the referencing log already carries, so they cost no
/// request and a row always has them.
pub(crate) const TX_LOG_MASK: u64 =
    (1u64 << (EvmTxField::TransactionIndex as u32)) | (1u64 << (EvmTxField::Hash as u32));

/// The reorg-detection fields every fetched block carries, whatever the user
/// selected: the key, the timestamp the indexer reports progress with, and the
/// two hashes a fork is detected by.
pub(crate) const BLOCK_OBSERVATION_MASK: u64 = BLOCK_KEY_MASK
    | (1u64 << (EvmBlockField::Timestamp as u32))
    | (1u64 << (EvmBlockField::Hash as u32))
    | (1u64 << (EvmBlockField::ParentHash as u32));

/// The requested fields a selection mask stands for — the inverse of
/// `block_mask`, for turning an accumulated need back into a fetch.
pub(crate) fn block_fields_in(mask: u64) -> Vec<BlockField> {
    use strum::VariantArray;
    BlockField::VARIANTS
        .iter()
        .copied()
        .filter(|&f| block_field_column(f).is_some_and(|c| mask & (1u64 << (c as u32)) != 0))
        .collect()
}

pub(crate) fn tx_fields_in(mask: u64) -> Vec<TransactionField> {
    use strum::VariantArray;
    TransactionField::VARIANTS
        .iter()
        .copied()
        .filter(|&f| tx_field_column(f).is_some_and(|c| mask & (1u64 << (c as u32)) != 0))
        .collect()
}

/// Decode a hex-string response value into one of the format newtypes. Every
/// EVM field but the three below arrives as a 0x-prefixed string.
fn hex_value<T: Hex>(field: &str, raw: &Json) -> Result<T> {
    let text = raw
        .as_str()
        .ok_or_else(|| anyhow!("expected a hex string, got {raw}"))
        .with_context(|| format!("field {field:?}"))?;
    T::decode_hex(text)
        .map_err(|e| anyhow!("{e}"))
        .with_context(|| format!("field {field:?} value {text:?}"))
}

fn hash_list(field: &str, raw: &Json) -> Result<Vec<format::Hash>> {
    raw.as_array()
        .ok_or_else(|| anyhow!("expected an array, got {raw}"))
        .with_context(|| format!("field {field:?}"))?
        .iter()
        .map(|item| hex_value(field, item))
        .collect()
}

/// `l1FeeScalar` is the one EVM field a provider serves as a decimal rather
/// than hex, and some serve it as a JSON number rather than a string.
fn decimal_f64(field: &str, raw: &Json) -> Result<f64> {
    match raw {
        Json::Number(n) => n
            .as_f64()
            .ok_or_else(|| anyhow!("field {field:?} number {n} is not representable")),
        Json::String(s) => s
            .parse()
            .with_context(|| format!("field {field:?} value {s:?} is not a decimal")),
        other => Err(anyhow!("field {field:?} expected a decimal, got {other}")),
    }
}

fn from_json<T: serde::de::DeserializeOwned>(field: &str, raw: &Json) -> Result<T> {
    serde_json::from_value(raw.clone()).with_context(|| format!("field {field:?}"))
}

/// Assign one decoded block field. `raw` is the response value under the
/// field's own name; a null or absent value is handled by the caller, which
/// knows whether the field is allowed to be missing.
pub(crate) fn set_block_field(block: &mut Block, field: EvmBlockField, raw: &Json) -> Result<()> {
    use EvmBlockField::*;
    let name = field.name();
    match field {
        Number => block.number = Some(hex_value::<format::BlockNumber>(name, raw)?.into()),
        Timestamp => block.timestamp = Some(hex_value(name, raw)?),
        Hash => block.hash = Some(hex_value(name, raw)?),
        ParentHash => block.parent_hash = Some(hex_value(name, raw)?),
        Nonce => block.nonce = Some(hex_value(name, raw)?),
        Sha3Uncles => block.sha3_uncles = Some(hex_value(name, raw)?),
        LogsBloom => block.logs_bloom = Some(hex_value(name, raw)?),
        TransactionsRoot => block.transactions_root = Some(hex_value(name, raw)?),
        StateRoot => block.state_root = Some(hex_value(name, raw)?),
        ReceiptsRoot => block.receipts_root = Some(hex_value(name, raw)?),
        Miner => block.miner = Some(hex_value(name, raw)?),
        Difficulty => block.difficulty = Some(hex_value(name, raw)?),
        TotalDifficulty => block.total_difficulty = Some(hex_value(name, raw)?),
        ExtraData => block.extra_data = Some(hex_value(name, raw)?),
        Size => block.size = Some(hex_value(name, raw)?),
        GasLimit => block.gas_limit = Some(hex_value(name, raw)?),
        GasUsed => block.gas_used = Some(hex_value(name, raw)?),
        Uncles => block.uncles = Some(hash_list(name, raw)?),
        BaseFeePerGas => block.base_fee_per_gas = Some(hex_value(name, raw)?),
        BlobGasUsed => block.blob_gas_used = Some(hex_value(name, raw)?),
        ExcessBlobGas => block.excess_blob_gas = Some(hex_value(name, raw)?),
        ParentBeaconBlockRoot => block.parent_beacon_block_root = Some(hex_value(name, raw)?),
        WithdrawalsRoot => block.withdrawals_root = Some(hex_value(name, raw)?),
        L1BlockNumber => block.l1_block_number = Some(hex_value(name, raw)?),
        SendCount => block.send_count = Some(hex_value(name, raw)?),
        SendRoot => block.send_root = Some(hex_value(name, raw)?),
        MixHash => block.mix_hash = Some(hex_value(name, raw)?),
    }
    Ok(())
}

/// Assign one decoded transaction field. The two `Carrier::Log` fields are set
/// from the log by the caller and never reach here.
pub(crate) fn set_tx_field(tx: &mut Transaction, field: EvmTxField, raw: &Json) -> Result<()> {
    use EvmTxField::*;
    let name = field.name();
    match field {
        TransactionIndex => {
            tx.transaction_index = Some(hex_value::<format::TransactionIndex>(name, raw)?)
        }
        Hash => tx.hash = Some(hex_value(name, raw)?),
        From => tx.from = Some(hex_value(name, raw)?),
        To => tx.to = Some(hex_value(name, raw)?),
        Gas => tx.gas = Some(hex_value(name, raw)?),
        GasPrice => tx.gas_price = Some(hex_value(name, raw)?),
        MaxPriorityFeePerGas => tx.max_priority_fee_per_gas = Some(hex_value(name, raw)?),
        MaxFeePerGas => tx.max_fee_per_gas = Some(hex_value(name, raw)?),
        CumulativeGasUsed => tx.cumulative_gas_used = Some(hex_value(name, raw)?),
        EffectiveGasPrice => tx.effective_gas_price = Some(hex_value(name, raw)?),
        GasUsed => tx.gas_used = Some(hex_value(name, raw)?),
        Input => tx.input = Some(hex_value(name, raw)?),
        Nonce => tx.nonce = Some(hex_value(name, raw)?),
        Value => tx.value = Some(hex_value(name, raw)?),
        V => tx.v = Some(hex_value(name, raw)?),
        R => tx.r = Some(hex_value(name, raw)?),
        S => tx.s = Some(hex_value(name, raw)?),
        ContractAddress => tx.contract_address = Some(hex_value(name, raw)?),
        LogsBloom => tx.logs_bloom = Some(hex_value(name, raw)?),
        Root => tx.root = Some(hex_value(name, raw)?),
        Status => tx.status = Some(hex_value(name, raw)?),
        YParity => tx.y_parity = Some(hex_value(name, raw)?),
        MaxFeePerBlobGas => tx.max_fee_per_blob_gas = Some(hex_value(name, raw)?),
        BlobVersionedHashes => tx.blob_versioned_hashes = Some(hash_list(name, raw)?),
        Type => tx.type_ = Some(hex_value(name, raw)?),
        L1Fee => tx.l1_fee = Some(hex_value(name, raw)?),
        L1GasPrice => tx.l1_gas_price = Some(hex_value(name, raw)?),
        L1GasUsed => tx.l1_gas_used = Some(hex_value(name, raw)?),
        L1FeeScalar => tx.l1_fee_scalar = Some(decimal_f64(name, raw)?),
        GasUsedForL1 => tx.gas_used_for_l1 = Some(hex_value(name, raw)?),
        AccessList => tx.access_list = Some(from_json(name, raw)?),
        AuthorizationList => tx.authorization_list = Some(from_json(name, raw)?),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use strum::VariantArray;

    #[test]
    fn the_list_shaped_transaction_fields_decode() {
        // The per-column pin gives each field a value only it could have, which
        // a list rendered by its length cannot be; these two are checked here
        // against their real response shapes instead.
        let mut tx = Transaction::default();
        set_tx_field(
            &mut tx,
            EvmTxField::AccessList,
            &json!([{
                "address": "0x".to_string() + &"22".repeat(20),
                "storageKeys": ["0x".to_string() + &"11".repeat(32)],
            }]),
        )
        .unwrap();
        set_tx_field(
            &mut tx,
            EvmTxField::AuthorizationList,
            &json!([{
                "chainId": "0x1",
                "address": "0x".to_string() + &"22".repeat(20),
                "nonce": "0x1",
                "yParity": "0x0",
                "r": "0x1",
                "s": "0x1",
            }]),
        )
        .unwrap();
        assert_eq!(
            (
                tx.access_list
                    .as_ref()
                    .and_then(|list| list.first())
                    .and_then(|entry| entry.storage_keys.as_ref())
                    .map(Vec::len),
                tx.authorization_list
                    .as_ref()
                    .and_then(|list| list.first())
                    .map(|entry| entry.address.encode_hex()),
            ),
            (Some(1), Some(format!("0x{}", "22".repeat(20))))
        );
    }

    #[test]
    fn a_decimal_field_reads_from_a_string_or_a_bare_number() {
        // Providers differ on whether `l1FeeScalar` is quoted.
        let mut from_string = Transaction::default();
        set_tx_field(&mut from_string, EvmTxField::L1FeeScalar, &json!("1.5")).unwrap();
        let mut from_number = Transaction::default();
        set_tx_field(&mut from_number, EvmTxField::L1FeeScalar, &json!(1.5)).unwrap();
        assert_eq!(
            (from_string.l1_fee_scalar, from_number.l1_fee_scalar),
            (Some(1.5), Some(1.5))
        );
    }

    #[test]
    fn a_malformed_value_names_the_field_it_came_from() {
        let mut block = Block::default();
        let err = set_block_field(&mut block, EvmBlockField::Timestamp, &json!("nope"))
            .unwrap_err()
            .to_string();
        assert!(err.contains("timestamp"), "{err}");
    }

    #[test]
    fn every_store_field_is_reachable_from_a_requested_field() {
        // The two conversions are the only way a selection reaches a column, so
        // a store field no requested field maps onto would be unselectable.
        let blocks: Vec<EvmBlockField> = BlockField::VARIANTS
            .iter()
            .filter_map(|&f| block_field_column(f))
            .collect();
        let txs: Vec<EvmTxField> = TransactionField::VARIANTS
            .iter()
            .filter_map(|&f| tx_field_column(f))
            .collect();
        assert_eq!(
            (
                EvmBlockField::VARIANTS.iter().all(|f| blocks.contains(f)),
                EvmTxField::VARIANTS.iter().all(|f| txs.contains(f)),
            ),
            (true, true)
        );
    }
}
