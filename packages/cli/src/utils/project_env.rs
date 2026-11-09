use super::dotenv::{self, EnvMap};
use std::{
    cell::OnceCell,
    path::{Path, PathBuf},
};

/// Resolves environment variables the way the indexer runtime does: the process
/// environment wins, and anything unset there falls back to the project's
/// `.env`. The file values are cached on the first miss.
#[derive(Debug)]
pub struct ProjectEnv {
    dotenv: OnceCell<EnvMap>,
    project_root: PathBuf,
}

impl ProjectEnv {
    pub fn new(project_root: &Path) -> Self {
        ProjectEnv {
            dotenv: OnceCell::new(),
            project_root: PathBuf::from(project_root),
        }
    }

    pub fn var(&self, name: &str) -> Option<String> {
        if let Ok(val) = std::env::var(name) {
            return Some(val);
        }
        self.dotenv
            .get_or_init(|| {
                let path = self.project_root.join(".env");
                let values = dotenv::from_path(&path).or_else(|err| match err {
                    dotenv::Error::LineParse(_, _) => {
                        eprintln!("Warning: Ignoring invalid entries in .env");
                        dotenv::from_path_ignoring_invalid_lines(&path)
                    }
                    err => Err(err),
                });
                match values {
                    Ok(env_map) => env_map,
                    Err(err) => {
                        match err {
                            dotenv::Error::Io(_, _) => (),
                            _ => eprintln!(
                                "Warning: Failed loading .env file with unexpected error: {err}"
                            ),
                        };
                        EnvMap::new()
                    }
                }
            })
            .var(name)
            .ok()
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use std::process::Command;

    #[test]
    fn preserves_settings_around_invalid_lines() {
        let Ok(contents) = std::env::var("ENVIO_PROJECT_ENV_TEST_CONTENTS") else {
            for (contents, warning) in [
                ("PROJECT_ENV_BEFORE=before\nPROJECT_ENV_AFTER=after\n", ""),
                (
                    "PROJECT_ENV_BEFORE=before\nINVALID LINE\nPROJECT_ENV_AFTER=after\n",
                    "Warning: Ignoring invalid entries in .env\n",
                ),
            ] {
                let output = Command::new(std::env::current_exe().unwrap())
                    .args([
                        "--exact",
                        "utils::project_env::test::preserves_settings_around_invalid_lines",
                        "--nocapture",
                    ])
                    .env("ENVIO_PROJECT_ENV_TEST_CONTENTS", contents)
                    .env_remove("PROJECT_ENV_BEFORE")
                    .env_remove("PROJECT_ENV_AFTER")
                    .output()
                    .unwrap();
                assert_eq!(
                    (
                        output.status.success(),
                        String::from_utf8_lossy(&output.stderr)
                    ),
                    (true, warning.into()),
                    "{}",
                    String::from_utf8_lossy(&output.stdout),
                );
            }
            return;
        };
        let project = tempdir::TempDir::new("project_env").unwrap();
        std::fs::write(project.path().join(".env"), contents).unwrap();
        let env = ProjectEnv::new(project.path());
        assert_eq!(
            (env.var("PROJECT_ENV_BEFORE"), env.var("PROJECT_ENV_AFTER")),
            (Some("before".to_owned()), Some("after".to_owned()))
        );
    }
}
