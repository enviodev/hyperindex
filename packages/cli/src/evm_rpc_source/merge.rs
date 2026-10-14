//! Collapses a short page's address-bound selections into one `eth_getLogs`.
//!
//! The selection builder groups address-bound events per contract, so that a
//! backfill range never pays for a sibling contract's traffic under signatures
//! it did not register. Over RPC every group is a request of its own, and at
//! the head — where a page spans a block or a handful — that is one request per
//! contract per block, to keep out a superset that holds a few logs at most.
//! So a short page asks once, for every emitter and every signature together,
//! and leaves the narrowing to routing, which re-checks each log's emitter,
//! signature and topic filters against its registration however the log was
//! fetched.
//!
//! Address-free selections are left alone: with no emitter list, their topic
//! filters are what keeps the query off the whole chain's traffic.

use crate::evm_hypersync_source::selection::BuiltLogSelection;

/// The longest page read with one request across its address-bound
/// selections. A head page spans the blocks that arrived while the previous
/// one was in flight, one to a handful, so this covers it with room for a slow
/// provider on a fast chain, while a merged read still pulls in sibling logs
/// from a few blocks at most.
pub(crate) const MERGED_PAGE_MAX_BLOCKS: u64 = 32;

pub(crate) fn merge_address_bound(selections: Vec<BuiltLogSelection>) -> Vec<BuiltLogSelection> {
    let (bound, free): (Vec<_>, Vec<_>) = selections
        .into_iter()
        .partition(|selection| !selection.addresses.is_empty());
    if bound.len() < 2 {
        return free.into_iter().chain(bound).collect();
    }

    let mut addresses: Vec<String> = Vec::new();
    let mut topic0: Vec<String> = Vec::new();
    // A selection matching any signature widens the merged one to the same.
    let mut any_topic0 = false;
    for selection in bound {
        for address in selection.addresses {
            if !addresses.contains(&address) {
                addresses.push(address);
            }
        }
        match selection.topics.first() {
            Some(values) if !values.is_empty() => {
                for value in values {
                    if !topic0.contains(value) {
                        topic0.push(value.clone());
                    }
                }
            }
            _ => any_topic0 = true,
        }
    }

    let mut merged = free;
    merged.push(BuiltLogSelection {
        addresses,
        topics: vec![
            if any_topic0 { Vec::new() } else { topic0 },
            Vec::new(),
            Vec::new(),
            Vec::new(),
        ],
    });
    merged
}

#[cfg(test)]
mod tests {
    use super::*;

    const ADDR_A: &str = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const ADDR_B: &str = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const SIG_1: &str = "0x1111111111111111111111111111111111111111111111111111111111111111";
    const SIG_2: &str = "0x2222222222222222222222222222222222222222222222222222222222222222";
    const FILTER: &str = "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    fn selection(addresses: &[&str], topics: [&[&str]; 4]) -> BuiltLogSelection {
        BuiltLogSelection {
            addresses: strings(addresses),
            topics: topics.iter().map(|position| strings(position)).collect(),
        }
    }

    #[test]
    fn two_contracts_are_read_as_one_selection_over_both() {
        let merged = merge_address_bound(vec![
            selection(&[ADDR_A], [&[SIG_1], &[], &[], &[]]),
            selection(&[ADDR_B], [&[SIG_2], &[], &[], &[]]),
        ]);
        assert_eq!(
            merged,
            vec![selection(
                &[ADDR_A, ADDR_B],
                [&[SIG_1, SIG_2], &[], &[], &[]]
            )]
        );
    }

    #[test]
    fn topic_filters_are_left_to_routing() {
        // Two OR branches of one contract's filtered event.
        let merged = merge_address_bound(vec![
            selection(&[ADDR_A], [&[SIG_1], &[FILTER], &[], &[]]),
            selection(&[ADDR_A], [&[SIG_1], &[], &[FILTER], &[]]),
        ]);
        assert_eq!(
            merged,
            vec![selection(&[ADDR_A], [&[SIG_1], &[], &[], &[]])]
        );
    }

    #[test]
    fn a_lone_address_bound_selection_keeps_its_filters() {
        let lone = selection(&[ADDR_A], [&[SIG_1], &[FILTER], &[], &[]]);
        assert_eq!(merge_address_bound(vec![lone.clone()]), vec![lone]);
    }

    #[test]
    fn address_free_selections_stay_apart_and_keep_their_filters() {
        let wildcard = selection(&[], [&[SIG_2], &[FILTER], &[], &[]]);
        let merged = merge_address_bound(vec![
            wildcard.clone(),
            selection(&[ADDR_A], [&[SIG_1], &[], &[], &[]]),
            selection(&[ADDR_B], [&[SIG_1], &[], &[], &[]]),
        ]);
        assert_eq!(
            merged,
            vec![
                wildcard,
                selection(&[ADDR_A, ADDR_B], [&[SIG_1], &[], &[], &[]])
            ]
        );
    }

    #[test]
    fn a_selection_matching_any_signature_widens_the_merged_one() {
        let merged = merge_address_bound(vec![
            selection(&[ADDR_A], [&[SIG_1], &[], &[], &[]]),
            selection(&[ADDR_B], [&[], &[], &[], &[]]),
        ]);
        assert_eq!(
            merged,
            vec![selection(&[ADDR_A, ADDR_B], [&[], &[], &[], &[]])]
        );
    }
}
