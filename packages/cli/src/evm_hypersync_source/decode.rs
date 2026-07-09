use std::collections::hash_map::Entry;
use std::collections::HashMap;
use std::sync::Arc;

use alloy_dyn_abi::{DecodedEvent, DynSolEvent, DynSolType};
use alloy_primitives::B256;
use anyhow::{Context, Result};
use hypersync_client::format::{Data, Hex, LogArgument};
use hypersync_client::simple_types;

use crate::evm_hypersync_source::types::{
    sol_value_to_param, EventParamsInput, Log, ParamMeta, ParamValue,
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
    id: i64,
    params: Vec<ParamMeta>,
}

/// One positional decoder plus the per-contract namings layered over it. Two
/// events sharing a `MetaKey` but indexing different params (same type list,
/// same indexed count, different positions) can't be told apart by (topic0,
/// topic count), so the first variant's layout backs the shared `decoder` and
/// `apply_names` keys names off each variant.
///
/// `wildcard`/`by_contract_name` index into `variants` and route a log to its
/// registration: the log's address resolves to a contract name (via the
/// partition's address index), the contract's own variant wins, and anything
/// else falls back to the wildcard variant.
struct RegisteredEvent {
    decoder: DynSolEvent,
    variants: Vec<EventVariant>,
    wildcard: Option<usize>,
    by_contract_name: HashMap<String, usize>,
}

#[derive(Clone)]
pub(crate) struct DecoderCore {
    events: Arc<HashMap<MetaKey, RegisteredEvent>>,
    checksummed_addresses: bool,
}

impl DecoderCore {
    pub(crate) fn from_params(
        event_params: Vec<EventParamsInput>,
        checksum_addresses: bool,
    ) -> Result<Self> {
        let mut events: HashMap<MetaKey, RegisteredEvent> = HashMap::new();
        for ep in event_params {
            let key = MetaKey::parse(&ep.sighash, ep.topic_count)
                .with_context(|| format!("parse meta key for {}", ep.event_name))?;
            let event = match events.entry(key) {
                Entry::Occupied(e) => e.into_mut(),
                Entry::Vacant(e) => {
                    let decoder = build_event_decoder(&key, &ep.params)
                        .with_context(|| format!("build decoder for {}", ep.event_name))?;
                    e.insert(RegisteredEvent {
                        decoder,
                        variants: Vec::new(),
                        wildcard: None,
                        by_contract_name: HashMap::new(),
                    })
                }
            };
            // The shared decoder is built from the first variant's layout. A
            // later variant colliding on this MetaKey but splitting indexed/body
            // differently would be silently mis-typed, so reject it. Config
            // parsing should already prevent this; this is the decoder-side
            // backstop. Differing param *names* are fine — `apply_names` applies
            // each variant's own.
            if let Some(first) = event.variants.first() {
                anyhow::ensure!(
                    same_decode_layout(&first.params, &ep.params),
                    "ABI layout mismatch for {}: another event with the same topic0 and topic \
                     count but a different indexed/type layout is already registered; they can't \
                     share a positional decoder",
                    ep.event_name,
                );
            }
            // Routing backstop mirroring the registration-time validation on
            // the JS side: one variant per contract per key, and at most one
            // wildcard variant per key.
            let variant_idx = event.variants.len();
            if event
                .by_contract_name
                .insert(ep.contract_name.clone(), variant_idx)
                .is_some()
            {
                anyhow::bail!(
                    "Duplicate event detected: {} for contract {} shares the same topic0 and \
                     topic count with another event of the contract",
                    ep.event_name,
                    ep.contract_name,
                );
            }
            if ep.is_wildcard {
                anyhow::ensure!(
                    event.wildcard.is_none(),
                    "Another event is already registered with the same signature that would \
                     interfere with wildcard filtering: {} for contract {}",
                    ep.event_name,
                    ep.contract_name,
                );
                event.wildcard = Some(variant_idx);
            }
            event.variants.push(EventVariant {
                id: ep.id,
                params: ep.params,
            });
        }

        Ok(Self {
            events: Arc::new(events),
            checksummed_addresses: checksum_addresses,
        })
    }

    pub(crate) fn checksummed_addresses(&self) -> bool {
        self.checksummed_addresses
    }

    pub(crate) fn route_and_decode_napi(
        &self,
        log: &Log,
        contract_name: Option<&str>,
    ) -> Result<Option<RoutedEvent>> {
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
        self.route_and_decode(&topics, &data, contract_name)
    }

    pub(crate) fn route_and_decode_simple(
        &self,
        log: &simple_types::Log,
        contract_name: Option<&str>,
    ) -> Result<Option<RoutedEvent>> {
        let data = log.data.as_ref().context("get log.data")?;
        self.route_and_decode(&log.topics, data, contract_name)
    }

    /// Routes a log to its registration and decodes with that registration's
    /// param names. `contract_name` is the log address's owning contract per
    /// the partition's address index; the contract's own variant wins, anything
    /// else falls back to the key's wildcard variant. `Ok(None)` means the log
    /// routes nowhere — unknown signature or no matching variant — and is
    /// dropped by the caller.
    fn route_and_decode(
        &self,
        topics: &[Option<LogArgument>],
        data: &Data,
        contract_name: Option<&str>,
    ) -> Result<Option<RoutedEvent>> {
        let event = match self.events.get(&MetaKey::from_topics(topics)?) {
            Some(e) => e,
            None => return Ok(None),
        };

        let variant_idx = match contract_name {
            Some(name) => event.by_contract_name.get(name).copied().or(event.wildcard),
            None => event.wildcard,
        };
        let variant = match variant_idx {
            Some(idx) => &event.variants[idx],
            None => return Ok(None),
        };

        let decoded = event
            .decoder
            .decode_log_parts(
                topics
                    .iter()
                    .take_while(|t| t.is_some())
                    .map(|t| t.as_ref().unwrap().into()),
                data,
            )
            .context("decode log")?;

        Ok(Some(RoutedEvent {
            id: variant.id,
            params: ParamValue::Obj(apply_names(
                decoded,
                &variant.params,
                self.checksummed_addresses,
            )?),
        }))
    }
}

pub(crate) struct RoutedEvent {
    pub id: i64,
    pub params: ParamValue,
}

fn apply_names(
    decoded: DecodedEvent,
    params: &[ParamMeta],
    checksummed_addresses: bool,
) -> Result<Vec<(String, ParamValue)>> {
    let mut indexed = decoded.indexed.into_iter();
    let mut body = decoded.body.into_iter();
    params
        .iter()
        .map(|param| {
            let sol_value = if param.indexed {
                indexed.next().context("indexed param out of bounds")?
            } else {
                body.next().context("body param out of bounds")?
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

/// Build the positional decoder for one MetaKey. The decoder's topic0 is pinned
/// to the on-chain sighash the MetaKey carries rather than derived from a
/// signature string, so an event surfaced to handlers under a different `name:`
/// (display name != on-chain name) still matches its real log (issue #1285).
/// The event name plays no part in decoding — only the param types do.
fn build_event_decoder(key: &MetaKey, params: &[ParamMeta]) -> Result<DynSolEvent> {
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
    DynSolEvent::new(
        Some(B256::from(key.sighash)),
        indexed,
        DynSolType::Tuple(body),
    )
    .context("construct event decoder")
}

/// Whether two param lists decode under the same positional layout. Names are
/// irrelevant to decoding (each variant applies its own), but the indexed/body
/// split and the ABI types must match or the shared decoder would mis-type a
/// later variant. Events colliding on a MetaKey already share topic0 — hence the
/// ordered type list — so in practice only the indexed flags can diverge; the
/// types and nested components are compared defensively all the same.
fn same_decode_layout(a: &[ParamMeta], b: &[ParamMeta]) -> bool {
    a.len() == b.len()
        && a.iter().zip(b).all(|(x, y)| {
            x.indexed == y.indexed
                && x.abi_type == y.abi_type
                && match (&x.components, &y.components) {
                    (None, None) => true,
                    (Some(xc), Some(yc)) => same_decode_layout(xc, yc),
                    _ => false,
                }
        })
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
                id: 7,
                sighash: real_sighash.clone(),
                topic_count: 1,
                event_name: "ApprovalRenamed".to_string(),
                contract_name: "TestContract".to_string(),
                is_wildcard: false,
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

        let routed = core
            .route_and_decode_napi(&log, Some("TestContract"))
            .unwrap()
            .expect("renamed event must decode under its real sighash");

        assert_eq!(routed.id, 7);
        match routed.params {
            ParamValue::Obj(fields) => match fields.as_slice() {
                [(owner, ParamValue::Str(owner_hex)), (value, ParamValue::BigInt(_))]
                    if owner == "owner" && value == "value" =>
                {
                    assert_eq!(owner_hex, "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
                }
                _ => panic!("unexpected decoded fields"),
            },
            _ => panic!("expected an object of params"),
        }
    }

    fn pm(name: &str, abi_type: &str, indexed: bool) -> ParamMeta {
        ParamMeta {
            name: name.to_string(),
            abi_type: abi_type.to_string(),
            indexed,
            components: None,
        }
    }

    #[test]
    fn rejects_metakey_collision_with_different_indexed_layout() {
        let sighash = alloy_json_abi::Event::parse("Foo(uint256 a, uint256 b)")
            .unwrap()
            .selector()
            .to_string();
        let variant = |contract: &str, params| EventParamsInput {
            id: 0,
            sighash: sighash.clone(),
            topic_count: 2,
            event_name: "Foo".to_string(),
            contract_name: contract.to_string(),
            is_wildcard: false,
            params,
        };

        let err = DecoderCore::from_params(
            vec![
                variant(
                    "C1",
                    vec![pm("a", "uint256", true), pm("b", "uint256", false)],
                ),
                variant(
                    "C2",
                    vec![pm("a", "uint256", false), pm("b", "uint256", true)],
                ),
            ],
            false,
        )
        .err()
        .expect("expected an ABI layout mismatch error");
        assert!(format!("{err}").contains("ABI layout mismatch"));
    }

    #[test]
    fn accepts_metakey_collision_with_same_layout_different_names() {
        let sighash =
            alloy_json_abi::Event::parse("Transfer(address from, address to, uint256 value)")
                .unwrap()
                .selector()
                .to_string();
        let variant = |contract: &str, params| EventParamsInput {
            id: 0,
            sighash: sighash.clone(),
            topic_count: 3,
            event_name: "Transfer".to_string(),
            contract_name: contract.to_string(),
            is_wildcard: false,
            params,
        };

        DecoderCore::from_params(
            vec![
                variant(
                    "TokenA",
                    vec![
                        pm("from", "address", true),
                        pm("to", "address", true),
                        pm("value", "uint256", false),
                    ],
                ),
                variant(
                    "TokenB",
                    vec![
                        pm("src", "address", true),
                        pm("dst", "address", true),
                        pm("wad", "uint256", false),
                    ],
                ),
            ],
            false,
        )
        .expect("same-layout variants with different names must register");
    }
}
