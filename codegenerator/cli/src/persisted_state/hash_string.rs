use anyhow::Context;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx;
use std::{
    fmt::{self, Display},
    fs::{File,read_dir},
    io::Read,
    path::{Path,PathBuf},
};

#[derive(Serialize, Deserialize, Debug, PartialEq, sqlx::FromRow, sqlx::Type)]
#[sqlx(type_name = "Text")]
#[serde(transparent)]
pub struct HashString(String);

impl HashString {

    pub fn from_string(string: String) -> Self {
        // Create a hash of the string
        let hash = Sha256::digest(&string);

        // Convert the hash to a hexadecimal string
        let hash_string = format!("{:x}", hash);

        HashString(hash_string)
    }

    //generates a hash of the contents of a directory
    pub fn from_directory(directory_path: PathBuf) -> anyhow::Result<Self> {

        fn get_files_recursive(directory_path: &Path) -> Vec<PathBuf> {
            let mut files = Vec::new();
        
            if let Ok(entries) = read_dir(directory_path) {
                for entry in entries {
                    if let Ok(entry) = entry {
                        let path = entry.path();
                        if path.is_file() {
                            files.push(path);
                        } else if path.is_dir() {
                            files.extend(get_files_recursive(&path));
                        }
                    }
                }
            }
        
            files
        }
            
        let files: Vec<PathBuf> = get_files_recursive(&directory_path);        

        Self::from_file_paths(files, true)
    }

    pub fn from_file_paths(
        file_paths: Vec<PathBuf>,
        file_must_exist: bool,
    ) -> anyhow::Result<Self> {
        // Read file contents into a buffer
        let mut buffer = Vec::new();

        for file_path in file_paths {
            // Open the file if we expect the file to exist at the stage of codegen
            if file_must_exist {
                let mut file =
                    File::open(file_path).context("Opening file in HashString::from_file_paths")?;
                file.read_to_end(&mut buffer)
                    .context("Reading file in HashString::from_file_paths where file must exist")?;
            }
            // Exception made specifically for event handlers which may not exist at codegen yet
            else if let Ok(mut file) = File::open(file_path) {
                file.read_to_end(&mut buffer)
                    .context("Reading file in HashString::from_file_paths where file")?;
            }
        }

        // Create a hash of the file contents
        let hash = Sha256::digest(&buffer);

        // Convert the hash to a hexadecimal string
        let hash_string = format!("{:x}", hash);

        Ok(HashString(hash_string))
    }

    pub fn from_file_path(file_path: PathBuf) -> anyhow::Result<Self> {
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

#[cfg(test)]
mod test {
    use std::path::PathBuf;
    use super::HashString;


    const CONFIG_1: &str = "test/configs/config1.yaml";
    const CONFIG_2: &str = "test/configs/config2.yaml";
    const EMPTY_HANDLER: &str = "test/configs/empty_handlers.res";
    const HANDLER_DIR: &str = "test/event_handlers/js";
    const HANDLER_DIR_TS: &str = "test/event_handlers/ts";

    #[test]
    fn file_hash_single() {
        let config1_path = PathBuf::from(CONFIG_1);
        let hash = HashString::from_file_path(config1_path).unwrap();
        assert_eq!(
            hash.inner(),
            "ee7d4f3ee517e61784134fef559b4091a56fe885c8af9fd77d42000d4cfc6725".to_string()
        );
    }
    #[test]
    fn file_hash_multiple() {
        let config1_path = PathBuf::from(CONFIG_1);
        let config2_path = PathBuf::from(CONFIG_2);
        let hash = HashString::from_file_paths(vec![config1_path, config2_path], true).unwrap();
        assert_eq!(
            hash.inner(),
            "891cfba3644d82f1bf39d629c336bca1929520034a490cb7640495163566dde5".to_string()
        );
    }

    #[test]
    fn file_hash_empty() {
        let empty_handler_path = PathBuf::from(EMPTY_HANDLER);
        let hash = HashString::from_file_paths(vec![empty_handler_path], false).unwrap();
        assert_eq!(
            hash.inner(),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".to_string()
        );
    }

    #[test]
    fn handler_file_hash_dir() {
        let handler_path_dir = PathBuf::from(HANDLER_DIR);
        let hash = HashString::from_directory(handler_path_dir).unwrap();
        assert_eq!(
            hash.inner(),
            "3a74a6b2bdd07e0e9928558bfaab423d55ef21fda394707c8901d3389790f0c3".to_string()
        );
    }
    
    #[test]
    fn handler_file_hash_dir_ts() {
        let handler_path_dir_ts = PathBuf::from(HANDLER_DIR_TS);
        let hash = HashString::from_directory(handler_path_dir_ts).unwrap();
        assert_eq!(
            hash.inner(),
            "a4e20ec6213dcf20890bc1d528fe0817332e75919ed47750ac6b0ce559036bcc".to_string()
        );
    }

    #[test]
    #[should_panic]
    fn fail_hash_empty_fail() {
        let empty_handler_path = PathBuf::from(EMPTY_HANDLER);
        HashString::from_file_paths(vec![empty_handler_path], true).unwrap();
    }
}
