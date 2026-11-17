//! Plans how a page reads the logs of its log selections: one merged
//! `eth_getLogs` for the selections a single filter can serve, and one read per
//! selection for the rest. A merged read is only ever a superset of its
//! members' filters, so each member's own logs are picked out of the answer
//! locally (`LogMatcher`).

use alloy_primitives::hex;
use std::collections::HashSet;

use super::super::evm_hypersync_source::selection::{BuiltLogSelection, Emitters};

/// How one page reads the logs of one selection, or of a group that shares one
/// filter.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum RangeRead {
    /// One selection, read the way it is read today.
    Own(usize),
    /// Two or more Listed selections, read with one merged filter.
    Merged {
        selections: Vec<usize>,
        filter: BuiltLogSelection,
    },
}

pub(super) fn plan_range_reads(selections: &[BuiltLogSelection]) -> Vec<RangeRead> {
    /// The filter two selections must share to land in one group: whether topic0
    /// is constrained, and the value at each position past it, trailing
    /// match-any positions removed.
    type TopicGroupKey = (bool, Vec<Vec<String>>);

    enum Planned {
        Own(usize),
        Group(Vec<usize>),
    }
    // Two selections naming the same filter land in one group, and one that
    // adds a `where` constraint on a position stays out.
    fn group_key(selection: &BuiltLogSelection) -> TopicGroupKey {
        let mut trimmed_len = selection.topics.len();
        while trimmed_len > 0 && selection.topics[trimmed_len - 1].is_empty() {
            trimmed_len -= 1;
        }
        let topic0_constrained = selection
            .topics
            .first()
            .is_some_and(|values| !values.is_empty());
        let positions = (1..=3)
            .map(|position| {
                if position < trimmed_len {
                    selection.topics[position].clone()
                } else {
                    Vec::new()
                }
            })
            .collect();
        (topic0_constrained, positions)
    }

    let mut planned: Vec<Planned> = Vec::new();
    let mut groups: Vec<(TopicGroupKey, usize)> = Vec::new();
    for (index, selection) in selections.iter().enumerate() {
        let groupable = matches!(
            &selection.emitters,
            Emitters::Listed(addresses) if !addresses.is_empty()
        );
        if !groupable {
            planned.push(Planned::Own(index));
            continue;
        }
        let key = group_key(selection);
        match groups.iter_mut().find(|(kept, _)| *kept == key) {
            Some((_, planned_index)) => match &mut planned[*planned_index] {
                Planned::Group(indexes) => indexes.push(index),
                Planned::Own(_) => unreachable!("a group is never planned as an own read"),
            },
            None => {
                groups.push((key, planned.len()));
                planned.push(Planned::Group(vec![index]));
            }
        }
    }

    planned
        .into_iter()
        .map(|entry| match entry {
            Planned::Own(index) => RangeRead::Own(index),
            Planned::Group(indexes) if indexes.len() == 1 => RangeRead::Own(indexes[0]),
            Planned::Group(indexes) => {
                let members: Vec<&BuiltLogSelection> =
                    indexes.iter().map(|&index| &selections[index]).collect();
                RangeRead::Merged {
                    filter: merge_selections_for_range(&members),
                    selections: indexes,
                }
            }
        })
        .collect()
}

/// The one filter that covers every member: the address union, the topic0
/// union, and the shared value at each position past topic0. By the group rule
/// those shared values are equal across the members, so the merged filter is a
/// superset of every member's filter and drops no constraint.
pub(super) fn merge_selections_for_range(selections: &[&BuiltLogSelection]) -> BuiltLogSelection {
    // The union keeps the first spelling of each address, so a set tracks
    // membership while the vector keeps the request order.
    let mut addresses: Vec<String> = Vec::new();
    let mut seen: HashSet<Vec<u8>> = HashSet::new();
    for selection in selections {
        for address in selection.addresses() {
            match hex::decode(address) {
                Ok(bytes) => {
                    if seen.insert(bytes) {
                        addresses.push(address.clone());
                    }
                }
                Err(_) => {
                    if !addresses.contains(address) {
                        addresses.push(address.clone());
                    }
                }
            }
        }
    }
    let mut topic0: Vec<String> = Vec::new();
    for selection in selections {
        if let Some(values) = selection.topics.first() {
            for value in values {
                if !topic0.contains(value) {
                    topic0.push(value.clone());
                }
            }
        }
    }
    let shared = |position: usize| -> Vec<String> {
        selections
            .first()
            .and_then(|selection| selection.topics.get(position))
            .cloned()
            .unwrap_or_default()
    };
    BuiltLogSelection {
        emitters: Emitters::Listed(addresses),
        topics: vec![topic0, shared(1), shared(2), shared(3)],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::evm_hypersync_source::selection::AddressFreeOrigin;

    const A: &str = "0x1000000000000000000000000000000000000001";
    const B: &str = "0x2000000000000000000000000000000000000002";
    const C: &str = "0x3000000000000000000000000000000000000003";
    const D: &str = "0x4000000000000000000000000000000000000004";
    const E: &str = "0x5000000000000000000000000000000000000005";
    const T1: &str = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
    const X: &str = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925";
    const Y: &str = "0x00000000000000000000000000000000000000000000000000000000000000aa";

    fn listed(addresses: &[&str]) -> Emitters {
        Emitters::Listed(addresses.iter().map(|a| a.to_string()).collect())
    }

    fn selection(addresses: &[&str], topics: &[&[&str]]) -> BuiltLogSelection {
        BuiltLogSelection {
            emitters: listed(addresses),
            topics: topics
                .iter()
                .map(|values| values.iter().map(|v| v.to_string()).collect())
                .collect(),
        }
    }

    #[test]
    fn listed_selections_with_equal_topics_past_topic0_share_one_read() {
        let selections = vec![
            // Trailing empty positions, implicit and explicit, name the same
            // filter and so land in one group.
            selection(&[A], &[&[T1]]),
            selection(&[B], &[&[T1], &[], &[], &[]]),
            // A shared constraint past topic0 groups two selections on its own.
            selection(&[C], &[&[T1], &[], &[X]]),
            selection(&[D], &[&[T1], &[], &[X], &[]]),
            // An address-free selection keeps its own read.
            BuiltLogSelection {
                emitters: Emitters::Any(AddressFreeOrigin::default()),
                topics: vec![vec![T1.to_string()], vec![]],
            },
            // A different value past topic0 keeps its own read: a merged filter
            // must not drop the constraint.
            selection(&[E], &[&[T1], &[Y]]),
        ];
        let expected = vec![
            RangeRead::Merged {
                selections: vec![0, 1],
                filter: selection(&[A, B], &[&[T1], &[], &[], &[]]),
            },
            RangeRead::Merged {
                selections: vec![2, 3],
                filter: selection(&[C, D], &[&[T1], &[], &[X], &[]]),
            },
            RangeRead::Own(4),
            RangeRead::Own(5),
        ];
        assert_eq!(plan_range_reads(&selections), expected);
    }
}
