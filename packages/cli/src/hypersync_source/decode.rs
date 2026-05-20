use std::sync::Arc;

use anyhow::{Context, Result};
use hypersync_client::format::{Data, Hex, LogArgument};
use napi_derive::napi;

use crate::hypersync_source::{
    map_err,
    types::{DecodedEvent, DecodedSolValue, Event, Log},
};

/// Decoder for Ethereum events
#[napi]
#[derive(Clone)]
pub struct Decoder {
    inner: Arc<hypersync_client::Decoder>,
    checksummed_addresses: bool,
}

#[napi]
impl Decoder {
    /// Create a decoder from event signatures. `checksum_addresses` controls
    /// whether decoded `address` parameters are returned as EIP-55 checksummed
    /// strings (default `false`).
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
}
