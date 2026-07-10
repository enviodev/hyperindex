use anyhow::Context;
use napi_derive::napi;

mod config;
mod query;
mod types;

use crate::block_store::{decode_hex_bytes, BlockStore, FuelBlockRow};
use config::ClientConfig;
use query::Query;
use types::{convert_response, ConvertError, QueryResponse};

#[napi]
pub struct HyperfuelClient {
    inner: hyperfuel_client::Client,
}

#[napi]
impl HyperfuelClient {
    #[napi(factory)]
    pub fn new(cfg: ClientConfig, user_agent: String) -> napi::Result<HyperfuelClient> {
        let client_config: hyperfuel_client::ClientConfig =
            cfg.try_into().context("build config").map_err(map_err)?;
        let inner = hyperfuel_client::Client::new_with_agent(client_config, user_agent)
            .context("build client")
            .map_err(map_err)?;
        Ok(HyperfuelClient { inner })
    }

    #[napi]
    pub async fn get_height(&self) -> napi::Result<i64> {
        let height = self
            .inner
            .get_height()
            .await
            .map_err(|e| request_err("Failed to get HyperFuel height", e))?;
        height.try_into().context("convert height").map_err(map_err)
    }

    #[napi]
    pub async fn get_selected_data(
        &self,
        query: Query,
    ) -> napi::Result<(QueryResponse, BlockStore)> {
        let query: hyperfuel_client::net_types::Query =
            query.try_into().context("parse query").map_err(map_err)?;
        let res = self
            .inner
            .get_arrow(&query)
            .await
            .map_err(|e| request_err("Failed to get data from HyperFuel", e))?;
        let response = convert_response(res).map_err(convert_error_to_napi)?;

        // The page's raw blocks, keyed by height — merged into the per-chain
        // store where their ids drive reorg detection and materialisation.
        let block_store = BlockStore::new_fuel();
        let rows = response
            .data
            .blocks
            .iter()
            .map(|b| {
                Ok(FuelBlockRow {
                    height: u64::try_from(b.height).context("block.height negative")?,
                    id: Some(decode_hex_bytes(&b.id, "block.id")?),
                    time: Some(b.time),
                })
            })
            .collect::<anyhow::Result<Vec<_>>>()
            .map_err(map_err)?;
        block_store.insert_fuel_block_rows(rows);

        Ok((response, block_store))
    }
}

/// The client embeds a `{:?}` debug dump in its error message; keep only the
/// first line so it stays readable when the indexer surfaces it on retries.
fn request_err(prefix: &str, e: anyhow::Error) -> napi::Error {
    let message = format!("{e}");
    let summary = message.lines().next().unwrap_or(message.as_str());
    napi::Error::from_reason(format!("{prefix}: {summary}"))
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
