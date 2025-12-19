use crate::{
    clap_definitions::svm::{InitFlow as ClapInitFlow, TemplateArgs},
    cli_args::interactive_init::shared_prompts::prompt_template,
    init_config::svm::{InitFlow, Template},
};
use anyhow::{Context, Result};
use inquire::Select;
use strum::IntoEnumIterator;

pub fn prompt_init_flow_missing(maybe_init_flow: Option<ClapInitFlow>) -> Result<ClapInitFlow> {
    let init_flow = match maybe_init_flow {
        Some(f) => f,
        None => {
            let flow_option = ClapInitFlow::iter().collect();
            Select::new("Choose an initialization option", flow_option)
                .prompt()
                .context("Failed prompting for Svm initialization option")?
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
