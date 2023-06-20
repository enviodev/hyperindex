use serde::{Deserialize, Serialize};
use serde_yaml;
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use tokio::time::{timeout, Duration};

use crate::{
    cli_args::Language,
    config_parsing::{
        Config, ConfigContract, ConfigEvent, EventNameOrSig, Network, NormalizedList,
    },
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

#[derive(Debug, Deserialize, Serialize)]
pub struct KeyValue {
    #[serde(rename = "/")]
    pub value: String,
}

#[derive(Debug, Deserialize)]
pub struct Schema {
    pub file: KeyValue,
}

#[derive(Debug, Deserialize)]
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

#[derive(Debug, Deserialize)]
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

#[derive(Debug, Deserialize)]
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
    pub file: KeyValue,
}

#[derive(Debug, Deserialize)]
pub struct Abi {
    pub name: String,
    pub file: KeyValue,
}

#[derive(Debug, Deserialize)]
pub struct EventHandler {
    pub event: String,
    pub handler: String,
}

#[derive(Debug, Deserialize)]
pub struct CallHandler {
    pub function: String,
    pub handler: String,
}

#[derive(Debug, Deserialize)]
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
) -> Result<HashMap<String, Vec<String>>, Box<dyn std::error::Error>> {
    let manifest: GraphManifest = serde_yaml::from_str(manifest_raw)?;

    let mut network_contracts: HashMap<String, Vec<String>> = HashMap::new();

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

    Ok(network_contracts)
}

// Function to return the chain ID of the network based on the network name
fn get_graph_protocol_chain_id(network_name: &str) -> Option<i32> {
    match network_name {
        "mainnet" => Some(1),
        "kovan" => Some(42),
        "rinkeby" => Some(4),
        "ropsten" => Some(3),
        "goerli" => Some(5),
        "poa-core" => Some(99),
        "poa-sokol" => Some(77),
        "xdai" => Some(100),
        "matic" => Some(137),
        "mumbai" => Some(80001),
        "fantom" => Some(250),
        "fantom-testnet" => Some(4002),
        "bsc" => Some(56),
        "chapel" => Some(-1),
        "clover" => Some(0),
        "avalanche" => Some(43114),
        "fuji" => Some(43113),
        "celo" => Some(42220),
        "celo-alfajores" => Some(44787),
        "fuse" => Some(122),
        "moonbeam" => Some(1284),
        "moonriver" => Some(1285),
        "mbase" => Some(-1),
        "arbitrum-one" => Some(42161),
        "arbitrum-rinkeby" => Some(421611),
        "optimism" => Some(10),
        "optimism-kovan" => Some(69),
        "aurora" => Some(1313161554),
        "aurora-testnet" => Some(1313161555),
        _ => None,
    }
}

pub async fn generate_config_from_subgraph_id(
    project_root_path: &PathBuf,
    subgraph_id: &str,
    language: &Language,
) {
    println!("Generating config for subgraph ID: {}", subgraph_id);

    // manifest file not required for Envio's indexing, but useful to save in project directory for debugging
    println!("Fetching subgraph manifest file");
    let fetch_manifest_str = timeout(Duration::from_secs(20), fetch_ipfs_file(subgraph_id));
    match fetch_manifest_str.await.unwrap() {
        Ok(manifest_str) => {
            // Convert manifest to YAML string
            let manifest_yaml = serde_yaml::to_string(&manifest_str).unwrap();

            // Write manifest YAML file to a file
            std::fs::write("manifest.yaml", manifest_yaml).expect("Failed to write manifest.yaml");

            let manifest = serde_yaml::from_str::<GraphManifest>(&manifest_str).unwrap();

            let mut config = Config {
                version: "1.0.0".to_string(),
                description: manifest.description.unwrap_or_else(|| "".to_string()),
                repository: manifest.repository.unwrap_or_else(|| "".to_string()),
                schema: None,
                networks: vec![],
                unstable_sync_config: None,
            };
            
            // Fetching schema file path from config
            let schema_file_path = &manifest.schema.file;
            let schema_id = &schema_file_path.value.as_str()[6..];
            println!("Fetching subgraph schema file");
            let schema = fetch_ipfs_file(schema_id)
                .await
                .unwrap()
                .replace("BigDecimal", "Float");
            let mut schema_file_directory =
                File::create(format!("{}schema.graphql", project_root_path.display()))
                    .expect("Failed to create file");
            schema_file_directory
                .write_all(schema.as_bytes())
                .expect("Failed to write to file");

            let network_hashmap = generate_network_contract_hashmap(&manifest_str)
                .await
                .unwrap();

            for (network_id, contracts) in &network_hashmap {
                let mut network = Network {
                    id: get_graph_protocol_chain_id(network_id).unwrap(),
                    // TODO: update to the final rpc url
                    rpc_url: "https://example.com/rpc".to_string(),
                    start_block: 0,
                    contracts: vec![],
                };
                for contract in contracts {
                    if let Some(data_source) =
                        manifest.data_sources.iter().find(|ds| &ds.source.abi == contract)
                    {
                        let mut contract = ConfigContract {
                            name: data_source.name.to_string(),
                            abi_file_path: Some(format!(
                                "{}abis/{}.json",
                                project_root_path.display(),
                                data_source.name.to_string()
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
                            if let Some(start) = event_handler.event.as_str().find('(') {
                                let event_name = &event_handler.event.as_str()[..start];
                                let event = ConfigEvent {
                                    event: EventNameOrSig::Name(event_name.to_string()),
                                    required_entities: Some(vec![]),
                                };
                                contract.events.push(event.clone());
                            }
                        }
                        network.contracts.push(contract.clone());

                        // Fetching abi file path from config
                        let abi_file_path = &data_source.mapping.abis[0].file;
                        let abi_id: &str = &abi_file_path.value.as_str()[6..];

                        let fetch_abi = timeout(Duration::from_secs(20), fetch_ipfs_file(abi_id));
                        match fetch_abi.await {
                            Ok(Ok(abi)) => {
                                let abi_file_directory = format!(
                                    "{}abis/{}.json",
                                    project_root_path.display(),
                                    data_source.name.to_string()
                                );
                                let file_path = Path::new(&abi_file_directory);

                                if let Some(parent_dir) = file_path.parent() {
                                    if !parent_dir.exists() {
                                        fs::create_dir_all(parent_dir)
                                            .expect("Failed to create directory");
                                    }
                                }
                                let mut abi_file = File::create(&abi_file_directory)
                                    .expect("Failed to create file");
                                abi_file
                                    .write_all(abi.as_bytes())
                                    .expect("Failed to write ABI to file");
                                println!("ABI written to file: {}", abi_file_directory);
                            }
                            Ok(Err(error)) => {
                                eprintln!("Failed to fetch ABI: {:?}", error);
                                eprintln!("Please export contract ABI manually");
                            }
                            Err(_) => {
                                eprintln!(
                                    "Fetching ABI timed out for contract: {}",
                                    data_source.name
                                );
                                eprintln!("Please export contract ABI manually");
                            }
                        }
                    } else {
                        println!("Data source not found");
                    }
                }
                config.networks.push(network);
            }
            // Convert config to YAML file
            let yaml_string = serde_yaml::to_string(&config).unwrap();

            // Write YAML string to a file
            std::fs::write("config.yaml", yaml_string).expect("Failed to write config.yaml");
        }
        Err(error) => {
            eprintln!("Failed to fetch manifest: {:?}", error);
            eprintln!("Please migrate subgraph manually");
        }
    }
}

#[cfg(test)] // ignore from the compiler when it builds, only checked when we run cargo test
mod test {
    use crate::cli_args::Language;

    #[tokio::test]
    async fn test_generate_config_from_subgraph_id() {
        // subgraph ID of USDC on Ethereum mainnet
        let cid: &str = "QmU5V3jy56KnFbxX2uZagvMwocYZASzy1inX828W2XWtTd";
        let language: Language = Language::Rescript;
        let project_root_path: std::path::PathBuf = std::path::PathBuf::from("./");
        super::generate_config_from_subgraph_id(&project_root_path, cid, &language).await;
    }
}
