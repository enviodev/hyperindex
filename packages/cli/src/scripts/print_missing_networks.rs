use crate::config_parsing::chain_helpers::{GraphNetwork, HypersyncChain, NetworkWithExplorer};
use anyhow::Result;
use convert_case::{Case, Casing};
use reqwest;
use serde::Deserialize;
use std::collections::HashSet;
use strum::IntoEnumIterator;

const HIDDEN_TIERS: &[&str] = &["INTERNAL", "HIDDEN", "EXPERIMENTAL"];

#[derive(Deserialize, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Ecosystem {
    Evm,
    Fuel,
}

#[derive(Deserialize, Debug)]
struct Chain {
    name: String,
    chain_id: Option<u64>, // None for Fuel testnet chain
    tier: Option<String>,
    ecosystem: Ecosystem,
}

impl Chain {
    fn is_public(&self) -> bool {
        match &self.tier {
            Some(tier) => !HIDDEN_TIERS.contains(&tier.as_str()),
            None => true,
        }
    }
}

pub struct Diff {
    pub missing_chains: Vec<String>,
    pub extra_chains: Vec<String>,
}

impl Diff {
    pub async fn get() -> Result<Self> {
        let url = "https://chains.hyperquery.xyz/active_chains";
        let response = reqwest::get(url).await?;
        let chains: Vec<Chain> = response.json::<Vec<Chain>>().await?;

        let mut api_chain_ids = HashSet::new();
        let mut missing_chains = Vec::new();

        let public_chains = chains
            .into_iter()
            .filter(|c| c.name != *"gnosis-traces" && c.is_public());

        for chain in public_chains {
            let Some(chain_id) = chain.chain_id else {
                continue;
            };
            match chain.ecosystem {
                Ecosystem::Evm => (),
                // Skip Fuel
                Ecosystem::Fuel => continue,
            }

            api_chain_ids.insert(chain_id);

            if HypersyncChain::from_repr(chain_id).is_none() {
                let subenums = vec![
                    Some("HypersyncChain"),
                    NetworkWithExplorer::from_repr(chain_id).map(|_| "NetworkWithExplorer"),
                    GraphNetwork::from_repr(chain_id).map(|_| "GraphNetwork"),
                ]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>()
                .join(", ");

                missing_chains.push(format!(
                    "    #[subenum({})]\n    {} = {},",
                    subenums,
                    chain.name.to_case(Case::Pascal),
                    chain_id
                ));
            }
        }

        let mut extra_chains = Vec::new();
        for network in HypersyncChain::iter() {
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
        })
    }

    pub fn is_empty(&self) -> bool {
        self.missing_chains.is_empty() && self.extra_chains.is_empty()
    }

    pub fn print_message(&self) {
        if self.is_empty() {
            println!(
                "All chains from the API are present in the HypersyncChain enum, and vice \
                 versa. Nothing to update."
            );
        } else {
            if !self.missing_chains.is_empty() {
                println!("\nThe following chains are missing from the Network enum:");
                for chain in &self.missing_chains {
                    println!("{}", chain);
                }
            }

            if !self.extra_chains.is_empty() {
                println!(
                    "\nThe following chains are in the HypersyncChain enum but not in the API \
                     (remove the HypersyncChain subEnum from the chain_helpers.rs file):"
                );
                for chain in &self.extra_chains {
                    println!("- {}", chain);
                }
            }
        }
    }
}

pub async fn run() -> Result<()> {
    Diff::get().await?.print_message();
    Ok(())
}
