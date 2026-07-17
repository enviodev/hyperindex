use std::collections::HashMap;
use std::sync::Arc;

use alloy_dyn_abi::{DecodedEvent, DynSolEvent, DynSolType};
use alloy_primitives::B256;
use anyhow::{Context, Result};
use hypersync_client::format::{Data, Hex, LogArgument};
use hypersync_client::simple_types;

use crate::evm_hypersync_source::selection::TopicSelectionInput;
use crate::evm_hypersync_source::types::{
    sol_value_to_param, Log, OnEventRegistrationInput, ParamMeta, ParamValue,
};

/// A registration's static topic constraints — its resolved `where` in DNF:
/// the outer Vec is an OR of alternatives, each alternative constrains the
/// four topic positions. Per position, `None` matches any value: the position
/// is either unfiltered or carries a `ContractAddresses` marker whose
/// temporal check stays on the JS `clientAddressFilter`. An empty DNF puts no
/// constraint on the registration's logs.
struct TopicFilters(Vec<[Option<Vec<[u8; 32]>>; 4]>);

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
        // An empty value list means match-any (mirroring query semantics),
        // same as a `ContractAddresses` marker (`None` input).
        let parse_position = |values: Option<&Vec<String>>| -> Result<Option<Vec<[u8; 32]>>> {
            match values {
                Some(values) if !values.is_empty() => Ok(Some(parse_values(values)?)),
                _ => Ok(None),
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

    fn matches(&self, topics: &[Option<LogArgument>]) -> bool {
        if self.0.is_empty() {
            return true;
        }
        self.0.iter().any(|alternative| {
            alternative
                .iter()
                .enumerate()
                .all(|(position, filter)| match filter {
                    None => true,
                    Some(values) => topics
                        .get(position)
                        .and_then(Option::as_ref)
                        .is_some_and(|topic| values.iter().any(|v| v == &***topic)),
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
    ) -> bool {
        self.sighash == *topic0
            && self.topic_count == topic_count
            && (self.is_wildcard || contract_name == Some(self.contract_name.as_str()))
            && self.topic_filters.matches(topics)
    }
}

/// All registrations passed at client construction, keyed by their
/// chain-scoped index. Holds no routing state itself — a query resolves its
/// own selection into a `SelectionDecoder` via `selection`.
#[derive(Clone)]
pub(crate) struct DecoderCore {
    registrations: Arc<HashMap<i64, Arc<OnEventRegistration>>>,
    checksummed_addresses: bool,
}

impl DecoderCore {
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
    /// belonging to the selection that fetched it.
    pub(crate) fn selection(&self, registration_indexes: &[i64]) -> Result<SelectionDecoder> {
        let mut registrations = registration_indexes
            .iter()
            .map(|id| {
                self.registrations
                    .get(id)
                    .cloned()
                    .with_context(|| format!("Unknown registration index {id} in query selection"))
            })
            .collect::<Result<Vec<_>>>()?;
        // Deterministic item order per log, independent of the selection's
        // index order.
        registrations.sort_unstable_by_key(|reg| reg.index);
        Ok(SelectionDecoder {
            registrations,
            checksummed_addresses: self.checksummed_addresses,
        })
    }
}

/// One query selection's registrations, in registration order. Routing is a
/// straight scan over them — a selection is small (one partition's events),
/// which also keeps the scan cheaper than a keyed lookup.
pub(crate) struct SelectionDecoder {
    registrations: Vec<Arc<OnEventRegistration>>,
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
    /// Same-signature registrations may declare different indexed/body
    /// splits, and the log's bytes need not be valid under every declaration
    /// — a match that fails to decode just contributes no item. Only when no
    /// match decodes is the failure surfaced as an error: the log was fetched
    /// for these registrations, so silently dropping it would hide genuinely
    /// malformed data or a wrong ABI. An empty result means the log routes
    /// nowhere and is dropped by the caller.
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
        let mut first_decode_err = None;
        for reg in &self.registrations {
            if !reg.matches(topic0, topic_count, contract_name, topics) {
                continue;
            }
            let decoded = match reg.decoder.decode_log_parts(
                topics
                    .iter()
                    .take_while(|t| t.is_some())
                    .map(|t| t.as_ref().unwrap().into()),
                data,
            ) {
                Ok(decoded) => decoded,
                Err(e) => {
                    if first_decode_err.is_none() {
                        first_decode_err = Some(anyhow::Error::new(e).context("decode log"));
                    }
                    continue;
                }
            };
            routed.push(RoutedEvent {
                index: reg.index,
                params: ParamValue::Obj(apply_names(
                    decoded,
                    &reg.params,
                    self.checksummed_addresses,
                )?),
            });
        }
        match (routed.is_empty(), first_decode_err) {
            (true, Some(err)) => Err(err),
            _ => Ok(routed),
        }
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
    fn registration_rejects_zero_topics() {
        let mut reg = value_reg(0, "C", false, VALID_SIGHASH);
        reg.topic_count = 0;
        let err = DecoderCore::from_registrations(&[reg], false)
            .err()
            .unwrap();
        assert!(format!("{err:#}").contains("topic_count must be 1..=4"));
    }

    #[test]
    fn registration_rejects_five_topics() {
        let mut reg = value_reg(0, "C", false, VALID_SIGHASH);
        reg.topic_count = 5;
        let err = DecoderCore::from_registrations(&[reg], false)
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
        assert!(DecoderCore::from_registrations(&[one, four], false).is_ok());
    }

    #[test]
    fn duplicate_registration_index_errors() {
        let err = DecoderCore::from_registrations(
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
        let core = DecoderCore::from_registrations(&[], false).unwrap();
        let err = core.selection(&[7]).err().unwrap();
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

        let core = DecoderCore::from_registrations(
            &[OnEventRegistrationInput {
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
            .selection(&[7])
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
        let core = DecoderCore::from_registrations(
            &[
                value_reg(0, "Owned", false, VALID_SIGHASH),
                value_reg(1, "W1", true, VALID_SIGHASH),
                value_reg(2, "W2", true, VALID_SIGHASH),
                value_reg(3, "Other", false, VALID_SIGHASH),
            ],
            false,
        )
        .unwrap();
        let decoder = core.selection(&[0, 1, 2, 3]).unwrap();
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
        let core = DecoderCore::from_registrations(
            &[
                value_reg(0, "Owned", false, VALID_SIGHASH),
                value_reg(1, "W1", true, VALID_SIGHASH),
            ],
            false,
        )
        .unwrap();
        let log = value_log(VALID_SIGHASH);
        let routed = core
            .selection(&[0])
            .unwrap()
            .route_and_decode_napi(&log, Some("Owned"))
            .unwrap();
        assert_eq!(routed_indexes(&routed), vec![0]);
    }

    #[test]
    fn static_topic_filters_reapplied_per_registration() {
        const TOPIC1_A: &str = "0x00000000000000000000000000000000000000000000000000000000000000aa";
        const TOPIC1_B: &str = "0x00000000000000000000000000000000000000000000000000000000000000bb";
        let selection = |topic1| TopicSelectionInput {
            topic0: vec![VALID_SIGHASH.to_string()],
            topic1,
            topic2: Some(vec![]),
            topic3: Some(vec![]),
        };
        // Three same-signature wildcards: one filtering topic1 to A, one to B,
        // and one with a ContractAddresses marker (None) that Rust must treat
        // as match-any (the JS clientAddressFilter owns that check).
        let mut filtered_a = value_reg(0, "WA", true, VALID_SIGHASH);
        filtered_a.topic_count = 2;
        filtered_a.params = vec![pm("who", "address", true), pm("value", "uint256", false)];
        filtered_a.topic_selections = vec![selection(Some(vec![TOPIC1_A.to_string()]))];
        let mut filtered_b = value_reg(1, "WB", true, VALID_SIGHASH);
        filtered_b.topic_count = 2;
        filtered_b.params = filtered_a.params.clone();
        filtered_b.topic_selections = vec![selection(Some(vec![TOPIC1_B.to_string()]))];
        let mut marker = value_reg(2, "WC", true, VALID_SIGHASH);
        marker.topic_count = 2;
        marker.params = filtered_a.params.clone();
        marker.topic_selections = vec![selection(None)];

        let core =
            DecoderCore::from_registrations(&[filtered_a, filtered_b, marker], false).unwrap();
        let log = Log {
            topics: vec![Some(VALID_SIGHASH.to_string()), Some(TOPIC1_A.to_string())],
            data: value_log(VALID_SIGHASH).data,
            ..Default::default()
        };
        let routed = core
            .selection(&[0, 1, 2])
            .unwrap()
            .route_and_decode_napi(&log, None)
            .unwrap();
        assert_eq!(routed_indexes(&routed), vec![0, 2]);
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
        let core = DecoderCore::from_registrations(
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
            .selection(&[0, 1])
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
        let core = DecoderCore::from_registrations(
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
            .selection(&[0, 1])
            .unwrap()
            .route_and_decode_napi(&log, None)
            .unwrap();
        assert_eq!(routed_indexes(&routed), vec![0]);

        // With only the failing declaration matched, the decode error surfaces
        // instead of the log silently disappearing.
        let err = core
            .selection(&[1])
            .unwrap()
            .route_and_decode_napi(&log, None)
            .err()
            .expect("expected a decode error when no matched declaration decodes");
        assert!(format!("{err:#}").contains("decode log"));
    }
}
