use envio::config_parsing::chain_helpers::{GraphNetwork, HypersyncNetwork};
use reqwest;
use serde::Deserialize;
use std::collections::HashSet;

fn to_pascal_case(s: &str) -> String {
    s.split(|c: char| !c.is_alphanumeric())
        .filter(|&s| !s.is_empty())
        .map(|s| {
            let mut c = s.chars();
            match c.next() {
                None => String::new(),
                Some(f) => f.to_uppercase().chain(c).collect(),
            }
        })
        .collect()
}

#[derive(Deserialize, Debug)]
struct Chain {
    name: String,
    chain_id: u64,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let url = "https://chains.hyperquery.xyz/active_chains";
    let response = reqwest::get(url).await?;
    let chains: Vec<Chain> = response.json().await?;

    let mut missing_chains = Vec::new();
    let mut api_chain_ids = HashSet::new();

    for chain in &chains {
        api_chain_ids.insert(chain.chain_id);
        if HypersyncNetwork::from_repr(chain.chain_id).is_none() {
            let is_graph = GraphNetwork::from_repr(chain.chain_id).is_some();

            let subenums = match is_graph {
                true => "HypersyncNetwork, GraphNetwork",
                false => "HypersyncNetwork",
            };
            missing_chains.push(format!(
                "    #[subenum({})]\n    {} = {},",
                subenums,
                to_pascal_case(&chain.name),
                chain.chain_id
            ));
        }
    }

    let mut extra_chains = Vec::new();
    for network in HypersyncNetwork::iter_hypersync_networks() {
        let network_id = network as u64;
        if !api_chain_ids.contains(&network_id) {
            extra_chains.push(format!("{:?} (ID: {})", network, network_id));
        }
    }

    if missing_chains.is_empty() && extra_chains.is_empty() {
        println!(
            "All chains from the API are present in the HypersyncNetwork enum, and vice versa. Nothing to update."
        );
    } else {
        if !missing_chains.is_empty() {
            println!("The following chains are missing from the Network enum:");
            for chain in missing_chains {
                println!("{}", chain);
            }
        }

        if !extra_chains.is_empty() {
            println!("\nThe following chains are in the HypersyncNetwork enum but not in the API (remove the HypersyncNetwork enum from the chain_helpers.rs file):");
            for chain in extra_chains {
                println!("- {}", chain);
            }
        }
    }

    Ok(())
}
