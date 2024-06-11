use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use strum::{Display, EnumIter, EnumString};

use crate::config_parsing::contract_import::converters::AutoConfigSelection;

#[derive(Clone, Debug, ValueEnum, Serialize, Deserialize, EnumIter, EnumString, Display)]
///Template to work off
pub enum EvmTemplate {
    Greeter,
    Erc20,
}

#[derive(Clone, Debug, Display)]
pub enum EvmInitFlow {
    Template(EvmTemplate),
    SubgraphID(String),
    ContractImport(AutoConfigSelection),
}

#[derive(Clone, Debug, ValueEnum, Serialize, Deserialize, EnumIter, EnumString, Display)]
///Template to work off
pub enum FuelTemplate {
    Greeter,
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

#[derive(
    Clone, Debug, ValueEnum, Serialize, Deserialize, EnumIter, EnumString, PartialEq, Eq, Display,
)]
///Which language do you want to write in?
pub enum Language {
    #[clap(name = "javascript")]
    JavaScript,
    #[clap(name = "typescript")]
    TypeScript,
    #[clap(name = "rescript")]
    ReScript,
}

#[derive(Clone, Debug)]
pub struct InitConfig {
    pub name: String,
    pub directory: String,
    pub ecosystem: Ecosystem,
    pub language: Language,
}
