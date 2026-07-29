use std::collections::HashSet;
use std::sync::Once;

use anyhow::{Context, Result};
use hypersync_client::{simple_types, RateLimitResponse};
use napi_derive::napi;

use crate::address_store::{AddressSet, AddressStore, SetCache};
use crate::block_store::BlockStore;
use crate::transaction_store::TransactionStore;

mod config;
pub(crate) mod decode;
mod query;
pub(crate) mod selection;
pub(crate) mod types;

use config::ClientConfig;
use decode::{Decoder, LogAddress, SelectionDecoder};
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
        address_store: &AddressStore,
    ) -> napi::Result<EvmHyperSyncClient> {
        init_logger(cfg.log_level.as_deref());

        let enable_checksum_addresses = cfg.enable_checksum_addresses.unwrap_or_default();

        let decoder = Decoder::from_registrations(
            &event_registrations,
            enable_checksum_addresses,
            address_store,
        )
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
        address_set: &AddressSet,
    ) -> napi::Result<(EventItemsResponse, TransactionStore, BlockStore)> {
        let client_filtered = crate::client_filtered_contracts::ClientFilteredContracts::from_vec(
            params.client_filtered_contracts.unwrap_or_default(),
        );
        let built = self
            .selection_builder
            .build(&params.registration_indexes, address_set, &client_filtered)
            .map_err(map_err)?;
        let set_cache = address_set.cache().clone();
        let selection_decoder = self
            .decoder
            .selection(
                &params.registration_indexes,
                &client_filtered,
                set_cache.clone(),
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
            max_num_logs: params.max_num_logs,
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
                &set_cache,
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

/// The whole per-query input for `get_event_items` beside the partition's
/// address set: the block range and its registration selection (by id). Log
/// selections, field selection, and the routing index are all derived
/// internally from the registrations passed at construction and the set.
#[napi(object)]
pub struct EventItemsQuery {
    pub from_block: i64,
    /// Inclusive; `None` queries to the end of available data.
    pub to_block: Option<i64>,
    /// `None` sends no server-side cap on the number of logs returned.
    pub max_num_logs: Option<i64>,
    pub registration_indexes: Vec<i64>,
    /// Contract names to fetch address-free even though their registrations
    /// depend on addresses (client-side filtering). Absent or empty
    /// means every address-dependent contract is filtered server-side.
    pub client_filtered_contracts: Option<Vec<String>>,
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
    /// The page's block headers, one per returned block number — including
    /// blocks no item references, which reorg detection still reads. Items
    /// reference theirs by `block_number`; the full blocks live in the
    /// `BlockStore` returned alongside this response, which keeps only the
    /// blocks items reference.
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

/// Builds the page's event items and its deduplicated block headers, fills the
/// page's transaction and block stores, and checks that every requested
/// block/transaction field came back. Only the blocks and transactions a routed
/// item joins to reach the stores — a log that routes nowhere is dropped, and
/// so is everything joined to it. Returns `ConvertError::MissingFields`
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
    set_cache: &SetCache,
) -> std::result::Result<(Vec<EventItem>, Vec<BlockHeader>), ConvertError> {
    let mut missing: Vec<String> = Vec::new();

    // Route before touching the joined tables: routing is what decides which
    // blocks and transactions anything will ever read.
    let mut items = Vec::with_capacity(logs.iter().map(Vec::len).sum());
    let mut referenced_blocks: HashSet<u64> = HashSet::new();
    let mut referenced_transactions: HashSet<(u64, u32)> = HashSet::new();
    {
        // One read lock for the whole page: registration from the JS thread waits
        // only as long as routing takes.
        let address_store = decoder.lock_store();
        for log in logs.into_iter().flatten() {
            let flat = flatten_log_for_js(&log, should_checksum).context("mapping log")?;
            // The emitter's raw 20 bytes are already the store's key, so ownership
            // and the effectiveStartBlock gate cost one hash lookup each — no
            // round-trip through the address string.
            let address_key = log.address.as_ref().context("log.address missing")?;
            let address = LogAddress {
                key: address_key.as_slice(),
                contract_name: set_cache.owner_of(address_key.as_slice()),
                block_number: flat.block_number,
            };
            // Only structurally malformed logs (missing topic0, bad topic bytes)
            // surface here; per-registration decode failures are dropped inside
            // `route_and_decode`.
            let routed = decoder
                .route_and_decode_simple(&log, &address, &address_store)
                .context("decode event params")?;
            if routed.is_empty() {
                continue;
            }
            let (block_key, _) = flat.transaction_key;
            referenced_blocks.insert(block_key);
            referenced_transactions.insert(flat.transaction_key);
            for routed in routed {
                items.push(EventItem {
                    log_index: flat.log_index,
                    src_address: flat.src_address.clone(),
                    block_number: flat.block_number,
                    transaction_index: flat.transaction_index,
                    on_event_registration_index: routed.index,
                    params: routed.params,
                });
            }
        }
    }

    // Accumulate transactions into the store keyed by (blockNumber, txIndex).
    // Many logs share a transaction, and the server returns each one once, so
    // the page's transactions go in as one chunk. A transaction no item
    // references is dropped whole — nothing ever reads its fields, so they
    // aren't validated either.
    let mut transaction_keys: HashSet<(u64, u32)> = HashSet::new();
    if !requested_transaction_fields.is_empty() {
        let mut kept: Vec<simple_types::Transaction> = Vec::new();
        for tx in transactions.into_iter().flatten() {
            // A row the source returned without its key backs no item — there
            // is nothing to join it to — so it is dropped unjudged. If a routed
            // item did want it, the coverage check below still reports the
            // transaction as missing.
            let (Some(block_number), Some(transaction_index)) =
                (tx.block_number, tx.transaction_index)
            else {
                continue;
            };
            let key = transaction_key(block_number, transaction_index);
            if !referenced_transactions.contains(&key) {
                continue;
            }
            for &field in requested_transaction_fields {
                if let Some(name) = transaction_field_missing(&tx, field) {
                    push_unique(&mut missing, format!("transaction.{}", name));
                }
            }
            transaction_keys.insert(key);
            kept.push(tx);
        }
        transaction_store.insert_evm_txs(kept);
    }

    // The server returns one block per number. Every returned block still
    // yields a header — reorg detection reads them all, items or not — so keep
    // them owned, validate them all, and track which numbers are present for
    // coverage.
    let response_blocks: Vec<simple_types::Block> = blocks.into_iter().flatten().collect();
    let present_block_numbers: HashSet<u64> =
        response_blocks.iter().filter_map(|b| b.number).collect();

    // Validate the requested block fields once per distinct block. The
    // always-required number/timestamp/hash back every header, so they are
    // checked on every returned block; the rest of the user's selection is only
    // ever read through the store, so it is checked only where an item can
    // reach it — same rule as transactions.
    for block in &response_blocks {
        let referenced = block
            .number
            .is_some_and(|number| referenced_blocks.contains(&number));
        for &field in validated_block_fields {
            if !referenced && !REQUIRED_BLOCK_FIELDS.contains(&field) {
                continue;
            }
            if let Some(name) = block_field_missing(block, field) {
                push_unique(&mut missing, format!("block.{}", name));
            }
        }
    }

    // Coverage: every routed item must resolve to its block (when block fields
    // were requested) and its transaction (when transaction fields were
    // requested).
    if !validated_block_fields.is_empty() {
        for block_number in &referenced_blocks {
            if !present_block_numbers.contains(block_number) {
                push_unique(&mut missing, "block".into());
            }
        }
    }
    if !requested_transaction_fields.is_empty() {
        for key in &referenced_transactions {
            if !transaction_keys.contains(key) {
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

    // Kept for every referenced block, not just when an event selected a field
    // beyond the trio: number/timestamp/hash decode from the store like any
    // other field (see `decode_evm_block_field`), so the store needs an entry
    // for every block the config's always-included trio selection touches.
    let mut kept_blocks = response_blocks;
    kept_blocks.retain(|b| {
        b.number
            .is_some_and(|number| referenced_blocks.contains(&number))
    });
    block_store.insert_evm_blocks(kept_blocks);

    Ok((items, out_blocks))
}

/// Key into the `TransactionStore`. The log side (which decides what a routed
/// item references) and the transaction side (which fills the store) must
/// produce identical keys or rows silently stop matching — a drift shows up as
/// a phantom "transaction missing", not as a compile error — so both derive
/// their keys here.
fn transaction_key(block_number: impl Into<u64>, transaction_index: impl Into<u64>) -> (u64, u32) {
    (block_number.into(), transaction_index.into() as u32)
}

/// A log's flattened JS fields, plus its transaction-store key.
struct FlatLog {
    log_index: i64,
    src_address: String,
    block_number: i64,
    transaction_index: i64,
    transaction_key: (u64, u32),
}

fn flatten_log_for_js(
    log: &hypersync_client::simple_types::Log,
    should_checksum: bool,
) -> Result<FlatLog> {
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
    let raw_block_number = log.block_number.context("log.blockNumber missing")?;
    let raw_transaction_index = log
        .transaction_index
        .context("log.transactionIndex missing")?;
    let block_number: i64 = u64::from(raw_block_number)
        .try_into()
        .context("log.blockNumber overflow")?;
    let transaction_index: i64 = u64::from(raw_transaction_index)
        .try_into()
        .context("log.transactionIndex overflow")?;
    Ok(FlatLog {
        log_index,
        src_address,
        block_number,
        transaction_index,
        transaction_key: transaction_key(raw_block_number, raw_transaction_index),
    })
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
    use crate::address_store::test_support::{evm_store, set_of};
    use crate::field_columns::test_support::str_column;
    use hypersync_client::simple_types;

    fn empty_decoder() -> SelectionDecoder {
        Decoder::from_registrations(&[], false, &evm_store(&[]))
            .unwrap()
            .selection(&[], &Default::default(), empty_set().cache().clone())
            .unwrap()
    }

    /// An address-free partition's set. Every fabricated log below emits from
    /// the zero address, which no fixture registers, so only wildcard
    /// registrations route — which is what these tests exercise.
    fn empty_set() -> AddressSet {
        set_of(&evm_store(&[]), &[])
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
                    start_block: None,
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
            &evm_store(&[("Zero", &[])]),
        )
        .unwrap()
        .selection(&[0], &Default::default(), empty_set().cache().clone())
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

    /// Same shape as `full_log`, but on a topic0 no fixture registration pins —
    /// so it routes nowhere.
    fn unrouted_log(block_number: u64) -> simple_types::Log {
        let mut topic0 = [0u8; 32];
        topic0[31] = 1;
        let topic0 = hypersync_client::format::LogArgument::from(topic0);
        simple_types::Log {
            topics: std::iter::once(Some(topic0)).collect(),
            ..full_log(block_number)
        }
    }

    #[test]
    fn missing_block_field_returns_typed_error() {
        // The server returned no block for the log but the user asked for
        // block.number/hash/timestamp.
        let err = process_response(
            vec![],
            vec![],
            vec![vec![full_log(1)]],
            &zero_event_decoder(),
            false,
            &[BlockField::Number, BlockField::Hash, BlockField::Timestamp],
            &[],
            &TransactionStore::new_evm(false),
            &BlockStore::new_evm(false),
            empty_set().cache(),
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
            empty_set().cache(),
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
            empty_set().cache(),
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
            empty_set().cache(),
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
            &zero_event_decoder(),
            false,
            &[BlockField::Number, BlockField::Hash, BlockField::Timestamp],
            &[TransactionField::Hash],
            &TransactionStore::new_evm(false),
            &BlockStore::new_evm(false),
            empty_set().cache(),
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
            &zero_event_decoder(),
            false,
            &[BlockField::Number, BlockField::Hash, BlockField::Timestamp],
            &[TransactionField::Hash],
            &TransactionStore::new_evm(false),
            &BlockStore::new_evm(false),
            empty_set().cache(),
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
            empty_set().cache(),
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

    // `materialize` uses `block_in_place`, which needs a multi-thread runtime.
    #[tokio::test(flavor = "multi_thread")]
    async fn unrouted_logs_keep_their_block_and_transaction_out_of_the_stores() {
        // Block 1's log routes; block 2's doesn't. Both blocks and both
        // transactions come back from the server, but only block 1's pair is
        // ever read, so only it is stored.
        let block = |number: u64| simple_types::Block {
            number: Some(number),
            hash: Some(Default::default()),
            timestamp: Some(Default::default()),
            ..Default::default()
        };
        let tx = |block_number: u64| simple_types::Transaction {
            block_number: Some(block_number.into()),
            transaction_index: Some(0u64.into()),
            hash: Some(Default::default()),
            ..Default::default()
        };

        let transaction_store = TransactionStore::new_evm(false);
        let block_store = BlockStore::new_evm(false);
        let (items, blocks) = process_response(
            vec![vec![block(1), block(2)]],
            vec![vec![tx(1), tx(2)]],
            vec![vec![full_log(1), unrouted_log(2)]],
            &zero_event_decoder(),
            false,
            REQUIRED_BLOCK_FIELDS,
            &[TransactionField::Hash],
            &transaction_store,
            &block_store,
            empty_set().cache(),
        )
        .expect("expected success");

        let stored_transaction_hashes = transaction_store
            .materialize(
                vec![1, 2],
                vec![0, 0],
                vec![(1u64 << (crate::transaction_store::EvmTxField::Hash as u32)) as f64; 2],
            )
            .await
            .expect("materialize transactions");
        let stored_block_hashes = block_store
            .materialize(
                vec![1, 2],
                vec![(1u64 << (crate::block_store::EvmBlockField::Hash as u32)) as f64; 2],
            )
            .await
            .expect("materialize blocks");

        let zero_hash = format!("0x{}", "00".repeat(32));
        assert_eq!(
            (
                items.iter().map(|i| i.block_number).collect::<Vec<_>>(),
                blocks.iter().map(|b| b.number).collect::<Vec<_>>(),
                str_column(&stored_transaction_hashes, "hash"),
                str_column(&stored_block_hashes, "hash"),
            ),
            (
                vec![1],
                // Every returned block still yields a header; only the store is filtered.
                vec![1, 2],
                vec![Some(zero_hash.clone()), None],
                vec![Some(zero_hash), None],
            )
        );
    }

    #[test]
    fn unrouted_logs_do_not_demand_their_block_and_transaction() {
        // The mirror of `missing_transaction_when_not_returned`: the source
        // returned neither the block nor the transaction for this log, but it
        // routes nowhere, so nothing will ever read them and the page stands.
        // Without this, filtering the stores would silently diverge from what
        // the coverage check still insists the source deliver.
        let (items, blocks) = process_response(
            vec![],
            vec![],
            vec![vec![unrouted_log(1)]],
            &zero_event_decoder(),
            false,
            REQUIRED_BLOCK_FIELDS,
            &[TransactionField::Hash],
            &TransactionStore::new_evm(false),
            &BlockStore::new_evm(false),
            empty_set().cache(),
        )
        .expect("an unrouted log's absent block and transaction are not missing fields");

        assert_eq!((items.len(), blocks.len()), (0, 0));
    }

    #[test]
    fn unreferenced_block_is_judged_only_on_its_header_fields() {
        // Block 2 backs no item, so its absent `gasUsed` can't fail the page —
        // nothing can read it. The header trio is still required of it, since
        // every returned block yields a header.
        let block = |number: u64| simple_types::Block {
            number: Some(number),
            hash: Some(Default::default()),
            timestamp: Some(Default::default()),
            gas_used: (number == 1).then(Default::default),
            ..Default::default()
        };
        let (items, blocks) = process_response(
            vec![vec![block(1), block(2)]],
            vec![],
            vec![vec![full_log(1), unrouted_log(2)]],
            &zero_event_decoder(),
            false,
            &[
                BlockField::Number,
                BlockField::Hash,
                BlockField::Timestamp,
                BlockField::GasUsed,
            ],
            &[],
            &TransactionStore::new_evm(false),
            &BlockStore::new_evm(false),
            empty_set().cache(),
        )
        .expect("an unreferenced block's absent selected field is not a missing field");

        assert_eq!(
            (
                items.len(),
                blocks.iter().map(|b| b.number).collect::<Vec<_>>()
            ),
            (1, vec![1, 2])
        );
    }

    #[test]
    fn keyless_transaction_is_dropped_unjudged() {
        // The source returned a transaction with no (blockNumber, txIndex), so
        // it joins to nothing; its absent `hash` must not fail a page whose
        // routed item got the transaction it asked for.
        let mut block = simple_types::Block::default();
        block.number = Some(1);
        block.hash = Some(Default::default());
        block.timestamp = Some(Default::default());

        let mut keyless = simple_types::Transaction::default();
        keyless.hash = None;

        let (items, _blocks) = process_response(
            vec![vec![block]],
            vec![vec![
                simple_types::Transaction {
                    block_number: Some(1u64.into()),
                    transaction_index: Some(0u64.into()),
                    hash: Some(Default::default()),
                    ..Default::default()
                },
                keyless,
            ]],
            vec![vec![full_log(1)]],
            &zero_event_decoder(),
            false,
            REQUIRED_BLOCK_FIELDS,
            &[TransactionField::Hash],
            &TransactionStore::new_evm(false),
            &BlockStore::new_evm(false),
            empty_set().cache(),
        )
        .expect("a keyless transaction's absent field is not a missing field");

        assert_eq!(items.len(), 1);
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
