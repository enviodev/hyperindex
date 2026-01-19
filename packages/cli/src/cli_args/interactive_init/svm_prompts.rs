use crate::{
    clap_definitions::svm::TemplateArgs,
    cli_args::interactive_init::shared_prompts::prompt_template,
    init_config::svm::{InitFlow, Template},
};
use anyhow::Result;
use strum::IntoEnumIterator;

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
