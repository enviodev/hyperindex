pub mod converters;

use crate::{
    cli_args::interactive_init::validation::filter_duplicate_events,
    config_parsing::chain_helpers::NetworkWithExplorer, evm::address::Address,
};
use anyhow::{anyhow, Context};
use async_recursion::async_recursion;
use serde::Deserialize;
use tokio::time::Duration;

pub struct ContractData {
    pub abi: ethers::abi::Abi,
    pub name: String,
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
        #[serde(rename = "contractName")]
        name: String,
        abi: String,
    },
    Error {
        tag: Option<String>,
    },
}

#[async_recursion]
pub async fn contract_import(
    network: &NetworkWithExplorer,
    address: &Address,
    retry: u64,
) -> anyhow::Result<ContractImportResult> {
    let response: reqwest::Response = match reqwest::get(format!(
        "http://localhost:3000/api/hyperindex/contract-import?chain={}&address={}",
        *network as u64,
        address.to_checksum_hex_string()
    ))
    .await
    {
        Ok(response) => response,
        Err(err) => {
            // Just a few retries in case of a bad internet connection
            if retry > 2 {
                return Err(anyhow!("Failed to fetch contract import. {}", err));
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
            return contract_import(network, address, retry + 1).await;
        }
    };

    let contract_import_response: ContractImportResponse = response
        .json()
        .await
        .context("Failed to parse Contract Import response")?;

    match contract_import_response {
        ContractImportResponse::Contract { name, abi } => {
            let mut abi: ethers::abi::Contract =
                serde_json::from_str(&abi).context("Failed parsing contract ABI")?;

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
