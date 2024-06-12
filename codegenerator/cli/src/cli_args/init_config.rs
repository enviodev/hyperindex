use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use strum::{Display, EnumIter, EnumString};

pub mod evm {
    use clap::ValueEnum;
    use serde::{Deserialize, Serialize};
    use strum::{Display, EnumIter, EnumString};

    use crate::config_parsing::contract_import::converters::AutoConfigSelection;

    #[derive(Clone, Debug, ValueEnum, Serialize, Deserialize, EnumIter, EnumString, Display)]
    pub enum Template {
        Greeter,
        Erc20,
    }

    #[derive(Clone, Debug, Display)]
    pub enum InitFlow {
        Template(Template),
        SubgraphID(String),
        ContractImport(AutoConfigSelection),
    }
}

pub mod fuel {
    use clap::ValueEnum;
    use serde::{Deserialize, Serialize};
    use strum::{Display, EnumIter, EnumString};

    #[derive(Clone, Debug, ValueEnum, Serialize, Deserialize, EnumIter, EnumString, Display)]
    pub enum Template {
        Greeter,
    }

    #[derive(Clone, Debug, Display)]
    pub enum InitFlow {
        Template(Template),
    }
}

#[derive(Clone, Debug, Display)]
pub enum Ecosystem {
    Evm { init_flow: evm::InitFlow },
    Fuel { init_flow: fuel::InitFlow },
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
