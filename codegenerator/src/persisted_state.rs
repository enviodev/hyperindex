use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::project_paths::{self, ProjectPaths};

#[derive(Serialize, Deserialize, Debug)]
pub struct PersistedState {
    pub has_run_db_migrations: bool,
}
const PERSISTED_STATE_FILE_NAME: &str = "persisted_state.envio.json";

impl PersistedState {
    pub fn default() -> Self {
        PersistedState {
            has_run_db_migrations: false,
        }
    }

    fn to_json_string(&self) -> String {
        serde_json::to_string(self).expect("PersistedState struct should always be serializable")
    }

    fn get_generated_file_path(project_paths: &ProjectPaths) -> PathBuf {
        project_paths.generated.join(PERSISTED_STATE_FILE_NAME)
    }

    pub fn get_from_generated_file(project_paths: &ProjectPaths) -> Result<Self, String> {
        let file_path = Self::get_generated_file_path(project_paths);
        let file_str = std::fs::read_to_string(file_path).map_err(|e| {
            format!(
                "Unable to find {} due to error: {}",
                PERSISTED_STATE_FILE_NAME, e
            )
        })?;

        serde_json::from_str(&file_str).map_err(|e| {
            format!(
                "Unable to parse {} due to error: {}",
                PERSISTED_STATE_FILE_NAME, e
            )
        })
    }

    fn write_to_generated_file(&self, project_paths: &ProjectPaths) -> Result<(), String> {
        let file_path = Self::get_generated_file_path(project_paths);
        let contents = self.to_json_string();
        std::fs::write(file_path, contents).map_err(|e| {
            format!(
                "Unable to write {} due to error: {}",
                PERSISTED_STATE_FILE_NAME, e
            )
        })
    }

    pub fn set_has_run_db_migrations(
        project_paths: &ProjectPaths,
        has_run_db_migrations: bool,
    ) -> Result<(), String> {
        let mut persisted_state = Self::get_from_generated_file(project_paths)?;
        if !(persisted_state.has_run_db_migrations == has_run_db_migrations) {
            persisted_state.has_run_db_migrations = has_run_db_migrations;
            return persisted_state.write_to_generated_file(project_paths);
        }
        Ok(())
    }
}

#[derive(Serialize, Deserialize, Debug)]
pub struct PersistedStateJsonString(String);

impl PersistedStateJsonString {
    pub fn default() -> Self {
        PersistedStateJsonString(PersistedState::default().to_json_string())
    }
}
