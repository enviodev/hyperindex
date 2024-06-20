use crate::{
    clap_definitions::fuel::{
        ContractImportArgs, InitFlow as ClapInitFlow, LocalImportArgs, LocalOrExplorerImport,
        TemplateArgs,
    },
    fuel::abi::Abi,
    init_config::fuel::{ContractImportSelection, InitFlow, SelectedContract, Template},
};
use anyhow::{Context, Result};
use inquire::{validator::Validation, Select};
use strum::IntoEnumIterator;

use super::{prompt_abi_file_path, prompt_contract_address, prompt_contract_name, prompt_template};

pub fn prompt_init_flow_missing(maybe_init_flow: Option<ClapInitFlow>) -> Result<ClapInitFlow> {
    let init_flow = match maybe_init_flow {
        Some(f) => f,
        None => {
            let flow_option = ClapInitFlow::iter().collect();
            Select::new("Choose an initialization option", flow_option)
                .prompt()
                .context("Failed prompting for Fuel initialization option")?
        }
    };
    Ok(init_flow)
}

pub fn prompt_template_init_flow(args: TemplateArgs) -> Result<InitFlow> {
    let chosen_template = match args.template {
        Some(template) => template,
        None => {
            let options = Template::iter().collect();
            prompt_template(options)?
        }
    };
    Ok(InitFlow::Template(chosen_template))
}

///Takes either the "local" or "explorer" subcommand from the cli args
///or prompts for a choice from the user (not supported by Fuel yet)
fn get_local_or_explorer_import(args: ContractImportArgs) -> LocalOrExplorerImport {
    match args.local_or_explorer {
        Some(v) => v,
        None => LocalOrExplorerImport::Local(LocalImportArgs {
            abi_file: None,
            contract_name: None,
        }),
    }
}

///Internal function to get the abi path from the cli args or prompt for
///a file path to the abi
fn get_abi_path_string(local_import_args: &LocalImportArgs) -> Result<String> {
    match &local_import_args.abi_file {
        Some(p) => Ok(p.clone()),
        None => prompt_abi_file_path(|path| {
            let maybe_parsed_abi = Abi::parse(&path.to_string());
            match maybe_parsed_abi {
                Ok(_) => Validation::Valid,
                Err(e) => Validation::Invalid(e.into()),
            }
        }),
    }
}

///Prompts for a contract name
fn get_contract_name(local_import_args: &LocalImportArgs) -> Result<String> {
    match &local_import_args.contract_name {
        Some(n) => Ok(n.clone()),
        None => prompt_contract_name(),
    }
}

//Constructs SelectedContract via local prompt. Uses abis and manual
//network/contract config
async fn get_contract_import_selection_from_local_import_args(
    local_import_args: &LocalImportArgs,
) -> Result<SelectedContract> {
    let abi_path_string =
        get_abi_path_string(&local_import_args).context("Failed getting Fuel ABI path")?;
    let abi = Abi::parse(&abi_path_string).context("Failed parsing Fuel ABI")?;

    let selected_logs = abi.get_logs();

    let name = get_contract_name(local_import_args).context("Failed getting contract name")?;

    let address = prompt_contract_address(None)?;

    Ok(SelectedContract {
        name,
        address,
        abi,
        selected_logs,
    })
}

pub async fn prompt_contract_import_init_flow(args: ContractImportArgs) -> Result<InitFlow> {
    let local_or_explorer_import = get_local_or_explorer_import(args);
    let contract_import_selection = match local_or_explorer_import {
        LocalOrExplorerImport::Local(local_import_args) => {
            get_contract_import_selection_from_local_import_args(&local_import_args)
                .await
                .context("Failed getting local contract selection")?
        }
    };
    Ok(InitFlow::ContractImport(ContractImportSelection {
        contracts: vec![contract_import_selection],
    }))
}
