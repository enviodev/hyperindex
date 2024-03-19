use anyhow::Context;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx;
use std::{
    fmt::{self, Display},
    fs::{File,read_dir},
    io::Read,
    path::PathBuf,
};

#[derive(Serialize, Deserialize, Debug, PartialEq, sqlx::FromRow, sqlx::Type)]
#[sqlx(type_name = "Text")]
#[serde(transparent)]
pub struct HashString(String);

impl HashString {
    pub fn from_string(hash:String) -> HashString{
        HashString(hash)
    }

    pub fn from_flattened_directory(directory_path: PathBuf) -> anyhow::Result<Self> {
        // Get a list of paths within the directory
        let paths = read_dir(directory_path)
            .expect("Failed to read directory")
            .map(|entry| entry.unwrap().path())
            .collect::<Vec<PathBuf>>();

        // Filter out only files from the paths - esbuild should only generate single nested child files but to be safe
        let files: Vec<PathBuf> = paths
            .into_iter()
            .filter(|path| path.is_file())
            .collect();

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
    const HANDLER_WITH_IMPORTS: &str = "test/configs/handler-with-imports.js"; // todo: test this with ts - docs seem to say it will work - https://swc.rs/ - test with different versions of js
    const HASH_OF_HANDLER_WITHOUT_IMPORTS: &str = "64d3f59d8dec3b31560262e5fd68690a0586771226d2f2635db2667818d8df0d";
    const IMPORTED_HANDLER_FILE: &str = "test/configs/imported-file.js";
    const HASH_OF_IMPORTED_HANDLER_FILE: &str = "e91348df5c1159dc72706a2007b0cdb8145187d31fe796ea7d7a98498b4467fe";
    const HASH_OF_HANDLER_AST : &str = "efb4545c5404ce70718b09dea80dc5ddde066b2bc498da39a8f9a9bfe3095378";

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
    fn handler_file_hash_with_imports_not_hash_of_handler_file() {
        let handler_path = PathBuf::from(HANDLER_WITH_IMPORTS);
        let hash = HashString::from_file_paths(vec![handler_path], true).unwrap();
        assert_ne!(
            hash.inner(),
            HASH_OF_HANDLER_WITHOUT_IMPORTS.to_string()
        );
    }

    #[test]
    #[should_panic]
    fn fail_hash_empty_fail() {
        let empty_handler_path = PathBuf::from(EMPTY_HANDLER);
        HashString::from_file_paths(vec![empty_handler_path], true).unwrap();
    }
}
