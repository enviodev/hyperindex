//! The RPC client as a source the manager calls itself, and the napi class
//! ReScript builds it from.

use std::sync::Arc;
use std::time::Instant;

use napi_derive::napi;

use super::{
    BlockHashResult, EvmRpcClientConfig, NextPageParams, NextPageResult, PageOutcome, RpcClient,
};
use crate::address_store::{AddressSet, AddressStore};
use crate::block_selection::{BlockItem, OnBlockRegistrationInput};
use crate::block_store::BlockStore;
use crate::evm_hypersync_source::types::OnEventRegistrationInput;
use crate::evm_hypersync_source::EventItem;
use crate::height_stream::{driver::Transport, ws::Ws};
use crate::request_stats::RequestStat;
use crate::source_manager::source::{
    request_stats, BoxFuture, HashesOutcome, HeightOutcome, ItemsOutcome, ItemsQuery, NativeSource,
    Source,
};
use crate::source_manager::{HashesFailure, Inconsistent, ItemsFailure};
use crate::transaction_store::TransactionStore;

#[napi]
pub struct EvmRpcClient {
    client: Arc<RpcClient>,
}

#[napi]
impl EvmRpcClient {
    #[napi(factory)]
    pub fn new(
        cfg: EvmRpcClientConfig,
        event_registrations: Vec<OnEventRegistrationInput>,
        block_registrations: Vec<OnBlockRegistrationInput>,
        checksum_addresses: bool,
        address_store: &AddressStore,
    ) -> napi::Result<EvmRpcClient> {
        Ok(EvmRpcClient {
            client: Arc::new(RpcClient::new(
                cfg,
                event_registrations,
                block_registrations,
                checksum_addresses,
                address_store,
            )?),
        })
    }

    #[napi]
    pub fn on_reorg(&self) {
        self.client.on_reorg();
    }

    #[napi]
    pub async fn get_block_hashes(
        &self,
        block_numbers: Vec<i64>,
    ) -> napi::Result<(BlockHashResult, BlockStore)> {
        self.client.get_block_hashes(block_numbers).await
    }

    #[napi]
    pub async fn get_height(&self) -> napi::Result<(i64, Vec<RequestStat>)> {
        self.client.get_height().await
    }

    #[napi]
    pub async fn get_next_page(
        &self,
        params: NextPageParams,
        address_set: &AddressSet,
        known_blocks: &BlockStore,
        known_transactions: &TransactionStore,
    ) -> napi::Result<(NextPageResult, BlockStore, TransactionStore)> {
        self.client
            .get_next_page(params, address_set, known_blocks, known_transactions)
            .await
    }

    /// The client as a source the manager calls itself. It plans against the
    /// chain's stores, and pushes heights over `ws_url` when there is one.
    #[napi]
    pub fn source(
        &self,
        known_blocks: &BlockStore,
        known_transactions: &TransactionStore,
        ws_url: Option<String>,
    ) -> NativeSource {
        NativeSource::new(RpcSource {
            client: self.client.clone(),
            known_blocks: known_blocks.share(),
            known_transactions: known_transactions.share(),
            ws_url,
        })
    }
}

/// A page as ReScript decodes it into the indexer's items.
#[napi(object, object_from_js = false)]
pub struct RpcItemsPage {
    pub to_block: i64,
    pub event_items: Vec<EventItem>,
    pub block_items: Vec<BlockItem>,
    pub blocks: BlockStore,
    pub transactions: TransactionStore,
    pub fetch_seconds: f64,
}

struct RpcSource {
    client: Arc<RpcClient>,
    known_blocks: BlockStore,
    known_transactions: TransactionStore,
    ws_url: Option<String>,
}

impl Source for RpcSource {
    fn get_height(&self) -> BoxFuture<HeightOutcome> {
        let client = self.client.clone();
        Box::pin(async move {
            let result = client.inner.get_height().await;
            let stats = request_stats(client.inner.take_stats());
            match result.map(i64::try_from) {
                Ok(Ok(height)) => HeightOutcome::Answered { height, stats },
                Ok(Err(_)) => HeightOutcome::Failed {
                    stats,
                    cause: "block height exceeds i64::MAX".to_string(),
                    alert: None,
                },
                Err(err) => HeightOutcome::Failed {
                    stats,
                    cause: err.to_string(),
                    alert: None,
                },
            }
        })
    }

    fn get_items(&self, query: ItemsQuery) -> BoxFuture<ItemsOutcome> {
        let client = self.client.clone();
        let known_blocks = self.known_blocks.share();
        let known_transactions = self.known_transactions.share();
        Box::pin(async move {
            let params = NextPageParams {
                from_block: query.from_block,
                // An RPC page always has an end.
                to_block_ceiling: query.to_block.map_or(query.known_height, |to_block| {
                    to_block.min(query.known_height)
                }),
                partition_id: query.partition_id,
                on_event_registration_indexes: query
                    .selection
                    .event_registration_indexes_through(query.to_block),
                on_block_registration_indexes: query
                    .selection
                    .on_block_registration_indexes
                    .clone(),
                client_filtered_contracts: query.selection.client_filtered_contracts.clone(),
                retry: i64::from(query.retry),
                reorgable_from: query.reorgable_from,
            };
            let started = Instant::now();
            let (result, blocks, transactions) = match client
                .get_next_page(params, &query.addresses, &known_blocks, &known_transactions)
                .await
            {
                Ok(page) => page,
                Err(err) => {
                    return ItemsOutcome::Unexpected {
                        cause: err.reason.clone(),
                    }
                }
            };
            let fetch_seconds = started.elapsed().as_secs_f64();
            items_outcome(
                result,
                blocks,
                transactions,
                query.known_height,
                fetch_seconds,
            )
        })
    }

    fn get_block_hashes(&self, block_numbers: Vec<i64>) -> BoxFuture<HashesOutcome> {
        let client = self.client.clone();
        Box::pin(async move {
            match client.get_block_hashes(block_numbers.clone()).await {
                Ok((
                    BlockHashResult {
                        message: None,
                        request_stats: stats,
                        ..
                    },
                    blocks,
                )) => HashesOutcome::Answered {
                    stats: request_stats(stats),
                    inconsistent: Inconsistent::check(
                        blocks.response_conflict(),
                        blocks.missing_hashes(block_numbers),
                    ),
                    blocks,
                },
                Ok((
                    BlockHashResult {
                        message: Some(message),
                        behind_head_block,
                        request_stats: stats,
                    },
                    _,
                )) => HashesOutcome::Failed {
                    failure: match behind_head_block {
                        Some(block_number) => HashesFailure::BehindHead { block_number },
                        None => HashesFailure::Other,
                    },
                    stats: request_stats(stats),
                    cause: message,
                },
                Err(err) => HashesOutcome::Failed {
                    failure: HashesFailure::Other,
                    stats: Vec::new(),
                    cause: err.reason.clone(),
                },
            }
        })
    }

    fn on_reorg(&self) {
        self.client.on_reorg();
    }

    fn height_transport(&self) -> Option<Arc<dyn Transport>> {
        self.ws_url
            .clone()
            .map(|url| Arc::new(Ws::new(url)) as Arc<dyn Transport>)
    }
}

fn items_outcome(
    result: NextPageResult,
    blocks: BlockStore,
    transactions: TransactionStore,
    known_height: i64,
    fetch_seconds: f64,
) -> ItemsOutcome {
    let stats = request_stats(result.request_stats);
    let attempted_to_block = result.to_block;
    let failure = match result.kind {
        PageOutcome::Ok => {
            return ItemsOutcome::Answered {
                known_height,
                inconsistent: Inconsistent::check(blocks.response_conflict(), Vec::new()),
                stats,
                page: Box::new(RpcItemsPage {
                    to_block: result.to_block,
                    event_items: result.event_items,
                    block_items: result.block_items,
                    blocks,
                    transactions,
                    fetch_seconds,
                }),
            }
        }
        PageOutcome::FieldSelection => match (result.message, result.block_number) {
            (Some(message), Some(block_number)) => Ok(ItemsFailure::FieldSelection {
                message,
                block_number,
            }),
            (None, _) => Err("message"),
            (_, None) => Err("blockNumber"),
        },
        PageOutcome::BehindHead => result
            .block_number
            .map(|block_number| ItemsFailure::BehindHead { block_number })
            .ok_or("blockNumber"),
        PageOutcome::SuggestedToBlock => result
            .retry_to_block
            .map(|to_block| ItemsFailure::SuggestedToBlock {
                to_block,
                attempted_to_block,
            })
            .ok_or("retryToBlock"),
        PageOutcome::Backoff => match (result.message, result.backoff_millis) {
            (Some(message), Some(backoff_millis)) => Ok(ItemsFailure::Backoff {
                message,
                backoff_millis: u32::try_from(backoff_millis).unwrap_or(u32::MAX),
                attempted_to_block,
            }),
            (None, _) => Err("message"),
            (_, None) => Err("backoffMillis"),
        },
    };
    match failure {
        Ok(failure) => ItemsOutcome::Failed {
            // A node behind the head is the whole story.
            cause: match failure {
                ItemsFailure::BehindHead { .. } => None,
                _ => result.provider_message,
            },
            failure,
            stats,
        },
        Err(field) => ItemsOutcome::Unexpected {
            cause: format!(
                "The RPC client returned a \"{:?}\" outcome without a {field}. Please, report \
                 to the Envio team.",
                result.kind
            ),
        },
    }
}
