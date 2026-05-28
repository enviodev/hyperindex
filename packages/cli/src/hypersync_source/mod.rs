use std::sync::Once;

use anyhow::{Context, Result};
use napi_derive::napi;

mod config;
mod decode;
mod query;
mod types;

use config::ClientConfig;
use decode::DecoderCore;
use query::Query;
use query::{BlockField, TransactionField};
use types::{Block, EventParamsInput, Log, ParamValue, RollbackGuard, Transaction};

static LOGGER_INIT: Once = Once::new();

fn init_logger(log_level: Option<&str>) {
    LOGGER_INIT.call_once(|| {
        if std::env::var("RUST_LOG").is_ok() {
            env_logger::init();
        } else if let Some(filter) = log_level {
            env_logger::Builder::new().parse_filters(filter).init();
        }
    });
}

/// HyperSync client for querying blockchain data.
#[napi]
pub struct HypersyncClient {
    inner: hypersync_client::Client,
    enable_checksum_addresses: bool,
    decoder: DecoderCore,
}

#[napi]
impl HypersyncClient {
    #[napi(factory)]
    pub fn new(
        cfg: ClientConfig,
        user_agent: String,
        event_params: Vec<EventParamsInput>,
    ) -> napi::Result<HypersyncClient> {
        init_logger(cfg.log_level.as_deref());

        let enable_checksum_addresses = cfg.enable_checksum_addresses.unwrap_or_default();

        let decoder = DecoderCore::from_params(event_params, enable_checksum_addresses)
            .context("build decoder")
            .map_err(map_err)?;

        let inner = hypersync_client::Client::new_with_agent(cfg.into(), user_agent)
            .context("build client")
            .map_err(map_err)?;

        Ok(HypersyncClient {
            inner,
            enable_checksum_addresses,
            decoder,
        })
    }

    #[napi]
    pub async fn get(&self, query: Query) -> napi::Result<QueryResponse> {
        let query = query.try_into().context("parse query").map_err(map_err)?;
        let res = self
            .inner
            .get(&query)
            .await
            .context("run inner query")
            .map_err(map_err)?;
        convert_response(res, self.enable_checksum_addresses)
            .context("convert response")
            .map_err(map_err)
    }

    #[napi]
    pub async fn get_event_items(&self, query: Query) -> napi::Result<EventItemsResponse> {
        // The requested fields drive the response-shape validation. Anything
        // the user asked for that the server didn't return (and that isn't
        // inherently nullable per-row) is a defect we want to surface clearly.
        let requested_block_fields = query.field_selection.block.clone().unwrap_or_default();
        let requested_transaction_fields = query
            .field_selection
            .transaction
            .clone()
            .unwrap_or_default();

        let query = query.try_into().context("parse query").map_err(map_err)?;
        let res = self
            .inner
            .get_events(query)
            .await
            .context("run inner query")
            .map_err(map_err)?;

        // Fuse conversion + decoding into the same task that ran get_events.
        // The upstream `get_events` already uses `block_in_place` for its
        // Arrow parse step, so we mirror that here — no separate
        // spawn_blocking, just a hint to the runtime that we're about to do
        // CPU work and any other tasks pinned to this worker should move.
        let items = tokio::task::block_in_place(|| {
            convert_event_items(
                res.data,
                &self.decoder,
                self.enable_checksum_addresses,
                &requested_block_fields,
                &requested_transaction_fields,
            )
        })
        .map_err(map_err)?;

        Ok(EventItemsResponse {
            archive_height: res
                .archive_height
                .map(|h| h.try_into())
                .transpose()
                .context("convert archive_height")
                .map_err(map_err)?,
            next_block: res
                .next_block
                .try_into()
                .context("convert next_block")
                .map_err(map_err)?,
            items,
            rollback_guard: res
                .rollback_guard
                .map(RollbackGuard::try_from)
                .transpose()
                .context("convert rollback guard")
                .map_err(map_err)?,
        })
    }
}

#[napi(object)]
pub struct QueryResponseData {
    pub blocks: Vec<Block>,
    pub transactions: Vec<Transaction>,
    pub logs: Vec<Log>,
}

#[napi(object)]
pub struct QueryResponse {
    pub archive_height: Option<i64>,
    pub next_block: i64,
    pub total_execution_time: i64,
    pub data: QueryResponseData,
    pub rollback_guard: Option<RollbackGuard>,
}

#[napi(object)]
pub struct EventItem {
    pub log_index: i64,
    pub src_address: String,
    /// Sighash (topic0), pre-encoded as a 0x-prefixed hex string.
    pub topic0: String,
    /// Number of non-null topics on the log (1..=4). Combined with `topic0`
    /// this is the routing key used by the event router on the JS side.
    pub topic_count: i64,
    pub block: Block,
    pub transaction: Transaction,
    /// Decoded event params; `None` when the log's topic0/topic-count doesn't
    /// match any signature passed to the client constructor (e.g. wildcard
    /// indexers that select more sighashes than they decode).
    pub params: Option<ParamValue>,
}

#[napi(object)]
pub struct EventItemsResponse {
    pub archive_height: Option<i64>,
    pub next_block: i64,
    pub items: Vec<EventItem>,
    pub rollback_guard: Option<RollbackGuard>,
}

fn convert_response(
    res: hypersync_client::QueryResponse,
    should_checksum: bool,
) -> Result<QueryResponse> {
    let blocks = res
        .data
        .blocks
        .into_iter()
        .flatten()
        .map(|b| Block::from_simple(&b, should_checksum))
        .collect::<Result<Vec<_>>>()
        .context("mapping blocks")?;

    let transactions = res
        .data
        .transactions
        .into_iter()
        .flatten()
        .map(|tx| Transaction::from_simple(&tx, should_checksum))
        .collect::<Result<Vec<_>>>()
        .context("mapping transactions")?;

    let logs = res
        .data
        .logs
        .into_iter()
        .flatten()
        .map(|l| Log::from_simple(&l, should_checksum))
        .collect::<Result<Vec<_>>>()
        .context("mapping logs")?;

    Ok(QueryResponse {
        archive_height: res
            .archive_height
            .map(|h| h.try_into())
            .transpose()
            .context("convert height")?,
        next_block: res.next_block.try_into().context("convert next_block")?,
        total_execution_time: res
            .total_execution_time
            .try_into()
            .context("convert total_execution_time")?,
        data: QueryResponseData {
            blocks,
            transactions,
            logs,
        },
        rollback_guard: res
            .rollback_guard
            .map(RollbackGuard::try_from)
            .transpose()
            .context("convert rollback guard")?,
    })
}

fn convert_event_items(
    events: Vec<hypersync_client::simple_types::Event>,
    decoder: &DecoderCore,
    should_checksum: bool,
    requested_block_fields: &[BlockField],
    requested_transaction_fields: &[TransactionField],
) -> Result<Vec<EventItem>> {
    let mut items = Vec::with_capacity(events.len());
    for event in events {
        let mut missing: Vec<String> = Vec::new();

        match &event.block {
            None if !requested_block_fields.is_empty() => missing.push("block".into()),
            Some(block) => {
                for &field in requested_block_fields {
                    if let Some(name) = block_field_missing(block, field) {
                        missing.push(format!("block.{}", name));
                    }
                }
            }
            None => {}
        }

        match &event.transaction {
            None if !requested_transaction_fields.is_empty() => missing.push("transaction".into()),
            Some(transaction) => {
                for &field in requested_transaction_fields {
                    if let Some(name) = transaction_field_missing(transaction, field) {
                        missing.push(format!("transaction.{}", name));
                    }
                }
            }
            None => {}
        }

        if !missing.is_empty() {
            return Err(MissingFieldsError(missing).into());
        }

        let params = decoder.decode_simple(&event.log).ok().flatten();

        let block = event
            .block
            .as_ref()
            .map(|b| Block::from_simple(b, should_checksum))
            .transpose()
            .context("mapping block")?
            .unwrap_or_default();

        let transaction = event
            .transaction
            .as_ref()
            .map(|t| Transaction::from_simple(t, should_checksum))
            .transpose()
            .context("mapping transaction")?
            .unwrap_or_default();

        let (log_index, src_address, topic0, topic_count) =
            flatten_log_for_js(&event.log, should_checksum).context("mapping log")?;

        items.push(EventItem {
            log_index,
            src_address,
            topic0,
            topic_count,
            block,
            transaction,
            params,
        });
    }
    Ok(items)
}

fn flatten_log_for_js(
    log: &hypersync_client::simple_types::Log,
    should_checksum: bool,
) -> Result<(i64, String, String, i64)> {
    use hypersync_client::format::Hex;

    let log_index: i64 = u64::from(log.log_index.context("log.logIndex missing")?)
        .try_into()
        .context("log.logIndex overflow")?;
    let address_raw = log.address.as_ref().context("log.address missing")?;
    let src_address = if should_checksum {
        alloy_primitives::Address(alloy_primitives::FixedBytes(***address_raw)).to_checksum(None)
    } else {
        address_raw.encode_hex()
    };
    let topic0 = log
        .topics
        .first()
        .context("log.topics empty")?
        .as_ref()
        .context("log.topics[0] missing")?
        .encode_hex();
    let topic_count: i64 = log
        .topics
        .iter()
        .filter(|t| t.is_some())
        .count()
        .try_into()
        .context("topic_count overflow")?;
    Ok((log_index, src_address, topic0, topic_count))
}

/// Marker error so the ReScript side can recognize "data shape" failures.
/// The `Debug` output is parsed at the JS boundary, so keep the prefix stable.
#[derive(Debug)]
pub struct MissingFieldsError(pub Vec<String>);

impl std::fmt::Display for MissingFieldsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "MissingFields: {}", self.0.join(","))
    }
}

impl std::error::Error for MissingFieldsError {}

/// Returns `Some(camelCaseFieldName)` if the user requested this field but the
/// server's response omits it AND the field isn't inherently nullable per-row.
/// `None` means "fine" — either the field is present, or it belongs to the
/// nullable set (legit chain/block-dependent absence).
fn block_field_missing(
    block: &hypersync_client::simple_types::Block,
    field: BlockField,
) -> Option<&'static str> {
    use BlockField::*;
    match field {
        // Inherently nullable: pre-EIP-1559 blocks, L2-only fields, etc.
        Nonce
        | Difficulty
        | TotalDifficulty
        | Uncles
        | BaseFeePerGas
        | BlobGasUsed
        | ExcessBlobGas
        | ParentBeaconBlockRoot
        | WithdrawalsRoot
        | L1BlockNumber
        | SendCount
        | SendRoot
        | MixHash => None,
        // Always-present-when-requested:
        Number => block.number.is_none().then_some("number"),
        Hash => block.hash.is_none().then_some("hash"),
        ParentHash => block.parent_hash.is_none().then_some("parentHash"),
        Sha3Uncles => block.sha3_uncles.is_none().then_some("sha3Uncles"),
        LogsBloom => block.logs_bloom.is_none().then_some("logsBloom"),
        TransactionsRoot => block
            .transactions_root
            .is_none()
            .then_some("transactionsRoot"),
        StateRoot => block.state_root.is_none().then_some("stateRoot"),
        ReceiptsRoot => block.receipts_root.is_none().then_some("receiptsRoot"),
        Miner => block.miner.is_none().then_some("miner"),
        ExtraData => block.extra_data.is_none().then_some("extraData"),
        Size => block.size.is_none().then_some("size"),
        GasLimit => block.gas_limit.is_none().then_some("gasLimit"),
        GasUsed => block.gas_used.is_none().then_some("gasUsed"),
        Timestamp => block.timestamp.is_none().then_some("timestamp"),
        Withdrawals => block.withdrawals.is_none().then_some("withdrawals"),
    }
}

fn transaction_field_missing(
    tx: &hypersync_client::simple_types::Transaction,
    field: TransactionField,
) -> Option<&'static str> {
    use TransactionField::*;
    match field {
        // Inherently nullable: type-dependent signature fields, optimism-only,
        // contract-creation `to`, etc.
        GasPrice | V | R | S | YParity | MaxPriorityFeePerGas | MaxFeePerGas | MaxFeePerBlobGas
        | BlobVersionedHashes | ContractAddress | Root | Status | L1Fee | L1GasPrice
        | L1GasUsed | L1FeeScalar | GasUsedForL1 | From | To | Type => None,
        // Always-present-when-requested:
        BlockHash => tx.block_hash.is_none().then_some("blockHash"),
        BlockNumber => tx.block_number.is_none().then_some("blockNumber"),
        Gas => tx.gas.is_none().then_some("gas"),
        Hash => tx.hash.is_none().then_some("hash"),
        Input => tx.input.is_none().then_some("input"),
        Nonce => tx.nonce.is_none().then_some("nonce"),
        TransactionIndex => tx.transaction_index.is_none().then_some("transactionIndex"),
        Value => tx.value.is_none().then_some("value"),
        ChainId => tx.chain_id.is_none().then_some("chainId"),
        AccessList => tx.access_list.is_none().then_some("accessList"),
        AuthorizationList => tx
            .authorization_list
            .is_none()
            .then_some("authorizationList"),
        CumulativeGasUsed => tx
            .cumulative_gas_used
            .is_none()
            .then_some("cumulativeGasUsed"),
        EffectiveGasPrice => tx
            .effective_gas_price
            .is_none()
            .then_some("effectiveGasPrice"),
        GasUsed => tx.gas_used.is_none().then_some("gasUsed"),
        LogsBloom => tx.logs_bloom.is_none().then_some("logsBloom"),
        // Fields exposed via the typed enum but not represented on the
        // simple_types::Transaction struct in this crate version — treat as
        // never-missing (no-op).
        L1BlockNumber
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

pub(crate) fn map_err(e: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{:?}", e))
}
