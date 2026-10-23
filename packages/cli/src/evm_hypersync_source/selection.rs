use std::collections::HashMap;

use anyhow::{Context, Result};

use crate::address_store::AddressSet;
use crate::evm_hypersync_source::query::{BlockField, TransactionField};
use crate::evm_hypersync_source::topic_filter::{TopicFilter, TopicFilters};

/// One log selection of a built query: `addresses` scopes the selection to
/// specific emitters (empty = any address), `topics` is the 4-position topic
/// filter (empty position = match any).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BuiltLogSelection {
    pub addresses: Vec<String>,
    pub topics: Vec<Vec<String>>,
}

/// A topic filter's values per position, as a query sends them.
type MaterializedTopics = [Vec<String>; 4];

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
/// the same signature now that routing fans one log out to all of them.
fn compress(selections: Vec<MaterializedTopics>) -> Vec<MaterializedTopics> {
    let mut folded_topic0s: Vec<String> = Vec::new();
    let mut separate: Vec<MaterializedTopics> = Vec::new();
    for selection in selections {
        let [topic0, topic1, topic2, topic3] = &selection;
        if !topic0.is_empty() && topic1.is_empty() && topic2.is_empty() && topic3.is_empty() {
            for value in topic0 {
                if !folded_topic0s.contains(value) {
                    folded_topic0s.push(value.clone());
                }
            }
        } else if !separate.contains(&selection) {
            separate.push(selection);
        }
    }
    let mut result = Vec::with_capacity(separate.len() + 1);
    if !folded_topic0s.is_empty() {
        result.push([folded_topic0s, Vec::new(), Vec::new(), Vec::new()]);
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
        let mut no_address: Vec<MaterializedTopics> = Vec::new();
        let mut by_contract: HashMap<&str, Vec<&TopicFilter>> = HashMap::new();
        let mut wildcard_by_contract: HashMap<&str, Vec<&TopicFilter>> = HashMap::new();
        // First-appearance order of address-bound contracts, so the built
        // query is byte-stable across calls (query caching keys on it).
        let mut ordered_contracts: Vec<&str> = Vec::new();
        let mut block_fields: Vec<BlockField> = Vec::new();
        let mut transaction_fields: Vec<TransactionField> = Vec::new();

        for id in registration_indexes {
            let reg = self
                .registrations
                .get(id)
                .with_context(|| format!("Unknown registration index {id} in query selection"))?;
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
                let bucket = if reg.is_wildcard {
                    &mut wildcard_by_contract
                } else {
                    &mut by_contract
                };
                bucket
                    .entry(reg.contract_name.as_str())
                    .or_default()
                    .extend(alternatives.iter());
            } else {
                // Address-free: genuine wildcards, plus client-filtered contracts
                // whose ContractAddresses markers materialize to match-any (empty
                // address topics). Routing re-applies the address gate on the
                // returned items, against the store alone.
                no_address.extend(alternatives.iter().map(|filter| filter.materialize(&[])));
            }
        }

        let mut log_selections: Vec<BuiltLogSelection> = Vec::new();
        let mut push_selections = |addresses: &[String], selections: Vec<MaterializedTopics>| {
            for topics in compress(selections) {
                log_selections.push(BuiltLogSelection {
                    addresses: addresses.to_vec(),
                    topics: topics.into(),
                });
            }
        };

        push_selections(&[], no_address);

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
                push_selections(
                    &slice.addresses,
                    filters
                        .iter()
                        .map(|filter| filter.materialize(&slice.topics))
                        .collect(),
                );
            }
            if let Some(filters) = wildcard_by_contract.get(contract_name) {
                push_selections(
                    &[],
                    filters
                        .iter()
                        .map(|filter| filter.materialize(&slice.topics))
                        .collect(),
                );
            }
        }

        Ok(BuiltSelection {
            log_selections,
            block_fields,
            transaction_fields,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::address_store::test_support::{evm_store, set_of};
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
                    addresses: vec![ADDR.to_string()],
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
                addresses: vec![],
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
                addresses: vec![],
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
                    addresses: vec![],
                    topics: vec![vec![SIGHASH_A.to_string()], vec![], vec![], vec![]],
                },
                BuiltLogSelection {
                    addresses: vec![],
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
                    addresses: vec![],
                    topics: vec![vec![SIGHASH_A.to_string()], vec![], vec![], vec![]],
                },
                BuiltLogSelection {
                    addresses: vec![],
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
        let client_filtered =
            crate::client_filtered_contracts::ClientFilteredContracts::from_vec(vec![
                "C".to_string()
            ]);
        let built = builder
            .build(&[0], &no_addresses().1, &client_filtered)
            .unwrap();
        assert_eq!(
            built.log_selections,
            vec![BuiltLogSelection {
                addresses: vec![],
                topics: vec![vec![SIGHASH_A.to_string()], vec![], vec![], vec![]],
            }]
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
        let client_filtered =
            crate::client_filtered_contracts::ClientFilteredContracts::from_vec(vec![
                "C".to_string()
            ]);
        let built = builder
            .build(&[0], &addresses(&[("C", &[ADDR])]).1, &client_filtered)
            .unwrap();
        assert_eq!(
            built.log_selections,
            vec![BuiltLogSelection {
                addresses: vec![],
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
                addresses: vec![ADDR.to_string()],
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
