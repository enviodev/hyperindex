use crate::config_parsing::chain_helpers::{
    ChainTier, GraphNetwork, HypersyncNetwork, NetworkWithExplorer,
};
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
    tier: Option<ChainTier>,
}

pub struct Diff {
    pub missing_tiers: Vec<String>,
    pub missing_chains: Vec<String>,
    pub extra_chains: Vec<String>,
    pub incorrect_tiers: Vec<String>,
}

impl Diff {
    pub async fn get() -> Result<Self> {
        let url = "https://chains.hyperquery.xyz/active_chains";
        let response = reqwest::get(url).await?;
        let chains: Vec<Chain> = response.json().await?;

        let mut api_chain_ids = HashSet::new();

        let mut missing_chains = Vec::new();
        let mut missing_tiers = Vec::new();
        let mut incorrect_tiers = Vec::new();

        let public_chains = chains.into_iter().filter(|c| match &c.tier {
            Some(tier) => tier.is_public(),
            None => true,
        });

        for chain in public_chains {
            let Some(chain_id) = chain.chain_id else {
                // Fuel chains don't have a chain_id
                continue;
            };

            api_chain_ids.insert(chain_id);

            let Some(hypersync_network) = HypersyncNetwork::from_repr(chain_id) else {
                let subenums = vec![
                    Some("HypersyncNetwork"),
                    NetworkWithExplorer::from_repr(chain_id).map(|_| "NetworkWithExplorer"),
                    GraphNetwork::from_repr(chain_id).map(|_| "GraphNetwork"),
                ]
                .into_iter()
                .filter_map(|s| s)
                .collect::<Vec<_>>()
                .join(", ");

                missing_chains.push(format!(
                    "    #[subenum({})]\n    {} = {},",
                    subenums,
                    chain.name.to_case(Case::Pascal),
                    chain_id
                ));

                continue;
            };

            let Some(tier) = chain.tier else {
                missing_tiers.push(chain.name.clone());
                continue;
            };

            if tier != hypersync_network.get_tier() {
                let network_name = hypersync_network.get_plain_name();
                let current_tier = hypersync_network.get_tier();
                incorrect_tiers.push(format!("{network_name}: {current_tier} -> {tier}",));
            }
        }

        let mut extra_chains = Vec::new();
        for network in HypersyncNetwork::iter() {
            let network_id = network as u64;
            if !api_chain_ids.contains(&network_id) {
                extra_chains.push(format!(
                    "{:?} (ID: {})",
                    network.get_plain_name(),
                    network_id
                ));
            }
        }

        Ok(Self {
            missing_chains,
            extra_chains,
            missing_tiers,
            incorrect_tiers,
        })
    }

    pub fn is_empty(&self) -> bool {
        let Self {
            missing_chains,
            extra_chains,
            missing_tiers,
            incorrect_tiers,
        } = self;

        vec![missing_chains, extra_chains, missing_tiers, incorrect_tiers]
            .iter()
            .all(|v| v.is_empty())
    }

    pub fn print_message(&self) {
        let Self {
            missing_chains,
            extra_chains,
            missing_tiers,
            incorrect_tiers,
        } = self;
        if self.is_empty() {
            println!(
            "All chains from the API are present in the HypersyncNetwork enum, and vice versa. \
         Nothing to update."
        );
        } else {
            if !missing_chains.is_empty() {
                println!("\nThe following chains are missing from the Network enum:");
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

            if !missing_tiers.is_empty() {
                println!("\nThe following chains do not have a defined tier in the API:");
                for tier in missing_tiers {
                    println!("- {}", tier);
                }
            }

            if !incorrect_tiers.is_empty() {
                println!(
                    "\nThe following chains have a tier that does not match the tier in the API:"
                );
                for tier in incorrect_tiers {
                    println!("- {}", tier);
                }
            }
        }
    }
}

pub async fn run() -> Result<()> {
    Diff::get().await?.print_message();
    Ok(())
}
