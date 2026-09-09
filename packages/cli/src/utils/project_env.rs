use super::dotenv::{self, EnvMap};
use std::{
    cell::OnceCell,
    path::{Path, PathBuf},
};

/// Resolves environment variables the way the indexer runtime does: the process
/// environment wins, and anything unset there falls back to the project's
/// `.env`. The file is read at most once, on the first miss.
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
            .get_or_init(|| match dotenv::from_path(self.project_root.join(".env")) {
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
            })
            .var(name)
            .ok()
    }
}
