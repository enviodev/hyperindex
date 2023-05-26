use std::error::Error;

use super::{InitArgs, JsFlavor, Template};

use inquire::Select;

pub struct InitInteractive {
    pub directory: String,
    pub template: Template,
    pub js_flavor: JsFlavor,
}

impl InitArgs {
    pub fn get_init_args_interactive(&self) -> Result<InitInteractive, Box<dyn Error>> {
        let directory = self.directory.clone();

        let template = match &self.template {
            Some(args_template) => args_template.clone(),
            None => {
                use Template::Greeter;

                let options = vec![Greeter]
                    .iter()
                    .map(|template| {
                        serde_json::to_string(template).expect("Enum should be serializable")
                    })
                    .collect::<Vec<String>>();

                let input_template =
                    Select::new("Which template would you like to use?", options).prompt()?;

                let chosen_template = serde_json::from_str(&input_template)?;
                chosen_template
            }
        };

        let js_flavor = match &self.js_flavor {
            Some(args_js_flavor) => args_js_flavor.clone(),
            None => {
                use JsFlavor::{Javascript, Rescript, Typescript};

                let options = vec![Javascript, Typescript, Rescript]
                    .iter()
                    .map(|flavor| {
                        serde_json::to_string(flavor).expect("Enum should be serializable")
                    })
                    .collect::<Vec<String>>();

                let input_flavor =
                    Select::new("Which javascript flavor would you like to use?", options)
                        .prompt()?;

                let chosen_flavor = serde_json::from_str(&input_flavor)?;
                chosen_flavor
            }
        };

        Ok(InitInteractive {
            directory,
            template,
            js_flavor,
        })
    }
}
