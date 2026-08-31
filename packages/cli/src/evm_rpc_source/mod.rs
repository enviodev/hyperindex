use anyhow::Context;
use napi_derive::napi;
use serde::Deserialize;
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};

mod classify;
mod client;
mod enrich;
mod fields;
mod inflight;
mod interval;
mod responses;

use crate::address_store::{AddressSet, AddressStore, Emitter, SetCache};
use crate::block_store::BlockStore;
use crate::evm_hypersync_source::decode::{Decoder, SelectionDecoder};
use crate::evm_hypersync_source::selection::{BuiltLogSelection, SelectionBuilder};
use crate::evm_hypersync_source::types::{
    encode_address, Log as DecoderLog, OnEventRegistrationInput, ParamValue,
};
use crate::evm_hypersync_source::EventItem;
use crate::request_stats::RequestStat;
use crate::transaction_store::TransactionStore;
use classify::{is_response_too_large_message, suggested_block_interval_from_message};
use client::{parse_hex_u64, JsonRpcClient, RpcError};
use enrich::{EnrichError, EnrichRequest, FetchCache, ItemFields, PageRefs, Stats};
use hypersync_client::format::{self, Hex};
use interval::{IntervalState, SyncConfig};

#[napi(object)]
pub struct EvmRpcClientConfig {
    pub url: String,
    pub http_req_timeout_millis: Option<i64>,
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

/// A routed log, alongside the two hashes the page needs from it: the block
/// hash is a reorg observation, and the transaction hash is what the enrichment
/// requests are keyed by. Neither crosses the napi boundary — the item the JS
/// side receives is the same shape the HyperSync path returns.
struct DecodedItem {
    item: EventItem,
    block_hash: format::Hash,
    transaction_hash: format::Hash,
}

impl RawLog {
    /// `address` is normalized (lowercase or checksummed per the client config)
    /// so it matches the JS-side address type.
    fn borrowed_event_item(
        &self,
        src_address: String,
        on_event_registration_index: i64,
        params: ParamValue,
    ) -> anyhow::Result<EventItem> {
        let to_i64 = |hex: &str| -> anyhow::Result<i64> {
            parse_hex_u64(hex)?
                .try_into()
                .context("hex quantity exceeds i64::MAX")
        };
        Ok(EventItem {
            block_number: to_i64(&self.block_number).context("log.blockNumber")?,
            transaction_index: to_i64(&self.transaction_index).context("log.transactionIndex")?,
            log_index: to_i64(&self.log_index).context("log.logIndex")?,
            src_address,
            on_event_registration_index,
            params,
        })
    }

    /// The emitter's 20 raw bytes — the address store's key — alongside the
    /// normalized string the JS payload carries.
    fn address_bytes_and_string(
        &self,
        should_checksum: bool,
    ) -> anyhow::Result<([u8; 20], String)> {
        let address = hypersync_client::format::Address::decode_hex(&self.address)
            .context("decode log.address hex")?;
        Ok((**address, encode_address(&address, should_checksum)))
    }

    fn to_decoder_log(&self) -> DecoderLog {
        DecoderLog {
            data: Some(self.data.clone()),
            topics: self.topics.iter().map(|t| Some(t.clone())).collect(),
            ..Default::default()
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
    /// The partition's registration selection, by chain-scoped id. Log
    /// selections and the routing index are derived internally from the
    /// registrations passed at construction.
    pub registration_indexes: Vec<i64>,
    /// Contract names to fetch address-free even though their registrations
    /// depend on addresses (client-side filtering). Absent or empty
    /// means every address-dependent contract is filtered server-side.
    pub client_filtered_contracts: Option<Vec<String>>,
    /// How many times this query has already been retried, which sets how long
    /// a transient miss waits before the next attempt.
    pub retry: i64,
}

/// What to do about a page that could not be read. Mirrors the ReScript
/// `Source.getItemsRetry` variant.
#[napi(object)]
pub struct RetryDecision {
    /// "suggestedToBlock" — retry the same `fromBlock` up to a narrower
    /// `toBlock`; or "backoff" — wait `backoffMillis` and retry unchanged.
    pub tag: String,
    pub to_block: Option<i64>,
    pub message: Option<String>,
    pub backoff_millis: Option<i64>,
}

/// The outcome of a page read. Every outcome an caller is expected to handle is
/// a value rather than an exception, so nothing has to be recovered by parsing
/// an error message; a thrown error from `get_next_page` is a genuine bug.
#[napi(object)]
pub struct NextPageResult {
    /// "ok" — `items` is the page; "retry" — `retry` says how to try again;
    /// "fieldSelection" — the provider cannot serve the selected fields, which
    /// retrying will not fix.
    pub kind: String,
    /// The requests this call issued. A call that joined another's in-flight
    /// request contributes nothing, so per-source totals stay exact.
    pub request_stats: Vec<RequestStat>,
    /// The block this attempt targeted: the page's own `toBlock` when it
    /// succeeded, the block it got as far as otherwise.
    pub to_block: i64,
    pub items: Vec<EventItem>,
    /// Set on "retry" and "fieldSelection".
    pub message: Option<String>,
    /// The provider's own message, when it gave one. Diagnostics only.
    pub error_message: Option<String>,
    pub retry: Option<RetryDecision>,
}

impl NextPageResult {
    /// The shape every outcome shares: no items, nothing to say, nothing to
    /// retry. Each arm fills in what its own kind means.
    fn new(kind: &str, to_block: u64, request_stats: Vec<RequestStat>) -> Self {
        NextPageResult {
            kind: kind.to_string(),
            request_stats,
            to_block: to_block as i64,
            items: Vec::new(),
            message: None,
            error_message: None,
            retry: None,
        }
    }
}

impl RetryDecision {
    /// Wait, then ask for the same range again.
    fn backoff(message: String, backoff_millis: i64) -> Self {
        RetryDecision {
            tag: "backoff".to_string(),
            to_block: None,
            message: Some(message),
            backoff_millis: Some(backoff_millis),
        }
    }

    /// Ask again for a narrower range, with no wait.
    fn suggested_to_block(to_block: u64) -> Self {
        RetryDecision {
            tag: "suggestedToBlock".to_string(),
            to_block: Some(to_block as i64),
            message: None,
            backoff_millis: None,
        }
    }
}

/// Outcome of a rollback-depth block-hash read. `message` is set when the read
/// failed, in which case the page returned alongside it is empty.
#[napi(object)]
pub struct BlockHashResult {
    pub message: Option<String>,
    pub request_stats: Vec<RequestStat>,
}

#[napi]
pub struct EvmRpcClient {
    inner: Arc<JsonRpcClient>,
    decoder: Decoder,
    selection_builder: SelectionBuilder,
    sync_config: SyncConfig,
    intervals: IntervalState,
    /// Coalesces block, transaction and receipt reads that overlap in time,
    /// including across the partitions of one chain, which scan the same blocks
    /// at the head.
    fetches: FetchCache,
    /// The fields each registration selected, as store masks. An item's block
    /// and transaction are fetched for the union of the masks of the items that
    /// reference them, so an event selecting nothing costs no request.
    registration_fields: HashMap<i64, ItemFields>,
    should_checksum: bool,
}

/// Everything one page read works from: the range, the queries to run over it,
/// and the stores whose contents decide what still has to be fetched.
struct PageQuery<'a> {
    from_block: u64,
    to_block: u64,
    selections: &'a [BuiltLogSelection],
    set_cache: &'a Arc<SetCache>,
    decoder: &'a Arc<SelectionDecoder>,
    known_blocks: &'a BlockStore,
    known_transactions: &'a TransactionStore,
    should_checksum: bool,
}

/// The attempt a retry decision is about.
struct Attempt<'a> {
    partition_id: &'a str,
    from_block: u64,
    to_block: u64,
    /// The structural cap on this source's range, which a provider's own
    /// "limited to N blocks" may only tighten.
    source_max: u64,
}

/// Why a page could not be read.
enum PageError {
    Rpc(RpcError),
    NotFound(String),
    FieldSelection(anyhow::Error),
}

impl From<EnrichError> for PageError {
    fn from(err: EnrichError) -> Self {
        match err {
            EnrichError::Rpc(err) => PageError::Rpc(err),
            EnrichError::NotFound(message) => PageError::NotFound(message),
            EnrichError::FieldSelection(err) => PageError::FieldSelection(err),
        }
    }
}

fn describe_rpc_error(err: &RpcError) -> String {
    match err {
        RpcError::JsonRpc { code, message } => format!("JSON-RPC error {code}: {message}"),
        RpcError::Other(err) => format!("{err:#}"),
    }
}

fn describe(err: &EnrichError) -> String {
    match err {
        EnrichError::NotFound(message) => message.clone(),
        EnrichError::FieldSelection(err) => format!("{err:#}"),
        EnrichError::Rpc(err) => describe_rpc_error(err),
    }
}

#[napi]
impl EvmRpcClient {
    #[napi(factory)]
    pub fn new(
        cfg: EvmRpcClientConfig,
        event_registrations: Vec<OnEventRegistrationInput>,
        checksum_addresses: bool,
        address_store: &AddressStore,
    ) -> napi::Result<EvmRpcClient> {
        let http_req_timeout_millis = cfg
            .http_req_timeout_millis
            .filter(|v| *v > 0)
            .map_or(JsonRpcClient::default_http_req_timeout_millis(), |v| {
                v as u64
            });
        let inner =
            JsonRpcClient::new(cfg.url, http_req_timeout_millis, cfg.headers).map_err(map_err)?;
        let decoder =
            Decoder::from_registrations(&event_registrations, checksum_addresses, address_store)
                .context("build decoder")
                .map_err(map_err)?;
        let selection_builder = SelectionBuilder::from_registrations(&event_registrations)
            .context("build selection builder")
            .map_err(map_err)?;
        // 0.0 would collapse every shrink to the floor of 1 block and 1.0 would
        // never shrink at all, so both ends are excluded (this also rejects NaN).
        if !(cfg.backoff_multiplicative > 0.0 && cfg.backoff_multiplicative < 1.0) {
            return Err(map_err(anyhow::anyhow!(
                "backoffMultiplicative must be in (0.0, 1.0), got {}",
                cfg.backoff_multiplicative,
            )));
        }
        // A zero interval would make `fromBlock + interval - 1` underflow.
        let positive_u64 = |value: i64, name: &str| {
            u64::try_from(value)
                .ok()
                .filter(|v| *v > 0)
                .ok_or_else(|| map_err(anyhow::anyhow!("{name} must be positive, got {value}")))
        };
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
            query_timeout_millis: u64::try_from(cfg.query_timeout_millis)
                .context("queryTimeoutMillis must be non-negative")
                .map_err(map_err)?,
        };
        let registration_fields = event_registrations
            .iter()
            .map(|reg| {
                (
                    reg.index,
                    ItemFields {
                        block_mask: fields::block_mask(&reg.block_fields),
                        tx_mask: fields::tx_mask(&reg.transaction_fields),
                    },
                )
            })
            .collect();
        Ok(EvmRpcClient {
            inner: Arc::new(inner),
            decoder,
            selection_builder,
            sync_config,
            intervals: IntervalState::new(),
            fetches: FetchCache::default(),
            registration_fields,
            should_checksum: checksum_addresses,
        })
    }

    /// Forget every in-flight block, transaction and receipt read. After a
    /// reorg an in-flight response may describe the orphaned fork, so a read
    /// issued afterwards must observe the chain again rather than join one.
    /// The stores are rolled back separately, which is what retires the data
    /// already merged from that fork.
    #[napi]
    pub fn on_reorg(&self) {
        self.fetches.clear();
    }

    /// Re-read the given blocks and return them as a page of hash-only
    /// observations, for the rollback-depth search. Never served from the
    /// store: the whole question being asked is whether the stored hashes still
    /// match the chain.
    #[napi]
    pub async fn get_block_hashes(
        &self,
        block_numbers: Vec<i64>,
    ) -> napi::Result<(BlockHashResult, BlockStore)> {
        let should_checksum = self.should_checksum;
        let stats = Stats::default();
        let numbers: Vec<u64> = block_numbers
            .into_iter()
            .map(u64::try_from)
            .collect::<Result<_, _>>()
            .context("block number is negative")
            .map_err(map_err)?;
        match enrich::fetch_block_hashes(
            &self.inner,
            &self.fetches,
            &stats,
            &numbers,
            should_checksum,
        )
        .await
        {
            Ok(blocks) => Ok((
                BlockHashResult {
                    message: None,
                    request_stats: stats.take(),
                },
                blocks,
            )),
            // The page is empty on failure and the caller reads `message`
            // instead; a store is cheap enough not to be worth an optional.
            Err(err) => Ok((
                BlockHashResult {
                    message: Some(describe(&err)),
                    request_stats: stats.take(),
                },
                BlockStore::new_evm(should_checksum),
            )),
        }
    }

    #[napi]
    pub async fn get_height(&self) -> napi::Result<i64> {
        let started = Instant::now();
        let height = self.inner.get_height().await.map_err(|err| {
            // A poll that failed still cost a request; carry its timing out
            // with the error so the source's metrics count it.
            crate::request_stats::error_with_request_stats(
                rpc_error_to_napi(err),
                &[RequestStat {
                    method: "eth_blockNumber".to_string(),
                    seconds: started.elapsed().as_secs_f64(),
                }],
            )
        })?;
        height
            .try_into()
            .context("block height exceeds i64::MAX")
            .map_err(map_err)
    }

    /// Reads one page: decides the actual `toBlock` from this partition's
    /// AIMD-suggested interval, fans out one `eth_getLogs` per selection, then
    /// fills the page's block and transaction stores for the fields the routed
    /// items selected. On success, grows the partition's interval when the full
    /// suggested range was applied. Everything a caller is expected to handle
    /// — a narrower range to retry, a backoff, a selection the provider cannot
    /// serve — comes back as a value; the stores returned alongside a non-"ok"
    /// result are empty.
    #[napi]
    pub async fn get_next_page(
        &self,
        params: NextPageParams,
        address_set: &AddressSet,
        known_blocks: &BlockStore,
        known_transactions: &TransactionStore,
    ) -> napi::Result<(NextPageResult, BlockStore, TransactionStore)> {
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
        let should_checksum = self.should_checksum;

        let (suggested_interval, source_max) = self
            .intervals
            .suggested_interval(&params.partition_id, &self.sync_config);
        // Defensively ensure we never query a target block below fromBlock.
        let to_block = (from_block + suggested_interval - 1)
            .min(to_block_ceiling)
            .max(from_block);

        let client_filtered = crate::client_filtered_contracts::ClientFilteredContracts::from_vec(
            params.client_filtered_contracts.unwrap_or_default(),
        );
        let built = self
            .selection_builder
            .build(&params.registration_indexes, address_set, &client_filtered)
            .map_err(map_err)?;
        let set_cache = address_set.cache().clone();
        let selection_decoder = Arc::new(
            self.decoder
                .selection(
                    &params.registration_indexes,
                    &client_filtered,
                    set_cache.clone(),
                )
                .map_err(map_err)?,
        );

        let query = PageQuery {
            from_block,
            to_block,
            selections: &built.log_selections,
            set_cache: &set_cache,
            decoder: &selection_decoder,
            known_blocks,
            known_transactions,
            should_checksum,
        };
        let attempt = Attempt {
            partition_id: &params.partition_id,
            from_block,
            to_block,
            source_max,
        };
        let stats = Stats::default();
        let timeout = Duration::from_millis(self.sync_config.query_timeout_millis);
        let outcome = tokio::time::timeout(timeout, self.read_page(&query, &stats)).await;

        // Only a page that was read has stores; every other outcome returns
        // empty ones, so the match decides the result and the stores follow.
        let (result, page) = match outcome {
            Ok(Ok((items, page))) => {
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
                    NextPageResult {
                        items,
                        ..NextPageResult::new("ok", to_block, stats.take())
                    },
                    Some(page),
                )
            }
            // The provider answered, but not with the selected fields. Retrying
            // asks the same question of the same chain, so the caller is told to
            // stop rather than to wait.
            Ok(Err(PageError::FieldSelection(err))) => (
                NextPageResult {
                    message: Some(format!("{err:#}")),
                    ..NextPageResult::new("fieldSelection", to_block, stats.take())
                },
                None,
            ),
            // A row that should exist was not there. The range is fine, so the
            // interval is left alone and only the wait grows with the attempt.
            Ok(Err(PageError::NotFound(message))) => (
                NextPageResult {
                    message: Some(message.clone()),
                    error_message: Some(message.clone()),
                    retry: Some(RetryDecision::backoff(
                        // The reason the wait exists travels with it, so a
                        // retry is explained where it is acted on.
                        message,
                        params.retry.saturating_mul(500).max(100),
                    )),
                    ..NextPageResult::new("retry", to_block, stats.take())
                },
                None,
            ),
            Ok(Err(PageError::Rpc(err))) => {
                let provider_message = match &err {
                    RpcError::JsonRpc { message, .. } => Some(message.clone()),
                    RpcError::Other(_) => None,
                };
                let message = provider_message
                    .clone()
                    .unwrap_or_else(|| describe_rpc_error(&err));
                (
                    self.retry_result(&attempt, provider_message.as_deref(), message, stats.take()),
                    None,
                )
            }
            // Dropping the timed-out future cancels the in-flight requests.
            Err(_elapsed) => {
                let message = format!(
                    "Query took longer than {}ms",
                    self.sync_config.query_timeout_millis
                );
                (
                    self.retry_result(&attempt, Some(&message), message.clone(), stats.take()),
                    None,
                )
            }
        };

        let (blocks, transactions) = match page {
            Some(page) => (page.blocks, page.transactions),
            None => (
                BlockStore::new_evm(should_checksum),
                TransactionStore::new_evm(should_checksum),
            ),
        };
        Ok((result, blocks, transactions))
    }

    /// Reads the logs, then everything the routed items need to be materialised.
    async fn read_page(
        &self,
        query: &PageQuery<'_>,
        stats: &Stats,
    ) -> Result<(Vec<EventItem>, enrich::EnrichedPage), PageError> {
        let decoded = self
            .fetch_page(query, stats)
            .await
            .map_err(PageError::Rpc)?;

        let mut refs = PageRefs::default();
        let mut items = Vec::with_capacity(decoded.len());
        for entry in decoded {
            // A registration the client was not constructed with cannot be
            // routed to, so this is a missing entry rather than an empty
            // selection; treating it as "wants nothing" would silently drop the
            // event's fields.
            let fields = *self
                .registration_fields
                .get(&entry.item.on_event_registration_index)
                .ok_or_else(|| {
                    PageError::FieldSelection(anyhow::anyhow!(
                        "no field selection for registration {}",
                        entry.item.on_event_registration_index
                    ))
                })?;
            refs.add(
                entry.item.block_number as u64,
                entry.item.transaction_index as u32,
                &entry.block_hash,
                &entry.transaction_hash,
                fields,
            );
            items.push(entry.item);
        }

        let page = enrich::enrich(
            &self.inner,
            &self.fetches,
            stats,
            EnrichRequest {
                from_block: query.from_block,
                to_block: query.to_block,
                refs,
                known_blocks: query.known_blocks,
                known_transactions: query.known_transactions,
                should_checksum: query.should_checksum,
            },
        )
        .await?;
        Ok((items, page))
    }

    /// Builds the retry decision for a page that could not be read, updating
    /// the AIMD state as a side effect.
    fn retry_result(
        &self,
        attempt: &Attempt<'_>,
        provider_message: Option<&str>,
        error_message: String,
        request_stats: Vec<RequestStat>,
    ) -> NextPageResult {
        let Attempt {
            partition_id,
            from_block,
            to_block,
            source_max,
        } = *attempt;
        let executed_interval = to_block - from_block + 1;
        let shrunk_interval =
            interval::shrink(executed_interval, self.sync_config.backoff_multiplicative);

        let retry = match provider_message.and_then(suggested_block_interval_from_message) {
            // "limited to N blocks" — a structural cap on the whole source; only tighten.
            Some((suggested, true)) => {
                let capped = self.intervals.tighten_source_max(source_max, suggested);
                RetryDecision::suggested_to_block(from_block + capped - 1)
            }
            // A one-off suggested range ("retry with the range X-Y") — apply to this partition.
            Some((suggested, false)) => {
                self.intervals.set_partition(partition_id, suggested);
                RetryDecision::suggested_to_block(from_block + suggested - 1)
            }
            // Density cap with no suggested number (too many logs / response too large):
            // shrink THIS partition and retry immediately (no wait); acceleration
            // re-adapts on the next successful query. The interval>1 guard avoids a
            // no-progress tight loop on a single over-cap block.
            None if executed_interval > 1
                && provider_message.is_some_and(is_response_too_large_message) =>
            {
                self.intervals.set_partition(partition_id, shrunk_interval);
                RetryDecision::suggested_to_block(from_block + shrunk_interval - 1)
            }
            // Transient/unknown (including a timeout) — shrink this partition and back off.
            None => {
                self.intervals.set_partition(partition_id, shrunk_interval);
                RetryDecision::backoff(
                    "Failed getting data for the block range. Will try smaller block range \
                     for the next attempt."
                        .to_string(),
                    self.sync_config.backoff_millis as i64,
                )
            }
        };

        NextPageResult {
            message: retry.message.clone(),
            error_message: Some(error_message),
            retry: Some(retry),
            ..NextPageResult::new("retry", to_block, request_stats)
        }
    }

    /// Fans out one `eth_getLogs` per selection concurrently, deduping the
    /// merged results by `(blockNumber, logIndex, registrationIndex)` — a log
    /// can satisfy more than one selection (an event's `where` OR-groups, or
    /// several registrations sharing a signature) and routing fans one log out
    /// to several registrations, so only exact repeats are dropped. Waits for
    /// every selection to settle (unlike `Promise.all`'s fail-fast) so every
    /// request's timing is still captured for `requestStats` even when one of
    /// them errors.
    async fn fetch_page(
        &self,
        query: &PageQuery<'_>,
        stats: &Stats,
    ) -> Result<Vec<DecodedItem>, RpcError> {
        if query.selections.is_empty() {
            return Ok(Vec::new());
        }

        let results =
            futures_util::future::join_all(query.selections.iter().map(|selection| async {
                let started = Instant::now();
                let result = self
                    .fetch_logs_raw(
                        query.from_block as i64,
                        query.to_block as i64,
                        selection,
                        query.set_cache.clone(),
                        query.decoder.clone(),
                    )
                    .await;
                stats.record_log_query(started.elapsed().as_secs_f64());
                result
            }))
            .await;

        let mut items = Vec::new();
        let mut seen: HashSet<(i64, i64, i64)> = HashSet::new();
        let mut first_err = None;
        for result in results {
            match result {
                Ok(page_items) => {
                    for entry in page_items {
                        if seen.insert((
                            entry.item.block_number,
                            entry.item.log_index,
                            entry.item.on_event_registration_index,
                        )) {
                            items.push(entry);
                        }
                    }
                }
                Err(e) => {
                    if first_err.is_none() {
                        first_err = Some(e);
                    }
                }
            }
        }
        match first_err {
            Some(e) => Err(e),
            None => Ok(items),
        }
    }

    async fn fetch_logs_raw(
        &self,
        from_block: i64,
        to_block: i64,
        selection: &BuiltLogSelection,
        set_cache: Arc<SetCache>,
        decoder: Arc<SelectionDecoder>,
    ) -> Result<Vec<DecodedItem>, RpcError> {
        // eth_getLogs topic filters: `null` matches any value at a position;
        // trailing match-any positions are trimmed entirely.
        let mut topics: Vec<Option<&Vec<String>>> = selection
            .topics
            .iter()
            .map(|values| {
                if values.is_empty() {
                    None
                } else {
                    Some(values)
                }
            })
            .collect();
        while matches!(topics.last(), Some(None)) {
            topics.pop();
        }
        let mut filter = json!({
            "fromBlock": format!("0x{:x}", from_block),
            "toBlock": format!("0x{:x}", to_block),
            "topics": topics,
        });
        if !selection.addresses.is_empty() {
            filter["address"] = json!(selection.addresses);
        }

        let raw_logs: Vec<RawLog> = self.inner.request("eth_getLogs", json!([filter])).await?;

        // Decoding is CPU-bound ABI work; keep it off the libuv async thread.
        tokio::task::spawn_blocking(move || {
            let should_checksum = decoder.checksummed_addresses();
            let address_store = decoder.lock_store();
            let mut items = Vec::new();
            for raw in raw_logs {
                let (address_key, address) = raw.address_bytes_and_string(should_checksum)?;
                let block_number = parse_hex_u64(&raw.block_number)
                    .context("log.blockNumber")?
                    .try_into()
                    .context("log.blockNumber exceeds i64::MAX")?;
                let log_address = Emitter {
                    key: &address_key,
                    owners: set_cache.owners_of(&address_key),
                    block: block_number,
                };
                // Per-registration decode failures are dropped inside
                // `route_and_decode`; only structurally malformed logs error,
                // and those propagate like on the HyperSync path.
                let routed = decoder.route_and_decode_napi(
                    &raw.to_decoder_log(),
                    &log_address,
                    &address_store,
                )?;
                if routed.is_empty() {
                    continue;
                }
                let block_hash = format::Hash::decode_hex(&raw.block_hash)
                    .map_err(|e| anyhow::anyhow!("log.blockHash: {e}"))?;
                let transaction_hash = format::Hash::decode_hex(&raw.transaction_hash)
                    .map_err(|e| anyhow::anyhow!("log.transactionHash: {e}"))?;
                for routed in routed {
                    items.push(DecodedItem {
                        item: raw.borrowed_event_item(
                            address.clone(),
                            routed.index,
                            routed.params,
                        )?,
                        block_hash: block_hash.clone(),
                        transaction_hash: transaction_hash.clone(),
                    });
                }
            }
            Ok(items)
        })
        .await
        .map_err(|e| {
            RpcError::Other(anyhow::anyhow!(
                "eth_getLogs decode worker join failure: {e}"
            ))
        })?
        .map_err(RpcError::Other)
    }
}

/// A JSON-RPC failure as a plain message. The provider's code is part of the
/// text rather than a separate channel: nothing recovers from it
/// programmatically, and one readable message beats a payload every reader has
/// to decode first.
fn rpc_error_to_napi(e: RpcError) -> napi::Error {
    match e {
        RpcError::JsonRpc { code, message } => {
            napi::Error::from_reason(format!("JSON-RPC error {code}: {message}"))
        }
        RpcError::Other(e) => map_err(e),
    }
}

fn map_err(e: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{e:#}"))
}
