//! The SVM HyperSync client as a source the manager calls itself, and the
//! napi class ReScript builds it from.

use std::sync::Arc;
use std::time::Instant;

use napi_derive::napi;

use super::config::SvmClientConfig;
use super::selection::SvmProgramInput;
use super::{EventItem, ItemsQuery, ItemsResponse, SvmClient};
use crate::address_store::{AddressSet, AddressStore};
use crate::block_selection::{BlockItem, OnBlockRegistrationInput};
use crate::block_store::BlockStore;
use crate::height_stream::{driver::Transport, sse::Sse};
use crate::request_stats::RequestStat;
use crate::source_manager::source::{
    hashes_outcome, items_failure, request_stat, unexplained_backoff_millis, BoxFuture,
    HashesOutcome, HeightOutcome, ItemsOutcome, NativeSource, Source,
};
use crate::source_manager::{Inconsistent, ItemsFailure};
use crate::transaction_store::TransactionStore;

#[napi]
pub struct SvmHyperSyncClient {
    client: Arc<SvmClient>,
}

#[napi]
impl SvmHyperSyncClient {
    #[napi(factory)]
    pub fn from_config(
        cfg: SvmClientConfig,
        user_agent: String,
        programs: Vec<SvmProgramInput>,
        block_registrations: Vec<OnBlockRegistrationInput>,
        address_store: &AddressStore,
    ) -> napi::Result<SvmHyperSyncClient> {
        Ok(SvmHyperSyncClient {
            client: Arc::new(SvmClient::from_config(
                cfg,
                user_agent,
                programs,
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

    /// The client as a source the manager calls itself, pushing slots over
    /// the server's stream.
    #[napi]
    pub fn source(&self, url: String, api_token: String, user_agent: String) -> NativeSource {
        NativeSource::new(SvmSource {
            client: self.client.clone(),
            stream: Arc::new(Sse::new(&url, api_token, user_agent)),
        })
    }
}

/// A page as ReScript decodes it into the indexer's items.
#[napi(object, object_from_js = false)]
pub struct SvmItemsPage {
    /// The last slot the query accounted for.
    pub to_block: i64,
    pub event_items: Vec<EventItem>,
    pub block_items: Vec<BlockItem>,
    pub blocks: BlockStore,
    pub transactions: TransactionStore,
    pub fetch_seconds: f64,
}

struct SvmSource {
    client: Arc<SvmClient>,
    stream: Arc<Sse>,
}

/// What a query asks the client for: its range and what its selection can
/// match there.
fn items_params(query: &crate::source_manager::source::ItemsQuery) -> ItemsQuery {
    let on_event_registration_indexes = query
        .selection
        .event_registration_indexes_through(query.to_block);
    // A query selecting slots alone has no instructions to end it, so it is
    // bounded by the head.
    let to_slot = if on_event_registration_indexes.is_empty() {
        Some(query.to_block.map_or(query.known_height, |to_block| {
            to_block.min(query.known_height)
        }))
    } else {
        query.to_block
    };
    ItemsQuery {
        from_slot: query.from_block,
        to_slot,
        items_target: query.items_target.map(i64::from),
        on_event_registration_indexes,
        on_block_registration_indexes: query.selection.on_block_registration_indexes.clone(),
        client_filtered_contracts: query.selection.client_filtered_contracts.clone(),
        reorgable_from: query.reorgable_from,
    }
}

impl Source for SvmSource {
    fn get_height(&self) -> BoxFuture<HeightOutcome> {
        let client = self.client.clone();
        Box::pin(async move {
            let started = Instant::now();
            let result = client.get_height().await;
            let stats = vec![request_stat("getHeight", started.elapsed().as_secs_f64())];
            match result {
                Ok(height) => HeightOutcome::Answered { height, stats },
                Err(err) => HeightOutcome::Failed {
                    stats,
                    cause: err.reason.clone(),
                    alert: None,
                },
            }
        })
    }

    fn get_items(
        &self,
        query: crate::source_manager::source::ItemsQuery,
    ) -> BoxFuture<ItemsOutcome> {
        let client = self.client.clone();
        Box::pin(async move {
            let params = items_params(&query);
            let attempted_to_block = query.to_block.unwrap_or(query.known_height);
            let started = Instant::now();
            let result = client.get_items(params, &query.addresses).await;
            let fetch_seconds = started.elapsed().as_secs_f64();
            let fetch_stats = || vec![request_stat("getInstructions", fetch_seconds)];
            match result {
                Ok((response, transactions, blocks)) => ItemsOutcome::Answered {
                    known_height: query.known_height,
                    stats: fetch_stats(),
                    inconsistent: Inconsistent::check(blocks.response_conflict(), Vec::new()),
                    page: Box::new(SvmItemsPage {
                        to_block: response.next_slot - 1,
                        event_items: response.event_items,
                        block_items: response.block_items,
                        blocks,
                        transactions,
                        fetch_seconds,
                    }),
                },
                Err(err) => items_failure(&err, |message| ItemsOutcome::Failed {
                    failure: ItemsFailure::Backoff {
                        message: "Unexpected issue while fetching instructions from SVM \
                                  HyperSync. Attempt a retry."
                            .to_string(),
                        backoff_millis: unexplained_backoff_millis(query.retry),
                        attempted_to_block,
                    },
                    stats: fetch_stats(),
                    cause: Some(message),
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::address_store::AddressStore;
    use crate::source_manager::source::{EventRegistration, Selection};

    fn query(
        to_block: Option<i64>,
        reorgable_from: Option<i64>,
        on_event_registrations: Vec<EventRegistration>,
    ) -> crate::source_manager::source::ItemsQuery {
        crate::source_manager::source::ItemsQuery {
            from_block: 90,
            to_block,
            known_height: 1000,
            reorgable_from,
            partition_id: "0".to_string(),
            selection: Arc::new(Selection {
                on_event_registrations,
                on_block_registration_indexes: vec![3],
                client_filtered_contracts: Some(vec!["TokenMetadata".to_string()]),
            }),
            items_target: Some(5000),
            retry: 0,
            addresses: AddressStore::new_svm(Vec::new()).unwrap().empty_set(),
        }
    }

    fn shape(params: ItemsQuery) -> serde_json::Value {
        serde_json::json!({
            "fromSlot": params.from_slot,
            "toSlot": params.to_slot,
            "itemsTarget": params.items_target,
            "onEventRegistrationIndexes": params.on_event_registration_indexes,
            "onBlockRegistrationIndexes": params.on_block_registration_indexes,
            "reorgableFrom": params.reorgable_from,
        })
    }

    #[test]
    fn asks_for_the_inclusive_range_and_what_can_match_in_it() {
        let registrations = vec![
            EventRegistration {
                index: 0,
                start_block: None,
            },
            EventRegistration {
                index: 1,
                start_block: Some(200),
            },
        ];
        assert_eq!(
            shape(items_params(&query(Some(110), Some(100), registrations))),
            serde_json::json!({
                "fromSlot": 90,
                "toSlot": 110,
                "itemsTarget": 5000,
                "onEventRegistrationIndexes": [0],
                "onBlockRegistrationIndexes": [3],
                "reorgableFrom": 100,
            })
        );
    }

    #[test]
    fn bounds_a_slots_only_query_by_the_head() {
        assert_eq!(
            [None, Some(2000), Some(500)].map(|to_block| items_params(&query(
                to_block,
                None,
                Vec::new()
            ))
            .to_slot),
            [Some(1000), Some(1000), Some(500)]
        );
    }
}
