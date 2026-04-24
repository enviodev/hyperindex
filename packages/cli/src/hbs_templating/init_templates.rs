use crate::{cli_args::init_config::Language, project_paths::ParsedProjectPaths};
use serde::Serialize;

#[derive(Serialize, Debug, PartialEq)]
pub struct InitTemplates {
    project_name: String,
    is_rescript: bool,
    is_typescript: bool,
    envio_version: String,
    envio_api_token: Option<String>,
    extra_dependencies: Vec<(String, String)>,
}

impl InitTemplates {
    pub fn new(
        project_name: String,
        lang: &Language,
        _project_paths: &ParsedProjectPaths,
        envio_version: String,
        envio_api_token: Option<String>,
        extra_dependencies: Vec<(String, String)>,
    ) -> anyhow::Result<Self> {
        Ok(InitTemplates {
            project_name,
            is_rescript: lang == &Language::ReScript,
            is_typescript: lang == &Language::TypeScript,
            envio_version,
            envio_api_token,
            extra_dependencies,
        })
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn test_new_init_template() {
        let init_temp = InitTemplates::new(
            "my-project".to_string(),
            &Language::ReScript,
            &ParsedProjectPaths::default(),
            "latest".to_string(),
            None,
            vec![],
        )
        .unwrap();

        let expected = InitTemplates {
            project_name: "my-project".to_string(),
            is_rescript: true,
            is_typescript: false,
            envio_version: "latest".to_string(),
            envio_api_token: None,
            extra_dependencies: vec![],
        };

        assert_eq!(expected, init_temp);
    }
}
