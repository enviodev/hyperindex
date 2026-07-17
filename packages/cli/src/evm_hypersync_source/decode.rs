use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use alloy_dyn_abi::{DecodedEvent, DynSolEvent, DynSolType};
use alloy_primitives::B256;
use anyhow::{Context, Result};
use hypersync_client::format::{Data, Hex, LogArgument};
use hypersync_client::simple_types;

use crate::evm_hypersync_source::selection::TopicSelectionInput;
use crate::evm_hypersync_source::types::{
    sol_value_to_param, Log, OnEventRegistration, ParamMeta, ParamValue,
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

/// One topic position's static constraint: `None` matches any value — either
/// the position is unfiltered, or it carries a `ContractAddresses` marker
/// whose temporal check stays on the JS `clientAddressFilter`.
type StaticTopicFilter = Option<Vec<[u8; 32]>>;

/// One registration's routing metadata for an event. Several registrations
/// collapse to the same `MetaKey` when they select the same-signature event;
/// the positional decode is shared, the param names and filters are not.
struct EventVariant {
    on_event_registration_index: i64,
    params: Vec<ParamMeta>,
    /// The registration's resolved `where` in DNF (outer Vec is OR); a log
    /// matches when any selection's four positions all match. Empty means the
    /// registration puts no static topic constraint on its logs.
    topic_filters: Vec<[StaticTopicFilter; 4]>,
}

/// One positional decoder plus the per-registration namings layered over it.
/// Two events sharing a `MetaKey` but indexing different params (same type
/// list, same indexed count, different positions) can't be told apart by
/// (topic0, topic count), so the first variant's layout backs the shared
/// `decoder` and `apply_names` keys names off each variant.
///
/// `wildcard_variant_idxs`/`variant_idxs_by_contract_name` index into
/// `variants` and fan a log out to its registrations: wildcard registrations
/// always match, contract-bound registrations match iff the log's address is
/// owned by that contract (via the partition's address index) — there is no
/// fallback tier between them.
struct RegisteredEvent {
    decoder: DynSolEvent,
    variants: Vec<EventVariant>,
    wildcard_variant_idxs: Vec<usize>,
    variant_idxs_by_contract_name: HashMap<String, Vec<usize>>,
}

#[derive(Clone)]
pub(crate) struct DecoderCore {
    events: Arc<HashMap<MetaKey, RegisteredEvent>>,
    checksummed_addresses: bool,
}

impl DecoderCore {
    pub(crate) fn from_registrations(
        registrations: &[OnEventRegistration],
        checksum_addresses: bool,
    ) -> Result<Self> {
        let mut events: HashMap<MetaKey, RegisteredEvent> = HashMap::new();
        for ep in registrations {
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
                        wildcard_variant_idxs: Vec::new(),
                        variant_idxs_by_contract_name: HashMap::new(),
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
            let variant_idx = event.variants.len();
            if ep.is_wildcard {
                event.wildcard_variant_idxs.push(variant_idx);
            } else {
                event
                    .variant_idxs_by_contract_name
                    .entry(ep.contract_name.clone())
                    .or_default()
                    .push(variant_idx);
            }
            event.variants.push(EventVariant {
                on_event_registration_index: ep.index,
                params: ep.params.clone(),
                topic_filters: parse_topic_filters(&ep.topic_selections)
                    .with_context(|| format!("parse topic filters for {}", ep.event_name))?,
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
        active_registrations: &HashSet<i64>,
    ) -> Result<Vec<RoutedEvent>> {
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
        self.route_and_decode(&topics, &data, contract_name, active_registrations)
    }

    pub(crate) fn route_and_decode_simple(
        &self,
        log: &simple_types::Log,
        contract_name: Option<&str>,
        active_registrations: &HashSet<i64>,
    ) -> Result<Vec<RoutedEvent>> {
        let data = log.data.as_ref().context("get log.data")?;
        self.route_and_decode(&log.topics, data, contract_name, active_registrations)
    }

    /// Fans a log out to every matching registration and decodes once, applying
    /// each registration's own param names. `contract_name` is the log
    /// address's owning contract per the partition's address index: wildcard
    /// registrations always match, contract-bound registrations match iff the
    /// address is owned — there is no fallback tier. A log only routes to
    /// registrations whose selection fetched it: registrations outside the
    /// query's `active_registrations` never participate, and each match
    /// re-applies the registration's static topic filters, since another
    /// registration's broader selection in the same query may have fetched
    /// the log. An empty result means the log routes nowhere and is dropped
    /// by the caller.
    fn route_and_decode(
        &self,
        topics: &[Option<LogArgument>],
        data: &Data,
        contract_name: Option<&str>,
        active_registrations: &HashSet<i64>,
    ) -> Result<Vec<RoutedEvent>> {
        let event = match self.events.get(&MetaKey::from_topics(topics)?) {
            Some(e) => e,
            None => return Ok(Vec::new()),
        };

        let owned_idxs = contract_name
            .and_then(|name| event.variant_idxs_by_contract_name.get(name))
            .map(Vec::as_slice)
            .unwrap_or_default();
        let mut variant_idxs: Vec<usize> = event
            .wildcard_variant_idxs
            .iter()
            .chain(owned_idxs)
            .copied()
            .filter(|&idx| {
                let variant = &event.variants[idx];
                active_registrations.contains(&variant.on_event_registration_index)
                    && matches_topic_filters(&variant.topic_filters, topics)
            })
            .collect();
        if variant_idxs.is_empty() {
            return Ok(Vec::new());
        }
        // Deterministic item order per log, independent of wildcard/owned split.
        variant_idxs.sort_unstable_by_key(|&idx| event.variants[idx].on_event_registration_index);

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

        variant_idxs
            .iter()
            .map(|&idx| {
                let variant = &event.variants[idx];
                Ok(RoutedEvent {
                    index: variant.on_event_registration_index,
                    params: ParamValue::Obj(apply_names(
                        decoded.clone(),
                        &variant.params,
                        self.checksummed_addresses,
                    )?),
                })
            })
            .collect()
    }
}

fn parse_topic_filters(
    topic_selections: &[TopicSelectionInput],
) -> Result<Vec<[StaticTopicFilter; 4]>> {
    let parse_values = |values: &[String]| -> Result<Vec<[u8; 32]>> {
        values
            .iter()
            .map(|v| {
                LogArgument::decode_hex(v)
                    .map(|arg| **arg)
                    .with_context(|| format!("decode topic filter value {v}"))
            })
            .collect()
    };
    // An empty value list means match-any (mirroring query semantics), same as
    // a `ContractAddresses` marker (`None` input) — the marker's check stays on
    // the JS `clientAddressFilter`.
    let parse_position = |input: &Option<Vec<String>>| -> Result<StaticTopicFilter> {
        match input {
            Some(values) if !values.is_empty() => Ok(Some(parse_values(values)?)),
            _ => Ok(None),
        }
    };
    topic_selections
        .iter()
        .map(|ts| {
            Ok([
                if ts.topic0.is_empty() {
                    None
                } else {
                    Some(parse_values(&ts.topic0)?)
                },
                parse_position(&ts.topic1)?,
                parse_position(&ts.topic2)?,
                parse_position(&ts.topic3)?,
            ])
        })
        .collect()
}

fn matches_topic_filters(
    filters: &[[StaticTopicFilter; 4]],
    topics: &[Option<LogArgument>],
) -> bool {
    if filters.is_empty() {
        return true;
    }
    filters.iter().any(|selection| {
        selection
            .iter()
            .enumerate()
            .all(|(i, filter)| match filter {
                None => true,
                Some(values) => topics
                    .get(i)
                    .and_then(Option::as_ref)
                    .is_some_and(|topic| values.iter().any(|v| v == &***topic)),
            })
    })
}

pub(crate) struct RoutedEvent {
    pub index: i64,
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

        let core = DecoderCore::from_registrations(
            &[OnEventRegistration {
                index: 7,
                sighash: real_sighash.clone(),
                topic_count: 1,
                event_name: "ApprovalRenamed".to_string(),
                contract_name: "TestContract".to_string(),
                is_wildcard: false,
                depends_on_addresses: false,
                topic_selections: vec![],
                block_fields: vec![],
                transaction_fields: vec![],
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

        let mut routed = core
            .route_and_decode_napi(&log, Some("TestContract"), &HashSet::from([7]))
            .unwrap();
        assert_eq!(routed.len(), 1);
        let routed = routed
            .pop()
            .expect("renamed event must decode under its real sighash");

        assert_eq!(routed.index, 7);
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

    // One Transfer(address,uint256)-shaped registration; anonymous topic-count-1
    // key so logs are easy to fabricate.
    fn transfer_reg(
        index: i64,
        contract_name: &str,
        is_wildcard: bool,
        sighash: &str,
    ) -> OnEventRegistration {
        OnEventRegistration {
            index,
            sighash: sighash.to_string(),
            topic_count: 1,
            event_name: "E".to_string(),
            contract_name: contract_name.to_string(),
            is_wildcard,
            depends_on_addresses: false,
            topic_selections: vec![],
            block_fields: vec![],
            transaction_fields: vec![],
            params: vec![pm("value", "uint256", false)],
        }
    }

    fn value_log(sighash: &str) -> Log {
        use alloy_dyn_abi::DynSolValue;
        use alloy_primitives::{hex, U256};
        let data = DynSolValue::Tuple(vec![DynSolValue::Uint(U256::from(1u64), 256)]).abi_encode();
        Log {
            topics: vec![Some(sighash.to_string())],
            data: Some(format!("0x{}", hex::encode(data))),
            ..Default::default()
        }
    }

    fn routed_indexes(routed: &[RoutedEvent]) -> Vec<i64> {
        routed.iter().map(|r| r.index).collect()
    }

    #[test]
    fn fans_out_to_wildcards_and_owned_contract_without_fallback_tier() {
        let core = DecoderCore::from_registrations(
            &[
                transfer_reg(0, "Owned", false, VALID_SIGHASH),
                transfer_reg(1, "W1", true, VALID_SIGHASH),
                transfer_reg(2, "W2", true, VALID_SIGHASH),
                transfer_reg(3, "Other", false, VALID_SIGHASH),
            ],
            false,
        )
        .unwrap();
        let active = HashSet::from([0, 1, 2, 3]);
        let log = value_log(VALID_SIGHASH);

        // Owned address: the contract's registration plus every wildcard.
        let owned = core
            .route_and_decode_napi(&log, Some("Owned"), &active)
            .unwrap();
        assert_eq!(routed_indexes(&owned), vec![0, 1, 2]);

        // Unowned address: wildcards only — no fallback into contract-bound
        // registrations.
        let unowned = core.route_and_decode_napi(&log, None, &active).unwrap();
        assert_eq!(routed_indexes(&unowned), vec![1, 2]);
    }

    #[test]
    fn routing_scoped_to_active_registrations() {
        let core = DecoderCore::from_registrations(
            &[
                transfer_reg(0, "Owned", false, VALID_SIGHASH),
                transfer_reg(1, "W1", true, VALID_SIGHASH),
            ],
            false,
        )
        .unwrap();
        let log = value_log(VALID_SIGHASH);
        let routed = core
            .route_and_decode_napi(&log, Some("Owned"), &HashSet::from([0]))
            .unwrap();
        assert_eq!(routed_indexes(&routed), vec![0]);
    }

    #[test]
    fn static_topic_filters_reapplied_per_registration() {
        const TOPIC1_A: &str = "0x00000000000000000000000000000000000000000000000000000000000000aa";
        const TOPIC1_B: &str = "0x00000000000000000000000000000000000000000000000000000000000000bb";
        let selection = |topic1| crate::evm_hypersync_source::selection::TopicSelectionInput {
            topic0: vec![VALID_SIGHASH.to_string()],
            topic1,
            topic2: Some(vec![]),
            topic3: Some(vec![]),
        };
        // Three same-signature wildcards: one filtering topic1 to A, one to B,
        // and one with a ContractAddresses marker (None) that Rust must treat
        // as match-any (the JS clientAddressFilter owns that check).
        let mut filtered_a = transfer_reg(0, "WA", true, VALID_SIGHASH);
        filtered_a.topic_count = 2;
        filtered_a.params = vec![pm("who", "address", true), pm("value", "uint256", false)];
        filtered_a.topic_selections = vec![selection(Some(vec![TOPIC1_A.to_string()]))];
        let mut filtered_b = transfer_reg(1, "WB", true, VALID_SIGHASH);
        filtered_b.topic_count = 2;
        filtered_b.params = filtered_a.params.clone();
        filtered_b.topic_selections = vec![selection(Some(vec![TOPIC1_B.to_string()]))];
        let mut marker = transfer_reg(2, "WC", true, VALID_SIGHASH);
        marker.topic_count = 2;
        marker.params = filtered_a.params.clone();
        marker.topic_selections = vec![selection(None)];

        let core =
            DecoderCore::from_registrations(&[filtered_a, filtered_b, marker], false).unwrap();
        let active = HashSet::from([0, 1, 2]);
        let log = Log {
            topics: vec![Some(VALID_SIGHASH.to_string()), Some(TOPIC1_A.to_string())],
            data: value_log(VALID_SIGHASH).data,
            ..Default::default()
        };
        let routed = core.route_and_decode_napi(&log, None, &active).unwrap();
        assert_eq!(routed_indexes(&routed), vec![0, 2]);
    }

    #[test]
    fn rejects_metakey_collision_with_different_indexed_layout() {
        let sighash = alloy_json_abi::Event::parse("Foo(uint256 a, uint256 b)")
            .unwrap()
            .selector()
            .to_string();
        let variant = |contract: &str, params| OnEventRegistration {
            index: 0,
            sighash: sighash.clone(),
            topic_count: 2,
            event_name: "Foo".to_string(),
            contract_name: contract.to_string(),
            is_wildcard: false,
            depends_on_addresses: false,
            topic_selections: vec![],
            block_fields: vec![],
            transaction_fields: vec![],
            params,
        };

        let err = DecoderCore::from_registrations(
            &[
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
        let variant = |contract: &str, params| OnEventRegistration {
            index: 0,
            sighash: sighash.clone(),
            topic_count: 3,
            event_name: "Transfer".to_string(),
            contract_name: contract.to_string(),
            is_wildcard: false,
            depends_on_addresses: false,
            topic_selections: vec![],
            block_fields: vec![],
            transaction_fields: vec![],
            params,
        };

        DecoderCore::from_registrations(
            &[
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
