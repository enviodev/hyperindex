use anyhow::Context;
use napi_derive::napi;
use serde::Deserialize;
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

mod classify;
mod client;
mod interval;

use crate::evm_hypersync_source::decode::DecoderCore;
use crate::evm_hypersync_source::types::{EventParamsInput, Log as DecoderLog, ParamValue};
use crate::request_stats::RequestStat;
use classify::{is_response_too_large_message, suggested_block_interval_from_message};
use client::{parse_hex_u64, JsonRpcClient, RpcError};
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

/// A log returned from `eth_getLogs`, with hex quantities decoded to integers.
/// Field names cross the napi boundary as camelCase, matching the ReScript
/// `Rpc.GetLogs.log` record.
// Only the fields the ReScript side reads cross the boundary. `data` is consumed
// by the decoder on the Rust side (see `to_decoder_log`) and `removed` is unused,
// so neither is carried here.
#[napi(object)]
pub struct RpcLog {
    pub address: String,
    pub topics: Vec<String>,
    pub block_number: i64,
    pub transaction_hash: String,
    pub transaction_index: i64,
    pub block_hash: String,
    pub log_index: i64,
}

#[napi(object)]
pub struct RpcEventItem {
    pub log: RpcLog,
    /// Decoded params keyed by contract name, or `None` when no registered event
    /// signature matches the log's topic0/topic-count (or decoding failed).
    pub params: Option<ParamValue>,
}

/// Raw `eth_getLogs` entry as the provider serialises it: integer fields are
/// 0x-prefixed hex quantities that `RpcLog` later decodes.
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

impl RawLog {
    fn into_rpc_log(self) -> anyhow::Result<RpcLog> {
        let to_i64 = |hex: &str| -> anyhow::Result<i64> {
            parse_hex_u64(hex)?
                .try_into()
                .context("hex quantity exceeds i64::MAX")
        };
        Ok(RpcLog {
            block_number: to_i64(&self.block_number).context("log.blockNumber")?,
            transaction_index: to_i64(&self.transaction_index).context("log.transactionIndex")?,
            log_index: to_i64(&self.log_index).context("log.logIndex")?,
            address: self.address,
            topics: self.topics,
            transaction_hash: self.transaction_hash,
            block_hash: self.block_hash,
        })
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
pub struct LogSelectionInput {
    pub addresses: Option<Vec<String>>,
    /// One entry per topic position. `None` matches any value; `Some(values)`
    /// matches any of the listed topic hashes (a one-element list is an exact
    /// match). The JS side flattens its `Single | Multiple | Null` filter here.
    pub topics: Vec<Option<Vec<String>>>,
}

#[napi(object)]
pub struct NextPageParams {
    pub from_block: i64,
    /// Upper bound on the query range; the actual `toBlock` is decided
    /// internally from the partition's AIMD-suggested interval and returned
    /// on `NextPageResponse`.
    pub to_block_ceiling: i64,
    pub log_selections: Vec<LogSelectionInput>,
    pub partition_id: String,
}

#[napi(object)]
pub struct NextPageResponse {
    pub items: Vec<RpcEventItem>,
    pub to_block: i64,
    pub request_stats: Vec<RequestStat>,
}

#[napi]
pub struct EvmRpcClient {
    inner: JsonRpcClient,
    decoder: DecoderCore,
    sync_config: SyncConfig,
    intervals: IntervalState,
}

#[napi]
impl EvmRpcClient {
    #[napi(factory)]
    pub fn new(
        cfg: EvmRpcClientConfig,
        event_params: Vec<EventParamsInput>,
        checksum_addresses: bool,
    ) -> napi::Result<EvmRpcClient> {
        let http_req_timeout_millis = cfg
            .http_req_timeout_millis
            .filter(|v| *v > 0)
            .map_or(JsonRpcClient::default_http_req_timeout_millis(), |v| {
                v as u64
            });
        let inner =
            JsonRpcClient::new(cfg.url, http_req_timeout_millis, cfg.headers).map_err(map_err)?;
        let decoder = DecoderCore::from_params(event_params, checksum_addresses)
            .context("build decoder")
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
        Ok(EvmRpcClient {
            inner,
            decoder,
            sync_config,
            intervals: IntervalState::new(),
        })
    }

    #[napi]
    pub async fn get_height(&self) -> napi::Result<i64> {
        let height = self.inner.get_height().await.map_err(rpc_error_to_napi)?;
        height
            .try_into()
            .context("block height exceeds i64::MAX")
            .map_err(map_err)
    }

    /// Decides the actual `toBlock` from this partition's AIMD-suggested
    /// interval, fans out one `eth_getLogs` per selection, dedups the merged
    /// results by `(blockNumber, logIndex)`, and races the whole thing against
    /// `queryTimeoutMillis`. On success, grows the partition's interval when
    /// the full suggested range was applied. On failure (timeout, RPC error,
    /// or a "too many logs" style response), shrinks/backs off and throws a
    /// structured retry decision (see `retry_decision_to_napi`).
    #[napi]
    pub async fn get_next_page(&self, params: NextPageParams) -> napi::Result<NextPageResponse> {
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
        // Defensively ensure we never query a target block below fromBlock.
        let to_block = (from_block + suggested_interval - 1)
            .min(to_block_ceiling)
            .max(from_block);

        let timeout = Duration::from_millis(self.sync_config.query_timeout_millis);
        let page_result = tokio::time::timeout(
            timeout,
            self.fetch_page(from_block, to_block, &params.log_selections),
        )
        .await;

        match page_result {
            Ok(Ok((items, request_stats))) => {
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
                Ok(NextPageResponse {
                    items,
                    to_block: to_block as i64,
                    request_stats,
                })
            }
            Ok(Err((rpc_err, request_stats))) => {
                let message = match &rpc_err {
                    RpcError::JsonRpc { message, .. } => Some(message.as_str()),
                    RpcError::Other(_) => None,
                };
                Err(self.retry_error(
                    &params.partition_id,
                    from_block,
                    to_block,
                    source_max,
                    message,
                    request_stats,
                ))
            }
            // Dropping the timed-out future cancels the in-flight requests.
            Err(_elapsed) => Err(self.retry_error(
                &params.partition_id,
                from_block,
                to_block,
                source_max,
                Some(&format!(
                    "Query took longer than {}ms",
                    self.sync_config.query_timeout_millis
                )),
                Vec::new(),
            )),
        }
    }

    /// Builds the structured retry decision for a failed page fetch, updating
    /// the AIMD state as a side effect.
    fn retry_error(
        &self,
        partition_id: &str,
        from_block: u64,
        to_block: u64,
        source_max: u64,
        message: Option<&str>,
        request_stats: Vec<RequestStat>,
    ) -> napi::Error {
        let executed_interval = to_block - from_block + 1;
        let shrunk_interval =
            interval::shrink(executed_interval, self.sync_config.backoff_multiplicative);

        let retry = match message.and_then(suggested_block_interval_from_message) {
            // "limited to N blocks" — a structural cap on the whole source; only tighten.
            Some((suggested, true)) => {
                let capped = self.intervals.tighten_source_max(source_max, suggested);
                RetryDecision::WithSuggestedToBlock {
                    to_block: from_block + capped - 1,
                }
            }
            // A one-off suggested range ("retry with the range X-Y") — apply to this partition.
            Some((suggested, false)) => {
                self.intervals.set_partition(partition_id, suggested);
                RetryDecision::WithSuggestedToBlock {
                    to_block: from_block + suggested - 1,
                }
            }
            // Density cap with no suggested number (too many logs / response too large):
            // shrink THIS partition and retry immediately (no wait); acceleration
            // re-adapts on the next successful query. The interval>1 guard avoids a
            // no-progress tight loop on a single over-cap block.
            None if executed_interval > 1 && message.is_some_and(is_response_too_large_message) => {
                self.intervals.set_partition(partition_id, shrunk_interval);
                RetryDecision::WithSuggestedToBlock {
                    to_block: from_block + shrunk_interval - 1,
                }
            }
            // Transient/unknown (including a timeout) — shrink this partition and back off.
            None => {
                self.intervals.set_partition(partition_id, shrunk_interval);
                RetryDecision::WithBackoff {
                    message: "Failed getting data for the block range. Will try smaller block range for the next attempt.".to_string(),
                    backoff_millis: self.sync_config.backoff_millis,
                }
            }
        };

        retry_decision_to_napi(to_block, message, retry, request_stats)
    }

    /// Fans out one `eth_getLogs` per selection concurrently, deduping the
    /// merged results by `(blockNumber, logIndex)` — a log can satisfy more
    /// than one selection when a single event's `where` is an OR of param
    /// groups. Waits for every selection to settle (unlike `Promise.all`'s
    /// fail-fast) so every request's timing is still captured for
    /// `requestStats` even when one of them errors.
    async fn fetch_page(
        &self,
        from_block: u64,
        to_block: u64,
        selections: &[LogSelectionInput],
    ) -> Result<(Vec<RpcEventItem>, Vec<RequestStat>), (RpcError, Vec<RequestStat>)> {
        if selections.is_empty() {
            return Ok((Vec::new(), Vec::new()));
        }

        let results = futures_util::future::join_all(selections.iter().map(|selection| async {
            let started = Instant::now();
            let result = self
                .fetch_logs_raw(
                    from_block as i64,
                    to_block as i64,
                    selection.addresses.clone(),
                    selection.topics.clone(),
                )
                .await;
            (result, started.elapsed().as_secs_f64())
        }))
        .await;

        let mut items = Vec::new();
        let mut stats = Vec::with_capacity(results.len());
        let mut seen: HashSet<(i64, i64)> = HashSet::new();
        let mut first_err = None;
        for (result, seconds) in results {
            stats.push(RequestStat {
                method: "eth_getLogs".to_string(),
                seconds,
            });
            match result {
                Ok(page_items) => {
                    for item in page_items {
                        if seen.insert((item.log.block_number, item.log.log_index)) {
                            items.push(item);
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
            Some(e) => Err((e, stats)),
            None => Ok((items, stats)),
        }
    }

    async fn fetch_logs_raw(
        &self,
        from_block: i64,
        to_block: i64,
        addresses: Option<Vec<String>>,
        topics: Vec<Option<Vec<String>>>,
    ) -> Result<Vec<RpcEventItem>, RpcError> {
        let mut filter = json!({
            "fromBlock": format!("0x{:x}", from_block),
            "toBlock": format!("0x{:x}", to_block),
            "topics": topics,
        });
        if let Some(addresses) = addresses {
            filter["address"] = json!(addresses);
        }

        let raw_logs: Vec<RawLog> = self.inner.request("eth_getLogs", json!([filter])).await?;

        let decoder = self.decoder.clone();
        // Decoding is CPU-bound ABI work; keep it off the libuv async thread.
        tokio::task::spawn_blocking(move || {
            raw_logs
                .into_iter()
                .map(|raw| {
                    let params = decoder.decode_napi(&raw.to_decoder_log()).ok().flatten();
                    Ok(RpcEventItem {
                        log: raw.into_rpc_log()?,
                        params,
                    })
                })
                .collect::<anyhow::Result<Vec<_>>>()
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

enum RetryDecision {
    WithSuggestedToBlock {
        to_block: u64,
    },
    WithBackoff {
        message: String,
        backoff_millis: u64,
    },
}

/// Encodes the paging retry decision as a JSON payload in the napi error's
/// message: `{"kind":"Retry","attemptedToBlock":...,"errorMessage":...,
/// "requestStats":[...],"retry":{"tag":...}}`.
fn retry_decision_to_napi(
    attempted_to_block: u64,
    error_message: Option<&str>,
    decision: RetryDecision,
    request_stats: Vec<RequestStat>,
) -> napi::Error {
    let retry_json = match decision {
        RetryDecision::WithSuggestedToBlock { to_block } => json!({
            "tag": "WithSuggestedToBlock",
            "toBlock": to_block,
        }),
        RetryDecision::WithBackoff {
            message,
            backoff_millis,
        } => json!({
            "tag": "WithBackoff",
            "message": message,
            "backoffMillis": backoff_millis,
        }),
    };
    let request_stats_json: Vec<_> = request_stats
        .into_iter()
        .map(|s| json!({"method": s.method, "seconds": s.seconds}))
        .collect();
    let payload = json!({
        "kind": "Retry",
        "attemptedToBlock": attempted_to_block,
        "errorMessage": error_message,
        "requestStats": request_stats_json,
        "retry": retry_json,
    })
    .to_string();
    napi::Error::new(napi::Status::GenericFailure, payload)
}

/// Encodes JSON-RPC errors as a JSON payload in the napi error's message.
/// The ReScript side parses it back into a structured exception, keeping
/// the provider's code and message intact across the boundary.
fn rpc_error_to_napi(e: RpcError) -> napi::Error {
    match e {
        RpcError::JsonRpc { code, message } => {
            let payload = serde_json::json!({
                "kind": "JsonRpcError",
                "code": code,
                "message": message,
            })
            .to_string();
            napi::Error::from_reason(payload)
        }
        RpcError::Other(e) => map_err(e),
    }
}

fn map_err(e: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{e:#}"))
}
