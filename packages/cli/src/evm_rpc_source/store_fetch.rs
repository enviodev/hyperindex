//! Bulk block/transaction/receipt fetching for the RPC source. After
//! `eth_getLogs`, the routed items' registrations decide which blocks and
//! transactions the page needs; those are fetched concurrently and inserted
//! into the page's `BlockStore`/`TransactionStore` as raw rows, the same shape
//! the HyperSync source builds. A key whose data the provider answered `null`
//! for (a load-balanced node drifting behind the head) is returned as still
//! missing rather than retried here — SourceManager owns that retry, through
//! `EvmRpcClient::fetch_store_data`.

use std::collections::HashMap;
use std::time::Instant;

use hypersync_client::format::{Data, FixedSizeData, Hash, Hex, Quantity, TransactionType};
use hypersync_client::simple_types;
use napi_derive::napi;
use serde::{Deserialize, Deserializer};
use serde_json::json;

use crate::block_store::BlockStore;
use crate::evm_hypersync_source::query::{BlockField, TransactionField};
use crate::evm_hypersync_source::types::OnEventRegistrationInput;
use crate::evm_hypersync_source::{
    block_field_missing, transaction_field_missing, REQUIRED_BLOCK_FIELDS,
};
use crate::request_stats::RequestStat;
use crate::transaction_store::TransactionStore;

use super::client::{JsonRpcClient, RpcError};

/// At most this many block/transaction requests in flight at once per page,
/// so a dense page doesn't stampede the provider.
const STORE_FETCH_CONCURRENCY: usize = 10;

// ============== Field classification ==============

enum TxFieldSource {
    /// Only `eth_getTransactionByHash` carries it.
    Transaction,
    /// Only `eth_getTransactionReceipt` carries it.
    Receipt,
    /// Both calls carry it.
    Both,
    /// Derived from the log itself; no extra request.
    Log,
}

/// Which RPC call serves a transaction field, or `None` for fields RPC cannot
/// deliver at all. The unsupported set must stay in step with the
/// `RpcTransactionField` subenum in `human_config.rs`, which rejects them from
/// an RPC-synced chain's field selection before the indexer starts.
fn rpc_tx_field_source(field: TransactionField) -> Option<TxFieldSource> {
    use TransactionField::*;
    match field {
        Gas | GasPrice | Input | Nonce | Value | V | R | S | YParity | MaxPriorityFeePerGas
        | MaxFeePerGas | MaxFeePerBlobGas | BlobVersionedHashes => Some(TxFieldSource::Transaction),
        GasUsed | CumulativeGasUsed | EffectiveGasPrice | ContractAddress | LogsBloom | Root
        | Status | L1Fee | L1GasPrice | L1GasUsed | L1FeeScalar | GasUsedForL1 => {
            Some(TxFieldSource::Receipt)
        }
        From | To | Type => Some(TxFieldSource::Both),
        Hash | TransactionIndex => Some(TxFieldSource::Log),
        BlockHash
        | BlockNumber
        | ChainId
        | AccessList
        | AuthorizationList
        | L1BlockNumber
        | L1BaseFeeScalar
        | L1BlobBaseFee
        | L1BlobBaseFeeScalar
        | Sighash
        | BlobGasPrice
        | BlobGasUsed
        | DepositNonce
        | DepositReceiptVersion
        | Mint
        | SourceHash => None,
    }
}

/// Whether `eth_getBlockByNumber` serves this block field. `Withdrawals` has no
/// store column, so it is the one selection RPC skips.
fn rpc_supports_block_field(field: BlockField) -> bool {
    !matches!(field, BlockField::Withdrawals)
}

/// What one registration's field selection demands per routed log, resolved
/// once at client construction.
pub(crate) struct RegistrationNeeds {
    /// Supported block fields, for validating a fetched block.
    pub block_fields: Vec<BlockField>,
    /// True when the selection needs data only `eth_getBlockByNumber` has:
    /// anything besides `number` (the store key) and `hash` (on the log).
    pub needs_block_fetch: bool,
    /// Supported transaction fields, for validating the merged transaction.
    pub tx_fields: Vec<TransactionField>,
    pub fetch_transaction: bool,
    pub fetch_receipt: bool,
    pub needs_effective_gas_price: bool,
    /// True when any transaction field is selected at all — the store then
    /// needs a row for the key, even if it's log-derived only.
    pub has_tx_row: bool,
}

pub(crate) fn registration_needs(reg: &OnEventRegistrationInput) -> RegistrationNeeds {
    let block_fields: Vec<BlockField> = reg
        .block_fields
        .iter()
        .copied()
        .filter(|&f| rpc_supports_block_field(f))
        .collect();
    let needs_block_fetch = block_fields
        .iter()
        .any(|&f| !matches!(f, BlockField::Number | BlockField::Hash));

    let mut tx_fields: Vec<TransactionField> = Vec::new();
    let mut tx_only = false;
    let mut receipt_only = false;
    let mut both = false;
    let mut needs_effective_gas_price = false;
    for &field in &reg.transaction_fields {
        match rpc_tx_field_source(field) {
            Some(TxFieldSource::Transaction) => tx_only = true,
            Some(TxFieldSource::Receipt) => {
                receipt_only = true;
                if field == TransactionField::EffectiveGasPrice {
                    needs_effective_gas_price = true;
                }
            }
            Some(TxFieldSource::Both) => both = true,
            Some(TxFieldSource::Log) => {}
            None => continue,
        }
        tx_fields.push(field);
    }

    // Mirrors the old strategy table: `Both` fields ride on the receipt only
    // when that's the single call already being made; otherwise the
    // transaction call serves them.
    let fetch_receipt = receipt_only;
    let fetch_transaction = tx_only || (both && !receipt_only);

    RegistrationNeeds {
        block_fields,
        needs_block_fetch,
        has_tx_row: !tx_fields.is_empty(),
        tx_fields,
        fetch_transaction,
        fetch_receipt,
        needs_effective_gas_price,
    }
}

// ============== Fetch plans (needs) ==============

#[derive(Clone)]
pub(crate) struct BlockNeed {
    pub number: u64,
    /// Selected fields to validate on the fetched block. Empty for the range's
    /// endpoint blocks, which are held only to the required trio.
    pub fields: Vec<BlockField>,
}

#[derive(Clone)]
pub(crate) struct TxNeed {
    pub block_number: u64,
    pub transaction_index: u32,
    pub transaction_hash: String,
    pub fetch_transaction: bool,
    pub fetch_receipt: bool,
    pub needs_effective_gas_price: bool,
    /// Selected fields to validate on the merged transaction.
    pub fields: Vec<TransactionField>,
}

fn union_fields<T: Copy + PartialEq>(dst: &mut Vec<T>, src: &[T]) {
    for &f in src {
        if !dst.contains(&f) {
            dst.push(f);
        }
    }
}

/// Accumulates per-key unions of what the page's items need, in the order keys
/// are first seen.
#[derive(Default)]
pub(crate) struct StoreFetchPlan {
    block_order: Vec<u64>,
    blocks: HashMap<u64, BlockNeed>,
    tx_order: Vec<(u64, u32)>,
    txs: HashMap<(u64, u32), TxNeed>,
}

impl StoreFetchPlan {
    pub(crate) fn add_block(&mut self, number: u64, fields: &[BlockField]) {
        match self.blocks.get_mut(&number) {
            Some(need) => union_fields(&mut need.fields, fields),
            None => {
                self.block_order.push(number);
                self.blocks.insert(
                    number,
                    BlockNeed {
                        number,
                        fields: fields.to_vec(),
                    },
                );
            }
        }
    }

    pub(crate) fn add_item(
        &mut self,
        needs: &RegistrationNeeds,
        block_number: u64,
        transaction_index: u32,
        transaction_hash: &str,
    ) {
        if needs.needs_block_fetch {
            self.add_block(block_number, &needs.block_fields);
        }
        if needs.fetch_transaction || needs.fetch_receipt {
            let key = (block_number, transaction_index);
            match self.txs.get_mut(&key) {
                Some(need) => {
                    need.fetch_transaction |= needs.fetch_transaction;
                    need.fetch_receipt |= needs.fetch_receipt;
                    need.needs_effective_gas_price |= needs.needs_effective_gas_price;
                    union_fields(&mut need.fields, &needs.tx_fields);
                }
                None => {
                    self.tx_order.push(key);
                    self.txs.insert(
                        key,
                        TxNeed {
                            block_number,
                            transaction_index,
                            transaction_hash: transaction_hash.to_string(),
                            fetch_transaction: needs.fetch_transaction,
                            fetch_receipt: needs.fetch_receipt,
                            needs_effective_gas_price: needs.needs_effective_gas_price,
                            fields: needs.tx_fields.clone(),
                        },
                    );
                }
            }
        }
    }

    pub(crate) fn into_needs(mut self) -> (Vec<BlockNeed>, Vec<TxNeed>) {
        let blocks = self
            .block_order
            .iter()
            .map(|n| self.blocks.remove(n).unwrap())
            .collect();
        let txs = self
            .tx_order
            .iter()
            .map(|k| self.txs.remove(k).unwrap())
            .collect();
        (blocks, txs)
    }
}

// ============== Missing-data DTOs (napi) ==============

/// One block the source could not load (the provider answered `null` or
/// errored). Echoed back verbatim to `fetch_store_data` so the retry knows
/// exactly what to fetch and validate.
#[napi(object)]
#[derive(Clone)]
pub struct MissingBlockData {
    pub block_number: i64,
    pub fields: Vec<BlockField>,
}

/// One transaction the source could not load, with the calls it needs.
#[napi(object)]
#[derive(Clone)]
pub struct MissingTransactionData {
    pub block_number: i64,
    pub transaction_index: i64,
    pub transaction_hash: String,
    pub fetch_transaction: bool,
    pub fetch_receipt: bool,
    pub needs_effective_gas_price: bool,
    pub fields: Vec<TransactionField>,
}

/// Block/transaction store rows a response failed to load. SourceManager keeps
/// calling `fetch_store_data` with the remainder until it is empty.
#[napi(object)]
#[derive(Clone)]
pub struct MissingStoreData {
    pub blocks: Vec<MissingBlockData>,
    pub transactions: Vec<MissingTransactionData>,
    /// The last fetch error observed, for the retry log. `None` when every
    /// missing key was a clean `null` response.
    pub sample_error: Option<String>,
}

impl MissingStoreData {
    pub fn is_empty(&self) -> bool {
        self.blocks.is_empty() && self.transactions.is_empty()
    }
}

pub(crate) fn missing_to_needs(
    missing: MissingStoreData,
) -> anyhow::Result<(Vec<BlockNeed>, Vec<TxNeed>)> {
    let blocks = missing
        .blocks
        .into_iter()
        .map(|b| {
            Ok(BlockNeed {
                number: u64::try_from(b.block_number)
                    .map_err(|_| anyhow::anyhow!("missing block number must be non-negative"))?,
                fields: b.fields,
            })
        })
        .collect::<anyhow::Result<Vec<_>>>()?;
    let txs = missing
        .transactions
        .into_iter()
        .map(|t| {
            Ok(TxNeed {
                block_number: u64::try_from(t.block_number)
                    .map_err(|_| anyhow::anyhow!("missing tx block number must be non-negative"))?,
                transaction_index: u32::try_from(t.transaction_index).map_err(|_| {
                    anyhow::anyhow!("missing tx transaction index must be non-negative")
                })?,
                transaction_hash: t.transaction_hash,
                fetch_transaction: t.fetch_transaction,
                fetch_receipt: t.fetch_receipt,
                needs_effective_gas_price: t.needs_effective_gas_price,
                fields: t.fields,
            })
        })
        .collect::<anyhow::Result<Vec<_>>>()?;
    Ok((blocks, txs))
}

fn needs_to_missing(
    blocks: Vec<BlockNeed>,
    txs: Vec<TxNeed>,
    sample_error: Option<String>,
) -> MissingStoreData {
    MissingStoreData {
        blocks: blocks
            .into_iter()
            .map(|b| MissingBlockData {
                block_number: b.number as i64,
                fields: b.fields,
            })
            .collect(),
        transactions: txs
            .into_iter()
            .map(|t| MissingTransactionData {
                block_number: t.block_number as i64,
                transaction_index: t.transaction_index as i64,
                transaction_hash: t.transaction_hash,
                fetch_transaction: t.fetch_transaction,
                fetch_receipt: t.fetch_receipt,
                needs_effective_gas_price: t.needs_effective_gas_price,
                fields: t.fields,
            })
            .collect(),
        sample_error,
    }
}

// ============== JSON-RPC response DTOs ==============

/// `l1FeeScalar` comes back as a decimal string (e.g. `"0.684"`), not hex.
fn deserialize_decimal_f64<'de, D: Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<f64>, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Raw {
        Str(String),
        Num(f64),
    }
    match Option::<Raw>::deserialize(deserializer)? {
        None => Ok(None),
        Some(Raw::Num(v)) => Ok(Some(v)),
        Some(Raw::Str(s)) => s
            .parse::<f64>()
            .map(Some)
            .map_err(|e| serde::de::Error::custom(format!("invalid decimal number {s:?}: {e}"))),
    }
}

/// A block-header `nonce` is nominally 8 bytes, but some chains serve it as a
/// short quantity; pad it to the fixed width the store row expects.
fn deserialize_nonce<'de, D: Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<FixedSizeData<8>>, D::Error> {
    match Option::<Quantity>::deserialize(deserializer)? {
        None => Ok(None),
        Some(q) => {
            let bytes: &[u8] = q.as_ref();
            if bytes.len() > 8 {
                return Err(serde::de::Error::custom(format!(
                    "block.nonce is wider than 8 bytes: {}",
                    bytes.len()
                )));
            }
            let mut buf = [0u8; 8];
            buf[8 - bytes.len()..].copy_from_slice(bytes);
            Ok(Some(FixedSizeData::from(buf)))
        }
    }
}

/// Raw `eth_getBlockByNumber` response. Every field is optional so that the
/// validation below — not serde — decides what a chain must serve, and unknown
/// extra fields are ignored. The hypersync-format value types parse the same
/// 0x-hex encodings the provider uses.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RpcBlock {
    number: Option<hypersync_client::format::BlockNumber>,
    hash: Option<Hash>,
    parent_hash: Option<Hash>,
    timestamp: Option<Quantity>,
    #[serde(default, deserialize_with = "deserialize_nonce")]
    nonce: Option<FixedSizeData<8>>,
    sha3_uncles: Option<Hash>,
    logs_bloom: Option<Data>,
    transactions_root: Option<Hash>,
    state_root: Option<Hash>,
    receipts_root: Option<Hash>,
    miner: Option<hypersync_client::format::Address>,
    difficulty: Option<Quantity>,
    total_difficulty: Option<Quantity>,
    extra_data: Option<Data>,
    size: Option<Quantity>,
    gas_limit: Option<Quantity>,
    gas_used: Option<Quantity>,
    uncles: Option<Vec<Hash>>,
    base_fee_per_gas: Option<Quantity>,
    blob_gas_used: Option<Quantity>,
    excess_blob_gas: Option<Quantity>,
    parent_beacon_block_root: Option<Hash>,
    withdrawals_root: Option<Hash>,
    l1_block_number: Option<hypersync_client::format::BlockNumber>,
    send_count: Option<Quantity>,
    send_root: Option<Hash>,
    mix_hash: Option<Hash>,
}

impl RpcBlock {
    fn into_simple(self) -> simple_types::Block {
        simple_types::Block {
            number: self.number.map(u64::from),
            hash: self.hash,
            parent_hash: self.parent_hash,
            timestamp: self.timestamp,
            nonce: self.nonce,
            sha3_uncles: self.sha3_uncles,
            logs_bloom: self.logs_bloom,
            transactions_root: self.transactions_root,
            state_root: self.state_root,
            receipts_root: self.receipts_root,
            miner: self.miner,
            difficulty: self.difficulty,
            total_difficulty: self.total_difficulty,
            extra_data: self.extra_data,
            size: self.size,
            gas_limit: self.gas_limit,
            gas_used: self.gas_used,
            uncles: self.uncles,
            base_fee_per_gas: self.base_fee_per_gas,
            blob_gas_used: self.blob_gas_used,
            excess_blob_gas: self.excess_blob_gas,
            parent_beacon_block_root: self.parent_beacon_block_root,
            withdrawals_root: self.withdrawals_root,
            l1_block_number: self.l1_block_number,
            send_count: self.send_count,
            send_root: self.send_root,
            mix_hash: self.mix_hash,
            ..Default::default()
        }
    }
}

/// Raw `eth_getTransactionByHash` response (the fields RPC can serve).
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RpcTransaction {
    from: Option<hypersync_client::format::Address>,
    to: Option<hypersync_client::format::Address>,
    #[serde(rename = "type")]
    type_: Option<TransactionType>,
    gas: Option<Quantity>,
    gas_price: Option<Quantity>,
    input: Option<Data>,
    nonce: Option<Quantity>,
    value: Option<Quantity>,
    v: Option<Quantity>,
    r: Option<Quantity>,
    s: Option<Quantity>,
    y_parity: Option<Quantity>,
    max_priority_fee_per_gas: Option<Quantity>,
    max_fee_per_gas: Option<Quantity>,
    max_fee_per_blob_gas: Option<Quantity>,
    blob_versioned_hashes: Option<Vec<Hash>>,
}

/// Raw `eth_getTransactionReceipt` response (the fields RPC can serve).
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RpcReceipt {
    from: Option<hypersync_client::format::Address>,
    to: Option<hypersync_client::format::Address>,
    #[serde(rename = "type")]
    type_: Option<TransactionType>,
    gas_used: Option<Quantity>,
    cumulative_gas_used: Option<Quantity>,
    effective_gas_price: Option<Quantity>,
    contract_address: Option<hypersync_client::format::Address>,
    logs_bloom: Option<Data>,
    root: Option<Hash>,
    status: Option<hypersync_client::format::TransactionStatus>,
    l1_fee: Option<Quantity>,
    l1_gas_price: Option<Quantity>,
    l1_gas_used: Option<Quantity>,
    #[serde(default, deserialize_with = "deserialize_decimal_f64")]
    l1_fee_scalar: Option<f64>,
    gas_used_for_l1: Option<Quantity>,
}

// ============== Errors ==============

/// A response that can never satisfy the field selection, however often it is
/// retried. Surfaced to JS as a `FieldSelectionError` payload, which the
/// source maps to the source-disabling `FailedGettingFieldSelection`.
pub(crate) struct FieldSelectionError {
    pub block_number: u64,
    pub message: String,
}

pub(crate) fn field_selection_error_to_napi(e: FieldSelectionError) -> napi::Error {
    let payload = json!({
        "kind": "FieldSelectionError",
        "blockNumber": e.block_number,
        "message": e.message,
    })
    .to_string();
    napi::Error::from_reason(payload)
}

// ============== Row assembly & validation ==============

/// Log-derived transaction row: the store key plus the hash off the log. This
/// is all a `hash`/`transactionIndex`-only selection needs, with no request.
pub(crate) fn log_derived_tx_row(
    block_number: u64,
    transaction_index: u32,
    transaction_hash: &str,
) -> anyhow::Result<simple_types::Transaction> {
    Ok(simple_types::Transaction {
        block_number: Some(block_number.into()),
        transaction_index: Some(u64::from(transaction_index).into()),
        hash: Some(
            Hash::decode_hex(transaction_hash)
                .map_err(|e| anyhow::anyhow!("decode log.transactionHash hex: {e}"))?,
        ),
        ..Default::default()
    })
}

/// Hash-only block row from a log's own `blockHash` observation.
pub(crate) fn log_observed_block_row(
    block_number: u64,
    block_hash: &str,
) -> anyhow::Result<simple_types::Block> {
    Ok(simple_types::Block {
        number: Some(block_number),
        hash: Some(
            Hash::decode_hex(block_hash)
                .map_err(|e| anyhow::anyhow!("decode log.blockHash hex: {e}"))?,
        ),
        ..Default::default()
    })
}

fn merge_transaction(
    need: &TxNeed,
    tx: Option<RpcTransaction>,
    receipt: Option<RpcReceipt>,
) -> Result<simple_types::Transaction, FieldSelectionError> {
    let hash = Hash::decode_hex(&need.transaction_hash).map_err(|e| FieldSelectionError {
        block_number: need.block_number,
        message: format!(
            "Invalid transaction hash {:?} on a log from the RPC response: {e}",
            need.transaction_hash
        ),
    })?;

    let mut merged = simple_types::Transaction {
        block_number: Some(need.block_number.into()),
        transaction_index: Some(u64::from(need.transaction_index).into()),
        hash: Some(hash),
        ..Default::default()
    };

    if let Some(receipt) = receipt {
        merged.from = receipt.from;
        merged.to = receipt.to;
        merged.type_ = receipt.type_;
        merged.gas_used = receipt.gas_used;
        merged.cumulative_gas_used = receipt.cumulative_gas_used;
        merged.effective_gas_price = receipt.effective_gas_price;
        merged.contract_address = receipt.contract_address;
        merged.logs_bloom = receipt.logs_bloom;
        merged.root = receipt.root;
        merged.status = receipt.status;
        merged.l1_fee = receipt.l1_fee;
        merged.l1_gas_price = receipt.l1_gas_price;
        merged.l1_gas_used = receipt.l1_gas_used;
        merged.l1_fee_scalar = receipt.l1_fee_scalar;
        merged.gas_used_for_l1 = receipt.gas_used_for_l1;
    }
    if let Some(tx) = tx {
        merged.from = merged.from.or(tx.from);
        merged.to = merged.to.or(tx.to);
        merged.type_ = merged.type_.or(tx.type_);
        merged.gas = tx.gas;
        merged.input = tx.input;
        merged.nonce = tx.nonce;
        merged.value = tx.value;
        merged.v = tx.v;
        merged.r = tx.r;
        merged.s = tx.s;
        merged.y_parity = tx.y_parity;
        merged.max_priority_fee_per_gas = tx.max_priority_fee_per_gas;
        merged.max_fee_per_gas = tx.max_fee_per_gas;
        merged.max_fee_per_blob_gas = tx.max_fee_per_blob_gas;
        merged.blob_versioned_hashes = tx.blob_versioned_hashes;

        // Pre-EIP-1559 receipts carry no `effectiveGasPrice` — every Optimism
        // block below the Bedrock migration, for one. Those chains price every
        // transaction the legacy way, so the transaction's `gasPrice` is the
        // effective price — the same substitution HyperSync serves.
        if need.needs_effective_gas_price && merged.effective_gas_price.is_none() {
            match tx.gas_price {
                Some(gas_price) => merged.effective_gas_price = Some(gas_price),
                None => {
                    return Err(FieldSelectionError {
                        block_number: need.block_number,
                        message: "Neither \"effectiveGasPrice\" nor \"gasPrice\" is present in \
                                  the RPC response for the transaction. Remove \
                                  \"effectiveGasPrice\" from the field selection, or index this \
                                  chain via HyperSync."
                            .to_string(),
                    })
                }
            }
        }
    }

    let mut missing = Vec::new();
    for &field in &need.fields {
        if let Some(name) = transaction_field_missing(&merged, field) {
            missing.push(format!("transaction.{name}"));
        }
    }
    if !missing.is_empty() {
        return Err(FieldSelectionError {
            block_number: need.block_number,
            message: format!(
                "The RPC response for transaction {} is missing the selected non-nullable \
                 fields: {}. Please double-check your RPC provider returns correct data.",
                need.transaction_hash,
                missing.join(", ")
            ),
        });
    }

    Ok(merged)
}

fn validate_block(
    need: &BlockNeed,
    block: &simple_types::Block,
) -> Result<(), FieldSelectionError> {
    let mut missing = Vec::new();
    for &field in REQUIRED_BLOCK_FIELDS {
        if let Some(name) = block_field_missing(block, field) {
            missing.push(format!("block.{name}"));
        }
    }
    for &field in &need.fields {
        if REQUIRED_BLOCK_FIELDS.contains(&field) {
            continue;
        }
        if let Some(name) = block_field_missing(block, field) {
            missing.push(format!("block.{name}"));
        }
    }
    if !missing.is_empty() {
        return Err(FieldSelectionError {
            block_number: need.number,
            message: format!(
                "The RPC response for block {} is missing the selected non-nullable fields: {}. \
                 Please double-check your RPC provider returns correct data.",
                need.number,
                missing.join(", ")
            ),
        });
    }
    Ok(())
}

// ============== Fetch engine ==============

enum FetchOutcome<T> {
    Data(T),
    /// The provider answered `null` — the serving node hasn't caught up.
    NullData,
    /// Transient failure (transport, provider error, mismatched response).
    Failed(String),
}

enum JobResult {
    Block {
        need: BlockNeed,
        outcome: Box<FetchOutcome<simple_types::Block>>,
        stats: Vec<RequestStat>,
    },
    Tx {
        need: TxNeed,
        outcome: Box<FetchOutcome<simple_types::Transaction>>,
        stats: Vec<RequestStat>,
    },
    Fatal {
        error: FieldSelectionError,
        stats: Vec<RequestStat>,
    },
}

fn rpc_error_message(e: &RpcError) -> String {
    match e {
        RpcError::JsonRpc { code, message } => format!("JSON-RPC error {code}: {message}"),
        RpcError::Other(e) => format!("{e:#}"),
    }
}

async fn fetch_block_job(client: &JsonRpcClient, need: BlockNeed) -> JobResult {
    let started = Instant::now();
    let result: Result<Option<RpcBlock>, RpcError> = client
        .request(
            "eth_getBlockByNumber",
            json!([format!("0x{:x}", need.number), false]),
        )
        .await;
    let stats = vec![RequestStat {
        method: "eth_getBlockByNumber".to_string(),
        seconds: started.elapsed().as_secs_f64(),
    }];
    let outcome = match result {
        Ok(None) => FetchOutcome::NullData,
        Ok(Some(raw)) => {
            let mut block = raw.into_simple();
            match block.number {
                // Key the row by the number that was asked for; a response
                // claiming another number is a mismatched answer, not data.
                Some(number) if number != need.number => FetchOutcome::Failed(format!(
                    "eth_getBlockByNumber returned block {number} for a request of block {}",
                    need.number
                )),
                _ => {
                    block.number = Some(need.number);
                    match validate_block(&need, &block) {
                        Ok(()) => FetchOutcome::Data(block),
                        Err(error) => return JobResult::Fatal { error, stats },
                    }
                }
            }
        }
        Err(e) => FetchOutcome::Failed(rpc_error_message(&e)),
    };
    JobResult::Block {
        need,
        outcome: Box::new(outcome),
        stats,
    }
}

async fn fetch_tx_job(client: &JsonRpcClient, need: TxNeed) -> JobResult {
    let mut stats = Vec::new();
    let request = |method: &'static str| {
        let params = json!([need.transaction_hash]);
        (method, params)
    };

    let mut tx: Option<RpcTransaction> = None;
    let mut receipt: Option<RpcReceipt> = None;

    let mut fetch_tx = need.fetch_transaction;
    if need.fetch_receipt {
        let (method, params) = request("eth_getTransactionReceipt");
        let started = Instant::now();
        let result: Result<Option<RpcReceipt>, RpcError> = client.request(method, params).await;
        stats.push(RequestStat {
            method: method.to_string(),
            seconds: started.elapsed().as_secs_f64(),
        });
        match result {
            Ok(Some(r)) => {
                // Only the chains that omit it pay for the extra request, and
                // only when the receipt has come back without it.
                if need.needs_effective_gas_price && r.effective_gas_price.is_none() {
                    fetch_tx = true;
                }
                receipt = Some(r);
            }
            Ok(None) => {
                return JobResult::Tx {
                    need,
                    outcome: Box::new(FetchOutcome::NullData),
                    stats,
                }
            }
            Err(e) => {
                return JobResult::Tx {
                    need,
                    outcome: Box::new(FetchOutcome::Failed(rpc_error_message(&e))),
                    stats,
                }
            }
        }
    }
    if fetch_tx {
        let (method, params) = request("eth_getTransactionByHash");
        let started = Instant::now();
        let result: Result<Option<RpcTransaction>, RpcError> = client.request(method, params).await;
        stats.push(RequestStat {
            method: method.to_string(),
            seconds: started.elapsed().as_secs_f64(),
        });
        match result {
            Ok(Some(t)) => tx = Some(t),
            Ok(None) => {
                return JobResult::Tx {
                    need,
                    outcome: Box::new(FetchOutcome::NullData),
                    stats,
                }
            }
            Err(e) => {
                return JobResult::Tx {
                    need,
                    outcome: Box::new(FetchOutcome::Failed(rpc_error_message(&e))),
                    stats,
                }
            }
        }
    }

    match merge_transaction(&need, tx, receipt) {
        Ok(merged) => JobResult::Tx {
            need,
            outcome: Box::new(FetchOutcome::Data(merged)),
            stats,
        },
        Err(error) => JobResult::Fatal { error, stats },
    }
}

pub(crate) struct StoreFetchOutcome {
    pub missing_blocks: Vec<BlockNeed>,
    pub missing_transactions: Vec<TxNeed>,
    pub sample_error: Option<String>,
    pub request_stats: Vec<RequestStat>,
}

impl StoreFetchOutcome {
    pub(crate) fn into_missing(self) -> MissingStoreData {
        needs_to_missing(
            self.missing_blocks,
            self.missing_transactions,
            self.sample_error,
        )
    }
}

/// Fetch every needed block and transaction concurrently (bounded pool),
/// inserting the rows that arrived into the page stores. Keys the provider
/// couldn't serve come back as still-missing — the caller decides the retry.
/// A response that can never satisfy the selection fails the whole fetch.
pub(crate) async fn fetch_store_data(
    client: &JsonRpcClient,
    block_needs: Vec<BlockNeed>,
    tx_needs: Vec<TxNeed>,
    transaction_store: &TransactionStore,
    block_store: &BlockStore,
) -> Result<StoreFetchOutcome, (FieldSelectionError, Vec<RequestStat>)> {
    use futures_util::StreamExt;

    enum Job {
        Block(BlockNeed),
        Tx(TxNeed),
    }
    let jobs: Vec<Job> = block_needs
        .into_iter()
        .map(Job::Block)
        .chain(tx_needs.into_iter().map(Job::Tx))
        .collect();

    let results: Vec<JobResult> = futures_util::stream::iter(jobs.into_iter().map(|job| async {
        match job {
            Job::Block(need) => fetch_block_job(client, need).await,
            Job::Tx(need) => fetch_tx_job(client, need).await,
        }
    }))
    .buffer_unordered(STORE_FETCH_CONCURRENCY)
    .collect()
    .await;

    let mut outcome = StoreFetchOutcome {
        missing_blocks: Vec::new(),
        missing_transactions: Vec::new(),
        sample_error: None,
        request_stats: Vec::new(),
    };
    let mut block_rows: Vec<simple_types::Block> = Vec::new();
    let mut tx_rows: Vec<simple_types::Transaction> = Vec::new();
    let mut fatal: Option<FieldSelectionError> = None;

    for result in results {
        match result {
            JobResult::Block {
                need,
                outcome: job_outcome,
                stats,
            } => {
                outcome.request_stats.extend(stats);
                match *job_outcome {
                    FetchOutcome::Data(block) => {
                        // Every fetched block also yields its parent's hash at
                        // no extra cost; when consecutive blocks are fetched,
                        // the page's own hash-collision check cross-validates
                        // the separately fetched responses.
                        if let (Some(number), Some(parent_hash)) =
                            (block.number, block.parent_hash.clone())
                        {
                            if number > 0 {
                                block_rows.push(simple_types::Block {
                                    number: Some(number - 1),
                                    hash: Some(parent_hash),
                                    ..Default::default()
                                });
                            }
                        }
                        block_rows.push(block);
                    }
                    FetchOutcome::NullData => outcome.missing_blocks.push(need),
                    FetchOutcome::Failed(message) => {
                        outcome.sample_error = Some(message);
                        outcome.missing_blocks.push(need);
                    }
                }
            }
            JobResult::Tx {
                need,
                outcome: job_outcome,
                stats,
            } => {
                outcome.request_stats.extend(stats);
                match *job_outcome {
                    FetchOutcome::Data(tx) => tx_rows.push(tx),
                    FetchOutcome::NullData => outcome.missing_transactions.push(need),
                    FetchOutcome::Failed(message) => {
                        outcome.sample_error = Some(message);
                        outcome.missing_transactions.push(need);
                    }
                }
            }
            JobResult::Fatal { error, stats } => {
                outcome.request_stats.extend(stats);
                if fatal.is_none() {
                    fatal = Some(error);
                }
            }
        }
    }

    if let Some(error) = fatal {
        return Err((error, outcome.request_stats));
    }

    block_store.insert_evm_blocks(block_rows);
    transaction_store.insert_evm_txs(tx_rows);

    Ok(outcome)
}
