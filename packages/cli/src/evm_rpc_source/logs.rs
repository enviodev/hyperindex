//! Reads the raw logs one log selection matches over a block range, or in one
//! block named by its hash. Routing them to registrations is the caller's next
//! step: everything here stays in the provider's own terms, `blockHash`
//! included.

use serde_json::{json, Value};

use super::classify::is_result_cap_message;
use super::client::{JsonRpcClient, RpcError};
use super::RawLog;
use crate::evm_hypersync_source::selection::{
    AddressFreeOrigin, BuiltLogSelection, Emitters, SelectionByAddress,
};
use crate::logger::{BoundLogger, Level};

/// What a read is reported as when it asks a head block again, so the source's
/// request metrics count those apart from the range reads.
pub(super) const HEAD_BLOCK_RECHECK_STAT: &str = "eth_getLogs (head block recheck)";

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

    fn stat_method(&self) -> &'static str {
        match self {
            LogBlocks::Range { .. } => "eth_getLogs",
            LogBlocks::Hash { .. } | LogBlocks::RecheckByNumber { .. } => HEAD_BLOCK_RECHECK_STAT,
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
        RpcError::Other(_) => false,
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

/// Reads `selection` over `blocks`. When one block of an address-free
/// selection holding client-filtered registrations is too large for the
/// provider, it is read again the way `by_address` rebuilds it. A wider range
/// goes back to the caller, whose retry shrinks it first. Nothing is
/// remembered: the next range is asked address-free again.
pub(super) async fn request_selection_logs(
    client: &JsonRpcClient,
    logger: &BoundLogger,
    blocks: LogBlocks<'_>,
    selection: &BuiltLogSelection,
    by_address: impl FnOnce(&AddressFreeOrigin) -> anyhow::Result<SelectionByAddress>,
) -> Result<Vec<RawLog>, RpcError> {
    let error = match request(client, blocks, selection).await {
        Ok(logs) => return Ok(logs),
        Err(error) => error,
    };
    let (from_block, to_block) = blocks.bounds();
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
            RpcError::JsonRpc {
                code: -32005,
                message: "project ID request rate exceeded".to_string(),
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
