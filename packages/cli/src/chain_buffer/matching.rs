//! A chain's event registrations compiled once, and which of them a fetched
//! row belongs to. Matching reads the address store and nothing else: which
//! partition fetched a row plays no part, so every copy of a row matches the
//! same registrations.

use std::sync::{Arc, RwLock, RwLockReadGuard};

use anyhow::{Context, Result};
use hypersync_client::format::{Hex, LogArgument};

use super::evm::LogView;
use crate::address_store::{AddressStore, StoreInner};
use crate::evm_hypersync_source::topic_filter::TopicFilterInput;
use crate::evm_hypersync_source::types::OnEventRegistrationInput;
use crate::registration_start_block::has_started;

enum TopicConstraint {
    Any,
    Values(Vec<[u8; 32]>),
    /// The topic is the padded form of an address the store holds for the
    /// registration's contract at the log's block.
    ContractAddresses,
}

impl TopicConstraint {
    fn parse(input: Option<&Vec<String>>) -> Result<Self> {
        Ok(match input {
            None => TopicConstraint::ContractAddresses,
            Some(values) if values.is_empty() => TopicConstraint::Any,
            Some(values) => TopicConstraint::Values(
                values
                    .iter()
                    .map(|value| {
                        LogArgument::decode_hex(value)
                            .map(|argument| **argument)
                            .with_context(|| format!("decode topic filter value {value}"))
                    })
                    .collect::<Result<_>>()?,
            ),
        })
    }

    fn matches(
        &self,
        topic: Option<&[u8]>,
        contract: u32,
        block_number: i64,
        store: &StoreInner,
    ) -> bool {
        match (self, topic) {
            (TopicConstraint::Any, _) => true,
            (_, None) => false,
            (TopicConstraint::Values(values), Some(topic)) => {
                values.iter().any(|value| value.as_slice() == topic)
            }
            (TopicConstraint::ContractAddresses, Some(topic)) => {
                topic.len() == 32
                    && topic[..12].iter().all(|byte| *byte == 0)
                    && store.is_indexed_at(&topic[12..], contract, block_number)
            }
        }
    }
}

/// One alternative of a registration's `where`: a constraint per topic.
struct TopicFilter([TopicConstraint; 4]);

impl TopicFilter {
    fn parse(input: &TopicFilterInput) -> Result<Self> {
        Ok(TopicFilter([
            TopicConstraint::parse(input.topic0.as_ref())?,
            TopicConstraint::parse(input.topic1.as_ref())?,
            TopicConstraint::parse(input.topic2.as_ref())?,
            TopicConstraint::parse(input.topic3.as_ref())?,
        ]))
    }
}

pub(crate) struct EvmRegistration {
    pub(crate) index: u32,
    topic_count: usize,
    /// In disjunctive normal form: an empty list matches nothing.
    filters: Vec<TopicFilter>,
    contract: u32,
    is_wildcard: bool,
    start_block: Option<i64>,
    pub(crate) has_contract_register: bool,
}

impl EvmRegistration {
    fn matches(&self, log: &LogView, store: &StoreInner) -> bool {
        let block_number = log.block_number as i64;
        log.topic_count() == self.topic_count
            && has_started(self.start_block, block_number)
            && self.filters.iter().any(|filter| {
                filter.0.iter().zip(log.topics).all(|(constraint, topic)| {
                    constraint.matches(topic, self.contract, block_number, store)
                })
            })
            && (self.is_wildcard || store.is_indexed_at(log.address, self.contract, block_number))
    }
}

/// The registrations a topic0 can match, looked up by the topic's first eight
/// bytes and confirmed on the whole topic.
struct Topic0Index {
    prefixes: Vec<u64>,
    topics: Vec<[u8; 32]>,
    /// `ids[offsets[i]..offsets[i + 1]]` are the registrations of `topics[i]`.
    offsets: Vec<u32>,
    ids: Vec<u32>,
    /// Registrations some alternative of which leaves topic0 open.
    unindexed: Vec<u32>,
}

fn topic_prefix(topic: &[u8]) -> u64 {
    u64::from_be_bytes(topic[..8].try_into().expect("a topic has 32 bytes"))
}

impl Topic0Index {
    fn build(registrations: &[EvmRegistration]) -> Self {
        let mut pairs: Vec<([u8; 32], u32)> = Vec::new();
        let mut unindexed = Vec::new();
        for (position, registration) in registrations.iter().enumerate() {
            let position = position as u32;
            let mut topics = Vec::new();
            let mut open = false;
            for filter in &registration.filters {
                match &filter.0[0] {
                    TopicConstraint::Values(values) => topics.extend(values.iter().copied()),
                    _ => open = true,
                }
            }
            if open {
                unindexed.push(position);
                continue;
            }
            topics.sort_unstable();
            topics.dedup();
            pairs.extend(topics.into_iter().map(|topic| (topic, position)));
        }
        pairs.sort_unstable();
        let mut index = Topic0Index {
            prefixes: Vec::new(),
            topics: Vec::new(),
            offsets: vec![0],
            ids: Vec::new(),
            unindexed,
        };
        for (topic, position) in pairs {
            if index.topics.last() != Some(&topic) {
                if !index.topics.is_empty() {
                    index.offsets.push(index.ids.len() as u32);
                }
                index.prefixes.push(topic_prefix(&topic));
                index.topics.push(topic);
            }
            index.ids.push(position);
        }
        index.offsets.push(index.ids.len() as u32);
        if index.topics.is_empty() {
            index.offsets = vec![0, 0];
        }
        index
    }

    fn candidates(&self, topic0: Option<&[u8]>) -> &[u32] {
        let Some(topic0) = topic0.filter(|topic| topic.len() == 32) else {
            return &[];
        };
        let prefix = topic_prefix(topic0);
        let mut at = self
            .prefixes
            .partition_point(|candidate| *candidate < prefix);
        while at < self.prefixes.len() && self.prefixes[at] == prefix {
            if self.topics[at].as_slice() == topic0 {
                return &self.ids[self.offsets[at] as usize..self.offsets[at + 1] as usize];
            }
            at += 1;
        }
        &[]
    }
}

/// A chain's EVM event registrations and the address store they read.
pub(crate) struct EvmMatcher {
    /// In registration index order.
    registrations: Vec<EvmRegistration>,
    topic0: Topic0Index,
    store: Arc<RwLock<StoreInner>>,
}

impl EvmMatcher {
    pub(crate) fn new(
        inputs: &[OnEventRegistrationInput],
        contract_register_indexes: &[i64],
        address_store: &AddressStore,
    ) -> Result<Self> {
        let store = address_store.handle();
        let mut registrations = {
            let inner = store.read().unwrap();
            inputs
                .iter()
                .map(|input| compile(input, contract_register_indexes, &inner))
                .collect::<Result<Vec<_>>>()?
        };
        registrations.sort_unstable_by_key(|registration| registration.index);
        anyhow::ensure!(
            registrations
                .windows(2)
                .all(|pair| pair[0].index != pair[1].index),
            "Duplicate event registration index"
        );
        Ok(EvmMatcher {
            topic0: Topic0Index::build(&registrations),
            registrations,
            store,
        })
    }

    pub(crate) fn read_store(&self) -> RwLockReadGuard<'_, StoreInner> {
        self.store.read().unwrap()
    }

    /// Calls `f` with every registration the log belongs to, in index order.
    pub(crate) fn for_each_match(
        &self,
        log: &LogView,
        store: &StoreInner,
        mut f: impl FnMut(&EvmRegistration),
    ) {
        let indexed = self.topic0.candidates(log.topics[0]);
        let unindexed = &self.topic0.unindexed;
        // Both lists hold positions in index order; walking them together
        // keeps the matches in that order.
        let (mut i, mut u) = (0, 0);
        while i < indexed.len() || u < unindexed.len() {
            let position = match (indexed.get(i), unindexed.get(u)) {
                (Some(a), Some(b)) if a <= b => {
                    i += 1;
                    *a
                }
                (Some(_), Some(b)) => {
                    u += 1;
                    *b
                }
                (Some(a), None) => {
                    i += 1;
                    *a
                }
                (None, Some(b)) => {
                    u += 1;
                    *b
                }
                (None, None) => unreachable!(),
            };
            let registration = &self.registrations[position as usize];
            if registration.matches(log, store) {
                f(registration);
            }
        }
    }

    /// What a page needs to know of a fetched log: whether any registration
    /// keeps it, and whether one of those registers contracts.
    pub(crate) fn classify(&self, log: &LogView, store: &StoreInner) -> RowMatch {
        let mut found = RowMatch::default();
        self.for_each_match(log, store, |registration| {
            found.kept = true;
            found.registers |= registration.has_contract_register;
        });
        found
    }
}

#[derive(Default, Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) struct RowMatch {
    pub(crate) kept: bool,
    pub(crate) registers: bool,
}

fn compile(
    input: &OnEventRegistrationInput,
    contract_register_indexes: &[i64],
    store: &StoreInner,
) -> Result<EvmRegistration> {
    let topic_count = usize::try_from(input.topic_count).context("topic_count is negative")?;
    anyhow::ensure!(
        (1..=4).contains(&topic_count),
        "topic_count must be 1..=4, got {topic_count}"
    );
    let filters = input
        .topic_filters
        .iter()
        .map(TopicFilter::parse)
        .collect::<Result<Vec<_>>>()
        .with_context(|| format!("parse topic filters of {}", input.event_name))?;
    anyhow::ensure!(
        input.sighash.is_some()
            || filters
                .iter()
                .all(|filter| matches!(filter.0[0], TopicConstraint::Values(_))),
        "Registration {} of the anonymous event {} must filter topic0 by values in every \
         alternative",
        input.index,
        input.event_name,
    );
    let contract = store.contract_idx(&input.contract_name).with_context(|| {
        format!(
            "Contract {} is missing from the chain's address store",
            input.contract_name
        )
    })?;
    Ok(EvmRegistration {
        index: u32::try_from(input.index).context("registration index is negative")?,
        topic_count,
        filters,
        contract,
        is_wildcard: input.is_wildcard,
        start_block: input.start_block,
        has_contract_register: contract_register_indexes.contains(&input.index),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::address_store::test_support::evm_store;
    use crate::chain_buffer::decode::evm::EvmDecoder;
    use crate::evm_hypersync_source::types::ParamMeta;
    use crate::js_value::test_value::JsValue;
    use alloy_dyn_abi::DynSolValue;
    use alloy_primitives::{hex, U256};

    const TRANSFER: &str = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
    const TOKEN: &str = "0x00000000000000000000000000000000000000aa";
    const OTHER: &str = "0x00000000000000000000000000000000000000bb";
    const SENDER: &str = "0x00000000000000000000000000000000000000cc";

    fn param(name: &str, abi_type: &str, indexed: bool) -> ParamMeta {
        ParamMeta {
            name: name.into(),
            abi_type: abi_type.into(),
            indexed,
            components: None,
        }
    }

    fn word(address: &str) -> String {
        format!("0x{}{}", "0".repeat(24), &address[2..])
    }

    fn filter(topic1: Option<Vec<String>>) -> TopicFilterInput {
        TopicFilterInput {
            topic0: Some(vec![TRANSFER.into()]),
            topic1,
            topic2: Some(vec![]),
            topic3: Some(vec![]),
        }
    }

    fn registration(
        index: i64,
        contract: &str,
        is_wildcard: bool,
        start_block: Option<i64>,
        filters: Vec<TopicFilterInput>,
    ) -> OnEventRegistrationInput {
        OnEventRegistrationInput {
            index,
            sighash: Some(TRANSFER.into()),
            topic_count: 3,
            event_name: "Transfer".into(),
            contract_name: contract.into(),
            is_wildcard,
            depends_on_addresses: !is_wildcard,
            start_block,
            params: vec![
                param("from", "address", true),
                param("to", "address", true),
                param("value", "uint256", false),
            ],
            topic_filters: filters,
            block_fields: vec![],
            transaction_fields: vec![],
        }
    }

    fn registrations() -> Vec<OnEventRegistrationInput> {
        vec![
            registration(0, "Token", false, None, vec![filter(Some(vec![]))]),
            registration(
                1,
                "Wild",
                true,
                None,
                vec![filter(Some(vec![word(SENDER)]))],
            ),
            registration(2, "Token", true, None, vec![filter(None)]),
            registration(3, "Token", false, Some(100), vec![filter(Some(vec![]))]),
            registration(4, "Wild", true, None, vec![]),
        ]
    }

    struct TestLog {
        address: &'static str,
        topics: Vec<Vec<u8>>,
        block_number: u64,
        data: Vec<u8>,
    }

    fn log(address: &'static str, from: &str, block_number: u64, data: Option<Vec<u8>>) -> TestLog {
        let data = data.unwrap_or_else(|| {
            DynSolValue::Tuple(vec![DynSolValue::Uint(U256::from(7u64), 256)]).abi_encode()
        });
        TestLog {
            address,
            topics: vec![bytes(TRANSFER), bytes(&word(from)), bytes(&word(OTHER))],
            block_number,
            data,
        }
    }

    fn bytes(text: &str) -> Vec<u8> {
        hex::decode(&text[2..]).unwrap()
    }

    /// Which registrations each log matches and decodes under, and what one
    /// of them decodes to.
    #[test]
    fn matches_on_topics_start_block_and_the_store_alone() {
        let store = evm_store(&[("Token", &[TOKEN]), ("Wild", &[])]);
        let inputs = registrations();
        let matcher = EvmMatcher::new(&inputs, &[], &store).unwrap();
        let decoder = EvmDecoder::new(&inputs, false).unwrap();

        let logs = [
            log(TOKEN, SENDER, 5, None),
            log(TOKEN, TOKEN, 5, None),
            log(TOKEN, OTHER, 150, None),
            log(OTHER, SENDER, 5, None),
            log(OTHER, TOKEN, 5, None),
            log(TOKEN, SENDER, 5, Some(vec![1, 2, 3])),
        ];
        let matched: Vec<Vec<(i64, JsValue)>> = logs
            .iter()
            .map(|log| {
                let address = bytes(log.address);
                let view = LogView {
                    block_number: log.block_number,
                    address: &address,
                    topics: [
                        Some(log.topics[0].as_slice()),
                        Some(log.topics[1].as_slice()),
                        Some(log.topics[2].as_slice()),
                        None,
                    ],
                };
                let mut matched = Vec::new();
                let guard = matcher.read_store();
                matcher.for_each_match(&view, &guard, |registration| {
                    if let Some(params) =
                        decoder.decode(registration.index, &view.topics, &log.data)
                    {
                        matched.push((registration.index as i64, JsValue::of(&params.to_tape())));
                    }
                });
                matched
            })
            .collect();
        assert_eq!(
            (
                matched
                    .iter()
                    .map(|matched| matched.iter().map(|(index, _)| *index).collect::<Vec<_>>())
                    .collect::<Vec<_>>(),
                matched[0][0].1.clone(),
            ),
            (
                vec![vec![0, 1], vec![0, 2], vec![0, 3], vec![1], vec![2], vec![]],
                JsValue::obj([
                    ("from", JsValue::str(SENDER)),
                    ("to", JsValue::str(OTHER)),
                    ("value", JsValue::uint(7u64)),
                ]),
            )
        );
    }
}
