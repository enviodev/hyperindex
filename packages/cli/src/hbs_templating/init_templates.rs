use super::env_template;
use crate::cli_args::init_config::Language;

#[derive(Debug, PartialEq)]
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
        envio_version: String,
        envio_api_token: Option<String>,
        extra_dependencies: Vec<(String, String)>,
    ) -> Self {
        InitTemplates {
            project_name,
            is_rescript: lang == &Language::ReScript,
            is_typescript: lang == &Language::TypeScript,
            envio_version,
            envio_api_token,
            extra_dependencies,
        }
    }

    pub fn render_env(&self) -> String {
        env_template::render(&self.envio_api_token)
    }

    pub fn render_package_json(&self) -> String {
        let mut out = String::new();
        out.push_str("{\n");
        out.push_str(&format!("  \"name\": \"{}\",\n", self.project_name));
        out.push_str("  \"version\": \"0.1.0\",\n");
        out.push_str("  \"type\": \"module\",\n");
        out.push_str("  \"scripts\": {\n");
        if self.is_rescript {
            out.push_str("    \"clean\": \"rescript clean\",\n");
            out.push_str("    \"build\": \"rescript\",\n");
            out.push_str("    \"watch\": \"rescript watch\",\n");
        }
        let build_prefix = if self.is_rescript {
            "pnpm build && "
        } else {
            ""
        };
        out.push_str("    \"codegen\": \"envio codegen\",\n");
        out.push_str(&format!("    \"dev\": \"{build_prefix}envio dev\",\n"));
        out.push_str(&format!("    \"start\": \"{build_prefix}envio start\",\n"));
        out.push_str(&format!(
            "    \"test\": \"{build_prefix}vitest run --test-timeout=20000\"\n"
        ));
        out.push_str("  },\n");
        out.push_str("  \"devDependencies\": {\n");
        if self.is_rescript {
            out.push_str("    \"rescript\": \"12.2.0\",\n");
            out.push_str("    \"@rescript/runtime\": \"12.2.0\",\n");
        }
        if self.is_typescript {
            out.push_str("    \"@types/node\": \"24.12.2\",\n");
            out.push_str("    \"typescript\": \"6.0.3\",\n");
        }
        out.push_str("    \"vitest\": \"4.1.0\"\n");
        out.push_str("  },\n");
        out.push_str("  \"dependencies\": {\n");
        out.push_str(&format!("    \"envio\": \"{}\"", self.envio_version));
        for (name, version) in &self.extra_dependencies {
            out.push_str(&format!(",\n    \"{name}\": \"{version}\""));
        }
        out.push_str("\n  },\n");
        out.push_str("  \"engines\": {\n");
        out.push_str("    \"node\": \">=22.0.0\"\n");
        out.push_str("  }\n");
        out.push_str("}\n");
        out
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use pretty_assertions::assert_eq;

    fn template(is_res: bool, ver: &str, deps: Vec<(String, String)>) -> InitTemplates {
        InitTemplates::new(
            "my-project".to_string(),
            if is_res {
                &Language::ReScript
            } else {
                &Language::TypeScript
            },
            ver.to_string(),
            None,
            deps,
        )
    }

    #[test]
    fn rescript_package_json_no_extra_deps() {
        assert_eq!(
            template(true, "latest", vec![]).render_package_json(),
            "{\n  \"name\": \"my-project\",\n  \"version\": \"0.1.0\",\n  \"type\": \"module\",\n  \"scripts\": {\n    \"clean\": \"rescript clean\",\n    \"build\": \"rescript\",\n    \"watch\": \"rescript watch\",\n    \"codegen\": \"envio codegen\",\n    \"dev\": \"pnpm build && envio dev\",\n    \"start\": \"pnpm build && envio start\",\n    \"test\": \"pnpm build && vitest run --test-timeout=20000\"\n  },\n  \"devDependencies\": {\n    \"rescript\": \"12.2.0\",\n    \"@rescript/runtime\": \"12.2.0\",\n    \"vitest\": \"4.1.0\"\n  },\n  \"dependencies\": {\n    \"envio\": \"latest\"\n  },\n  \"engines\": {\n    \"node\": \">=22.0.0\"\n  }\n}\n"
        );
    }

    #[test]
    fn typescript_package_json_no_extra_deps() {
        assert_eq!(
            template(false, "latest", vec![]).render_package_json(),
            "{\n  \"name\": \"my-project\",\n  \"version\": \"0.1.0\",\n  \"type\": \"module\",\n  \"scripts\": {\n    \"codegen\": \"envio codegen\",\n    \"dev\": \"envio dev\",\n    \"start\": \"envio start\",\n    \"test\": \"vitest run --test-timeout=20000\"\n  },\n  \"devDependencies\": {\n    \"@types/node\": \"24.12.2\",\n    \"typescript\": \"6.0.3\",\n    \"vitest\": \"4.1.0\"\n  },\n  \"dependencies\": {\n    \"envio\": \"latest\"\n  },\n  \"engines\": {\n    \"node\": \">=22.0.0\"\n  }\n}\n"
        );
    }

    #[test]
    fn package_json_with_extra_deps() {
        assert_eq!(
            template(
                true,
                "1.2.3",
                vec![
                    ("viem".to_string(), "2.54.0".to_string()),
                    ("foo".to_string(), "1.0.0".to_string())
                ]
            )
            .render_package_json(),
            "{\n  \"name\": \"my-project\",\n  \"version\": \"0.1.0\",\n  \"type\": \"module\",\n  \"scripts\": {\n    \"clean\": \"rescript clean\",\n    \"build\": \"rescript\",\n    \"watch\": \"rescript watch\",\n    \"codegen\": \"envio codegen\",\n    \"dev\": \"pnpm build && envio dev\",\n    \"start\": \"pnpm build && envio start\",\n    \"test\": \"pnpm build && vitest run --test-timeout=20000\"\n  },\n  \"devDependencies\": {\n    \"rescript\": \"12.2.0\",\n    \"@rescript/runtime\": \"12.2.0\",\n    \"vitest\": \"4.1.0\"\n  },\n  \"dependencies\": {\n    \"envio\": \"1.2.3\",\n    \"viem\": \"2.54.0\",\n    \"foo\": \"1.0.0\"\n  },\n  \"engines\": {\n    \"node\": \">=22.0.0\"\n  }\n}\n"
        );
    }

    #[test]
    fn test_new_init_template() {
        let init_temp = InitTemplates::new(
            "my-project".to_string(),
            &Language::ReScript,
            "latest".to_string(),
            None,
            vec![],
        );

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
