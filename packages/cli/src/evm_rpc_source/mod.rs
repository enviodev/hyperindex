use anyhow::Context;
use napi_derive::napi;
use serde::Deserialize;
use serde_json::json;
use std::collections::HashMap;

mod client;

use crate::evm_hypersync_source::decode::DecoderCore;
use crate::evm_hypersync_source::types::{EventParamsInput, Log as DecoderLog, ParamValue};
use client::{parse_hex_u64, JsonRpcClient, RpcError};

#[napi(object)]
pub struct EvmRpcClientConfig {
    pub url: String,
    pub http_req_timeout_millis: Option<i64>,
    pub headers: Option<HashMap<String, String>>,
}

#[napi(object)]
pub struct GetLogsParams {
    pub from_block: i64,
    pub to_block: i64,
    pub addresses: Option<Vec<String>>,
    /// One entry per topic position. `None` matches any value; `Some(values)`
    /// matches any of the listed topic hashes (a one-element list is an exact
    /// match). The JS side flattens its `Single | Multiple | Null` filter here.
    pub topics: Vec<Option<Vec<String>>>,
}

/// A log returned from `eth_getLogs`, with hex quantities decoded to integers.
/// Field names cross the napi boundary as camelCase, matching the ReScript
/// `Rpc.GetLogs.log` record.
// Only the fields the ReScript side reads cross the boundary. `data` is consumed
// by the decoder on the Rust side (see `to_decoder_log`) and `removed` is unused,
// so neither is carried here.
#[napi(object)]
pub struct RpcLog {
    pub address: String,
    pub topics: Vec<String>,
    pub block_number: i64,
    pub transaction_hash: String,
    pub transaction_index: i64,
    pub block_hash: String,
    pub log_index: i64,
}

#[napi(object)]
pub struct RpcEventItem {
    pub log: RpcLog,
    /// Decoded params keyed by contract name, or `None` when no registered event
    /// signature matches the log's topic0/topic-count (or decoding failed).
    pub params: Option<ParamValue>,
}

/// Raw `eth_getLogs` entry as the provider serialises it: integer fields are
/// 0x-prefixed hex quantities that `RpcLog` later decodes.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawLog {
    address: String,
    topics: Vec<String>,
    data: String,
    block_number: String,
    transaction_hash: String,
    transaction_index: String,
    block_hash: String,
    log_index: String,
}

impl RawLog {
    fn into_rpc_log(self) -> anyhow::Result<RpcLog> {
        let to_i64 = |hex: &str| -> anyhow::Result<i64> {
            parse_hex_u64(hex)?
                .try_into()
                .context("hex quantity exceeds i64::MAX")
        };
        Ok(RpcLog {
            block_number: to_i64(&self.block_number).context("log.blockNumber")?,
            transaction_index: to_i64(&self.transaction_index).context("log.transactionIndex")?,
            log_index: to_i64(&self.log_index).context("log.logIndex")?,
            address: self.address,
            topics: self.topics,
            transaction_hash: self.transaction_hash,
            block_hash: self.block_hash,
        })
    }

    fn to_decoder_log(&self) -> DecoderLog {
        DecoderLog {
            data: Some(self.data.clone()),
            topics: self.topics.iter().map(|t| Some(t.clone())).collect(),
            ..Default::default()
        }
    }
}

#[napi]
pub struct EvmRpcClient {
    inner: JsonRpcClient,
    decoder: DecoderCore,
}

#[napi]
impl EvmRpcClient {
    #[napi(factory)]
    pub fn new(
        cfg: EvmRpcClientConfig,
        event_params: Vec<EventParamsInput>,
        checksum_addresses: bool,
    ) -> napi::Result<EvmRpcClient> {
        let http_req_timeout_millis = cfg
            .http_req_timeout_millis
            .filter(|v| *v > 0)
            .map_or(JsonRpcClient::default_http_req_timeout_millis(), |v| {
                v as u64
            });
        let inner =
            JsonRpcClient::new(cfg.url, http_req_timeout_millis, cfg.headers).map_err(map_err)?;
        let decoder = DecoderCore::from_params(event_params, checksum_addresses)
            .context("build decoder")
            .map_err(map_err)?;
        Ok(EvmRpcClient { inner, decoder })
    }

    #[napi]
    pub async fn get_height(&self) -> napi::Result<i64> {
        let height = self.inner.get_height().await.map_err(rpc_error_to_napi)?;
        height
            .try_into()
            .context("block height exceeds i64::MAX")
            .map_err(map_err)
    }

    #[napi]
    pub async fn get_logs(&self, params: GetLogsParams) -> napi::Result<Vec<RpcEventItem>> {
        // Hex-formatting a negative i64 yields a two's-complement quantity, which
        // would silently widen the queried range; reject it at the boundary.
        if params.from_block < 0 || params.to_block < 0 {
            return Err(map_err(anyhow::anyhow!(
                "block bounds must be non-negative, got from_block={}, to_block={}",
                params.from_block,
                params.to_block,
            )));
        }
        let mut filter = json!({
            "fromBlock": format!("0x{:x}", params.from_block),
            "toBlock": format!("0x{:x}", params.to_block),
            "topics": params.topics,
        });
        if let Some(addresses) = params.addresses {
            filter["address"] = json!(addresses);
        }

        let raw_logs: Vec<RawLog> = self
            .inner
            .request("eth_getLogs", json!([filter]))
            .await
            .map_err(rpc_error_to_napi)?;

        let decoder = self.decoder.clone();
        // Decoding is CPU-bound ABI work; keep it off the libuv async thread.
        tokio::task::spawn_blocking(move || {
            raw_logs
                .into_iter()
                .map(|raw| {
                    let params = decoder.decode_napi(&raw.to_decoder_log()).ok().flatten();
                    Ok(RpcEventItem {
                        log: raw.into_rpc_log()?,
                        params,
                    })
                })
                .collect::<anyhow::Result<Vec<_>>>()
        })
        .await
        .map_err(|e| map_err(anyhow::anyhow!("get_logs worker join failure: {e}")))?
        .map_err(map_err)
    }
}

/// Encodes JSON-RPC errors as a JSON payload in the napi error's message.
/// The ReScript side parses it back into a structured exception, keeping
/// the provider's code and message intact across the boundary.
fn rpc_error_to_napi(e: RpcError) -> napi::Error {
    match e {
        RpcError::JsonRpc { code, message } => {
            let payload = serde_json::json!({
                "kind": "JsonRpcError",
                "code": code,
                "message": message,
            })
            .to_string();
            napi::Error::from_reason(payload)
        }
        RpcError::Other(e) => map_err(e),
    }
}

fn map_err(e: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{e:#}"))
}
