use crate::{
    config_parsing::human_config::parse_contract_abi,
    constants::project_paths::DEFAULT_PROJECT_ROOT_PATH,
};
use inquire::{validator::Validation, CustomUserError};
use std::{fs, path::PathBuf};

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
pub fn is_valid_foldername_inquire_validator(name: &str) -> Result<Validation, CustomUserError> {
    if !is_valid_folder_name(name) {
        Ok(Validation::Invalid(
            "EE400: Invalid folder name. The folder name cannot contain any of the following special characters: / \\ : * ? \" < > |"
            .into(),
        ))
    } else {
        Ok(Validation::Valid)
    }
}

pub fn is_directory_new(directory: &str) -> bool {
    !(fs::metadata(directory).is_ok() && directory != DEFAULT_PROJECT_ROOT_PATH)
}

pub fn is_directory_new_validator(directory: &str) -> Result<Validation, CustomUserError> {
    if !is_directory_new(directory) {
        Ok(Validation::Invalid(
            format!(
                "Directory '{}' already exists. Please use a new directory.",
                directory
            )
            .into(),
        ))
    } else {
        Ok(Validation::Valid)
    }
}

pub fn is_abi_file_validator(abi_file_path: &str) -> Result<Validation, CustomUserError> {
    let maybe_parsed_abi = parse_contract_abi(PathBuf::from(abi_file_path));

    match maybe_parsed_abi {
        Ok(_) => Ok(Validation::Valid),
        Err(e) => Ok(Validation::Invalid(e.into())),
    }
}

pub fn is_not_empty_string_validator(s: &str) -> Result<Validation, CustomUserError> {
    if s.trim().is_empty() {
        Ok(Validation::Invalid("Invalid empty string input".into()))
    } else {
        Ok(Validation::Valid)
    }
}

pub fn contains_no_whitespace_validator(s: &str) -> Result<Validation, CustomUserError> {
    if s.contains(char::is_whitespace) {
        Ok(Validation::Invalid(
            "Invalid input cannot contain spaces".into(),
        ))
    } else {
        Ok(Validation::Valid)
    }
}

pub fn is_only_alpha_numeric_characters_validator(s: &str) -> Result<Validation, CustomUserError> {
    if !s.chars().all(|s| s.is_ascii_alphanumeric()) {
        Ok(Validation::Invalid(
            "Invalid input, must use alpha-numeric characters".into(),
        ))
    } else {
        Ok(Validation::Valid)
    }
}

pub fn first_char_is_alphabet_validator(s: &str) -> Result<Validation, CustomUserError> {
    match s.chars().next() {
        Some(c) if c.is_ascii_alphabetic() => Ok(Validation::Valid),
        _ => Ok(Validation::Invalid(
            "Invalid input, first character must be alphabetic".into(),
        )),
    }
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
