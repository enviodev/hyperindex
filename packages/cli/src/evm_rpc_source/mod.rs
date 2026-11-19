use anyhow::Context;
use napi_derive::napi;
use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::Semaphore;

mod classify;
mod client;
mod enrich;
pub(crate) mod fields;
mod head_checks;
mod inflight;
mod interval;
mod logs;
mod responses;
mod transactions;

use crate::address_store::AddressSet;
use crate::block_selection::BlockSelection;
use crate::chain_buffer::evm::{log_column, LogView};
use crate::chain_buffer::page::{Page, PageData};
use crate::chain_buffer::table::make_key;
use crate::chain_buffer::{ChainBuffer, Ecosystem, EvmRegistrations, Shared};
use crate::evm_hypersync_source::query::BlockField;
use crate::evm_hypersync_source::selection::BuiltLogSelection;
use crate::logger::{BoundLogger, Level, Logger};
use crate::request_stats::RequestStat;
use classify::{
    is_rate_limited_message, is_response_too_large_message, is_unsupported_request,
    suggested_block_interval_from_message,
};
use client::{parse_hex_u64, JsonRpcClient, RpcError};
use enrich::{BlockRead, EnrichError, EnrichRequest, Fetches, PageRefs, SelectedFields};
use hypersync_client::format::{self, Hex};
use interval::{IntervalState, SyncConfig};
use transactions::TransactionRead;

#[napi(object)]
pub struct EvmRpcClientConfig {
    pub url: String,
    pub max_concurrent_requests: Option<i64>,
    pub headers: Option<HashMap<String, String>>,
    // Sync-tuning knobs for the paging AIMD state (see `interval::SyncConfig`).
    // Resolved (defaulted, env-overridden) by ReScript's `EvmChain.getSyncConfig`
    // — that's the single source of defaults, so these are required here.
    pub initial_block_interval: i64,
    pub backoff_multiplicative: f64,
    pub acceleration_additive: i64,
    pub interval_ceiling: i64,
    pub backoff_millis: i64,
    pub query_timeout_millis: i64,
    /// How many addresses one `eth_getLogs` may carry when an address-free read
    /// is asked again by address.
    pub max_addresses_per_request: i64,
}

/// Raw `eth_getLogs` entry as the provider serialises it: integer fields are
/// 0x-prefixed hex quantities that decoding later converts.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawLog {
    address: String,
    topics: Vec<String>,
    data: String,
    block_number: String,
    transaction_hash: String,
    transaction_index: String,
    block_hash: String,
    log_index: String,
}

/// A log some registration matches, with the two hashes the page needs from
/// it: the block hash is a reorg observation, and the transaction hash is
/// what enrichment requests are keyed by.
struct MatchedLog {
    block_number: u64,
    log_index: u64,
    transaction_index: u32,
    address: [u8; 20],
    topics: Vec<[u8; 32]>,
    data: Vec<u8>,
    /// The registrations it matches, by index.
    registrations: Vec<u32>,
    registers: bool,
    block_hash: format::Hash,
    transaction_hash: format::Hash,
}

impl RawLog {
    fn to_matched(&self) -> anyhow::Result<MatchedLog> {
        let address = format::Address::decode_hex(&self.address).context("log.address")?;
        let topics = self
            .topics
            .iter()
            .take(4)
            .map(|topic| {
                format::LogArgument::decode_hex(topic)
                    .map(|topic| **topic)
                    .context("log.topics")
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        Ok(MatchedLog {
            block_number: parse_hex_u64(&self.block_number).context("log.blockNumber")?,
            log_index: parse_hex_u64(&self.log_index).context("log.logIndex")?,
            transaction_index: u32::try_from(
                parse_hex_u64(&self.transaction_index).context("log.transactionIndex")?,
            )
            .context("log.transactionIndex exceeds what a block holds")?,
            address: **address,
            topics,
            data: format::Data::decode_hex(&self.data)
                .context("log.data")?
                .to_vec(),
            registrations: Vec::new(),
            registers: false,
            block_hash: format::Hash::decode_hex(&self.block_hash).context("log.blockHash")?,
            transaction_hash: format::Hash::decode_hex(&self.transaction_hash)
                .context("log.transactionHash")?,
        })
    }
}

impl MatchedLog {
    fn view(&self) -> LogView<'_> {
        LogView {
            block_number: self.block_number,
            address: &self.address,
            topics: std::array::from_fn(|position| {
                self.topics.get(position).map(|topic| topic.as_slice())
            }),
        }
    }
}

#[napi(object)]
pub struct NextPageParams {
    pub from_block: i64,
    /// Upper bound on the query range; the actual `toBlock` is decided
    /// internally from the partition's AIMD-suggested interval and returned
    /// on `NextPageResponse`.
    pub to_block_ceiling: i64,
    pub partition_id: String,
    /// The event registrations selecting logs, by chain-scoped id. Log
    /// selections and the matching index are derived internally from the
    /// registrations passed at construction. Empty selects no logs.
    pub on_event_registration_indexes: Vec<i64>,
    /// The block handlers selecting blocks, by chain-scoped id.
    pub on_block_registration_indexes: Vec<i64>,
    /// The transaction handlers selecting transactions, by chain-scoped id.
    pub on_transaction_registration_indexes: Vec<i64>,
    /// Contract names to fetch address-free even though their registrations
    /// depend on addresses (client-side filtering). Absent or empty
    /// means every address-dependent contract is filtered server-side.
    pub client_filtered_contracts: Option<Vec<String>>,
    /// How many times this query has already been retried, which sets how long
    /// a transient miss waits before the next attempt.
    pub retry: i64,
    /// Blocks at or above this one can still be reorged, so each of them in the
    /// page has its header read and its logs checked against it, even a
    /// blocks-only page with no handler block in range. Absent when the whole
    /// range is final.
    pub reorgable_from: Option<i64>,
    /// The chain's height as last seen, which the head checks reach down from.
    pub known_height: i64,
}

/// What a page read came back as, and so which of `NextPageResult`'s optional
/// fields are set. The two retryable outcomes are their own kinds rather than a
/// nested decision object: one discriminator means one place for the ReScript
/// side to match on.
#[napi(string_enum)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PageOutcome {
    Ok,
    /// Ask again for a narrower range, with no wait.
    SuggestedToBlock,
    /// Wait, then ask for the same range again.
    Backoff,
    /// The provider cannot serve the selected fields.
    FieldSelection,
    /// The node that answered has not reached `block_number` yet.
    BehindHead,
}

/// The outcome of a page read.
#[napi(object, object_from_js = false)]
pub struct NextPageResult {
    pub kind: PageOutcome,
    /// The requests that finished since the source last reported any, so
    /// per-source totals stay exact whichever call a shared read was issued by.
    pub request_stats: Vec<RequestStat>,
    /// The block this attempt targeted: the page's own `toBlock` when it
    /// succeeded, the block it got as far as otherwise.
    pub to_block: i64,
    /// What to say about a failure: on `Backoff` the line the retry logs, on
    /// `FieldSelection` why the selection cannot be served.
    pub message: Option<String>,
    /// The cause logged beside `message`, where there is one distinct from it:
    /// the provider's own words, or the transport's.
    pub provider_message: Option<String>,
    /// `FieldSelection` and `BehindHead` only: the block it happened on, which
    /// is the one thing that makes an unservable selection diagnosable.
    pub block_number: Option<i64>,
    /// `SuggestedToBlock` only: the narrower end to ask for instead.
    pub retry_to_block: Option<i64>,
    /// `Backoff` only: how long to wait first.
    pub backoff_millis: Option<i64>,
}

/// A node that answered badly once may not again, so a transient miss waits
/// longer with every attempt rather than the configured backoff, which is tuned
/// for a provider erroring outright.
const TRANSIENT_BACKOFF_STEP_MILLIS: i64 = 500;
const TRANSIENT_BACKOFF_MIN_MILLIS: i64 = 100;

fn transient_backoff_millis(retry: i64) -> i64 {
    retry
        .saturating_mul(TRANSIENT_BACKOFF_STEP_MILLIS)
        .max(TRANSIENT_BACKOFF_MIN_MILLIS)
}

/// Where a page read failed. The two halves are judged differently: a rejected
/// `eth_getLogs` is what the range's size answers for, while the reads behind
/// it fail per block and per transaction, which no block range decides.
enum PageError {
    Logs(RpcError),
    Enrich(EnrichError),
}

impl From<EnrichError> for PageError {
    fn from(error: EnrichError) -> Self {
        PageError::Enrich(error)
    }
}

impl NextPageResult {
    /// The shape every outcome shares: no items, nothing to say, nothing to
    /// retry. Each arm fills in what its own kind means.
    fn new(kind: PageOutcome, to_block: u64, request_stats: Vec<RequestStat>) -> Self {
        NextPageResult {
            kind,
            request_stats,
            to_block: to_block as i64,
            message: None,
            provider_message: None,
            block_number: None,
            retry_to_block: None,
            backoff_millis: None,
        }
    }

    fn backoff(
        message: String,
        backoff_millis: i64,
        to_block: u64,
        request_stats: Vec<RequestStat>,
    ) -> Self {
        NextPageResult {
            message: Some(message),
            backoff_millis: Some(backoff_millis),
            ..NextPageResult::new(PageOutcome::Backoff, to_block, request_stats)
        }
    }

    fn suggested_to_block(
        retry_to_block: u64,
        to_block: u64,
        request_stats: Vec<RequestStat>,
    ) -> Self {
        NextPageResult {
            retry_to_block: Some(retry_to_block as i64),
            ..NextPageResult::new(PageOutcome::SuggestedToBlock, to_block, request_stats)
        }
    }
}

/// Outcome of a rollback-depth block-hash read. `message` is set when the read
/// failed, in which case the page returned alongside it is empty.
#[napi(object)]
pub struct BlockHashResult {
    pub message: Option<String>,
    /// Set alongside `message` when the node that answered has not reached
    /// this block yet.
    pub behind_head_block: Option<i64>,
    pub request_stats: Vec<RequestStat>,
}

#[napi]
pub struct EvmRpcClient {
    inner: Arc<JsonRpcClient>,
    chain: Arc<Shared>,
    evm: Arc<EvmRegistrations>,
    sync_config: SyncConfig,
    max_addresses_per_request: usize,
    logger: BoundLogger,
    intervals: IntervalState,
    /// Coalesces block, transaction and receipt reads that overlap in time,
    /// including across the partitions of one chain, which scan the same blocks
    /// at the head.
    fetches: Fetches,
    /// The fields each registration selected, as table field masks. An item's block
    /// and transaction are fetched for the union of the masks of the items that
    /// reference them, so an event selecting nothing costs no request.
    registration_fields: HashMap<i64, SelectedFields>,
    /// What every block and transaction is decoded for: the union of the
    /// selections above, not just the ones of the page that fetched the
    /// response, so a later page with a different selection is served from the
    /// chain buffer rather than refetched.
    block_read: BlockRead,
    chain_tx_mask: u64,
    /// Whether the provider has been seen refusing reads by block hash, which
    /// is said once per source rather than on every block.
    warned_block_hash_refusal: AtomicBool,
    /// Whether the provider has ever answered a read by block hash, which
    /// makes any later refusal one of a hash it doesn't know yet.
    answered_block_hash_read: AtomicBool,
}

/// How many times a page is retried, a node behind the head taking about a
/// second over them, before a refusal of reads by hash is taken to mean the
/// provider doesn't serve them.
const RETRIES_BEFORE_RECHECKING_BY_NUMBER: i64 = 3;

/// How many blocks a page reads for its block or transaction handlers at most:
/// each costs an `eth_getBlockByNumber`, which the log range's size says
/// nothing about.
const MAX_HANDLER_BLOCKS_PER_PAGE: usize = 100;

/// Everything one page read works from: the range it covers, the queries to run
/// over it, the chain buffer whose contents decide what still has to be fetched, and
/// what a retry decision about it would need.
struct PageQuery<'a> {
    partition_id: &'a str,
    from_block: u64,
    to_block: u64,
    reorgable_from: Option<u64>,
    known_height: u64,
    retry: i64,
    selections: &'a [BuiltLogSelection],
    address_set: &'a AddressSet,
    block_selection: &'a BlockSelection,
    /// Reads every block of the page in full.
    transactions: Option<&'a TransactionRead<'a>>,
    block_read: &'a BlockRead,
    known: &'a ChainBuffer,
}

#[napi]
impl EvmRpcClient {
    #[napi(factory)]
    pub fn new(
        cfg: EvmRpcClientConfig,
        buffer: &ChainBuffer,
        logger: &Logger,
        bound_fields_json: Vec<String>,
    ) -> napi::Result<EvmRpcClient> {
        let max_concurrent_requests = cfg
            .max_concurrent_requests
            .filter(|v| *v > 0)
            .map_or(JsonRpcClient::default_max_concurrent_requests(), |v| {
                (v as usize).min(Semaphore::MAX_PERMITS)
            });
        // A zero value would make `fromBlock + interval - 1` underflow, and a
        // zero timeout would cancel every request before it left.
        let positive_u64 = |value: i64, name: &str| {
            u64::try_from(value)
                .ok()
                .filter(|v| *v > 0)
                .ok_or_else(|| map_err(anyhow::anyhow!("{name} must be positive, got {value}")))
        };
        // `queryTimeoutMillis` is documented as how long to wait before
        // cancelling an RPC request, so it bounds each one. Bounding the page
        // instead would cancel reads the provider was answering fine, over a
        // total the caller's only lever — the block range — does not decide.
        let request_timeout_millis = positive_u64(cfg.query_timeout_millis, "queryTimeoutMillis")?;
        let max_addresses_per_request =
            positive_u64(cfg.max_addresses_per_request, "maxAddressesPerRequest")? as usize;
        let inner = JsonRpcClient::new(
            cfg.url,
            request_timeout_millis,
            max_concurrent_requests,
            cfg.headers,
        )
        .map_err(map_err)?;
        let chain = buffer.shared();
        let evm = chain.evm().map_err(map_err)?;
        let event_registrations = &evm.inputs;
        // 0.0 would collapse every shrink to the floor of 1 block and 1.0 would
        // never shrink at all, so both ends are excluded (this also rejects NaN).
        if !(cfg.backoff_multiplicative > 0.0 && cfg.backoff_multiplicative < 1.0) {
            return Err(map_err(anyhow::anyhow!(
                "backoffMultiplicative must be in (0.0, 1.0), got {}",
                cfg.backoff_multiplicative,
            )));
        }
        let sync_config = SyncConfig {
            initial_block_interval: positive_u64(
                cfg.initial_block_interval,
                "initialBlockInterval",
            )?,
            backoff_multiplicative: cfg.backoff_multiplicative,
            acceleration_additive: u64::try_from(cfg.acceleration_additive)
                .context("accelerationAdditive must be non-negative")
                .map_err(map_err)?,
            interval_ceiling: positive_u64(cfg.interval_ceiling, "intervalCeiling")?,
            backoff_millis: u64::try_from(cfg.backoff_millis)
                .context("backoffMillis must be non-negative")
                .map_err(map_err)?,
        };
        let registration_fields: HashMap<i64, SelectedFields> = event_registrations
            .iter()
            .map(|reg| {
                (
                    reg.index,
                    SelectedFields {
                        block_mask: BlockField::store_mask(&reg.block_fields),
                        tx_mask: fields::tx_mask(&reg.transaction_fields),
                    },
                )
            })
            .collect();
        // Registrations are fixed once the client is built, so what a response
        // is read for is too.
        let chain_fields =
            registration_fields
                .values()
                .fold(SelectedFields::default(), |acc, fields| SelectedFields {
                    block_mask: acc.block_mask | fields.block_mask,
                    tx_mask: acc.tx_mask | fields.tx_mask,
                });
        Ok(EvmRpcClient {
            inner: Arc::new(inner),
            chain,
            evm: evm.clone(),
            sync_config,
            max_addresses_per_request,
            logger: logger.bind(bound_fields_json),
            intervals: IntervalState::new(),
            fetches: Fetches::default(),
            registration_fields,
            block_read: BlockRead::for_chain(chain_fields.block_mask),
            chain_tx_mask: chain_fields.tx_mask,
            warned_block_hash_refusal: AtomicBool::new(false),
            answered_block_hash_read: AtomicBool::new(false),
        })
    }

    /// Forget every in-flight block, transaction and receipt read. After a
    /// reorg an in-flight response may describe the orphaned fork, so a read
    /// issued afterwards must observe the chain again rather than join one.
    /// The chain buffer is rolled back separately, which is what retires the data
    /// already merged from that fork.
    #[napi]
    pub fn on_reorg(&self) {
        self.fetches.clear();
    }

    /// Re-read the given blocks and return them as a page of hash-only
    /// observations, for the rollback-depth search. Never served from the
    /// chain buffer: the whole question being asked is whether the stored hashes still
    /// match the chain.
    #[napi]
    pub async fn get_block_hashes(
        &self,
        block_numbers: Vec<i64>,
    ) -> napi::Result<(BlockHashResult, Page)> {
        let numbers: Vec<u64> = block_numbers
            .into_iter()
            .map(u64::try_from)
            .collect::<Result<_, _>>()
            .context("block number is negative")
            .map_err(map_err)?;
        match enrich::fetch_block_hashes(&self.inner, &self.fetches, &numbers).await {
            Ok(blocks) => Ok((
                BlockHashResult {
                    message: None,
                    behind_head_block: None,
                    request_stats: self.inner.take_stats(),
                },
                Page::from_data(blocks),
            )),
            // The page is empty on failure and the caller reads `message`
            // instead; an empty page is cheap enough not to be worth an optional.
            Err(err) => Ok((
                BlockHashResult {
                    message: Some(err.to_string()),
                    behind_head_block: match err {
                        EnrichError::BehindHead { block_number, .. } => Some(block_number as i64),
                        _ => None,
                    },
                    request_stats: self.inner.take_stats(),
                },
                empty_page(),
            )),
        }
    }

    /// The chain's height, with the timing of the request it took.
    #[napi]
    pub async fn get_height(&self) -> napi::Result<(i64, Vec<RequestStat>)> {
        let result = self.inner.get_height().await;
        let request_stats = self.inner.take_stats();
        // A poll that failed still cost a request; carry its timing out with
        // the error so the source's metrics count it.
        let height = result.map_err(|err| {
            crate::request_stats::error_with_request_stats(
                napi::Error::from_reason(err.to_string()),
                &request_stats,
            )
        })?;
        let height: i64 = height
            .try_into()
            .context("block height exceeds i64::MAX")
            .map_err(map_err)?;
        Ok((height, request_stats))
    }

    /// Reads one page: decides the actual `toBlock` from this partition's
    /// AIMD-suggested interval, fans out one `eth_getLogs` per selection, then
    /// fills the page's blocks and transactions for the fields the matched
    /// items selected. On success, grows the partition's interval when the full
    /// suggested range was applied. Everything a caller is expected to handle
    /// — a narrower range to retry, a backoff, a selection the provider cannot
    /// serve — comes back as a value; the page returned alongside a non-"ok"
    /// result is empty.
    #[napi]
    pub async fn get_next_page(
        &self,
        params: NextPageParams,
        address_set: &AddressSet,
        known: &ChainBuffer,
    ) -> napi::Result<(NextPageResult, Page)> {
        if params.from_block < 0 || params.to_block_ceiling < 0 {
            return Err(map_err(anyhow::anyhow!(
                "block bounds must be non-negative, got from_block={}, to_block_ceiling={}",
                params.from_block,
                params.to_block_ceiling,
            )));
        }
        let from_block = params.from_block as u64;
        let to_block_ceiling = params.to_block_ceiling as u64;
        if to_block_ceiling < from_block {
            return Err(map_err(anyhow::anyhow!(
                "to_block_ceiling ({to_block_ceiling}) must be >= from_block ({from_block})",
            )));
        }

        let (suggested_interval, source_max) = self
            .intervals
            .suggested_interval(&params.partition_id, &self.sync_config);
        let interval_end = (from_block + suggested_interval - 1).min(to_block_ceiling);
        let block_selection = self
            .chain
            .schedule
            .select(
                &params.on_block_registration_indexes,
                from_block,
                Some(interval_end),
            )
            .map_err(map_err)?;
        let transaction_read = TransactionRead::new(
            self.chain
                .transactions
                .select(&params.on_transaction_registration_indexes)
                .map_err(map_err)?,
        );
        // A page selecting only blocks, where no handler runs, reads nothing:
        // over a final range it has no reorg observation to make either, so it
        // answers without a request up to the next block a handler runs on.
        if params.on_event_registration_indexes.is_empty()
            && block_selection.is_empty()
            && transaction_read.is_none()
        {
            let next_handler_block = self
                .chain
                .schedule
                .select(
                    &params.on_block_registration_indexes,
                    from_block,
                    Some(to_block_ceiling),
                )
                .map_err(map_err)?
                .first_from(from_block);
            let claimed_to = next_handler_block.map_or(to_block_ceiling, |block| block - 1);
            if params
                .reorgable_from
                .is_none_or(|reorgable_from| (claimed_to as i64) < reorgable_from)
            {
                return Ok((
                    NextPageResult::new(PageOutcome::Ok, claimed_to, self.inner.take_stats()),
                    empty_page(),
                ));
            }
        }
        let to_block =
            block_selection.range_end(from_block, interval_end, MAX_HANDLER_BLOCKS_PER_PAGE);
        let to_block = match transaction_read {
            Some(_) => to_block.min(from_block + MAX_HANDLER_BLOCKS_PER_PAGE as u64 - 1),
            None => to_block,
        };
        // A block or transaction handler can select fields no event
        // registration does, so a page reading blocks for one reads them for
        // its fields too.
        let handler_block_mask = block_selection.mask()
            | transaction_read
                .as_ref()
                .map_or(0, |transactions| transactions.block_mask);
        let block_read = (!block_selection.is_empty() || transaction_read.is_some())
            .then(|| BlockRead::for_chain(self.block_read.covering | handler_block_mask));

        let client_filtered = crate::client_filtered_contracts::ClientFilteredContracts::from_vec(
            params.client_filtered_contracts.unwrap_or_default(),
        );
        let built = self
            .evm
            .selection
            .build(
                &params.on_event_registration_indexes,
                address_set,
                &client_filtered,
            )
            .map_err(map_err)?;

        let query = PageQuery {
            partition_id: &params.partition_id,
            from_block,
            to_block,
            reorgable_from: params
                .reorgable_from
                .map(|reorgable_from| reorgable_from.max(0) as u64),
            known_height: params.known_height.max(0) as u64,
            retry: params.retry,
            selections: &built.log_selections,
            address_set,
            block_selection: &block_selection,
            transactions: transaction_read.as_ref(),
            block_read: block_read.as_ref().unwrap_or(&self.block_read),
            known,
        };
        let outcome = self.read_page(&query).await;
        let request_stats = self.inner.take_stats();

        // Only a page that was read has rows; every other outcome returns an
        // empty one, so the match decides the result and the page follows.
        let (result, page) = match outcome {
            Ok(page) => {
                let executed_interval = to_block - from_block + 1;
                // Grow this partition's interval only when the full suggested range
                // was actually applied (not clamped by a hard toBlock ceiling). The
                // clamp to `source_max` also stops growth once a structural cap
                // tightened it.
                if executed_interval >= suggested_interval {
                    self.intervals.grow(
                        &params.partition_id,
                        executed_interval,
                        &self.sync_config,
                        source_max,
                    );
                }
                (
                    NextPageResult::new(PageOutcome::Ok, to_block, request_stats),
                    Some(page),
                )
            }
            Err(PageError::Logs(err)) => {
                let provider_message = match &err {
                    RpcError::JsonRpc { message, .. } => Some(message.clone()),
                    _ => None,
                };
                let message = provider_message.clone().unwrap_or_else(|| err.to_string());
                (
                    self.retry_result(&query, provider_message.as_deref(), message, request_stats),
                    None,
                )
            }
            Err(PageError::Enrich(EnrichError::FieldSelection {
                block_number,
                error,
            })) => (
                NextPageResult {
                    message: Some(format!("{error:#}")),
                    block_number: Some(block_number as i64),
                    ..NextPageResult::new(PageOutcome::FieldSelection, to_block, request_stats)
                },
                None,
            ),
            Err(PageError::Enrich(EnrichError::BehindHead { block_number, .. })) => (
                NextPageResult {
                    block_number: Some(block_number as i64),
                    ..NextPageResult::new(PageOutcome::BehindHead, to_block, request_stats)
                },
                None,
            ),
            // The answer was unusable but the next one may not be. The symptom
            // is its own explanation, so it is the whole of what the retry logs.
            Err(PageError::Enrich(EnrichError::Transient(message))) => (
                NextPageResult::backoff(
                    message,
                    transient_backoff_millis(params.retry),
                    to_block,
                    request_stats,
                ),
                None,
            ),
            // A block or transaction read failed. The range is fine — the logs
            // came back — so the interval is left alone and the page waits out
            // the configured backoff, like a provider erroring on any request.
            Err(PageError::Enrich(EnrichError::Rpc(err))) => (
                NextPageResult {
                    provider_message: Some(err.to_string()),
                    ..NextPageResult::backoff(
                        "Failed reading the blocks, transactions or head block re-checks \
                         behind the range's logs. Will retry the block range."
                            .to_string(),
                        self.sync_config.backoff_millis as i64,
                        to_block,
                        request_stats,
                    )
                },
                None,
            ),
        };

        Ok((result, page.map_or_else(empty_page, Page::from_data)))
    }

    /// Reads the logs, with the headers of the head blocks they are checked
    /// against, then everything the matched items need to be materialised.
    async fn read_page(&self, query: &PageQuery<'_>) -> Result<PageData, PageError> {
        let checked_blocks = head_checks::blocks_to_check(
            query.from_block,
            query.to_block,
            query.reorgable_from,
            (!query.selections.is_empty()).then_some(query.known_height),
        );
        // A transaction page reads every block in full, which serves the
        // checked blocks' headers too, and observes each block's hash.
        let read_blocks: Vec<u64> = match query.transactions {
            Some(_) => (query.from_block..=query.to_block).collect(),
            None => checked_blocks.clone(),
        };
        // Both are awaited before either is judged: a failed range is what
        // decides the retry, so it wins over a header that failed beside it.
        let (logs, headers) = futures_util::future::join(
            self.fetch_selection_logs(query),
            enrich::fetch_block_responses(
                &self.inner,
                &self.fetches,
                &read_blocks,
                query.transactions.is_some(),
            ),
        )
        .await;
        let mut logs = logs.map_err(PageError::Logs)?;
        let headers = headers?;
        self.recheck_head_blocks(query, &checked_blocks, &headers, &mut logs)
            .await?;
        let matched = Self::match_logs(logs.into_iter().flatten().collect(), self.evm.clone())
            .await
            .map_err(PageError::Logs)?;

        let mut page = PageData::new(Ecosystem::Evm);
        let mut refs = PageRefs::default();
        let mut rows = page.events.builder();
        let mut registering_blocks = Vec::new();
        // A log can satisfy more than one selection, so the same log can come
        // back twice; it is stored once. Each copy's hashes are still recorded:
        // the two `eth_getLogs` calls ran concurrently and can straddle a fork,
        // and the disagreement between their block hashes is what catches it.
        let mut seen: HashSet<(u64, u64)> = HashSet::new();
        for log in matched {
            let mut fields = SelectedFields::default();
            for registration in &log.registrations {
                // A registration the client was not constructed with cannot
                // be matched, so this is a missing entry rather than an empty
                // selection.
                let selected = self
                    .registration_fields
                    .get(&(*registration as i64))
                    .ok_or_else(|| EnrichError::FieldSelection {
                        block_number: log.block_number,
                        error: anyhow::anyhow!(
                            "no field selection for registration {registration}"
                        ),
                    })?;
                fields.block_mask |= selected.block_mask;
                fields.tx_mask |= selected.tx_mask;
            }
            refs.add(
                log.block_number,
                log.transaction_index,
                &log.block_hash,
                &log.transaction_hash,
                fields,
            );
            if !seen.insert((log.block_number, log.log_index)) {
                continue;
            }
            if log.registers {
                registering_blocks.push(log.block_number);
            }
            if log.log_index > crate::chain_buffer::table::MAX_POSITION {
                return Err(PageError::Enrich(EnrichError::Transient(format!(
                    "the RPC reported log index {} in block {}, past what the buffer keys hold",
                    log.log_index, log.block_number
                ))));
            }
            rows.push_row(make_key(log.block_number, log.log_index), 0, 0);
            rows.set_u64(log_column::TRANSACTION_INDEX, log.transaction_index as u64);
            rows.set_bytes(log_column::ADDRESS, &log.address);
            for (position, topic) in log.topics.iter().enumerate() {
                rows.set_bytes(log_column::TOPIC0 + position, topic);
            }
            rows.set_bytes(log_column::DATA, &log.data);
        }
        page.add_events(rows.finish());
        page.add_registering_blocks(registering_blocks);

        // The page reads every block a handler runs on, so none can be missing.
        let mask = query.block_selection.mask();
        for block in query
            .block_selection
            .blocks_run_on(query.from_block..query.to_block + 1)
        {
            refs.add_block(block, mask);
        }
        if let Some(read) = query.transactions {
            for block in
                transactions::read(&self.inner, &self.fetches, read, &headers, &mut page).await?
            {
                refs.add_block(block, read.block_mask);
            }
        }

        enrich::page(
            &self.inner,
            &self.fetches,
            EnrichRequest {
                checked_blocks: &read_blocks,
                prefetched_blocks: &headers,
                refs,
                known: query.known,
                block_read: query.block_read,
                chain_tx_mask: self.chain_tx_mask,
            },
            &mut page,
        )
        .await?;
        Ok(page)
    }

    /// Builds the retry decision for a page that could not be read, updating
    /// the AIMD state as a side effect.
    fn retry_result(
        &self,
        query: &PageQuery<'_>,
        provider_message: Option<&str>,
        logged_message: String,
        request_stats: Vec<RequestStat>,
    ) -> NextPageResult {
        let PageQuery {
            partition_id,
            from_block,
            to_block,
            ..
        } = *query;
        let executed_interval = to_block - from_block + 1;
        let shrunk_interval =
            interval::shrink(executed_interval, self.sync_config.backoff_multiplicative);

        let result = match provider_message.and_then(suggested_block_interval_from_message) {
            // "limited to N blocks" — a structural cap on the whole source; only tighten.
            Some((suggested, true)) => {
                let capped = self
                    .intervals
                    .tighten_source_max(self.sync_config.interval_ceiling, suggested);
                NextPageResult::suggested_to_block(from_block + capped - 1, to_block, request_stats)
            }
            // A one-off suggested range ("retry with the range X-Y") — apply to this partition.
            Some((suggested, false)) => {
                self.intervals.set_partition(partition_id, suggested);
                NextPageResult::suggested_to_block(
                    from_block + suggested - 1,
                    to_block,
                    request_stats,
                )
            }
            // Density cap with no suggested number (too many logs / response too large):
            // shrink THIS partition and retry immediately (no wait); acceleration
            // re-adapts on the next successful query. The interval>1 guard avoids a
            // no-progress tight loop on a single over-cap block.
            None if executed_interval > 1
                && provider_message.is_some_and(is_response_too_large_message) =>
            {
                self.intervals.set_partition(partition_id, shrunk_interval);
                NextPageResult::suggested_to_block(
                    from_block + shrunk_interval - 1,
                    to_block,
                    request_stats,
                )
            }
            // Anything else, including a timeout: the range may simply be too
            // dense for the provider, so shrink this partition and back off.
            None => {
                self.intervals.set_partition(partition_id, shrunk_interval);
                NextPageResult::backoff(
                    "Failed getting data for the block range. Will try smaller block range \
                     for the next attempt."
                        .to_string(),
                    self.sync_config.backoff_millis as i64,
                    to_block,
                    request_stats,
                )
            }
        };

        NextPageResult {
            provider_message: Some(logged_message),
            ..result
        }
    }

    /// Reads `selection` over `blocks`, falling back to its addresses where
    /// one address-free block is too large for the provider.
    async fn request_logs(
        &self,
        query: &PageQuery<'_>,
        blocks: logs::LogBlocks<'_>,
        selection: &BuiltLogSelection,
    ) -> Result<Vec<RawLog>, RpcError> {
        logs::request_selection_logs(&self.inner, &self.logger, blocks, selection, |origin| {
            self.evm
                .selection
                .build_by_address(origin, query.address_set, |contract_names| {
                    query
                        .address_set
                        .contract_chunks(contract_names, self.max_addresses_per_request)
                })
        })
        .await
    }

    /// Reads every selection concurrently, each selection's logs kept apart in
    /// the order of `query.selections`. Every selection is awaited even once
    /// one has failed, so each request is made and billed; the first failure
    /// then decides the page.
    async fn fetch_selection_logs(
        &self,
        query: &PageQuery<'_>,
    ) -> Result<Vec<Vec<RawLog>>, RpcError> {
        let blocks = logs::LogBlocks::Range {
            from_block: query.from_block,
            to_block: query.to_block,
        };
        futures_util::future::join_all(
            query
                .selections
                .iter()
                .map(|selection| self.request_logs(query, blocks, selection)),
        )
        .await
        .into_iter()
        .collect()
    }

    /// Asks again, by hash, for every checked block a selection's answer held
    /// none of its logs for while the block's header can't rule them out, and
    /// adds what comes back to that selection's logs. A node that doesn't have
    /// the block yet must refuse a hash it doesn't know, so a refusal is the
    /// node being behind it, which the source manager retries and fails over.
    async fn recheck_head_blocks(
        &self,
        query: &PageQuery<'_>,
        checked_blocks: &[u64],
        headers: &HashMap<u64, Arc<serde_json::Value>>,
        logs: &mut [Vec<RawLog>],
    ) -> Result<(), EnrichError> {
        if checked_blocks.is_empty() {
            return Ok(());
        }
        let checked_headers: HashMap<u64, head_checks::CheckedHeader> = headers
            .iter()
            .map(|(&block, header)| (block, head_checks::CheckedHeader::read(header)))
            .collect();
        let rechecks: Vec<(usize, u64, head_checks::RecheckReason)> = query
            .selections
            .iter()
            .zip(logs.iter())
            .enumerate()
            .flat_map(|(index, (selection, selection_logs))| {
                let answered: HashSet<u64> = selection_logs
                    .iter()
                    .filter_map(|log| parse_hex_u64(&log.block_number).ok())
                    .collect();
                head_checks::blocks_to_recheck(
                    checked_blocks,
                    &answered,
                    &checked_headers,
                    selection,
                )
                .into_iter()
                .map(move |(block, reason)| (index, block, reason))
            })
            .collect();

        let results =
            futures_util::future::join_all(rechecks.iter().map(|&(index, block, reason)| {
                let hash = checked_headers
                    .get(&block)
                    .and_then(|header| header.hash.as_deref());
                async move {
                    let hash = hash.ok_or_else(|| {
                        EnrichError::Transient(format!(
                            "The RPC returned the header of block {block} without its hash."
                        ))
                    })?;
                    let found = self
                        .recheck_block(query, &query.selections[index], block, hash)
                        .await?;
                    self.logger.log(
                        Level::TRACE,
                        "Asked the RPC again for a head block its range answer held none of the selection's logs for.",
                        &serde_json::json!({
                            "blockNumber": block,
                            "reason": reason.as_str(),
                            "logs": found.len(),
                        }),
                    );
                    Ok((index, found))
                }
            }))
            .await;
        for (index, found) in enrich::collect_worst(results)? {
            logs[index].extend(found);
        }
        Ok(())
    }

    /// Asks for one checked block again by its hash. A provider that refuses
    /// reads by hash altogether is asked by number instead: that still catches
    /// a range that left the block out, but not a node lagging on every
    /// answer, so it is said once.
    ///
    /// Some providers refuse a hash they don't know yet with the same
    /// "unsupported" error they would give a request they never serve, so that
    /// refusal is only taken at its word from a source that has never answered
    /// a read by hash, and only once the page has been retried for longer than
    /// a node takes to catch up.
    async fn recheck_block(
        &self,
        query: &PageQuery<'_>,
        selection: &BuiltLogSelection,
        block: u64,
        hash: &str,
    ) -> Result<Vec<RawLog>, EnrichError> {
        let by_hash = logs::LogBlocks::Hash {
            block_number: block,
            hash,
        };
        let refusal = match self.request_logs(query, by_hash, selection).await {
            Ok(found) => {
                self.answered_block_hash_read.store(true, Ordering::Relaxed);
                return Ok(found);
            }
            Err(RpcError::JsonRpc { code, message })
                if is_unsupported_request(code, &message)
                    && !self.answered_block_hash_read.load(Ordering::Relaxed)
                    && query.retry >= RETRIES_BEFORE_RECHECKING_BY_NUMBER =>
            {
                message
            }
            // A throttled read says nothing about the block, and retrying it
            // at the pace a node behind the head gets would only throttle more.
            Err(RpcError::JsonRpc { code, message }) if is_rate_limited_message(&message) => {
                return Err(EnrichError::Rpc(Arc::new(RpcError::JsonRpc {
                    code,
                    message,
                })))
            }
            Err(RpcError::JsonRpc { .. } | RpcError::MalformedResponse(_)) => {
                return Err(EnrichError::BehindHead {
                    block_number: block,
                })
            }
            Err(error) => return Err(EnrichError::Rpc(Arc::new(error))),
        };
        if !self.warned_block_hash_refusal.swap(true, Ordering::Relaxed) {
            self.logger.log(
                Level::WARN,
                "The RPC provider refused to read logs by block hash, so a block near the head it answered with none of our logs is asked again by number instead. That still catches a range that left a block out, but a node lagging on every answer can drop events unnoticed. A provider that serves eth_getLogs by blockHash (EIP-234) gets the full check.",
                &serde_json::json!({ "providerMessage": refusal }),
            );
        }
        self.request_logs(
            query,
            logs::LogBlocks::RecheckByNumber {
                block_number: block,
            },
            selection,
        )
        .await
        .map_err(|error| EnrichError::Rpc(Arc::new(error)))
    }

    async fn match_logs(
        raw_logs: Vec<RawLog>,
        evm: Arc<EvmRegistrations>,
    ) -> Result<Vec<MatchedLog>, RpcError> {
        // Many logs, each a few compares; keep them off the libuv thread.
        tokio::task::spawn_blocking(move || {
            let matcher = &evm.matcher;
            let store = matcher.read_store();
            let mut matched = Vec::new();
            for raw in raw_logs {
                let mut log = raw.to_matched()?;
                let (mut registrations, mut registers) = (Vec::new(), false);
                matcher.for_each_match(&log.view(), &store, |registration| {
                    registrations.push(registration.index);
                    registers |= matcher.contract_registers.has(registration.index);
                });
                log.registrations = registrations;
                log.registers = registers;
                if !log.registrations.is_empty() {
                    matched.push(log);
                }
            }
            Ok(matched)
        })
        .await
        .map_err(|e| {
            RpcError::Other(anyhow::anyhow!(
                "eth_getLogs match worker join failure: {e}"
            ))
        })?
        .map_err(RpcError::Other)
    }
}

fn empty_page() -> Page {
    Page::from_data(PageData::new(Ecosystem::Evm))
}

fn map_err(e: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{e:#}"))
}
