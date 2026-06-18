use std::sync::Once;

use anyhow::{Context, Result};
use hypersync_client::RateLimitResponse;
use napi_derive::napi;

use crate::transaction_store::TransactionStore;

mod config;
mod decode;
mod query;
pub(crate) mod types;

use config::ClientConfig;
use decode::DecoderCore;
use query::{BlockField, LogField, Query, TransactionField};
use types::{encode_address, Block, EventParamsInput, Log, ParamValue, RollbackGuard, Transaction};

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

fn make_rate_limit_err(info: &hypersync_client::RateLimitInfo) -> napi::Error {
    let reset_ms = info.suggested_wait_secs().unwrap_or(1) * 1000;
    napi::Error::from_reason(format!("RATE_LIMITED:{reset_ms}"))
}

#[napi]
pub struct EvmHypersyncClient {
    inner: hypersync_client::Client,
    enable_checksum_addresses: bool,
    decoder: DecoderCore,
}

#[napi]
impl EvmHypersyncClient {
    #[napi(factory)]
    pub fn new(
        cfg: ClientConfig,
        user_agent: String,
        event_params: Vec<EventParamsInput>,
    ) -> napi::Result<EvmHypersyncClient> {
        init_logger(cfg.log_level.as_deref());

        let enable_checksum_addresses = cfg.enable_checksum_addresses.unwrap_or_default();

        let decoder = DecoderCore::from_params(event_params, enable_checksum_addresses)
            .context("build decoder")
            .map_err(map_err)?;

        let inner = hypersync_client::Client::new_with_agent(cfg.into(), user_agent)
            .context("build client")
            .map_err(map_err)?;

        Ok(EvmHypersyncClient {
            inner,
            enable_checksum_addresses,
            decoder,
        })
    }

    #[napi]
    pub async fn get_height(&self) -> napi::Result<i64> {
        let height = self.inner.get_height().await.map_err(|e| {
            // The client embeds a `{:?}` debug dump (a full backtrace when
            // RUST_BACKTRACE is set) in its error message; keep only the first
            // line so it stays readable when the indexer surfaces it on retries.
            let message = format!("{e}");
            let summary = message.lines().next().unwrap_or(message.as_str());
            napi::Error::from_reason(format!("Failed to get HyperSync height: {summary}"))
        })?;
        height.try_into().context("convert height").map_err(map_err)
    }

    #[napi]
    pub async fn get(&self, query: Query) -> napi::Result<QueryResponse> {
        let query = query.try_into().context("parse query").map_err(map_err)?;
        let res = self
            .inner
            .get_with_rate_limit(&query)
            .await
            .context("run inner query")
            .map_err(map_err)?;
        match res {
            RateLimitResponse::Success { response, .. } => {
                convert_response(response, self.enable_checksum_addresses)
                    .context("convert response")
                    .map_err(map_err)
            }
            RateLimitResponse::RateLimited(info) => Err(make_rate_limit_err(&info)),
        }
    }

    #[napi]
    pub async fn get_event_items(
        &self,
        mut query: Query,
    ) -> napi::Result<(EventItemsResponse, TransactionStore)> {
        // get_event_items always reads address/data/topic0..3/logIndex off the
        // log to decode params and flatten the JS-side shape. Force-add them
        // to the field selection so callers don't have to know the contract.
        ensure_required_log_fields(&mut query.field_selection.log);

        let requested_block_fields = query.field_selection.block.clone().unwrap_or_default();
        let requested_transaction_fields = query
            .field_selection
            .transaction
            .clone()
            .unwrap_or_default();

        let query = query.try_into().context("parse query").map_err(map_err)?;
        let res = self
            .inner
            .get_events_with_rate_limit(query)
            .await
            .context("run inner query")
            .map_err(map_err)?;

        let response = match res {
            RateLimitResponse::Success { response, .. } => response,
            RateLimitResponse::RateLimited(info) => return Err(make_rate_limit_err(&info)),
        };

        let transaction_store = TransactionStore::new();
        let items = tokio::task::block_in_place(|| {
            convert_event_items(
                response.data,
                &self.decoder,
                self.enable_checksum_addresses,
                &requested_block_fields,
                &requested_transaction_fields,
                &transaction_store,
            )
        })
        .map_err(convert_error_to_napi)?;

        let event_items = EventItemsResponse {
            archive_height: response
                .archive_height
                .map(|h| h.try_into())
                .transpose()
                .context("convert archive_height")
                .map_err(map_err)?,
            next_block: response
                .next_block
                .try_into()
                .context("convert next_block")
                .map_err(map_err)?,
            items,
            rollback_guard: response
                .rollback_guard
                .map(RollbackGuard::try_from)
                .transpose()
                .context("convert rollback guard")
                .map_err(map_err)?,
        };
        Ok((event_items, transaction_store))
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
    pub topic0: String,
    pub topic_count: i64,
    pub block: Block,
    /// Key into the per-chain `TransactionStore` (paired with the block number);
    /// the transaction itself is materialised field-by-field on demand.
    pub transaction_index: i64,
    /// `None` when the log's topic0/topic-count doesn't match any signature
    /// passed to the client constructor (e.g. wildcard indexers that select
    /// more sighashes than they decode).
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

/// Validation + decoding for one page of events. Aborts on the first item that
/// has a structural defect (server omitted a required field; raw bytes can't
/// be decoded against the declared ABI).
fn convert_event_items(
    events: Vec<hypersync_client::simple_types::Event>,
    decoder: &DecoderCore,
    should_checksum: bool,
    requested_block_fields: &[BlockField],
    requested_transaction_fields: &[TransactionField],
    store: &TransactionStore,
) -> std::result::Result<Vec<EventItem>, ConvertError> {
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
            return Err(ConvertError::MissingFields(missing));
        }

        // Propagate genuine decode errors (malformed bytes, ABI mismatch) up
        // to the JS caller instead of silently coercing them into `None` —
        // `None` is reserved for "topic0/count doesn't match a registered
        // signature", which is the only outcome the wildcard event path
        // expects to handle.
        let params = decoder
            .decode_simple(&event.log)
            .context("decode event params")?;

        let block = event
            .block
            .as_ref()
            .map(|b| Block::from_simple(b, should_checksum))
            .transpose()
            .context("mapping block")?
            .unwrap_or_default();

        let (log_index, src_address, topic0, topic_count, block_number, transaction_index) =
            flatten_log_for_js(&event.log, should_checksum).context("mapping log")?;

        // Move the raw transaction into the store keyed by (block, txIndex). Its
        // fields materialise on demand; logs sharing a tx collapse to one entry.
        if let Some(tx) = event.transaction {
            store.insert_evm_raw(
                block_number as u64,
                transaction_index.to_string(),
                tx,
                should_checksum,
            );
        }

        items.push(EventItem {
            log_index,
            src_address,
            topic0,
            topic_count,
            block,
            transaction_index,
            params,
        });
    }
    Ok(items)
}

fn flatten_log_for_js(
    log: &hypersync_client::simple_types::Log,
    should_checksum: bool,
) -> Result<(i64, String, String, i64, i64, i64)> {
    use hypersync_client::format::Hex;

    let log_index: i64 = u64::from(log.log_index.context("log.logIndex missing")?)
        .try_into()
        .context("log.logIndex overflow")?;
    let src_address = encode_address(
        log.address.as_ref().context("log.address missing")?,
        should_checksum,
    );
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
    // block_number + transaction_index are force-selected (see
    // `ensure_required_log_fields`) so they're always present, independent of
    // the user's field selection — they key the transaction store.
    let block_number: i64 = u64::from(log.block_number.context("log.blockNumber missing")?)
        .try_into()
        .context("log.blockNumber overflow")?;
    let transaction_index: i64 = u64::from(
        log.transaction_index
            .context("log.transactionIndex missing")?,
    )
    .try_into()
    .context("log.transactionIndex overflow")?;
    Ok((
        log_index,
        src_address,
        topic0,
        topic_count,
        block_number,
        transaction_index,
    ))
}

/// Failure modes specific to event-items conversion. `MissingFields` is the
/// shape the JS side recognizes and treats as `ImpossibleForTheQuery`;
/// `Other` falls through to the generic napi error path.
#[derive(Debug)]
pub(crate) enum ConvertError {
    MissingFields(Vec<String>),
    Other(anyhow::Error),
}

impl From<anyhow::Error> for ConvertError {
    fn from(e: anyhow::Error) -> Self {
        Self::Other(e)
    }
}

/// Encodes `ConvertError::MissingFields` as a JSON payload in the napi
/// error's message. The ReScript side calls `JSON.parse` on the message and
/// dispatches on `kind`, so any future variants can be added by extending
/// the JSON shape — no string-grepping protocol to maintain.
fn convert_error_to_napi(err: ConvertError) -> napi::Error {
    match err {
        ConvertError::MissingFields(fields) => {
            let payload = serde_json::json!({
                "kind": "MissingFields",
                "fields": fields,
            })
            .to_string();
            napi::Error::new(napi::Status::InvalidArg, payload)
        }
        ConvertError::Other(e) => map_err(e),
    }
}

/// Returns `Some(camelCaseFieldName)` if the user requested this field but the
/// server's response omits it AND the field isn't inherently nullable per-row.
fn block_field_missing(
    block: &hypersync_client::simple_types::Block,
    field: BlockField,
) -> Option<&'static str> {
    use BlockField::*;
    match field {
        // `Withdrawals` and `WithdrawalsRoot` are Shanghai-only and legitimately
        // absent on pre-Shanghai blocks; the original `evmNullableBlockFields`
        // missed `Withdrawals` — fixed here.
        Nonce
        | Difficulty
        | TotalDifficulty
        | Uncles
        | BaseFeePerGas
        | BlobGasUsed
        | ExcessBlobGas
        | ParentBeaconBlockRoot
        | WithdrawalsRoot
        | Withdrawals
        | L1BlockNumber
        | SendCount
        | SendRoot
        | MixHash => None,
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
    }
}

fn transaction_field_missing(
    tx: &hypersync_client::simple_types::Transaction,
    field: TransactionField,
) -> Option<&'static str> {
    use TransactionField::*;
    match field {
        GasPrice | V | R | S | YParity | MaxPriorityFeePerGas | MaxFeePerGas | MaxFeePerBlobGas
        | BlobVersionedHashes | ContractAddress | Root | Status | L1Fee | L1GasPrice
        | L1GasUsed | L1FeeScalar | GasUsedForL1 | From | To | Type => None,
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
        // Enum variants not represented on simple_types::Transaction in this
        // crate version — treat as never-missing.
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

fn ensure_required_log_fields(selection: &mut Option<Vec<LogField>>) {
    use std::collections::BTreeSet;
    const REQUIRED: &[LogField] = &[
        LogField::Address,
        LogField::Data,
        LogField::LogIndex,
        LogField::Topic0,
        LogField::Topic1,
        LogField::Topic2,
        LogField::Topic3,
        // Key the transaction store regardless of the user's field selection.
        LogField::BlockNumber,
        LogField::TransactionIndex,
    ];
    let mut set: BTreeSet<LogField> = selection.take().unwrap_or_default().into_iter().collect();
    set.extend(REQUIRED.iter().copied());
    *selection = Some(set.into_iter().collect());
}

pub(crate) fn map_err(e: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{:?}", e))
}

#[cfg(test)]
mod tests {
    use super::*;
    use hypersync_client::simple_types;

    fn empty_decoder() -> DecoderCore {
        DecoderCore::from_params(Vec::new(), false).unwrap()
    }

    #[test]
    fn missing_block_field_returns_typed_error() {
        // event.block is None but the user asked for block.number/hash/timestamp.
        let event = simple_types::Event {
            transaction: None,
            block: None,
            log: simple_types::Log::default(),
        };
        let err = convert_event_items(
            vec![event],
            &empty_decoder(),
            false,
            &[BlockField::Number, BlockField::Hash, BlockField::Timestamp],
            &[],
            &TransactionStore::new(),
        )
        .err()
        .expect("expected MissingFields error");

        match err {
            ConvertError::MissingFields(fields) => assert_eq!(fields, vec!["block".to_string()]),
            ConvertError::Other(e) => panic!("unexpected ConvertError::Other: {e:?}"),
        }
    }

    #[test]
    fn missing_block_field_named_path() {
        // block is present but timestamp is not.
        let mut block = simple_types::Block::default();
        block.number = Some(1u64.into());
        block.hash = Some(Default::default());
        // timestamp left None
        let event = simple_types::Event {
            transaction: None,
            block: Some(block.into()),
            log: simple_types::Log::default(),
        };
        let err = convert_event_items(
            vec![event],
            &empty_decoder(),
            false,
            &[BlockField::Number, BlockField::Hash, BlockField::Timestamp],
            &[],
            &TransactionStore::new(),
        )
        .err()
        .expect("expected MissingFields error");

        match err {
            ConvertError::MissingFields(fields) => {
                assert_eq!(fields, vec!["block.timestamp".to_string()])
            }
            ConvertError::Other(e) => panic!("unexpected ConvertError::Other: {e:?}"),
        }
    }

    #[test]
    fn nullable_block_field_not_reported() {
        // BaseFeePerGas is inherently nullable — server omitting it must not
        // trigger MissingFields, regardless of whether the user requested it.
        let mut block = simple_types::Block::default();
        block.number = Some(1u64.into());
        block.hash = Some(Default::default());
        block.timestamp = Some(Default::default());
        // base_fee_per_gas left None
        let event = simple_types::Event {
            transaction: None,
            block: Some(block.into()),
            log: simple_types::Log {
                log_index: Some(0.into()),
                block_number: Some(0u64.into()),
                transaction_index: Some(0u64.into()),
                address: Some(Default::default()),
                data: Some(Default::default()),
                topics: std::iter::once(Some(Default::default())).collect(),
                ..Default::default()
            },
        };
        let res = convert_event_items(
            vec![event],
            &empty_decoder(),
            false,
            &[
                BlockField::Number,
                BlockField::Hash,
                BlockField::Timestamp,
                BlockField::BaseFeePerGas,
            ],
            &[],
            &TransactionStore::new(),
        )
        .expect("expected success when only nullable fields are absent");
        assert_eq!(res.len(), 1);
    }

    #[test]
    fn missing_transaction_field_with_transaction_present() {
        let mut block = simple_types::Block::default();
        block.number = Some(1u64.into());
        block.hash = Some(Default::default());
        block.timestamp = Some(Default::default());
        let tx = simple_types::Transaction::default(); // hash absent
        let event = simple_types::Event {
            transaction: Some(tx.into()),
            block: Some(block.into()),
            log: simple_types::Log {
                log_index: Some(0.into()),
                block_number: Some(0u64.into()),
                transaction_index: Some(0u64.into()),
                address: Some(Default::default()),
                data: Some(Default::default()),
                topics: std::iter::once(Some(Default::default())).collect(),
                ..Default::default()
            },
        };
        let err = convert_event_items(
            vec![event],
            &empty_decoder(),
            false,
            &[BlockField::Number, BlockField::Hash, BlockField::Timestamp],
            &[TransactionField::Hash],
            &TransactionStore::new(),
        )
        .err()
        .expect("expected MissingFields error");

        match err {
            ConvertError::MissingFields(fields) => {
                assert_eq!(fields, vec!["transaction.hash".to_string()])
            }
            ConvertError::Other(e) => panic!("unexpected ConvertError::Other: {e:?}"),
        }
    }

    #[test]
    fn convert_error_serializes_as_expected_json() {
        let err = ConvertError::MissingFields(vec![
            "block.timestamp".to_string(),
            "transaction.hash".to_string(),
        ]);
        let napi_err = convert_error_to_napi(err);
        // The reason field carries the JSON payload that the ReScript side
        // parses with JSON.parse.
        let parsed: serde_json::Value =
            serde_json::from_str(&format!("{}", napi_err.reason)).expect("payload must be JSON");
        assert_eq!(parsed["kind"], "MissingFields");
        assert_eq!(parsed["fields"][0], "block.timestamp");
        assert_eq!(parsed["fields"][1], "transaction.hash");
    }
}
