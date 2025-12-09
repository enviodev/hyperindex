use crate::{
    clap_definitions::solana::{InitFlow as ClapInitFlow, TemplateArgs},
    init_config::solana::{InitFlow, Template},
};
use anyhow::Result;

pub fn prompt_init_flow_missing(maybe_init_flow: Option<ClapInitFlow>) -> Result<ClapInitFlow> {
    let init_flow = match maybe_init_flow {
        Some(f) => f,
        None => {
            // let flow_option = ClapInitFlow::iter().collect();
            // Select::new("Choose an initialization option", flow_option)
            //     .prompt()
            //     .context("Failed prompting for Solana initialization option")?
            ClapInitFlow::Template(TemplateArgs { template: None })
        }
    };
    Ok(init_flow)
}

pub fn prompt_template_init_flow(args: TemplateArgs) -> Result<InitFlow> {
    let chosen_template = match args.template {
        Some(template) => template,
        None => {
            // let options = Template::iter().collect();
            // prompt_template(options)?
            Template::FeatureSolanaBlockHandler
        }
    };
    Ok(InitFlow::Template(chosen_template))
}
