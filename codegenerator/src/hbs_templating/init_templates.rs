use regex::Regex;
use serde::Serialize;

use crate::cli_args;

#[derive(Serialize)]
pub struct InitTemplates {
    project_name: String,
    is_rescript: bool,
    is_typescript: bool,
    is_javascript: bool,
    envio_version: String,
}

impl InitTemplates {
    pub fn new(project_name: String, lang: &cli_args::Language) -> Self {
        let crate_version = env!("CARGO_PKG_VERSION");

        let envio_version = if is_valid_release_version_number(crate_version) {
            //Check that crate version is not a dev release. In which case the
            //version should be installable from npm
            crate_version.to_string()
        } else {
            //Else install the latest version from npm so as not to break dev environments
            "latest".to_string()
        };

        let template = InitTemplates {
            project_name,
            is_rescript: false,
            is_typescript: false,
            is_javascript: false,
            envio_version,
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

//Validates version name (3 digits separated by period ".")
//Returns false if there are any additional chars as this should imply
//it is a dev release version or an unstable release
fn is_valid_release_version_number(version: &str) -> bool {
    let re_version_pattern =
        Regex::new(r"^\d+\.\d+\.\d+$").expect("version regex pattern should be valid regex");
    re_version_pattern.is_match(version)
}

#[cfg(test)]
mod test {

    #[test]
    fn test_valid_version_numbers() {
        let valid_version_numbers = vec!["0.0.0", "999.999.999", "0.0.1", "10.2.3"];

        for vn in valid_version_numbers {
            assert_eq!(super::is_valid_release_version_number(vn), true);
        }
    }

    #[test]
    fn test_invalid_version_numbers() {
        let invalid_version_numbers = vec![
            "v10.1.0",
            "0.1",
            "0.0.1-dev",
            "0.1.*",
            "^0.1.2",
            "0.0.1.2",
            "1..1",
            "1.1.",
            ".1.1",
            "1.1.1.",
        ];
        for vn in invalid_version_numbers {
            assert_eq!(super::is_valid_release_version_number(vn), false);
        }
    }
}
