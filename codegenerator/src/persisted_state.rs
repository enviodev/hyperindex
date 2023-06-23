use std::{error::Error, fs::File, io::Read, path::PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::project_paths::{ParsedPaths, ProjectPaths};

#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct HashString(String);

impl HashString {
    fn from_file(file_path: &PathBuf) -> Result<Self, Box<dyn Error>> {
        // Open the file
        let mut file = File::open(file_path)?;

        // Read file contents into a buffer
        let mut buffer = Vec::new();
        file.read_to_end(&mut buffer)?;

        // Create a hash of the file contents
        let hash = Sha256::digest(&buffer);

        // Convert the hash to a hexadecimal string
        let hash_string = format!("{:x}", hash);

        Ok(HashString(hash_string))
    }

    fn from_config_file(project_paths: &ProjectPaths) -> Result<Self, Box<dyn Error>> {
        Self::from_file(&project_paths.config)
    }

    // fn from_schema_file(project_paths: &ProjectPaths) -> Result<Self, Box<dyn Error>> {
    //     // ParsedPaths::new(project_paths.)
    //     // Self::from_file(&project_paths.)
    // }
}

#[derive(Serialize, Deserialize, Debug)]
pub struct PersistedState {
    pub has_run_db_migrations: bool,
    pub config_hash: HashString,
}
const PERSISTED_STATE_FILE_NAME: &str = "persisted_state.envio.json";

impl PersistedState {
    pub fn try_default(project_paths: &ProjectPaths) -> Result<Self, Box<dyn Error>> {
        Ok(PersistedState {
            has_run_db_migrations: false,
            config_hash: HashString::from_file(&project_paths.config)?,
        })
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

fn check_diff_match(parsed_paths: &ParsedPaths) -> Result<bool, Box<dyn Error>> {
    let persisted_state = PersistedState::get_from_generated_file(&parsed_paths.project_paths)?;
    let current_config_hash = HashString::from_config_file(&parsed_paths.project_paths)?;
    let current_schema_hash = HashString::from_file(&parsed_paths.schema_path)?;
    Ok(persisted_state.config_hash == current_config_hash)
}

#[derive(Serialize, Deserialize, Debug)]
pub struct PersistedStateJsonString(String);

impl PersistedStateJsonString {
    pub fn try_default(project_paths: &ProjectPaths) -> Result<Self, Box<dyn Error>> {
        Ok(PersistedStateJsonString(
            PersistedState::try_default(project_paths)?.to_json_string(),
        ))
    }
}
