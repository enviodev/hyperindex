use std::sync::Once;
use std::time::Duration;

use anyhow::{Context, Result};
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

#[napi(object)]
pub struct NapiRateLimitInfo {
    pub remaining: Option<i64>,
    pub reset_secs: Option<i64>,
    pub limit: Option<i64>,
}

fn convert_rate_limit_info(info: &hypersync_client::RateLimitInfo) -> NapiRateLimitInfo {
    NapiRateLimitInfo {
        remaining: info.remaining.map(|v| v as i64),
        reset_secs: info.reset_secs.map(|v| v as i64),
        limit: info.limit.map(|v| v as i64),
    }
}

fn make_rate_limit_err(inner: &hypersync_client::Client, e: anyhow::Error) -> napi::Error {
    if let Some(info) = inner.rate_limit_info() {
        if info.is_rate_limited() {
            let reset_ms = info.suggested_wait_secs().unwrap_or(1) * 1000;
            return napi::Error::from_reason(format!("RATE_LIMITED:{reset_ms}"));
        }
    }
    map_err(e.context("run inner query"))
}

fn make_timeout_or_rate_limit_err(inner: &hypersync_client::Client) -> napi::Error {
    if let Some(info) = inner.rate_limit_info() {
        if info.is_rate_limited() {
            let reset_ms = info.suggested_wait_secs().unwrap_or(1) * 1000;
            return napi::Error::from_reason(format!("RATE_LIMITED:{reset_ms}"));
        }
    }
    map_err(anyhow::anyhow!("request timed out"))
}

/// HyperSync client for querying blockchain data.
#[napi]
pub struct HypersyncClient {
    inner: hypersync_client::Client,
    enable_checksum_addresses: bool,
    // Used to detect when the inner client is stuck sleeping on a 429
    // instead of returning the error promptly.
    http_req_timeout: Duration,
}

#[napi]
impl HypersyncClient {
    #[napi(factory)]
    pub fn new_with_agent(cfg: ClientConfig, user_agent: String) -> napi::Result<HypersyncClient> {
        init_logger(cfg.log_level.as_deref());

        let enable_checksum_addresses = cfg.enable_checksum_addresses.unwrap_or_default();

        let http_req_timeout_millis = cfg.http_req_timeout_millis.filter(|v| *v >= 0).map_or(
            hypersync_client::ClientConfig::default_http_req_timeout_millis(),
            |v| v as u64,
        );

        let inner = hypersync_client::Client::new_with_agent(cfg.into(), user_agent)
            .context("build client")
            .map_err(map_err)?;

        Ok(HypersyncClient {
            inner,
            enable_checksum_addresses,
            http_req_timeout: Duration::from_millis(http_req_timeout_millis),
        })
    }

    #[napi]
    pub async fn get(&self, query: Query) -> napi::Result<QueryResponse> {
        let query = query.try_into().context("parse query").map_err(map_err)?;
        let deadline = self.http_req_timeout + Duration::from_secs(1);
        let res = match tokio::time::timeout(deadline, self.inner.get_with_rate_limit(&query)).await
        {
            Ok(res) => res.map_err(|e| make_rate_limit_err(&self.inner, e))?,
            Err(_) => return Err(make_timeout_or_rate_limit_err(&self.inner)),
        };
        let rate_limit = convert_rate_limit_info(&res.rate_limit);
        convert_response(res.response, self.enable_checksum_addresses, rate_limit)
            .context("convert response")
            .map_err(map_err)
    }

    #[napi]
    pub async fn get_events(&self, query: Query) -> napi::Result<EventResponse> {
        let query = query.try_into().context("parse query").map_err(map_err)?;
        let deadline = self.http_req_timeout + Duration::from_secs(1);
        let res = match tokio::time::timeout(deadline, self.inner.get_events(query)).await {
            Ok(res) => res.map_err(|e| make_rate_limit_err(&self.inner, e))?,
            Err(_) => return Err(make_timeout_or_rate_limit_err(&self.inner)),
        };
        let rate_limit = self
            .inner
            .rate_limit_info()
            .map(|info| convert_rate_limit_info(&info));
        convert_event_response(res, self.enable_checksum_addresses, rate_limit)
            .context("convert response")
            .map_err(map_err)
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
    pub rate_limit: NapiRateLimitInfo,
}

#[napi(object)]
pub struct EventResponse {
    pub archive_height: Option<i64>,
    pub next_block: i64,
    pub total_execution_time: i64,
    pub data: Vec<Event>,
    pub rollback_guard: Option<RollbackGuard>,
    pub rate_limit: Option<NapiRateLimitInfo>,
}

fn convert_response(
    res: hypersync_client::QueryResponse,
    should_checksum: bool,
    rate_limit: NapiRateLimitInfo,
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
        rate_limit,
    })
}

fn convert_event_response(
    resp: hypersync_client::QueryResponse<Vec<hypersync_client::simple_types::Event>>,
    should_checksum: bool,
    rate_limit: Option<NapiRateLimitInfo>,
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
        rate_limit,
    })
}

pub(crate) fn map_err(e: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{:?}", e))
}
