use std::collections::HashSet;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Once, RwLock};

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
use decode::DecoderCore;
use query::{BlockField, LogField, LogFilter, LogSelection, Query, TransactionField};
use selection::{BuiltLogSelection, SelectionBuilder};
use types::{
    encode_address, map_hex_string, map_i64, Block, OnEventRegistration, ParamValue, RollbackGuard,
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

// A reqwest client speaking HTTP/2 multiplexes every request to the host over a
// single TCP connection, whose concurrent-stream cap is negotiated per
// connection (typically ~100). Requests beyond the cap queue client-side, so
// one client stalls at high query concurrency. Each hypersync_client::Client
// owns its own reqwest client (own connection), so the pool holds several and
// treats each as full at STREAMS_PER_CLIENT concurrent requests.
const STREAMS_PER_CLIENT: usize = 80;
// Past this point extra connections stop helping — bandwidth and decode
// threads become the ceiling — so cap the pool regardless of concurrency.
const MAX_CLIENTS: usize = 8;

struct PooledClient {
    client: hypersync_client::Client,
    in_flight: AtomicUsize,
}

// Keeps the client alive for the request and releases its in-flight slot on
// drop (including error paths).
struct Lease(Arc<PooledClient>);

impl Lease {
    fn client(&self) -> &hypersync_client::Client {
        &self.0.client
    }
}

impl Drop for Lease {
    fn drop(&mut self) {
        self.0.in_flight.fetch_sub(1, Ordering::Relaxed);
    }
}

struct ClientPool {
    cfg: ClientConfig,
    user_agent: String,
    clients: RwLock<Vec<Arc<PooledClient>>>,
}

impl ClientPool {
    fn new_client(&self) -> Result<Arc<PooledClient>> {
        Ok(Arc::new(PooledClient {
            client: hypersync_client::Client::new_with_agent(
                self.cfg.clone().into(),
                self.user_agent.clone(),
            )
            .context("build pooled client")?,
            in_flight: AtomicUsize::new(0),
        }))
    }

    fn new(cfg: ClientConfig, user_agent: String) -> Result<ClientPool> {
        let pool = ClientPool {
            cfg,
            user_agent,
            clients: RwLock::new(vec![]),
        };
        let first = pool.new_client()?;
        pool.clients.write().unwrap().push(first);
        Ok(pool)
    }

    // Fill-first: pack requests into the earliest clients so their connections
    // stay warm and later clients only come into play (and only get created)
    // when everything before them is at stream capacity. Spreading evenly would
    // leave every connection lukewarm at low load, and an idle one can drop
    // its connection right before a request lands on it.
    // Grow-only: idle clients are cheap and the underlying client already
    // recreates its connection every 60s, so shrinking buys nothing.
    fn acquire(&self) -> Result<Lease> {
        let claim_non_full = (|| {
            let clients = self.clients.read().unwrap();
            for pooled in clients.iter() {
                // fetch_add claims the slot atomically; concurrent acquires that
                // push a client just past the cap back off and move on.
                if pooled.in_flight.fetch_add(1, Ordering::Relaxed) < STREAMS_PER_CLIENT {
                    return Some(Lease(pooled.clone()));
                }
                pooled.in_flight.fetch_sub(1, Ordering::Relaxed);
            }
            None
        });

        if let Some(lease) = claim_non_full() {
            return Ok(lease);
        }

        {
            let mut clients = self.clients.write().unwrap();
            if clients.len() < MAX_CLIENTS {
                let pooled = self.new_client()?;
                pooled.in_flight.fetch_add(1, Ordering::Relaxed);
                let lease = Lease(pooled.clone());
                clients.push(pooled);
                return Ok(lease);
            }
        }

        // Retry after the write lock: another acquire may have freed or added
        // capacity between our scan and here.
        if let Some(lease) = claim_non_full() {
            return Ok(lease);
        }

        // Pool at MAX_CLIENTS and every client at capacity: overflow onto the
        // least-loaded client rather than queueing here — the connection-level
        // queue in reqwest handles the excess.
        let clients = self.clients.read().unwrap();
        let pooled = clients
            .iter()
            .min_by_key(|p| p.in_flight.load(Ordering::Relaxed))
            .expect("pool is never empty")
            .clone();
        pooled.in_flight.fetch_add(1, Ordering::Relaxed);
        Ok(Lease(pooled))
    }
}

#[napi]
pub struct EvmHypersyncClient {
    pool: ClientPool,
    enable_checksum_addresses: bool,
    decoder: DecoderCore,
    selection_builder: SelectionBuilder,
}

#[napi]
impl EvmHypersyncClient {
    #[napi(factory)]
    pub fn new(
        cfg: ClientConfig,
        user_agent: String,
        event_registrations: Vec<OnEventRegistration>,
    ) -> napi::Result<EvmHypersyncClient> {
        init_logger(cfg.log_level.as_deref());

        let enable_checksum_addresses = cfg.enable_checksum_addresses.unwrap_or_default();

        let decoder =
            DecoderCore::from_registrations(&event_registrations, enable_checksum_addresses)
                .context("build decoder")
                .map_err(map_err)?;

        let selection_builder = SelectionBuilder::from_registrations(&event_registrations)
            .context("build selection builder")
            .map_err(map_err)?;

        let pool = ClientPool::new(cfg, user_agent).map_err(map_err)?;

        Ok(EvmHypersyncClient {
            pool,
            enable_checksum_addresses,
            decoder,
            selection_builder,
        })
    }

    #[napi]
    pub async fn get_height(&self) -> napi::Result<i64> {
        let lease = self.pool.acquire().map_err(map_err)?;
        let height = lease.client().get_height().await.map_err(|e| {
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
        let lease = self.pool.acquire().map_err(map_err)?;
        let res = lease
            .client()
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
        let built = self
            .selection_builder
            .build(
                &params.registration_indexes,
                &params.addresses_by_contract_name,
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
        let lease = self.pool.acquire().map_err(map_err)?;
        let res = lease
            .client()
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
                &self.decoder,
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
    decoder: &DecoderCore,
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
        // Propagate genuine decode errors (malformed bytes, ABI mismatch) up to
        // the JS caller instead of silently coercing them into a drop — a drop
        // is reserved for logs that route to no registration.
        let routed = decoder
            .route_and_decode_simple(
                &log,
                contract_name_by_address
                    .get(&src_address)
                    .map(String::as_str),
            )
            .context("decode event params")?;
        if let Some(routed) = routed {
            items.push(EventItem {
                log_index,
                src_address,
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

    fn empty_decoder() -> DecoderCore {
        DecoderCore::from_registrations(&[], false).unwrap()
    }

    // Routes `full_log` (zero topic0, one topic, empty data) to a wildcard
    // registration so success-path tests still produce an item now that
    // unrouted logs are dropped.
    fn zero_event_decoder() -> DecoderCore {
        DecoderCore::from_registrations(
            &[crate::evm_hypersync_source::types::OnEventRegistration {
                index: 0,
                sighash: format!("0x{}", "00".repeat(32)),
                topic_count: 1,
                event_name: "Zero".to_string(),
                contract_name: "Zero".to_string(),
                is_wildcard: true,
                depends_on_addresses: false,
                topic_selections: vec![],
                block_fields: vec![],
                transaction_fields: vec![],
                params: vec![],
            }],
            false,
        )
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

    fn test_pool() -> ClientPool {
        ClientPool::new(
            ClientConfig {
                url: "https://eth.hypersync.xyz".to_string(),
                api_token: "test".to_string(),
                ..Default::default()
            },
            "test-agent".to_string(),
        )
        .unwrap()
    }

    fn pool_loads(pool: &ClientPool) -> Vec<usize> {
        pool.clients
            .read()
            .unwrap()
            .iter()
            .map(|p| p.in_flight.load(Ordering::Relaxed))
            .collect()
    }

    #[test]
    fn client_pool_fills_first_client_before_growing() {
        let pool = test_pool();

        let full_first: Vec<_> = (0..STREAMS_PER_CLIENT)
            .map(|_| pool.acquire().unwrap())
            .collect();
        assert_eq!(pool_loads(&pool), vec![STREAMS_PER_CLIENT]);

        // The next request spills into a newly created second client.
        let spill = pool.acquire().unwrap();
        assert_eq!(pool_loads(&pool), vec![STREAMS_PER_CLIENT, 1]);

        // Freeing a slot on the first client makes it the target again.
        drop(full_first);
        let after_release = pool.acquire().unwrap();
        assert_eq!(pool_loads(&pool), vec![1, 1]);

        drop((spill, after_release));
        // Grow-only: releasing everything keeps the clients around.
        assert_eq!(pool_loads(&pool), vec![0, 0]);
    }

    #[test]
    fn client_pool_overflows_at_max_clients() {
        let pool = test_pool();

        let saturating: Vec<_> = (0..MAX_CLIENTS * STREAMS_PER_CLIENT)
            .map(|_| pool.acquire().unwrap())
            .collect();
        assert_eq!(pool_loads(&pool), vec![STREAMS_PER_CLIENT; MAX_CLIENTS]);

        // Beyond full capacity the pool stays at MAX_CLIENTS and overflows
        // onto the least-loaded client instead of creating more.
        let overflow = pool.acquire().unwrap();
        let loads = pool_loads(&pool);
        assert_eq!(
            (loads.len(), loads.iter().sum::<usize>()),
            (MAX_CLIENTS, MAX_CLIENTS * STREAMS_PER_CLIENT + 1)
        );

        drop((saturating, overflow));
        assert_eq!(pool_loads(&pool), vec![0; MAX_CLIENTS]);
    }
}
