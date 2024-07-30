use super::etherscan_helpers::fetch_contract_auto_selection_from_etherscan;
use crate::{
    config_parsing::chain_helpers::{HypersyncNetwork, NetworkWithExplorer},
    evm::address::Address,
};
use anyhow::{Context, Result};
use std::fmt::{self, Display};

///The hierarchy is based on how you would add items to
///your selection as you go. Ie. Once you have constructed
///the selection of a contract you can add more addresses or
///networks
#[derive(Clone, Debug)]
pub struct SelectedContract {
    pub name: String,
    pub networks: Vec<ContractImportNetworkSelection>,
    pub events: Vec<ethers::abi::Event>,
}

impl SelectedContract {
    pub fn new(
        name: String,
        network_selection: ContractImportNetworkSelection,
        events: Vec<ethers::abi::Event>,
    ) -> Self {
        Self {
            name,
            networks: vec![network_selection],
            events,
        }
    }

    pub fn get_last_network_mut(&mut self) -> Result<&mut ContractImportNetworkSelection> {
        self.networks
            .last_mut()
            .context("Failed to get the last select contract network")
    }

    pub fn get_last_network_name(&self) -> Result<String> {
        let network_selection = self
            .networks
            .last()
            .context("Failed to get the last select contract network")?;
        Ok(network_selection.network.to_string())
    }

    pub async fn from_etherscan(
        network: &NetworkWithExplorer,
        address: Address,
    ) -> anyhow::Result<Self> {
        fetch_contract_auto_selection_from_etherscan(address, network).await
    }

    pub fn get_network_ids(&self) -> Vec<u64> {
        self.networks
            .iter()
            .map(|n| n.network.get_network_id())
            .collect()
    }
}

type NetworkId = u64;
type RpcUrl = String;

#[derive(Clone, Debug)]
pub enum NetworkKind {
    Supported(HypersyncNetwork),
    Unsupported(NetworkId, RpcUrl),
}

impl NetworkKind {
    pub fn get_network_id(&self) -> NetworkId {
        match self {
            Self::Supported(n) => n.clone() as u64,
            Self::Unsupported(n, _) => *n,
        }
    }

    pub fn uses_hypersync(&self) -> bool {
        match self {
            Self::Supported(_) => true,
            Self::Unsupported(_, _) => false,
        }
    }
}

impl Display for NetworkKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self {
            Self::Supported(n) => write!(f, "{}", n),
            Self::Unsupported(n, _) => write!(f, "{}", n),
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
