//! A source the manager calls itself. Its answers reach the core without a
//! round trip through JavaScript, which only ever sees the pages a query
//! resolved with.

use std::{future::Future, pin::Pin, sync::Arc};

use napi::bindgen_prelude::ToNapiValue;
use napi_derive::napi;

use super::{
    core::RequestStat,
    from_request_stats,
    query::{HashesFailure, Inconsistent, ItemsFailure},
    SourceItemsFailure, SourceManagerItemsQuery, SourceRequestStat,
};
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
