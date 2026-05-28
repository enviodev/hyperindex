use std::collections::HashMap;
use std::sync::Arc;

use anyhow::{Context, Result};
use hypersync_client::format::{Data, Hex, LogArgument};
use hypersync_client::simple_types;
use napi_derive::napi;

use crate::hypersync_source::{
    map_err,
    types::{sol_value_to_param, Event, EventParamsInput, Log, ParamMeta, ParamValue},
};

type MetaKey = ([u8; 32], u8);

#[derive(Clone)]
pub(crate) struct DecoderCore {
    inner: Arc<hypersync_client::Decoder>,
    checksummed_addresses: bool,
    param_meta: Arc<HashMap<MetaKey, Vec<ParamMeta>>>,
}

impl DecoderCore {
    pub(crate) fn from_params(
        event_params: Vec<EventParamsInput>,
        checksum_addresses: bool,
    ) -> Result<Self> {
        let signatures: Vec<String> = event_params
            .iter()
            .map(|ep| reconstruct_signature(&ep.event_name, &ep.params))
            .collect();

        let inner = hypersync_client::Decoder::from_signatures(&signatures)
            .context("create inner decoder")?;

        let mut param_meta: HashMap<MetaKey, Vec<ParamMeta>> = HashMap::new();
        for ep in event_params {
            let key = parse_meta_key(&ep.sighash, ep.topic_count)
                .with_context(|| format!("parse meta key for {}", ep.event_name))?;
            param_meta.insert(key, ep.params);
        }

        Ok(Self {
            inner: Arc::new(inner),
            checksummed_addresses: checksum_addresses,
            param_meta: Arc::new(param_meta),
        })
    }

    pub(crate) fn decode_napi(&self, log: &Log) -> Result<Option<ParamValue>> {
        let topics: Vec<Option<LogArgument>> = log
            .topics
            .iter()
            .map(|v| {
                v.as_ref()
                    .map(|v| LogArgument::decode_hex(v).context("decode topic"))
                    .transpose()
            })
            .collect::<Result<_>>()
            .context("decode topics")?;
        let data = log.data.as_ref().context("get log.data")?;
        let data = Data::decode_hex(data).context("decode data")?;
        self.decode_with_topics_and_data(&topics, &data)
    }

    pub(crate) fn decode_simple(&self, log: &simple_types::Log) -> Result<Option<ParamValue>> {
        let data = log.data.as_ref().context("get log.data")?;
        self.decode_with_topics_and_data(&log.topics, data)
    }

    fn decode_with_topics_and_data(
        &self,
        topics: &[Option<LogArgument>],
        data: &Data,
    ) -> Result<Option<ParamValue>> {
        let topic0 = topics
            .first()
            .context("get topic0")?
            .as_ref()
            .context("topic0 is null")?;

        let decoded = match self
            .inner
            .decode(topic0.as_slice(), topics, data)
            .context("decode log")?
        {
            Some(v) => v,
            None => return Ok(None),
        };

        let topic_count: u8 = topics
            .iter()
            .rposition(|t| t.is_some())
            .map_or(0, |i| i + 1)
            .try_into()
            .context("topic_count overflow")?;
        let key: MetaKey = (***topic0, topic_count);

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

fn parse_meta_key(sighash: &str, topic_count: i32) -> Result<MetaKey> {
    let bytes = LogArgument::decode_hex(sighash).context("decode sighash hex")?;
    let count: u8 = u8::try_from(topic_count).context("topic_count out of u8 range")?;
    Ok((**bytes, count))
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
#[derive(Clone)]
pub struct Decoder {
    core: DecoderCore,
}

#[napi]
impl Decoder {
    #[napi(factory)]
    pub fn from_params(
        event_params: Vec<EventParamsInput>,
        checksum_addresses: Option<bool>,
    ) -> napi::Result<Decoder> {
        let core = DecoderCore::from_params(event_params, checksum_addresses.unwrap_or(false))
            .map_err(map_err)?;
        Ok(Self { core })
    }

    #[napi]
    pub async fn decode_logs(&self, events: Vec<Event>) -> napi::Result<Vec<Option<ParamValue>>> {
        let core = self.core.clone();
        tokio::task::spawn_blocking(move || {
            events
                .iter()
                .map(|event| core.decode_napi(&event.log).ok().flatten())
                .collect::<Vec<_>>()
        })
        .await
        .map_err(|e| map_err(anyhow::anyhow!("decode_logs worker join failure: {e}")))
    }
}
