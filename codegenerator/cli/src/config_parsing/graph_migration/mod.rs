use crate::{
    cli_args::init_config::Language,
    config_parsing::{
        chain_helpers::{self, GraphNetwork},
        human_config::{
            evm::{ContractConfig, EventConfig, HumanConfig, Network},
            NetworkContract,
        },
    },
    constants::project_paths::DEFAULT_SCHEMA_PATH,
};
use anyhow::{anyhow, Context};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_yaml;
use std::{collections::HashMap, fs, path::PathBuf};
use tokio::{
    task::JoinSet,
    time::{timeout, Duration},
};

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
    pub network: GraphNetwork,
    pub source: Source,
    pub mapping: Mapping,
}
#[derive(Debug, Deserialize)]
pub struct Template {
    pub kind: String,
    pub name: String,
    pub network: GraphNetwork,
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
        Language::ReScript => "./src/EventHandlers.res.js".to_string(),
        Language::TypeScript => "src/EventHandlers.ts".to_string(),
        Language::JavaScript => "./src/EventHandlers.js".to_string(),
    }
}

// Function to replace unsupported field types from schema
fn update_schema_with_supported_field_types(schema_str: String) -> String {
    schema_str.replace("BigDecimal", "Float")
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
async fn generate_network_contract_hashmap(
    manifest_raw: &str,
) -> HashMap<GraphNetwork, Vec<String>> {
    // Deserialize manifest file
    let manifest: GraphManifest = serde_yaml::from_str::<GraphManifest>(manifest_raw).unwrap();

    let mut network_contracts: HashMap<GraphNetwork, Vec<String>> = HashMap::new();

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
            .or_default()
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
                .or_default()
                .extend(contracts);
        }
    }

    // remove any duplicate contracts per network before returning the network_contracts hashmap
    for contracts in network_contracts.values_mut() {
        contracts.sort();
        contracts.dedup();
    }

    network_contracts
}

// maximum backoff period for fetching files from IPFS
const MAXIMUM_BACKOFF: Duration = Duration::from_secs(32);

async fn fetch_ipfs_file_with_retry(file_id: &str, file_name: &str) -> anyhow::Result<String> {
    let mut refetch_delay = Duration::from_secs(2);

    let fail_if_maximum_is_exceeded = |current_refetch_delay, err: &str| -> anyhow::Result<()> {
        if current_refetch_delay >= MAXIMUM_BACKOFF {
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

fn valid_ipfs_cid(cid: &str) -> bool {
    let ipfs_cid_regex = Regex::new(r"Qm[1-9A-HJ-NP-Za-km-z]{44,}").unwrap();
    ipfs_cid_regex.is_match(cid)
}

// Function to generate config, schema and abis from subgraph ID
pub async fn generate_config_from_subgraph_id(
    project_root_path: &PathBuf,
    subgraph_id: &str,
    language: &Language,
) -> anyhow::Result<HumanConfig> {
    if !valid_ipfs_cid(subgraph_id) {
        return Err(anyhow!(
            "EE402: Invalid subgraph ID. Subgraph ID must match the IPFS CID format convention. More information can be found here: https://github.com/multiformats/cid#cidv0"
        ));
    }

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
    let mut config = HumanConfig {
        name: manifest.data_sources[0].name.clone(),
        description: manifest.description,
        ecosystem: None,
        schema: None,
        contracts: None,
        networks: vec![],
        unordered_multichain_mode: None,
        event_decoder: None,
        rollback_on_reorg: None,
        save_full_history: None,
        field_selection: None,
        raw_events: None,
    };
    let mut networks: Vec<Network> = vec![];

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

    for (graph_network, contracts) in &network_hashmap {
        // Create network object to be populated
        let mut network = Network {
            id: chain_helpers::Network::from(*graph_network).get_network_id(),
            hypersync_config: None,
            // TODO: update to the final rpc url
            rpc_config: None,
            rpc: None,
            start_block: 0,
            end_block: None,
            confirmed_block_threshold: None,
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
                    // Fetching event names from config
                    let event_handlers = &data_source.mapping.event_handlers;
                    let events = event_handlers
                        .iter()
                        .map(|event_handler| {
                            let start =
                                event_handler.event.as_str().find('(').ok_or_else(|| {
                                    anyhow!("Unexepected event definition without a '(' char")
                                })?;

                            // Event signatures of the manifest file from theGraph can differ from smart contract event signature convention
                            // therefore just extracting event name from event signature
                            let event_name = &event_handler
                                .event
                                .as_str()
                                .chars()
                                .take(start)
                                .collect::<String>();
                            let event = EventConfig {
                                event: event_name.to_string(),
                                name: None,
                                field_selection: None,
                            };

                            Ok(event)
                        })
                        .collect::<anyhow::Result<Vec<_>>>()?;

                    let contract = NetworkContract {
                        name: data_source.name.to_string(),
                        address: vec![data_source.source.address.to_string()].into(),
                        config: Some(ContractConfig {
                            abi_file_path: Some(format!("abis/{}.json", data_source.name)),
                            handler: get_event_handler_directory(language),
                            events,
                        }),
                    };

                    // Pushing contract to network
                    network.contracts.push(contract.clone());

                    //Create the dir for all abis to be dropped in
                    let abi_dir_path = project_root_path.join("abis");
                    fs::create_dir_all(&abi_dir_path).context("Failed to create abis dir")?;

                    for data_source_abi in &data_source.mapping.abis {
                        let abi_dir_path = abi_dir_path.clone();
                        let abi_ipfs_file_path = data_source_abi.file.value.clone();
                        let abi_file_path =
                            abi_dir_path.join(format!("{}.json", data_source_abi.name));
                        println!("abi_ipfs_file_path: {}", abi_ipfs_file_path);
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
        networks.push(network);
    }
    config.networks = networks;

    // Convert config to YAML file
    let yaml_string = serde_yaml::to_string(&config).unwrap();

    // Write YAML string to a file
    std::fs::write(project_root_path.join("config.yaml"), yaml_string)
        .context("Failed to write config.yaml")?;

    //Await all the fetch and write threads before finishing
    while let Some(join) = join_set.join_next().await {
        join.map_err(|_| anyhow!("Failed to join abi fetch thread"))??;
    }

    Ok(config)
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
    use super::GraphManifest;
    use crate::{
        cli_args::init_config::Language,
        config_parsing::{
            chain_helpers::{GraphNetwork, Network},
            graph_migration::get_ipfs_id_from_file_path,
        },
    };
    use std::{collections::HashMap, path::PathBuf};
    use tempdir::TempDir;

    // Integration test to see that a config file can be generated from a subgraph ID
    #[tokio::test]
    #[ignore = "Integration test that interacts with ipfs"]
    async fn test_generate_config_from_subgraph_id() {
        let temp_dir = TempDir::new("temp_graph_migration_folder").unwrap();
        // subgraph ID of USDC on Ethereum mainnet
        let cid: &str = "QmU5V3jy56KnFbxX2uZagvMwocYZASzy1inX828W2XWtTd";
        let language: Language = Language::ReScript;
        let project_root = PathBuf::from(temp_dir.path());
        super::generate_config_from_subgraph_id(&project_root, cid, &language)
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
            let chain_id = Network::from(data_source.network).get_network_id();
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
        let language_1: Language = Language::ReScript;
        let language_2: Language = Language::JavaScript;
        let language_3: Language = Language::TypeScript;
        let event_handler_directory_1 = super::get_event_handler_directory(&language_1);
        let event_handler_directory_2 = super::get_event_handler_directory(&language_2);
        let event_handler_directory_3 = super::get_event_handler_directory(&language_3);
        assert_eq!(event_handler_directory_1, "./src/EventHandlers.res.js");
        assert_eq!(event_handler_directory_2, "./src/EventHandlers.js");
        assert_eq!(event_handler_directory_3, "src/EventHandlers.ts");
    }
    // Unit test to check that the correct network contract hashmap is generated
    #[tokio::test]
    async fn test_generate_network_contract_hashmap() {
        let manifest_file = std::fs::read_to_string("test/configs/graph-manifest.yaml").unwrap();
        let network_contracts = super::generate_network_contract_hashmap(&manifest_file).await;
        let mut network_contracts_expected = HashMap::new();
        network_contracts_expected.insert(
            GraphNetwork::EthereumMainnet,
            vec!["FiatTokenV1".to_string()],
        );
        assert_eq!(network_contracts, network_contracts_expected);
    }

    #[test]
    fn test_valid_ipfs_cid() {
        let subgraph_id_1 = "QmdAmQxQCuGoeqNLuE8m6zH366pY2LkustTRYDhSt85X7w";
        let subgraph_id_2 = "QmZ81YMckH8LxaLd9MnaGugvbvC9Mto3Ye3Vz4ydWE7npt";
        let subgraph_id_3 = "QmZ81YMckH8LxaLd9MnaGugvbvC9Mto3Ye3Vz4ydWE7nt";

        let valid_1 = super::valid_ipfs_cid(subgraph_id_1);
        let valid_2 = super::valid_ipfs_cid(subgraph_id_2);
        let valid_3 = super::valid_ipfs_cid(subgraph_id_3);

        assert!(valid_1);
        assert!(valid_2);
        assert!(!valid_3);
    }

    #[test]
    #[ignore]
    fn subgraph_id() {
        let valid_sub_graph_ids = vec![
            //Aave V2 Ethereum
            "C2zniPn45RnLDGzVeGZCx2Sw3GXrbc9gL4ZfL8B8Em2j",
            //Substreams Uniswap v3 Ethereum
            "HUZDsRpEVP2AvzDCyzDHtdc64dyDxx8FQjzsmqSg4H3B",
        ];

        for id in valid_sub_graph_ids {
            assert!(super::valid_ipfs_cid(id))
        }
    }
}
