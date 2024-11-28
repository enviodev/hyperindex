use anyhow::Context;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx;
use std::{
    fmt::{self, Display},
    fs::File,
    io::Read,
    path::PathBuf,
};

#[derive(Serialize, Deserialize, Debug, PartialEq, sqlx::FromRow, sqlx::Type)]
#[sqlx(type_name = "Text")]
#[serde(transparent)]
pub struct HashString(String);

impl HashString {
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

    pub fn from_string(string: String) -> Self {
        let mut hasher = Sha256::new();
        hasher.update(string);
        let hash = hasher.finalize().to_vec();
        HashString(format!("{:?}", hash))
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
    use pretty_assertions::assert_eq;
    use std::path::PathBuf;

    use super::HashString;
    const CONFIG_1: &str = "test/configs/config1.yaml";
    const CONFIG_2: &str = "test/configs/config2.yaml";
    const EMPTY_HANDLER: &str = "test/configs/empty_handlers.res";
    #[test]
    fn file_hash_single() {
        let config1_path = PathBuf::from(CONFIG_1);
        let hash = HashString::from_file_path(config1_path).unwrap();
        assert_eq!(
            hash.inner(),
            "deae0e280f52f275dc28a0ac1112e1ef99eb026b20e9a16c09265d213bdfda0f".to_string()
        );
    }
    #[test]
    fn file_hash_multiple() {
        let config1_path = PathBuf::from(CONFIG_1);
        let config2_path = PathBuf::from(CONFIG_2);
        let hash = HashString::from_file_paths(vec![config1_path, config2_path], true).unwrap();
        assert_eq!(
            hash.inner(),
            "6a603f030988963175e15a8861c37206747ce0ede1030f7b1598a0a4713470b7".to_string()
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
    #[should_panic]
    fn fail_hash_empty_fail() {
        let empty_handler_path = PathBuf::from(EMPTY_HANDLER);
        HashString::from_file_paths(vec![empty_handler_path], true).unwrap();
    }
}
