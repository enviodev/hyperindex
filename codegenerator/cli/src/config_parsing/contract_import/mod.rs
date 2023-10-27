use anyhow::{anyhow, Context};
use async_recursion::async_recursion;
use ethers::etherscan::contract::ContractMetadata;
use ethers::{etherscan, types::H160};
use std::fs;
use std::path::PathBuf;
use tokio::time::Duration;

use crate::{
    cli_args::Language,
    config_parsing::{
        chain_helpers::{self, NetworkWithExplorer},
        constants, RequiredEntity,
    },
    config_parsing::{
        Config, ConfigContract, ConfigEvent, EventNameOrSig, Network, NormalizedList,
    },
};

// Function to generate config, schema and abis from subgraph ID
pub async fn generate_config_from_contract_address(
    name: &str,
    network: &NetworkWithExplorer,
    contract_address: String,
    language: &Language,
) -> anyhow::Result<Config> {
    let contract_address_h160 = contract_address
        .parse()
        .context("parsing address to h160")?;
    let contract_data = get_contract_data_from_contract(network, &contract_address_h160)
        .await
        .context("fetching implementation abi")?;

    let events: Vec<ConfigEvent> = contract_data
        .abi
        .events()
        .map(|event| ConfigEvent {
            event: EventNameOrSig::Event(event.clone()),
            required_entities: Some(vec![RequiredEntity {
                //Required entity needed for autogen schema
                name: "EventsSummary".to_string(),
                labels: None,
                array_labels: None,
            }]),
        })
        .collect();

    // Create contract object to be populated
    let contract = ConfigContract {
        name: contract_data.name.to_string(),
        abi_file_path: None,
        address: NormalizedList::from_single(contract_address),
        handler: get_event_handler_directory(language),
        events,
    };

    // Create network object to be populated
    let network = Network {
        id: *network as u64,
        sync_source: None,
        start_block: 0,
        contracts: vec![contract],
    };

    // Create config object to be populated
    let config = Config {
        name: contract_data.name.clone(),
        description: name.to_string(),
        schema: None,
        networks: vec![network],
    };

    Ok(config)
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

async fn fetch_get_source_code_result_from_block_explorer(
    client: &etherscan::Client,
    address: &H160,
) -> anyhow::Result<etherscan::contract::Metadata> {
    //todo make retryable
    let mut refetch_delay = Duration::from_secs(2);

    let fail_if_maximum_is_exceeded = |current_refetch_delay| -> anyhow::Result<()> {
        if current_refetch_delay >= constants::MAXIMUM_BACKOFF {
            Err(anyhow!("Maximum backoff timeout exceeded"))
        } else {
            Ok(())
        }
    };

    let contract_metadata: ContractMetadata = loop {
        match client.contract_source_code(address.clone()).await {
            Ok(res) => {
                break Ok::<_, anyhow::Error>(res);
            }
            Err(_e) => {
                fail_if_maximum_is_exceeded(refetch_delay)?;
                tokio::time::sleep(refetch_delay).await;
                refetch_delay *= 2;
            }
        }
    }
    .context("fetching contract source code")?;

    if contract_metadata.items.len() > 1 {
        return Err(anyhow!("Unexpected multiple metadata items in contract"));
    }

    contract_metadata
        .items
        .get(0)
        .cloned()
        .ok_or_else(|| anyhow!("No items returned with contract metadata"))
}

// Logic to get the event handler directory based on the language
fn get_event_handler_directory(language: &Language) -> String {
    match language {
        Language::Rescript => "./src/EventHandlers.bs.js".to_string(),
        Language::Typescript => "src/EventHandlers.ts".to_string(),
        Language::Javascript => "./src/EventHandlers.js".to_string(),
    }
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
        let name = "LongShort";
        let contract_address = "0x168a5d1217AEcd258b03018d5bF1A1677A07b733".to_string();
        let network: NetworkWithExplorer = NetworkWithExplorer::Polygon;
        let language: Language = Language::Typescript;
        super::generate_config_from_contract_address(name, &network, contract_address, &language)
            .await
            .unwrap();
    }
}
