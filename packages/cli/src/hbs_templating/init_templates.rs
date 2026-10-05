use super::env_template;
use crate::cli_args::init_config::{Language, PackageManager};

/// `.github/workflows/test.yaml`, set up for the project's package manager.
pub fn render_test_workflow(pm: PackageManager) -> String {
    let setup = match pm {
        PackageManager::Pnpm => "      # Set up pnpm package manager
      # Update the version below if you need a different pnpm version
      - name: Setup pnpm
        uses: pnpm/action-setup@v4
        with:
          version: 10

      # Set up Node.js with caching for faster installs
      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 24
          cache: 'pnpm'
"
        .to_string(),
        PackageManager::Npm | PackageManager::Yarn => format!(
            "      # Set up Node.js with caching for faster installs
      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 24
          cache: '{}'
",
            pm.cmd()
        ),
        PackageManager::Bun => "      # Set up Node.js, which runs the indexer and its tests
      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 24

      # Set up Bun, which installs dependencies and runs the scripts
      - name: Setup Bun
        uses: oven-sh/setup-bun@v2
"
        .to_string(),
    };
    format!(
        "# GitHub Actions workflow for testing your Envio indexer
#
# This workflow runs your indexer tests on every push to main and on pull requests.
# It ensures your indexer code compiles correctly and all tests pass before merging.
#
# It runs the \"codegen\" and \"test\" scripts from package.json.
#
# Required: ENVIO_API_TOKEN
# Envio indexers use HyperSync as the default data source, which requires an Envio API token.
# Add ENVIO_API_TOKEN to your repository secrets before running this workflow.
# To add the secret: Repository Settings > Secrets and variables > Actions > New repository secret
# Get your token at: https://envio.dev

name: Test

on:
  # Run tests when code is pushed to main branch
  push:
    branches:
      - main
  # Run tests on all pull requests
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
      # Check out your repository code
      - name: Checkout code
        uses: actions/checkout@v4

{setup}
      # Install project dependencies
      - name: Install dependencies
        run: {install}

      # Generate indexer types
      # This step is required before running tests
      - name: Run codegen
        run: {codegen}
        env:
          ENVIO_API_TOKEN: ${{{{ secrets.ENVIO_API_TOKEN }}}}

      # Run your indexer tests using Vitest
      - name: Run tests
        run: {test}
        env:
          ENVIO_API_TOKEN: ${{{{ secrets.ENVIO_API_TOKEN }}}}
",
        install = pm.install_command(),
        codegen = pm.run_script_command("codegen"),
        test = pm.run_script_command("test"),
    )
}

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
        // `rescript` itself rather than the build script, so running these
        // doesn't need any one package manager.
        let build_prefix = if self.is_rescript { "rescript && " } else { "" };
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
        out.push_str("    \"node\": \">=22.15.0\"\n");
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
    fn test_workflow_for_each_package_manager() {
        use crate::cli_args::init_config::PackageManager;
        for pm in [
            PackageManager::Pnpm,
            PackageManager::Npm,
            PackageManager::Yarn,
            PackageManager::Bun,
        ] {
            insta::assert_snapshot!(format!("test_workflow_{pm}"), render_test_workflow(pm));
        }
    }

    #[test]
    fn rescript_package_json_no_extra_deps() {
        insta::assert_snapshot!(template(true, "latest", vec![]).render_package_json());
    }

    #[test]
    fn typescript_package_json_no_extra_deps() {
        insta::assert_snapshot!(template(false, "latest", vec![]).render_package_json());
    }

    #[test]
    fn package_json_with_extra_deps() {
        insta::assert_snapshot!(template(
            true,
            "1.2.3",
            vec![
                ("viem".to_string(), "2.54.0".to_string()),
                ("foo".to_string(), "1.0.0".to_string())
            ]
        )
        .render_package_json());
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
