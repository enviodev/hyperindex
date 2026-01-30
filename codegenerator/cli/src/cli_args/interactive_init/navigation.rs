use crate::cli_args::init_config::Language;
use crate::{
    config_parsing::{
        contract_import::converters::{
            ContractImportNetworkSelection, NetworkKind, SelectedContract as EvmSelectedContract,
        },
        human_config::fuel::EventConfig,
    },
    evm::address::Address as EvmAddress,
    fuel::{abi::FuelAbi, address::Address},
    init_config::fuel::{Network, SelectedContract as FuelSelectedContract},
};
use alloy_json_abi::Event as AlloyEvent;
use anyhow::Result;

// Reuse EcosystemOption from mod.rs instead of creating duplicate enum
use super::EcosystemOption;

pub struct PromptStack {
    pub entries: Vec<PromptStackEntry>
}

impl PromptStack {
    pub fn new() -> Self {
        Self {
            entries: Vec::new(),
        }
    }

    pub fn push(&mut self, entry: PromptStackEntry) {
        self.entries.push(entry);
    }

    pub fn pop(&mut self) -> Option<PromptStackEntry> {
        self.entries.pop()
    }
}

pub struct PromptStackEntry {
    pub step_name: PromptSteps,
}

#[derive(Clone, Debug, PartialEq)]
pub enum PromptSteps {
    FolderName,
    EcosystemSelection,
    ApiTokenOption,  // "Create" or "Add existing" selection
    ApiTokenInput,  // Text input for the actual token
    EvmInitOption,
    FuelInitOption,
    // Fuel contract import steps
    FuelContractAbiPath,
    FuelContractNetwork,
    FuelContractAddress,
    FuelContractName,
    FuelContractEvents,
    FuelAddAnotherContract,  // "Add another contract?" prompt
    // EVM contract import steps
    EvmContractAbiPath,  // If Local
    EvmContractNetwork,  // If Explorer
    EvmContractAddress,
    EvmContractName,
    EvmContractEvents,
    EvmAddAnotherContract,  // "Add another contract?" prompt
}

/// Result of a prompt that can include navigation actions
#[derive(Debug)]
pub enum PromptResult<T> {
    Value(T),
    Back,
}

pub struct InitConfigBuilder {
    pub name: Option<String>,
    pub directory: Option<String>,
    pub ecosystem: Option<EcosystemBuilder>,
    pub language: Option<Language>,
    pub api_token: Option<String>,
}

impl InitConfigBuilder {
    pub fn new() -> Self {
        Self {
            name: None,
            directory: None,
            ecosystem: None,
            language: None,
            api_token: None,
        }
    }
}

// Reuse EcosystemOption from mod.rs to track which ecosystem we're building for

/// Builder for Fuel contract import flow
/// Stores partial contract data as user fills it in
#[derive(Clone, Debug)]
pub struct FuelContractBuilder {
    pub abi_path: Option<String>,
    pub abi: Option<FuelAbi>,  // Parsed ABI (stored directly in Fuel)
    pub network: Option<Network>,  // Mainnet or Testnet
    pub addresses: Vec<Address>,  // Can have multiple addresses
    pub name: Option<String>,
    pub events: Option<Vec<EventConfig>>,
}

impl FuelContractBuilder {
    pub fn new() -> Self {
        Self {
            abi_path: None,
            abi: None,
            network: None,
            addresses: Vec::new(),
            name: None,
            events: None,
        }
    }

    /// Check if all required fields are filled to complete the contract
    pub fn is_complete(&self) -> bool {
        self.abi_path.is_some()
            && self.abi.is_some()
            && self.network.is_some()
            && !self.addresses.is_empty()
            && self.name.is_some()
            && self.events.is_some()
    }

    /// Convert to SelectedContract (only call when complete)
    pub fn to_selected_contract(self) -> Result<FuelSelectedContract> {
        if !self.is_complete() {
            return Err(anyhow::anyhow!("ContractBuilder is not complete"));
        }

        Ok(FuelSelectedContract {
            name: self.name.unwrap(),
            addresses: self.addresses,
            abi: self.abi.unwrap(),
            selected_events: self.events.unwrap(),
            network: self.network.unwrap(),
        })
    }
}

/// Builder for EVM contract import flow
/// Stores partial contract data as user fills it in
#[derive(Clone, Debug)]
pub struct EvmContractBuilder {
    pub import_type: Option<EvmImportType>,  // Local or Explorer
    pub abi_path: Option<String>,  // If Local
    pub abi: Option<alloy_json_abi::JsonAbi>,  // Parsed ABI (if Local or after Explorer fetch)
    pub network: Option<NetworkKind>,  // If Explorer or after network selection
    pub address: Option<EvmAddress>,
    pub name: Option<String>,
    pub events: Option<Vec<AlloyEvent>>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum EvmImportType {
    Local,
    Explorer,
}

impl EvmContractBuilder {
    pub fn new() -> Self {
        Self {
            import_type: None,
            abi_path: None,
            abi: None,
            network: None,
            address: None,
            name: None,
            events: None,
        }
    }

    /// Check if all required fields are filled to complete the contract
    pub fn is_complete(&self) -> bool {
        self.import_type.is_some()
            && self.address.is_some()
            && self.name.is_some()
            && self.events.is_some()
            && match self.import_type.as_ref().unwrap() {
                EvmImportType::Local => self.abi_path.is_some() && self.abi.is_some(),
                EvmImportType::Explorer => self.network.is_some(),
            }
    }

    /// Convert to SelectedContract (only call when complete)
    pub fn to_selected_contract(self) -> Result<EvmSelectedContract> {
        if !self.is_complete() {
            return Err(anyhow::anyhow!("EvmContractBuilder is not complete"));
        }

        let network = self.network.unwrap();
        let address = self.address.unwrap();
        let network_selection = ContractImportNetworkSelection::new(network, address);
        
        Ok(EvmSelectedContract::new(
            self.name.unwrap(),
            network_selection,
            self.events.unwrap(),
        ))
    }

    /// Convert from SelectedContract back to builder
    /// Takes the first chain's network and first address
    pub fn from_selected_contract(contract: &EvmSelectedContract) -> Result<Self> {
        let first_chain = contract.chains.first()
            .ok_or_else(|| anyhow::anyhow!("Contract has no chains"))?;
        let first_address = first_chain.addresses.first()
            .ok_or_else(|| anyhow::anyhow!("Contract chain has no addresses"))?;
        
        // Determine import type from ABI availability
        // If we have ABI path info, it's Local; otherwise assume Explorer
        // For now, we'll need to check if we can determine this from the contract
        // Since SelectedContract doesn't store import_type, we'll default to Explorer
        // and let the flow handle it
        
        Ok(Self {
            import_type: Some(EvmImportType::Explorer), // Default, will be set correctly in flow
            abi_path: None, // Can't recover this from SelectedContract
            abi: None, // Can't recover this from SelectedContract (would need to re-parse)
            network: Some(first_chain.network.clone()),
            address: Some(first_address.clone()),
            name: Some(contract.name.clone()),
            events: Some(contract.events.clone()),
        })
    }
}

/// Builder for ecosystem-specific contract data
/// Uses enum to handle different contract types for EVM vs Fuel
#[derive(Clone, Debug)]
pub enum ContractBuilder {
    Fuel(FuelContractBuilder),
    Evm(EvmContractBuilder),
}

impl ContractBuilder {
    pub fn new_fuel() -> Self {
        Self::Fuel(FuelContractBuilder::new())
    }

    pub fn new_evm() -> Self {
        Self::Evm(EvmContractBuilder::new())
    }
}

pub struct EcosystemBuilder {
    // For templates: just store the template
    pub template: Option<Template>,
    
    // Track which ecosystem we're building for (determines which contract type to use)
    pub ecosystem_type: Option<EcosystemOption>,
    
    // For Fuel contract import: store completed contracts
    // Only committed when user chooses "I'm finished" or "Add new contract"
    pub fuel_contracts: Vec<FuelSelectedContract>,
    
    // For EVM contract import: store completed contracts
    // Only committed when user chooses "I'm finished" or "Add new contract"
    pub evm_contracts: Vec<EvmSelectedContract>,
    
    // Current contract being built OR being edited
    // - If building new contract: contains partial/new contract data
    // - If editing existing (AddAddress/AddNetwork): contains the last contract being edited
    // - Only committed to `contracts` Vec when user chooses "I'm finished" or "Add new contract"
    pub current_contract: Option<ContractBuilder>,
    
    // Store the final completed Ecosystem when selection is done
    // This is set when user completes their selection (template or contracts)
    pub completed_ecosystem: Option<crate::init_config::Ecosystem>,
}

use crate::init_config::fuel::Template;

impl EcosystemBuilder {
    pub fn new() -> Self {
        Self {
            template: None,
            ecosystem_type: None,
            fuel_contracts: Vec::new(),
            evm_contracts: Vec::new(),
            current_contract: None,
            completed_ecosystem: None,
        }
    }

    /// Clear all contract data (used when going back to ecosystem selection)
    pub fn clear_contracts(&mut self) {
        self.fuel_contracts.clear();
        self.evm_contracts.clear();
        self.current_contract = None;
        self.ecosystem_type = None;
    }

    // Note: Methods for editing contracts when going back are reserved for future use
    // when implementing the "add another contract" flow with full back navigation support
}




