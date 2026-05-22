use anyhow::{anyhow, Result};
use std::str::FromStr;

use crate::config_parsing::chain_helpers::Network;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChainKind {
    Evm,
    Fuel,
}

#[derive(Debug, Clone)]
pub struct Chain {
    pub kind: ChainKind,
    pub base_url: String,
    pub display: String,
}

pub fn resolve(input: &str) -> Result<Chain> {
    let normalized = input.trim().to_ascii_lowercase();

    if normalized == "solana" || normalized == "svm" {
        return Err(anyhow!(
            "`--chain={input}` is not supported yet.\n\
             Solana support is on the roadmap. For now use an EVM chain (e.g. `--chain=base`) or Fuel (`--chain=fuel`).",
        ));
    }

    if normalized == "fuel" {
        return Ok(Chain {
            kind: ChainKind::Fuel,
            base_url: "https://fuel.hypersync.xyz".to_string(),
            display: "fuel".to_string(),
        });
    }

    if normalized == "fuel-testnet" {
        return Ok(Chain {
            kind: ChainKind::Fuel,
            base_url: "https://fuel-testnet.hypersync.xyz".to_string(),
            display: "fuel-testnet".to_string(),
        });
    }

    let chain_id = if let Ok(id) = normalized.parse::<u64>() {
        id
    } else {
        let network = Network::from_str(&normalized).map_err(|_| {
            anyhow!(
                "Unknown chain `{input}`. Pass a numeric chain id (e.g. `--chain=8453`),\n\
                 a kebab-case network name (e.g. `--chain=base`, `--chain=arbitrum-one`),\n\
                 or `--chain=fuel` / `--chain=fuel-testnet`."
            )
        })?;
        network.get_network_id()
    };

    Ok(Chain {
        kind: ChainKind::Evm,
        base_url: format!("https://{chain_id}.hypersync.xyz"),
        display: chain_id.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_evm_by_name() {
        let c = resolve("base").unwrap();
        assert_eq!(
            (c.kind, c.base_url.as_str(), c.display.as_str()),
            (ChainKind::Evm, "https://8453.hypersync.xyz", "8453")
        );
    }

    #[test]
    fn resolves_evm_by_id() {
        let c = resolve("42161").unwrap();
        assert_eq!(
            (c.kind, c.base_url.as_str(), c.display.as_str()),
            (ChainKind::Evm, "https://42161.hypersync.xyz", "42161")
        );
    }

    #[test]
    fn resolves_fuel_mainnet() {
        let c = resolve("fuel").unwrap();
        assert_eq!(
            (c.kind, c.base_url.as_str()),
            (ChainKind::Fuel, "https://fuel.hypersync.xyz")
        );
    }

    #[test]
    fn resolves_fuel_testnet() {
        let c = resolve("FUEL-TESTNET").unwrap();
        assert_eq!(
            (c.kind, c.base_url.as_str()),
            (ChainKind::Fuel, "https://fuel-testnet.hypersync.xyz")
        );
    }

    #[test]
    fn solana_errors_with_hint() {
        let err = resolve("solana").unwrap_err().to_string();
        assert!(
            err.contains("not supported yet") && err.contains("fuel"),
            "{err}",
        );
    }

    #[test]
    fn unknown_chain_errors_with_examples() {
        let err = resolve("bogus-network").unwrap_err().to_string();
        assert!(
            err.contains("--chain=base") && err.contains("--chain=fuel"),
            "{err}",
        );
    }
}
