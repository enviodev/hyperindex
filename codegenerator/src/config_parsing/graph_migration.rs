use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_yaml;
use serde_json::{json, Value};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GraphManifest {
    pub spec_version: String,
    pub description: String,
    pub repository: String,
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

// serde_yaml::from_str::<GraphManifest>(manifest_str).unwrap();

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

// serde_yaml::from_str::<DataSource>(data_source_str).unwrap();

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

#[derive(Debug, Deserialize, Serialize)]
pub struct Config {
    version: String,
    description: String,
    repository: String,
    networks: Vec<Network>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct Network {
    id: i32,
    rpc_url: String,
    start_block: i32,
    contracts: Vec<Contract>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct Contract {
    name: String,
    abi_file_path: String,
    address: ContractAddress,
    // #[serde(serialize_with = "serialize_handler")]
    handler: String,
    events: Vec<Event>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(untagged)]
pub enum ContractAddress {
    Single(String),
    Multiple(Vec<String>),
}

#[derive(Debug, Deserialize, Serialize)]
pub struct Event {
    event: String,
    requiredEntities: Vec<RequiredEntity>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct RequiredEntity {
    name: String,
    labels: Vec<String>,
}

pub fn get_event_handler_directory(language: &str) -> String {
    // Logic to get the event handler directory based on the language
    unimplemented!()
}

pub fn serialize_handler<S>(handler: &String, serializer: S) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    let directory = get_event_handler_directory(handler);
    serializer.serialize_str(&directory)
}

async fn fetch_ipfs_file(cid: &str) -> Result<String, reqwest::Error> {
    let url = format!("https://ipfs.network.thegraph.com/api/v0/cat?arg={}", cid);
    let client = reqwest::Client::new();
    let response = client.get(&url).send().await?;
    let content_raw = response.text().await?;
    Ok(content_raw)
}

pub async fn from_subgraph_id(subgraph_id: &str) -> Result<String, Box<dyn std::error::Error>> {
    // Fetch the manifest file.
    let manifest_raw = fetch_ipfs_file(subgraph_id).await?;
    let manifest: GraphManifest = serde_yaml::from_str(&manifest_raw)?;

    // Fetch and write the schema.graphql file.
    let schema_cid = manifest.schema.file.value.as_str()[6..].to_owned();
    let schema_raw = fetch_ipfs_file(&schema_cid).await?;
    let schema_cleaned = schema_raw.replace("BigDecimal", "Float");

    Ok(schema_cleaned)
}

#[cfg(test)] // ignore from the compiler when it builds, only checked when we run cargo test
mod test {

    use std::collections::HashMap;
    use std::fs::File;
    use std::io::Write;

    async fn fetch_ipfs_file(cid: &str) -> Result<String, reqwest::Error> {
        let url = format!("https://ipfs.network.thegraph.com/api/v0/cat?arg={}", cid);
        let client = reqwest::Client::new();
        let response = client.get(&url).send().await?;
        let content_raw = response.text().await?;
        Ok(content_raw)
    }

    #[test]
    fn deserialize_manifest() {
        let manifest_str = std::fs::read_to_string("test/configs/graph_manifest.yaml").unwrap();
        let manifest = serde_yaml::from_str::<super::GraphManifest>(&manifest_str).unwrap();

        let data_sources = &manifest.data_sources;
        for data_source in data_sources {
            // Fetching contract name from config
            let contract_name = &data_source.name;
            println!("Contract name: {}", contract_name);

            // Fetching contract address and start block from config
            let address = data_source.source.address.as_str();
            println!("Address: {}", address);
            let start_block = data_source.source.start_block.as_str();
            println!("Start block: {}", start_block);

            // Fetching chain ID from config
            let chain_id = get_graph_protocol_chain_id(data_source.network.as_str());
            println!("Chain ID: {}", chain_id.unwrap());

            // Fetching abi file path from config
            let abi_file_path = &data_source.mapping.abis[0].file;
            println!("ABI file path: {:?}", abi_file_path);

            // Fetching event names from config
            let event_handlers = &data_source.mapping.event_handlers;
            for event_handler in event_handlers {
                if let Some(start) = event_handler.event.as_str().find('(') {
                    println!("Event: {}", &event_handler.event.as_str()[..start]);
                }
            }
        }
    }

    #[tokio::test]
    async fn from_subgraph_id() {
        let mut config = super::Config {
            version: String::new(),
            description: String::new(),
            repository: String::new(),
            networks: vec![],
        };

        let cid: &str = "QmQ2rQ6zfhQFwRRJLb1XT1kteweQqhyo7Va8NnfiSLC8qe";
        let manifest_str = fetch_ipfs_file(cid).await.unwrap();

        println!("Manifest: {}", manifest_str);

        let manifest = serde_yaml::from_str::<super::GraphManifest>(&manifest_str).unwrap();

        let data_sources = &manifest.data_sources;

        // Populate custom values for each field
        config.version = "1.0.0".to_string();
        config.description = manifest.description.to_string();
        config.repository = manifest.repository.to_string();

        for data_source in data_sources {
            // Fetching contract name from config
            let contract_name = &data_source.name;
            // println!("Contract name: {}", contract_name);

            // Fetching contract address and start block from config
            let address = data_source.source.address.as_str();
            // println!("Address: {}", address);
            let start_block = data_source.source.start_block.as_str();
            // println!("Start block: {}", start_block);

            // Fetching chain ID from config
            let chain_id = get_graph_protocol_chain_id(data_source.network.as_str());
            // println!("Chain ID: {}", chain_id.unwrap());

            // Fetching schema file path from config
            let schema_file_path = &manifest.schema.file;
            // println!("Schema file path: {:?}", schema_file_path.value);
            let schema_id = &schema_file_path.value.as_str()[6..];
            // println!("Schema ID: {}", schema_id);
            let schema = fetch_ipfs_file(schema_id)
                .await
                .unwrap()
                .replace("BigDecimal", "Float");
            let mut file = File::create( "./schema.graphql").expect("Failed to create file");
            file.write_all(schema.as_bytes())
                .expect("Failed to write to file");
            // print!("schema: {}", schema);

            // Fetching abi file path from config
            let abi_file_path = &data_source.mapping.abis[0].file;
            // println!("ABI file path: {:?}", abi_file_path.value);
            let abi_id = &abi_file_path.value.as_str()[6..];
            // println!("ABI ID: {}", schema_id);
            // let abi = fetch_ipfs_file(abi_id).await.unwrap();
            // print!("ABI: {}", abi);

            let mut network = super::Network {
                id: chain_id.unwrap(),
                rpc_url: "https://example.com/rpc".to_string(),
                start_block: start_block.parse::<i32>().unwrap(),
                contracts: vec![],
            };

            let mut contract =super::Contract {
                name: contract_name.to_string(),
                abi_file_path: "./path/to/abi.json".to_string(),
                address: super::ContractAddress::Single(address.to_string()),
                handler: "rust".to_string(),
                events: vec![],
            };



            
            // Fetching event names from config
            let event_handlers = &data_source.mapping.event_handlers;
            for event_handler in event_handlers {
                if let Some(start) = event_handler.event.as_str().find('(') {
                    let event_name =  &event_handler.event.as_str()[..start];
                    // println!("Event: {}", &event_handler.event.as_str()[..start]);
                    let mut event = super::Event {
                        event: event_name.to_string(),
                        requiredEntities: vec![],
                    };
                    contract.events.push(event);
                }
            }

            network.contracts.push(contract);
            config.networks.push(network);
            
        }
    
        let mut event = super::Event {
            event: "MyEvent".to_string(),
            requiredEntities: vec![],
        };
    
        // Convert config to YAML
        let yaml_string = serde_yaml::to_string(&config).unwrap();
    
        // Write YAML string to a file
        std::fs::write("config.yaml", yaml_string).expect("Failed to write config.yaml");
    }

    fn get_graph_protocol_chain_id(network_name: &str) -> Option<i32> {
        let chain_id_by_graph_network: HashMap<&str, i32> = [
            ("mainnet", 1),
            ("kovan", 42),
            ("rinkeby", 4),
            ("ropsten", 3),
            ("goerli", 5),
            ("poa-core", 99),
            ("poa-sokol", 77),
            ("xdai", 100),
            ("matic", 137),
            ("mumbai", 80001),
            ("fantom", 250),
            ("fantom-testnet", 4002),
            ("bsc", 56),
            ("chapel", -1),
            ("clover", 0),
            ("avalanche", 43114),
            ("fuji", 43113),
            ("celo", 42220),
            ("celo-alfajores", 44787),
            ("fuse", 122),
            ("moonbeam", 1284),
            ("moonriver", 1285),
            ("mbase", -1),
            ("arbitrum-one", 42161),
            ("arbitrum-rinkeby", 421611),
            ("optimism", 10),
            ("optimism-kovan", 69),
            ("aurora", 1313161554),
            ("aurora-testnet", 1313161555),
        ]
        .iter()
        .cloned()
        .collect();

        chain_id_by_graph_network.get(network_name).cloned()
    }
}

//loop through contracts
//get network id and set a hashmap entry of key network id and value contract config


//manifest
// [
//     {
//         contract: 1
//          networkid: 1
//     },
//     {
//         contract: 2,
//         networkid: 1
//     }
// ]

// {
//     "1" : {contacts: [contract1, contract2], startblocks: [1,2]},
// }
