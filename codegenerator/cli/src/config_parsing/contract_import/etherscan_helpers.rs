use super::converters::{
    AutoConfigSelection, ContractImportNetworkSelection, ContractImportSelection,
};
use crate::{
    cli_args::Language,
    config_parsing::{
        chain_helpers::{self, NetworkWithExplorer},
        human_config::HumanConfig,
    },
    utils::address_type::Address,
};
use anyhow::{anyhow, Context, Result};
use async_recursion::async_recursion;
use ethers::{
    etherscan::{self, contract::ContractMetadata},
    prelude::errors::EtherscanError,
    types::H160,
};
use std::{fs, path::PathBuf};
use tokio::time::Duration;

pub async fn fetch_contract_auto_selection_from_etherscan(
    contract_address: Address,
    network: &NetworkWithExplorer,
) -> Result<ContractImportSelection> {
    let contract_data = get_contract_data_from_contract(network, contract_address.as_h160())
        .await
        .context(format!(
            "Failed fetching implementation abi of contract {} on network {}",
            contract_address, network
        ))?;

    let events = contract_data.abi.events().cloned().collect();

    let network_selection = ContractImportNetworkSelection::new(*network as u64, contract_address);

    Ok(ContractImportSelection::new(
        contract_data.name,
        network_selection,
        events,
    ))
}

// Function to generate config, schema and abis from subgraph ID
pub async fn generate_config_from_contract_address(
    project_name: String,
    network: &NetworkWithExplorer,
    contract_address: Address,
    language: Language,
) -> anyhow::Result<HumanConfig> {
    let selected_contract = fetch_contract_auto_selection_from_etherscan(contract_address, network)
        .await
        .context("Failed fetching contract data")?;

    let auto_config_selection: AutoConfigSelection =
        AutoConfigSelection::new(project_name, language, selected_contract);

    let human_config = HumanConfig::try_from(auto_config_selection)
        .context("Failed converting contract data to config.yaml")?;

    Ok(human_config)
}

pub async fn write_file_to_system(
    file_string: String,
    fs_file_path: PathBuf,
) -> anyhow::Result<()> {
    let file_path_str = fs_file_path.to_str().unwrap_or_else(|| "unknown file path");
    // Create the directory if it doesn't exist
    if let Some(parent_dir) = fs_file_path.parent() {
        fs::create_dir_all(parent_dir)
            .with_context(|| format!("Failed to create directory for {} file", file_path_str))?;
    }
    fs::write(&fs_file_path, file_string)
        .with_context(|| format!("Failed to write {} file", file_path_str))?;

    Ok(())
}

struct ContractData {
    abi: ethers::abi::Abi,
    name: String,
}

#[async_recursion]
async fn get_contract_data_from_contract(
    network: &NetworkWithExplorer,
    address: &H160,
) -> anyhow::Result<ContractData> {
    let client = chain_helpers::get_etherscan_client(network)
        .context("Making client for getting source code")?;

    let contract_metadata =
        fetch_get_source_code_result_from_block_explorer(&client, address).await?;

    match contract_metadata {
        // if implementation contract, return abi from fetch_get_source_code_result_from_block_explorer
        etherscan::contract::Metadata {
            proxy: 1,
            implementation: Some(implementation_address),
            ..
        } => get_contract_data_from_contract(network, &implementation_address).await,
        // if proxy contract, call fetch_get_source_code_result_from_block_explorer recursively on implementation contract address
        _ => {
            let abi = contract_metadata.abi()?;

            Ok(ContractData {
                abi,
                name: contract_metadata.contract_name,
            })
        }
    }
}

// maximum backoff period for fetching result from explorer
const MAXIMUM_BACKOFF: Duration = Duration::from_secs(32);

async fn fetch_get_source_code_result_from_block_explorer(
    client: &etherscan::Client,
    address: &H160,
) -> anyhow::Result<etherscan::contract::Metadata> {
    //todo make retryable
    let mut refetch_delay = Duration::from_secs(2);

    let fail_if_maximum_is_exceeded = |current_refetch_delay: Duration, e| -> anyhow::Result<()> {
        if current_refetch_delay >= MAXIMUM_BACKOFF {
            Err(e).context(format!(
                "Maximum backoff timeout {}s exceeded",
                MAXIMUM_BACKOFF.as_secs()
            ))
        } else {
            println!(
                "Retrying in {}s due to failure: {}",
                current_refetch_delay.as_secs(),
                e
            );
            Ok(())
        }
    };

    let contract_metadata: ContractMetadata = loop {
        match client.contract_source_code(address.clone()).await {
            Ok(res) => {
                break Ok::<_, anyhow::Error>(res);
            }
            Err(e) => {
                let retry_err = match e {
                    //In these cases, return ok(err) if it should be retried
                    EtherscanError::Reqwest(_)
                    | EtherscanError::BadStatusCode(_)
                    | EtherscanError::RateLimitExceeded
                    | EtherscanError::IO(_)
                    | EtherscanError::ErrorResponse { .. } => Ok(e),

                    //In these cases exit with error
                    EtherscanError::ChainNotSupported(_)
                    | EtherscanError::ExecutionFailed(_)
                    | EtherscanError::BalanceFailed
                    | EtherscanError::BlockNumberByTimestampFailed
                    | EtherscanError::TransactionReceiptFailed
                    | EtherscanError::GasEstimationFailed
                    | EtherscanError::EnvVarNotFound(_)
                    | EtherscanError::Serde(_)
                    | EtherscanError::ContractCodeNotVerified(_)
                    | EtherscanError::EmptyResult { .. }
                    | EtherscanError::LocalNetworksNotSupported
                    | EtherscanError::Unknown(_)
                    | EtherscanError::Builder(_)
                    | EtherscanError::MissingSolcVersion(_)
                    | EtherscanError::InvalidApiKey
                    | EtherscanError::BlockedByCloudflare
                    | EtherscanError::CloudFlareSecurityChallenge
                    | EtherscanError::PageNotFound => Err(e),
                }?;
                fail_if_maximum_is_exceeded(refetch_delay, retry_err)?;
                tokio::time::sleep(refetch_delay).await;
                refetch_delay *= 2;
            }
        }
    }
    .context("Fetching contract source code")?;

    if contract_metadata.items.len() > 1 {
        return Err(anyhow!("Unexpected multiple metadata items in contract"));
    }

    contract_metadata
        .items
        .get(0)
        .cloned()
        .ok_or_else(|| anyhow!("No items returned with contract metadata"))
}

#[cfg(test)]
mod test {
    use crate::cli_args::Language;
    use crate::config_parsing::chain_helpers::NetworkWithExplorer;

    // Integration test to see that a config file can be generated from a contract address
    #[tokio::test]
    #[ignore = "Integration test that interacts with block explorer API"]
    async fn test_generate_config_from_contract_address() {
        // contract address of deprecated LongShort contract on Polygon
        let name = "LongShort".to_string();
        let contract_address = "0x168a5d1217AEcd258b03018d5bF1A1677A07b733"
            .parse()
            .unwrap();
        let network: NetworkWithExplorer = NetworkWithExplorer::Polygon;
        let language: Language = Language::Typescript;
        super::generate_config_from_contract_address(name, &network, contract_address, language)
            .await
            .unwrap();
    }
}
