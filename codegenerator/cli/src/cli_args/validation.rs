use super::constants::DEFAULT_PROJECT_ROOT_PATH;
use inquire::validator::Validation;
use serde::ser::StdError;
use std::fs;

pub fn is_valid_folder_name(name: &str) -> bool {
    // Disallow invalid characters in folder names.
    let invalid_chars = ['/', '\\', ':', '*', '?', '"', '<', '>', '|'];
    if name.chars().any(|c| invalid_chars.contains(&c)) {
        return false;
    }

    // Ensure the folder name is not empty.
    if name.is_empty() {
        return false;
    }

    true
}

// todo: consider returning invalid rather than error ?
pub fn is_valid_foldername_inquire_validation_result(
    name: &str,
) -> Result<Validation, Box<(dyn StdError + Send + Sync + 'static)>> {
    if !is_valid_folder_name(name) {
        return Err(Box::new(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "Invalid folder name",
        )));
    }
    Ok(Validation::Valid)
}

pub fn is_directory_new(
    directory: &str,
) -> Result<Validation, Box<(dyn StdError + Send + Sync + 'static)>> {
    if fs::metadata(directory).is_ok() && directory != DEFAULT_PROJECT_ROOT_PATH {
        return Err(Box::new(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!(
                "Directory '{}' already exists. Please use a new directory.",
                directory
            ),
        )));
    }

    Ok(Validation::Valid)
}

mod tests {
    #[test]
    fn valid_folder_name() {
        let valid_name = "my_folder";
        let is_valid = super::is_valid_folder_name(valid_name);
        assert!(is_valid);
    }
    #[test]
    fn invalid_folder_name() {
        let invalid_name_star = "my*folder";
        let invalid_name_colon = "my:folder";
        let invalid_name_empty = "";

        let is_invalid_star = super::is_valid_folder_name(invalid_name_star);
        let is_invalid_colon = super::is_valid_folder_name(invalid_name_colon);
        let is_invalid_empty = super::is_valid_folder_name(invalid_name_empty);

        assert!(!is_invalid_star);
        assert!(!is_invalid_colon);
        assert!(!is_invalid_empty);
    }
}
