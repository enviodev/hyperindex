use crate::{
    clap_definitions::fuel::{InitFlow as ClapInitFlow, TemplateArgs},
    init_config::fuel::{InitFlow, Template},
};
use anyhow::{Context, Result};
use inquire::Select;
use strum::IntoEnumIterator;

use super::prompt_template;

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

// pub fn prompt_contract_import_init_flow(_args: ContractImportArgs) -> Result<InitFlow> {
//     Ok(InitFlow::ContractImport(vec![ContractImportSelection {
//         abi_file_path: "TODO: abi_file_path".to_string(),
//         name: "TODO: Name".to_string(),
//         events: vec![],
//     }]))
// }
