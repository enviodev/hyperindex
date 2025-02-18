mod db;
mod hash_string;

use crate::{config_parsing::system_config::SystemConfig, project_paths::ParsedProjectPaths};
use anyhow::Context;
use hash_string::HashString;
use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use std::{
    fmt::{self, Display},
    path::PathBuf,
};
use strum::IntoEnumIterator;
use strum_macros::EnumIter;

#[derive(Serialize, Deserialize, Debug, FromRow)]
pub struct PersistedState {
    pub envio_version: String,
    pub config_hash: HashString,
    pub schema_hash: HashString,
    pub handler_files_hash: HashString,
    pub abi_files_hash: HashString,
}
const PERSISTED_STATE_FILE_NAME: &str = "persisted_state.envio.json";
pub static CURRENT_CRATE_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, strum::Display, EnumIter, PartialEq, Clone)]
///An enum representation of the fields stored in persisted state
pub enum StateField {
    EnvioVersion,
    Config,
    Schema,
    AbiFiles,
    HandlerFiles,
}

///Gets the path to the persisted file in generated folder
fn get_generated_file_path(project_paths: &ParsedProjectPaths) -> PathBuf {
    project_paths.generated.join(PERSISTED_STATE_FILE_NAME)
}

impl PersistedState {
    ///Compares a given field between two PersistedState structs.
    ///Useful for checking diffs between new state and persisted state file or db
    fn compare_state_field(&self, other_state: &Self, field: &StateField) -> bool {
        match field {
            StateField::Config => self.config_hash == other_state.config_hash,
            StateField::EnvioVersion => self.envio_version == other_state.envio_version,
            StateField::Schema => self.schema_hash == other_state.schema_hash,
            StateField::AbiFiles => self.abi_files_hash == other_state.abi_files_hash,
            StateField::HandlerFiles => self.handler_files_hash == other_state.handler_files_hash,
        }
    }

    ///Given a vec of fields and two states to compare
    ///Returns a vec of the fields that have changed
    fn get_non_matching_fields(
        &self,
        other_state: &Self,
        fields: Vec<StateField>,
    ) -> Vec<StateField> {
        fields
            .into_iter()
            .filter(|f| !self.compare_state_field(other_state, f))
            .collect()
    }

    ///Constructs the state and all file hashes representing the current state
    ///of an envio project. This will be used to diff against db and local file
    ///persisted state.
    pub fn get_current_state(config: &SystemConfig) -> anyhow::Result<Self> {
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
            envio_version: CURRENT_CRATE_VERSION.to_string(),
            config_hash: HashString::from_string(config.human_config.to_string()),
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

    ///Compares the current state and a persisted state file, returning a boolean of whether
    ///codegen should be run and a vector of the changed fields that make the rerun necessary
    pub fn should_run_codegen(&self, persisted_state_file: &Self) -> (bool, Vec<StateField>) {
        let codegen_affecting_fields = vec![
            //If the config has changed, this could affect values in generated code
            StateField::Config,
            //If abi files have changed it could affect event types
            StateField::AbiFiles,
            //If schema has changed this will affect generated entity types
            StateField::Schema,
            //If the version envio changes, this could infer differences that need to be re-code
            //generated
            StateField::EnvioVersion,
        ];

        let non_matching_fields =
            self.get_non_matching_fields(persisted_state_file, codegen_affecting_fields);

        (!non_matching_fields.is_empty(), non_matching_fields)
    }

    ///Compares the current state and a persisted state on the db, returning a boolean of whether
    ///migrations should be run and a vector of the changed fields that make the rerun necessary
    pub fn should_run_db_migrations(&self, persisted_state_db: &Self) -> (bool, Vec<StateField>) {
        //Check if any changes to the state and report which fields. All should invoke a migration
        let codegen_affecting_fields: Vec<_> = StateField::iter().collect();

        let non_matching_fields =
            self.get_non_matching_fields(persisted_state_db, codegen_affecting_fields);

        (!non_matching_fields.is_empty(), non_matching_fields)
    }
}

#[derive(Debug)]
pub enum PersistedStateExists {
    Exists(PersistedState),
    NotExists,
    Corrupted,
}

impl PersistedStateExists {
    ///Gets the PersistedState stored in a file in the generated code
    ///If the file does not exist it results in None
    ///And if it fails to deserialize persisted state then it means that the file
    ///is corrupted OR it uses a previous version of persisted state that can't deserialize
    pub fn get_persisted_state_file(project_paths: &ParsedProjectPaths) -> Self {
        let file_path = get_generated_file_path(project_paths);
        match std::fs::read_to_string(file_path) {
            Err(_) => Self::NotExists,
            Ok(file_str) => {
                //If it fails to deserialize, it could be an old or corrupted
                //representation of PersistedState. In either of these cases we
                //need to re-codegen so we can just treat it as an option type
                match serde_json::from_str(&file_str) {
                    Err(_) => Self::Corrupted,
                    Ok(state) => Self::Exists(state),
                }
            }
        }
    }
}

impl Display for PersistedState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let json_string = serde_json::to_string(self).map_err(|_| fmt::Error)?;
        write!(f, "{}", json_string)
    }
}
#[derive(Serialize, Deserialize, Debug)]
pub struct PersistedStateJsonString(String);

impl From<PersistedState> for PersistedStateJsonString {
    fn from(val: PersistedState) -> Self {
        Self(val.to_string())
    }
}

#[cfg(test)]
mod test {
    use super::PersistedState;
    use serde_json::json;

    #[test]
    fn should_run_codegen() {
        let persisted_file: PersistedState = serde_json::from_value(json!({
            "envio_version": "0.0.1",
            "config_hash": "<HASH_STRING>",
            "schema_hash": "<HASH_STRING>",
            "handler_files_hash": "<HASH_STRING>",
            "abi_files_hash": "<HASH_STRING>",
        }))
        .unwrap();

        let current_state: PersistedState = serde_json::from_value(json!({
            "envio_version": "0.0.1",
            "config_hash": "<CHANGED_HASH_STRING>",
            "schema_hash": "<HASH_STRING>",
            "handler_files_hash": "<HASH_STRING>",
            "abi_files_hash": "<HASH_STRING>",
        }))
        .unwrap();

        let (should_run_codegen, _changed_fields) =
            current_state.should_run_codegen(&persisted_file);

        assert!(
            should_run_codegen,
            "should run codegen should be true since config hash changed"
        );
    }

    #[test]
    fn should_not_run_codegen() {
        let persisted_file: PersistedState = serde_json::from_value(json!({
            "envio_version": "0.0.1",
            "config_hash": "<HASH_STRING>",
            "schema_hash": "<HASH_STRING>",
            "handler_files_hash": "<HASH_STRING>",
            "abi_files_hash": "<HASH_STRING>",
        }))
        .unwrap();

        let current_state: PersistedState = serde_json::from_value(json!({
            "envio_version": "0.0.1",
            "config_hash": "<HASH_STRING>",
            "schema_hash": "<HASH_STRING>",
            "handler_files_hash": "<CHANGED_HASH_STRING>",
            "abi_files_hash": "<HASH_STRING>",
        }))
        .unwrap();

        let (should_run_codegen, _changed_fields) =
            current_state.should_run_codegen(&persisted_file);

        assert!(
            !should_run_codegen,
            "should run codegen should be false since only handler file changed"
        );
    }

    #[test]
    fn should_run_db_migrations() {
        let persisted_db: PersistedState = serde_json::from_value(json!({
            "envio_version": "0.0.1",
            "config_hash": "<HASH_STRING>",
            "schema_hash": "<HASH_STRING>",
            "handler_files_hash": "<HASH_STRING>",
            "abi_files_hash": "<HASH_STRING>",
        }))
        .unwrap();

        let current_state: PersistedState = serde_json::from_value(json!({
            "envio_version": "0.0.1",
            "config_hash": "<HASH_STRING>",
            "schema_hash": "<CHANGED_HASH_STRING>",
            "handler_files_hash": "<CHANGED_HASH_STRING>",
            "abi_files_hash": "<HASH_STRING>",
        }))
        .unwrap();

        let (should_run_db_migrations, _changed_fields) =
            current_state.should_run_db_migrations(&persisted_db);

        assert!(
            should_run_db_migrations,
            "should run codegen should be true due since a change occurred"
        );
    }

    #[test]
    fn should_not_run_db_migrations() {
        let persisted_db: PersistedState = serde_json::from_value(json!({
            "envio_version": "0.0.1",
            "config_hash": "<HASH_STRING>",
            "schema_hash": "<HASH_STRING>",
            "handler_files_hash": "<HASH_STRING>",
            "abi_files_hash": "<HASH_STRING>",
        }))
        .unwrap();

        let current_state: PersistedState = serde_json::from_value(json!({
            "envio_version": "0.0.1",
            "config_hash": "<HASH_STRING>",
            "schema_hash": "<HASH_STRING>",
            "handler_files_hash": "<HASH_STRING>",
            "abi_files_hash": "<HASH_STRING>",
        }))
        .unwrap();

        let (should_run_db_migrations, _changed_fields) =
            current_state.should_run_db_migrations(&persisted_db);

        assert!(
            !should_run_db_migrations,
            "should run codegen should be false since nothing changed"
        );
    }
}
