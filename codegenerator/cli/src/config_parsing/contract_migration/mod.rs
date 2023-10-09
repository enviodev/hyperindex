use anyhow::{anyhow, Context};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use tokio::time::{timeout, Duration};

use crate::{
    cli_args::Language,
    config_parsing::validation::is_valid_ethereum_address,
    config_parsing::{
        chain_helpers::{self, NetworkName, NetworkWithExplorer},
        constants,
    },
    config_parsing::{
        Config, ConfigContract, ConfigEvent, EventNameOrSig, Network, NormalizedList,
    },
};

use super::chain_helpers::BlockExplorerApi;

// generic API response structure - keeping for possible future use.
#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct ResponseTypeV1<T> {
    status: String,
    message: String,
    result: Vec<T>,
}

pub type GetSourceCodeResponseType = ResponseTypeV1<GetSourceCodeResult>;

#[allow(non_snake_case)]
#[derive(Clone, Serialize, Deserialize, Debug, PartialEq)]
pub struct GetSourceCodeResult {
    SourceCode: String,
    ABI: String,
    ContractName: String,
    CompilerVersion: String,
    OptimizationUsed: String,
    Runs: String,
    ConstructorArguments: String,
    EVMVersion: String,
    Library: String,
    LicenseType: String,
    Proxy: String,
    Implementation: String,
    SwarmSource: String,
}

#[allow(non_snake_case)]
#[allow(dead_code)]
#[derive(Debug, Deserialize)]
struct Input {
    internalType: String,
    name: String,
    #[serde(rename = "type")]
    input_type: String,
}

#[derive(Debug, Deserialize)]
struct Item {
    inputs: Vec<Input>,
    name: Option<String>,
    #[serde(rename = "type")]
    item_type: String,
}

// Function to generate config, schema and abis from subgraph ID
pub async fn generate_config_from_contract_address(
    name: &str,
    project_root_path: &PathBuf,
    network: &NetworkWithExplorer,
    contract_address: &str,
    language: &Language,
) -> anyhow::Result<()> {
    // Validate that the contract address is in the correct format.
    if !is_valid_ethereum_address(contract_address) {
        return Err(anyhow!(
            "Address {} is not a valid address. Please provide a valid address for contract import.",
            contract_address
        ));
    }

    // Initialize variables
    #[allow(unused_assignments)]
    let mut implementation_contract_name = String::from("UNASSIGNED");
    #[allow(unused_assignments)]
    let mut abi_string = String::from("UNASSIGNED");

    // GetSourceCodeResult from API call
    let get_source_code_result =
        fetch_get_source_code_result_from_block_explorer(network, contract_address).await?;

    if get_source_code_result.Proxy == "1" {
        let implementation_contract_address = get_source_code_result.Implementation.clone();
        // GetSourceCodeResult from API call for the implementation contract
        let implementation_get_source_code_result =
            fetch_get_source_code_result_from_block_explorer(
                network,
                &implementation_contract_address,
            )
            .await?;

        implementation_contract_name = implementation_get_source_code_result.ContractName.clone();
        abi_string = implementation_get_source_code_result.ABI.clone();
    } else {
        // Assumption here is that we don't currently support contracts that are not proxies for contract import.
        return Err(anyhow!(
            "Address {} is an implementation address. Please provide a proxy contract address for contract import.",
            contract_address
        ));
    }

    // Create config object to be populated
    let mut config = Config {
        name: implementation_contract_name.clone(),
        description: name.to_string(),
        schema: None,
        networks: vec![],
    };

    // Create network object to be populated
    let mut network = Network {
        id: chain_helpers::get_network_id_given_network_name(NetworkName::from(network.clone())),
        sync_source: None,
        start_block: 0,
        contracts: vec![],
    };

    // Create contract object to be populated
    let mut contract = ConfigContract {
        name: implementation_contract_name.to_string(),
        abi_file_path: None,
        address: NormalizedList::from_single(contract_address.to_string()),
        handler: get_event_handler_directory(language),
        events: vec![],
    };

    // Deserialize the ABI string into a vector of Items
    let abi_item: Vec<Item> = serde_json::from_str(&abi_string).with_context(|| {
        format!(
            "Failed to deserialize ABI string for contract {}",
            implementation_contract_name
        )
    })?;

    // Iterate through the ABI items to find events
    for item in abi_item.iter() {
        if item.item_type == "event" {
            if let Some(name) = &item.name {
                let mut event_signature = format!("{}(", name);
                // Generating human readable ABI
                for input in item.inputs.iter() {
                    event_signature.push_str(&format!("{} {}, ", input.input_type, input.name));
                }
                // Remove the last comma only if there were any inputs
                if !item.inputs.is_empty() {
                    event_signature.truncate(event_signature.len() - 2);
                }
                // Close the bracket
                event_signature.push_str(")");

                let event = ConfigEvent {
                    event: EventNameOrSig::Name(event_signature.to_string()),
                    required_entities: Some(vec![]),
                };

                // Pushing event to contract
                contract.events.push(event);
            }
        }
    }

    // Pushing contract to network
    network.contracts.push(contract.clone());

    // Pushing network to config
    config.networks.push(network);

    // Convert config to YAML file
    let config_yaml_string = serde_yaml::to_string(&config)?;

    // Write config YAML string to a file
    write_file_to_system(
        config_yaml_string,
        project_root_path.join("config.yaml"),
        "config.yaml",
    )
    .await?;

    Ok(())
}

async fn write_file_to_system(
    file_string: String,
    fs_file_path: PathBuf,
    context_name: &str,
) -> anyhow::Result<()> {
    // Create the directory if it doesn't exist
    if let Some(parent_dir) = fs_file_path.parent() {
        fs::create_dir_all(parent_dir)
            .with_context(|| format!("Failed to create directory for {} file", context_name))?;
    }
    fs::write(&fs_file_path, file_string)
        .with_context(|| format!("Failed to write {} file", context_name))?;

    Ok(())
}

async fn fetch_from_block_explorer_with_retry(url: &str) -> anyhow::Result<String> {
    let mut refetch_delay = Duration::from_secs(2);

    let fail_if_maximum_is_exceeded = |current_refetch_delay, _err: &str| -> anyhow::Result<()> {
        if current_refetch_delay >= constants::MAXIMUM_BACKOFF {
            eprintln!(
                "Failed to fetch a response for the following API request {}",
                url
            );
            return Err(anyhow!("Maximum backoff timeout exceeded"));
        }
        Ok(())
    };
    loop {
        match timeout(refetch_delay, fetch_from_block_explorer(url)).await {
            Ok(Ok(response)) => break Ok(response),
            Ok(Err(err)) => {
                fail_if_maximum_is_exceeded(refetch_delay, &err.to_string())?;
                eprintln!(
                    "Failed to fetch a response for the following API request {}: {}. Retrying in {} seconds...",
                    url,
                    &err,
                    refetch_delay.as_secs()
                );
            }
            Err(err) => {
                fail_if_maximum_is_exceeded(refetch_delay, &err.to_string())?;
                eprintln!(
                    "Fetching a response for the following API request {} timed out. Retrying in {} seconds...",
                    url,
                    refetch_delay.as_secs()
                );
            }
        }
        tokio::time::sleep(refetch_delay).await;
        refetch_delay *= 2;
    }
}

async fn fetch_from_block_explorer(url: &str) -> anyhow::Result<String> {
    let client = reqwest::Client::builder()
        .user_agent("MyApp/1.0")
        .build()
        .expect("Failed to build client");

    let response = client.get(url).send().await?;

    if response.status().is_success() {
        let content_raw = response.text().await?;
        Ok(content_raw)
    } else {
        Err(anyhow::anyhow!(
            "Received non-success status code: {}",
            response.status()
        ))
    }
}

async fn fetch_get_source_code_result_from_block_explorer(
    network: &NetworkWithExplorer,
    address: &str,
) -> anyhow::Result<GetSourceCodeResult> {
    let BlockExplorerApi { base_url, api_key } = chain_helpers::get_block_explorer_api(network);

    let url = format!(
        "https://{}/api?module=contract&action=getsourcecode&address={}&apikey={}",
        base_url, address, api_key
    );

    let content_raw = fetch_from_block_explorer_with_retry(&url).await?;
    // Deserializing the JSON response into the correct response type
    let get_source_code_response: GetSourceCodeResponseType = serde_json::from_str(&content_raw)?;

    let get_source_code_result = get_source_code_response.result.get(0).ok_or_else(|| anyhow!("No first index of source code respones"))?.clone();

    Ok(get_source_code_result)
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

    use super::GetSourceCodeResponseType;
    use super::GetSourceCodeResult;

    use super::Item;

    // Integration test to see that a config file can be generated from a contract address
    #[tokio::test]
    #[ignore = "Integration test that interacts with block explorer API"]
    async fn generate_config_from_contract_address() {
        // contract address of deprecated LongShort contract on Polygon
        let name = "LongShort";
        let contract_address: &str = "0x168a5d1217AEcd258b03018d5bF1A1677A07b733";
        let network: NetworkWithExplorer = NetworkWithExplorer::Matic;
        let language: Language = Language::Typescript;
        let project_root_path: std::path::PathBuf = std::path::PathBuf::from("./");
        super::generate_config_from_contract_address(
            name,
            &project_root_path,
            &network,
            contract_address,
            &language,
        )
        .await
        .unwrap();
    }

    #[test]
    fn test_deserialize_get_source_code_response_type() {
        // json object needs to read GetSourceCodeResponse.json from codegenerator/cli/test/json/GetSourceCodeResponse.json
        let json = std::fs::read_to_string("test/api_response/GetSourceCodeResponse.json").unwrap();

        let actual_response_type =
            serde_json::from_str::<GetSourceCodeResponseType>(&json).unwrap();

        let expected_type = GetSourceCodeResponseType {
            status: "1".to_string(),
            message: "OK".to_string(),
            result: vec![
                GetSourceCodeResult {
                    SourceCode: "pragma solidity 0.6.6".to_string(),
                    ABI: "[{\"inputs\":[{\"internalType\":\"address\",\"name\":\"_aggregator\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"_accessController\",\"type\":\"address\"}],\"stateMutability\":\"nonpayable\",\"type\":\"constructor\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"int256\",\"name\":\"current\",\"type\":\"int256\"},{\"indexed\":true,\"internalType\":\"uint256\",\"name\":\"roundId\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"updatedAt\",\"type\":\"uint256\"}],\"name\":\"AnswerUpdated\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"uint256\",\"name\":\"roundId\",\"type\":\"uint256\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"startedBy\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"startedAt\",\"type\":\"uint256\"}],\"name\":\"NewRound\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"from\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"to\",\"type\":\"address\"}],\"name\":\"OwnershipTransferRequested\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"from\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"to\",\"type\":\"address\"}],\"name\":\"OwnershipTransferred\",\"type\":\"event\"},{\"inputs\":[],\"name\":\"acceptOwnership\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"accessController\",\"outputs\":[{\"internalType\":\"contract AccessControllerInterface\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"aggregator\",\"outputs\":[{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"_aggregator\",\"type\":\"address\"}],\"name\":\"confirmAggregator\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"decimals\",\"outputs\":[{\"internalType\":\"uint8\",\"name\":\"\",\"type\":\"uint8\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"description\",\"outputs\":[{\"internalType\":\"string\",\"name\":\"\",\"type\":\"string\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"_roundId\",\"type\":\"uint256\"}],\"name\":\"getAnswer\",\"outputs\":[{\"internalType\":\"int256\",\"name\":\"\",\"type\":\"int256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint80\",\"name\":\"_roundId\",\"type\":\"uint80\"}],\"name\":\"getRoundData\",\"outputs\":[{\"internalType\":\"uint80\",\"name\":\"roundId\",\"type\":\"uint80\"},{\"internalType\":\"int256\",\"name\":\"answer\",\"type\":\"int256\"},{\"internalType\":\"uint256\",\"name\":\"startedAt\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"updatedAt\",\"type\":\"uint256\"},{\"internalType\":\"uint80\",\"name\":\"answeredInRound\",\"type\":\"uint80\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"_roundId\",\"type\":\"uint256\"}],\"name\":\"getTimestamp\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"latestAnswer\",\"outputs\":[{\"internalType\":\"int256\",\"name\":\"\",\"type\":\"int256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"latestRound\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"latestRoundData\",\"outputs\":[{\"internalType\":\"uint80\",\"name\":\"roundId\",\"type\":\"uint80\"},{\"internalType\":\"int256\",\"name\":\"answer\",\"type\":\"int256\"},{\"internalType\":\"uint256\",\"name\":\"startedAt\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"updatedAt\",\"type\":\"uint256\"},{\"internalType\":\"uint80\",\"name\":\"answeredInRound\",\"type\":\"uint80\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"latestTimestamp\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"owner\",\"outputs\":[{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint16\",\"name\":\"\",\"type\":\"uint16\"}],\"name\":\"phaseAggregators\",\"outputs\":[{\"internalType\":\"contract AggregatorV2V3Interface\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"phaseId\",\"outputs\":[{\"internalType\":\"uint16\",\"name\":\"\",\"type\":\"uint16\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"_aggregator\",\"type\":\"address\"}],\"name\":\"proposeAggregator\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"proposedAggregator\",\"outputs\":[{\"internalType\":\"contract AggregatorV2V3Interface\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint80\",\"name\":\"_roundId\",\"type\":\"uint80\"}],\"name\":\"proposedGetRoundData\",\"outputs\":[{\"internalType\":\"uint80\",\"name\":\"roundId\",\"type\":\"uint80\"},{\"internalType\":\"int256\",\"name\":\"answer\",\"type\":\"int256\"},{\"internalType\":\"uint256\",\"name\":\"startedAt\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"updatedAt\",\"type\":\"uint256\"},{\"internalType\":\"uint80\",\"name\":\"answeredInRound\",\"type\":\"uint80\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"proposedLatestRoundData\",\"outputs\":[{\"internalType\":\"uint80\",\"name\":\"roundId\",\"type\":\"uint80\"},{\"internalType\":\"int256\",\"name\":\"answer\",\"type\":\"int256\"},{\"internalType\":\"uint256\",\"name\":\"startedAt\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"updatedAt\",\"type\":\"uint256\"},{\"internalType\":\"uint80\",\"name\":\"answeredInRound\",\"type\":\"uint80\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"_accessController\",\"type\":\"address\"}],\"name\":\"setController\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"_to\",\"type\":\"address\"}],\"name\":\"transferOwnership\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"version\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"}]".to_string(),
                    ContractName: "EACAggregatorProxy".to_string(),
                    CompilerVersion: "v0.6.6+commit.6c089d02".to_string(),
                    OptimizationUsed: "1".to_string(),
                    Runs: "1000000".to_string(),
                    ConstructorArguments: "000000000000000000000000f0dd0dc63216f5603afc09c1bb04b6a78dcc682f0000000000000000000000000000000000000000000000000000000000000000".to_string(),
                    EVMVersion: "Default".to_string(),
                    Library: "".to_string(),
                    LicenseType: "MIT".to_string(),
                    Proxy: "0".to_string(),
                    Implementation: "".to_string(),
                    SwarmSource: "".to_string()
                }
            ],
        };
        assert_eq!(actual_response_type, expected_type);
    }

    // Unit test to see that a json string for ABI can be deserialized
    #[test]
    fn test_abi_string_deserializes() {
        let abi_string = "[{\"inputs\":[{\"internalType\":\"address\",\"name\":\"_aggregator\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"_accessController\",\"type\":\"address\"}],\"stateMutability\":\"nonpayable\",\"type\":\"constructor\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"int256\",\"name\":\"current\",\"type\":\"int256\"},{\"indexed\":true,\"internalType\":\"uint256\",\"name\":\"roundId\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"updatedAt\",\"type\":\"uint256\"}],\"name\":\"AnswerUpdated\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"uint256\",\"name\":\"roundId\",\"type\":\"uint256\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"startedBy\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"startedAt\",\"type\":\"uint256\"}],\"name\":\"NewRound\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"from\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"to\",\"type\":\"address\"}],\"name\":\"OwnershipTransferRequested\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"from\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"to\",\"type\":\"address\"}],\"name\":\"OwnershipTransferred\",\"type\":\"event\"},{\"inputs\":[],\"name\":\"acceptOwnership\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"accessController\",\"outputs\":[{\"internalType\":\"contract AccessControllerInterface\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"aggregator\",\"outputs\":[{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"_aggregator\",\"type\":\"address\"}],\"name\":\"confirmAggregator\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"decimals\",\"outputs\":[{\"internalType\":\"uint8\",\"name\":\"\",\"type\":\"uint8\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"description\",\"outputs\":[{\"internalType\":\"string\",\"name\":\"\",\"type\":\"string\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"_roundId\",\"type\":\"uint256\"}],\"name\":\"getAnswer\",\"outputs\":[{\"internalType\":\"int256\",\"name\":\"\",\"type\":\"int256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint80\",\"name\":\"_roundId\",\"type\":\"uint80\"}],\"name\":\"getRoundData\",\"outputs\":[{\"internalType\":\"uint80\",\"name\":\"roundId\",\"type\":\"uint80\"},{\"internalType\":\"int256\",\"name\":\"answer\",\"type\":\"int256\"},{\"internalType\":\"uint256\",\"name\":\"startedAt\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"updatedAt\",\"type\":\"uint256\"},{\"internalType\":\"uint80\",\"name\":\"answeredInRound\",\"type\":\"uint80\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"_roundId\",\"type\":\"uint256\"}],\"name\":\"getTimestamp\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"latestAnswer\",\"outputs\":[{\"internalType\":\"int256\",\"name\":\"\",\"type\":\"int256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"latestRound\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"latestRoundData\",\"outputs\":[{\"internalType\":\"uint80\",\"name\":\"roundId\",\"type\":\"uint80\"},{\"internalType\":\"int256\",\"name\":\"answer\",\"type\":\"int256\"},{\"internalType\":\"uint256\",\"name\":\"startedAt\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"updatedAt\",\"type\":\"uint256\"},{\"internalType\":\"uint80\",\"name\":\"answeredInRound\",\"type\":\"uint80\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"latestTimestamp\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"owner\",\"outputs\":[{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint16\",\"name\":\"\",\"type\":\"uint16\"}],\"name\":\"phaseAggregators\",\"outputs\":[{\"internalType\":\"contract AggregatorV2V3Interface\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"phaseId\",\"outputs\":[{\"internalType\":\"uint16\",\"name\":\"\",\"type\":\"uint16\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"_aggregator\",\"type\":\"address\"}],\"name\":\"proposeAggregator\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"proposedAggregator\",\"outputs\":[{\"internalType\":\"contract AggregatorV2V3Interface\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint80\",\"name\":\"_roundId\",\"type\":\"uint80\"}],\"name\":\"proposedGetRoundData\",\"outputs\":[{\"internalType\":\"uint80\",\"name\":\"roundId\",\"type\":\"uint80\"},{\"internalType\":\"int256\",\"name\":\"answer\",\"type\":\"int256\"},{\"internalType\":\"uint256\",\"name\":\"startedAt\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"updatedAt\",\"type\":\"uint256\"},{\"internalType\":\"uint80\",\"name\":\"answeredInRound\",\"type\":\"uint80\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"proposedLatestRoundData\",\"outputs\":[{\"internalType\":\"uint80\",\"name\":\"roundId\",\"type\":\"uint80\"},{\"internalType\":\"int256\",\"name\":\"answer\",\"type\":\"int256\"},{\"internalType\":\"uint256\",\"name\":\"startedAt\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"updatedAt\",\"type\":\"uint256\"},{\"internalType\":\"uint80\",\"name\":\"answeredInRound\",\"type\":\"uint80\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"_accessController\",\"type\":\"address\"}],\"name\":\"setController\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"_to\",\"type\":\"address\"}],\"name\":\"transferOwnership\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"version\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"}]".to_string();
        let _abi_json: Vec<Item> = serde_json::from_str(&abi_string).unwrap();
    }
}
