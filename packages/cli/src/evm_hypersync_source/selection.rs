use std::collections::HashMap;

use anyhow::{Context, Result};
use hypersync_client::format::Hex;
use napi_derive::napi;

use crate::evm_hypersync_source::query::{BlockField, TransactionField};

/// Topic positions 1..3: static topic values, or `None` — the "currently
/// registered addresses of this contract" marker, expanded to padded address
/// topics when a query is built. Spelled as `Option<...>` directly (not an
/// alias) so the napi macro sees the field as optional.
#[napi(object)]
#[derive(Clone)]
pub struct TopicSelectionInput {
    pub topic0: Vec<String>,
    pub topic1: Option<Vec<String>>,
    pub topic2: Option<Vec<String>>,
    pub topic3: Option<Vec<String>>,
}

/// One log selection of a built query: `addresses` scopes the selection to
/// specific emitters (empty = any address), `topics` is the 4-position topic
/// filter (empty position = match any).
#[napi(object)]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BuiltLogSelection {
    pub addresses: Vec<String>,
    pub topics: Vec<Vec<String>>,
}

#[derive(Clone)]
enum TopicFilter {
    Values(Vec<String>),
    ContractAddresses,
}

impl TopicFilter {
    fn parse(input: &Option<Vec<String>>) -> Self {
        match input {
            Some(values) => TopicFilter::Values(values.clone()),
            None => TopicFilter::ContractAddresses,
        }
    }

    fn materialize(&self, address_topics: &[String]) -> Vec<String> {
        match self {
            TopicFilter::Values(values) => values.clone(),
            TopicFilter::ContractAddresses => address_topics.to_vec(),
        }
    }
}

#[derive(Clone)]
struct TopicSelection {
    topic0: Vec<String>,
    topic1: TopicFilter,
    topic2: TopicFilter,
    topic3: TopicFilter,
}

impl TopicSelection {
    fn materialize(&self, address_topics: &[String]) -> MaterializedTopicSelection {
        MaterializedTopicSelection {
            topic0: self.topic0.clone(),
            topic1: self.topic1.materialize(address_topics),
            topic2: self.topic2.materialize(address_topics),
            topic3: self.topic3.materialize(address_topics),
        }
    }
}

struct MaterializedTopicSelection {
    topic0: Vec<String>,
    topic1: Vec<String>,
    topic2: Vec<String>,
    topic3: Vec<String>,
}

impl MaterializedTopicSelection {
    fn has_filters(&self) -> bool {
        !(self.topic1.is_empty() && self.topic2.is_empty() && self.topic3.is_empty())
    }

    fn into_topics(self) -> Vec<Vec<String>> {
        vec![self.topic0, self.topic1, self.topic2, self.topic3]
    }
}

struct RegistrationSelection {
    contract_name: String,
    is_wildcard: bool,
    depends_on_addresses: bool,
    topic_selections: Vec<TopicSelection>,
    block_fields: Vec<BlockField>,
    transaction_fields: Vec<TransactionField>,
}

/// Left-pad a 20-byte address to a 32-byte topic value. Lowercased — topic
/// values are compared as bytes server-side and registration-time values are
/// lowercased the same way.
fn address_to_topic(address: &str) -> Result<String> {
    let bytes = hypersync_client::format::Address::decode_hex(address)
        .with_context(|| format!("decode address {address} for topic encoding"))?;
    Ok(format!(
        "0x000000000000000000000000{}",
        faster_hex::hex_string(bytes.as_slice())
    ))
}

/// Fold selections without topic1..3 filters into one selection combining
/// their topic0s, keeping the common case at a single log selection/request.
fn compress(
    selections: Vec<MaterializedTopicSelection>,
) -> Vec<MaterializedTopicSelection> {
    let mut filterless_topic0s: Vec<String> = Vec::new();
    let mut with_filters = Vec::new();
    for selection in selections {
        if selection.has_filters() {
            with_filters.push(selection);
        } else {
            filterless_topic0s.extend(selection.topic0);
        }
    }
    let mut result = Vec::with_capacity(with_filters.len() + 1);
    if !filterless_topic0s.is_empty() {
        result.push(MaterializedTopicSelection {
            topic0: filterless_topic0s,
            topic1: Vec::new(),
            topic2: Vec::new(),
            topic3: Vec::new(),
        });
    }
    result.extend(with_filters);
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
    /// Inverted address index for routing (1:1 — each address belongs to one
    /// contract).
    pub contract_name_by_address: HashMap<String, String>,
}

/// Builds per-query log selections from the registrations passed at client
/// construction. Registrations are keyed by their chain-scoped sequential id;
/// a query names the ids of its partition's selection plus the partition's
/// current addresses per contract.
pub(crate) struct SelectionBuilder {
    registrations: HashMap<i64, RegistrationSelection>,
}

impl SelectionBuilder {
    pub(crate) fn from_registrations(
        registrations: &[super::types::EventRegistrationInput],
    ) -> Result<Self> {
        let mut map = HashMap::new();
        for reg in registrations {
            let parsed = RegistrationSelection {
                contract_name: reg.contract_name.clone(),
                is_wildcard: reg.is_wildcard,
                depends_on_addresses: reg.depends_on_addresses,
                topic_selections: reg
                    .topic_selections
                    .iter()
                    .map(|ts| TopicSelection {
                        topic0: ts.topic0.clone(),
                        topic1: TopicFilter::parse(&ts.topic1),
                        topic2: TopicFilter::parse(&ts.topic2),
                        topic3: TopicFilter::parse(&ts.topic3),
                    })
                    .collect(),
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
        addresses_by_contract_name: &HashMap<String, Vec<String>>,
    ) -> Result<BuiltSelection> {
        // Buckets: address-free selections pool together; address-bound ones
        // group per contract so one contract's query can't fetch a sibling's
        // logs (routing never re-applies the sibling's filter). Wildcard
        // events that filter an indexed param by registered addresses fold
        // the addresses into topics, so their query stays address-unbound.
        let mut no_address: Vec<MaterializedTopicSelection> = Vec::new();
        let mut by_contract: HashMap<&str, Vec<&TopicSelection>> = HashMap::new();
        let mut wildcard_by_contract: HashMap<&str, Vec<&TopicSelection>> = HashMap::new();
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
            if reg.depends_on_addresses {
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
                    .extend(reg.topic_selections.iter());
            } else {
                no_address.extend(reg.topic_selections.iter().map(|ts| ts.materialize(&[])));
            }
        }

        let mut log_selections: Vec<BuiltLogSelection> = Vec::new();
        let mut push_selections =
            |addresses: &[String], selections: Vec<MaterializedTopicSelection>| {
                for selection in compress(selections) {
                    log_selections.push(BuiltLogSelection {
                        addresses: addresses.to_vec(),
                        topics: selection.into_topics(),
                    });
                }
            };

        push_selections(&[], no_address);

        for contract_name in ordered_contracts {
            let addresses = match addresses_by_contract_name.get(contract_name) {
                None => continue,
                Some(addresses) if addresses.is_empty() => continue,
                Some(addresses) => addresses,
            };
            let address_topics: Vec<String> = addresses
                .iter()
                .map(|a| address_to_topic(a))
                .collect::<Result<_>>()?;
            if let Some(selections) = by_contract.get(contract_name) {
                push_selections(
                    addresses,
                    selections
                        .iter()
                        .map(|ts| ts.materialize(&address_topics))
                        .collect(),
                );
            }
            if let Some(selections) = wildcard_by_contract.get(contract_name) {
                push_selections(
                    &[],
                    selections
                        .iter()
                        .map(|ts| ts.materialize(&address_topics))
                        .collect(),
                );
            }
        }

        // Routing needs the whole partition index, including contracts with no
        // selection in this query (their logs still fall back to wildcards).
        let mut contract_name_by_address = HashMap::new();
        for (contract_name, addresses) in addresses_by_contract_name {
            for address in addresses {
                contract_name_by_address.insert(address.clone(), contract_name.clone());
            }
        }

        Ok(BuiltSelection {
            log_selections,
            block_fields,
            transaction_fields,
            contract_name_by_address,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::evm_hypersync_source::types::EventRegistrationInput;

    const SIGHASH_A: &str = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const SIGHASH_B: &str = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const ADDR: &str = "0x1234567890abcdef1234567890abcdef12345678";
    const ADDR_TOPIC: &str =
        "0x0000000000000000000000001234567890abcdef1234567890abcdef12345678";

    fn reg(
        id: i64,
        sighash: &str,
        contract_name: &str,
        is_wildcard: bool,
        depends_on_addresses: bool,
        topic1: Option<Vec<String>>,
    ) -> EventRegistrationInput {
        EventRegistrationInput {
            index: id,
            sighash: sighash.to_string(),
            topic_count: 1,
            event_name: "E".to_string(),
            contract_name: contract_name.to_string(),
            is_wildcard,
            depends_on_addresses,
            params: vec![],
            topic_selections: vec![TopicSelectionInput {
                topic0: vec![sighash.to_string()],
                topic1,
                topic2: Some(vec![]),
                topic3: Some(vec![]),
            }],
            block_fields: vec![],
            transaction_fields: vec![],
        }
    }

    fn addresses(entries: &[(&str, &[&str])]) -> HashMap<String, Vec<String>> {
        entries
            .iter()
            .map(|(name, addrs)| {
                (
                    name.to_string(),
                    addrs.iter().map(|a| a.to_string()).collect(),
                )
            })
            .collect()
    }

    #[test]
    fn filterless_events_compress_into_one_selection() {
        let builder = SelectionBuilder::from_registrations(&[
            reg(0, SIGHASH_A, "C", false, true, Some(vec![])),
            reg(1, SIGHASH_B, "C", false, true, Some(vec![])),
        ])
        .unwrap();
        let built = builder
            .build(&[0, 1], &addresses(&[("C", &[ADDR])]))
            .unwrap();
        assert_eq!(
            built.log_selections,
            vec![BuiltLogSelection {
                addresses: vec![ADDR.to_string()],
                topics: vec![
                    vec![SIGHASH_A.to_string(), SIGHASH_B.to_string()],
                    vec![],
                    vec![],
                    vec![],
                ],
            }]
        );
        assert_eq!(
            built.contract_name_by_address.get(ADDR),
            Some(&"C".to_string())
        );
    }

    #[test]
    fn wildcard_selection_stays_address_free() {
        let builder = SelectionBuilder::from_registrations(&[reg(
            0, SIGHASH_A, "C", true, false, Some(vec![]),
        )])
        .unwrap();
        let built = builder.build(&[0], &HashMap::new()).unwrap();
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
        let builder = SelectionBuilder::from_registrations(&[reg(
            0, SIGHASH_A, "C", true, true, None,
        )])
        .unwrap();
        let built = builder
            .build(&[0], &addresses(&[("C", &[ADDR])]))
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
    fn contract_without_addresses_is_skipped() {
        let builder = SelectionBuilder::from_registrations(&[reg(
            0, SIGHASH_A, "C", false, true, Some(vec![]),
        )])
        .unwrap();
        let built = builder
            .build(&[0], &addresses(&[("C", &[])]))
            .unwrap();
        assert_eq!(built.log_selections, vec![]);
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
            .build(&[1], &addresses(&[("C", &[ADDR])]))
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
        let built = builder.build(&[0, 1], &HashMap::new()).unwrap();
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
        let err = builder.build(&[7], &HashMap::new()).err().unwrap();
        assert!(format!("{err:#}").contains("Unknown registration index 7"));
    }
}
