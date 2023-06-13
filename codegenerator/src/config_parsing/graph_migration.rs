use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_yaml;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GraphManifest {
    pub spec_version: String,
    pub description: String,
    pub repository: String,
    pub schema: Schema,
    pub data_sources: Vec<DataSource>,
}

#[derive(Debug, Deserialize)]
pub struct Schema {
    pub file: String,
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
pub struct Mapping {
    pub kind: String,
    pub api_version: String,
    pub language: String,
    pub entities: Vec<String>,
    pub abis: Vec<Abi>,
    pub event_handlers: Vec<EventHandler>,
    pub call_handlers: Vec<CallHandler>,
    pub block_handlers: Vec<BlockHandler>,
    pub file: String,
}

#[derive(Debug, Deserialize)]
pub struct Abi {
    pub name: String,
    pub file: String,
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
    let schema_cid = manifest.schema.file.as_str()[6..].to_owned();
    let schema_raw = fetch_ipfs_file(&schema_cid).await?;
    let schema_cleaned = schema_raw.replace("BigDecimal", "Float");

    Ok(schema_cleaned)
}

#[cfg(test)] // ignore from the compiler when it builds, only checked when we run cargo test
mod test {

    use std::collections::HashMap;

    #[test]
    fn deserialize_manifest() {
        let manifest_str = std::fs::read_to_string("test/configs/graph_manifest.yaml").unwrap();
        let manifest = serde_yaml::from_str::<super::GraphManifest>(&manifest_str).unwrap();

        // Fetching contract address and start block from config
        let address = manifest.data_sources[0].source.address.as_str();
        println!("{}", address);
        let start_block = manifest.data_sources[0].source.start_block.as_str();
        println!("{}", start_block);

        // Fetching event names from config
        let event_handlers = &manifest.data_sources[0].mapping.event_handlers;
        println!("{:?}", event_handlers);
        
        for event_handler in event_handlers {
            println!("{}", event_handler.event);
            println!("{}", event_handler.handler);
        }
        
        // Fetch chain ID from config
        let chain_id = get_graph_protocol_chain_id(manifest.data_sources[0].network.as_str());
        println!("Chain ID: {}", chain_id.unwrap());
    }

    #[tokio::test]
    async fn fetch_ipfs_file() {
        let cid: &str = "QmNkMVJdswYgUYpP6BtQy8K1P9EJQrbVJX2b2RrhAx8s6x";
        println!("{}", cid);
        let url = format!("https://ipfs.network.thegraph.com/api/v0/cat?arg={}", cid);
        println!("{}", url);
        let client = reqwest::Client::new();
        let response = client.get(&url).send().await.unwrap();
        println!("{:?}", response);
        let content_raw = response.text().await.unwrap();
        println!("{}", content_raw);
        // serde_yaml::from_str::<super::GraphManifest>(&content_raw).unwrap();
    }

    #[tokio::test]
    async fn from_subgraph_id() {
        let manifest_str = std::fs::read_to_string("test/configs/graph_manifest.yaml").unwrap();
        let manifest = serde_yaml::from_str::<super::GraphManifest>(&manifest_str).unwrap();

        // Fetch the schema.graphql file.
        let schema_cid = manifest.schema.file.as_str()[6..].to_owned();
        // let schema_cid = "QmNkMVJdswYgUYpP6BtQy8K1P9EJQrbVJX2b2RrhAx8s6x";
        println!("{}", schema_cid);

        let url = format!(
            "https://ipfs.network.thegraph.com/api/v0/cat?arg={}",
            schema_cid
        );
        println!("{}", url);
        let client = reqwest::Client::new();
        let response = client.get(&url).send().await.unwrap();
        println!("{:?}", response);
        let content_raw = response.text().await.unwrap();
        println!("{}", content_raw);

        let schema_cleaned = content_raw.replace("BigDecimal", "Float");
        println!("{}", schema_cleaned);

        // Fetch
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
