use std::sync::{Mutex, Once};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use hypersync_client::RateLimitInfo;
use napi_derive::napi;

mod config;
mod decode;
mod query;
mod types;

use config::ClientConfig;
use query::Query;
use types::{Block, Event, Log, RollbackGuard, Transaction};

static LOGGER_INIT: Once = Once::new();

fn init_logger(log_level: Option<&str>) {
    LOGGER_INIT.call_once(|| {
        if std::env::var("RUST_LOG").is_ok() {
            env_logger::init();
        } else if let Some(filter) = log_level {
            env_logger::Builder::new().parse_filters(filter).init();
        }
    });
}

/// HyperSync client for querying blockchain data.
#[napi]
pub struct HypersyncClient {
    inner: hypersync_client::Client,
    enable_checksum_addresses: bool,
    rate_limit_state: Mutex<Option<(RateLimitInfo, Instant)>>,
}

#[napi]
impl HypersyncClient {
    #[napi(factory)]
    pub fn new_with_agent(cfg: ClientConfig, user_agent: String) -> napi::Result<HypersyncClient> {
        init_logger(cfg.log_level.as_deref());

        let enable_checksum_addresses = cfg.enable_checksum_addresses.unwrap_or_default();

        let inner = hypersync_client::Client::new_with_agent(cfg.into(), user_agent)
            .context("build client")
            .map_err(map_err)?;

        Ok(HypersyncClient {
            inner,
            enable_checksum_addresses,
            rate_limit_state: Mutex::new(None),
        })
    }

    #[napi]
    pub async fn get(&self, query: Query) -> napi::Result<QueryResponse> {
        self.wait_for_rate_limit().await;
        let query = query.try_into().context("parse query").map_err(map_err)?;
        let res = self
            .inner
            .get(&query)
            .await
            .context("run inner query")
            .map_err(map_err)?;
        self.save_rate_limit_state();
        convert_response(res, self.enable_checksum_addresses)
            .context("convert response")
            .map_err(map_err)
    }

    #[napi]
    pub async fn get_events(&self, query: Query) -> napi::Result<EventResponse> {
        self.wait_for_rate_limit().await;
        let query = query.try_into().context("parse query").map_err(map_err)?;
        let res = self
            .inner
            .get_events(query)
            .await
            .context("run inner query")
            .map_err(map_err)?;
        self.save_rate_limit_state();
        convert_event_response(res, self.enable_checksum_addresses)
            .context("convert response")
            .map_err(map_err)
    }
}

impl HypersyncClient {
    fn save_rate_limit_state(&self) {
        if let Some(info) = self.inner.rate_limit_info() {
            if info.limit.is_some() || info.remaining.is_some() || info.reset_secs.is_some() {
                *self.rate_limit_state.lock().unwrap() = Some((info, Instant::now()));
            }
        }
    }

    async fn wait_for_rate_limit(&self) {
        let wait = {
            let state = self.rate_limit_state.lock().unwrap();
            state.as_ref().and_then(|(info, captured_at)| {
                if info.is_rate_limited() {
                    info.suggested_wait_secs().map(|secs| {
                        let elapsed = captured_at.elapsed().as_secs();
                        (secs.saturating_sub(elapsed), info.clone())
                    })
                } else {
                    None
                }
            })
        };
        if let Some((secs, info)) = wait {
            if secs > 0 {
                log::warn!(
                    "rate limit exhausted ({info}), proactively waiting {secs}s for window reset. \
                     To increase your rate limits, upgrade your plan at https://app.envio.dev/api-tokens. \
                     For more info: https://docs.envio.dev/docs/HyperSync/api-tokens"
                );
                tokio::time::sleep(Duration::from_secs(secs)).await;
            }
        }
    }
}

#[napi(object)]
pub struct QueryResponseData {
    pub blocks: Vec<Block>,
    pub transactions: Vec<Transaction>,
    pub logs: Vec<Log>,
}

#[napi(object)]
pub struct QueryResponse {
    pub archive_height: Option<i64>,
    pub next_block: i64,
    pub total_execution_time: i64,
    pub data: QueryResponseData,
    pub rollback_guard: Option<RollbackGuard>,
}

#[napi(object)]
pub struct EventResponse {
    pub archive_height: Option<i64>,
    pub next_block: i64,
    pub total_execution_time: i64,
    pub data: Vec<Event>,
    pub rollback_guard: Option<RollbackGuard>,
}

fn convert_response(
    res: hypersync_client::QueryResponse,
    should_checksum: bool,
) -> Result<QueryResponse> {
    let blocks = res
        .data
        .blocks
        .into_iter()
        .flatten()
        .map(|b| Block::from_simple(&b, should_checksum))
        .collect::<Result<Vec<_>>>()
        .context("mapping blocks")?;

    let transactions = res
        .data
        .transactions
        .into_iter()
        .flatten()
        .map(|tx| Transaction::from_simple(&tx, should_checksum))
        .collect::<Result<Vec<_>>>()
        .context("mapping transactions")?;

    let logs = res
        .data
        .logs
        .into_iter()
        .flatten()
        .map(|l| Log::from_simple(&l, should_checksum))
        .collect::<Result<Vec<_>>>()
        .context("mapping logs")?;

    Ok(QueryResponse {
        archive_height: res
            .archive_height
            .map(|h| h.try_into())
            .transpose()
            .context("convert height")?,
        next_block: res.next_block.try_into().context("convert next_block")?,
        total_execution_time: res
            .total_execution_time
            .try_into()
            .context("convert total_execution_time")?,
        data: QueryResponseData {
            blocks,
            transactions,
            logs,
        },
        rollback_guard: res
            .rollback_guard
            .map(RollbackGuard::try_from)
            .transpose()
            .context("convert rollback guard")?,
    })
}

fn convert_event_response(
    resp: hypersync_client::QueryResponse<Vec<hypersync_client::simple_types::Event>>,
    should_checksum: bool,
) -> Result<EventResponse> {
    let data = resp
        .data
        .into_iter()
        .map(|event| {
            Ok(Event {
                transaction: event
                    .transaction
                    .map(|v| Transaction::from_simple(&v, should_checksum))
                    .transpose()
                    .context("mapping transaction")?,
                block: event
                    .block
                    .map(|v| Block::from_simple(&v, should_checksum))
                    .transpose()
                    .context("mapping block")?,
                log: Log::from_simple(&event.log, should_checksum).context("mapping log")?,
            })
        })
        .collect::<Result<Vec<_>>>()
        .context("mapping response data")?;

    Ok(EventResponse {
        archive_height: resp
            .archive_height
            .map(|v| v.try_into())
            .transpose()
            .context("mapping archive_height")?,
        next_block: resp.next_block.try_into().context("mapping next_block")?,
        total_execution_time: resp
            .total_execution_time
            .try_into()
            .context("mapping total_execution_time")?,
        data,
        rollback_guard: resp
            .rollback_guard
            .map(|rg| RollbackGuard::try_from(rg).context("convert rollback guard"))
            .transpose()?,
    })
}

pub(crate) fn map_err(e: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{:?}", e))
}
