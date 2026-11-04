use std::collections::HashMap;

use anyhow::{Context, Result};

use crate::address_store::AddressSet;
use crate::evm_hypersync_source::query::{BlockField, TransactionField};
use crate::evm_hypersync_source::topic_filter::{TopicFilter, TopicFilters};

/// One log selection of a built query: the emitters it reaches, and the
/// 4-position topic filter (empty position = match any).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BuiltLogSelection {
    pub emitters: Emitters,
    pub topics: Vec<Vec<String>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Emitters {
    /// Only these addresses.
    Listed(Vec<String>),
    /// Any address, with the registrations the selection was built from, so
    /// the same logs can be asked for another way.
    Any(AddressFreeOrigin),
}

/// The registrations an address-free selection was built from, by whether a
/// registered address can stand in for them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AddressFreeOrigin {
    /// Selected by their topics alone, so only ever asked for address-free.
    pub topic_only_registrations: Vec<i64>,
    /// Address-dependent registrations of client-filtered contracts, whose
    /// registered addresses can be asked for instead.
    pub client_filtered_registrations: Vec<i64>,
}

impl BuiltLogSelection {
    /// The emitter filter as a query sends it: empty for any address.
    pub fn addresses(&self) -> &[String] {
        match &self.emitters {
            Emitters::Listed(addresses) => addresses,
            Emitters::Any(_) => &[],
        }
    }
}

/// The same logs as an address-free selection, asked for by the registered
/// addresses of its client-filtered contracts.
pub(crate) struct SelectionByAddress {
    pub contract_names: Vec<String>,
    pub log_selections: Vec<BuiltLogSelection>,
}

/// A topic filter's values per position, as a query sends them.
type MaterializedTopics = [Vec<String>; 4];

#[derive(Clone, Copy)]
enum AddressFreeRole {
    TopicOnly,
    ClientFiltered,
}

fn address_free_origin(registrations: Vec<(AddressFreeRole, i64)>) -> AddressFreeOrigin {
    let mut origin = AddressFreeOrigin::default();
    for (role, index) in registrations {
        let indexes = match role {
            AddressFreeRole::TopicOnly => &mut origin.topic_only_registrations,
            AddressFreeRole::ClientFiltered => &mut origin.client_filtered_registrations,
        };
        if !indexes.contains(&index) {
            indexes.push(index);
        }
    }
    origin
}

fn address_free_selections(
    selections: Vec<(MaterializedTopics, (AddressFreeRole, i64))>,
) -> Vec<BuiltLogSelection> {
    compress(selections)
        .into_iter()
        .map(|(topics, registrations)| BuiltLogSelection {
            emitters: Emitters::Any(address_free_origin(registrations)),
            topics: topics.into(),
        })
        .collect()
}

struct RegistrationSelection {
    contract_name: String,
    is_wildcard: bool,
    depends_on_addresses: bool,
    topic_filters: TopicFilters,
    block_fields: Vec<BlockField>,
    transaction_fields: Vec<TransactionField>,
}

/// Fold selections constraining topic0 alone into one selection combining
/// their topic0s, keeping the common case at a single log selection/request.
/// Any other selection stays on its own: folding one that leaves topic0
/// unconstrained would widen the fold to every log. Repeated topic0s and
/// identical selections are deduplicated — several registrations may select
/// the same signature now that routing fans one log out to all of them. Each
/// selection keeps the tags of everything folded into it.
fn compress<Tag>(
    selections: Vec<(MaterializedTopics, Tag)>,
) -> Vec<(MaterializedTopics, Vec<Tag>)> {
    let mut folded_topic0s: Vec<String> = Vec::new();
    let mut folded_tags: Vec<Tag> = Vec::new();
    let mut separate: Vec<(MaterializedTopics, Vec<Tag>)> = Vec::new();
    for (selection, tag) in selections {
        let [topic0, topic1, topic2, topic3] = &selection;
        if !topic0.is_empty() && topic1.is_empty() && topic2.is_empty() && topic3.is_empty() {
            for value in topic0 {
                if !folded_topic0s.contains(value) {
                    folded_topic0s.push(value.clone());
                }
            }
            folded_tags.push(tag);
        } else {
            match separate.iter_mut().find(|(kept, _)| *kept == selection) {
                Some((_, tags)) => tags.push(tag),
                None => separate.push((selection, vec![tag])),
            }
        }
    }
    let mut result = Vec::with_capacity(separate.len() + 1);
    if !folded_topic0s.is_empty() {
        result.push((
            [folded_topic0s, Vec::new(), Vec::new(), Vec::new()],
            folded_tags,
        ));
    }
    result.extend(separate);
    result
}

/// Everything a source query needs that depends on the partition's selection
/// and current addresses.
pub(crate) struct BuiltSelection {
    pub log_selections: Vec<BuiltLogSelection>,
    /// Union over the selection's registrations; unsorted, deduplicated.
    pub block_fields: Vec<BlockField>,
    /// Union over the selection's registrations; `TransactionIndex` excluded —
    /// it's read off the log (the store key), and requesting it alone would
    /// pull the whole transaction table for nothing.
    pub transaction_fields: Vec<TransactionField>,
}

/// Builds per-query log selections from the registrations passed at client
/// construction. Registrations are keyed by their chain-scoped sequential
/// index; a query names the indexes of its partition's selection plus the
/// partition's current addresses per contract.
pub(crate) struct SelectionBuilder {
    registrations: HashMap<i64, RegistrationSelection>,
}

impl SelectionBuilder {
    pub(crate) fn from_registrations(
        registrations: &[super::types::OnEventRegistrationInput],
    ) -> Result<Self> {
        let mut map = HashMap::new();
        for reg in registrations {
            let parsed = RegistrationSelection {
                contract_name: reg.contract_name.clone(),
                is_wildcard: reg.is_wildcard,
                depends_on_addresses: reg.depends_on_addresses,
                topic_filters: TopicFilters::parse(reg)?,
                block_fields: reg.block_fields.clone(),
                transaction_fields: reg.transaction_fields.clone(),
            };
            anyhow::ensure!(
                map.insert(reg.index, parsed).is_none(),
                "Duplicate registration index {} for event {}",
                reg.index,
                reg.event_name,
            );
        }
        Ok(Self { registrations: map })
    }

    pub(crate) fn build(
        &self,
        registration_indexes: &[i64],
        address_set: &AddressSet,
        client_filtered: &crate::client_filtered_contracts::ClientFilteredContracts,
    ) -> Result<BuiltSelection> {
        // Buckets: address-free selections pool together; address-bound ones
        // group per contract so one contract's query can't fetch a sibling's
        // logs (routing never re-applies the sibling's filter). Wildcard
        // events that filter an indexed param by registered addresses fold
        // the addresses into topics, so their query stays address-unbound.
        let mut no_address: Vec<(MaterializedTopics, (AddressFreeRole, i64))> = Vec::new();
        let mut by_contract: HashMap<&str, Vec<&TopicFilter>> = HashMap::new();
        let mut wildcard_by_contract: HashMap<&str, Vec<(&TopicFilter, i64)>> = HashMap::new();
        // First-appearance order of address-bound contracts, so the built
        // query is byte-stable across calls (query caching keys on it).
        let mut ordered_contracts: Vec<&str> = Vec::new();
        let mut block_fields: Vec<BlockField> = Vec::new();
        let mut transaction_fields: Vec<TransactionField> = Vec::new();

        for &id in registration_indexes {
            let reg = self.registration(id)?;
            for &field in &reg.block_fields {
                if !block_fields.contains(&field) {
                    block_fields.push(field);
                }
            }
            for &field in &reg.transaction_fields {
                if field != TransactionField::TransactionIndex
                    && !transaction_fields.contains(&field)
                {
                    transaction_fields.push(field);
                }
            }
            let alternatives = reg.topic_filters.alternatives();
            if reg.depends_on_addresses && !client_filtered.applies(&reg.contract_name) {
                if !ordered_contracts.contains(&reg.contract_name.as_str()) {
                    ordered_contracts.push(reg.contract_name.as_str());
                }
                if reg.is_wildcard {
                    wildcard_by_contract
                        .entry(reg.contract_name.as_str())
                        .or_default()
                        .extend(alternatives.iter().map(|filter| (filter, id)));
                } else {
                    by_contract
                        .entry(reg.contract_name.as_str())
                        .or_default()
                        .extend(alternatives.iter());
                }
            } else {
                // Address-free: genuine wildcards, plus client-filtered contracts
                // whose ContractAddresses markers materialize to match-any (empty
                // address topics). Routing re-applies the address gate on the
                // returned items, against the store alone.
                let role = if reg.depends_on_addresses {
                    AddressFreeRole::ClientFiltered
                } else {
                    AddressFreeRole::TopicOnly
                };
                no_address.extend(
                    alternatives
                        .iter()
                        .map(|filter| (filter.materialize(&[]), (role, id))),
                );
            }
        }

        let mut log_selections = address_free_selections(no_address);

        // The set's per-contract slices carry both the address strings the
        // filter needs and their padded topic forms, materialised once when the
        // partition's set was first used rather than per query.
        let cache = address_set.cache();
        for contract_name in ordered_contracts {
            let slice = match cache.slice(contract_name) {
                Some(slice) if !slice.addresses.is_empty() => slice,
                _ => continue,
            };
            if let Some(filters) = by_contract.get(contract_name) {
                for (topics, _) in compress(
                    filters
                        .iter()
                        .map(|filter| (filter.materialize(&slice.topics), ()))
                        .collect(),
                ) {
                    log_selections.push(BuiltLogSelection {
                        emitters: Emitters::Listed(slice.addresses.clone()),
                        topics: topics.into(),
                    });
                }
            }
            if let Some(filters) = wildcard_by_contract.get(contract_name) {
                log_selections.extend(address_free_selections(
                    filters
                        .iter()
                        .map(|&(filter, id)| {
                            (
                                filter.materialize(&slice.topics),
                                (AddressFreeRole::TopicOnly, id),
                            )
                        })
                        .collect(),
                ));
            }
        }

        Ok(BuiltSelection {
            log_selections,
            block_fields,
            transaction_fields,
        })
    }

    /// The logs of an address-free selection, asked for another way: its
    /// topic-only registrations still address-free, and its client-filtered
    /// ones the way a server-side partition would, once per address chunk.
    /// `address_chunks` receives the client-filtered contracts' names.
    pub(crate) fn build_by_address(
        &self,
        origin: &AddressFreeOrigin,
        address_set: &AddressSet,
        address_chunks: impl FnOnce(&[String]) -> Vec<AddressSet>,
    ) -> Result<SelectionByAddress> {
        let mut contract_names: Vec<String> = Vec::new();
        for &id in &origin.client_filtered_registrations {
            let contract_name = &self.registration(id)?.contract_name;
            if !contract_names.contains(contract_name) {
                contract_names.push(contract_name.clone());
            }
        }
        let server_side = Default::default();
        let mut log_selections = if origin.topic_only_registrations.is_empty() {
            Vec::new()
        } else {
            self.build(&origin.topic_only_registrations, address_set, &server_side)?
                .log_selections
        };
        for chunk in address_chunks(&contract_names) {
            log_selections.extend(
                self.build(&origin.client_filtered_registrations, &chunk, &server_side)?
                    .log_selections,
            );
        }
        Ok(SelectionByAddress {
            contract_names,
            log_selections,
        })
    }

    fn registration(&self, id: i64) -> Result<&RegistrationSelection> {
        self.registrations
            .get(&id)
            .with_context(|| format!("Unknown registration index {id} in query selection"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::address_store::test_support::{evm_store, set_of};
    use crate::client_filtered_contracts::ClientFilteredContracts;
    use crate::evm_hypersync_source::topic_filter::TopicFilterInput;
    use crate::evm_hypersync_source::types::OnEventRegistrationInput;

    const SIGHASH_A: &str = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const SIGHASH_B: &str = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const ADDR: &str = "0x1234567890abcdef1234567890abcdef12345678";
    const ADDR_BYTES: [u8; 20] = [
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef, 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd,
        0xef, 0x12, 0x34, 0x56, 0x78,
    ];
    const ADDR_TOPIC: &str = "0x0000000000000000000000001234567890abcdef1234567890abcdef12345678";

    fn reg(
        id: i64,
        sighash: &str,
        contract_name: &str,
        is_wildcard: bool,
        depends_on_addresses: bool,
        topic1: Option<Vec<String>>,
    ) -> OnEventRegistrationInput {
        OnEventRegistrationInput {
            index: id,
            sighash: Some(sighash.to_string()),
            topic_count: 1,
            event_name: "E".to_string(),
            contract_name: contract_name.to_string(),
            is_wildcard,
            depends_on_addresses,
            start_block: None,
            params: vec![],
            topic_filters: vec![TopicFilterInput {
                topic0: Some(vec![sighash.to_string()]),
                topic1,
                topic2: Some(vec![]),
                topic3: Some(vec![]),
            }],
            block_fields: vec![],
            transaction_fields: vec![],
        }
    }

    /// A store over `entries` plus a set spanning all of them — the pair a
    /// query is built from.
    fn addresses(entries: &[(&str, &[&str])]) -> (crate::address_store::AddressStore, AddressSet) {
        let store = evm_store(entries);
        let names: Vec<&str> = entries.iter().map(|(name, _)| *name).collect();
        let set = set_of(&store, &names);
        (store, set)
    }

    /// A wildcard partition's set: no addresses, but still a real one.
    fn no_addresses() -> (crate::address_store::AddressStore, AddressSet) {
        addresses(&[])
    }

    fn listed(addresses: &[&str]) -> Emitters {
        Emitters::Listed(
            addresses
                .iter()
                .map(|address| address.to_string())
                .collect(),
        )
    }

    fn any(topic_only: &[i64], client_filtered: &[i64]) -> Emitters {
        Emitters::Any(AddressFreeOrigin {
            topic_only_registrations: topic_only.to_vec(),
            client_filtered_registrations: client_filtered.to_vec(),
        })
    }

    fn client_filtered(contract_names: &[&str]) -> ClientFilteredContracts {
        ClientFilteredContracts::from_vec(
            contract_names.iter().map(|name| name.to_string()).collect(),
        )
    }

    #[test]
    fn filterless_events_compress_into_one_selection() {
        let builder = SelectionBuilder::from_registrations(&[
            reg(0, SIGHASH_A, "C", false, true, Some(vec![])),
            reg(1, SIGHASH_B, "C", false, true, Some(vec![])),
        ])
        .unwrap();
        let (_store, set) = addresses(&[("C", &[ADDR])]);
        let built = builder.build(&[0, 1], &set, &Default::default()).unwrap();
        assert_eq!(
            (built.log_selections, set.cache().owns(&ADDR_BYTES, 0),),
            (
                vec![BuiltLogSelection {
                    emitters: listed(&[ADDR]),
                    topics: vec![
                        vec![SIGHASH_A.to_string(), SIGHASH_B.to_string()],
                        vec![],
                        vec![],
                        vec![],
                    ],
                }],
                true,
            )
        );
    }

    #[test]
    fn wildcard_selection_stays_address_free() {
        let builder = SelectionBuilder::from_registrations(&[reg(
            0,
            SIGHASH_A,
            "C",
            true,
            false,
            Some(vec![]),
        )])
        .unwrap();
        let built = builder
            .build(&[0], &no_addresses().1, &Default::default())
            .unwrap();
        assert_eq!(
            built.log_selections,
            vec![BuiltLogSelection {
                emitters: any(&[0], &[]),
                topics: vec![vec![SIGHASH_A.to_string()], vec![], vec![], vec![]],
            }]
        );
    }

    #[test]
    fn contract_addresses_marker_expands_to_padded_topics() {
        // Wildcard event filtering an indexed param by the contract's own
        // addresses: the query stays address-unbound, the addresses fold into
        // topic1.
        let builder =
            SelectionBuilder::from_registrations(&[reg(0, SIGHASH_A, "C", true, true, None)])
                .unwrap();
        let built = builder
            .build(&[0], &addresses(&[("C", &[ADDR])]).1, &Default::default())
            .unwrap();
        assert_eq!(
            built.log_selections,
            vec![BuiltLogSelection {
                emitters: any(&[0], &[]),
                topics: vec![
                    vec![SIGHASH_A.to_string()],
                    vec![ADDR_TOPIC.to_string()],
                    vec![],
                    vec![],
                ],
            }]
        );
    }

    #[test]
    fn compress_dedupes_repeated_topic0s_and_identical_filtered_selections() {
        let builder = SelectionBuilder::from_registrations(&[
            // Two registrations selecting the same signature with no filters,
            // plus two with an identical topic1 filter.
            reg(0, SIGHASH_A, "C", true, false, Some(vec![])),
            reg(1, SIGHASH_A, "D", true, false, Some(vec![])),
            reg(
                2,
                SIGHASH_B,
                "C",
                true,
                false,
                Some(vec![ADDR_TOPIC.to_string()]),
            ),
            reg(
                3,
                SIGHASH_B,
                "D",
                true,
                false,
                Some(vec![ADDR_TOPIC.to_string()]),
            ),
        ])
        .unwrap();
        let built = builder
            .build(&[0, 1, 2, 3], &no_addresses().1, &Default::default())
            .unwrap();
        assert_eq!(
            built.log_selections,
            vec![
                BuiltLogSelection {
                    emitters: any(&[0, 1], &[]),
                    topics: vec![vec![SIGHASH_A.to_string()], vec![], vec![], vec![]],
                },
                BuiltLogSelection {
                    emitters: any(&[2, 3], &[]),
                    topics: vec![
                        vec![SIGHASH_B.to_string()],
                        vec![ADDR_TOPIC.to_string()],
                        vec![],
                        vec![],
                    ],
                },
            ]
        );
    }

    #[test]
    fn compress_keeps_an_unconstrained_topic0_selection_separate() {
        // An alternative filtering only topic1 must not fold into the topic0
        // list of its siblings: folded, it would either vanish or narrow to
        // their signatures.
        let mut topic1_only = reg(1, SIGHASH_B, "C", true, false, None);
        topic1_only.topic_filters = vec![TopicFilterInput {
            topic0: Some(vec![]),
            topic1: Some(vec![ADDR_TOPIC.to_string()]),
            topic2: Some(vec![]),
            topic3: Some(vec![]),
        }];
        let builder = SelectionBuilder::from_registrations(&[
            reg(0, SIGHASH_A, "C", true, false, Some(vec![])),
            topic1_only,
        ])
        .unwrap();
        let built = builder
            .build(&[0, 1], &no_addresses().1, &Default::default())
            .unwrap();
        assert_eq!(
            built.log_selections,
            vec![
                BuiltLogSelection {
                    emitters: any(&[0], &[]),
                    topics: vec![vec![SIGHASH_A.to_string()], vec![], vec![], vec![]],
                },
                BuiltLogSelection {
                    emitters: any(&[1], &[]),
                    topics: vec![vec![], vec![ADDR_TOPIC.to_string()], vec![], vec![]],
                },
            ]
        );
    }

    #[test]
    fn anonymous_registration_without_topic0_values_is_rejected() {
        let mut anonymous = reg(0, SIGHASH_A, "C", false, true, Some(vec![]));
        anonymous.sighash = None;
        anonymous.topic_filters = vec![
            TopicFilterInput {
                topic0: Some(vec![SIGHASH_A.to_string()]),
                topic1: Some(vec![]),
                topic2: Some(vec![]),
                topic3: Some(vec![]),
            },
            TopicFilterInput {
                topic0: Some(vec![]),
                topic1: Some(vec![ADDR_TOPIC.to_string()]),
                topic2: Some(vec![]),
                topic3: Some(vec![]),
            },
        ];
        let err = SelectionBuilder::from_registrations(&[anonymous])
            .err()
            .unwrap();
        assert_eq!(
            format!("{err:#}"),
            "Registration 0 of the anonymous event E must filter topic0 by values in every \
             alternative"
        );
    }

    #[test]
    fn contract_without_addresses_is_skipped() {
        let builder = SelectionBuilder::from_registrations(&[reg(
            0,
            SIGHASH_A,
            "C",
            false,
            true,
            Some(vec![]),
        )])
        .unwrap();
        let built = builder
            .build(&[0], &addresses(&[("C", &[])]).1, &Default::default())
            .unwrap();
        assert_eq!(built.log_selections, vec![]);
    }

    #[test]
    fn client_filtered_contract_builds_address_free_selection() {
        // A non-wildcard, address-dependent registration whose contract is
        // client-filtered is queried address-free (topic0 only), even though
        // the query carries no addresses for it.
        let builder = SelectionBuilder::from_registrations(&[reg(
            0,
            SIGHASH_A,
            "C",
            false,
            true,
            Some(vec![]),
        )])
        .unwrap();
        let built = builder
            .build(&[0], &no_addresses().1, &client_filtered(&["C"]))
            .unwrap();
        assert_eq!(
            built.log_selections,
            vec![BuiltLogSelection {
                emitters: any(&[], &[0]),
                topics: vec![vec![SIGHASH_A.to_string()], vec![], vec![], vec![]],
            }]
        );
    }

    /// Two client-filtered contracts and a wildcard event, all selecting by
    /// topic0 alone: one selection, keeping which registration could be asked
    /// for by address.
    fn pooled_builder() -> SelectionBuilder {
        SelectionBuilder::from_registrations(&[
            reg(0, SIGHASH_A, "C", false, true, Some(vec![])),
            reg(1, SIGHASH_B, "D", false, true, Some(vec![])),
            reg(2, SIGHASH_B, "W", true, false, Some(vec![])),
        ])
        .unwrap()
    }

    #[test]
    fn client_filtered_contracts_pool_with_wildcards_and_keep_their_origin() {
        let built = pooled_builder()
            .build(&[0, 1, 2], &no_addresses().1, &client_filtered(&["C", "D"]))
            .unwrap();
        assert_eq!(
            built.log_selections,
            vec![BuiltLogSelection {
                emitters: any(&[2], &[0, 1]),
                topics: vec![
                    vec![SIGHASH_A.to_string(), SIGHASH_B.to_string()],
                    vec![],
                    vec![],
                    vec![],
                ],
            }]
        );
    }

    #[test]
    fn by_address_keeps_wildcards_address_free_and_splits_the_rest_per_chunk() {
        // ADDR sorts before ADDR_2, so the one-address chunks come out C's
        // first, then D's.
        const ADDR_2: &str = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd";
        let (_store, set) = addresses(&[("C", &[ADDR]), ("D", &[ADDR_2])]);
        let origin = AddressFreeOrigin {
            topic_only_registrations: vec![2],
            client_filtered_registrations: vec![0, 1],
        };
        let by_address = pooled_builder()
            .build_by_address(&origin, &no_addresses().1, |contract_names| {
                set.contract_chunks(contract_names, 1)
            })
            .unwrap();
        assert_eq!(
            (by_address.contract_names, by_address.log_selections),
            (
                vec!["C".to_string(), "D".to_string()],
                vec![
                    BuiltLogSelection {
                        emitters: any(&[2], &[]),
                        topics: vec![vec![SIGHASH_B.to_string()], vec![], vec![], vec![]],
                    },
                    BuiltLogSelection {
                        emitters: listed(&[ADDR]),
                        topics: vec![vec![SIGHASH_A.to_string()], vec![], vec![], vec![]],
                    },
                    BuiltLogSelection {
                        emitters: listed(&[ADDR_2]),
                        topics: vec![vec![SIGHASH_B.to_string()], vec![], vec![], vec![]],
                    },
                ],
            )
        );
    }

    #[test]
    fn by_address_puts_a_contract_addresses_marker_back_into_topics() {
        // A wildcard event filtering an indexed param by its client-filtered
        // contract's own addresses goes out match-any; by address, those
        // addresses go back into the topic position instead. A contract with
        // no addresses left yields nothing to ask for.
        let builder =
            SelectionBuilder::from_registrations(&[reg(0, SIGHASH_A, "C", true, true, None)])
                .unwrap();
        let origin = AddressFreeOrigin {
            topic_only_registrations: vec![],
            client_filtered_registrations: vec![0],
        };
        let by_address_with = |entries: &[(&str, &[&str])]| {
            let (_store, set) = addresses(entries);
            builder
                .build_by_address(&origin, &no_addresses().1, |contract_names| {
                    set.contract_chunks(contract_names, 10)
                })
                .unwrap()
                .log_selections
        };
        assert_eq!(
            (
                by_address_with(&[("C", &[ADDR])]),
                by_address_with(&[("C", &[])])
            ),
            (
                vec![BuiltLogSelection {
                    emitters: any(&[0], &[]),
                    topics: vec![
                        vec![SIGHASH_A.to_string()],
                        vec![ADDR_TOPIC.to_string()],
                        vec![],
                        vec![],
                    ],
                }],
                vec![],
            )
        );
    }

    #[test]
    fn client_filtered_contract_addresses_marker_becomes_match_any() {
        // A wildcard event filtering an indexed param by the contract's own
        // addresses: when the contract is client-filtered the marker resolves to
        // match-any (empty topic position) instead of the address topics.
        let builder =
            SelectionBuilder::from_registrations(&[reg(0, SIGHASH_A, "C", true, true, None)])
                .unwrap();
        let built = builder
            .build(
                &[0],
                &addresses(&[("C", &[ADDR])]).1,
                &client_filtered(&["C"]),
            )
            .unwrap();
        assert_eq!(
            built.log_selections,
            vec![BuiltLogSelection {
                emitters: any(&[], &[0]),
                topics: vec![vec![SIGHASH_A.to_string()], vec![], vec![], vec![]],
            }]
        );
    }

    #[test]
    fn selection_subset_excludes_other_registrations() {
        // A partition's query only includes its own selection's registrations
        // even though the builder holds the whole chain's.
        let builder = SelectionBuilder::from_registrations(&[
            reg(0, SIGHASH_A, "C", false, true, Some(vec![])),
            reg(1, SIGHASH_B, "C", false, true, Some(vec![])),
        ])
        .unwrap();
        let built = builder
            .build(&[1], &addresses(&[("C", &[ADDR])]).1, &Default::default())
            .unwrap();
        assert_eq!(
            built.log_selections,
            vec![BuiltLogSelection {
                emitters: listed(&[ADDR]),
                topics: vec![vec![SIGHASH_B.to_string()], vec![], vec![], vec![]],
            }]
        );
    }

    #[test]
    fn field_selection_unions_and_excludes_transaction_index() {
        let mut a = reg(0, SIGHASH_A, "C", true, false, Some(vec![]));
        a.block_fields = vec![BlockField::Hash, BlockField::Number];
        a.transaction_fields = vec![TransactionField::TransactionIndex, TransactionField::Hash];
        let mut b = reg(1, SIGHASH_B, "D", true, false, Some(vec![]));
        b.block_fields = vec![BlockField::Number, BlockField::Nonce];
        b.transaction_fields = vec![TransactionField::GasPrice];
        let builder = SelectionBuilder::from_registrations(&[a, b]).unwrap();
        let built = builder
            .build(&[0, 1], &no_addresses().1, &Default::default())
            .unwrap();
        assert_eq!(
            built.block_fields,
            vec![BlockField::Hash, BlockField::Number, BlockField::Nonce]
        );
        // TransactionIndex is read off the log (the store key), so it's never
        // requested as a transaction column.
        assert_eq!(
            built.transaction_fields,
            vec![TransactionField::Hash, TransactionField::GasPrice]
        );
    }

    #[test]
    fn unknown_registration_id_errors() {
        let builder = SelectionBuilder::from_registrations(&[]).unwrap();
        let err = builder
            .build(&[7], &no_addresses().1, &Default::default())
            .err()
            .unwrap();
        assert!(format!("{err:#}").contains("Unknown registration index 7"));
    }
}
