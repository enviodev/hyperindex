//! Reads the raw logs one log selection matches over a block range, or in one
//! block named by its hash. Matching them to registrations is the caller's next
//! step: everything here stays in the provider's own terms, `blockHash`
//! included.

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};

use serde_json::{json, Value};

use super::classify::is_result_cap_message;
use super::client::{JsonRpcClient, RpcError};
use super::RawLog;
use crate::chain_buffer::selection::evm::{
    AddressFreeOrigin, BuiltLogSelection, Emitters, SelectionByAddress,
};
use crate::logger::{BoundLogger, Level};

/// The blocks one `eth_getLogs` asks about.
#[derive(Clone, Copy, Debug)]
pub(super) enum LogBlocks<'a> {
    Range {
        from_block: u64,
        to_block: u64,
    },
    /// One block by its hash (EIP-234). A node that doesn't have that block
    /// answers with an error rather than with no logs, which is the point of
    /// asking this way.
    Hash {
        block_number: u64,
        hash: &'a str,
    },
    /// One block asked again by its number, for a provider that refuses
    /// reads by hash.
    RecheckByNumber {
        block_number: u64,
    },
}

impl LogBlocks<'_> {
    fn bounds(&self) -> (u64, u64) {
        match *self {
            LogBlocks::Range {
                from_block,
                to_block,
            } => (from_block, to_block),
            LogBlocks::Hash { block_number, .. } | LogBlocks::RecheckByNumber { block_number } => {
                (block_number, block_number)
            }
        }
    }

    /// What the read is reported as, so the source's request metrics count a
    /// head block asked again apart from the range reads.
    fn stat_method(&self) -> &'static str {
        match self {
            LogBlocks::Range { .. } => "eth_getLogs",
            LogBlocks::Hash { .. } | LogBlocks::RecheckByNumber { .. } => {
                "eth_getLogs (head block recheck)"
            }
        }
    }
}

/// The `eth_getLogs` filter: `null` matches any value at a topic position,
/// trailing match-any positions are trimmed, and no addresses means any
/// emitter.
fn log_filter(blocks: LogBlocks, topics: &[Vec<String>], addresses: &[String]) -> Value {
    let mut topics: Vec<Option<&Vec<String>>> = topics
        .iter()
        .map(|values| (!values.is_empty()).then_some(values))
        .collect();
    while matches!(topics.last(), Some(None)) {
        topics.pop();
    }
    let mut filter = match blocks {
        LogBlocks::Range { .. } | LogBlocks::RecheckByNumber { .. } => {
            let (from_block, to_block) = blocks.bounds();
            json!({
                "fromBlock": format!("0x{from_block:x}"),
                "toBlock": format!("0x{to_block:x}"),
                "topics": topics,
            })
        }
        LogBlocks::Hash { hash, .. } => json!({
            "blockHash": hash,
            "topics": topics,
        }),
    };
    if !addresses.is_empty() {
        filter["address"] = json!(addresses);
    }
    filter
}

/// Whether an address-free request failed for the size of what it asked for,
/// which the same logs asked for by address can avoid. Throttling and an
/// unreachable provider aren't: more requests would only make them worse.
fn is_answer_too_large(error: &RpcError) -> bool {
    match error {
        RpcError::JsonRpc { message, .. } => is_result_cap_message(message),
        RpcError::Timeout(_) | RpcError::MalformedResponse(_) => true,
        RpcError::RateLimited { .. } | RpcError::Other(_) => false,
    }
}

/// Every request is awaited even once one has failed, so each is made and
/// billed; the first failure then decides.
async fn request_all(
    client: &JsonRpcClient,
    blocks: LogBlocks<'_>,
    selections: &[BuiltLogSelection],
) -> Result<Vec<RawLog>, RpcError> {
    let results = futures_util::future::join_all(
        selections
            .iter()
            .map(|selection| request(client, blocks, selection)),
    )
    .await;
    let mut logs = Vec::new();
    for result in results {
        logs.extend(result?);
    }
    Ok(logs)
}

async fn request(
    client: &JsonRpcClient,
    blocks: LogBlocks<'_>,
    selection: &BuiltLogSelection,
) -> Result<Vec<RawLog>, RpcError> {
    client
        .request_recorded_as(
            blocks.stat_method(),
            "eth_getLogs",
            json!([log_filter(blocks, &selection.topics, selection.addresses())]),
        )
        .await
}

/// The selections as requests: one asking for more than `cap` addresses is
/// split into requests of at most `cap`. With `group`, the by-address ones
/// that constrain topic0 alone are merged, up to `cap` addresses a request,
/// each asking for all their addresses and topic0s. A log of one contract's
/// address with another contract's topic0 comes back too; matching drops it.
/// Aligned with what it returns, the selections each request was made of:
/// none for one read as built.
pub(super) fn pack_by_address(
    selections: Vec<BuiltLogSelection>,
    group: bool,
    cap: usize,
) -> (Vec<BuiltLogSelection>, Vec<Vec<BuiltLogSelection>>) {
    let cap = cap.max(1);
    let groupable = |selection: &BuiltLogSelection| {
        group
            && matches!(selection.emitters, Emitters::Listed(_))
            && selection
                .topics
                .first()
                .is_some_and(|topic0| !topic0.is_empty())
            && selection.topics.iter().skip(1).all(Vec::is_empty)
    };
    let mut kept = Vec::new();
    let mut grouped = Vec::new();
    for selection in selections {
        let chunks: Vec<BuiltLogSelection> = match &selection.emitters {
            Emitters::Listed(addresses) if addresses.len() > cap => addresses
                .chunks(cap)
                .map(|chunk| BuiltLogSelection {
                    emitters: Emitters::Listed(chunk.to_vec()),
                    topics: selection.topics.clone(),
                })
                .collect(),
            _ => vec![selection],
        };
        for chunk in chunks {
            if groupable(&chunk) {
                grouped.push(chunk);
            } else {
                kept.push(chunk);
            }
        }
    }
    let mut parts: Vec<Vec<BuiltLogSelection>> = kept.iter().map(|_| Vec::new()).collect();
    let mut batch: Vec<BuiltLogSelection> = Vec::new();
    let mut batch_addresses: HashSet<String> = HashSet::new();
    let mut flush = |batch: &mut Vec<BuiltLogSelection>| match batch.len() {
        0 => {}
        1 => {
            kept.push(batch.pop().expect("one selection"));
            parts.push(Vec::new());
        }
        _ => {
            let mut addresses: Vec<String> = Vec::new();
            let mut topic0s: Vec<String> = Vec::new();
            let mut seen_addresses = HashSet::new();
            let mut seen_topic0s = HashSet::new();
            for selection in batch.iter() {
                for address in selection.addresses() {
                    if seen_addresses.insert(address.as_str()) {
                        addresses.push(address.clone());
                    }
                }
                for topic0 in &selection.topics[0] {
                    if seen_topic0s.insert(topic0.as_str()) {
                        topic0s.push(topic0.clone());
                    }
                }
            }
            kept.push(BuiltLogSelection {
                emitters: Emitters::Listed(addresses),
                topics: vec![topic0s],
            });
            parts.push(std::mem::take(batch));
        }
    };
    for selection in grouped {
        let added = selection
            .addresses()
            .iter()
            .filter(|&address| !batch_addresses.contains(address))
            .count();
        if !batch.is_empty() && batch_addresses.len() + added > cap {
            batch_addresses.clear();
            flush(&mut batch);
        }
        batch_addresses.extend(selection.addresses().iter().cloned());
        batch.push(selection);
    }
    flush(&mut batch);
    (kept, parts)
}

/// Reads `selection` over `blocks`. A grouped selection the provider refuses
/// as too large is read as the selections it was made of, one request each.
/// When one block of an address-free selection holding client-filtered
/// registrations is too large, it is read again the way `by_address` rebuilds
/// it. A wider range goes back to the caller, whose retry shrinks it first.
/// A refused grouping is remembered in `grouping_refused`; an address-free
/// fallback is not: the next page asks the same way again.
pub(super) async fn request_selection_logs(
    client: &JsonRpcClient,
    logger: &BoundLogger,
    blocks: LogBlocks<'_>,
    selection: &BuiltLogSelection,
    parts: &[BuiltLogSelection],
    grouping_refused: &AtomicBool,
    by_address: impl FnOnce(&AddressFreeOrigin) -> anyhow::Result<SelectionByAddress>,
) -> Result<Vec<RawLog>, RpcError> {
    let error = match request(client, blocks, selection).await {
        Ok(logs) => return Ok(logs),
        Err(error) => error,
    };
    let (from_block, to_block) = blocks.bounds();
    if parts.len() > 1 && is_answer_too_large(&error) {
        grouping_refused.store(true, Ordering::Relaxed);
        let logs = request_all(client, blocks, parts).await?;
        logger.log(
            Level::TRACE,
            "The RPC provider couldn't answer the contracts' addresses in one query, so the range was read with one query per contract.",
            &json!({
                "fromBlock": from_block,
                "toBlock": to_block,
                "requests": parts.len(),
                "reason": error.to_string(),
            }),
        );
        return Ok(logs);
    }
    let origin = match &selection.emitters {
        Emitters::Any(origin)
            if from_block == to_block
                && !origin.client_filtered_registrations.is_empty()
                && is_answer_too_large(&error) =>
        {
            origin
        }
        _ => return Err(error),
    };
    let SelectionByAddress {
        contract_names,
        address_free,
        by_address,
    } = by_address(origin).map_err(RpcError::Other)?;
    // The topic-only part first: when it is what's too large, no address
    // request is spent on a read that fails anyway.
    let mut logs = request_all(client, blocks, &address_free).await?;
    logs.extend(request_all(client, blocks, &by_address).await?);
    logger.log(
        Level::TRACE,
        "The RPC provider couldn't answer an address-free query, so its range was read again by the contracts' registered addresses.",
        &json!({
            "fromBlock": from_block,
            "toBlock": to_block,
            "contractNames": contract_names,
            "requests": address_free.len() + by_address.len(),
            "reason": error.to_string(),
        }),
    );
    Ok(logs)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn listed(addresses: &[&str], topics: &[&[&str]]) -> BuiltLogSelection {
        BuiltLogSelection {
            emitters: Emitters::Listed(addresses.iter().map(|a| a.to_string()).collect()),
            topics: topics
                .iter()
                .map(|values| values.iter().map(|v| v.to_string()).collect())
                .collect(),
        }
    }

    #[test]
    fn groups_by_address_selections_on_topic0_alone_and_keeps_the_rest() {
        let token = listed(&["0x01"], &[&["0xaa"], &[], &[], &[]]);
        let pool = listed(&["0x02", "0x01"], &[&["0xbb"], &[], &[], &[]]);
        let filtered = listed(&["0x03"], &[&["0xcc"], &["0xdd"], &[], &[]]);
        let (selections, parts) = pack_by_address(
            vec![token.clone(), filtered.clone(), pool.clone()],
            true,
            10,
        );
        assert_eq!(
            (selections, parts),
            (
                vec![filtered, listed(&["0x01", "0x02"], &[&["0xaa", "0xbb"]]),],
                vec![vec![], vec![token, pool]],
            )
        );
    }

    #[test]
    fn asks_for_at_most_the_address_cap_in_one_request() {
        let token = listed(&["0x01", "0x02", "0x03"], &[&["0xaa"], &[], &[], &[]]);
        let pool = listed(&["0x04"], &[&["0xbb"], &[], &[], &[]]);
        let filtered = listed(&["0x05", "0x06", "0x07"], &[&["0xcc"], &["0xdd"], &[], &[]]);
        let (selections, parts) =
            pack_by_address(vec![token.clone(), filtered.clone(), pool.clone()], true, 2);
        let token_head = listed(&["0x01", "0x02"], &[&["0xaa"], &[], &[], &[]]);
        let token_tail = listed(&["0x03"], &[&["0xaa"], &[], &[], &[]]);
        assert_eq!(
            (selections, parts),
            (
                vec![
                    listed(&["0x05", "0x06"], &[&["0xcc"], &["0xdd"], &[], &[]]),
                    listed(&["0x07"], &[&["0xcc"], &["0xdd"], &[], &[]]),
                    token_head,
                    listed(&["0x03", "0x04"], &[&["0xaa", "0xbb"]]),
                ],
                vec![vec![], vec![], vec![], vec![token_tail, pool]],
            )
        );
    }

    #[test]
    fn filter_trims_trailing_match_any_topics_and_omits_absent_addresses() {
        let topics = vec![vec!["0xaa".to_string()], vec![], vec![], vec![]];
        assert_eq!(
            (
                log_filter(
                    LogBlocks::Range {
                        from_block: 16,
                        to_block: 17
                    },
                    &topics,
                    &[]
                ),
                log_filter(
                    LogBlocks::Range {
                        from_block: 16,
                        to_block: 16
                    },
                    &topics,
                    &["0x01".to_string()]
                ),
                log_filter(
                    LogBlocks::Hash {
                        block_number: 16,
                        hash: "0xbb"
                    },
                    &topics,
                    &["0x01".to_string()]
                ),
            ),
            (
                json!({"fromBlock": "0x10", "toBlock": "0x11", "topics": [["0xaa"]]}),
                json!({
                    "fromBlock": "0x10",
                    "toBlock": "0x10",
                    "topics": [["0xaa"]],
                    "address": ["0x01"],
                }),
                json!({
                    "blockHash": "0xbb",
                    "topics": [["0xaa"]],
                    "address": ["0x01"],
                }),
            )
        );
    }

    #[test]
    fn only_answers_too_large_to_get_call_for_addresses() {
        let errors = [
            RpcError::JsonRpc {
                code: -32005,
                message: "query returned more than 10000 results".to_string(),
            },
            RpcError::RateLimited {
                code: Some(-32005),
                message: "project ID request rate exceeded".to_string(),
                retry_after_millis: None,
            },
            RpcError::Timeout(anyhow::anyhow!("eth_getLogs took longer than 20000ms")),
            RpcError::MalformedResponse(anyhow::anyhow!("parse eth_getLogs result")),
            RpcError::Other(anyhow::anyhow!("send eth_getLogs request")),
        ];
        assert_eq!(
            errors.each_ref().map(is_answer_too_large),
            [true, false, true, true, false]
        );
    }
}
