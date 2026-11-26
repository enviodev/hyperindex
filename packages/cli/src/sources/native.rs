//! The one napi class every production source is. It owns a client, times
//! its requests, and says what each client error means for the caller as a
//! `SourceFailure`; nothing a caller is expected to handle crosses as an
//! exception.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

use napi_derive::napi;
use serde_json::json;

use super::evm_hypersync::{self, config::SerializationFormat, EvmHyperSyncClient};
use super::evm_rpc::{EvmRpcClient, EvmRpcClientConfig, NextPageParams};
use super::failure::{ClientError, SourceFailure};
use super::fuel_hypersync::{self, FuelHyperSyncClient};
use super::request_stats::RequestStat;
use super::svm_hypersync::{self, SvmHyperSyncClient};
use crate::address_store::AddressSet;
use crate::chain_buffer::page::Page;
use crate::chain_buffer::{ChainBuffer, Ecosystem};
use crate::logger::{BoundLogger, Level, Logger};

/// How often a HyperSync source is asked for the height while nothing is
/// pushing one: short enough that a chain at the head isn't held up behind
/// it, long enough that waiting out a block isn't thousands of requests.
const HYPERSYNC_POLLING_INTERVAL_MILLIS: u32 = 400;

const MISSING_API_TOKEN: &str =
    "An Envio API token is required for using HyperSync as a data-source.
Set the ENVIO_API_TOKEN environment variable in your .env file.
Learn more or get a free Envio API token at: https://envio.dev/app/api-tokens";

#[napi(string_enum)]
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum SourceFor {
    Sync,
    Fallback,
    Realtime,
}

/// `Config.hyperSync`.
#[napi(object)]
pub struct HyperSyncOptions {
    pub url: String,
    pub api_token: Option<String>,
    pub http_req_timeout_millis: u32,
    pub serialization_format: SerializationFormat,
    pub enable_query_caching: bool,
    /// RUST_LOG when set, else the configured level.
    pub log_filter: String,
}

/// `Config.sourceSyncOptions`: what config.yaml set, with environment
/// overrides applied. Defaults are filled in here.
#[napi(object)]
pub struct RpcSyncOptions {
    pub initial_block_interval: Option<u32>,
    pub backoff_multiplicative: Option<f64>,
    pub acceleration_additive: Option<u32>,
    pub interval_ceiling: Option<u32>,
    pub backoff_millis: Option<u32>,
    pub query_timeout_millis: Option<u32>,
    pub polling_interval: Option<u32>,
}

#[napi(object)]
pub struct RpcOptions {
    pub url: String,
    pub source_for: SourceFor,
    pub ws: Option<String>,
    pub headers: Option<HashMap<String, String>>,
    pub sync_config: RpcSyncOptions,
}

#[napi(object)]
pub struct ChainSourcesConfig {
    pub chain_id: i64,
    pub ecosystem: String,
    pub hyper_sync: Option<HyperSyncOptions>,
    pub rpcs: Vec<RpcOptions>,
    /// How many addresses one `eth_getLogs` may carry when an address-free
    /// read is asked again by address.
    pub max_addresses_per_request: u32,
    pub user_agent: String,
}

/// Where a source's pushed heights come from. The transports still live in
/// JS.
#[napi(discriminant = "kind")]
#[derive(Clone)]
pub enum HeightSubscriptionTarget {
    HyperSyncSse { url: String, api_token: String },
    RpcWs { url: String },
}

#[napi(object)]
pub struct ItemsQuery {
    pub from_block: u32,
    /// Inclusive. Absent asks for everything the backend has from
    /// `from_block` on.
    pub to_block: Option<u32>,
    pub partition_id: String,
    pub on_event_registration_indexes: Vec<u32>,
    pub on_block_registration_indexes: Vec<u32>,
    pub on_transaction_registration_indexes: Vec<u32>,
    /// Contract names fetched address-free though their registrations depend
    /// on addresses.
    pub client_filtered_contracts: Option<Vec<String>>,
    pub retry: u32,
    pub reorgable_from: Option<u32>,
    pub known_height: u32,
}

#[napi(discriminant = "kind")]
pub enum HeightAnswer {
    Height {
        height: u32,
        request_stats: Vec<RequestStat>,
    },
    Failed {
        failure: SourceFailure,
        request_stats: Vec<RequestStat>,
    },
}

// An answer lives for one call and is handed straight to JavaScript, so the
// page is kept by value rather than boxed.
#[allow(clippy::large_enum_variant)]
#[napi(discriminant = "kind", object_from_js = false)]
pub enum ItemsAnswer {
    Fetched {
        page: Page,
        latest_fetched_block_number: u32,
        known_height: Option<u32>,
        request_stats: Vec<RequestStat>,
    },
    Failed {
        failure: SourceFailure,
        request_stats: Vec<RequestStat>,
    },
}

#[allow(clippy::large_enum_variant)]
#[napi(discriminant = "kind", object_from_js = false)]
pub enum BlockHashesAnswer {
    Hashes {
        page: Page,
        request_stats: Vec<RequestStat>,
    },
    Failed {
        failure: SourceFailure,
        request_stats: Vec<RequestStat>,
    },
}

enum SourceClient {
    EvmHyperSync(EvmHyperSyncClient),
    EvmRpc(Box<EvmRpcClient>),
    FuelHyperSync(FuelHyperSyncClient),
    SvmHyperSync(SvmHyperSyncClient),
}

#[napi]
pub struct NativeSource {
    client: SourceClient,
    name: String,
    source_for: SourceFor,
    polling_interval: u32,
    height_subscription: Option<HeightSubscriptionTarget>,
    logger: BoundLogger,
    /// A rejected token is said once per source, not on every retry for the
    /// life of the process.
    warned_unauthorized: AtomicBool,
}

fn block_u32(block: impl TryInto<u32>) -> u32 {
    block.try_into().unwrap_or(u32::MAX)
}

fn indexes(indexes: &[u32]) -> Vec<i64> {
    indexes.iter().copied().map(i64::from).collect()
}

/// The host of an http(s) url, which names an RPC source without leaking a
/// key that rides in its path or query.
fn url_host(url: &str) -> Option<&str> {
    let rest = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))?;
    let host = rest.split(['/', '?']).next().unwrap_or_default();
    (!host.is_empty()).then_some(host)
}

fn timed(method: &str, started: Instant) -> RequestStat {
    RequestStat::new(method, started.elapsed().as_secs_f64())
}

#[napi]
impl NativeSource {
    /// Every source a chain's config names, HyperSync first.
    #[napi]
    pub fn make_chain_sources(
        config: ChainSourcesConfig,
        buffer: &ChainBuffer,
        logger: &Logger,
        bound_fields_json: Vec<String>,
    ) -> napi::Result<Vec<NativeSource>> {
        make_chain_sources(config, buffer, logger, bound_fields_json)
            .map_err(|error| napi::Error::from_reason(format!("{error:#}")))
    }

    #[napi(getter)]
    pub fn name(&self) -> String {
        self.name.clone()
    }

    #[napi(getter)]
    pub fn source_for(&self) -> SourceFor {
        self.source_for
    }

    #[napi(getter)]
    pub fn polling_interval(&self) -> u32 {
        self.polling_interval
    }

    #[napi(getter)]
    pub fn powered_by_hyper_sync(&self) -> bool {
        !matches!(self.client, SourceClient::EvmRpc(_))
    }

    /// HyperFuel can't read block hashes, and Fuel never rolls back.
    #[napi(getter)]
    pub fn can_read_block_hashes(&self) -> bool {
        !matches!(self.client, SourceClient::FuelHyperSync(_))
    }

    #[napi(getter)]
    pub fn height_subscription(&self) -> Option<HeightSubscriptionTarget> {
        self.height_subscription.clone()
    }

    #[napi]
    pub fn on_reorg(&self) {
        if let SourceClient::EvmRpc(client) = &self.client {
            client.on_reorg();
        }
    }

    #[napi]
    pub async fn get_height(&self) -> HeightAnswer {
        let started = Instant::now();
        let (result, request_stats) = match &self.client {
            SourceClient::EvmRpc(client) => client.get_height().await,
            SourceClient::EvmHyperSync(client) => {
                (client.get_height().await, vec![timed("getHeight", started)])
            }
            SourceClient::FuelHyperSync(client) => {
                (client.get_height().await, vec![timed("getHeight", started)])
            }
            SourceClient::SvmHyperSync(client) => {
                (client.get_height().await, vec![timed("getHeight", started)])
            }
        };
        match result {
            Ok(height) => HeightAnswer::Height {
                height: block_u32(height),
                request_stats,
            },
            Err(error) => {
                self.warn_once_if_unauthorized(&error);
                HeightAnswer::Failed {
                    failure: describe(error, backoff),
                    request_stats,
                }
            }
        }
    }

    #[napi]
    pub async fn get_items(
        &self,
        query: ItemsQuery,
        address_set: &AddressSet,
        buffer: &ChainBuffer,
    ) -> napi::Result<ItemsAnswer> {
        let started = Instant::now();
        let from_block = i64::from(query.from_block);
        // A page that ends where it began came from a replica that hasn't
        // reached the range.
        let behind_head_unless_advanced = |next_block: i64, page: Page, known_height, stats| {
            if next_block <= from_block {
                ItemsAnswer::Failed {
                    failure: SourceFailure::BehindHead {
                        block_number: query.from_block,
                    },
                    request_stats: stats,
                }
            } else {
                ItemsAnswer::Fetched {
                    page,
                    latest_fetched_block_number: block_u32(next_block - 1),
                    known_height,
                    request_stats: stats,
                }
            }
        };
        let hypersync_failure = |product: &'static str| {
            move |message: String| {
                SourceFailure::Backoff {
                    message: format!(
                        "Unexpected issue while fetching events from {product} client. Attempt a retry."
                    ),
                    backoff_millis: None,
                    cause: Some(message),
                }
            }
        };
        Ok(match &self.client {
            SourceClient::EvmHyperSync(client) => {
                let params = evm_hypersync::ItemsQuery {
                    from_block,
                    to_block: query.to_block.map(i64::from),
                    on_event_registration_indexes: indexes(&query.on_event_registration_indexes),
                    on_block_registration_indexes: indexes(&query.on_block_registration_indexes),
                    on_transaction_registration_indexes: indexes(
                        &query.on_transaction_registration_indexes,
                    ),
                    client_filtered_contracts: query.client_filtered_contracts,
                    reorgable_from: query.reorgable_from.map(i64::from),
                };
                match client.get_items(params, address_set, buffer).await {
                    Ok((response, page)) => {
                        let stat = RequestStat {
                            response_blocks: Some(response.response_blocks),
                            ..timed("getLogs", started)
                        };
                        behind_head_unless_advanced(
                            response.next_block,
                            page,
                            response.archive_height.map(block_u32),
                            vec![stat],
                        )
                    }
                    Err(error) => ItemsAnswer::Failed {
                        failure: describe(error, hypersync_failure("HyperSync")),
                        request_stats: vec![timed("getLogs", started)],
                    },
                }
            }
            SourceClient::FuelHyperSync(client) => {
                let params = fuel_hypersync::EventItemsQuery {
                    from_block,
                    to_block: query.to_block.map(i64::from),
                    registration_indexes: indexes(&query.on_event_registration_indexes),
                    client_filtered_contracts: query.client_filtered_contracts,
                };
                match client.get_event_items(params, address_set).await {
                    Ok((response, page)) => behind_head_unless_advanced(
                        response.next_block,
                        page,
                        response.archive_height.map(block_u32),
                        vec![timed("getLogs", started)],
                    ),
                    Err(error) => ItemsAnswer::Failed {
                        failure: describe(error, hypersync_failure("HyperFuel")),
                        request_stats: vec![timed("getLogs", started)],
                    },
                }
            }
            SourceClient::SvmHyperSync(client) => {
                let params = svm_hypersync::ItemsQuery {
                    from_slot: from_block,
                    to_slot: query.to_block.map(i64::from),
                    on_event_registration_indexes: indexes(&query.on_event_registration_indexes),
                    on_block_registration_indexes: indexes(&query.on_block_registration_indexes),
                    reorgable_from: query.reorgable_from.map(i64::from),
                };
                match client.get_items(params).await {
                    Ok((response, page)) => ItemsAnswer::Fetched {
                        page,
                        latest_fetched_block_number: block_u32(response.next_slot - 1),
                        known_height: None,
                        request_stats: vec![timed("getInstructions", started)],
                    },
                    Err(error) => ItemsAnswer::Failed {
                        failure: describe(error, |message| SourceFailure::Backoff {
                            message: "Unexpected issue while fetching instructions from SVM \
                                      HyperSync. Attempt a retry."
                                .to_string(),
                            backoff_millis: None,
                            cause: Some(message),
                        }),
                        request_stats: vec![timed("getInstructions", started)],
                    },
                }
            }
            SourceClient::EvmRpc(client) => {
                let known_height = u64::from(query.known_height);
                let params = NextPageParams {
                    from_block: u64::from(query.from_block),
                    // An RPC page always has an end, and none past the head.
                    to_block_ceiling: query.to_block.map_or(known_height, |to_block| {
                        u64::from(to_block).min(known_height)
                    }),
                    partition_id: query.partition_id,
                    on_event_registration_indexes: indexes(&query.on_event_registration_indexes),
                    on_block_registration_indexes: indexes(&query.on_block_registration_indexes),
                    on_transaction_registration_indexes: indexes(
                        &query.on_transaction_registration_indexes,
                    ),
                    client_filtered_contracts: query.client_filtered_contracts,
                    retry: i64::from(query.retry),
                    reorgable_from: query.reorgable_from.map(u64::from),
                    known_height,
                };
                let (result, page) = client
                    .get_next_page(params, address_set, buffer)
                    .await
                    .map_err(|error| napi::Error::from_reason(format!("{error:#}")))?;
                match result.result {
                    Ok(()) => ItemsAnswer::Fetched {
                        page,
                        latest_fetched_block_number: block_u32(result.to_block),
                        known_height: None,
                        request_stats: result.request_stats,
                    },
                    Err(failure) => ItemsAnswer::Failed {
                        failure,
                        request_stats: result.request_stats,
                    },
                }
            }
        })
    }

    #[napi]
    pub async fn get_block_hashes(&self, block_numbers: Vec<u32>) -> BlockHashesAnswer {
        let (result, request_stats) = match &self.client {
            SourceClient::EvmHyperSync(client) => client.get_block_hashes(&block_numbers).await,
            SourceClient::SvmHyperSync(client) => client.get_block_hashes(&block_numbers).await,
            SourceClient::EvmRpc(client) => client.get_block_hashes(&block_numbers).await,
            SourceClient::FuelHyperSync(_) => (
                Err(ClientError::Other(anyhow::anyhow!(
                    "HyperFuel does not support getting block hashes"
                ))),
                Vec::new(),
            ),
        };
        match result {
            Ok(page) => BlockHashesAnswer::Hashes {
                page,
                request_stats,
            },
            Err(error) => BlockHashesAnswer::Failed {
                failure: describe(error, backoff),
                request_stats,
            },
        }
    }
}

impl NativeSource {
    fn warn_once_if_unauthorized(&self, error: &ClientError) {
        let ClientError::Other(error) = error else {
            return;
        };
        if !format!("{error:#}").contains("401 Unauthorized")
            || self.warned_unauthorized.swap(true, Ordering::Relaxed)
        {
            return;
        }
        let product = match self.client {
            SourceClient::FuelHyperSync(_) => "HyperFuel",
            _ => "HyperSync",
        };
        self.logger.log(
            Level::ERROR,
            &format!(
                "Your ENVIO_API_TOKEN was rejected by {product} (401 Unauthorized). The indexer \
                 will not be able to fetch events. Update the token and try again using 'envio \
                 start' or 'envio dev'. For more info: https://docs.envio.dev/docs/HyperSync/api-tokens"
            ),
            &json!({}),
        );
    }
}

/// Retry an error nothing classified, with the caller's schedule.
fn backoff(message: String) -> SourceFailure {
    SourceFailure::Backoff {
        message,
        backoff_millis: None,
        cause: None,
    }
}

/// What a client error means for the caller. `other` describes an error the
/// client couldn't classify, from its message.
fn describe(error: ClientError, other: impl FnOnce(String) -> SourceFailure) -> SourceFailure {
    match error {
        ClientError::RateLimited { reset_ms } => SourceFailure::RateLimited {
            reset_ms: block_u32(reset_ms),
        },
        ClientError::BehindHead { block_number } => SourceFailure::BehindHead {
            block_number: block_u32(block_number),
        },
        ClientError::MissingFields(fields) => SourceFailure::WrongSourceForQuery {
            message: format!(
                "Source returned invalid data with missing required fields: {}",
                fields.join(", ")
            ),
            cause: None,
        },
        ClientError::Other(error) => other(format!("{error:#}")),
    }
}

fn make_chain_sources(
    config: ChainSourcesConfig,
    buffer: &ChainBuffer,
    logger: &Logger,
    bound_fields_json: Vec<String>,
) -> anyhow::Result<Vec<NativeSource>> {
    let ecosystem = Ecosystem::parse(&config.ecosystem)?;
    let bind = |source: &str| {
        let mut fields = bound_fields_json.clone();
        fields.push(json!({ "source": source }).to_string());
        logger.bind(fields)
    };
    let mut sources = Vec::new();
    if let Some(hyper_sync) = config.hyper_sync {
        let api_token = hyper_sync
            .api_token
            .ok_or_else(|| anyhow::anyhow!(MISSING_API_TOKEN))?;
        let http_req_timeout_millis = u64::from(hyper_sync.http_req_timeout_millis);
        let (name, client, streams) = match ecosystem {
            Ecosystem::Evm => (
                "HyperSync",
                SourceClient::EvmHyperSync(EvmHyperSyncClient::new(
                    evm_hypersync::ClientConfig {
                        url: hyper_sync.url.clone(),
                        api_token: api_token.clone(),
                        http_req_timeout_millis,
                        serialization_format: hyper_sync.serialization_format,
                        enable_query_caching: hyper_sync.enable_query_caching,
                        log_filter: hyper_sync.log_filter.clone(),
                    },
                    config.user_agent.clone(),
                    buffer,
                )?),
                true,
            ),
            Ecosystem::Fuel => (
                "HyperFuel",
                SourceClient::FuelHyperSync(FuelHyperSyncClient::new(
                    fuel_hypersync::ClientConfig {
                        url: hyper_sync.url.clone(),
                        api_token: api_token.clone(),
                        http_req_timeout_millis,
                    },
                    config.user_agent.clone(),
                    buffer,
                )?),
                false,
            ),
            Ecosystem::Svm => (
                "SvmHyperSync",
                SourceClient::SvmHyperSync(SvmHyperSyncClient::new(
                    svm_hypersync::SvmClientConfig {
                        url: hyper_sync.url.clone(),
                        api_token: api_token.clone(),
                        http_req_timeout_millis,
                    },
                    config.user_agent.clone(),
                    buffer,
                )?),
                true,
            ),
        };
        sources.push(NativeSource {
            client,
            name: name.to_string(),
            source_for: SourceFor::Sync,
            polling_interval: HYPERSYNC_POLLING_INTERVAL_MILLIS,
            height_subscription: streams.then_some(HeightSubscriptionTarget::HyperSyncSse {
                url: hyper_sync.url,
                api_token,
            }),
            logger: bind(name),
            warned_unauthorized: AtomicBool::new(false),
        });
    }
    if ecosystem == Ecosystem::Evm {
        for rpc in config.rpcs {
            let host = url_host(&rpc.url).ok_or_else(|| {
                anyhow::anyhow!(
                    "The RPC url for chain {} is in incorrect format. The RPC url needs to start \
                     with either http:// or https://",
                    config.chain_id
                )
            })?;
            let name = format!("RPC ({host})");
            let sync = rpc.sync_config;
            let client = EvmRpcClient::new(
                EvmRpcClientConfig {
                    url: rpc.url,
                    max_concurrent_requests: None,
                    headers: rpc.headers,
                    initial_block_interval: i64::from(
                        sync.initial_block_interval.unwrap_or(10_000),
                    ),
                    backoff_multiplicative: sync.backoff_multiplicative.unwrap_or(0.8),
                    acceleration_additive: i64::from(sync.acceleration_additive.unwrap_or(500)),
                    interval_ceiling: i64::from(sync.interval_ceiling.unwrap_or(10_000)),
                    backoff_millis: i64::from(sync.backoff_millis.unwrap_or(2_000)),
                    query_timeout_millis: i64::from(sync.query_timeout_millis.unwrap_or(20_000)),
                    max_addresses_per_request: i64::from(config.max_addresses_per_request),
                },
                buffer,
                logger,
                bound_fields_json.clone(),
            )?;
            sources.push(NativeSource {
                client: SourceClient::EvmRpc(Box::new(client)),
                source_for: rpc.source_for,
                polling_interval: sync.polling_interval.unwrap_or(1_000),
                height_subscription: rpc.ws.map(|url| HeightSubscriptionTarget::RpcWs { url }),
                logger: bind(&name),
                name,
                warned_unauthorized: AtomicBool::new(false),
            });
        }
    }
    Ok(sources)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_rpc_source_is_named_by_its_host_alone() {
        assert_eq!(
            [
                url_host("https://eth.rpc.hypersync.xyz?api_key=123"),
                url_host("http://127.0.0.1:8545/v1/key"),
                url_host("ws://127.0.0.1:8545"),
                url_host("https://"),
            ],
            [
                Some("eth.rpc.hypersync.xyz"),
                Some("127.0.0.1:8545"),
                None,
                None
            ]
        );
    }

    #[test]
    fn a_client_error_is_described_by_its_kind() {
        let failures = [
            describe(ClientError::RateLimited { reset_ms: 2_000 }, backoff),
            describe(ClientError::BehindHead { block_number: 7 }, backoff),
            describe(
                ClientError::MissingFields(vec!["block.timestamp".to_string()]),
                backoff,
            ),
            describe(ClientError::Other(anyhow::anyhow!("boom")), backoff),
        ];
        assert_eq!(
            failures,
            [
                SourceFailure::RateLimited { reset_ms: 2_000 },
                SourceFailure::BehindHead { block_number: 7 },
                SourceFailure::WrongSourceForQuery {
                    message: "Source returned invalid data with missing required fields: \
                              block.timestamp"
                        .to_string(),
                    cause: None,
                },
                SourceFailure::Backoff {
                    message: "boom".to_string(),
                    backoff_millis: None,
                    cause: None,
                },
            ]
        );
    }
}
