//! Reads the raw logs one log selection matches over a block range. Routing
//! them to registrations is the caller's next step: everything here stays in
//! the provider's own terms, `blockHash` included.

use napi_derive::napi;
use serde_json::{json, Value};

use super::classify::is_result_cap_message;
use super::client::{JsonRpcClient, RpcError};
use super::RawLog;
use crate::evm_hypersync_source::selection::{
    AddressFreeOrigin, BuiltLogSelection, Emitters, SelectionByAddress,
};

/// An address-free request the provider couldn't answer, read again by the
/// addresses of the client-filtered contracts in it.
#[napi(object, object_from_js = false)]
pub struct AddressFallback {
    pub contract_names: Vec<String>,
    /// The `eth_getLogs` requests the range took instead: the topic-only part
    /// still address-free, and one per chunk of addresses.
    pub requests: i64,
    /// What the provider said about the address-free request.
    pub reason: String,
}

pub(super) struct SelectionLogs {
    pub logs: Vec<RawLog>,
    pub fallback: Option<AddressFallback>,
}

/// The `eth_getLogs` filter for a range: `null` matches any value at a topic
/// position, trailing match-any positions are trimmed, and no addresses means
/// any emitter.
fn log_filter(
    from_block: u64,
    to_block: u64,
    topics: &[Vec<String>],
    addresses: &[String],
) -> Value {
    let mut topics: Vec<Option<&Vec<String>>> = topics
        .iter()
        .map(|values| (!values.is_empty()).then_some(values))
        .collect();
    while matches!(topics.last(), Some(None)) {
        topics.pop();
    }
    let mut filter = json!({
        "fromBlock": format!("0x{from_block:x}"),
        "toBlock": format!("0x{to_block:x}"),
        "topics": topics,
    });
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
    from_block: u64,
    to_block: u64,
    selections: &[BuiltLogSelection],
) -> Result<Vec<RawLog>, RpcError> {
    let results = futures_util::future::join_all(
        selections
            .iter()
            .map(|selection| request(client, from_block, to_block, selection)),
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
    from_block: u64,
    to_block: u64,
    selection: &BuiltLogSelection,
) -> Result<Vec<RawLog>, RpcError> {
    client
        .request(
            "eth_getLogs",
            json!([log_filter(
                from_block,
                to_block,
                &selection.topics,
                selection.addresses()
            )]),
        )
        .await
}

/// Reads `selection` over the range. When a one-block range of an address-free
/// selection holding client-filtered registrations is too large for the
/// provider, it is read again the way `by_address` rebuilds it. A wider range
/// goes back to the caller, whose retry shrinks it first. Nothing is
/// remembered: the next range is asked address-free again.
pub(super) async fn request_selection_logs(
    client: &JsonRpcClient,
    from_block: u64,
    to_block: u64,
    selection: &BuiltLogSelection,
    by_address: impl FnOnce(&AddressFreeOrigin) -> anyhow::Result<SelectionByAddress>,
) -> Result<SelectionLogs, RpcError> {
    let error = match request(client, from_block, to_block, selection).await {
        Ok(logs) => {
            return Ok(SelectionLogs {
                logs,
                fallback: None,
            })
        }
        Err(error) => error,
    };
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
    let mut logs = request_all(client, from_block, to_block, &address_free).await?;
    logs.extend(request_all(client, from_block, to_block, &by_address).await?);
    Ok(SelectionLogs {
        logs,
        fallback: Some(AddressFallback {
            contract_names,
            requests: (address_free.len() + by_address.len()) as i64,
            reason: error.to_string(),
        }),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filter_trims_trailing_match_any_topics_and_omits_absent_addresses() {
        let topics = vec![vec!["0xaa".to_string()], vec![], vec![], vec![]];
        assert_eq!(
            (
                log_filter(16, 17, &topics, &[]),
                log_filter(16, 16, &topics, &["0x01".to_string()]),
            ),
            (
                json!({"fromBlock": "0x10", "toBlock": "0x11", "topics": [["0xaa"]]}),
                json!({
                    "fromBlock": "0x10",
                    "toBlock": "0x10",
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
