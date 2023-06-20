use std::error::Error;

use super::{InitArgs, Language, Template};

use inquire::{Select, Text};

pub struct InitInteractive {
    pub directory: String,
    pub template: Template,
    pub language: Language,
    pub subgraph_id: String,
}

impl InitArgs {
    pub fn get_init_args_interactive(&self) -> Result<InitInteractive, Box<dyn Error>> {
        let directory = self.directory.clone();

        let template = match &self.template {
            Some(args_template) => args_template.clone(),
            None => {
                use Template::Blank;
                use Template::Erc20;
                use Template::Greeter;
                use Template::SubgraphMigration;

                let options = vec![Blank, Greeter, Erc20, SubgraphMigration]
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

        let language = match &self.language {
            Some(args_language) => args_language.clone(),
            None => {
                use Language::{Javascript, Rescript, Typescript};

                let options = vec![Javascript, Typescript, Rescript]
                    .iter()
                    .map(|language| {
                        serde_json::to_string(language).expect("Enum should be serializable")
                    })
                    .collect::<Vec<String>>();

                let input_language =
                    Select::new("Which language would you like to use?", options).prompt()?;

                let chosen_language = serde_json::from_str(&input_language)?;
                chosen_language
            }
        };

        let subgraph_id = match &template {
            Template::SubgraphMigration => {
                let input_subgraph_id =
                    Text::new("[BETA VERSION] What is the subgraph ID?").prompt().unwrap();
                    
                input_subgraph_id
            }
            _ => "".to_string(),
        };

        Ok(InitInteractive {
            directory,
            template,
            language,
            subgraph_id,
        })
    }
}
