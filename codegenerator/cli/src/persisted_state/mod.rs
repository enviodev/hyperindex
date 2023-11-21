mod hash_string;

use crate::{config_parsing::system_config::SystemConfig, project_paths::ParsedProjectPaths};
use anyhow::Context;
use hash_string::HashString;
use serde::{Deserialize, Serialize};
use std::{fs, path::PathBuf};

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
    pub fn try_default(config: &SystemConfig) -> anyhow::Result<Self> {
        let schema_path = config
            .get_path_to_schema()
            .context("Failed getting path to schema")?;

        let all_handler_paths = config
            .get_all_paths_to_handlers()
            .context("Failed getting handler paths")?;

        let all_abi_file_paths = config
            .get_all_paths_to_abi_files()
            .context("Failed getting abi file paths")?;

        const HANDLER_FILES_MUST_EXIST: bool = false;
        const ABI_FILES_MUST_EXIST: bool = true;

        Ok(PersistedState {
            has_run_db_migrations: false,
            config_hash: HashString::from_file_path(config.parsed_project_paths.config.clone())
                .context("Failed hashing config file")?,
            schema_hash: HashString::from_file_path(schema_path.clone())
                .context("Failed hashing schema file")?,
            handler_files_hash: HashString::from_file_paths(
                all_handler_paths,
                HANDLER_FILES_MUST_EXIST,
            )
            .context("Failed hashing handler files")?,
            abi_files_hash: HashString::from_file_paths(all_abi_file_paths, ABI_FILES_MUST_EXIST)
                .context("Failed hashing abi files")?,
        })
    }

    pub fn try_get_updated(&self, config: &SystemConfig) -> anyhow::Result<Self> {
        let default =
            Self::try_default(config).context("Failed getting default in try get update")?;

        Ok(PersistedState {
            has_run_db_migrations: self.has_run_db_migrations,
            ..default
        })
    }

    fn to_json_string(&self) -> String {
        serde_json::to_string(self).expect("PersistedState struct should always be serializable")
    }

    fn get_generated_file_path(project_paths: &ParsedProjectPaths) -> PathBuf {
        project_paths.generated.join(PERSISTED_STATE_FILE_NAME)
    }

    pub fn get_from_generated_file(project_paths: &ParsedProjectPaths) -> anyhow::Result<Self> {
        let file_path = Self::get_generated_file_path(project_paths);
        let file_str = std::fs::read_to_string(file_path)
            .context(format!("Unable to find {}", PERSISTED_STATE_FILE_NAME,))?;

        serde_json::from_str(&file_str)
            .context(format!("Unable to parse {}", PERSISTED_STATE_FILE_NAME,))
    }

    fn write_to_generated_file(&self, project_paths: &ParsedProjectPaths) -> anyhow::Result<()> {
        let file_path = Self::get_generated_file_path(project_paths);
        let contents = self.to_json_string();
        std::fs::write(file_path, contents)
            .context(format!("Unable to write {}", PERSISTED_STATE_FILE_NAME))
    }

    pub fn set_has_run_db_migrations(
        project_paths: &ParsedProjectPaths,
        has_run_db_migrations: bool,
    ) -> anyhow::Result<()> {
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
    config: &SystemConfig,
    project_paths: &ParsedProjectPaths,
) -> anyhow::Result<RerunOptions> {
    //If there is no existing file, the whole process needs to
    //be run so we can skip diff checking
    let persisted_state = match existing_persisted_state {
        ExistingPersistedState::NoFile => {
            return Ok(RerunOptions::CodegenAndSyncFromRpc);
        }
        ExistingPersistedState::ExistingFile(f) => f,
    };

    let mut diff = PersistedStateDiff::new();

    let new_state = persisted_state
        .try_get_updated(config)
        .context("Getting updated persisted state")?;

    if persisted_state.config_hash != new_state.config_hash {
        println!("Change in config detected");
        diff.config_change = true;
    }
    if persisted_state.schema_hash != new_state.schema_hash {
        println!("Change in schema detected");
        diff.schema_change = true;
    }

    if persisted_state.handler_files_hash != new_state.handler_files_hash {
        println!("Change in handlers detected");
        diff.handler_change = true;
    }

    if persisted_state.abi_files_hash != new_state.abi_files_hash {
        println!("Change in abis detected");
        diff.abi_change = true;
    }

    new_state
        .write_to_generated_file(project_paths)
        .context("Writing new persisted state")?;
    Ok(diff.get_rerun_option())
}

pub fn handler_file_has_changed(
    existing_persisted_state: &ExistingPersistedState,
    config: &SystemConfig,
) -> anyhow::Result<bool> {
    let persisted_state = match existing_persisted_state {
        ExistingPersistedState::NoFile => {
            return Ok(false);
        }
        ExistingPersistedState::ExistingFile(f) => f,
    };

    let all_handler_paths = config
        .get_all_paths_to_handlers()
        .context("Failed getting all handler paths")?;

    let current_handlers_hash = HashString::from_file_paths(all_handler_paths, false)
        .context("Failed hashing handler files")?;

    Ok(persisted_state.handler_files_hash != current_handlers_hash)
}

pub fn persisted_state_file_exists(project_paths: &ParsedProjectPaths) -> bool {
    let file_path = project_paths.generated.join(PERSISTED_STATE_FILE_NAME);

    fs::metadata(file_path).is_ok()
}

#[derive(Serialize, Deserialize, Debug)]
pub struct PersistedStateJsonString(String);

impl PersistedStateJsonString {
    pub fn try_default(config: &SystemConfig) -> anyhow::Result<Self> {
        Ok(PersistedStateJsonString(
            PersistedState::try_default(config)
                .context("Failed getting default persisted state")?
                .to_json_string(),
        ))
    }
}
