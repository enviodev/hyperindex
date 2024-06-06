use strum::{Display, EnumIter};

use crate::config_parsing::contract_import::converters::AutoConfigSelection;

pub trait Template {
    fn to_dir_name(self: &Self) -> String;
}

#[derive(Clone, Debug, Display, EnumIter)]
pub enum EvmTemplate {
    Greeter,
    Erc20,
}

impl Template for EvmTemplate {
    fn to_dir_name(self: &Self) -> String {
        self.to_string().to_lowercase()
    }
}

#[derive(Clone, Debug, Display)]
pub enum EvmInitFlow {
    Template(EvmTemplate),
    SubgraphID(String),
    ContractImportWithArgs(AutoConfigSelection),
}

#[derive(Clone, Debug, Display, EnumIter)]
pub enum FuelTemplate {
    Greeter,
}

impl Template for FuelTemplate {
    fn to_dir_name(self: &Self) -> String {
        match self {
            FuelTemplate::Greeter => "greeteronfuel".to_string(),
        }
    }
}

#[derive(Clone, Debug, Display)]
pub enum FuelInitFlow {
    Template(FuelTemplate),
}

#[derive(Clone, Debug, Display)]
pub enum Ecosystem {
    Evm { init_flow: EvmInitFlow },
    Fuel { init_flow: FuelInitFlow },
}

#[derive(Clone, Debug, Display, PartialEq, EnumIter)]
pub enum Language {
    JavaScript,
    TypeScript,
    ReScript,
}

#[derive(Clone, Debug)]
pub struct InitConfig {
    pub name: String,
    pub directory: String,
    pub ecosystem: Ecosystem,
    pub language: Language,
}
