use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use alloy_dyn_abi::{DecodedEvent, DynSolEvent, DynSolType};
use alloy_primitives::B256;
use anyhow::{Context, Result};
use hypersync_client::format::{Data, Hex, LogArgument};
use hypersync_client::simple_types;

use crate::address_store::{AddressStore, SetCache, StoreInner};
use crate::evm_hypersync_source::selection::TopicSelectionInput;
use crate::evm_hypersync_source::types::{
    sol_value_to_param, Log, OnEventRegistrationInput, ParamMeta, ParamValue,
};

/// One topic position's constraint, resolved from a registration's `where`.
enum TopicConstraint {
    /// Unfiltered — matches any value.
    Any,
    /// Matches when the log's topic is one of these values.
    Values(Vec<[u8; 32]>),
    /// A `ContractAddresses` marker: the topic must be the padded form of an
    /// address this partition holds for the registration's own contract, at or
    /// before the log's block. Ownership is the partition set's answer — the
    /// query materialised this position from that same set, so a sibling
    /// selection's log carrying another partition's address must not fan out
    /// here. The store answers only the temporal half, dropping a value
    /// registered after the log's block that a merged partition over-fetched.
    ContractAddresses,
}

/// The emitter facts every address gate reads off a log: its binary address,
/// the contract this partition's set says owns that address (`None` when the
/// partition doesn't hold it), and the log's block.
pub(crate) struct LogAddress<'a> {
    pub key: &'a [u8],
    pub contract_name: Option<&'a str>,
    pub block_number: i64,
}

/// The 20 address bytes of a padded indexed topic, or `None` when the topic's
/// upper bytes aren't zero — then it isn't an address at all.
fn topic_address(topic: &LogArgument) -> Option<&[u8]> {
    let bytes: &[u8; 32] = topic;
    bytes[..12].iter().all(|b| *b == 0).then(|| &bytes[12..])
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

    /// Whether a log's topics satisfy any DNF alternative. `ContractAddresses`
    /// markers resolve against the partition's set under `contract_name`, then
    /// against the store for the `effectiveStartBlock` gate. A client-filtered
    /// contract (`force_wildcard`) has no addresses in the set, so there the
    /// store answers ownership too.
    #[allow(clippy::too_many_arguments)]
    fn matches(
        &self,
        topics: &[Option<LogArgument>],
        contract_name: &str,
        contract_idx: u32,
        block_number: i64,
        force_wildcard: bool,
        cache: &SetCache,
        store: &StoreInner,
    ) -> bool {
        // No explicit empty-DNF guard: `any` over zero alternatives is already
        // `false`. (An empty DNF is `where: false`, which is dropped at
        // registration and never reaches here.)
        self.0.iter().any(|alternative| {
            alternative
                .iter()
                .enumerate()
                .all(|(position, constraint)| {
                    let topic = match topics.get(position).and_then(Option::as_ref) {
                        Some(topic) => topic,
                        // An absent topic satisfies only an unconstrained position.
                        None => return matches!(constraint, TopicConstraint::Any),
                    };
                    match constraint {
                        TopicConstraint::Any => true,
                        TopicConstraint::Values(values) => values.iter().any(|v| v == &***topic),
                        TopicConstraint::ContractAddresses => {
                            topic_address(topic).is_some_and(|key| {
                                (force_wildcard || cache.owner_of(key) == Some(contract_name))
                                    && store.is_indexed_at(key, contract_idx, block_number)
                            })
                        }
                    }
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
    /// This registration's contract in the chain's address store, resolved once
    /// at construction so every per-log gate is an index compare.
    contract_idx: u32,
    is_wildcard: bool,
    /// Earliest block this registration accepts; `None` is unrestricted.
    start_block: Option<i64>,
    topic_filters: TopicFilters,
    params: Vec<ParamMeta>,
    decoder: DynSolEvent,
}

impl OnEventRegistration {
    fn parse(ep: &OnEventRegistrationInput, store: &StoreInner) -> Result<Self> {
        let sighash = LogArgument::decode_hex(&ep.sighash).context("decode sighash hex")?;
        let topic_count: u8 =
            u8::try_from(ep.topic_count).context("topic_count out of u8 range")?;
        anyhow::ensure!(
            (1..=4).contains(&topic_count),
            "topic_count must be 1..=4, got {topic_count}",
        );
        let contract_idx = store.contract_idx(&ep.contract_name).with_context(|| {
            format!(
                "Contract {} is missing from the chain's address store",
                ep.contract_name
            )
        })?;
        Ok(Self {
            index: ep.index,
            sighash: **sighash,
            topic_count,
            contract_name: ep.contract_name.clone(),
            contract_idx,
            is_wildcard: ep.is_wildcard,
            start_block: ep.start_block,
            topic_filters: TopicFilters::parse(&ep.topic_selections)
                .context("parse topic filters")?,
            params: ep.params.clone(),
            decoder: build_event_decoder(**sighash, &ep.params).context("build decoder")?,
        })
    }

    /// Whether a log belongs to this registration: same event signature
    /// (topic0 + topic count), at or after the registration's own start block,
    /// an allowed emitter, and the registration's topic filters.
    ///
    /// Emitter rules. A wildcard registration accepts any address. A
    /// contract-bound one accepts only an address this partition's set holds for
    /// its own contract (`address.contract_name`), registered at or before the
    /// log's block — the temporal half matters even when the partition fetched
    /// the address server-side, because a merged partition's addresses don't all
    /// start at the same block. A client-filtered contract has none of its
    /// addresses in the query, so there the store answers ownership on its own.
    #[allow(clippy::too_many_arguments)]
    fn matches(
        &self,
        topic0: &[u8; 32],
        topic_count: u8,
        topics: &[Option<LogArgument>],
        address: &LogAddress,
        force_wildcard: bool,
        cache: &SetCache,
        store: &StoreInner,
    ) -> bool {
        self.sighash == *topic0
            && self.topic_count == topic_count
            && crate::registration_start_block::has_started(self.start_block, address.block_number)
            && (self.is_wildcard
                || ((force_wildcard || address.contract_name == Some(self.contract_name.as_str()))
                    && store.is_indexed_at(address.key, self.contract_idx, address.block_number)))
            && self.topic_filters.matches(
                topics,
                &self.contract_name,
                self.contract_idx,
                address.block_number,
                force_wildcard,
                cache,
                store,
            )
    }
}

/// All registrations passed at client construction, keyed by their
/// chain-scoped index. Holds no routing state itself — a query resolves its
/// own selection into a `SelectionDecoder` via `selection`.
#[derive(Clone)]
pub(crate) struct Decoder {
    registrations: Arc<HashMap<i64, Arc<OnEventRegistration>>>,
    checksummed_addresses: bool,
    /// The chain's address index, shared with the fetch state. Every address
    /// gate reads it; nothing here writes to it.
    store: Arc<RwLock<StoreInner>>,
}

impl Decoder {
    pub(crate) fn from_registrations(
        registrations: &[OnEventRegistrationInput],
        checksum_addresses: bool,
        address_store: &AddressStore,
    ) -> Result<Self> {
        let handle = address_store.handle();
        let mut map = HashMap::new();
        {
            let store = handle.read().unwrap();
            for ep in registrations {
                let parsed = OnEventRegistration::parse(ep, &store)
                    .with_context(|| format!("parse registration for {}", ep.event_name))?;
                anyhow::ensure!(
                    map.insert(ep.index, Arc::new(parsed)).is_none(),
                    "Duplicate registration index {} for event {}",
                    ep.index,
                    ep.event_name,
                );
            }
        }
        Ok(Self {
            registrations: Arc::new(map),
            checksummed_addresses: checksum_addresses,
            store: handle,
        })
    }

    #[cfg(test)]
    pub(crate) fn store_handle(&self) -> &Arc<RwLock<StoreInner>> {
        &self.store
    }

    /// Resolves a query's registration selection into the decoder its response
    /// logs route through, so a log can only ever route to a registration
    /// belonging to the selection that fetched it.
    pub(crate) fn selection(
        &self,
        registration_indexes: &[i64],
        client_filtered: &crate::client_filtered_contracts::ClientFilteredContracts,
        cache: Arc<SetCache>,
    ) -> Result<SelectionDecoder> {
        let mut registrations = registration_indexes
            .iter()
            .map(|id| {
                let registration = self.registrations.get(id).cloned().with_context(|| {
                    format!("Unknown registration index {id} in query selection")
                })?;
                // A client-filtered contract is queried address-free and holds
                // no addresses in the partition's set, so the store alone
                // decides which emitters it accepts.
                let force_wildcard = client_filtered.applies(&registration.contract_name);
                Ok(SelectedRegistration {
                    registration,
                    force_wildcard,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        // Deterministic item order per log, independent of the selection's
        // index order.
        registrations.sort_unstable_by_key(|sel| sel.registration.index);
        Ok(SelectionDecoder {
            registrations,
            checksummed_addresses: self.checksummed_addresses,
            store: self.store.clone(),
            cache,
        })
    }
}

struct SelectedRegistration {
    registration: Arc<OnEventRegistration>,
    /// The contract is client-side filtered: this query carries none of its
    /// addresses, so partition ownership can't be asserted and the store's
    /// chain-wide answer stands alone.
    force_wildcard: bool,
}

/// One query selection's registrations, in registration order. Routing is a
/// straight scan over them — a selection is small (one partition's events),
/// which also keeps the scan cheaper than a keyed lookup.
pub(crate) struct SelectionDecoder {
    registrations: Vec<SelectedRegistration>,
    checksummed_addresses: bool,
    store: Arc<RwLock<StoreInner>>,
    /// The querying partition's set, materialised. Address-valued topic filters
    /// resolve ownership against it, so a log only ever routes to the addresses
    /// this partition asked for.
    cache: Arc<SetCache>,
}

impl SelectionDecoder {
    pub(crate) fn checksummed_addresses(&self) -> bool {
        self.checksummed_addresses
    }

    /// Read view of the chain's address index, held for a whole response so the
    /// per-log gates don't re-lock. Registration from the JS thread waits on it
    /// for the length of one page's routing.
    pub(crate) fn lock_store(&self) -> std::sync::RwLockReadGuard<'_, StoreInner> {
        self.store.read().unwrap()
    }

    pub(crate) fn route_and_decode_napi(
        &self,
        log: &Log,
        address: &LogAddress,
        store: &StoreInner,
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
        self.route_and_decode(&topics, &data, address, store)
    }

    pub(crate) fn route_and_decode_simple(
        &self,
        log: &simple_types::Log,
        address: &LogAddress,
        store: &StoreInner,
    ) -> Result<Vec<RoutedEvent>> {
        let data = log.data.as_ref().context("get log.data")?;
        self.route_and_decode(&log.topics, data, address, store)
    }

    /// Fans a log out to every registration of the selection it matches
    /// (see `OnEventRegistration::matches`), decoding it under each match's own
    /// ABI declaration.
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
        address: &LogAddress,
        store: &StoreInner,
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
                topics,
                address,
                sel.force_wildcard,
                &self.cache,
                store,
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
    use crate::address_store::test_support::evm_store;

    const VALID_SIGHASH: &str =
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";

    /// The emitter used by every routing test, registered for whichever
    /// contract the test wants to own it.
    const EMITTER: &str = "0x00000000000000000000000000000000000000aa";
    const EMITTER_KEY: [u8; 20] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xaa,
    ];
    /// An address no store in these tests holds.
    const FOREIGN_KEY: [u8; 20] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xbb,
    ];

    /// A store whose `owner` (when given) holds `EMITTER`; the other contracts
    /// exist but hold nothing.
    fn store(contract_names: &[&str], owner: Option<&str>) -> crate::address_store::AddressStore {
        evm_store(
            &contract_names
                .iter()
                .map(|name| {
                    let addresses: &[&str] = if Some(*name) == owner {
                        &[EMITTER]
                    } else {
                        &[]
                    };
                    (*name, addresses)
                })
                .collect::<Vec<_>>(),
        )
    }

    /// The registered emitter, owned by `contract_name` per the partition's set.
    fn owned(contract_name: &str) -> LogAddress<'_> {
        LogAddress {
            key: &EMITTER_KEY,
            contract_name: Some(contract_name),
            block_number: 0,
        }
    }

    /// An emitter the partition's set doesn't hold. Contract-bound
    /// registrations reject it; wildcards still see it.
    fn unowned() -> LogAddress<'static> {
        LogAddress {
            key: &FOREIGN_KEY,
            contract_name: None,
            block_number: 0,
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
            start_block: None,
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

    /// A query selection carrying the partition set a whole-store query would.
    /// Tests that need a narrower partition build their own set and call
    /// `Decoder::selection` directly.
    fn selection_of(
        core: &Decoder,
        indexes: &[i64],
        client_filtered: &crate::client_filtered_contracts::ClientFilteredContracts,
    ) -> Result<SelectionDecoder> {
        let cache = crate::address_store::test_support::full_set(core.store_handle())
            .cache()
            .clone();
        core.selection(indexes, client_filtered, cache)
    }

    /// Route one log, holding the store read lock the way a response does.
    fn route(decoder: &SelectionDecoder, log: &Log, address: &LogAddress) -> Vec<RoutedEvent> {
        let store = decoder.lock_store();
        decoder
            .route_and_decode_napi(log, address, &store)
            .expect("routing must not fail on a well-formed log")
    }

    #[test]
    fn registration_rejects_zero_topics() {
        let mut reg = value_reg(0, "C", false, VALID_SIGHASH);
        reg.topic_count = 0;
        let err = Decoder::from_registrations(&[reg], false, &store(&["C"], None))
            .err()
            .unwrap();
        assert!(format!("{err:#}").contains("topic_count must be 1..=4"));
    }

    #[test]
    fn registration_rejects_five_topics() {
        let mut reg = value_reg(0, "C", false, VALID_SIGHASH);
        reg.topic_count = 5;
        let err = Decoder::from_registrations(&[reg], false, &store(&["C"], None))
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
        assert!(Decoder::from_registrations(&[one, four], false, &store(&["C"], None)).is_ok());
    }

    #[test]
    fn duplicate_registration_index_errors() {
        let err = Decoder::from_registrations(
            &[
                value_reg(0, "C", false, VALID_SIGHASH),
                value_reg(0, "D", false, VALID_SIGHASH),
            ],
            false,
            &store(&["C", "D"], None),
        )
        .err()
        .unwrap();
        assert!(format!("{err:#}").contains("Duplicate registration index 0"));
    }

    #[test]
    fn unknown_registration_index_errors() {
        let core = Decoder::from_registrations(&[], false, &store(&[], None)).unwrap();
        let err = selection_of(&core, &[7], &Default::default())
            .err()
            .unwrap();
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
                start_block: None,
                topic_selections: no_filter_selection(&real_sighash),
                block_fields: vec![],
                transaction_fields: vec![],
                params: vec![pm("owner", "address", false), pm("value", "uint256", false)],
            }],
            false,
            &store(&["TestContract"], Some("TestContract")),
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

        let decoder = selection_of(&core, &[7], &Default::default()).unwrap();
        let mut routed = route(&decoder, &log, &owned("TestContract"));
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
            &store(&["Owned", "W1", "W2", "Other"], Some("Owned")),
        )
        .unwrap();
        let decoder = selection_of(&core, &[0, 1, 2, 3], &Default::default()).unwrap();
        let log = value_log(VALID_SIGHASH);

        assert_eq!(
            (
                // Owned address: the contract's registration plus every wildcard.
                routed_indexes(&route(&decoder, &log, &owned("Owned"))),
                // Unowned address: wildcards only — no fallback into
                // contract-bound registrations.
                routed_indexes(&route(&decoder, &log, &unowned())),
            ),
            (vec![0, 1, 2], vec![1, 2])
        );
    }

    #[test]
    fn registration_start_block_holds_back_only_its_own_registration() {
        // Two registrations of one event on one contract: one unrestricted, one
        // starting at 100. The address store's start block is contract-wide, so
        // only this per-registration gate can separate them.
        let mut restricted = value_reg(1, "Owned", false, VALID_SIGHASH);
        restricted.start_block = Some(100);
        let core = Decoder::from_registrations(
            &[value_reg(0, "Owned", false, VALID_SIGHASH), restricted],
            false,
            &store(&["Owned"], Some("Owned")),
        )
        .unwrap();
        let decoder = selection_of(&core, &[0, 1], &Default::default()).unwrap();
        let log = value_log(VALID_SIGHASH);
        let at = |block_number| LogAddress {
            key: &EMITTER_KEY,
            contract_name: Some("Owned"),
            block_number,
        };

        assert_eq!(
            (
                routed_indexes(&route(&decoder, &log, &at(99))),
                routed_indexes(&route(&decoder, &log, &at(100))),
            ),
            (vec![0], vec![0, 1])
        );
    }

    #[test]
    fn client_filtered_contract_routes_on_the_store_alone() {
        // "Owned" is a non-wildcard registration, but client-filtered: this
        // query carries none of its addresses, so the partition's set can't
        // claim the emitter (contract_name is None) and the store decides.
        let core = Decoder::from_registrations(
            &[
                value_reg(0, "Owned", false, VALID_SIGHASH),
                value_reg(1, "W1", true, VALID_SIGHASH),
            ],
            false,
            &store(&["Owned", "W1"], Some("Owned")),
        )
        .unwrap();
        let client_filtered =
            crate::client_filtered_contracts::ClientFilteredContracts::from_vec(vec![
                "Owned".to_string()
            ]);
        let decoder = selection_of(&core, &[0, 1], &client_filtered).unwrap();
        let registered = LogAddress {
            key: &EMITTER_KEY,
            contract_name: None,
            block_number: 0,
        };
        let log = value_log(VALID_SIGHASH);
        assert_eq!(
            (
                // Registered for "Owned" in the store: routes to it and the wildcard.
                routed_indexes(&route(&decoder, &log, &registered)),
                // Not registered anywhere: the wildcard only. Over-fetched logs
                // from a client-filtered query are dropped here rather than
                // downstream in JS.
                routed_indexes(&route(&decoder, &log, &unowned())),
            ),
            (vec![0, 1], vec![1])
        );
    }

    #[test]
    fn emitter_registered_after_the_log_block_is_dropped() {
        // A merged partition holds addresses with different effective start
        // blocks, so a query for the whole partition over-fetches logs from
        // before an address was registered. The temporal half of the gate
        // drops them.
        let address_store = crate::address_store::AddressStore::new_evm(
            false,
            vec![crate::address_store::AddressStoreContract {
                name: "Owned".to_string(),
                start_block: None,
                depends_on_addresses: true,
            }],
        );
        address_store.register_seed(vec![crate::address_store::AddressRegistration {
            address: EMITTER.to_string(),
            contract_name: "Owned".to_string(),
            registration_block: 100,
        }]);
        let core = Decoder::from_registrations(
            &[value_reg(0, "Owned", false, VALID_SIGHASH)],
            false,
            &address_store,
        )
        .unwrap();
        let decoder = selection_of(&core, &[0], &Default::default()).unwrap();
        let log = value_log(VALID_SIGHASH);
        let at = |block_number| LogAddress {
            key: &EMITTER_KEY,
            contract_name: Some("Owned"),
            block_number,
        };
        assert_eq!(
            (
                routed_indexes(&route(&decoder, &log, &at(99))),
                routed_indexes(&route(&decoder, &log, &at(100))),
            ),
            (vec![], vec![0])
        );
    }

    #[test]
    fn routing_scoped_to_query_selection() {
        let core = Decoder::from_registrations(
            &[
                value_reg(0, "Owned", false, VALID_SIGHASH),
                value_reg(1, "W1", true, VALID_SIGHASH),
            ],
            false,
            &store(&["Owned", "W1"], Some("Owned")),
        )
        .unwrap();
        let log = value_log(VALID_SIGHASH);
        let decoder = selection_of(&core, &[0], &Default::default()).unwrap();
        assert_eq!(
            routed_indexes(&route(&decoder, &log, &owned("Owned"))),
            vec![0]
        );
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

        let core = Decoder::from_registrations(
            &[disabled, sibling],
            false,
            &store(&["Disabled", "Live"], None),
        )
        .unwrap();
        let decoder = selection_of(&core, &[0, 1], &Default::default()).unwrap();
        assert_eq!(
            routed_indexes(&route(&decoder, &value_log(VALID_SIGHASH), &unowned())),
            vec![1]
        );
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

        let core = Decoder::from_registrations(
            &[filtered_a, filtered_b],
            false,
            &store(&["WA", "WB"], None),
        )
        .unwrap();
        let log = Log {
            topics: vec![Some(VALID_SIGHASH.to_string()), Some(topic1_a)],
            data: value_log(VALID_SIGHASH).data,
            ..Default::default()
        };
        let decoder = selection_of(&core, &[0, 1], &Default::default()).unwrap();
        assert_eq!(routed_indexes(&route(&decoder, &log, &unowned())), vec![0]);
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

    /// A second address the marker fixtures register alongside `EMITTER`.
    const SECOND: &str = "0x00000000000000000000000000000000000000cc";

    /// A registration filtering two indexed address params by
    /// `chain.C.addresses`. `and_group` puts both markers in one DNF
    /// alternative (both must hold); otherwise each gets its own alternative
    /// (either may hold).
    fn two_marker_reg(contract: &str, and_group: bool) -> OnEventRegistrationInput {
        let mut reg = value_reg(0, contract, true, VALID_SIGHASH);
        reg.topic_count = 3;
        reg.params = vec![
            pm("from", "address", true),
            pm("to", "address", true),
            pm("value", "uint256", false),
        ];
        let sighash = || vec![VALID_SIGHASH.to_string()];
        reg.topic_selections = if and_group {
            vec![TopicSelectionInput {
                topic0: sighash(),
                topic1: None,
                topic2: None,
                topic3: Some(vec![]),
            }]
        } else {
            vec![
                TopicSelectionInput {
                    topic0: sighash(),
                    topic1: None,
                    topic2: Some(vec![]),
                    topic3: Some(vec![]),
                },
                TopicSelectionInput {
                    topic0: sighash(),
                    topic1: Some(vec![]),
                    topic2: None,
                    topic3: Some(vec![]),
                },
            ]
        };
        reg
    }

    fn two_address_param_log(topic1: &str, topic2: &str) -> Log {
        Log {
            topics: vec![
                Some(VALID_SIGHASH.to_string()),
                Some(topic1.to_string()),
                Some(topic2.to_string()),
            ],
            data: value_log(VALID_SIGHASH).data,
            ..Default::default()
        }
    }

    /// An emitter no contract owns, at `block_number` — for wildcard marker
    /// registrations, where only the log's block feeds the gate.
    fn at_block(block_number: i64) -> LogAddress<'static> {
        LogAddress {
            key: &FOREIGN_KEY,
            contract_name: None,
            block_number,
        }
    }

    #[test]
    fn marker_param_registered_after_the_log_block_is_dropped() {
        // The temporal half of the param gate: a wildcard query over-fetches
        // logs whose address param was only registered later, and the marker
        // drops them at the log's own block rather than downstream.
        let address_store = crate::address_store::AddressStore::new_evm(
            false,
            vec![crate::address_store::AddressStoreContract {
                name: "C".to_string(),
                start_block: None,
                depends_on_addresses: true,
            }],
        );
        address_store.register_seed(vec![crate::address_store::AddressRegistration {
            address: EMITTER.to_string(),
            contract_name: "C".to_string(),
            registration_block: 100,
        }]);
        let core =
            Decoder::from_registrations(&[marker_reg(0, "C")], false, &address_store).unwrap();
        let decoder = selection_of(&core, &[0], &Default::default()).unwrap();
        let log = address_param_log(&addr_topic("aa"));
        assert_eq!(
            (
                routed_indexes(&route(&decoder, &log, &at_block(99))),
                routed_indexes(&route(&decoder, &log, &at_block(100))),
            ),
            (vec![], vec![0])
        );
    }

    #[test]
    fn marker_scoped_to_the_partitions_addresses() {
        // The querying partition holds only D's address, so it materialised the
        // marker from that slice. A sibling selection's log carrying C's
        // address — registered chain-wide, but not by this partition — must not
        // route here, or the same log would be emitted from every partition.
        let address_store = evm_store(&[("C", &[EMITTER]), ("D", &[SECOND])]);
        let core =
            Decoder::from_registrations(&[marker_reg(0, "C")], false, &address_store).unwrap();
        let d_only = crate::address_store::test_support::set_of(&address_store, &["D"]);
        let decoder = core
            .selection(&[0], &Default::default(), d_only.cache().clone())
            .unwrap();
        assert_eq!(
            routed_indexes(&route(
                &decoder,
                &address_param_log(&addr_topic("aa")),
                &unowned()
            )),
            Vec::<i64>::new()
        );
    }

    #[test]
    fn client_filtered_marker_routes_on_the_store_alone() {
        // A client-filtered contract is queried address-free, so its markers
        // materialise to match-any and the partition set holds none of its
        // addresses. The store has to answer ownership on its own — scoping to
        // the (empty) set here would drop every one of the contract's events.
        let address_store = evm_store(&[("C", &[EMITTER])]);
        let core =
            Decoder::from_registrations(&[marker_reg(0, "C")], false, &address_store).unwrap();
        let client_filtered =
            crate::client_filtered_contracts::ClientFilteredContracts::from_vec(vec![
                "C".to_string()
            ]);
        let decoder = core
            .selection(
                &[0],
                &client_filtered,
                address_store.empty_set().cache().clone(),
            )
            .unwrap();
        assert_eq!(
            (
                routed_indexes(&route(
                    &decoder,
                    &address_param_log(&addr_topic("aa")),
                    &unowned()
                )),
                // Still gated: an address the store doesn't hold is dropped.
                routed_indexes(&route(
                    &decoder,
                    &address_param_log(&addr_topic("bb")),
                    &unowned()
                )),
            ),
            (vec![0], vec![])
        );
    }

    #[test]
    fn marker_and_group_requires_every_param_registered() {
        let core = Decoder::from_registrations(
            &[two_marker_reg("C", true)],
            false,
            &evm_store(&[("C", &[EMITTER, SECOND])]),
        )
        .unwrap();
        let decoder = selection_of(&core, &[0], &Default::default()).unwrap();
        let routed = |t1: &str, t2: &str| {
            routed_indexes(&route(
                &decoder,
                &two_address_param_log(&addr_topic(t1), &addr_topic(t2)),
                &unowned(),
            ))
        };
        assert_eq!(
            (routed("aa", "cc"), routed("aa", "bb"), routed("bb", "cc")),
            (vec![0], vec![], vec![])
        );
    }

    #[test]
    fn marker_or_of_groups_matches_either_alternative() {
        let core = Decoder::from_registrations(
            &[two_marker_reg("C", false)],
            false,
            &evm_store(&[("C", &[EMITTER, SECOND])]),
        )
        .unwrap();
        let decoder = selection_of(&core, &[0], &Default::default()).unwrap();
        let routed = |t1: &str, t2: &str| {
            routed_indexes(&route(
                &decoder,
                &two_address_param_log(&addr_topic(t1), &addr_topic(t2)),
                &unowned(),
            ))
        };
        assert_eq!(
            (routed("aa", "bb"), routed("bb", "cc"), routed("bb", "bb")),
            (vec![0], vec![0], vec![])
        );
    }

    #[test]
    fn contract_addresses_marker_materialized_from_query_addresses() {
        let core =
            Decoder::from_registrations(&[marker_reg(0, "C")], false, &store(&["C"], Some("C")))
                .unwrap();
        let decoder = selection_of(&core, &[0], &Default::default()).unwrap();
        assert_eq!(
            (
                // topic1 is C's registered address → the marker matches.
                routed_indexes(&route(
                    &decoder,
                    &address_param_log(&addr_topic("aa")),
                    &unowned()
                )),
                // topic1 is not one of C's addresses → the marker excludes it.
                routed_indexes(&route(
                    &decoder,
                    &address_param_log(&addr_topic("bb")),
                    &unowned()
                )),
            ),
            (vec![0], vec![])
        );
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

        let core = Decoder::from_registrations(
            &[marker_reg(0, "C"), sibling],
            false,
            &store(&["C", "S"], Some("C")),
        )
        .unwrap();
        let decoder = selection_of(&core, &[0, 1], &Default::default()).unwrap();
        // Foreign address (0x..bb) in topic1: only the broad sibling matches.
        assert_eq!(
            routed_indexes(&route(
                &decoder,
                &address_param_log(&addr_topic("bb")),
                &unowned()
            )),
            vec![1]
        );
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
            &store(&["C1", "C2"], None),
        )
        .expect("different indexed layouts on one signature must register");

        // A log emitted with `a` indexed: topic1 = 7, data = (8,).
        let data = DynSolValue::Tuple(vec![DynSolValue::Uint(U256::from(8u64), 256)]).abi_encode();
        let log = Log {
            topics: vec![Some(sighash.clone()), Some(format!("0x{:064x}", 7))],
            data: Some(format!("0x{}", hex::encode(data))),
            ..Default::default()
        };
        let decoder = selection_of(&core, &[0, 1], &Default::default()).unwrap();
        let routed = route(&decoder, &log, &unowned());
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
            &store(&["C1", "C2"], None),
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
        let decoder = selection_of(&core, &[0, 1], &Default::default()).unwrap();
        assert_eq!(routed_indexes(&route(&decoder, &log, &unowned())), vec![0]);

        // With only the failing declaration matched, the log drops rather than
        // erroring — a decode failure is a benign "not this declaration's log",
        // not malformed data (a wildcard registration routinely fetches foreign
        // same-signature logs it can't read under its own indexed split).
        let decoder = selection_of(&core, &[1], &Default::default()).unwrap();
        assert!(route(&decoder, &log, &unowned()).is_empty());
    }
}
