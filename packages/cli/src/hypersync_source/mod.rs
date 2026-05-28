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
    pub async fn get_event_items(
        &self,
        query: Query,
        non_optional_block_fields: Vec<String>,
        non_optional_transaction_fields: Vec<String>,
    ) -> napi::Result<EventItemsResponse> {
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
                &non_optional_block_fields,
                &non_optional_transaction_fields,
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

/// Slim log shape consumed by `HyperSyncSource.res` — only the four fields it
/// actually reads (`address`, `data`, `topics`, `logIndex`). Address is
/// pre-unwrapped (and checksummed when the client config asks for it), topics
/// are pre-filtered to non-null hex strings, and `data` is pre-encoded.
#[napi(object)]
pub struct EventLog {
    pub log_index: i64,
    pub address: String,
    pub data: String,
    pub topics: Vec<String>,
}

#[napi(object)]
pub struct EventItem {
    pub log: EventLog,
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
    non_optional_block_fields: &[String],
    non_optional_transaction_fields: &[String],
) -> Result<Vec<EventItem>> {
    let mut items = Vec::with_capacity(events.len());
    for event in events {
        let mut missing: Vec<String> = Vec::new();

        match &event.block {
            None if !non_optional_block_fields.is_empty() => missing.push("block".into()),
            Some(block) => {
                for name in non_optional_block_fields {
                    if !block_field_present(block, name) {
                        missing.push(format!("block.{}", name));
                    }
                }
            }
            None => {}
        }

        match &event.transaction {
            None if !non_optional_transaction_fields.is_empty() => {
                missing.push("transaction".into())
            }
            Some(transaction) => {
                for name in non_optional_transaction_fields {
                    if !transaction_field_present(transaction, name) {
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

        let log = convert_event_log(&event.log, should_checksum).context("mapping log")?;

        items.push(EventItem {
            log,
            block,
            transaction,
            params,
        });
    }
    Ok(items)
}

fn convert_event_log(
    log: &hypersync_client::simple_types::Log,
    should_checksum: bool,
) -> Result<EventLog> {
    use hypersync_client::format::Hex;

    let log_index: i64 = u64::from(log.log_index.context("log.logIndex missing")?)
        .try_into()
        .context("log.logIndex overflow")?;
    let address_raw = log.address.as_ref().context("log.address missing")?;
    let address = if should_checksum {
        alloy_primitives::Address(alloy_primitives::FixedBytes(***address_raw)).to_checksum(None)
    } else {
        address_raw.encode_hex()
    };
    let data = log.data.as_ref().context("log.data missing")?.encode_hex();
    let topics = log
        .topics
        .iter()
        .filter_map(|t| t.as_ref().map(|v| v.encode_hex()))
        .collect();

    Ok(EventLog {
        log_index,
        address,
        data,
        topics,
    })
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

fn block_field_present(block: &hypersync_client::simple_types::Block, name: &str) -> bool {
    match name {
        "number" => block.number.is_some(),
        "hash" => block.hash.is_some(),
        "parentHash" => block.parent_hash.is_some(),
        "nonce" => block.nonce.is_some(),
        "sha3Uncles" => block.sha3_uncles.is_some(),
        "logsBloom" => block.logs_bloom.is_some(),
        "transactionsRoot" => block.transactions_root.is_some(),
        "stateRoot" => block.state_root.is_some(),
        "receiptsRoot" => block.receipts_root.is_some(),
        "miner" => block.miner.is_some(),
        "difficulty" => block.difficulty.is_some(),
        "totalDifficulty" => block.total_difficulty.is_some(),
        "extraData" => block.extra_data.is_some(),
        "size" => block.size.is_some(),
        "gasLimit" => block.gas_limit.is_some(),
        "gasUsed" => block.gas_used.is_some(),
        "timestamp" => block.timestamp.is_some(),
        "uncles" => block.uncles.is_some(),
        "baseFeePerGas" => block.base_fee_per_gas.is_some(),
        "blobGasUsed" => block.blob_gas_used.is_some(),
        "excessBlobGas" => block.excess_blob_gas.is_some(),
        "parentBeaconBlockRoot" => block.parent_beacon_block_root.is_some(),
        "withdrawalsRoot" => block.withdrawals_root.is_some(),
        "withdrawals" => block.withdrawals.is_some(),
        "l1BlockNumber" => block.l1_block_number.is_some(),
        "sendCount" => block.send_count.is_some(),
        "sendRoot" => block.send_root.is_some(),
        "mixHash" => block.mix_hash.is_some(),
        _ => true,
    }
}

fn transaction_field_present(tx: &hypersync_client::simple_types::Transaction, name: &str) -> bool {
    match name {
        "blockHash" => tx.block_hash.is_some(),
        "blockNumber" => tx.block_number.is_some(),
        "from" => tx.from.is_some(),
        "gas" => tx.gas.is_some(),
        "gasPrice" => tx.gas_price.is_some(),
        "hash" => tx.hash.is_some(),
        "input" => tx.input.is_some(),
        "nonce" => tx.nonce.is_some(),
        "to" => tx.to.is_some(),
        "transactionIndex" => tx.transaction_index.is_some(),
        "value" => tx.value.is_some(),
        "v" => tx.v.is_some(),
        "r" => tx.r.is_some(),
        "s" => tx.s.is_some(),
        "yParity" => tx.y_parity.is_some(),
        "maxPriorityFeePerGas" => tx.max_priority_fee_per_gas.is_some(),
        "maxFeePerGas" => tx.max_fee_per_gas.is_some(),
        "chainId" => tx.chain_id.is_some(),
        "accessList" => tx.access_list.is_some(),
        "authorizationList" => tx.authorization_list.is_some(),
        "maxFeePerBlobGas" => tx.max_fee_per_blob_gas.is_some(),
        "blobVersionedHashes" => tx.blob_versioned_hashes.is_some(),
        "cumulativeGasUsed" => tx.cumulative_gas_used.is_some(),
        "effectiveGasPrice" => tx.effective_gas_price.is_some(),
        "gasUsed" => tx.gas_used.is_some(),
        "contractAddress" => tx.contract_address.is_some(),
        "logsBloom" => tx.logs_bloom.is_some(),
        "type" => tx.type_.is_some(),
        "root" => tx.root.is_some(),
        "status" => tx.status.is_some(),
        "l1Fee" => tx.l1_fee.is_some(),
        "l1GasPrice" => tx.l1_gas_price.is_some(),
        "l1GasUsed" => tx.l1_gas_used.is_some(),
        "l1FeeScalar" => tx.l1_fee_scalar.is_some(),
        "gasUsedForL1" => tx.gas_used_for_l1.is_some(),
        _ => true,
    }
}

pub(crate) fn map_err(e: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{:?}", e))
}
