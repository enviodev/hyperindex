use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Debug)]
struct PersistedState {
    has_run_db_migrations: bool,
}

impl PersistedState {
    fn default() -> Self {
        PersistedState {
            has_run_db_migrations: false,
        }
    }

    fn to_json_string(&self) -> String {
        serde_json::to_string(self).expect("PersistedState struct should always be serializable")
    }
}

//codegen creates a state file
//db migrations sets state to true
//db migrations down sets state to false
//envio start checks and runs up migrations if not
