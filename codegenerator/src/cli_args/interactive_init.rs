use std::error::Error;

use super::{InitArgs, Language, Template as InitTemplate};

use inquire::{Select, Text};

use serde::{Deserialize, Serialize};

pub enum TemplateOrSubgraphID {
    Template(InitTemplate),
    SubgraphID(String),
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
enum TemplateOrSubgraphPrompt {
    Template,
    SubgraphMigration,
}

pub struct InitInteractive {
    pub directory: String,
    pub template: TemplateOrSubgraphID,
    pub language: Language,
}

impl InitArgs {
    pub fn get_init_args_interactive(&self) -> Result<InitInteractive, Box<dyn Error>> {
        let directory = self.directory.clone();

        let template = match (&self.template, &self.subgraph_migration) {
            (None, None) => {
                use TemplateOrSubgraphPrompt::{SubgraphMigration, Template};
                //start prompt to determine whether user is migration from subgraph or starting from a template
                let user_response_options = vec![SubgraphMigration, Template]
                    .iter()
                    .map(|template| {
                        serde_json::to_string(template).expect("Enum should be serializable")
                    })
                    .collect::<Vec<String>>();

                let user_response = Select::new(
                    "Would you like to start from a template or migrate from a subgraph?",
                    user_response_options,
                )
                .prompt()?;

                let chosen_template_or_subgraph = serde_json::from_str(&user_response)?;

                match chosen_template_or_subgraph {
                    TemplateOrSubgraphPrompt::Template => {
                        use InitTemplate::{Blank, Erc20, Greeter};

                        let options = vec![Blank, Greeter, Erc20]
                            .iter()
                            .map(|template| {
                                serde_json::to_string(template)
                                    .expect("Enum should be serializable")
                            })
                            .collect::<Vec<String>>();

                        let input_template =
                            Select::new("Which template would you like to use?", options)
                                .prompt()?;

                        let chosen_template = serde_json::from_str(&input_template)?;
                        TemplateOrSubgraphID::Template(chosen_template)
                    }
                    TemplateOrSubgraphPrompt::SubgraphMigration => {
                        let input_subgraph_id =
                            Text::new("[BETA VERSION] What is the subgraph ID?").prompt()?;

                        TemplateOrSubgraphID::SubgraphID(input_subgraph_id)
                    }
                }
            }
            (Some(_), Some(cid)) => TemplateOrSubgraphID::SubgraphID(cid.clone()),
            (Some(args_template), None) => TemplateOrSubgraphID::Template(args_template.clone()),
            (None, Some(cid)) => TemplateOrSubgraphID::SubgraphID(cid.clone()),
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
        //
        // let subgraph_id = match &template {
        //     Template::SubgraphMigration => {
        //         let input_subgraph_id =
        //             Text::new("[BETA VERSION] What is the subgraph ID?").prompt().unwrap();
        //
        //         input_subgraph_id
        //     }
        //     _ => "".to_string(),
        // };

        Ok(InitInteractive {
            directory,
            template,
            language,
        })
    }
}
