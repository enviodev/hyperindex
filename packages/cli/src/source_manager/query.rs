//! A block-range query or a block-hash lookup, carried from source to source
//! until one answers. The caller makes each attempt and reports how it went;
//! everything about what happens next is decided here.

use serde_json::{json, Map, Value};

use super::core::{Core, Effect, Level, RequestStat, TimerPurpose};
use crate::block_store::HashMismatch;

pub enum Kind {
    Items {
        from_block: i64,
        partition_id: String,
        addresses: u32,
    },
    BlockHashes,
}

pub struct Request {
    kind: Kind,
    is_realtime: bool,
    to_block: Option<i64>,
    retry: u32,
    source: usize,
    /// Sources the query is impossible on. Excluded for this query only.
    excluded: Vec<usize>,
}

impl Request {
    fn method(&self) -> &'static str {
        match self.kind {
            Kind::Items { .. } => "getItems",
            Kind::BlockHashes => "getBlockHashes",
        }
    }
}

/// How an attempt at a block range went, when it didn't answer.
pub enum ItemsFailure {
    RateLimited {
        reset_ms: u32,
    },
    BehindHead {
        block_number: i64,
    },
    /// The source can never serve this selection.
    FieldSelection {
        message: String,
        block_number: i64,
    },
    SuggestedToBlock {
        to_block: i64,
        attempted_to_block: i64,
    },
    /// The query can't work on this source, which isn't broken for it.
    Impossible {
        message: String,
        attempted_to_block: i64,
    },
    Backoff {
        message: String,
        backoff_millis: u32,
        attempted_to_block: i64,
    },
}

pub enum HashesFailure {
    RateLimited { reset_ms: u32 },
    BehindHead { block_number: i64 },
    Other,
}

/// A response that contradicts itself: the same block twice with different
/// hashes, or a requested hash missing.
pub struct Inconsistent {
    conflict: Option<HashMismatch>,
    missing_block_numbers: Vec<i64>,
}

impl Inconsistent {
    pub fn check(conflict: Option<HashMismatch>, missing_block_numbers: Vec<i64>) -> Option<Self> {
        (conflict.is_some() || !missing_block_numbers.is_empty()).then_some(Inconsistent {
            conflict,
            missing_block_numbers,
        })
    }

    fn describe(&self, method: &str) -> Value {
        match &self.conflict {
            Some(conflict) => json!({
                "message": format!(
                    "The {method} response holds block {} twice, with hashes {} and {}.",
                    conflict.block_number, conflict.stored_hash, conflict.received_hash
                ),
                "blockNumber": conflict.block_number,
                "storedHash": conflict.stored_hash,
                "receivedHash": conflict.received_hash,
            }),
            None => json!({
                "message": format!("The {method} response is missing requested block hashes."),
                "missingBlockNumbers": self.missing_block_numbers,
            }),
        }
    }
}

const MAX_RETRY_BACKOFF_MILLIS: u32 = 60_000;

/// Floor for the retries driven by a condition the source reported itself.
/// Unlike a caller-supplied backoff of 0, these must never busy-loop when there
/// is no other source to move to.
const MIN_RECOVERABLE_BACKOFF_MILLIS: u32 = 50;

/// A replica behind its siblings usually catches up within seconds, and failing
/// over demotes an otherwise healthy source for the whole recovery timeout. So
/// the source keeps the query for about 10s (100ms doubling, capped at 1s)
/// before a failover is tried; past that it is polled less and less often.
const BEHIND_HEAD_FAILOVER_RETRIES: u32 = 12;

/// A query that has failed this many times running has rotated through the
/// chain's sources several times over and none answered: whatever the cause,
/// the chain has stopped making progress and the operator has to hear.
pub const STALL_RETRIES: u32 = 13;

/// Rate-limit windows are capped against pathological server values.
const MAX_RATE_LIMIT_WAIT_MILLIS: u32 = 300_000;

fn exponential_backoff_millis(base: u32, exp: u32, max_millis: u32) -> u32 {
    let factor = 2u64.saturating_pow(exp);
    (u64::from(base).saturating_mul(factor)).min(u64::from(max_millis)) as u32
}

/// One schedule for every retry of the same request, whatever made it fail.
fn retry_backoff_millis(retry: u32) -> u32 {
    exponential_backoff_millis(100, retry, MAX_RETRY_BACKOFF_MILLIS)
}

fn behind_head_backoff_millis(retry: u32) -> u32 {
    if retry < BEHIND_HEAD_FAILOVER_RETRIES {
        exponential_backoff_millis(100, retry, 1_000)
    } else {
        exponential_backoff_millis(
            1_000,
            retry - BEHIND_HEAD_FAILOVER_RETRIES,
            MAX_RETRY_BACKOFF_MILLIS,
        )
    }
}

/// The level a retry is reported at, and what it says once the retries have
/// outlasted the rotation.
fn escalate_when_stalled(
    retry: u32,
    warn_after: u32,
    message: String,
    stalled: &str,
) -> (Level, String) {
    if retry >= STALL_RETRIES {
        (Level::Error, message + stalled)
    } else if retry >= warn_after {
        (Level::Warn, message)
    } else {
        (Level::Trace, message)
    }
}

/// Builds a JSON object, leaving out the fields that have no value, as a
/// JavaScript object with `undefined` fields serializes.
fn object_without_nulls(entries: Vec<(&str, Value)>) -> Value {
    Value::Object(
        entries
            .into_iter()
            .filter(|(_, value)| !value.is_null())
            .map(|(key, value)| (key.to_string(), value))
            .collect::<Map<String, Value>>(),
    )
}

struct Backoff {
    millis: u32,
    min_millis: u32,
    failover_after_retries: u32,
}

impl Core {
    pub fn start_items_query(
        &mut self,
        from_block: i64,
        to_block: Option<i64>,
        partition_id: String,
        addresses: u32,
        is_realtime: bool,
        now: f64,
    ) -> u32 {
        self.start_request(
            Kind::Items {
                from_block,
                partition_id,
                addresses,
            },
            to_block,
            is_realtime,
            now,
        )
    }

    pub fn start_block_hashes(&mut self, is_realtime: bool, now: f64) -> u32 {
        self.start_request(Kind::BlockHashes, None, is_realtime, now)
    }

    fn start_request(
        &mut self,
        kind: Kind,
        to_block: Option<i64>,
        is_realtime: bool,
        now: f64,
    ) -> u32 {
        let request = self.next_id();
        self.requests.insert(
            request,
            Request {
                kind,
                is_realtime,
                to_block,
                retry: 0,
                source: self.active,
                excluded: Vec::new(),
            },
        );
        self.attempt(request, now);
        request
    }

    /// A request is live from its start until it resolves, rejects or is
    /// abandoned, and the caller only reports on, and times, live ones.
    fn request(&self, request_id: u32) -> &Request {
        self.requests
            .get(&request_id)
            .expect("a request is reported on only while it is live")
    }

    fn request_mut(&mut self, request_id: u32) -> &mut Request {
        self.requests
            .get_mut(&request_id)
            .expect("a request is reported on only while it is live")
    }

    pub fn abandon_request(&mut self, request: u32) {
        self.requests.remove(&request);
    }

    /// Read when the manager runs out, not on the way in: the reason is
    /// recorded by the failure that disabled the last source.
    fn no_sources_message(&self) -> String {
        match &self.disable_reason {
            Some(reason) => format!(
                "The indexer doesn't have data-sources which can continue fetching. The last one was disabled because {reason}"
            ),
            None => "The indexer doesn't have data-sources which can continue fetching. Please, check the error logs or reach out to the Envio team.".to_string(),
        }
    }

    /// Picks the best source for the request at the start of every attempt.
    fn attempt(&mut self, request_id: u32, now: f64) {
        let request = self.request(request_id);
        let Some(source) = self.next_source(request.is_realtime, &request.excluded, now) else {
            let message = self.no_sources_message();
            self.requests.remove(&request_id);
            self.emit(Effect::Reject {
                request: request_id,
                message,
            });
            return;
        };
        if let Kind::Items { from_block, .. } = request.kind {
            if source != self.active {
                self.log(
                    None,
                    Level::Info,
                    "Switching data-source".to_string(),
                    json!({
                        "source": self.sources[source].spec.name,
                        "previousSource": self.sources[self.active].spec.name,
                        "fromBlock": from_block,
                    }),
                );
            }
        }
        self.active = source;
        let request = self.request_mut(request_id);
        request.source = source;
        let (to_block, retry) = (request.to_block, request.retry);
        let fields = self.request_log_fields(request_id).expect("checked above");
        self.emit(Effect::Attempt {
            request: request_id,
            source,
            to_block,
            retry,
            fields,
        });
    }

    /// The fields every line about the request's current attempt carries.
    fn request_log_fields(&self, request: u32) -> Option<Value> {
        let request = self.request(request);
        let name = &self.sources[request.source].spec.name;
        Some(match &request.kind {
            Kind::Items {
                from_block,
                partition_id,
                addresses,
            } => object_without_nulls(vec![
                ("logType", json!("Block Range Query")),
                ("partitionId", json!(partition_id)),
                ("source", json!(name)),
                ("fromBlock", json!(from_block)),
                ("toBlock", json!(request.to_block)),
                ("addresses", json!(addresses)),
                ("retry", json!(request.retry)),
            ]),
            Kind::BlockHashes => json!({
                "logType": "Block Hash Query",
                "source": name,
                "retry": request.retry,
            }),
        })
    }

    pub fn items_answered(
        &mut self,
        request_id: u32,
        known_height: i64,
        stats: &[RequestStat],
        inconsistent: Option<Inconsistent>,
        now: f64,
    ) {
        let source = self.request(request_id).source;
        self.sources[source].record_request_stats(stats);
        if let Some(inconsistent) = inconsistent {
            self.retry_inconsistent(request_id, &inconsistent, now);
            return;
        }
        self.sources[source].last_failed_at = None;
        // A fresh height for exactly this source: during a long backfill, when
        // nothing waits on the feed, it keeps envio_source_known_height current,
        // and a height learned this way can settle a wait in flight.
        self.record_height(source, known_height);
        self.requests.remove(&request_id);
        self.emit(Effect::Resolve {
            request: request_id,
        });
    }

    pub fn items_failed(
        &mut self,
        request_id: u32,
        failure: ItemsFailure,
        stats: &[RequestStat],
        err: Option<u32>,
        now: f64,
    ) {
        let request = self.request(request_id);
        let source = request.source;
        let retry = request.retry;
        // A page that ends in a retry still made requests.
        self.sources[source].record_request_stats(stats);
        let fields = self.request_log_fields(request_id);
        let name = self.sources[source].spec.name.clone();
        match failure {
            ItemsFailure::RateLimited { reset_ms } => {
                self.wait_for_rate_limit_reset(request_id, reset_ms, now)
            }
            ItemsFailure::BehindHead { block_number } => {
                self.retry_behind_head(request_id, block_number, now)
            }
            ItemsFailure::FieldSelection {
                message,
                block_number,
            } => {
                // Can never succeed here, so the source is not tried again. With
                // several partitions failing at once, it is logged once.
                if self.disable_source(source) {
                    self.disable_reason = Some(message.clone());
                    self.log_with_err(
                        fields,
                        Level::Error,
                        message,
                        json!({ "blockNumber": block_number }),
                        err,
                    );
                }
                self.retry_now(request_id, 0, now);
            }
            // A suggestion that doesn't narrow the range asks for the query that
            // just failed. Retried unchanged and without a wait it would make no
            // progress and never count against the source.
            ItemsFailure::SuggestedToBlock {
                to_block,
                attempted_to_block,
            } if to_block >= attempted_to_block => {
                let message = format!(
                    "The {name} source rejected the block range and suggested #{to_block}, which is no narrower than the #{attempted_to_block} it just refused."
                );
                self.retry_failed_page(
                    request_id,
                    message,
                    attempted_to_block,
                    Backoff {
                        millis: retry_backoff_millis(retry),
                        min_millis: MIN_RECOVERABLE_BACKOFF_MILLIS,
                        failover_after_retries: 2,
                    },
                    err,
                    now,
                );
            }
            ItemsFailure::SuggestedToBlock {
                to_block,
                attempted_to_block,
            } => {
                self.log(
                    fields,
                    Level::Trace,
                    "Failed getting data for the block range. Immediately retrying with the suggested block range from response.".to_string(),
                    json!({ "toBlock": attempted_to_block, "suggestedToBlock": to_block }),
                );
                self.request_mut(request_id).to_block = Some(to_block);
                // A strictly smaller question starts a fresh schedule.
                self.retry_now(request_id, 0, now);
            }
            ItemsFailure::Impossible {
                message,
                attempted_to_block,
            } => {
                // No failure is recorded: the source isn't broken, the query just
                // can't work on it.
                self.request_mut(request_id).excluded.push(source);
                self.log_with_err(
                    fields,
                    Level::Warn,
                    message + " - Attempting another source",
                    json!({ "toBlock": attempted_to_block }),
                    err,
                );
                self.retry_now(request_id, 0, now);
            }
            ItemsFailure::Backoff {
                message,
                backoff_millis,
                attempted_to_block,
            } => self.retry_failed_page(
                request_id,
                message,
                attempted_to_block,
                Backoff {
                    millis: backoff_millis,
                    min_millis: 0,
                    failover_after_retries: 2,
                },
                err,
                now,
            ),
        }
    }

    pub fn hashes_answered(
        &mut self,
        request_id: u32,
        stats: &[RequestStat],
        inconsistent: Option<Inconsistent>,
        now: f64,
    ) {
        let source = self.request(request_id).source;
        self.sources[source].record_request_stats(stats);
        if let Some(inconsistent) = inconsistent {
            self.retry_inconsistent(request_id, &inconsistent, now);
            return;
        }
        self.sources[source].last_failed_at = None;
        self.requests.remove(&request_id);
        self.emit(Effect::Resolve {
            request: request_id,
        });
    }

    pub fn hashes_failed(
        &mut self,
        request_id: u32,
        failure: HashesFailure,
        stats: &[RequestStat],
        err: Option<u32>,
        now: f64,
    ) {
        let request = self.request(request_id);
        let (source, retry) = (request.source, request.retry);
        self.sources[source].record_request_stats(stats);
        match failure {
            HashesFailure::RateLimited { reset_ms } => {
                self.wait_for_rate_limit_reset(request_id, reset_ms, now)
            }
            HashesFailure::BehindHead { block_number } => {
                self.retry_behind_head(request_id, block_number, now)
            }
            HashesFailure::Other => {
                let backoff_millis = retry_backoff_millis(retry);
                let level = if retry >= 4 {
                    Level::Warn
                } else {
                    Level::Trace
                };
                self.log_with_err(
                    self.request_log_fields(request_id),
                    level,
                    "Failed to fetch block hashes. Retrying.".to_string(),
                    json!({ "retry": retry, "backOffMilliseconds": backoff_millis }),
                    err,
                );
                self.back_off_before_retry(
                    request_id,
                    Backoff {
                        millis: backoff_millis,
                        min_millis: MIN_RECOVERABLE_BACKOFF_MILLIS,
                        failover_after_retries: 2,
                    },
                    now,
                );
            }
        }
    }

    /// The next attempt starts now, at `retry`.
    fn retry_now(&mut self, request_id: u32, retry: u32, now: f64) {
        self.request_mut(request_id).retry = retry;
        self.attempt(request_id, now);
    }

    pub fn retry_backoff_ended(&mut self, request_id: u32, now: f64) {
        self.next_retry(request_id, now);
    }

    fn next_retry(&mut self, request_id: u32, now: f64) {
        let retry = self.request(request_id).retry;
        self.retry_now(request_id, retry + 1, now);
    }

    /// Waits out the server's suggested reset window, escalating from trace to
    /// warn after the second consecutive retry so chronic throttling isn't
    /// silent.
    fn wait_for_rate_limit_reset(&mut self, request_id: u32, reset_ms: u32, now: f64) {
        let retry = self.request(request_id).retry;
        let wait_ms = reset_ms.min(MAX_RATE_LIMIT_WAIT_MILLIS);
        let level = if retry >= 2 {
            Level::Warn
        } else {
            Level::Trace
        };
        self.log(
            self.request_log_fields(request_id),
            level,
            format!(
                "HyperSync source is rate-limited - not critical, the indexer will retry in {}s. For higher limits upgrade your plan at https://envio.dev/app/api-tokens.",
                wait_ms / 1000
            ),
            json!({ "retry": retry, "waitMs": wait_ms }),
        );
        self.start_rate_limit(wait_ms, now);
        self.arm_timer(
            TimerPurpose::RateLimitReset {
                request: request_id,
            },
            "rate-limit reset",
            wait_ms,
            false,
        );
    }

    pub fn rate_limit_reset(&mut self, request_id: u32, now: f64) {
        self.stop_rate_limit(now);
        self.next_retry(request_id, now);
    }

    /// The queried block hasn't reached the backend instance that served the
    /// request. Expected near the head of a load-balanced backend, so early
    /// attempts stay quiet and short.
    fn retry_behind_head(&mut self, request_id: u32, block_number: i64, now: f64) {
        let request = self.request(request_id);
        let retry = request.retry;
        let backoff_millis = behind_head_backoff_millis(retry);
        let name = &self.sources[request.source].spec.name;
        // Routine and self-healing, and the wording says so.
        let (level, message) = if retry < BEHIND_HEAD_FAILOVER_RETRIES {
            (
                Level::Trace,
                format!("{name} hasn't reached block {block_number} on all of its servers yet. This is normal near the latest block and resolves by itself - retrying shortly."),
            )
        } else {
            (
                Level::Warn,
                format!("{name} is still catching up to block {block_number}. This is a delay on the provider's side; indexing will continue automatically, using another data source if one is configured."),
            )
        };
        self.log(
            self.request_log_fields(request_id),
            level,
            message,
            json!({ "retry": retry, "backOffMilliseconds": backoff_millis }),
        );
        self.back_off_before_retry(
            request_id,
            Backoff {
                millis: backoff_millis,
                min_millis: MIN_RECOVERABLE_BACKOFF_MILLIS,
                failover_after_retries: BEHIND_HEAD_FAILOVER_RETRIES,
            },
            now,
        );
    }

    /// It may be a reorg mid-request, so refetch before concluding anything
    /// about the chain.
    fn retry_inconsistent(&mut self, request_id: u32, inconsistent: &Inconsistent, now: f64) {
        let request = self.request(request_id);
        let (retry, source, method) = (request.retry, request.source, request.method());
        let backoff_millis = retry_backoff_millis(retry);
        let message = format!(
            "Received a partial indicator of a possible reorg from the {} source while fetching {method}. Retrying the request to better identify whether a reorg happened.",
            self.sources[source].spec.name
        );
        let (level, message) = escalate_when_stalled(
            retry,
            2,
            message,
            " It has disagreed with itself on every attempt for several minutes now, so this chain has stopped making progress - the endpoint is likely serving blocks and logs from nodes on different chains.",
        );
        self.log(
            self.request_log_fields(request_id),
            level,
            message,
            json!({
                "method": method,
                "retry": retry,
                "backOffMilliseconds": backoff_millis,
                "err": inconsistent.describe(method),
            }),
        );
        // Before the backoff: local state may point at an orphaned chain, and a
        // sibling query on this source would keep reading it while we wait.
        self.emit(Effect::Reorg { source });
        self.back_off_before_retry(
            request_id,
            Backoff {
                millis: backoff_millis,
                min_millis: MIN_RECOVERABLE_BACKOFF_MILLIS,
                failover_after_retries: 2,
            },
            now,
        );
    }

    /// The source couldn't serve the page and reported nothing that changes the
    /// query, so the only move left is to wait and let the schedule try another
    /// source.
    fn retry_failed_page(
        &mut self,
        request_id: u32,
        message: String,
        attempted_to_block: i64,
        backoff: Backoff,
        err: Option<u32>,
        now: f64,
    ) {
        let retry = self.request(request_id).retry;
        let (level, message) = escalate_when_stalled(
            retry,
            4,
            message,
            " No source available to this chain has served this query on any attempt since, so indexing has stopped making progress.",
        );
        self.log_with_err(
            self.request_log_fields(request_id),
            level,
            message,
            json!({
                "toBlock": attempted_to_block,
                "backOffMilliseconds": backoff.millis,
                "retry": retry,
            }),
            err,
        );
        self.back_off_before_retry(request_id, backoff, now);
    }

    /// Backs off before retrying, failing the source over first when another can
    /// take over. Marking the failure only demotes this source: with no working
    /// alternative the next attempt lands right back here, so the floor is what
    /// keeps a retry loop that never changes source from spinning.
    fn back_off_before_retry(&mut self, request_id: u32, backoff: Backoff, now: f64) {
        let request = self.request(request_id);
        let (retry, source, is_realtime) = (request.retry, request.source, request.is_realtime);
        let excluded = request.excluded.clone();
        // A few attempts before demoting the source, then a failover every
        // second attempt.
        let switched_to_working_source = retry >= backoff.failover_after_retries
            && (retry - backoff.failover_after_retries).is_multiple_of(2)
            && {
                self.sources[source].last_failed_at = Some(now);
                self.next_source(is_realtime, &excluded, now)
                    .is_some_and(|next| self.is_working(next, now))
            };
        let sleep = if switched_to_working_source {
            // The next attempt goes elsewhere, which is progress on its own.
            (backoff.min_millis > 0).then_some(backoff.min_millis)
        } else {
            Some(
                backoff
                    .millis
                    .max(backoff.min_millis)
                    .min(MAX_RETRY_BACKOFF_MILLIS),
            )
        };
        match sleep {
            Some(millis) => {
                self.arm_timer(
                    TimerPurpose::RetryBackoff {
                        request: request_id,
                    },
                    "retry backoff",
                    millis,
                    false,
                );
            }
            None => self.next_retry(request_id, now),
        }
    }
}
