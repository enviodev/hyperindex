use anyhow::{anyhow, Context};
use serde::{Deserialize, Serialize};
use serde_yaml;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use tokio::task::JoinSet;
use tokio::time::{timeout, Duration};

use crate::project_paths::handler_paths::DEFAULT_SCHEMA_PATH;
use crate::{
    cli_args::Language,
    config_parsing::{
        Config, ConfigContract, ConfigEvent, EventNameOrSig, Network, NormalizedList,
    },
};

mod chain_helpers;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GraphManifest {
    pub spec_version: String,
    pub description: Option<String>,
    pub repository: Option<String>,
    pub schema: Schema,
    pub data_sources: Vec<DataSource>,
    pub templates: Option<Vec<Template>>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct FileID {
    #[serde(rename = "/")]
    pub value: String,
}

#[derive(Debug, Deserialize)]
pub struct Schema {
    pub file: FileID,
}

#[derive(Debug, Deserialize, Clone)]
pub struct DataSource {
    pub kind: String,
    pub name: String,
    pub network: String,
    pub source: Source,
    pub mapping: Mapping,
}
#[derive(Debug, Deserialize)]
pub struct Template {
    pub kind: String,
    pub name: String,
    pub network: String,
    pub source: TemplateSource,
    pub mapping: Mapping,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Source {
    pub address: String,
    pub abi: String,
    pub start_block: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TemplateSource {
    pub address: Option<String>,
    pub abi: Option<String>,
    pub start_block: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Mapping {
    pub kind: String,
    pub api_version: String,
    pub language: String,
    pub entities: Vec<String>,
    pub abis: Vec<Abi>,
    pub event_handlers: Vec<EventHandler>,
    pub call_handlers: Option<Vec<CallHandler>>,
    pub block_handlers: Option<Vec<BlockHandler>>,
    pub file: FileID,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Abi {
    pub name: String,
    pub file: FileID,
}

#[derive(Debug, Deserialize, Clone)]
pub struct EventHandler {
    pub event: String,
    pub handler: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct CallHandler {
    pub function: String,
    pub handler: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct BlockHandler {
    pub handler: String,
}

// Logic to get the event handler directory based on the language
fn get_event_handler_directory(language: &Language) -> String {
    match language {
        Language::Rescript => "./src/EventHandlers.bs.js".to_string(),
        Language::Typescript => "src/EventHandlers.ts".to_string(),
        Language::Javascript => "./src/EventHandlers.js".to_string(),
    }
}

// Function to replace unsupported field types from schema
fn update_schema_with_supported_field_types(schema_str: String) -> String {
    return schema_str.replace("BigDecimal", "Float");
}

// Function to fetch a file from IPFS
// TODO: use a pinning service of hitting the IPFS gateway which can be slow sometimes
async fn fetch_ipfs_file(cid: &str) -> Result<String, reqwest::Error> {
    let url = format!("https://ipfs.network.thegraph.com/api/v0/cat?arg={}", cid);
    let client = reqwest::Client::new();
    let response = client.get(&url).send().await?;
    let content_raw = response.text().await?;
    Ok(content_raw)
}

// Function to generate a hashmap of network name to contracts
// Unnecessary to use a hashmap for subgraphs, because there is only one network per subgraph
// But will be useful multiple subgraph IDs for same subgraph across different chains
async fn generate_network_contract_hashmap(manifest_raw: &str) -> HashMap<String, Vec<String>> {
    // Deserialize manifest file
    let manifest: GraphManifest = serde_yaml::from_str::<GraphManifest>(manifest_raw).unwrap();

    let mut network_contracts: HashMap<String, Vec<String>> = HashMap::new();

    // Iterate through data sources and templates to get network name and contracts
    for data_source in manifest.data_sources {
        let network = data_source.network;
        let contracts: Vec<_> = data_source
            .mapping
            .abis
            .iter()
            .map(|abi| abi.name.clone())
            .collect();
        network_contracts
            .entry(network)
            .or_insert_with(Vec::new)
            .extend(contracts);
    }

    // If templates exist, iterate through templates to get network name and contracts
    if let Some(templates) = manifest.templates {
        for template in templates {
            let network = template.network;
            let contracts: Vec<_> = template
                .mapping
                .abis
                .iter()
                .map(|abi| abi.name.clone())
                .collect();
            network_contracts
                .entry(network)
                .or_insert_with(Vec::new)
                .extend(contracts);
        }
    }

    network_contracts
}

async fn fetch_ipfs_file_with_retry(file_id: &str, file_name: &str) -> anyhow::Result<String> {
    let mut refetch_delay = Duration::from_secs(2);

    let fail_if_maximum_is_exceeded = |current_refetch_delay, err: &str| -> anyhow::Result<()> {
        if current_refetch_delay >= super::constants::MAXIMUM_BACKOFF {
            eprintln!("Failed to fetch {}: {}", file_name, err);
            eprintln!("{} file needs to be imported manually.", file_name);
            return Err(anyhow!("Maximum backoff timeout exceeded"));
        }
        Ok(())
    };
    loop {
        match timeout(refetch_delay, fetch_ipfs_file(file_id)).await {
            Ok(Ok(file)) => break Ok(file),
            Ok(Err(err)) => {
                fail_if_maximum_is_exceeded(refetch_delay, &err.to_string())?;
                eprintln!(
                    "Failed to fetch {}: {}. Retrying in {} seconds...",
                    file_name,
                    &err,
                    refetch_delay.as_secs()
                );
            }
            Err(err) => {
                fail_if_maximum_is_exceeded(refetch_delay, &err.to_string())?;
                eprintln!(
                    "Fetching {} timed out. Retrying in {} seconds...",
                    file_name,
                    refetch_delay.as_secs()
                );
            }
        }
        tokio::time::sleep(refetch_delay).await;
        refetch_delay *= 2;
    }
}

///Slice off "/ipfs/" from the path
///Note this can panic the first 6 chars in the string slice are invalid utf8
///However it will check for utf8 validity so there is no risk of junk values and path should
///always start with /ipfs/ which is valid
fn get_ipfs_id_from_file_path(file_path: &str) -> &str {
    &file_path[6..]
}

// Function to generate config, schema and abis from subgraph ID
pub async fn generate_config_from_subgraph_id(
    project_root_path: &PathBuf,
    subgraph_id: &str,
    language: &Language,
) -> anyhow::Result<()> {
    const MANIFEST_FILE_NAME: &str = "manifest.yaml";
    let manifest_file_string = fetch_ipfs_file_with_retry(subgraph_id, MANIFEST_FILE_NAME)
        .await
        .context("Failed to fetch manifest IPFS file")?;

    //Ensure the root dir is created before writing files to it
    fs::create_dir_all(project_root_path).context("Failed to create root dir")?;
    // Write manifest YAML file to a file
    // manifest file not required for Envio's indexing, but useful to save in project directory for debugging
    let manifest_path = project_root_path.join(MANIFEST_FILE_NAME);
    std::fs::write(manifest_path, &manifest_file_string)
        .with_context(|| format!("Failed to write {}.", MANIFEST_FILE_NAME))?;

    // Deserialize manifest file
    let manifest = serde_yaml::from_str::<GraphManifest>(&manifest_file_string)
        .with_context(|| format!("Failed to deserialize {}.", MANIFEST_FILE_NAME))?;

    // Create config object to be populated
    let mut config = Config {
        name: manifest.data_sources[0].name.clone(),
        description: manifest.description.unwrap_or_default(),
        schema: None,
        networks: vec![],
    };

    //Allow schema and abis to be fetched on different threads
    let mut join_set = JoinSet::new();

    // Fetching schema file path from config
    let schema_ipfs_file_path = manifest.schema.file.value.clone();

    let schema_fs_path = project_root_path.join(DEFAULT_SCHEMA_PATH);

    //spawn a thread for fetching schema
    join_set.spawn(async move {
        fetch_ipfs_file_and_write_to_system(schema_ipfs_file_path, schema_fs_path, "schema").await
    });

    // Generate network contract hashmap
    let network_hashmap = generate_network_contract_hashmap(&manifest_file_string).await;

    for (network_name, contracts) in &network_hashmap {
        // Create network object to be populated
        let mut network = Network {
            id: chain_helpers::get_graph_protocol_chain_id(
                chain_helpers::deserialize_network_name(network_name),
            ),
            // TODO: update to the final rpc url
            sync_source: None,
            start_block: 0,
            contracts: vec![],
        };
        // Iterate through contracts to get contract name, abi file path, address and event names
        for contract in contracts {
            match manifest
                .data_sources
                .iter()
                .find(|ds| &ds.source.abi == contract)
                .cloned()
            {
                None => {
                    println!("Data source not found");
                }
                Some(data_source) => {
                    let mut contract = ConfigContract {
                        name: data_source.name.to_string(),
                        abi_file_path: Some(format!(
                            "{}/abis/{}.json",
                            project_root_path.display(),
                            data_source.name
                        )),
                        address: NormalizedList::from_single(
                            data_source.source.address.to_string(),
                        ),
                        handler: get_event_handler_directory(language),
                        events: vec![],
                    };

                    // Fetching event names from config
                    let event_handlers = &data_source.mapping.event_handlers;
                    for event_handler in event_handlers {
                        // Event signatures of the manifest file from theGraph can differ from smart contract event signature convention
                        // therefore just extracting event name from event signature
                        if let Some(start) = event_handler.event.as_str().find('(') {
                            let event_name = &event_handler
                                .event
                                .as_str()
                                .chars()
                                .take(start)
                                .collect::<String>();
                            let event = ConfigEvent {
                                event: EventNameOrSig::Name(event_name.to_string()),
                                required_entities: Some(vec![]),
                            };

                            // Pushing event to contract
                            contract.events.push(event);
                        };
                    }
                    // Pushing contract to network
                    network.contracts.push(contract.clone());

                    //Create the dir for all abis to be dropped in
                    let abi_dir_path = project_root_path.join("abis");
                    fs::create_dir_all(&abi_dir_path).context("Failed to create abis dir")?;

                    for data_source_abi in &data_source.mapping.abis {
                        let abi_dir_path = abi_dir_path.clone();
                        let abi_ipfs_file_path = data_source_abi.file.value.clone();
                        let abi_file_path = abi_dir_path.join(format!("{}.json", data_source.name));
                        join_set.spawn(async move {
                            fetch_ipfs_file_and_write_to_system(
                                abi_ipfs_file_path,
                                abi_file_path,
                                "abi",
                            )
                            .await
                        });
                    }
                }
            };
        }
        // Pushing network to config
        config.networks.push(network);
    }
    // Convert config to YAML file
    let yaml_string = serde_yaml::to_string(&config).unwrap();

    // Write YAML string to a file
    std::fs::write("config.yaml", yaml_string).context("Failed to write config.yaml")?;

    //Await all the fetch and write threads before finishing
    while let Some(join) = join_set.join_next().await {
        join.map_err(|_| anyhow!("Failed to join abi fetch thread"))??;
    }

    Ok(())
}

async fn fetch_ipfs_file_and_write_to_system(
    ipfs_file_path: String,
    fs_file_path: PathBuf,
    context_name: &str,
) -> anyhow::Result<()> {
    let ipfs_id: &str = get_ipfs_id_from_file_path(&ipfs_file_path);

    let mut file_string = fetch_ipfs_file_with_retry(ipfs_id, context_name)
        .await
        .with_context(|| format!("Failed to fetch {} IPFS file", context_name))?;

    if context_name == "schema" {
        file_string = update_schema_with_supported_field_types(file_string);
    }

    fs::write(&fs_file_path, file_string)
        .with_context(|| format!("Failed to write {} IPFS file", context_name))?;
    // Write abi file to directory
    println!(
        "{} written to file: {}",
        context_name,
        fs_file_path.display()
    );

    Ok(())
}

#[cfg(test)] // ignore from the compiler when it builds, only checked when we run cargo test
mod test {
    use crate::cli_args::Language;
    use crate::config_parsing::graph_migration::get_ipfs_id_from_file_path;
    use std::collections::HashMap;

    use super::GraphManifest;

    use super::chain_helpers;
    // mod chain_helpers;

    // Integration test to see that a config file can be generated from a subgraph ID
    #[tokio::test]
    #[ignore = "Integration test that interacts with ipfs"]
    async fn test_generate_config_from_subgraph_id() {
        // subgraph ID of USDC on Ethereum mainnet
        let cid: &str = "QmU5V3jy56KnFbxX2uZagvMwocYZASzy1inX828W2XWtTd";
        let language: Language = Language::Rescript;
        let project_root_path: std::path::PathBuf = std::path::PathBuf::from("./");
        super::generate_config_from_subgraph_id(&project_root_path, cid, &language)
            .await
            .unwrap();
    }

    // Unit test to see that a manifest file can be deserialized
    #[test]
    fn test_manifest_deserializes() {
        let manifest_file = std::fs::read_to_string("test/configs/graph-manifest.yaml").unwrap();
        serde_yaml::from_str::<GraphManifest>(&manifest_file).unwrap();
    }

    // Unit test to see unsupported types in schema are replaced correctly
    #[test]
    fn test_update_schema_with_supported_field_types() {
        let schema_str = "type Factory @entity {
                id: ID!
                poolCount: BigInt!
                txCount: BigInt!
                totalVolumeUSD: BigDecimal!
                totalVolumeETH: BigDecimal!
                totalFeesUSD: BigDecimal!
                totalFeesETH: BigDecimal!
                untrackedVolumeUSD: BigDecimal!
                totalValueLockedUSD: BigDecimal!
                totalValueLockedETH: BigDecimal!
                totalValueLockedUSDUntracked: BigDecimal!
                totalValueLockedETHUntracked: BigDecimal!
                owner: ID!
            }"
        .to_string();
        let expected_schema_str = "type Factory @entity {
                id: ID!
                poolCount: BigInt!
                txCount: BigInt!
                totalVolumeUSD: Float!
                totalVolumeETH: Float!
                totalFeesUSD: Float!
                totalFeesETH: Float!
                untrackedVolumeUSD: Float!
                totalValueLockedUSD: Float!
                totalValueLockedETH: Float!
                totalValueLockedUSDUntracked: Float!
                totalValueLockedETHUntracked: Float!
                owner: ID!
            }"
        .to_string();

        assert_eq!(
            super::update_schema_with_supported_field_types(schema_str),
            expected_schema_str
        );
    }

    // Unit test to see if the network name is deserialized correctly
    #[test]
    fn test_network_deserialization() {
        let manifest_file = std::fs::read_to_string("test/configs/graph-manifest.yaml").unwrap();
        let manifest: GraphManifest =
            serde_yaml::from_str::<GraphManifest>(&manifest_file).unwrap();
        for data_source in manifest.data_sources {
            let chain_id = chain_helpers::get_graph_protocol_chain_id(
                chain_helpers::deserialize_network_name(&data_source.network),
            );
            println!("chainID: {}", chain_id);
        }
    }

    #[test]
    fn ipfs_id_from_path() {
        let path = "/ipfs/QmZ81YMckH8LxaLd9MnaGugvbvC9Mto3Ye3Vz4ydWE7npt";
        let id = get_ipfs_id_from_file_path(path);

        assert_eq!(id, "QmZ81YMckH8LxaLd9MnaGugvbvC9Mto3Ye3Vz4ydWE7npt");
    }

    // Unit test to that the correct ipfrs id is returned from a path
    #[test]
    #[should_panic]
    fn ipfs_id_from_path_non_unicode_panics() {
        //Panics because slicing half way through a non asci character does not return valid utf8
        //This should always be safe in our case because the first 6 chars should always be valid
        //utf8
        let non_unicode_string = "Hello世界!";
        get_ipfs_id_from_file_path(non_unicode_string);
    }

    // Unit test to check that the correct event handler directory is returned based on the language
    #[test]
    fn test_get_event_handler_directory() {
        let language_1: Language = Language::Rescript;
        let language_2: Language = Language::Javascript;
        let language_3: Language = Language::Typescript;
        let event_handler_directory_1 = super::get_event_handler_directory(&language_1);
        let event_handler_directory_2 = super::get_event_handler_directory(&language_2);
        let event_handler_directory_3 = super::get_event_handler_directory(&language_3);
        assert_eq!(event_handler_directory_1, "./src/EventHandlers.bs.js");
        assert_eq!(event_handler_directory_2, "./src/EventHandlers.js");
        assert_eq!(event_handler_directory_3, "src/EventHandlers.ts");
    }
    // Unit test to check that the correct network contract hashmap is generated
    #[tokio::test]
    async fn test_generate_network_contract_hashmap() {
        let manifest_file = std::fs::read_to_string("test/configs/graph-manifest.yaml").unwrap();
        let network_contracts = super::generate_network_contract_hashmap(&manifest_file).await;
        let mut network_contracts_expected = HashMap::new();
        network_contracts_expected.insert("mainnet".to_string(), vec!["FiatTokenV1".to_string()]);
        assert_eq!(network_contracts, network_contracts_expected);
    }
}
