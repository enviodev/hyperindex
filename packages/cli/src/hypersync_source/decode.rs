use std::collections::HashMap;
use std::sync::Arc;

use anyhow::{Context, Result};
use hypersync_client::format::{Data, Hex, LogArgument};
use napi_derive::napi;

use crate::hypersync_source::{
    map_err,
    types::{
        sol_value_to_param, DecodedEvent, DecodedSolValue, Event, EventParamsInput, Log, ParamMeta,
        ParamValue,
    },
};

/// Decoder for Ethereum events
#[napi]
#[derive(Clone)]
pub struct Decoder {
    inner: Arc<hypersync_client::Decoder>,
    checksummed_addresses: bool,
    param_meta: Arc<HashMap<String, Vec<ParamMeta>>>,
}

fn meta_key(sighash: &str, topic_count: usize) -> String {
    format!("{}_{}", sighash, topic_count)
}

fn reconstruct_signature(event_name: &str, params: &[ParamMeta]) -> String {
    let params_str = params
        .iter()
        .map(|p| {
            if p.indexed {
                format!("{} indexed {}", p.abi_type, p.name)
            } else {
                format!("{} {}", p.abi_type, p.name)
            }
        })
        .collect::<Vec<_>>()
        .join(", ");
    format!("{}({})", event_name, params_str)
}

#[napi]
impl Decoder {
    #[napi(factory)]
    pub fn from_signatures(
        signatures: Vec<String>,
        checksum_addresses: Option<bool>,
    ) -> napi::Result<Decoder> {
        let inner = hypersync_client::Decoder::from_signatures(&signatures)
            .context("create inner decoder")
            .map_err(map_err)?;
        Ok(Self {
            inner: Arc::new(inner),
            checksummed_addresses: checksum_addresses.unwrap_or(false),
            param_meta: Arc::new(HashMap::new()),
        })
    }

    #[napi(factory)]
    pub fn from_params(
        event_params: Vec<EventParamsInput>,
        checksum_addresses: Option<bool>,
    ) -> napi::Result<Decoder> {
        let signatures: Vec<String> = event_params
            .iter()
            .map(|ep| reconstruct_signature(&ep.event_name, &ep.params))
            .collect();

        let inner = hypersync_client::Decoder::from_signatures(&signatures)
            .context("create inner decoder")
            .map_err(map_err)?;

        let mut param_meta = HashMap::new();
        for ep in event_params {
            let key = meta_key(&ep.sighash, ep.topic_count as usize);
            param_meta.insert(key, ep.params);
        }

        Ok(Self {
            inner: Arc::new(inner),
            checksummed_addresses: checksum_addresses.unwrap_or(false),
            param_meta: Arc::new(param_meta),
        })
    }

    #[napi]
    pub async fn decode_events(
        &self,
        events: Vec<Event>,
    ) -> napi::Result<Vec<Option<DecodedEvent>>> {
        let decoder = self.clone();
        tokio::task::spawn_blocking(move || {
            events
                .iter()
                .map(|event| decoder.decode_impl(&event.log).ok().flatten())
                .collect::<Vec<_>>()
        })
        .await
        .map_err(|e| map_err(anyhow::anyhow!("decode_events worker join failure: {e}")))
    }

    #[napi]
    pub async fn decode_logs(&self, events: Vec<Event>) -> napi::Result<Vec<Option<ParamValue>>> {
        let decoder = self.clone();
        tokio::task::spawn_blocking(move || {
            events
                .iter()
                .map(|event| decoder.decode_to_params(&event.log).map_err(|e| map_err(e)))
                .collect::<napi::Result<Vec<_>>>()
        })
        .await
        .map_err(|e| map_err(anyhow::anyhow!("decode_logs worker join failure: {e}")))?
    }

    fn decode_impl(&self, log: &Log) -> Result<Option<DecodedEvent>> {
        let topics = log
            .topics
            .iter()
            .map(|v| {
                v.as_ref()
                    .map(|v| LogArgument::decode_hex(v).context("decode topic"))
                    .transpose()
            })
            .collect::<Result<Vec<_>>>()
            .context("decode topics")?;

        let topic0 = topics
            .first()
            .context("get topic0")?
            .as_ref()
            .context("topic0 is null")?;

        let data = log.data.as_ref().context("get log.data")?;
        let data = Data::decode_hex(data).context("decode data")?;

        let decoded = match self
            .inner
            .decode(topic0.as_slice(), &topics, &data)
            .context("decode log")?
        {
            Some(v) => v,
            None => return Ok(None),
        };

        Ok(Some(DecodedEvent {
            indexed: decoded
                .indexed
                .into_iter()
                .map(|v| DecodedSolValue::new(v, self.checksummed_addresses))
                .collect(),
            body: decoded
                .body
                .into_iter()
                .map(|v| DecodedSolValue::new(v, self.checksummed_addresses))
                .collect(),
        }))
    }

    fn decode_to_params(&self, log: &Log) -> Result<Option<ParamValue>> {
        let topics = log
            .topics
            .iter()
            .map(|v| {
                v.as_ref()
                    .map(|v| LogArgument::decode_hex(v).context("decode topic"))
                    .transpose()
            })
            .collect::<Result<Vec<_>>>()
            .context("decode topics")?;

        let topic0 = topics
            .first()
            .context("get topic0")?
            .as_ref()
            .context("topic0 is null")?;

        let data = log.data.as_ref().context("get log.data")?;
        let data = Data::decode_hex(data).context("decode data")?;

        let decoded = match self
            .inner
            .decode(topic0.as_slice(), &topics, &data)
            .context("decode log")?
        {
            Some(v) => v,
            None => return Ok(None),
        };

        let sighash = format!("0x{}", faster_hex::hex_string(topic0.as_slice()));
        let key = meta_key(&sighash, topics.len());

        let params = match self.param_meta.get(&key) {
            Some(p) => p,
            None => return Ok(None),
        };

        let mut fields = Vec::with_capacity(params.len());
        let mut indexed_idx = 0;
        let mut body_idx = 0;

        for param in params {
            let sol_value = if param.indexed {
                let v = decoded
                    .indexed
                    .get(indexed_idx)
                    .context("indexed param out of bounds")?
                    .clone();
                indexed_idx += 1;
                v
            } else {
                let v = decoded
                    .body
                    .get(body_idx)
                    .context("body param out of bounds")?
                    .clone();
                body_idx += 1;
                v
            };

            let value = sol_value_to_param(
                sol_value,
                param.components.as_deref(),
                self.checksummed_addresses,
            );
            fields.push((param.name.clone(), value));
        }

        Ok(Some(ParamValue::Obj(fields)))
    }
}
