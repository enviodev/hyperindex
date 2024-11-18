use crate::config_parsing::chain_helpers::{GraphNetwork, HypersyncNetwork, IgnoreFromTests, Network};
use anyhow::Result;
use convert_case::{Case, Casing};
use reqwest;
use serde::Deserialize;
use std::collections::HashSet;
use strum::IntoEnumIterator;

#[derive(Deserialize, Debug)]
struct Chain {
    name: String,
    chain_id: Option<u64>, // None for Fuel chains
}

pub struct Diff {
    pub missing_chains: Vec<String>,
    pub extra_chains: Vec<String>,
}

pub async fn get_diff() -> Result<Diff> {
    let url = "https://chains.hyperquery.xyz/active_chains";
    let response = reqwest::get(url).await?;
    let chains: Vec<Chain> = response.json().await?;
    let ignored_chains = IgnoreFromTests::iter().map(|c|{Network::from(c).get_network_id()}).collect::<Vec<u64>>();

    let mut missing_chains = Vec::new();
    let mut api_chain_ids = HashSet::new();

    for chain in &chains {
        let Some(chain_id) = chain.chain_id else {
            continue;
        };
        if ignored_chains.contains(&chain_id) {
            continue;
        }
        if chain.name == "internal-test-chain" {
            continue;
        }
        api_chain_ids.insert(chain_id);
        if HypersyncNetwork::from_repr(chain_id).is_none() {
            let is_graph = GraphNetwork::from_repr(chain_id).is_some();

            let subenums = match is_graph {
                true => "HypersyncNetwork, GraphNetwork",
                false => "HypersyncNetwork",
            };
            missing_chains.push(format!(
                "    #[subenum({})]\n    {} = {},",
                subenums,
                chain.name.to_case(Case::Pascal),
                chain_id
            ));
        }
    }

    let mut extra_chains = Vec::new();
    for network in HypersyncNetwork::iter_hypersync_networks() {
        let network_id = network as u64;
        if !ignored_chains.contains(&network_id) {
            continue;
        }
        if !api_chain_ids.contains(&network_id) {
            extra_chains.push(format!("{:?} (ID: {})", network, network_id));
        }
    }

    Ok(Diff {
        missing_chains,
        extra_chains,
    })
}

pub fn print_diff_message(diff: Diff) {
    let Diff {
        missing_chains,
        extra_chains,
    } = diff;
    if missing_chains.is_empty() && extra_chains.is_empty() {
        println!(
            "All chains from the API are present in the HypersyncNetwork enum, and vice versa. \
         Nothing to update."
        );
    } else {
        if !missing_chains.is_empty() {
            println!("The following chains are missing from the Network enum:");
            for chain in missing_chains {
                println!("{}", chain);
            }
        }

        if !extra_chains.is_empty() {
            println!(
                "\nThe following chains are in the HypersyncNetwork enum but not in the API \
             (remove the HypersyncNetwork subEnum from the chain_helpers.rs file):"
            );
            for chain in extra_chains {
                println!("- {}", chain);
            }
        }
    }
}

pub async fn run() -> Result<()> {
    let diff = get_diff().await?;
    print_diff_message(diff);
    Ok(())
}
