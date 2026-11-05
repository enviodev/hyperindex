//! The HyperSync client as a source the manager calls itself, and the napi
//! class ReScript builds it from.

use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::Instant;

use napi_derive::napi;

use super::config::ClientConfig;
use super::types::OnEventRegistrationInput;
use super::{EventItem, HyperSyncClient, ItemsQuery, ItemsResponse, Query, QueryResponse};
use crate::address_store::{AddressSet, AddressStore};
use crate::block_selection::{BlockItem, OnBlockRegistrationInput};
use crate::block_store::BlockStore;
use crate::height_stream::{driver::Transport, sse::Sse};
use crate::request_stats::RequestStat;
use crate::source_manager::source::{
    hashes_outcome, items_failure, missing_fields, request_stat, unauthorized_alert,
    unexplained_backoff_millis, BoxFuture, HashesOutcome, HeightOutcome, ItemsOutcome,
    NativeSource, Source,
};
use crate::source_manager::{Inconsistent, ItemsFailure};
use crate::transaction_store::TransactionStore;

#[napi]
pub struct EvmHyperSyncClient {
    client: Arc<HyperSyncClient>,
}

#[napi]
impl EvmHyperSyncClient {
    #[napi(factory)]
    pub fn new(
        cfg: ClientConfig,
        user_agent: String,
        event_registrations: Vec<OnEventRegistrationInput>,
        block_registrations: Vec<OnBlockRegistrationInput>,
        address_store: &AddressStore,
    ) -> napi::Result<EvmHyperSyncClient> {
        Ok(EvmHyperSyncClient {
            client: Arc::new(HyperSyncClient::new(
                cfg,
                user_agent,
                event_registrations,
                block_registrations,
                address_store,
            )?),
        })
    }

    #[napi]
    pub async fn get_height(&self) -> napi::Result<i64> {
        self.client.get_height().await
    }

    #[napi]
    pub async fn get(&self, query: Query) -> napi::Result<QueryResponse> {
        self.client.get(query).await
    }

    #[napi]
    pub async fn get_block_hashes(
        &self,
        block_numbers: Vec<i64>,
    ) -> napi::Result<(BlockStore, Vec<RequestStat>)> {
        self.client.get_block_hashes(block_numbers).await
    }

    #[napi]
    pub async fn get_items(
        &self,
        params: ItemsQuery,
        address_set: &AddressSet,
    ) -> napi::Result<(ItemsResponse, TransactionStore, BlockStore)> {
        self.client.get_items(params, address_set).await
    }

    /// The client as a source the manager calls itself, pushing heights over
    /// the server's stream.
    #[napi]
    pub fn source(&self, url: String, api_token: String, user_agent: String) -> NativeSource {
        NativeSource::new(HyperSyncSource {
            client: self.client.clone(),
            stream: Arc::new(Sse::new(&url, api_token, user_agent)),
            unauthorized_warned: Arc::new(AtomicBool::new(false)),
        })
    }
}

/// A page as ReScript decodes it into the indexer's items.
#[napi(object, object_from_js = false)]
pub struct HyperSyncItemsPage {
    /// The last block the query accounted for, not necessarily one with an
    /// item.
    pub to_block: i64,
    /// The server's height, 0 when the page was answered without a request.
    pub known_height: i64,
    pub event_items: Vec<EventItem>,
    pub block_items: Vec<BlockItem>,
    pub blocks: BlockStore,
    pub transactions: TransactionStore,
    pub fetch_seconds: f64,
}

struct HyperSyncSource {
    client: Arc<HyperSyncClient>,
    stream: Arc<Sse>,
    /// So a rejected token is reported once rather than on every height retry
    /// for the life of the process.
    unauthorized_warned: Arc<AtomicBool>,
}

impl Source for HyperSyncSource {
    fn get_height(&self) -> BoxFuture<HeightOutcome> {
        let client = self.client.clone();
        let warned = self.unauthorized_warned.clone();
        Box::pin(async move {
            let started = Instant::now();
            let result = client.get_height().await;
            let stats = vec![request_stat("getHeight", started.elapsed().as_secs_f64())];
            match result {
                Ok(height) => HeightOutcome::Answered { height, stats },
                Err(err) => {
                    let alert = unauthorized_alert("HyperSync", &err.reason, &warned);
                    HeightOutcome::Failed {
                        stats,
                        cause: err.reason.clone(),
                        alert,
                    }
                }
            }
        })
    }

    fn get_items(
        &self,
        query: crate::source_manager::source::ItemsQuery,
    ) -> BoxFuture<ItemsOutcome> {
        let client = self.client.clone();
        Box::pin(async move {
            let on_event_registration_indexes = query
                .selection
                .event_registration_indexes_through(query.to_block);
            // A query selecting blocks alone has no logs to end it, so it is
            // bounded by the head.
            let to_block = if on_event_registration_indexes.is_empty() {
                Some(query.to_block.map_or(query.known_height, |to_block| {
                    to_block.min(query.known_height)
                }))
            } else {
                query.to_block
            };
            let attempted_to_block = query.to_block.unwrap_or(query.known_height);
            let params = ItemsQuery {
                from_block: query.from_block,
                to_block,
                items_target: query.items_target.map(i64::from),
                on_event_registration_indexes,
                on_block_registration_indexes: query
                    .selection
                    .on_block_registration_indexes
                    .clone(),
                client_filtered_contracts: query.selection.client_filtered_contracts.clone(),
                reorgable_from: query.reorgable_from,
            };
            let started = Instant::now();
            let result = client.get_items(params, &query.addresses).await;
            let fetch_seconds = started.elapsed().as_secs_f64();
            let fetch_stats = || vec![request_stat("getLogs", fetch_seconds)];
            match result {
                Ok((response, transactions, blocks)) => {
                    // Possible when the height came from another instance.
                    if response.next_block <= query.from_block {
                        return ItemsOutcome::Failed {
                            failure: ItemsFailure::BehindHead {
                                block_number: query.from_block,
                            },
                            stats: fetch_stats(),
                            cause: None,
                        };
                    }
                    let mut stats = fetch_stats();
                    stats[0].response_blocks = Some(response.response_blocks);
                    // None when the page was answered without a request; 0
                    // reports no height, which never lowers a known one.
                    let known_height = response.archive_height.unwrap_or(0);
                    ItemsOutcome::Answered {
                        known_height,
                        stats,
                        inconsistent: Inconsistent::check(blocks.response_conflict(), Vec::new()),
                        page: Box::new(HyperSyncItemsPage {
                            to_block: response.next_block - 1,
                            known_height,
                            event_items: response.event_items,
                            block_items: response.block_items,
                            blocks,
                            transactions,
                            fetch_seconds,
                        }),
                    }
                }
                Err(err) => items_failure(&err, |message| match missing_fields(&message) {
                    Some(fields) => ItemsOutcome::Failed {
                        failure: ItemsFailure::Impossible {
                            message: format!(
                                "Source returned invalid data with missing required fields: {}",
                                fields.join(", ")
                            ),
                            attempted_to_block,
                        },
                        stats: fetch_stats(),
                        cause: None,
                    },
                    None => ItemsOutcome::Failed {
                        failure: ItemsFailure::Backoff {
                            message: "Unexpected issue while fetching events from HyperSync \
                                      client. Attempt a retry."
                                .to_string(),
                            backoff_millis: unexplained_backoff_millis(query.retry),
                            attempted_to_block,
                        },
                        stats: fetch_stats(),
                        cause: Some(message),
                    },
                }),
            }
        })
    }

    fn get_block_hashes(&self, block_numbers: Vec<i64>) -> BoxFuture<HashesOutcome> {
        let client = self.client.clone();
        Box::pin(async move {
            hashes_outcome(
                client.get_block_hashes(block_numbers.clone()).await,
                block_numbers,
            )
        })
    }

    fn height_transport(&self) -> Option<Arc<dyn Transport>> {
        Some(self.stream.clone() as Arc<dyn Transport>)
    }
}
