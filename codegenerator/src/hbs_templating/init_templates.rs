use serde::Serialize;

use crate::cli_args;

#[derive(Serialize)]
pub struct InitTemplates {
    project_name: String,
    is_rescript: bool,
    is_typescript: bool,
    is_javascript: bool,
}

impl InitTemplates {
    pub fn new(project_name: String, lang: &cli_args::Language) -> Self {
        let template = InitTemplates {
            project_name,
            is_rescript: false,
            is_typescript: false,
            is_javascript: false,
        };

        use cli_args::Language;
        match lang {
            Language::Rescript => InitTemplates {
                is_rescript: true,
                ..template
            },

            Language::Typescript => InitTemplates {
                is_typescript: true,
                ..template
            },
            Language::Javascript => InitTemplates {
                is_javascript: true,
                ..template
            },
        }
    }
}
