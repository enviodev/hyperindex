use std::collections::HashMap;
use std::sync::Arc;

use alloy_dyn_abi::{DecodedEvent, DynSolEvent, DynSolType, Specifier};
use alloy_primitives::B256;
use anyhow::{Context, Result};
use hypersync_client::format::{Data, Hex, LogArgument};
use hypersync_client::simple_types;
use napi_derive::napi;

use crate::hypersync_source::{
    map_err,
    types::{sol_value_to_param, Event, EventParamsInput, Log, ParamMeta, ParamValue},
};

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
struct MetaKey {
    sighash: [u8; 32],
    topic_count: u8,
}

impl MetaKey {
    fn parse(sighash: &str, topic_count: i32) -> Result<Self> {
        let bytes = LogArgument::decode_hex(sighash).context("decode sighash hex")?;
        let topic_count: u8 = u8::try_from(topic_count).context("topic_count out of u8 range")?;
        anyhow::ensure!(
            (1..=4).contains(&topic_count),
            "topic_count must be 1..=4, got {topic_count}",
        );
        Ok(Self {
            sighash: **bytes,
            topic_count,
        })
    }

    fn from_topics(topics: &[Option<LogArgument>]) -> Result<Self> {
        let topic0 = topics
            .first()
            .context("get topic0")?
            .as_ref()
            .context("topic0 is null")?;
        let topic_count: u8 = topics
            .iter()
            .rposition(|t| t.is_some())
            .map_or(0, |i| i + 1)
            .try_into()
            .context("topic_count overflow")?;
        Ok(Self {
            sighash: ***topic0,
            topic_count,
        })
    }
}

/// One contract's naming for an event. Several contracts collapse to the same
/// `MetaKey` when they emit the same-signature event; the positional decode is
/// shared, the param names are not.
struct EventVariant {
    contract_name: String,
    params: Vec<ParamMeta>,
}

#[derive(Clone)]
pub(crate) struct DecoderCore {
    decoders: Arc<HashMap<MetaKey, DynSolEvent>>,
    checksummed_addresses: bool,
    variants: Arc<HashMap<MetaKey, Vec<EventVariant>>>,
}

impl DecoderCore {
    pub(crate) fn from_params(
        event_params: Vec<EventParamsInput>,
        checksum_addresses: bool,
    ) -> Result<Self> {
        let mut variants: HashMap<MetaKey, Vec<EventVariant>> = HashMap::new();
        // The positional decoder is keyed by (topic0, topic count) — the same
        // MetaKey — so it holds one decode per key. Contracts that share a key
        // reuse that single positional decode and only layer on their own names.
        // Two events sharing a MetaKey but indexing different params (same type
        // list, same indexed count, different positions) can't be told apart at
        // this layer regardless, so the first variant's layout wins; `apply_names`
        // then keys names off each variant.
        let mut decoders: HashMap<MetaKey, DynSolEvent> = HashMap::new();
        for ep in event_params {
            let key = MetaKey::parse(&ep.sighash, ep.topic_count)
                .with_context(|| format!("parse meta key for {}", ep.event_name))?;
            if !decoders.contains_key(&key) {
                let decoder = build_event_decoder(&key, &ep.event_name, &ep.params)
                    .with_context(|| format!("build decoder for {}", ep.event_name))?;
                decoders.insert(key, decoder);
            }
            variants.entry(key).or_default().push(EventVariant {
                contract_name: ep.contract_name,
                params: ep.params,
            });
        }

        Ok(Self {
            decoders: Arc::new(decoders),
            checksummed_addresses: checksum_addresses,
            variants: Arc::new(variants),
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
        let key = MetaKey::from_topics(topics)?;

        let decoder = match self.decoders.get(&key) {
            Some(d) => d,
            None => return Ok(None),
        };

        let variants = match self.variants.get(&key) {
            Some(v) => v,
            None => return Ok(None),
        };

        let decoded = decoder
            .decode_log_parts(
                topics
                    .iter()
                    .take_while(|t| t.is_some())
                    .map(|t| t.as_ref().unwrap().into()),
                data,
            )
            .context("decode log")?;

        // Same log, one decode, named once per contract. JS routes by address
        // and then picks `params[contractName]`, so two contracts that share a
        // signature but name their params differently each get their own names.
        let by_contract = variants
            .iter()
            .map(|variant| {
                let fields = apply_names(&decoded, &variant.params, self.checksummed_addresses)?;
                Ok((variant.contract_name.clone(), ParamValue::Obj(fields)))
            })
            .collect::<Result<Vec<_>>>()?;

        Ok(Some(ParamValue::Obj(by_contract)))
    }
}

fn apply_names(
    decoded: &DecodedEvent,
    params: &[ParamMeta],
    checksummed_addresses: bool,
) -> Result<Vec<(String, ParamValue)>> {
    let mut indexed_idx = 0;
    let mut body_idx = 0;
    params
        .iter()
        .map(|param| {
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
                checksummed_addresses,
            );
            Ok((param.name.clone(), value))
        })
        .collect()
}

/// Build the positional decoder for one MetaKey. Rebuilding the signature from
/// the event's display `name:` recovers the ABI types, but its keccak selector
/// is wrong whenever the event was renamed (display name != on-chain name) — so
/// the decoder's topic0 is pinned to the on-chain sighash the MetaKey carries.
/// Without this, a renamed event's log topic0 never matches and the log decodes
/// as null (issue #1285).
fn build_event_decoder(
    key: &MetaKey,
    event_name: &str,
    params: &[ParamMeta],
) -> Result<DynSolEvent> {
    let signature = reconstruct_signature(event_name, params);
    let resolved = alloy_json_abi::Event::parse(&signature)
        .context("parse event signature")?
        .resolve()
        .context("resolve event signature")?;
    DynSolEvent::new(
        Some(B256::from(key.sighash)),
        resolved.indexed().to_vec(),
        DynSolType::Tuple(resolved.body().to_vec()),
    )
    .context("construct event decoder")
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

#[cfg(test)]
mod tests {
    use super::*;

    const VALID_SIGHASH: &str =
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";

    #[test]
    fn parse_meta_key_rejects_zero_topics() {
        let err = MetaKey::parse(VALID_SIGHASH, 0).unwrap_err();
        assert!(format!("{err}").contains("topic_count must be 1..=4"));
    }

    #[test]
    fn parse_meta_key_rejects_five_topics() {
        let err = MetaKey::parse(VALID_SIGHASH, 5).unwrap_err();
        assert!(format!("{err}").contains("topic_count must be 1..=4"));
    }

    #[test]
    fn parse_meta_key_accepts_boundary_values() {
        assert!(MetaKey::parse(VALID_SIGHASH, 1).is_ok());
        assert!(MetaKey::parse(VALID_SIGHASH, 4).is_ok());
    }

    // Regression for issue #1285: an event surfaced to handlers under a name
    // that differs from its on-chain name must still decode. The decoder keys
    // on the on-chain sighash, not the keccak of the display name.
    #[test]
    fn renamed_event_decodes_under_real_sighash() {
        use alloy_dyn_abi::DynSolValue;
        use alloy_primitives::{hex, Address, U256};

        let real_sighash = alloy_json_abi::Event::parse("Approval(address owner, uint256 value)")
            .unwrap()
            .selector()
            .to_string();

        let core = DecoderCore::from_params(
            vec![EventParamsInput {
                sighash: real_sighash.clone(),
                topic_count: 1,
                event_name: "ApprovalRenamed".to_string(),
                contract_name: "TestContract".to_string(),
                params: vec![
                    ParamMeta {
                        name: "owner".to_string(),
                        abi_type: "address".to_string(),
                        indexed: false,
                        components: None,
                    },
                    ParamMeta {
                        name: "value".to_string(),
                        abi_type: "uint256".to_string(),
                        indexed: false,
                        components: None,
                    },
                ],
            }],
            false,
        )
        .unwrap();

        let data = DynSolValue::Tuple(vec![
            DynSolValue::Address(Address::from([0xaa; 20])),
            DynSolValue::Uint(U256::from(42u64), 256),
        ])
        .abi_encode();
        let log = Log {
            topics: vec![Some(real_sighash)],
            data: Some(format!("0x{}", hex::encode(data))),
            ..Default::default()
        };

        let decoded = core
            .decode_napi(&log)
            .unwrap()
            .expect("renamed event must decode under its real sighash");

        match decoded {
            ParamValue::Obj(contracts) => match contracts.as_slice() {
                [(contract, ParamValue::Obj(fields))] if contract == "TestContract" => {
                    match fields.as_slice() {
                        [(owner, ParamValue::Str(owner_hex)), (value, ParamValue::BigInt(_))]
                            if owner == "owner" && value == "value" =>
                        {
                            assert_eq!(owner_hex, "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
                        }
                        _ => panic!("unexpected decoded fields"),
                    }
                }
                _ => panic!("unexpected decoded contracts"),
            },
            _ => panic!("expected an object of params"),
        }
    }
}
