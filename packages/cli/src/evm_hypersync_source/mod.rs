use std::collections::HashSet;
use std::sync::Once;

use anyhow::{Context, Result};
use hypersync_client::{simple_types, RateLimitResponse};
use napi_derive::napi;

use crate::block_store::BlockStore;
use crate::transaction_store::TransactionStore;

mod config;
pub(crate) mod decode;
mod query;
pub(crate) mod selection;
pub(crate) mod types;

use std::collections::HashMap;

use config::ClientConfig;
use decode::{Decoder, SelectionDecoder};
use query::{BlockField, LogField, LogFilter, LogSelection, Query, TransactionField};
use selection::{BuiltLogSelection, SelectionBuilder};
use types::{
    encode_address, map_hex_string, map_i64, Block, OnEventRegistrationInput, ParamValue,
    RollbackGuard,
};

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
pub struct EvmHyperSyncClient {
    inner: hypersync_client::Client,
    enable_checksum_addresses: bool,
    decoder: Decoder,
    selection_builder: SelectionBuilder,
}

#[napi]
impl EvmHyperSyncClient {
    #[napi(factory)]
    pub fn new(
        cfg: ClientConfig,
        user_agent: String,
        event_registrations: Vec<OnEventRegistrationInput>,
    ) -> napi::Result<EvmHyperSyncClient> {
        init_logger(cfg.log_level.as_deref());

        let enable_checksum_addresses = cfg.enable_checksum_addresses.unwrap_or_default();

        let decoder = Decoder::from_registrations(&event_registrations, enable_checksum_addresses)
            .context("build decoder")
            .map_err(map_err)?;

        let selection_builder = SelectionBuilder::from_registrations(&event_registrations)
            .context("build selection builder")
            .map_err(map_err)?;

        let inner = hypersync_client::Client::new_with_agent(cfg.into(), user_agent)
            .context("build client")
            .map_err(map_err)?;

        Ok(EvmHyperSyncClient {
            inner,
            enable_checksum_addresses,
            decoder,
            selection_builder,
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
        params: EventItemsQuery,
    ) -> napi::Result<(EventItemsResponse, TransactionStore, BlockStore)> {
        let client_filtered = crate::client_filtered_contracts::ClientFilteredContracts::from_vec(
            params.client_side_filtered_contracts.unwrap_or_default(),
        );
        let built = self
            .selection_builder
            .build(
                &params.registration_indexes,
                &params.addresses_by_contract_name,
                &client_filtered,
            )
            .map_err(map_err)?;
        let selection_decoder = self
            .decoder
            .selection(
                &params.registration_indexes,
                &params.addresses_by_contract_name,
                &client_filtered,
            )
            .map_err(map_err)?;

        let requested_transaction_fields = built.transaction_fields;
        let mut block_fields = built.block_fields;
        // Force-add the always-required block fields, then validate the full
        // set. Validating the forced fields (not just the selection's) is what
        // guarantees the consumer's unconditional number/timestamp/hash reads
        // — the presence check, not the request, is the guarantee.
        for &field in REQUIRED_BLOCK_FIELDS {
            if !block_fields.contains(&field) {
                block_fields.push(field);
            }
        }
        let validated_block_fields = block_fields;

        let mut transaction_fields = requested_transaction_fields.clone();
        // Transactions are accumulated into the store keyed by
        // (blockNumber, transactionIndex), so those keys must come back on each
        // transaction row whenever any transaction field is requested.
        if !transaction_fields.is_empty() {
            for field in [
                TransactionField::BlockNumber,
                TransactionField::TransactionIndex,
            ] {
                if !transaction_fields.contains(&field) {
                    transaction_fields.push(field);
                }
            }
        }

        let query = Query {
            from_block: params.from_block,
            to_block: params.to_block.map(|b| b + 1),
            logs: Some(
                built
                    .log_selections
                    .into_iter()
                    .map(log_selection_from_built)
                    .collect(),
            ),
            max_num_logs: Some(params.max_num_logs),
            field_selection: query::FieldSelection {
                block: Some(validated_block_fields.clone()),
                transaction: Some(transaction_fields),
                // Everything get_event_items reads off the log: decode inputs,
                // the flattened item fields, and the transaction-store keys.
                log: Some(vec![
                    LogField::Address,
                    LogField::Data,
                    LogField::LogIndex,
                    LogField::Topic0,
                    LogField::Topic1,
                    LogField::Topic2,
                    LogField::Topic3,
                    LogField::BlockNumber,
                    LogField::TransactionIndex,
                ]),
            },
            ..Default::default()
        };
        let contract_name_by_address = built.contract_name_by_address;

        let query = query.try_into().context("parse query").map_err(map_err)?;
        let res = self
            .inner
            .get_with_rate_limit(&query)
            .await
            .context("run inner query")
            .map_err(map_err)?;

        let response = match res {
            RateLimitResponse::Success { response, .. } => response,
            RateLimitResponse::RateLimited(info) => return Err(make_rate_limit_err(&info)),
        };

        let transaction_store = TransactionStore::new_evm(self.enable_checksum_addresses);
        let block_store = BlockStore::new_evm(self.enable_checksum_addresses);
        let (items, blocks) = tokio::task::block_in_place(|| {
            process_response(
                response.data.blocks,
                response.data.transactions,
                response.data.logs,
                &selection_decoder,
                self.enable_checksum_addresses,
                &validated_block_fields,
                &requested_transaction_fields,
                &transaction_store,
                &block_store,
                &contract_name_by_address,
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
            blocks,
            items,
            rollback_guard: response
                .rollback_guard
                .map(RollbackGuard::try_from)
                .transpose()
                .context("convert rollback guard")
                .map_err(map_err)?,
        };
        Ok((event_items, transaction_store, block_store))
    }
}

/// The whole per-query input for `get_event_items`: the block range, the
/// partition's registration selection (by id), and its current addresses.
/// Log selections, field selection, and the routing index are all derived
/// internally from the registrations passed at construction.
#[napi(object)]
pub struct EventItemsQuery {
    pub from_block: i64,
    /// Inclusive; `None` queries to the end of available data.
    pub to_block: Option<i64>,
    pub max_num_logs: i64,
    pub registration_indexes: Vec<i64>,
    pub addresses_by_contract_name: HashMap<String, Vec<String>>,
    /// Contract names to fetch address-free even though their registrations
    /// depend on addresses (client-side / wildcard filtering). Absent or empty
    /// means every address-dependent contract is filtered server-side.
    pub client_side_filtered_contracts: Option<Vec<String>>,
}

fn log_selection_from_built(
    built: BuiltLogSelection,
) -> napi::bindgen_prelude::Either<LogSelection, LogFilter> {
    napi::bindgen_prelude::Either::B(LogFilter {
        address: Some(built.addresses),
        topics: Some(built.topics),
    })
}

// The only caller of `get` is the block-hash query, which selects block fields
// only — so the response carries just blocks. Event items (with their
// transactions in the store) flow through `get_event_items` instead.
#[napi(object)]
pub struct QueryResponseData {
    pub blocks: Vec<Block>,
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
    /// Block this log belongs to. The block itself is carried once, deduplicated,
    /// in `EventItemsResponse.blocks` — the caller joins on this number.
    pub block_number: i64,
    /// Key into the per-chain `TransactionStore` (paired with the block number);
    /// the transaction itself is materialised field-by-field on demand.
    pub transaction_index: i64,
    /// The registration this log routed to, as passed to the client
    /// constructor. Logs that route nowhere never cross the boundary.
    pub on_event_registration_index: i64,
    pub params: ParamValue,
}

/// The always-needed block fields, surfaced per block number so the consumer can
/// set each item's `timestamp`/`blockHash`, feed reorg detection, and stamp
/// `event.block`'s number/timestamp/hash — without the full block crossing the
/// napi boundary. The block's remaining fields stay raw in the per-chain
/// `BlockStore` and are materialised field-by-field on demand.
#[napi(object)]
pub struct BlockHeader {
    pub number: i64,
    pub timestamp: i64,
    pub hash: String,
}

#[napi(object)]
pub struct EventItemsResponse {
    pub archive_height: Option<i64>,
    pub next_block: i64,
    /// The page's block headers, one per block number. Items reference them by
    /// `block_number`; the full blocks live in the `BlockStore` returned
    /// alongside this response.
    pub blocks: Vec<BlockHeader>,
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
        data: QueryResponseData { blocks },
        rollback_guard: res
            .rollback_guard
            .map(RollbackGuard::try_from)
            .transpose()
            .context("convert rollback guard")?,
    })
}

fn push_unique(missing: &mut Vec<String>, name: String) {
    if !missing.contains(&name) {
        missing.push(name);
    }
}

/// Builds the page's event items and its deduplicated blocks, accumulates the
/// page's transactions into `transaction_store`, and checks that every requested
/// block/transaction field came back. Returns `ConvertError::MissingFields`
/// (surfaced as `ImpossibleForTheQuery` on the JS side) when the source omitted
/// a requested non-nullable field or a joined row, and propagates genuine decode
/// errors otherwise.
#[allow(clippy::too_many_arguments)]
fn process_response(
    blocks: Vec<Vec<simple_types::Block>>,
    transactions: Vec<Vec<simple_types::Transaction>>,
    logs: Vec<Vec<simple_types::Log>>,
    decoder: &SelectionDecoder,
    should_checksum: bool,
    validated_block_fields: &[BlockField],
    requested_transaction_fields: &[TransactionField],
    transaction_store: &TransactionStore,
    block_store: &BlockStore,
    contract_name_by_address: &std::collections::HashMap<String, String>,
) -> std::result::Result<(Vec<EventItem>, Vec<BlockHeader>), ConvertError> {
    // The server returns one block per number; items reference them by number,
    // so keep them owned and track which numbers are present for coverage.
    let response_blocks: Vec<simple_types::Block> = blocks.into_iter().flatten().collect();
    let present_block_numbers: HashSet<u64> =
        response_blocks.iter().filter_map(|b| b.number).collect();

    let mut missing: Vec<String> = Vec::new();

    // Accumulate transactions into the store keyed by (blockNumber, txIndex).
    // Many logs share a transaction, and the server returns each one once, so
    // the page's transactions go in as one chunk.
    let mut transaction_keys: HashSet<(u64, u32)> = HashSet::new();
    if !requested_transaction_fields.is_empty() {
        let mut kept: Vec<simple_types::Transaction> = Vec::new();
        for tx in transactions.into_iter().flatten() {
            for &field in requested_transaction_fields {
                if let Some(name) = transaction_field_missing(&tx, field) {
                    push_unique(&mut missing, format!("transaction.{}", name));
                }
            }
            if let (Some(block_number), Some(transaction_index)) =
                (tx.block_number, tx.transaction_index)
            {
                transaction_keys
                    .insert((u64::from(block_number), u64::from(transaction_index) as u32));
                kept.push(tx);
            }
        }
        transaction_store.insert_evm_txs(kept);
    }

    // Validate every block field we requested — the user's selection plus the
    // always-required number/timestamp/hash — once per distinct block.
    for block in &response_blocks {
        for &field in validated_block_fields {
            if let Some(name) = block_field_missing(block, field) {
                push_unique(&mut missing, format!("block.{}", name));
            }
        }
    }

    // Coverage: every log must resolve to its block (when block fields were
    // requested) and its transaction (when transaction fields were requested).
    for log in logs.iter().flatten() {
        if !validated_block_fields.is_empty() {
            let present = log
                .block_number
                .is_some_and(|n| present_block_numbers.contains(&u64::from(n)));
            if !present {
                push_unique(&mut missing, "block".into());
            }
        }
        if !requested_transaction_fields.is_empty() {
            let present = match (log.block_number, log.transaction_index) {
                (Some(bn), Some(ti)) => {
                    transaction_keys.contains(&(u64::from(bn), u64::from(ti) as u32))
                }
                _ => false,
            };
            if !present {
                push_unique(&mut missing, "transaction".into());
            }
        }
    }

    if !missing.is_empty() {
        return Err(ConvertError::MissingFields(missing));
    }

    // Lean headers (number/timestamp/hash) for the page, one per number; items
    // reference them by number. The required trio is validated present above.
    let out_blocks: Vec<BlockHeader> = response_blocks
        .iter()
        .map(|b| -> Result<BlockHeader> {
            Ok(BlockHeader {
                number: b
                    .number
                    .map(i64::try_from)
                    .transpose()
                    .context("block.number overflow")?
                    .context("block.number missing")?,
                timestamp: map_i64(&b.timestamp)
                    .context("block.timestamp overflow")?
                    .context("block.timestamp missing")?,
                hash: map_hex_string(&b.hash).context("block.hash missing")?,
            })
        })
        .collect::<Result<Vec<_>>>()
        .context("mapping block headers")?;

    // Retained for every block, not just when an event selected a field beyond
    // the trio: number/timestamp/hash decode from the store like any other
    // field (see `decode_evm_block_field`), so the store needs an entry for
    // every block the config's always-included trio selection touches.
    block_store.insert_evm_blocks(response_blocks);

    let mut items = Vec::with_capacity(logs.iter().map(Vec::len).sum());
    for log in logs.into_iter().flatten() {
        let (log_index, src_address, block_number, transaction_index) =
            flatten_log_for_js(&log, should_checksum).context("mapping log")?;
        // Only structurally malformed logs (missing topic0, bad topic bytes)
        // surface here; per-registration decode failures are dropped inside
        // `route_and_decode`.
        let routed = decoder
            .route_and_decode_simple(
                &log,
                contract_name_by_address
                    .get(&src_address)
                    .map(String::as_str),
            )
            .context("decode event params")?;
        for routed in routed {
            items.push(EventItem {
                log_index,
                src_address: src_address.clone(),
                block_number,
                transaction_index,
                on_event_registration_index: routed.index,
                params: routed.params,
            });
        }
    }

    Ok((items, out_blocks))
}

fn flatten_log_for_js(
    log: &hypersync_client::simple_types::Log,
    should_checksum: bool,
) -> Result<(i64, String, i64, i64)> {
    let log_index: i64 = u64::from(log.log_index.context("log.logIndex missing")?)
        .try_into()
        .context("log.logIndex overflow")?;
    let src_address = encode_address(
        log.address.as_ref().context("log.address missing")?,
        should_checksum,
    );
    // block_number + transaction_index are force-selected in the query's log
    // field selection so they're always present, independent of the user's
    // field selection — they key the transaction store.
    let block_number: i64 = u64::from(log.block_number.context("log.blockNumber missing")?)
        .try_into()
        .context("log.blockNumber overflow")?;
    let transaction_index: i64 = u64::from(
        log.transaction_index
            .context("log.transactionIndex missing")?,
    )
    .try_into()
    .context("log.transactionIndex overflow")?;
    Ok((log_index, src_address, block_number, transaction_index))
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

/// Block fields the indexer always needs: `number` keys the page's blocks and
/// lets items reference them; the consumer reads `timestamp` and `hash` off
/// every block unconditionally. Force-added to the query and validated for
/// presence regardless of the user's selection.
const REQUIRED_BLOCK_FIELDS: &[BlockField] =
    &[BlockField::Number, BlockField::Timestamp, BlockField::Hash];

pub(crate) fn map_err(e: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{:?}", e))
}

#[cfg(test)]
mod tests {
    use super::*;
    use hypersync_client::simple_types;

    fn empty_decoder() -> SelectionDecoder {
        Decoder::from_registrations(&[], false)
            .unwrap()
            .selection(&[], &HashMap::new(), &Default::default())
            .unwrap()
    }

    // Routes `full_log` (zero topic0, one topic, empty data) to a wildcard
    // registration so success-path tests still produce an item now that
    // unrouted logs are dropped.
    fn zero_event_decoder() -> SelectionDecoder {
        Decoder::from_registrations(
            &[
                crate::evm_hypersync_source::types::OnEventRegistrationInput {
                    index: 0,
                    sighash: format!("0x{}", "00".repeat(32)),
                    topic_count: 1,
                    event_name: "Zero".to_string(),
                    contract_name: "Zero".to_string(),
                    is_wildcard: true,
                    depends_on_addresses: false,
                    // One no-filter selection pinning topic0 (an empty list would
                    // be `where: false` and match nothing).
                    topic_selections: vec![
                        crate::evm_hypersync_source::selection::TopicSelectionInput {
                            topic0: vec![format!("0x{}", "00".repeat(32))],
                            topic1: Some(vec![]),
                            topic2: Some(vec![]),
                            topic3: Some(vec![]),
                        },
                    ],
                    block_fields: vec![],
                    transaction_fields: vec![],
                    params: vec![],
                },
            ],
            false,
        )
        .unwrap()
        .selection(&[0], &HashMap::new(), &Default::default())
        .unwrap()
    }

    fn full_log(block_number: u64) -> simple_types::Log {
        simple_types::Log {
            log_index: Some(0.into()),
            block_number: Some(block_number.into()),
            transaction_index: Some(0u64.into()),
            address: Some(Default::default()),
            data: Some(Default::default()),
            topics: std::iter::once(Some(Default::default())).collect(),
            ..Default::default()
        }
    }

    #[test]
    fn missing_block_field_returns_typed_error() {
        // The server returned no block for the log but the user asked for
        // block.number/hash/timestamp.
        let err = process_response(
            vec![],
            vec![],
            vec![vec![simple_types::Log::default()]],
            &empty_decoder(),
            false,
            &[BlockField::Number, BlockField::Hash, BlockField::Timestamp],
            &[],
            &TransactionStore::new_evm(false),
            &BlockStore::new_evm(false),
            &Default::default(),
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
        block.number = Some(1);
        block.hash = Some(Default::default());
        // timestamp left None
        let err = process_response(
            vec![vec![block]],
            vec![],
            vec![vec![full_log(1)]],
            &empty_decoder(),
            false,
            &[BlockField::Number, BlockField::Hash, BlockField::Timestamp],
            &[],
            &TransactionStore::new_evm(false),
            &BlockStore::new_evm(false),
            &Default::default(),
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
    fn forced_block_fields_validated_even_when_user_requested_none() {
        // get_event_items force-adds REQUIRED_BLOCK_FIELDS and validates that
        // forced set, so number/timestamp/hash are guaranteed present even when
        // the user's config selected no block fields. Here the user requested
        // nothing yet a missing timestamp is still reported.
        let mut block = simple_types::Block::default();
        block.number = Some(1);
        block.hash = Some(Default::default());
        // timestamp left None
        let err = process_response(
            vec![vec![block]],
            vec![],
            vec![vec![full_log(1)]],
            &empty_decoder(),
            false,
            REQUIRED_BLOCK_FIELDS,
            &[],
            &TransactionStore::new_evm(false),
            &BlockStore::new_evm(false),
            &Default::default(),
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
        block.number = Some(1);
        block.hash = Some(Default::default());
        block.timestamp = Some(Default::default());
        // base_fee_per_gas left None
        let (items, _blocks) = process_response(
            vec![vec![block]],
            vec![],
            vec![vec![full_log(1)]],
            &zero_event_decoder(),
            false,
            &[
                BlockField::Number,
                BlockField::Hash,
                BlockField::Timestamp,
                BlockField::BaseFeePerGas,
            ],
            &[],
            &TransactionStore::new_evm(false),
            &BlockStore::new_evm(false),
            &Default::default(),
        )
        .expect("expected success when only nullable fields are absent");
        assert_eq!(items.len(), 1);
    }

    #[test]
    fn missing_transaction_field_with_transaction_present() {
        let mut block = simple_types::Block::default();
        block.number = Some(1);
        block.hash = Some(Default::default());
        block.timestamp = Some(Default::default());
        // The transaction is keyed to the log by (blockNumber, txIndex) but is
        // missing the requested hash, so transaction.hash is reported missing.
        let mut tx = simple_types::Transaction::default();
        tx.block_number = Some(1u64.into());
        tx.transaction_index = Some(0u64.into());
        let err = process_response(
            vec![vec![block]],
            vec![vec![tx]],
            vec![vec![full_log(1)]],
            &empty_decoder(),
            false,
            &[BlockField::Number, BlockField::Hash, BlockField::Timestamp],
            &[TransactionField::Hash],
            &TransactionStore::new_evm(false),
            &BlockStore::new_evm(false),
            &Default::default(),
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
    fn missing_transaction_when_not_returned() {
        // Transaction fields requested but the source returned no transaction for
        // the log's (blockNumber, txIndex).
        let mut block = simple_types::Block::default();
        block.number = Some(1);
        block.hash = Some(Default::default());
        block.timestamp = Some(Default::default());
        let err = process_response(
            vec![vec![block]],
            vec![],
            vec![vec![full_log(1)]],
            &empty_decoder(),
            false,
            &[BlockField::Number, BlockField::Hash, BlockField::Timestamp],
            &[TransactionField::Hash],
            &TransactionStore::new_evm(false),
            &BlockStore::new_evm(false),
            &Default::default(),
        )
        .err()
        .expect("expected MissingFields error");

        match err {
            ConvertError::MissingFields(fields) => {
                assert_eq!(fields, vec!["transaction".to_string()])
            }
            ConvertError::Other(e) => panic!("unexpected ConvertError::Other: {e:?}"),
        }
    }

    #[test]
    fn full_join_matches_block_and_transaction() {
        // Block and transaction live in separate response arrays; the log is
        // matched to its block by number and the transaction lands in the store
        // keyed by (blockNumber, txIndex). The page carries one deduplicated block.
        let mut block = simple_types::Block::default();
        block.number = Some(7);
        block.hash = Some(Default::default());
        block.timestamp = Some(Default::default());

        let mut tx = simple_types::Transaction::default();
        tx.block_number = Some(7u64.into());
        tx.transaction_index = Some(0u64.into());

        let store = TransactionStore::new_evm(false);
        let (items, blocks) = process_response(
            vec![vec![block]],
            vec![vec![tx]],
            vec![vec![full_log(7)]],
            &zero_event_decoder(),
            false,
            &[BlockField::Number, BlockField::Hash, BlockField::Timestamp],
            &[TransactionField::BlockNumber],
            &store,
            &BlockStore::new_evm(false),
            &Default::default(),
        )
        .expect("expected success when block and transaction join");

        assert_eq!(
            (
                items.iter().map(|i| i.block_number).collect::<Vec<_>>(),
                blocks.iter().map(|b| b.number).collect::<Vec<_>>(),
            ),
            (vec![7], vec![7])
        );
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
