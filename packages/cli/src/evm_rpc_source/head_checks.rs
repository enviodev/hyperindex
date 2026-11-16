//! Near the head a load-balanced provider can answer `eth_getLogs` from a node
//! that doesn't have the newest blocks yet, or from one still on a branch the
//! chain left, and nothing in the answer says so. So every block a head range
//! covers has its header read beside the logs, and a block the answer has none
//! of the selection's logs for is asked again by its hash whenever its
//! `logsBloom` can't rule them out. The logs' hashes themselves are checked
//! against the headers by the page's block store.

use std::collections::{HashMap, HashSet};
use std::str::FromStr;

use alloy_primitives::{hex, Bloom, BloomInput};
use serde_json::Value as Json;

use crate::evm_hypersync_source::selection::BuiltLogSelection;

/// How far below the head blocks are checked, whatever the chain's reorg
/// depth: a chain that never reorgs, which Arbitrum and Optimism are
/// configured as, has providers that lag all the same.
const HEAD_CHECK_DISTANCE: u64 = 200;

/// The blocks of `from_block..=to_block` to check: every block that can still
/// be reorged, and for a page reading logs every block within
/// `HEAD_CHECK_DISTANCE` of the head, the backfill's last page included. A page
/// reading no logs, `log_page_known_height` `None`, has nothing a lagging node
/// could leave out, so only the hashes linking its reorgable blocks are read.
pub(crate) fn blocks_to_check(
    from_block: u64,
    to_block: u64,
    reorgable_from: Option<u64>,
    log_page_known_height: Option<u64>,
) -> Vec<u64> {
    let near_head_from =
        log_page_known_height.map(|known_height| known_height.saturating_sub(HEAD_CHECK_DISTANCE));
    let check_from = match (reorgable_from, near_head_from) {
        (Some(reorgable_from), Some(near_head_from)) => reorgable_from.min(near_head_from),
        (Some(check_from), None) | (None, Some(check_from)) => check_from,
        (None, None) => return Vec::new(),
    };
    (from_block.max(check_from)..=to_block).collect()
}

/// The bloom bits each value a selection filters on sets, so a header's bloom
/// is tested without hashing the selection again for every block.
struct SelectionBloom {
    /// Empty for an address-free selection.
    addresses: Vec<Bloom>,
    /// Per topic position; empty where the position matches anything.
    topics: Vec<Vec<Bloom>>,
}

impl SelectionBloom {
    /// `None` when a value isn't hex, which leaves the selection's blocks
    /// unruled-out rather than failing the page.
    fn new(selection: &BuiltLogSelection) -> Option<Self> {
        let blooms = |values: &[String]| -> Option<Vec<Bloom>> {
            values
                .iter()
                .map(|value| {
                    hex::decode(value)
                        .ok()
                        .map(|bytes| Bloom::from(BloomInput::Raw(&bytes)))
                })
                .collect()
        };
        Some(SelectionBloom {
            addresses: blooms(selection.addresses())?,
            topics: selection
                .topics
                .iter()
                .map(|values| blooms(values))
                .collect::<Option<_>>()?,
        })
    }

    /// A matching log has one of the addresses and, at every constrained
    /// position, one of its topics. The bloom can't tell whether those come
    /// from the same log, so this is a "maybe".
    fn may_match(&self, bloom: &Bloom) -> bool {
        let any_set = |values: &[Bloom]| values.iter().any(|value| bloom.contains(value));
        (self.addresses.is_empty() || any_set(&self.addresses))
            && self
                .topics
                .iter()
                .all(|values| values.is_empty() || any_set(values))
    }
}

pub(crate) struct CheckedHeader {
    pub hash: Option<String>,
    bloom: Option<Bloom>,
}

impl CheckedHeader {
    pub(crate) fn read(header: &Json) -> Self {
        let string = |field| header.get(field).and_then(Json::as_str);
        CheckedHeader {
            hash: string("hash").map(str::to_string),
            bloom: string("logsBloom").and_then(|bloom| Bloom::from_str(bloom).ok()),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RecheckReason {
    /// The bloom has the selection's bits set.
    BloomMatches,
    /// The bloom is missing or all zero, which some chains serve whatever
    /// the block holds.
    BloomSaysNothing,
}

impl RecheckReason {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            RecheckReason::BloomMatches => "bloomMatches",
            RecheckReason::BloomSaysNothing => "bloomSaysNothing",
        }
    }
}

/// The checked blocks a selection's answer held none of its logs for, and
/// whose header can't rule them out, so they are asked for again by hash.
pub(crate) fn blocks_to_recheck(
    checked: &[u64],
    answered: &HashSet<u64>,
    headers: &HashMap<u64, CheckedHeader>,
    selection: &BuiltLogSelection,
) -> Vec<(u64, RecheckReason)> {
    // Hashing a selection costs a keccak per address, which only a block whose
    // bloom has something to say is worth paying for.
    let mut selection_bloom: Option<Option<SelectionBloom>> = None;
    let mut rechecks = Vec::new();
    for &block in checked {
        if answered.contains(&block) {
            continue;
        }
        let bloom = headers
            .get(&block)
            .and_then(|header| header.bloom)
            .filter(|bloom| *bloom != Bloom::ZERO);
        let reason = match bloom {
            Some(bloom) => {
                match selection_bloom.get_or_insert_with(|| SelectionBloom::new(selection)) {
                    Some(selection_bloom) if !selection_bloom.may_match(&bloom) => continue,
                    Some(_) => RecheckReason::BloomMatches,
                    None => RecheckReason::BloomSaysNothing,
                }
            }
            None => RecheckReason::BloomSaysNothing,
        };
        rechecks.push((block, reason));
    }
    rechecks
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::evm_hypersync_source::selection::{AddressFreeOrigin, Emitters};

    const TOKEN: &str = "0x1000000000000000000000000000000000000001";
    const OTHER_TOKEN: &str = "0x2000000000000000000000000000000000000002";
    const TRANSFER: &str = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
    const APPROVAL: &str = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925";

    /// A header whose bloom holds `logs`, each an address and its topics.
    fn header(logs: &[(&str, &[&str])]) -> CheckedHeader {
        let mut bloom = Bloom::ZERO;
        for (address, topics) in logs {
            for value in std::iter::once(address).chain(topics.iter()) {
                bloom.accrue(BloomInput::Raw(&hex::decode(value).unwrap()));
            }
        }
        CheckedHeader {
            hash: Some("0xaa".to_string()),
            bloom: Some(bloom),
        }
    }

    fn selection(emitters: Emitters, topics: &[&[&str]]) -> BuiltLogSelection {
        BuiltLogSelection {
            emitters,
            topics: topics
                .iter()
                .map(|values| values.iter().map(|value| value.to_string()).collect())
                .collect(),
        }
    }

    fn may_match(selection: BuiltLogSelection, bloom: &Bloom) -> bool {
        SelectionBloom::new(&selection).unwrap().may_match(bloom)
    }

    #[test]
    fn checks_reorgable_blocks_and_at_least_the_last_two_hundred() {
        let range = |from: u64, to: u64| (from..=to).collect::<Vec<_>>();
        assert_eq!(
            (
                // Backfill reaching the head, and far below it.
                blocks_to_check(500, 1000, None, Some(1000)),
                blocks_to_check(100, 500, None, Some(1000)),
                // A reorg depth past the distance.
                blocks_to_check(500, 1000, Some(700), Some(1000)),
                // A reorg depth inside it, down to 0.
                blocks_to_check(500, 1000, Some(990), Some(1000)),
                blocks_to_check(500, 1000, Some(1000), Some(1000)),
                // A page catching up far below the head.
                blocks_to_check(100, 500, Some(1000), Some(1000)),
                // A chain younger than the distance.
                blocks_to_check(21, 24, Some(24), Some(24)),
                // A page reading no logs.
                blocks_to_check(500, 1000, Some(990), None),
                blocks_to_check(500, 1000, None, None),
            ),
            (
                range(800, 1000),
                vec![],
                range(700, 1000),
                range(800, 1000),
                range(800, 1000),
                vec![],
                range(21, 24),
                range(990, 1000),
                vec![],
            ),
        );
    }

    #[test]
    fn rechecks_an_unanswered_block_unless_its_bloom_rules_the_selection_out() {
        let headers = HashMap::from([
            (21, header(&[(TOKEN, &[TRANSFER])])),
            // Neither the address nor the event.
            (22, header(&[(OTHER_TOKEN, &[APPROVAL])])),
            // Both, but in different logs.
            (
                23,
                header(&[(TOKEN, &[APPROVAL]), (OTHER_TOKEN, &[TRANSFER])]),
            ),
            (24, header(&[])),
            (
                25,
                CheckedHeader {
                    hash: Some("0xaa".to_string()),
                    bloom: None,
                },
            ),
            // The address, but not the event.
            (26, header(&[(TOKEN, &[APPROVAL])])),
        ]);
        let checked = [21, 22, 23, 24, 25, 26, 27];
        let answered = HashSet::from([21]);
        let by_address = selection(Emitters::Listed(vec![TOKEN.to_string()]), &[&[TRANSFER]]);
        let address_free = selection(Emitters::Any(AddressFreeOrigin::default()), &[&[TRANSFER]]);
        let not_hex = selection(Emitters::Listed(vec!["token".to_string()]), &[&[TRANSFER]]);
        let recheck = |selection| blocks_to_recheck(&checked, &answered, &headers, selection);
        use RecheckReason::*;
        assert_eq!(
            (
                recheck(&by_address),
                recheck(&address_free),
                recheck(&not_hex),
            ),
            (
                vec![
                    (23, BloomMatches),
                    (24, BloomSaysNothing),
                    (25, BloomSaysNothing),
                    (27, BloomSaysNothing),
                ],
                vec![
                    (23, BloomMatches),
                    (24, BloomSaysNothing),
                    (25, BloomSaysNothing),
                    (27, BloomSaysNothing),
                ],
                (22..=27).map(|block| (block, BloomSaysNothing)).collect(),
            ),
        );
    }

    #[test]
    fn a_constrained_topic_position_must_have_one_of_its_values_set() {
        let from_token = format!("0x{:0>64}", &TOKEN[2..]);
        let from_other = format!("0x{:0>64}", &OTHER_TOKEN[2..]);
        let bloom = header(&[(TOKEN, &[TRANSFER, &from_other])]).bloom.unwrap();
        assert_eq!(
            (
                may_match(
                    selection(Emitters::Listed(vec![]), &[&[TRANSFER], &[&from_token]]),
                    &bloom
                ),
                may_match(
                    selection(Emitters::Listed(vec![]), &[&[TRANSFER], &[], &[]]),
                    &bloom
                ),
                may_match(
                    selection(
                        Emitters::Listed(vec![]),
                        &[&[TRANSFER], &[&from_token, &from_other]]
                    ),
                    &bloom
                ),
            ),
            (false, true, true),
        );
    }

    #[test]
    fn reads_the_hash_and_bloom_a_header_carries() {
        let bloom = format!("0x{}", "00".repeat(255) + "01");
        let read = |header: Json| {
            let read = CheckedHeader::read(&header);
            (read.hash, read.bloom.map(|bloom| bloom == Bloom::ZERO))
        };
        assert_eq!(
            (
                read(serde_json::json!({"hash": "0xaa", "logsBloom": bloom})),
                read(serde_json::json!({"hash": "0xaa", "logsBloom": "0x12"})),
                read(serde_json::json!({})),
            ),
            (
                (Some("0xaa".to_string()), Some(false)),
                (Some("0xaa".to_string()), None),
                (None, None),
            ),
        );
    }
}
