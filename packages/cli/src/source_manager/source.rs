//! A source the manager calls itself. Its answers reach the core without a
//! round trip through JavaScript, which only ever sees the pages a query
//! resolved with.

use std::{
    future::Future,
    pin::Pin,
    sync::atomic::{AtomicBool, Ordering},
    sync::Arc,
};

use napi::bindgen_prelude::ToNapiValue;
use napi_derive::napi;

use super::{
    core::RequestStat,
    from_request_stats,
    query::{HashesFailure, Inconsistent, ItemsFailure},
    SourceItemsFailure, SourceManagerItemsQuery, SourceRequestStat,
};
use crate::request_stats::{read_native_failure, Marker};
use crate::{address_store::AddressSet, block_store::BlockStore, height_stream::driver::Transport};

pub type BoxFuture<T> = Pin<Box<dyn Future<Output = T> + Send>>;

pub enum HeightOutcome {
    Answered {
        height: i64,
        stats: Vec<RequestStat>,
    },
    Failed {
        stats: Vec<RequestStat>,
        cause: String,
        /// A line for the operator, beyond the retry's own.
        alert: Option<String>,
    },
}

pub struct EventRegistration {
    pub index: i64,
    pub start_block: Option<i64>,
}

/// What a partition selects, as fixed when its query started.
pub struct Selection {
    pub on_event_registrations: Vec<EventRegistration>,
    pub on_block_registration_indexes: Vec<i64>,
    pub client_filtered_contracts: Option<Vec<String>>,
}

impl Selection {
    /// The event registrations that can match at or below `to_block`. When none
    /// can, the whole selection: narrowing to nothing would build a query with
    /// no log filter, which every source reads as "select everything", so the
    /// routers drop what hasn't started instead.
    pub fn event_registration_indexes_through(&self, to_block: Option<i64>) -> Vec<i64> {
        let in_range: Vec<i64> = self
            .on_event_registrations
            .iter()
            .filter(|registration| match (to_block, registration.start_block) {
                (Some(to_block), Some(start_block)) => start_block <= to_block,
                _ => true,
            })
            .map(|registration| registration.index)
            .collect();
        if in_range.is_empty() {
            self.on_event_registrations
                .iter()
                .map(|registration| registration.index)
                .collect()
        } else {
            in_range
        }
    }
}

pub struct ItemsQuery {
    pub from_block: i64,
    /// The attempt's end, which the core may have narrowed from the query's.
    pub to_block: Option<i64>,
    pub known_height: i64,
    /// Blocks at or above this one can still be reorged. None when every block
    /// of the range is final.
    pub reorgable_from: Option<i64>,
    pub partition_id: String,
    pub selection: Arc<Selection>,
    /// Soft cap on the primary items to ask for. None means no cap.
    pub items_target: Option<u32>,
    pub retry: u32,
    pub addresses: AddressSet,
}

/// A page as JavaScript receives it, converted only when it asks.
pub trait JsPage: Send {
    /// # Safety
    /// `env` must be the environment of the call converting it.
    unsafe fn into_napi(
        self: Box<Self>,
        env: napi::sys::napi_env,
    ) -> napi::Result<napi::sys::napi_value>;
}

impl<T: ToNapiValue + Send> JsPage for T {
    unsafe fn into_napi(
        self: Box<Self>,
        env: napi::sys::napi_env,
    ) -> napi::Result<napi::sys::napi_value> {
        T::to_napi_value(env, *self)
    }
}

pub struct NativePage(pub Box<dyn JsPage>);

impl ToNapiValue for NativePage {
    unsafe fn to_napi_value(
        env: napi::sys::napi_env,
        page: Self,
    ) -> napi::Result<napi::sys::napi_value> {
        page.0.into_napi(env)
    }
}

pub enum ItemsOutcome {
    Answered {
        known_height: i64,
        stats: Vec<RequestStat>,
        inconsistent: Option<Inconsistent>,
        page: Box<dyn JsPage>,
    },
    Failed {
        failure: ItemsFailure,
        stats: Vec<RequestStat>,
        cause: Option<String>,
    },
    /// Nothing here can retry it, so the query fails with it.
    Unexpected { cause: String },
}

pub enum HashesOutcome {
    Answered {
        stats: Vec<RequestStat>,
        inconsistent: Option<Inconsistent>,
        blocks: BlockStore,
    },
    Failed {
        failure: HashesFailure,
        stats: Vec<RequestStat>,
        cause: String,
    },
}

pub trait Source: Send + Sync + 'static {
    fn get_height(&self) -> BoxFuture<HeightOutcome>;
    fn get_items(&self, query: ItemsQuery) -> BoxFuture<ItemsOutcome>;
    fn get_block_hashes(&self, block_numbers: Vec<i64>) -> BoxFuture<HashesOutcome>;
    /// What the source is holding may describe an orphaned chain.
    fn on_reorg(&self) {}
    /// How heights are pushed to the source's subscribers, if they can be.
    fn height_transport(&self) -> Option<Arc<dyn Transport>> {
        None
    }
}

#[napi(object, object_from_js = false)]
pub struct NativeItemsCall {
    pub page: Option<NativePage>,
    pub known_height: Option<i64>,
    pub failure: Option<SourceItemsFailure>,
    pub cause: Option<String>,
    /// A failure nothing could retry.
    pub unexpected: Option<String>,
    pub request_stats: Vec<SourceRequestStat>,
}

#[napi(object, object_from_js = false)]
pub struct NativeHashesCall {
    pub blocks: Option<BlockStore>,
    pub behind_head_block: Option<i64>,
    pub cause: Option<String>,
    pub request_stats: Vec<SourceRequestStat>,
}

/// A source built in Rust, handed to the manager that calls it.
#[napi]
pub struct NativeSource {
    pub(crate) source: Arc<dyn Source>,
}

impl NativeSource {
    pub(crate) fn new(source: impl Source) -> Self {
        NativeSource {
            source: Arc::new(source),
        }
    }
}

#[napi]
impl NativeSource {
    #[napi]
    pub fn can_stream(&self) -> bool {
        self.source.height_transport().is_some()
    }

    #[napi]
    pub fn on_reorg(&self) {
        self.source.on_reorg();
    }

    /// One items read, outside any manager, as a source's contract tests make
    /// it.
    #[napi]
    pub async fn call_items(
        &self,
        query: SourceManagerItemsQuery,
        addresses: &AddressSet,
        retry: u32,
    ) -> NativeItemsCall {
        let outcome = self
            .source
            .get_items(ItemsQuery {
                from_block: query.from_block,
                to_block: query.to_block,
                known_height: query.known_height,
                reorgable_from: query.reorgable_from,
                partition_id: query.partition_id,
                selection: Arc::new(query.selection.into()),
                items_target: query.items_target,
                retry,
                addresses: addresses.share(),
            })
            .await;
        let call = NativeItemsCall {
            page: None,
            known_height: None,
            failure: None,
            cause: None,
            unexpected: None,
            request_stats: Vec::new(),
        };
        match outcome {
            ItemsOutcome::Answered {
                known_height,
                stats,
                page,
                ..
            } => NativeItemsCall {
                page: Some(NativePage(page)),
                known_height: Some(known_height),
                request_stats: from_request_stats(stats),
                ..call
            },
            ItemsOutcome::Failed {
                failure,
                stats,
                cause,
            } => NativeItemsCall {
                failure: Some(failure.into()),
                cause,
                request_stats: from_request_stats(stats),
                ..call
            },
            ItemsOutcome::Unexpected { cause } => NativeItemsCall {
                unexpected: Some(cause),
                ..call
            },
        }
    }

    /// One block-hash read, outside any manager, as a source's contract tests
    /// make it.
    #[napi]
    pub async fn call_block_hashes(&self, block_numbers: Vec<i64>) -> NativeHashesCall {
        match self.source.get_block_hashes(block_numbers).await {
            HashesOutcome::Answered { stats, blocks, .. } => NativeHashesCall {
                blocks: Some(blocks),
                behind_head_block: None,
                cause: None,
                request_stats: from_request_stats(stats),
            },
            HashesOutcome::Failed {
                failure,
                stats,
                cause,
            } => NativeHashesCall {
                blocks: None,
                behind_head_block: match failure {
                    HashesFailure::BehindHead { block_number } => Some(block_number),
                    _ => None,
                },
                cause: Some(cause),
                request_stats: from_request_stats(stats),
            },
        }
    }

    /// One height read, outside any manager: for resolving a `latest` start
    /// block before the chain's manager exists.
    #[napi]
    pub async fn get_height(&self) -> napi::Result<i64> {
        match self.source.get_height().await {
            HeightOutcome::Answered { height, .. } => Ok(height),
            HeightOutcome::Failed { cause, .. } => Err(napi::Error::from_reason(cause)),
        }
    }
}

/// A HyperSync client's paginated block-hash read, which names a recoverable
/// failure in its error.
pub fn hashes_outcome(
    result: napi::Result<(BlockStore, Vec<crate::request_stats::RequestStat>)>,
    block_numbers: Vec<i64>,
) -> HashesOutcome {
    match result {
        Ok((blocks, stats)) => HashesOutcome::Answered {
            stats: request_stats(stats),
            inconsistent: Inconsistent::check(
                blocks.response_conflict(),
                blocks.missing_hashes(block_numbers),
            ),
            blocks,
        },
        Err(err) => {
            let failure = read_native_failure(&err);
            HashesOutcome::Failed {
                failure: match failure.marker {
                    Marker::RateLimited { reset_ms } => HashesFailure::RateLimited { reset_ms },
                    Marker::BehindHead { block_number } => {
                        HashesFailure::BehindHead { block_number }
                    }
                    Marker::None => HashesFailure::Other,
                },
                stats: request_stats(failure.request_stats),
                cause: failure.message,
            }
        }
    }
}

/// A HyperSync client's failed items read: the rate limit or lagging replica
/// its error names, or what `otherwise` makes of anything else.
pub fn items_failure(
    err: &napi::Error,
    otherwise: impl FnOnce(String) -> ItemsOutcome,
) -> ItemsOutcome {
    let failure = read_native_failure(err);
    let recoverable = match failure.marker {
        Marker::RateLimited { reset_ms } => ItemsFailure::RateLimited { reset_ms },
        Marker::BehindHead { block_number } => ItemsFailure::BehindHead { block_number },
        Marker::None => return otherwise(failure.message),
    };
    ItemsOutcome::Failed {
        failure: recoverable,
        stats: request_stats(failure.request_stats),
        cause: None,
    }
}

/// The wait before retrying a page that failed for no reason a source could
/// name.
pub fn unexplained_backoff_millis(retry: u32) -> u32 {
    match retry {
        0 => 500,
        retry => retry.saturating_mul(1000),
    }
}

/// The line saying a HyperSync product rejected the token, the first time a
/// failure says so. The failure itself still goes to the retries: a token can
/// be replaced without restarting, so they go on asking, and saying it on every
/// retry would bury the log.
pub fn unauthorized_alert(product: &str, message: &str, warned: &AtomicBool) -> Option<String> {
    (message.contains("401 Unauthorized") && !warned.swap(true, Ordering::Relaxed)).then(|| {
        format!(
            "Your ENVIO_API_TOKEN was rejected by {product} (401 Unauthorized). The indexer will \
             not be able to fetch events. Update the token and try again using 'envio start' or \
             'envio dev'. For more info: https://docs.envio.dev/docs/HyperSync/api-tokens"
        )
    })
}

/// The fields a HyperSync response lacked, when that is what it failed with.
pub fn missing_fields(message: &str) -> Option<Vec<String>> {
    let payload: serde_json::Value = serde_json::from_str(message).ok()?;
    (payload["kind"] == "MissingFields").then(|| {
        payload["fields"]
            .as_array()
            .map(|fields| {
                fields
                    .iter()
                    .filter_map(|field| field.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default()
    })
}

pub fn request_stat(method: &str, seconds: f64) -> RequestStat {
    RequestStat {
        method: method.to_string(),
        seconds,
        response_blocks: None,
    }
}

pub fn request_stats(stats: Vec<crate::request_stats::RequestStat>) -> Vec<RequestStat> {
    stats
        .into_iter()
        .map(|stat| RequestStat {
            method: stat.method,
            seconds: stat.seconds,
            response_blocks: None,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alerts_on_a_rejected_token_once() {
        let warned = AtomicBool::new(false);
        let rejected = "Failed to get HyperSync height: http response status code 401 Unauthorized";
        assert_eq!(
            [
                unauthorized_alert("HyperSync", "connection reset", &warned),
                unauthorized_alert("HyperSync", rejected, &warned),
                unauthorized_alert("HyperSync", rejected, &warned),
            ]
            .map(|alert| alert.is_some()),
            [false, true, false]
        );
    }

    #[test]
    fn reads_the_fields_a_response_lacked() {
        assert_eq!(
            [
                r#"{"kind":"MissingFields","fields":["block.timestamp","transaction.hash"]}"#,
                "some unrelated message",
                r#"{"kind":"SomethingElse","fields":["x"]}"#,
            ]
            .map(missing_fields),
            [
                Some(vec![
                    "block.timestamp".to_string(),
                    "transaction.hash".to_string()
                ]),
                None,
                None,
            ]
        );
    }

    #[test]
    fn narrows_to_the_registrations_started_by_the_end_of_the_range() {
        let selection = Selection {
            on_event_registrations: vec![
                EventRegistration {
                    index: 0,
                    start_block: None,
                },
                EventRegistration {
                    index: 1,
                    start_block: Some(200),
                },
                EventRegistration {
                    index: 2,
                    start_block: Some(100),
                },
            ],
            on_block_registration_indexes: Vec::new(),
            client_filtered_contracts: None,
        };
        let starting_late = Selection {
            on_event_registrations: vec![EventRegistration {
                index: 1,
                start_block: Some(200),
            }],
            on_block_registration_indexes: Vec::new(),
            client_filtered_contracts: None,
        };
        assert_eq!(
            [
                selection.event_registration_indexes_through(Some(150)),
                selection.event_registration_indexes_through(None),
                starting_late.event_registration_indexes_through(Some(150)),
            ],
            [vec![0, 2], vec![0, 1, 2], vec![1]]
        );
    }
}
