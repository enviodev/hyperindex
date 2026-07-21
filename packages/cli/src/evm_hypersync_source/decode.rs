use std::collections::HashMap;
use std::sync::Arc;

use alloy_dyn_abi::{DecodedEvent, DynSolEvent, DynSolType};
use alloy_primitives::B256;
use anyhow::{Context, Result};
use hypersync_client::format::{Data, Hex, LogArgument};
use hypersync_client::simple_types;

use crate::evm_hypersync_source::selection::{address_to_topic_bytes, TopicSelectionInput};
use crate::evm_hypersync_source::types::{
    sol_value_to_param, Log, OnEventRegistrationInput, ParamMeta, ParamValue,
};

/// One topic position's constraint, resolved from a registration's `where`.
enum TopicConstraint {
    /// Unfiltered — matches any value.
    Any,
    /// Matches when the log's topic is one of these values.
    Values(Vec<[u8; 32]>),
    /// A `ContractAddresses` marker: matches the padded topic of one of the
    /// registration's contract's currently registered addresses. Resolved at
    /// routing time from the partition's address index (see
    /// `SelectionDecoder`); the temporal `effectiveStartBlock` check stays on
    /// the JS `clientAddressFilter`.
    ContractAddresses,
}

/// A registration's static topic constraints — its resolved `where` in DNF:
/// the outer Vec is an OR of alternatives, each alternative constrains the
/// four topic positions. A registration with no `where` carries one all-`Any`
/// alternative. (A `where: false` registration resolves to an empty DNF, but
/// it's dropped at registration and never reaches routing — see
/// `HandlerRegister`; an empty DNF here would just match nothing.)
struct TopicFilters(Vec<[TopicConstraint; 4]>);

impl TopicFilters {
    fn parse(topic_selections: &[TopicSelectionInput]) -> Result<Self> {
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
        // topic1..3 cross the boundary as `Option<Vec<String>>`: `None` is a
        // `ContractAddresses` marker, `Some([])` is unfiltered, and a non-empty
        // list is a static value set. topic0 is always a concrete value set.
        let parse_position = |input: Option<&Vec<String>>| -> Result<TopicConstraint> {
            match input {
                None => Ok(TopicConstraint::ContractAddresses),
                Some(values) if values.is_empty() => Ok(TopicConstraint::Any),
                Some(values) => Ok(TopicConstraint::Values(parse_values(values)?)),
            }
        };
        let alternatives = topic_selections
            .iter()
            .map(|ts| {
                Ok([
                    parse_position(Some(&ts.topic0))?,
                    parse_position(ts.topic1.as_ref())?,
                    parse_position(ts.topic2.as_ref())?,
                    parse_position(ts.topic3.as_ref())?,
                ])
            })
            .collect::<Result<_>>()?;
        Ok(Self(alternatives))
    }

    /// Whether a log's topics satisfy any DNF alternative. `contract_address_topics`
    /// are the padded topics of the registration's contract's current addresses,
    /// used to resolve `ContractAddresses` markers.
    fn matches(
        &self,
        topics: &[Option<LogArgument>],
        contract_address_topics: &[[u8; 32]],
    ) -> bool {
        // No explicit empty-DNF guard: `any` over zero alternatives is already
        // `false`. (An empty DNF is `where: false`, which is dropped at
        // registration and never reaches here.)
        self.0.iter().any(|alternative| {
            alternative
                .iter()
                .enumerate()
                .all(|(position, constraint)| {
                    let allowed: &[[u8; 32]] = match constraint {
                        TopicConstraint::Any => return true,
                        TopicConstraint::Values(values) => values,
                        TopicConstraint::ContractAddresses => contract_address_topics,
                    };
                    topics
                        .get(position)
                        .and_then(Option::as_ref)
                        .is_some_and(|topic| allowed.iter().any(|v| v == &***topic))
                })
        })
    }
}

/// Everything needed to match a log against one registration and decode it
/// under that registration's own ABI declaration. Registrations sharing an
/// event signature stay fully independent — each carries its own decoder, so
/// they may name params differently and even split indexed/body params
/// differently.
struct OnEventRegistration {
    index: i64,
    sighash: [u8; 32],
    topic_count: u8,
    contract_name: String,
    is_wildcard: bool,
    topic_filters: TopicFilters,
    params: Vec<ParamMeta>,
    decoder: DynSolEvent,
}

impl OnEventRegistration {
    fn parse(ep: &OnEventRegistrationInput) -> Result<Self> {
        let sighash = LogArgument::decode_hex(&ep.sighash).context("decode sighash hex")?;
        let topic_count: u8 =
            u8::try_from(ep.topic_count).context("topic_count out of u8 range")?;
        anyhow::ensure!(
            (1..=4).contains(&topic_count),
            "topic_count must be 1..=4, got {topic_count}",
        );
        Ok(Self {
            index: ep.index,
            sighash: **sighash,
            topic_count,
            contract_name: ep.contract_name.clone(),
            is_wildcard: ep.is_wildcard,
            topic_filters: TopicFilters::parse(&ep.topic_selections)
                .context("parse topic filters")?,
            params: ep.params.clone(),
            decoder: build_event_decoder(**sighash, &ep.params).context("build decoder")?,
        })
    }

    /// Whether a log belongs to this registration: same event signature
    /// (topic0 + topic count), an allowed emitter (wildcard registrations
    /// accept any address, contract-bound registrations only their own
    /// contract's — no fallback tier between them), and the registration's
    /// static topic filters.
    fn matches(
        &self,
        topic0: &[u8; 32],
        topic_count: u8,
        contract_name: Option<&str>,
        topics: &[Option<LogArgument>],
        contract_address_topics: &[[u8; 32]],
    ) -> bool {
        self.sighash == *topic0
            && self.topic_count == topic_count
            && (self.is_wildcard || contract_name == Some(self.contract_name.as_str()))
            && self.topic_filters.matches(topics, contract_address_topics)
    }
}

/// All registrations passed at client construction, keyed by their
/// chain-scoped index. Holds no routing state itself — a query resolves its
/// own selection into a `SelectionDecoder` via `selection`.
#[derive(Clone)]
pub(crate) struct Decoder {
    registrations: Arc<HashMap<i64, Arc<OnEventRegistration>>>,
    checksummed_addresses: bool,
}

impl Decoder {
    pub(crate) fn from_registrations(
        registrations: &[OnEventRegistrationInput],
        checksum_addresses: bool,
    ) -> Result<Self> {
        let mut map = HashMap::new();
        for ep in registrations {
            let parsed = OnEventRegistration::parse(ep)
                .with_context(|| format!("parse registration for {}", ep.event_name))?;
            anyhow::ensure!(
                map.insert(ep.index, Arc::new(parsed)).is_none(),
                "Duplicate registration index {} for event {}",
                ep.index,
                ep.event_name,
            );
        }
        Ok(Self {
            registrations: Arc::new(map),
            checksummed_addresses: checksum_addresses,
        })
    }

    /// Resolves a query's registration selection into the decoder its response
    /// logs route through, so a log can only ever route to a registration
    /// belonging to the selection that fetched it. Each registration's
    /// `ContractAddresses` markers are materialized from `addresses_by_contract_name`
    /// (the same per-query addresses the log selections were built from).
    pub(crate) fn selection(
        &self,
        registration_indexes: &[i64],
        addresses_by_contract_name: &HashMap<String, Vec<String>>,
    ) -> Result<SelectionDecoder> {
        let mut registrations = registration_indexes
            .iter()
            .map(|id| {
                let registration = self.registrations.get(id).cloned().with_context(|| {
                    format!("Unknown registration index {id} in query selection")
                })?;
                let contract_address_topics = addresses_by_contract_name
                    .get(&registration.contract_name)
                    .map(|addresses| {
                        addresses
                            .iter()
                            .map(|a| address_to_topic_bytes(a))
                            .collect::<Result<Vec<_>>>()
                    })
                    .transpose()?
                    .unwrap_or_default();
                Ok(SelectedRegistration {
                    registration,
                    contract_address_topics,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        // Deterministic item order per log, independent of the selection's
        // index order.
        registrations.sort_unstable_by_key(|sel| sel.registration.index);
        Ok(SelectionDecoder {
            registrations,
            checksummed_addresses: self.checksummed_addresses,
        })
    }
}

/// A selection's registration paired with the padded topics of its contract's
/// current addresses, resolving the registration's `ContractAddresses` markers.
struct SelectedRegistration {
    registration: Arc<OnEventRegistration>,
    contract_address_topics: Vec<[u8; 32]>,
}

/// One query selection's registrations, in registration order. Routing is a
/// straight scan over them — a selection is small (one partition's events),
/// which also keeps the scan cheaper than a keyed lookup.
pub(crate) struct SelectionDecoder {
    registrations: Vec<SelectedRegistration>,
    checksummed_addresses: bool,
}

impl SelectionDecoder {
    pub(crate) fn checksummed_addresses(&self) -> bool {
        self.checksummed_addresses
    }

    pub(crate) fn route_and_decode_napi(
        &self,
        log: &Log,
        contract_name: Option<&str>,
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
        self.route_and_decode(&topics, &data, contract_name)
    }

    pub(crate) fn route_and_decode_simple(
        &self,
        log: &simple_types::Log,
        contract_name: Option<&str>,
    ) -> Result<Vec<RoutedEvent>> {
        let data = log.data.as_ref().context("get log.data")?;
        self.route_and_decode(&log.topics, data, contract_name)
    }

    /// Fans a log out to every registration of the selection it matches
    /// (see `OnEventRegistration::matches`), decoding it under each match's own
    /// ABI declaration. `contract_name` is the log address's owning contract
    /// per the partition's address index.
    ///
    /// Same-signature registrations may declare different indexed/body splits,
    /// and the log's bytes need not be valid under every declaration — a match
    /// that fails to decode (or to name its params) just contributes no item.
    /// A decode failure is benign whether or not a sibling in the selection
    /// happens to decode: a wildcard registration routinely fetches foreign
    /// same-signature logs whose indexed split its own declaration can't read,
    /// so those are dropped, not surfaced. Only a structurally malformed log
    /// (missing topic0, more topics than fit) is an error. An empty result
    /// means the log routes nowhere and is dropped by the caller.
    fn route_and_decode(
        &self,
        topics: &[Option<LogArgument>],
        data: &Data,
        contract_name: Option<&str>,
    ) -> Result<Vec<RoutedEvent>> {
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

        let mut routed = Vec::new();
        for sel in &self.registrations {
            let reg = &sel.registration;
            if !reg.matches(
                topic0,
                topic_count,
                contract_name,
                topics,
                &sel.contract_address_topics,
            ) {
                continue;
            }
            let decoded = reg.decoder.decode_log_parts(
                topics
                    .iter()
                    .take_while(|t| t.is_some())
                    .map(|t| t.as_ref().unwrap().into()),
                data,
            );
            let fields = decoded.ok().and_then(|decoded| {
                apply_names(decoded, &reg.params, self.checksummed_addresses).ok()
            });
            if let Some(fields) = fields {
                routed.push(RoutedEvent {
                    index: reg.index,
                    params: ParamValue::Obj(fields),
                });
            }
        }
        Ok(routed)
    }
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

/// Build the positional decoder for one registration. The decoder's topic0 is
/// pinned to the on-chain sighash the registration carries rather than derived
/// from a signature string, so an event surfaced to handlers under a different
/// `name:` (display name != on-chain name) still matches its real log (issue
/// #1285). The event name plays no part in decoding — only the param types do.
fn build_event_decoder(sighash: [u8; 32], params: &[ParamMeta]) -> Result<DynSolEvent> {
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
    DynSolEvent::new(Some(B256::from(sighash)), indexed, DynSolType::Tuple(body))
        .context("construct event decoder")
}

#[cfg(test)]
mod tests {
    use super::*;

    const VALID_SIGHASH: &str =
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";

    fn pm(name: &str, abi_type: &str, indexed: bool) -> ParamMeta {
        ParamMeta {
            name: name.to_string(),
            abi_type: abi_type.to_string(),
            indexed,
            components: None,
        }
    }

    // A no-`where` selection for `sighash`: one alternative that pins topic0
    // and leaves the rest unconstrained (the shape `LogSelection` builds for a
    // registration without a `where`). An empty `topic_selections` would mean
    // `where: false` (match nothing), so tests that expect a match use this.
    fn no_filter_selection(sighash: &str) -> Vec<TopicSelectionInput> {
        vec![TopicSelectionInput {
            topic0: vec![sighash.to_string()],
            topic1: Some(vec![]),
            topic2: Some(vec![]),
            topic3: Some(vec![]),
        }]
    }

    // A one-body-param registration with an arbitrary sighash and topic count 1,
    // so logs are easy to fabricate.
    fn value_reg(
        index: i64,
        contract_name: &str,
        is_wildcard: bool,
        sighash: &str,
    ) -> OnEventRegistrationInput {
        OnEventRegistrationInput {
            index,
            sighash: sighash.to_string(),
            topic_count: 1,
            event_name: "E".to_string(),
            contract_name: contract_name.to_string(),
            is_wildcard,
            depends_on_addresses: false,
            topic_selections: no_filter_selection(sighash),
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
    fn registration_rejects_zero_topics() {
        let mut reg = value_reg(0, "C", false, VALID_SIGHASH);
        reg.topic_count = 0;
        let err = Decoder::from_registrations(&[reg], false)
            .err()
            .unwrap();
        assert!(format!("{err:#}").contains("topic_count must be 1..=4"));
    }

    #[test]
    fn registration_rejects_five_topics() {
        let mut reg = value_reg(0, "C", false, VALID_SIGHASH);
        reg.topic_count = 5;
        let err = Decoder::from_registrations(&[reg], false)
            .err()
            .unwrap();
        assert!(format!("{err:#}").contains("topic_count must be 1..=4"));
    }

    #[test]
    fn registration_accepts_boundary_topic_counts() {
        let mut one = value_reg(0, "C", false, VALID_SIGHASH);
        one.topic_count = 1;
        let mut four = value_reg(1, "C", false, VALID_SIGHASH);
        four.topic_count = 4;
        assert!(Decoder::from_registrations(&[one, four], false).is_ok());
    }

    #[test]
    fn duplicate_registration_index_errors() {
        let err = Decoder::from_registrations(
            &[
                value_reg(0, "C", false, VALID_SIGHASH),
                value_reg(0, "D", false, VALID_SIGHASH),
            ],
            false,
        )
        .err()
        .unwrap();
        assert!(format!("{err:#}").contains("Duplicate registration index 0"));
    }

    #[test]
    fn unknown_registration_index_errors() {
        let core = Decoder::from_registrations(&[], false).unwrap();
        let err = core.selection(&[7], &HashMap::new()).err().unwrap();
        assert!(format!("{err:#}").contains("Unknown registration index 7"));
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

        let core = Decoder::from_registrations(
            &[OnEventRegistrationInput {
                index: 7,
                sighash: real_sighash.clone(),
                topic_count: 1,
                event_name: "ApprovalRenamed".to_string(),
                contract_name: "TestContract".to_string(),
                is_wildcard: false,
                depends_on_addresses: false,
                topic_selections: no_filter_selection(&real_sighash),
                block_fields: vec![],
                transaction_fields: vec![],
                params: vec![pm("owner", "address", false), pm("value", "uint256", false)],
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
            .selection(&[7], &HashMap::new())
            .unwrap()
            .route_and_decode_napi(&log, Some("TestContract"))
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

    #[test]
    fn fans_out_to_wildcards_and_owned_contract_without_fallback_tier() {
        let core = Decoder::from_registrations(
            &[
                value_reg(0, "Owned", false, VALID_SIGHASH),
                value_reg(1, "W1", true, VALID_SIGHASH),
                value_reg(2, "W2", true, VALID_SIGHASH),
                value_reg(3, "Other", false, VALID_SIGHASH),
            ],
            false,
        )
        .unwrap();
        let decoder = core.selection(&[0, 1, 2, 3], &HashMap::new()).unwrap();
        let log = value_log(VALID_SIGHASH);

        // Owned address: the contract's registration plus every wildcard.
        let owned = decoder.route_and_decode_napi(&log, Some("Owned")).unwrap();
        assert_eq!(routed_indexes(&owned), vec![0, 1, 2]);

        // Unowned address: wildcards only — no fallback into contract-bound
        // registrations.
        let unowned = decoder.route_and_decode_napi(&log, None).unwrap();
        assert_eq!(routed_indexes(&unowned), vec![1, 2]);
    }

    #[test]
    fn routing_scoped_to_query_selection() {
        let core = Decoder::from_registrations(
            &[
                value_reg(0, "Owned", false, VALID_SIGHASH),
                value_reg(1, "W1", true, VALID_SIGHASH),
            ],
            false,
        )
        .unwrap();
        let log = value_log(VALID_SIGHASH);
        let routed = core
            .selection(&[0], &HashMap::new())
            .unwrap()
            .route_and_decode_napi(&log, Some("Owned"))
            .unwrap();
        assert_eq!(routed_indexes(&routed), vec![0]);
    }

    #[test]
    fn empty_dnf_matches_nothing() {
        // Defensive: a `where: false` registration (empty DNF) is dropped at
        // registration and never reaches routing, but if one ever did — even
        // sharing a signature with a broad sibling that fetches the log — it
        // must match nothing rather than everything.
        let mut disabled = value_reg(0, "Disabled", true, VALID_SIGHASH);
        disabled.topic_selections = vec![];
        let sibling = value_reg(1, "Live", true, VALID_SIGHASH);

        let core = Decoder::from_registrations(&[disabled, sibling], false).unwrap();
        let routed = core
            .selection(&[0, 1], &HashMap::new())
            .unwrap()
            .route_and_decode_napi(&value_log(VALID_SIGHASH), None)
            .unwrap();
        assert_eq!(routed_indexes(&routed), vec![1]);
    }

    // One indexed address param + one body value, so a topic1-filtered log
    // decodes cleanly (topic_count 2).
    fn indexed_address_params() -> Vec<ParamMeta> {
        vec![pm("who", "address", true), pm("value", "uint256", false)]
    }

    fn addr_topic(byte: &str) -> String {
        format!("0x{}{}", "0".repeat(62), byte)
    }

    #[test]
    fn static_topic_filters_reapplied_per_registration() {
        let topic1_a = addr_topic("aa");
        let topic1_b = addr_topic("bb");
        let selection = |topic1| TopicSelectionInput {
            topic0: vec![VALID_SIGHASH.to_string()],
            topic1,
            topic2: Some(vec![]),
            topic3: Some(vec![]),
        };
        // Two same-signature wildcards filtering topic1 to A vs B; a topic1=A
        // log matches only the A-filtered registration.
        let mut filtered_a = value_reg(0, "WA", true, VALID_SIGHASH);
        filtered_a.topic_count = 2;
        filtered_a.params = indexed_address_params();
        filtered_a.topic_selections = vec![selection(Some(vec![topic1_a.clone()]))];
        let mut filtered_b = value_reg(1, "WB", true, VALID_SIGHASH);
        filtered_b.topic_count = 2;
        filtered_b.params = indexed_address_params();
        filtered_b.topic_selections = vec![selection(Some(vec![topic1_b]))];

        let core = Decoder::from_registrations(&[filtered_a, filtered_b], false).unwrap();
        let log = Log {
            topics: vec![Some(VALID_SIGHASH.to_string()), Some(topic1_a)],
            data: value_log(VALID_SIGHASH).data,
            ..Default::default()
        };
        let routed = core
            .selection(&[0, 1], &HashMap::new())
            .unwrap()
            .route_and_decode_napi(&log, None)
            .unwrap();
        assert_eq!(routed_indexes(&routed), vec![0]);
    }

    // A wildcard registration whose topic1 filter is a `ContractAddresses`
    // marker (`chain.C.addresses`, spelled `None` across the boundary).
    fn marker_reg(index: i64, contract: &str) -> OnEventRegistrationInput {
        let mut reg = value_reg(index, contract, true, VALID_SIGHASH);
        reg.topic_count = 2;
        reg.params = indexed_address_params();
        reg.topic_selections = vec![TopicSelectionInput {
            topic0: vec![VALID_SIGHASH.to_string()],
            topic1: None,
            topic2: Some(vec![]),
            topic3: Some(vec![]),
        }];
        reg
    }

    fn address_param_log(topic1: &str) -> Log {
        Log {
            topics: vec![Some(VALID_SIGHASH.to_string()), Some(topic1.to_string())],
            data: value_log(VALID_SIGHASH).data,
            ..Default::default()
        }
    }

    #[test]
    fn contract_addresses_marker_materialized_from_query_addresses() {
        let core = Decoder::from_registrations(&[marker_reg(0, "C")], false).unwrap();
        let addresses = HashMap::from([(
            "C".to_string(),
            vec!["0x00000000000000000000000000000000000000aa".to_string()],
        )]);
        let decoder = core.selection(&[0], &addresses).unwrap();

        // topic1 is C's registered address → the marker matches.
        let owned = decoder
            .route_and_decode_napi(&address_param_log(&addr_topic("aa")), None)
            .unwrap();
        assert_eq!(routed_indexes(&owned), vec![0]);

        // topic1 is not one of C's addresses → the marker excludes it.
        let foreign = decoder
            .route_and_decode_napi(&address_param_log(&addr_topic("bb")), None)
            .unwrap();
        assert!(foreign.is_empty());
    }

    #[test]
    fn marker_registration_excludes_sibling_fan_out_from_other_contracts() {
        // The P1: a wildcard-by-address registration (contract C, topic1 =
        // chain.C.addresses) shares a signature with a broad sibling that
        // fetches the same logs. A sibling log carrying a different contract's
        // address must not fan out to the marker registration — routing
        // excludes it rather than relying on the JS filter's global check.
        let mut sibling = value_reg(1, "S", true, VALID_SIGHASH);
        sibling.topic_count = 2;
        sibling.params = indexed_address_params();

        let core = Decoder::from_registrations(&[marker_reg(0, "C"), sibling], false).unwrap();
        let addresses = HashMap::from([(
            "C".to_string(),
            vec!["0x00000000000000000000000000000000000000aa".to_string()],
        )]);
        // Foreign address (0x..bb) in topic1: only the broad sibling matches.
        let routed = core
            .selection(&[0, 1], &addresses)
            .unwrap()
            .route_and_decode_napi(&address_param_log(&addr_topic("bb")), None)
            .unwrap();
        assert_eq!(routed_indexes(&routed), vec![1]);
    }

    #[test]
    fn same_signature_with_different_indexed_layout_decodes_per_registration() {
        use alloy_dyn_abi::DynSolValue;
        use alloy_primitives::{hex, U256};

        let sighash = alloy_json_abi::Event::parse("Foo(uint256 a, uint256 b)")
            .unwrap()
            .selector()
            .to_string();
        let variant = |index, contract: &str, params| {
            let mut reg = value_reg(index, contract, true, &sighash);
            reg.topic_count = 2;
            reg.params = params;
            reg
        };
        let core = Decoder::from_registrations(
            &[
                variant(
                    0,
                    "C1",
                    vec![pm("a", "uint256", true), pm("b", "uint256", false)],
                ),
                variant(
                    1,
                    "C2",
                    vec![pm("a", "uint256", false), pm("b", "uint256", true)],
                ),
            ],
            false,
        )
        .expect("different indexed layouts on one signature must register");

        // A log emitted with `a` indexed: topic1 = 7, data = (8,).
        let data = DynSolValue::Tuple(vec![DynSolValue::Uint(U256::from(8u64), 256)]).abi_encode();
        let log = Log {
            topics: vec![Some(sighash.clone()), Some(format!("0x{:064x}", 7))],
            data: Some(format!("0x{}", hex::encode(data))),
            ..Default::default()
        };
        let routed = core
            .selection(&[0, 1], &HashMap::new())
            .unwrap()
            .route_and_decode_napi(&log, None)
            .unwrap();
        // Both declarations decode this log (same word-sized types either
        // way), each reading the topic/body split its own registration
        // declared.
        let values: Vec<(i64, Vec<String>)> = routed
            .iter()
            .map(|r| {
                let fields = match &r.params {
                    ParamValue::Obj(fields) => {
                        fields.iter().map(|(name, _)| name.clone()).collect()
                    }
                    _ => panic!("expected an object of params"),
                };
                (r.index, fields)
            })
            .collect();
        assert_eq!(
            values,
            vec![
                (0, vec!["a".to_string(), "b".to_string()]),
                (1, vec!["a".to_string(), "b".to_string()]),
            ]
        );
    }

    #[test]
    fn declaration_that_fails_to_decode_drops_only_its_own_registration() {
        use alloy_dyn_abi::DynSolValue;
        use alloy_primitives::{hex, U256};

        let sighash = alloy_json_abi::Event::parse("Foo(string a, uint256 b)")
            .unwrap()
            .selector()
            .to_string();
        let variant = |index, contract: &str, params| {
            let mut reg = value_reg(index, contract, true, &sighash);
            reg.topic_count = 2;
            reg.params = params;
            reg
        };
        let core = Decoder::from_registrations(
            &[
                variant(
                    0,
                    "C1",
                    vec![pm("a", "string", true), pm("b", "uint256", false)],
                ),
                variant(
                    1,
                    "C2",
                    vec![pm("a", "string", false), pm("b", "uint256", true)],
                ),
            ],
            false,
        )
        .unwrap();

        // Emitted under C1's declaration: topic1 = keccak(a), body = (8,).
        // C2's declaration reads the body as a string tuple — word 8 as an
        // offset past the data — which fails to decode; only C1's item
        // survives.
        let data = DynSolValue::Tuple(vec![DynSolValue::Uint(U256::from(8u64), 256)]).abi_encode();
        let log = Log {
            topics: vec![Some(sighash.clone()), Some(format!("0x{:064x}", 7))],
            data: Some(format!("0x{}", hex::encode(data))),
            ..Default::default()
        };
        let routed = core
            .selection(&[0, 1], &HashMap::new())
            .unwrap()
            .route_and_decode_napi(&log, None)
            .unwrap();
        assert_eq!(routed_indexes(&routed), vec![0]);

        // With only the failing declaration matched, the log drops rather than
        // erroring — a decode failure is a benign "not this declaration's log",
        // not malformed data (a wildcard registration routinely fetches foreign
        // same-signature logs it can't read under its own indexed split).
        let routed = core
            .selection(&[1], &HashMap::new())
            .unwrap()
            .route_and_decode_napi(&log, None)
            .unwrap();
        assert!(routed.is_empty());
    }
}
