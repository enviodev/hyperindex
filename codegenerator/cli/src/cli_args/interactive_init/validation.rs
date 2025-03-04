use crate::constants::project_paths::DEFAULT_PROJECT_ROOT_PATH;
use colored::Colorize;
use inquire::validator::CustomTypeValidator;
use inquire::{validator::Validation, CustomUserError};
use std::collections::BTreeMap;
use std::fmt::Display;
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
pub fn is_valid_foldername_inquire_validator(name: &str) -> Result<Validation, CustomUserError> {
    if !is_valid_folder_name(name) {
        Ok(Validation::Invalid(
            "EE400: Invalid folder name. The folder name cannot contain any of the following \
             special characters: / \\ : * ? \" < > |"
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
                "EE401: Directory '{}' already exists. Please use a new directory.",
                directory
            )
            .into(),
        ))
    } else {
        Ok(Validation::Valid)
    }
}

#[derive(Clone)]
pub struct UniqueValueValidator<T> {
    other_values: Vec<T>,
}

impl<T: Clone + Display + PartialEq> CustomTypeValidator<T> for UniqueValueValidator<T> {
    fn validate(&self, input: &T) -> Result<Validation, CustomUserError> {
        if self.other_values.contains(input) {
            Ok(Validation::Invalid(
                format!("{input} has already been added").into(),
            ))
        } else {
            Ok(Validation::Valid)
        }
    }
}

impl<T> UniqueValueValidator<T> {
    pub fn new(other_values: Vec<T>) -> UniqueValueValidator<T> {
        Self { other_values }
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

fn are_events_equivalent(event1: &ethers::abi::Event, event2: &ethers::abi::Event) -> bool {
    event1.name == event2.name
        && event1.inputs.len() == event2.inputs.len()
        && event1
            .inputs
            .iter()
            .zip(&event2.inputs)
            .all(|(input1, input2)| input1.kind == input2.kind && input1.indexed == input2.indexed)
}

pub fn filter_duplicate_events(
    events: BTreeMap<String, Vec<ethers::abi::Event>>,
) -> BTreeMap<String, Vec<ethers::abi::Event>> {
    let mut filtered_events: BTreeMap<String, Vec<ethers::abi::Event>> = BTreeMap::new();

    for (event_name, event_list) in events {
        if event_list.len() > 1 {
            let first_event = event_list[0].clone();
            for event in event_list.iter().skip(1) {
                if !are_events_equivalent(&first_event, event) {
                    let warning_message = "Note: this is unimplemented! The code might behave \
                                           unexpectedly.\n"
                        .red()
                        .bold();
                    println!("{}", warning_message);
                    println!(
                        "Found duplicate event: {} in contract abi. This event will be ignored. However, this second ignored event has the same name as the first event, but different inputs. Handling this is currently unimplemented. Please ask the team on discord, or comment on our github issue if this is affecting you.\n\nhttps://github.com/enviodev/envio-hyperindexer-issues/issues/1\n",
                        event_name
                    );
                }
            }

            filtered_events.insert(event_name, vec![first_event]);
        } else {
            filtered_events.insert(event_name, event_list);
            continue;
        }
    }

    filtered_events
}
