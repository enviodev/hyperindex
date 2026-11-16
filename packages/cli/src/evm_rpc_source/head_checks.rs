//! Near the head a load-balanced provider can answer `eth_getLogs` from a node
//! that doesn't have the newest blocks yet, or from one still on a branch the
//! chain left, and nothing in the answer says so. So every block a head range
//! covers has its header read beside the logs, and a block the answer has none
//! of the selection's logs for is asked again by its hash whenever its
//! `logsBloom` can't rule them out. The logs' hashes themselves are checked
//! against the headers by the page's block store.
//!
//! Rechecking costs one filtered read per selection per block, so a block more
//! than one selection wants is read once unfiltered and matched locally. That
//! is strictly no worse than the per-selection reads it replaces for
//! completeness: it is one request, so every selection's logs come from the
//! same replica and cannot straddle a fork between them, and the local match
//! only drops logs no selection asked for. It still cannot catch what the
//! per-selection reads could not — a replica that answers a block hash with the
//! right hash but no logs — and that case is what the in-source completeness
//! check is for.
//!
//! An all-zero `logsBloom` is what some chains serve for every block, and what
//! every chain serves for a block holding no logs, so on its own it says
//! nothing. A checked block makes it say something: a block the range answer
//! holds one of the selection's logs for, and whose bloom is set, shows the
//! chain fills blooms, after which an all-zero bloom only means the block holds
//! no logs, and an empty head block is left alone. A block that holds a log yet
//! answers an all-zero bloom shows the opposite, and disproof is taken over
//! proof. Trust is earned per source and never shared, so a fallback provider
//! is calibrated on its own answers. The risk accepted is a chain that fills
//! blooms but serves a stale zero bloom at the head, which, together with a
//! replica's empty answer, loses the block's events; disproof only fires when a
//! log is seen at a zero-bloom block.

use std::collections::{BTreeMap, HashMap, HashSet};
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
/// whose header can't rule them out, so they are asked for again by hash. A
/// zero bloom is left alone when the chain is trusted to fill blooms, which
/// makes it the answer for a block holding no logs.
pub(crate) fn blocks_to_recheck(
    checked: &[u64],
    answered: &HashSet<u64>,
    headers: &HashMap<u64, CheckedHeader>,
    trust_zero_bloom: bool,
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
        let header_bloom = headers.get(&block).and_then(|header| header.bloom);
        // A chain that fills blooms serves a zero one only for a block with no
        // logs, so an empty block is not asked again. A missing bloom still
        // says nothing and is still asked again.
        if trust_zero_bloom && header_bloom == Some(Bloom::ZERO) {
            continue;
        }
        let bloom = header_bloom.filter(|bloom| *bloom != Bloom::ZERO);
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

/// What a checked block that holds one of the selection's logs says about a
/// source whose empty blocks come back with an all-zero `logsBloom`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ZeroBloomEvidence {
    /// The block holds a log and its bloom is set: the chain fills blooms.
    Proof,
    /// The block holds a log and its bloom is all zero: the chain does not.
    Disproof { block: u64 },
}

/// The evidence `checked` gives about a source that serves all-zero blooms,
/// taken from the blocks `blocks_with_logs` holds a log for. Disproof wins: a
/// source seen answering a zero bloom for a block that holds logs is distrusted
/// whatever else it answered. A block without a parsed bloom says nothing.
pub(crate) fn zero_bloom_evidence(
    checked: &[u64],
    blocks_with_logs: &HashSet<u64>,
    headers: &HashMap<u64, CheckedHeader>,
) -> Option<ZeroBloomEvidence> {
    let mut proof = None;
    for &block in checked {
        if !blocks_with_logs.contains(&block) {
            continue;
        }
        match headers.get(&block).and_then(|header| header.bloom) {
            Some(bloom) if bloom == Bloom::ZERO => {
                return Some(ZeroBloomEvidence::Disproof { block })
            }
            Some(_) => proof = proof.or(Some(ZeroBloomEvidence::Proof)),
            None => {}
        }
    }
    proof
}

/// The fewest selections that must want one block rechecked before a single
/// unfiltered read replaces their per-selection filtered reads. A block wanted
/// by one selection keeps that selection's own read: it is narrower and costs
/// the same.
const MIN_SELECTIONS_TO_COLLAPSE: usize = 2;

/// What a page's rechecks cost: the blocks each selection asks for on its own,
/// and the blocks read once unfiltered and matched across several selections.
pub(crate) struct RecheckPlan {
    /// `(selection index, block, reason)`, one filtered read per entry.
    pub filtered: Vec<(usize, u64, RecheckReason)>,
    /// `(block, selection indexes, reason)`, one unfiltered read per entry.
    pub unfiltered: Vec<(u64, Vec<usize>, RecheckReason)>,
}

/// Groups per-selection rechecks by block: a block two or more selections want
/// is read once unfiltered, a block one selection wants keeps its own filtered
/// read, and a block no selection wants is not read at all.
pub(crate) fn plan_rechecks(per_selection: Vec<Vec<(u64, RecheckReason)>>) -> RecheckPlan {
    let mut by_block: BTreeMap<u64, Vec<(usize, RecheckReason)>> = BTreeMap::new();
    for (selection, rechecks) in per_selection.into_iter().enumerate() {
        for (block, reason) in rechecks {
            by_block.entry(block).or_default().push((selection, reason));
        }
    }
    let mut filtered = Vec::new();
    let mut unfiltered = Vec::new();
    for (block, selections) in by_block {
        if selections.len() >= MIN_SELECTIONS_TO_COLLAPSE {
            // One read answers for all of them, so it is logged as matching
            // whenever any selection's bloom does.
            let reason = if selections
                .iter()
                .any(|&(_, reason)| reason == RecheckReason::BloomMatches)
            {
                RecheckReason::BloomMatches
            } else {
                RecheckReason::BloomSaysNothing
            };
            unfiltered.push((
                block,
                selections
                    .into_iter()
                    .map(|(selection, _)| selection)
                    .collect(),
                reason,
            ));
        } else {
            filtered.extend(
                selections
                    .into_iter()
                    .map(|(selection, reason)| (selection, block, reason)),
            );
        }
    }
    RecheckPlan {
        filtered,
        unfiltered,
    }
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
        let recheck =
            |selection| blocks_to_recheck(&checked, &answered, &headers, false, selection);
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

    #[test]
    fn a_block_two_selections_want_is_read_once_unfiltered() {
        use RecheckReason::*;
        let plan = plan_rechecks(vec![
            vec![(21, BloomSaysNothing), (22, BloomMatches)],
            vec![(22, BloomSaysNothing)],
            vec![(22, BloomMatches), (23, BloomSaysNothing)],
        ]);
        assert_eq!(
            (plan.filtered, plan.unfiltered),
            (
                // Block 21 and 23 are wanted by one selection each; block 22 is
                // wanted by three, so it is read once unfiltered.
                vec![(0, 21, BloomSaysNothing), (2, 23, BloomSaysNothing)],
                vec![(22, vec![0, 1, 2], BloomMatches)],
            ),
        );
    }

    #[test]
    fn a_filled_bloom_and_a_zero_one_each_speak_for_the_chain() {
        use ZeroBloomEvidence::*;
        let headers = HashMap::from([
            (3, header(&[(TOKEN, &[TRANSFER])])),
            (4, header(&[])),
            (
                5,
                CheckedHeader {
                    hash: Some("0xaa".to_string()),
                    bloom: None,
                },
            ),
            (6, header(&[(OTHER_TOKEN, &[APPROVAL])])),
        ]);
        let checked = [3, 4, 5, 6];
        let evidence = |blocks: &[u64]| {
            zero_bloom_evidence(&checked, &blocks.iter().copied().collect(), &headers)
        };
        assert_eq!(
            (
                // A log at a filled bloom is proof the chain fills blooms.
                evidence(&[3]),
                // A log at a zero bloom is proof the other way.
                evidence(&[4]),
                // Disproof wins over proof, whatever the order.
                evidence(&[3, 4]),
                // A block without a parsed bloom says nothing, so only the
                // filled-bloom block of 5 and 6 speaks.
                evidence(&[5, 6]),
                evidence(&[5]),
            ),
            (
                Some(Proof),
                Some(Disproof { block: 4 }),
                Some(Disproof { block: 4 }),
                Some(Proof),
                None,
            ),
        );
    }

    #[test]
    fn a_trusted_chain_leaves_an_all_zero_bloom_alone() {
        use RecheckReason::*;
        let headers = HashMap::from([
            (21, header(&[(TOKEN, &[TRANSFER])])),
            (22, header(&[])),
            (
                23,
                CheckedHeader {
                    hash: Some("0xaa".to_string()),
                    bloom: None,
                },
            ),
        ]);
        let checked = [21, 22, 23];
        let answered = HashSet::new();
        let selection = selection(Emitters::Listed(vec![TOKEN.to_string()]), &[&[TRANSFER]]);
        let recheck = |trust| blocks_to_recheck(&checked, &answered, &headers, trust, &selection);
        assert_eq!(
            (
                // Untrusted, an all-zero bloom says nothing, as a missing one
                // does.
                recheck(false),
                // Trusted, the zero bloom is the block holding no logs, while a
                // missing bloom still says nothing.
                recheck(true),
            ),
            (
                vec![
                    (21, BloomMatches),
                    (22, BloomSaysNothing),
                    (23, BloomSaysNothing),
                ],
                vec![(21, BloomMatches), (23, BloomSaysNothing)],
            ),
        );
    }
}
