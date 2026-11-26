//! ABI decoding of a log under each registration it matched.

use std::sync::Arc;

use alloy_dyn_abi::{DynSolEvent, DynSolType};
use alloy_primitives::B256;
use anyhow::{Context, Result};
use hypersync_client::format::{Hex, LogArgument};

use crate::ecosystems::evm::registration::{
    EvmParams, OnEventRegistrationInput, ParamMeta, ParamSchema,
};

struct Registration {
    schema: Arc<ParamSchema>,
    decoder: DynSolEvent,
}

/// The decoders of a chain's registrations, by registration index.
pub(crate) struct EvmDecoder {
    by_index: Vec<Option<Registration>>,
}

impl EvmDecoder {
    pub(crate) fn new(
        inputs: &[OnEventRegistrationInput],
        checksum_addresses: bool,
    ) -> Result<Self> {
        let mut by_index: Vec<Option<Registration>> = Vec::new();
        for input in inputs {
            let index = usize::try_from(input.index).context("registration index is negative")?;
            let sighash = input
                .sighash
                .as_ref()
                .map(|sighash| LogArgument::decode_hex(sighash).map(|sighash| **sighash))
                .transpose()
                .context("decode sighash hex")?;
            if by_index.len() <= index {
                by_index.resize_with(index + 1, || None);
            }
            by_index[index] = Some(Registration {
                schema: Arc::new(ParamSchema::new(input.params.clone(), checksum_addresses)),
                decoder: build_event_decoder(sighash, &input.params)
                    .with_context(|| format!("build decoder for {}", input.event_name))?,
            });
        }
        Ok(EvmDecoder { by_index })
    }

    /// The log's params under the registration's own declaration, `None`
    /// when the log doesn't decode under it.
    pub(crate) fn decode(
        &self,
        registration: u32,
        topics: &[Option<&[u8]>; 4],
        data: &[u8],
    ) -> Option<EvmParams> {
        let registration = self.by_index.get(registration as usize)?.as_ref()?;
        let topics = topics
            .iter()
            .map_while(|topic| *topic)
            .map(|topic| B256::try_from(topic).ok())
            .collect::<Option<Vec<_>>>()?;
        let decoded = registration.decoder.decode_log_parts(topics, data).ok()?;
        EvmParams::from_decoded(decoded, &registration.schema)
    }
}

/// The decoder's topic0 is the on-chain sighash the registration carries, so
/// an event renamed for its handlers still matches its real log. Without a
/// sighash the event is anonymous and topic0 is its first indexed param.
fn build_event_decoder(sighash: Option<[u8; 32]>, params: &[ParamMeta]) -> Result<DynSolEvent> {
    let mut indexed = Vec::new();
    let mut body = Vec::new();
    for param in params {
        let ty = DynSolType::parse(&param.abi_type)
            .with_context(|| format!("parse abi type {}", param.abi_type))?;
        if param.indexed {
            indexed.push(ty);
        } else {
            body.push(ty);
        }
    }
    DynSolEvent::new(sighash.map(B256::from), indexed, DynSolType::Tuple(body))
        .context("construct event decoder")
}
