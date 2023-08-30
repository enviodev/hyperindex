use std::{
    error::Error,
    fmt::{self, Display},
    fs::{self, File},
    io::Read,
    path::PathBuf,
};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::project_paths::{ParsedPaths, ProjectPaths};

#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct HashString(String);

impl HashString {
    fn from_file_paths(
        file_paths: Vec<&PathBuf>,
        file_must_exist: bool,
    ) -> Result<Self, Box<dyn Error>> {
        // Read file contents into a buffer
        let mut buffer = Vec::new();

        for file_path in file_paths {
            // Open the file if we expect the file to exist at the stage of codegen
            if file_must_exist {
                let mut file = File::open(file_path)?;
                file.read_to_end(&mut buffer)?;
            }
            // Exception made specifically for event handlers which may not exist at codegen yet
            else if let Ok(mut file) = File::open(file_path) {
                file.read_to_end(&mut buffer)?;
            }
        }

        // Create a hash of the file contents
        let hash = Sha256::digest(&buffer);

        // Convert the hash to a hexadecimal string
        let hash_string = format!("{:x}", hash);

        Ok(HashString(hash_string))
    }

    fn from_file_path(file_path: &PathBuf) -> Result<Self, Box<dyn Error>> {
        Self::from_file_paths(vec![file_path], true)
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
            handler_files_hash: HashString::from_file_paths(
                parsed_paths.get_all_handler_paths(),
                false,
            )?,
            abi_files_hash: HashString::from_file_paths(parsed_paths.get_all_abi_paths(), true)?,
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
        if persisted_state.has_run_db_migrations != has_run_db_migrations {
            persisted_state.has_run_db_migrations = has_run_db_migrations;
            return persisted_state.write_to_generated_file(project_paths);
        }
        Ok(())
    }
}

pub enum RerunOptions {
    CodegenAndSyncFromRpc,
    CodegenAndResyncFromStoredEvents,
    ResyncFromStoredEvents,
    ContinueSync,
}

//Used to determin what action should be taken
//based on changes a user has made to parts of their code
struct PersistedStateDiff {
    config_change: bool,
    abi_change: bool,
    schema_change: bool,
    handler_change: bool,
}

impl PersistedStateDiff {
    pub fn new() -> Self {
        PersistedStateDiff {
            config_change: false,
            abi_change: false,
            schema_change: false,
            handler_change: false,
        }
    }

    pub fn get_rerun_option(&self) -> RerunOptions {
        match (
            //Config or Abi change -> Codegen & rerun sync from RPC
            (self.config_change || self.abi_change),
            //Schema change -> Rerun codegen, resync from stored raw events
            self.schema_change,
            //Handlers change -> resync from stored raw events (no codegen)
            self.handler_change,
        ) {
            (true, _, _) => RerunOptions::CodegenAndSyncFromRpc,
            (false, true, _) => RerunOptions::CodegenAndResyncFromStoredEvents,
            (false, false, true) => RerunOptions::ResyncFromStoredEvents,
            (false, false, false) => RerunOptions::ContinueSync,
        }
    }
}

pub enum ExistingPersistedState {
    NoFile,
    ExistingFile(PersistedState),
}

pub fn check_user_file_diff_match(
    existing_persisted_state: &ExistingPersistedState,
    parsed_paths: &ParsedPaths,
) -> Result<RerunOptions, Box<dyn Error>> {
    //If there is no existing file, the whole process needs to
    //be run so we can skip diff checking
    let persisted_state = match existing_persisted_state {
        ExistingPersistedState::NoFile => {
            return Ok(RerunOptions::CodegenAndSyncFromRpc);
        }
        ExistingPersistedState::ExistingFile(f) => f,
    };
    let mut diff = PersistedStateDiff::new();
    let current_config_hash = HashString::from_file_path(&parsed_paths.project_paths.config)?;
    if persisted_state.config_hash != current_config_hash {
        println!("Change in config detected");
        diff.config_change = true;
    }
    let current_schema_hash = HashString::from_file_path(&parsed_paths.schema_path)?;
    if persisted_state.schema_hash != current_schema_hash {
        println!("Change in schema detected");
        diff.schema_change = true;
    }
    let current_handlers_hash =
        HashString::from_file_paths(parsed_paths.get_all_handler_paths(), false)?;
    if persisted_state.handler_files_hash != current_handlers_hash {
        println!("Change in handlers detected");
        diff.handler_change = true;
    }
    let current_abi_hash = HashString::from_file_paths(parsed_paths.get_all_abi_paths(), true)?;
    if persisted_state.abi_files_hash != current_abi_hash {
        println!("Change in abis detected");
        diff.abi_change = true;
    }
    Ok(diff.get_rerun_option())
}

pub fn handler_file_has_changed(
    existing_persisted_state: &ExistingPersistedState,
    parsed_paths: &ParsedPaths,
) -> Result<bool, Box<dyn Error>> {
    let persisted_state = match existing_persisted_state {
        ExistingPersistedState::NoFile => {
            return Ok(false);
        }
        ExistingPersistedState::ExistingFile(f) => f,
    };
    let current_handlers_hash =
        HashString::from_file_paths(parsed_paths.get_all_handler_paths(), false)?;
    Ok(persisted_state.handler_files_hash != current_handlers_hash)
}

pub fn persisted_state_file_exists(project_paths: &ProjectPaths) -> bool {
    let file_path = project_paths.generated.join(PERSISTED_STATE_FILE_NAME);

    fs::metadata(file_path).is_ok()
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
    const EMPTY_HANDLER: &str = "test/configs/empty_handlers.res";
    #[test]
    fn file_hash_single() {
        let config1_path = PathBuf::from(CONFIG_1);
        let hash = HashString::from_file_path(&config1_path).unwrap();
        assert_eq!(
            hash.inner(),
            "ee7d4f3ee517e61784134fef559b4091a56fe885c8af9fd77d42000d4cfc6725".to_string()
        );
    }
    #[test]
    fn file_hash_multiple() {
        let config1_path = PathBuf::from(CONFIG_1);
        let config2_path = PathBuf::from(CONFIG_2);
        let hash = HashString::from_file_paths(vec![&config1_path, &config2_path], true).unwrap();
        assert_eq!(
            hash.inner(),
            "891cfba3644d82f1bf39d629c336bca1929520034a490cb7640495163566dde5".to_string()
        );
    }

    #[test]
    fn file_hash_empty() {
        let empty_handler_path = PathBuf::from(EMPTY_HANDLER);
        let hash = HashString::from_file_paths(vec![&empty_handler_path], false).unwrap();
        assert_eq!(
            hash.inner(),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".to_string()
        );
    }

    #[test]
    #[should_panic]
    fn fail_hash_empty_fail() {
        let empty_handler_path = PathBuf::from(EMPTY_HANDLER);
        HashString::from_file_paths(vec![&empty_handler_path], true).unwrap();
    }
}
