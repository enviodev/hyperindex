use crate::{
    config_parsing::{chain_helpers::HypersyncChain, entity_parsing::MAX_PG_IDENTIFIER_LENGTH},
    evm::address::Address,
};
use alloy_json_abi::Event;
use anyhow::{Context, Result};
use std::fmt::{self, Display};

/// Normalizes a contract name by replacing spaces, hyphens, and dots with underscores.
pub fn normalize_contract_name(name: String) -> String {
    name.replace([' ', '-', '.'], "_")
}

/// Init names an entity `{contract}_{event}` for every imported event, and an
/// entity name is a Postgres table name. Cut the contract name just enough for
/// the longest event to fit. An event too long to fit on its own leaves the
/// name whole, so codegen reports the event itself.
pub fn fit_contract_name_to_events(
    name: String,
    event_names: impl IntoIterator<Item = impl AsRef<str>>,
) -> String {
    let longest_event_name = event_names
        .into_iter()
        .map(|event_name| event_name.as_ref().len())
        .max()
        .unwrap_or(0);
    let room = MAX_PG_IDENTIFIER_LENGTH.saturating_sub(longest_event_name + "_".len());
    if name.len() <= room || room == 0 {
        return name;
    }
    let fitted = name[..name.floor_char_boundary(room)].trim_end_matches('_');
    println!(
        "Contract name '{name}' is shortened to '{fitted}' so its entity names fit Postgres's \
         {MAX_PG_IDENTIFIER_LENGTH}-character limit."
    );
    fitted.to_string()
}

///The hierarchy is based on how you would add items to
///your selection as you go. Ie. Once you have constructed
///the selection of a contract you can add more addresses or
///chains
#[derive(Clone, Debug)]
pub struct SelectedContract {
    pub name: String,
    pub chains: Vec<ContractImportNetworkSelection>,
    pub events: Vec<Event>,
}

impl SelectedContract {
    pub fn new(
        name: String,
        network_selection: ContractImportNetworkSelection,
        events: Vec<Event>,
    ) -> Self {
        Self {
            name: fit_contract_name_to_events(
                normalize_contract_name(name),
                events.iter().map(|event| &event.name),
            ),
            chains: vec![network_selection],
            events,
        }
    }

    pub fn get_last_chain_mut(&mut self) -> Result<&mut ContractImportNetworkSelection> {
        self.chains
            .last_mut()
            .context("Failed to get the last select contract chain")
    }

    pub fn get_last_chain_name(&self) -> Result<String> {
        let network_selection = self
            .chains
            .last()
            .context("Failed to get the last select contract chain")?;
        Ok(network_selection.network.to_string())
    }

    pub fn get_chain_ids(&self) -> Vec<u64> {
        self.chains
            .iter()
            .map(|n| n.network.get_network_id())
            .collect()
    }
}

#[derive(Clone, Debug)]
pub enum NetworkKind {
    Supported(HypersyncChain),
    Unsupported {
        network_id: u64,
        rpc_url: String,
        start_block: u64,
    },
}

impl NetworkKind {
    pub fn get_network_id(&self) -> u64 {
        match self {
            Self::Supported(n) => *n as u64,
            Self::Unsupported { network_id, .. } => *network_id,
        }
    }
    pub fn get_start_block(&self) -> u64 {
        match self {
            Self::Supported(_) => 0,
            Self::Unsupported { start_block, .. } => *start_block,
        }
    }
    pub fn uses_hypersync(&self) -> bool {
        match self {
            Self::Supported(_) => true,
            Self::Unsupported { .. } => false,
        }
    }
}

impl Display for NetworkKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self {
            Self::Supported(n) => write!(f, "{}", n),
            Self::Unsupported { network_id, .. } => write!(f, "{}", network_id),
        }
    }
}

#[derive(Clone, Debug)]
pub struct ContractImportNetworkSelection {
    pub network: NetworkKind,
    pub addresses: Vec<Address>,
}

impl ContractImportNetworkSelection {
    pub fn new(network: NetworkKind, address: Address) -> Self {
        Self {
            network,
            addresses: vec![address],
        }
    }

    pub fn new_without_addresses(network: NetworkKind) -> Self {
        Self {
            network,
            addresses: vec![],
        }
    }

    pub fn uses_hypersync(&self) -> bool {
        self.network.uses_hypersync()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_contract_name() {
        // Spaces are replaced with underscores
        assert_eq!(
            normalize_contract_name("Yearn V3 Vault".to_string()),
            "Yearn_V3_Vault"
        );

        // Hyphens are replaced with underscores
        assert_eq!(
            normalize_contract_name("Uniswap-V3".to_string()),
            "Uniswap_V3"
        );

        // Dots are replaced with underscores
        assert_eq!(
            normalize_contract_name("Token.Contract".to_string()),
            "Token_Contract"
        );

        // Multiple special characters
        assert_eq!(
            normalize_contract_name("My-Contract.Name V2".to_string()),
            "My_Contract_Name_V2"
        );

        // Already valid name remains unchanged
        assert_eq!(
            normalize_contract_name("ValidContractName".to_string()),
            "ValidContractName"
        );

        // Underscores are preserved
        assert_eq!(
            normalize_contract_name("Valid_Contract_Name".to_string()),
            "Valid_Contract_Name"
        );
    }

    // https://github.com/enviodev/hyperindex/issues/794
    #[test]
    fn a_long_contract_name_is_cut_so_every_entity_name_fits_postgres() {
        let aave_pool = "InitializableImmutableAdminUpgradeabilityProxy";
        let entity_name = |contract: &str, event: &str| format!("{contract}_{event}");
        let longest_aave_event = "ReserveUsedAsCollateralDisabled";
        let fitted_for_aave =
            fit_contract_name_to_events(aave_pool.to_string(), ["Supply", longest_aave_event]);
        let fitted_for_long_event = fit_contract_name_to_events(
            aave_pool.to_string(),
            ["OwnershipTransferRequestedWithMessage"],
        );
        assert_eq!(
            (
                fitted_for_aave.as_str(),
                entity_name(&fitted_for_aave, longest_aave_event).len(),
                fitted_for_long_event.as_str(),
                fit_contract_name_to_events(aave_pool.to_string(), ["Supply"]),
                fit_contract_name_to_events("Pool".to_string(), ["Supply"]),
            ),
            (
                "InitializableImmutableAdminUpgr",
                63,
                "InitializableImmutableAdm",
                aave_pool.to_string(),
                "Pool".to_string(),
            )
        );
    }

    #[test]
    fn a_cut_contract_name_drops_a_trailing_separator_and_never_splits_a_character() {
        assert_eq!(
            (
                fit_contract_name_to_events(format!("{}_Proxy", "A".repeat(29)), ["E".repeat(32)]),
                fit_contract_name_to_events(format!("{}éé", "A".repeat(28)), ["E".repeat(31)]),
                fit_contract_name_to_events("Pool".to_string(), ["E".repeat(70)]),
            ),
            (
                "A".repeat(29),
                format!("{}é", "A".repeat(28)),
                "Pool".to_string(),
            )
        );
    }
}
