use std::{
    error::Error,
    fmt::{self, Display},
    fs::File,
    io::Read,
    path::PathBuf,
};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::project_paths::{ParsedPaths, ProjectPaths};

#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct HashString(String);

impl HashString {
    fn from_file_paths(file_paths: Vec<&PathBuf>) -> Result<Self, Box<dyn Error>> {
        // Read file contents into a buffer
        let mut buffer = Vec::new();

        for file_path in file_paths {
            // Open the file
            let mut file = File::open(file_path)?;
            file.read_to_end(&mut buffer)?;
        }

        // Create a hash of the file contents
        let hash = Sha256::digest(&buffer);

        // Convert the hash to a hexadecimal string
        let hash_string = format!("{:x}", hash);

        Ok(HashString(hash_string))
    }

    fn from_file_path(file_path: &PathBuf) -> Result<Self, Box<dyn Error>> {
        Self::from_file_paths(vec![file_path])
    }

    #[cfg(test)]
    fn inner(&self) -> String {
        self.0.clone()
    }
}

impl Display for HashString {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

#[derive(Serialize, Deserialize, Debug)]
pub struct PersistedState {
    pub has_run_db_migrations: bool,
    pub config_hash: HashString,
    pub schema_hash: HashString,
    pub handler_files_hash: HashString,
    pub abi_files_hash: HashString,
}
const PERSISTED_STATE_FILE_NAME: &str = "persisted_state.envio.json";

impl PersistedState {
    pub fn try_default(parsed_paths: &ParsedPaths) -> Result<Self, Box<dyn Error>> {
        Ok(PersistedState {
            has_run_db_migrations: false,
            config_hash: HashString::from_file_path(&parsed_paths.project_paths.config)?,
            schema_hash: HashString::from_file_path(&parsed_paths.schema_path)?,
            handler_files_hash: HashString::from_file_paths(parsed_paths.get_all_handler_paths())?,
            abi_files_hash: HashString::from_file_paths(parsed_paths.get_all_abi_paths())?,
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

pub fn check_user_file_diff_match(parsed_paths: &ParsedPaths) -> Result<bool, Box<dyn Error>> {
    let persisted_state = PersistedState::get_from_generated_file(&parsed_paths.project_paths)?;
    let current_config_hash = HashString::from_file_path(&parsed_paths.project_paths.config)?;
    if persisted_state.config_hash != current_config_hash {
        println!("Change in config detected");
        return Ok(false);
    }
    let current_schema_hash = HashString::from_file_path(&parsed_paths.schema_path)?;
    if persisted_state.schema_hash != current_schema_hash {
        println!("Change in schema detected");
        return Ok(false);
    }
    let current_handlers_hash = HashString::from_file_paths(parsed_paths.get_all_handler_paths())?;
    if persisted_state.handler_files_hash != current_handlers_hash {
        println!("Change in handlers detected");
        return Ok(false);
    }
    let current_abi_hash = HashString::from_file_paths(parsed_paths.get_all_abi_paths())?;
    if persisted_state.abi_files_hash != current_abi_hash {
        println!("Change in abis detected");
        return Ok(false);
    }
    Ok(true)
}

#[derive(Serialize, Deserialize, Debug)]
pub struct PersistedStateJsonString(String);

impl PersistedStateJsonString {
    pub fn try_default(parsed_paths: &ParsedPaths) -> Result<Self, Box<dyn Error>> {
        Ok(PersistedStateJsonString(
            PersistedState::try_default(parsed_paths)?.to_json_string(),
        ))
    }
}

#[cfg(test)]
mod test {

    use std::path::PathBuf;

    use super::HashString;
    const CONFIG_1: &str = "test/configs/config1.yaml";
    const CONFIG_2: &str = "test/configs/config2.yaml";
    #[test]
    fn file_hash_single() {
        let config1_path = PathBuf::from(CONFIG_1);
        let hash = HashString::from_file_path(&config1_path).unwrap();
        assert_eq!(
            hash.inner(),
            "70d77546796f25584e5b87fa851885990bc7870f02cf2b4afa9f64ef9a42b02a".to_string()
        );
    }
    #[test]
    fn file_hash_multiple() {
        let config1_path = PathBuf::from(CONFIG_1);
        let config2_path = PathBuf::from(CONFIG_2);
        let hash = HashString::from_file_paths(vec![&config1_path, &config2_path]).unwrap();
        assert_eq!(
            hash.inner(),
            "95b678bf1e788f56a819f8f13b7ece20a91775095360d297f9fea5555ad0e39b".to_string()
        );
    }
}
