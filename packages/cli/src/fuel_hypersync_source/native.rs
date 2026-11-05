//! The HyperFuel client as a source the manager calls itself, and the napi
//! class ReScript builds it from.

use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::Instant;

use napi_derive::napi;

use super::config::ClientConfig;
use super::selection::FuelOnEventRegistrationInput;
use super::{EventItem, EventItemsQuery, EventItemsResponse, FuelClient, RejectedLogData};
use crate::address_store::{AddressSet, AddressStore};
use crate::block_store::BlockStore;
use crate::source_manager::source::{
    items_failure, missing_fields, request_stat, unauthorized_alert, unexplained_backoff_millis,
    BoxFuture, HashesOutcome, HeightOutcome, ItemsOutcome, ItemsQuery, NativeSource, Source,
};
use crate::source_manager::{HashesFailure, Inconsistent, ItemsFailure};

#[napi]
pub struct FuelHyperSyncClient {
    client: Arc<FuelClient>,
}

#[napi]
impl FuelHyperSyncClient {
    #[napi(factory)]
    pub fn new(
        cfg: ClientConfig,
        user_agent: String,
        event_registrations: Vec<FuelOnEventRegistrationInput>,
        address_store: &AddressStore,
    ) -> napi::Result<FuelHyperSyncClient> {
        Ok(FuelHyperSyncClient {
            client: Arc::new(FuelClient::new(
                cfg,
                user_agent,
                event_registrations,
                address_store,
            )?),
        })
    }

    #[napi]
    pub async fn get_height(&self) -> napi::Result<i64> {
        self.client.get_height().await
    }

    #[napi]
    pub async fn get_event_items(
        &self,
        params: EventItemsQuery,
        address_set: &AddressSet,
    ) -> napi::Result<(EventItemsResponse, BlockStore)> {
        self.client.get_event_items(params, address_set).await
    }

    /// The client as a source the manager calls itself.
    #[napi]
    pub fn source(&self) -> NativeSource {
        NativeSource::new(FuelSource {
            client: self.client.clone(),
            unauthorized_warned: Arc::new(AtomicBool::new(false)),
        })
    }
}

/// A page as ReScript decodes it into the indexer's items. Fuel keeps the
/// transaction inline on each item, so there is no transaction store.
#[napi(object, object_from_js = false)]
pub struct FuelItemsPage {
    /// The last block the query accounted for.
    pub to_block: i64,
    /// The server's height, 0 when it reported none.
    pub known_height: i64,
    pub items: Vec<EventItem>,
    pub rejected_log_data: Vec<RejectedLogData>,
    pub blocks: BlockStore,
    pub fetch_seconds: f64,
}

struct FuelSource {
    client: Arc<FuelClient>,
    /// So a rejected token is reported once rather than on every height retry
    /// for the life of the process.
    unauthorized_warned: Arc<AtomicBool>,
}

impl Source for FuelSource {
    fn get_height(&self) -> BoxFuture<HeightOutcome> {
        let client = self.client.clone();
        let warned = self.unauthorized_warned.clone();
        Box::pin(async move {
            let started = Instant::now();
            let result = client.get_height().await;
            let stats = vec![request_stat("getHeight", started.elapsed().as_secs_f64())];
            match result {
                Ok(height) => HeightOutcome::Answered { height, stats },
                Err(err) => HeightOutcome::Failed {
                    stats,
                    alert: unauthorized_alert("HyperFuel", &err.reason, &warned),
                    cause: err.reason.clone(),
                },
            }
        })
    }

    fn get_items(&self, query: ItemsQuery) -> BoxFuture<ItemsOutcome> {
        let client = self.client.clone();
        Box::pin(async move {
            let params = EventItemsQuery {
                from_block: query.from_block,
                to_block: query.to_block,
                registration_indexes: query
                    .selection
                    .event_registration_indexes_through(query.to_block),
                client_filtered_contracts: query.selection.client_filtered_contracts.clone(),
            };
            let attempted_to_block = query.to_block.unwrap_or(query.known_height);
            let started = Instant::now();
            let result = client.get_event_items(params, &query.addresses).await;
            let fetch_seconds = started.elapsed().as_secs_f64();
            let fetch_stats = || vec![request_stat("getLogs", fetch_seconds)];
            match result {
                // Possible when the height came from another instance.
                Ok((response, _)) if response.next_block <= query.from_block => {
                    ItemsOutcome::Failed {
                        failure: ItemsFailure::BehindHead {
                            block_number: query.from_block,
                        },
                        stats: fetch_stats(),
                        cause: None,
                    }
                }
                Ok((response, blocks)) => {
                    let known_height = response.archive_height.unwrap_or(0);
                    ItemsOutcome::Answered {
                        known_height,
                        stats: fetch_stats(),
                        inconsistent: Inconsistent::check(blocks.response_conflict(), Vec::new()),
                        page: Box::new(FuelItemsPage {
                            to_block: response.next_block - 1,
                            known_height,
                            items: response.items,
                            rejected_log_data: response.rejected_log_data,
                            blocks,
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
                            message: "Unexpected issue while fetching events from HyperFuel \
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

    fn get_block_hashes(&self, _block_numbers: Vec<i64>) -> BoxFuture<HashesOutcome> {
        Box::pin(async {
            HashesOutcome::Failed {
                failure: HashesFailure::Other,
                stats: Vec::new(),
                cause: "HyperFuel does not support getting block hashes".to_string(),
            }
        })
    }
}
