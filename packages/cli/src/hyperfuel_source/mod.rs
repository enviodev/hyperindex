use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use napi_derive::napi;

mod config;
mod parse;
mod query;
mod types;

use config::ClientConfig;
use query::Query;
use types::{convert_response, ConvertError, QueryResponse};

#[napi]
pub struct HyperfuelClient {
    http: reqwest::Client,
    url: String,
    bearer_token: Option<String>,
}

#[napi]
impl HyperfuelClient {
    #[napi(factory)]
    pub fn new(cfg: ClientConfig, user_agent: String) -> napi::Result<HyperfuelClient> {
        // The hyperfuel-client crate's Client supports neither custom user
        // agents nor authorized /height requests, so HTTP is done here and
        // the crate is used only for its wire types and response parsing.
        let http = reqwest::Client::builder()
            .user_agent(user_agent)
            .timeout(Duration::from_secs(30))
            .tcp_keepalive(Duration::from_secs(7200))
            .build()
            .context("build http client")
            .map_err(map_err)?;
        Ok(HyperfuelClient {
            http,
            url: cfg.url.trim_end_matches('/').to_string(),
            bearer_token: cfg.bearer_token,
        })
    }

    #[napi]
    pub async fn get_height(&self) -> napi::Result<i64> {
        let res = self
            .request(self.http.get(format!("{}/height", self.url)))
            .await
            .map_err(|e| {
                napi::Error::from_reason(format!("Failed to get HyperFuel height: {e}"))
            })?;

        #[derive(serde::Deserialize)]
        struct ArchiveHeight {
            height: Option<i64>,
        }
        let height: ArchiveHeight = res
            .json()
            .await
            .context("read height response json")
            .map_err(map_err)?;
        height
            .height
            .context("missing height in response")
            .map_err(map_err)
    }

    #[napi]
    pub async fn get_selected_data(&self, query: Query) -> napi::Result<QueryResponse> {
        let query: hyperfuel_client::net_types::Query =
            query.try_into().context("parse query").map_err(map_err)?;
        let res = self
            .request(
                self.http
                    .post(format!("{}/query/arrow-ipc", self.url))
                    .json(&query),
            )
            .await
            .map_err(|e| {
                napi::Error::from_reason(format!("Failed to get data from HyperFuel: {e}"))
            })?;

        let bytes = res
            .bytes()
            .await
            .context("read response body")
            .map_err(map_err)?;
        let parsed = tokio::task::spawn_blocking(move || parse::parse_query_response(&bytes))
            .await
            .context("join parse task")
            .map_err(map_err)?
            .context("parse query response")
            .map_err(map_err)?;

        convert_response(parsed).map_err(convert_error_to_napi)
    }
}

impl HyperfuelClient {
    async fn request(&self, mut req: reqwest::RequestBuilder) -> Result<reqwest::Response> {
        if let Some(bearer_token) = &self.bearer_token {
            req = req.bearer_auth(bearer_token);
        }
        let res = req.send().await.context("execute http request")?;
        let status = res.status();
        if !status.is_success() {
            let body = res.text().await.unwrap_or_default();
            return Err(anyhow!("server responded with status {status}: {body}"));
        }
        Ok(res)
    }
}

/// Encodes `ConvertError::MissingFields` as a JSON payload in the napi
/// error's message — the same protocol as hypersync_source, which the
/// ReScript side recovers via JSON.parse and a `kind` dispatch.
fn convert_error_to_napi(err: ConvertError) -> napi::Error {
    match err {
        ConvertError::MissingFields(fields) => {
            let payload = serde_json::json!({
                "kind": "MissingFields",
                "fields": fields,
            })
            .to_string();
            napi::Error::new(napi::Status::InvalidArg, payload)
        }
        ConvertError::Other(e) => map_err(e),
    }
}

fn map_err(e: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{:?}", e))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn convert_error_serializes_as_expected_json() {
        let err =
            ConvertError::MissingFields(vec!["receipt.txId".to_string(), "block.time".to_string()]);
        let napi_err = convert_error_to_napi(err);
        let parsed: serde_json::Value =
            serde_json::from_str(&napi_err.reason).expect("payload must be JSON");
        assert_eq!(parsed["kind"], "MissingFields");
        assert_eq!(parsed["fields"][0], "receipt.txId");
        assert_eq!(parsed["fields"][1], "block.time");
    }
}
