pub mod converters;

use std::env;

use crate::{
    cli_args::interactive_init::validation::filter_duplicate_events,
    config_parsing::chain_helpers::NetworkWithExplorer,
    evm::{abi::AbiOrNestedAbi, address::Address},
};
use alloy_json_abi::JsonAbi;
use anyhow::{anyhow, Context};
use async_recursion::async_recursion;
use serde::Deserialize;
use tokio::time::Duration;

pub struct ContractData {
    pub abi: JsonAbi,
    pub name: Option<String>,
}

pub enum ContractImportResult {
    Contract(ContractData),
    NotVerified,
    UnsupportedChain,
}

#[derive(Deserialize, Debug)]
#[serde(untagged)]
enum ContractImportResponse {
    Contract {
        // Currently it always returns a name, but handle None for future,
        // when we start supporting explorers which only have an API to get the contract ABI
        #[serde(rename = "contractName")]
        name: Option<String>,
        abi: String,
    },
    Error {
        tag: Option<String>,
    },
}

const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

pub async fn contract_import(
    network: &NetworkWithExplorer,
    address: &Address,
    retry: u64,
) -> anyhow::Result<ContractImportResult> {
    contract_import_with_timeout(network, address, retry, REQUEST_TIMEOUT).await
}

#[async_recursion]
async fn contract_import_with_timeout(
    network: &NetworkWithExplorer,
    address: &Address,
    retry: u64,
    timeout: Duration,
) -> anyhow::Result<ContractImportResult> {
    let api_url = env::var("ENVIO_API_URL").unwrap_or("https://envio.dev/api".to_string());
    // Without a timeout an API that holds the socket open never returns, and the
    // retry below never sees the error that would let it try again.
    let client = reqwest::Client::builder()
        .timeout(timeout)
        .build()
        .context("Failed building the contract import HTTP client")?;
    let response: reqwest::Response = match client
        .get(format!(
            "{api_url}/hyperindex/contract-import?chain={}&address={}",
            *network as u64,
            address.to_checksum_hex_string()
        ))
        .send()
        .await
    {
        Ok(response) => response,
        Err(err) => {
            // Just a few retries in case of a bad internet connection
            if retry > 2 {
                return Err(anyhow!("Failed to fetch contract import. {}", err));
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
            return contract_import_with_timeout(network, address, retry + 1, timeout).await;
        }
    };

    let contract_import_response: ContractImportResponse = response
        .json::<ContractImportResponse>()
        .await
        .context("Failed to parse Contract Import response")?;

    match contract_import_response {
        ContractImportResponse::Contract { name, abi } => {
            let mut abi = match crate::evm::abi::parse(None, &abi)
                .context("Failed to read the ABI the block explorer returned")?
            {
                AbiOrNestedAbi::Abi(abi) => abi,
                AbiOrNestedAbi::NestedAbi { abi } => abi,
            };

            abi.events = filter_duplicate_events(abi.events);

            Ok(ContractImportResult::Contract(ContractData { name, abi }))
        }
        ContractImportResponse::Error { tag } => {
            if tag == Some("NotVerified".to_string()) {
                Ok(ContractImportResult::NotVerified)
            } else if tag == Some("UnsupportedChain".to_string()) {
                Ok(ContractImportResult::UnsupportedChain)
            } else {
                Err(anyhow!("Failed to fetch contract import. Unknown error"))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config_parsing::chain_helpers::NetworkWithExplorer;
    use crate::mock_http;
    use tokio::net::TcpListener;

    /// `ENVIO_API_URL` is process-wide, so the tests that point it at their own
    /// server take turns.
    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    async fn listener() -> (TcpListener, String) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        (listener, format!("http://{addr}"))
    }

    fn address() -> Address {
        Address::new("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48").unwrap()
    }

    /// A stalled API used to hang `envio init` indefinitely: the default client
    /// carries no timeout, so the retry never saw an error to act on.
    #[tokio::test]
    async fn stalled_api_fails_instead_of_hanging() {
        let (listener, url) = listener().await;
        // Accept and then never answer, holding the socket open.
        tokio::spawn(async move {
            let mut accepted = Vec::new();
            while let Ok((stream, _)) = listener.accept().await {
                accepted.push(stream);
            }
        });

        let result = {
            let _guard = ENV_LOCK.lock().unwrap();
            env::set_var("ENVIO_API_URL", url);
            // `retry` past the limit, so this measures one request rather than
            // the backoff between attempts.
            tokio::time::timeout(
                Duration::from_secs(5),
                contract_import_with_timeout(
                    &NetworkWithExplorer::EthereumMainnet,
                    &address(),
                    3,
                    Duration::from_millis(200),
                ),
            )
            .await
        };

        assert!(
            matches!(result, Ok(Err(_))),
            "expected the request to give up on its own, but it hung"
        );
    }

    #[tokio::test]
    async fn answered_request_returns_the_contract() {
        let (listener, url) = listener().await;
        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut buffered = Vec::new();
            mock_http::read_request(&mut stream, &mut buffered)
                .await
                .unwrap();
            let body = serde_json::json!({
                "contractName": "USDC",
                "abi": r#"[{"type":"event","name":"Transfer","inputs":[]}]"#,
            })
            .to_string();
            mock_http::write_response(
                &mut stream,
                200,
                &[("Content-Type", "application/json")],
                body.as_bytes(),
            )
            .await
            .unwrap();
        });

        let result = {
            let _guard = ENV_LOCK.lock().unwrap();
            env::set_var("ENVIO_API_URL", url);
            contract_import_with_timeout(
                &NetworkWithExplorer::EthereumMainnet,
                &address(),
                0,
                REQUEST_TIMEOUT,
            )
            .await
        };

        let contract = match result.unwrap() {
            ContractImportResult::Contract(contract) => contract,
            _ => panic!("expected a decoded contract"),
        };
        assert_eq!(
            (
                contract.name,
                contract
                    .abi
                    .events
                    .keys()
                    .map(String::as_str)
                    .collect::<Vec<_>>(),
            ),
            (Some("USDC".to_string()), vec!["Transfer"])
        );
    }
}
