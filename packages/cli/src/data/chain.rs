use anyhow::{anyhow, Result};
use std::str::FromStr;

use crate::config_parsing::chain_helpers::Network;

#[derive(Debug, Clone)]
pub struct Chain {
    pub base_url: String,
    pub display: String,
}

pub fn resolve(input: &str) -> Result<Chain> {
    let normalized = input.trim().to_ascii_lowercase();

    if normalized == "solana" || normalized == "svm" {
        return Err(anyhow!(
            "`--chain={input}` is not supported yet.\n\
             Solana support is on the roadmap. For now use an EVM chain (e.g. `--chain=base`).",
        ));
    }

    if normalized == "fuel" || normalized == "fuel-testnet" {
        return Err(anyhow!(
            "`--chain={input}` is not supported yet.\n\
             Fuel support is on the roadmap. For now use an EVM chain (e.g. `--chain=base`).",
        ));
    }

    let chain_id = if let Ok(id) = normalized.parse::<u64>() {
        id
    } else {
        let network = Network::from_str(&normalized).map_err(|_| {
            anyhow!(
                "Unknown chain `{input}`. Pass a numeric chain id (e.g. `--chain=8453`) or\n\
                 a kebab-case network name (e.g. `--chain=base`, `--chain=arbitrum-one`)."
            )
        })?;
        network.get_network_id()
    };

    Ok(Chain {
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
            (c.base_url.as_str(), c.display.as_str()),
            ("https://8453.hypersync.xyz", "8453")
        );
    }

    #[test]
    fn resolves_evm_by_id() {
        let c = resolve("42161").unwrap();
        assert_eq!(
            (c.base_url.as_str(), c.display.as_str()),
            ("https://42161.hypersync.xyz", "42161")
        );
    }

    #[test]
    fn fuel_errors_not_supported() {
        let err = resolve("fuel").unwrap_err().to_string();
        assert!(err.contains("not supported yet"), "{err}");
    }

    #[test]
    fn solana_errors_not_supported() {
        let err = resolve("solana").unwrap_err().to_string();
        assert!(err.contains("not supported yet"), "{err}");
    }

    #[test]
    fn unknown_chain_errors_with_examples() {
        let err = resolve("bogus-network").unwrap_err().to_string();
        assert!(err.contains("--chain=base"), "{err}");
    }
}
