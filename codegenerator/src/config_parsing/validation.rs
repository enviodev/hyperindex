use regex::Regex;
use std::collections::HashSet;
use std::path::PathBuf;

use crate::config_parsing::Config;

use super::constants::RESERVED_WORDS;

// It must start with a letter or underscore.
// It can contain letters, numbers, and underscores.
// It must have a maximum length of 63 characters (the first character + 62 subsequent characters)
fn is_valid_postgres_db_name(name: &str) -> bool {
    let re = Regex::new(r"^[a-zA-Z_][a-zA-Z0-9_]{0,62}$").unwrap();
    re.is_match(name)
}

fn is_valid_ethereum_address(address: &str) -> bool {
    let re = Regex::new(r"^0x[0-9a-fA-F]{40}$").unwrap();
    re.is_match(address)
}

fn are_valid_ethereum_addresses(addresses: &[String]) -> bool {
    for address in addresses {
        if !is_valid_ethereum_address(address) {
            return false;
        }
    }
    true
}

// Contracts must have unique names in the config file.
// Contract names are not case-sensitive.
// This is regardless of networks.
fn are_contract_names_unique(contract_names: &[String]) -> bool {
    let mut unique_names = std::collections::HashSet::new();

    for name in contract_names {
        let lowercase_name = name.to_lowercase();
        if !unique_names.insert(lowercase_name) {
            return false;
        }
    }
    true
}

// Check for reserved words in a string, to be applied for schema and config.
// Words from config and schema are used in the codegen and eventually in eventHandlers for the user, thus cannot contain any reserved words.
fn check_reserved_words(input_string: &str) -> Vec<String> {
    let mut flagged_words = Vec::new();
    let words_set: HashSet<&str> = RESERVED_WORDS.iter().cloned().collect();
    let re = Regex::new(r"\b\w+\b").unwrap();

    // Find all alphanumeric words in the YAML string
    for word in re.find_iter(input_string) {
        let word = word.as_str();
        if words_set.contains(word) {
            flagged_words.push(word.to_string());
        }
    }

    flagged_words
}
// Check if the given RPC URL is valid in terms of formatting.
// For now, we only check if it starts with http:// or https://
fn validate_rpc_url(url: &str) -> bool {
    // Check URL format
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return false;
    }
    true
}

// Check if all RPC URLs in the config file are valid.
fn validate_rpc_urls_from_config(urls: &[String]) -> bool {
    for url in urls {
        if !validate_rpc_url(url) {
            return false;
        }
    }
    true
}

// Check if all names in the config file are valid.
fn validate_names_not_reserved(
    names_from_config: &Vec<String>,
    part_of_config: String,
) -> Result<(), Box<dyn std::error::Error>> {
    let detected_reserved_words = check_reserved_words(&names_from_config.join(" "));
    if !detected_reserved_words.is_empty() {
        return Err(format!(
            "The config file cannot contain any reserved words. Reserved words are: {:?} in {}.",
            detected_reserved_words.join(" "),
            part_of_config
        )
        .into());
    }
    Ok(())
}

pub fn validate_deserialized_config_yaml(
    config_path: &PathBuf,
    deserialized_yaml: &Config,
) -> Result<(), Box<dyn std::error::Error>> {
    if !is_valid_postgres_db_name(&deserialized_yaml.name) {
        return Err(format!("The 'name' field in your config file ({}) must have the following pattern: It must start with a letter or underscore. It can contain letters, numbers, and underscores (no spaces). It must have a maximum length of 63 characters", &config_path.to_str().unwrap_or("unknown config file name path")).into());
    }

    // Retrieving details from config file as a vectors of String
    let mut contract_names = Vec::new();
    let mut contract_addresses = Vec::new();
    let mut event_names = Vec::new();
    let mut entity_and_label_names = Vec::new();
    let mut rpc_urls = Vec::new();

    for network in &deserialized_yaml.networks {
        rpc_urls.push(network.rpc_config.url.clone());
        for contract in &network.contracts {
            contract_names.push(contract.name.clone());
            contract_addresses.push(contract.address.clone());
            for event in &contract.events {
                event_names.push(event.event.get_name());
                if let Some(required_entities) = &event.required_entities {
                    for entity in required_entities {
                        entity_and_label_names.push(entity.name.clone());
                        for label in &entity.labels {
                            entity_and_label_names.push(label.clone());
                        }
                    }
                    // Checking that entity names and labels do not include any reserved words
                    validate_names_not_reserved(
                        &entity_and_label_names,
                        "Required Entities".to_string(),
                    )?;
                }
            }
            // Checking that event names do not include any reserved words
            validate_names_not_reserved(&event_names, "Events".to_string())?;
        }

        // Checking that contract names are non-unique
        if !are_contract_names_unique(&contract_names) {
            return Err(format!("The config file ({}) cannot have duplicate contract names. All contract names need to be unique, regardless of network. Contract names are not case-sensitive.", &config_path.to_str().unwrap_or("unknown config file name path")).into());
        }

        // Checking that contract names do not include any reserved words
        validate_names_not_reserved(&contract_names, "Contracts".to_string())?;
    }

    // Checking if contract addresses are valid addresses
    for a_contract_addressess in &contract_addresses {
        if !are_valid_ethereum_addresses(&a_contract_addressess.inner) {
            return Err(format!(
                "One of the contract addresses in the config file ({}) isn't valid",
                &config_path
                    .to_str()
                    .unwrap_or("unknown config file name path")
            )
            .into());
        }
    }

    // Checking if RPC URLs are valid
    if !validate_rpc_urls_from_config(&rpc_urls) {
        return Err(format!("The config file ({}) has RPC URL(s) in incorrect format. The RPC URLs need to start with either http:// or https://", &config_path.to_str().unwrap_or("unknown config file name path")).into());
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn valid_postgres_db_name() {
        let valid_name = "_helloPotter";
        let is_valid = super::is_valid_postgres_db_name(valid_name);
        assert!(is_valid);
    }

    #[test]
    fn invalid_postgres_db_name() {
        let invalid_name_space = "HarryShallNotReturn_to Hogwarts";
        let invalid_name_long =
            "Its_just_too_long_thats_what_she_said_michael_scott_the_office_series";
        let invalid_name_special_char = "HarryShallNotReturn_to Hogwart$";
        let is_not_valid_space = super::is_valid_postgres_db_name(invalid_name_space);
        let is_not_valid_long = super::is_valid_postgres_db_name(invalid_name_long);
        let is_not_special_chars = super::is_valid_postgres_db_name(invalid_name_special_char);
        assert!(!is_not_valid_space);
        assert!(!is_not_valid_long);
        assert!(!is_not_special_chars);
    }

    #[test]
    fn valid_ethereum_address() {
        let pure_number_address =
            super::is_valid_ethereum_address("0x1234567890123456789012345678901234567890");
        let mixed_case_address =
            super::is_valid_ethereum_address("0xabcdefABCDEF1234567890123456789012345678");
        assert!(pure_number_address);
        assert!(mixed_case_address);
    }

    #[test]
    fn invalid_ethereum_address() {
        let invalid_length_address =
            super::is_valid_ethereum_address("0x123456789012345678901234567890123456789");
        let invalid_characters =
            super::is_valid_ethereum_address("0xzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz");
        let invalid_start =
            super::is_valid_ethereum_address("123456789012345678901234567890123456789");
        assert!(!invalid_length_address);
        assert!(!invalid_characters);
        assert!(!invalid_start);
    }

    #[test]
    fn test_unique_contract_names() {
        let contract_names = vec![
            "Hello".to_string(),
            "HelloWorld".to_string(),
            "Hello_World".to_string(),
            "Hello_World_123".to_string(),
            "Hello_World_123_".to_string(),
            "_Hello_World_123".to_string(),
            "_Hello_World_123_".to_string(),
        ];
        let unique_contract_names = super::are_contract_names_unique(&contract_names);
        assert!(unique_contract_names);
    }

    #[test]
    fn test_non_unique_contract_names() {
        let contract_names = vec![
            "Hello".to_string(),
            "HelloWorld".to_string(),
            "Hello-World".to_string(),
            "Hello-world".to_string(),
            "Hello_World_123_".to_string(),
            "_Hello_World_123".to_string(),
            "_Hello_World_123".to_string(),
        ];
        let non_unique_contract_names = super::are_contract_names_unique(&contract_names);
        assert!(!non_unique_contract_names);
    }

    #[test]
    fn test_check_reserved_words() {
        let yaml_string =
            "This is a YAML string with reserved words like break, import, match and symbol.";
        let flagged_words = super::check_reserved_words(yaml_string);
        assert_eq!(
            flagged_words,
            vec!["string", "with", "break", "import", "match", "and", "symbol"]
        );
    }

    #[test]
    fn test_check_no_reserved_words() {
        let yaml_string =
            "This is a YAML without reserved words but has words like avocado plus mayo.";
        let flagged_words = super::check_reserved_words(yaml_string);
        let empty_vec: Vec<String> = Vec::new();
        assert_eq!(flagged_words, empty_vec);
    }

    #[test]
    fn test_valid_rpc_urls() {
        let valid_rpc_url_1 =
            "https://eth-mainnet.g.alchemy.com/v2/T7uPV59s7knYTOUardPPX0hq7n7_rQwv";
        let valid_rpc_url_2 = "http://api.example.org:8080";
        let valid_rpc_url_3 = "https://eth.com/rpc-endpoint";
        let is_valid_url_1 = super::validate_rpc_url(valid_rpc_url_1);
        let is_valid_url_2 = super::validate_rpc_url(valid_rpc_url_2);
        let is_valid_url_3 = super::validate_rpc_url(valid_rpc_url_3);
        assert!(is_valid_url_1);
        assert!(is_valid_url_2);
        assert!(is_valid_url_3);
    }

    #[test]
    fn test_invalid_rpc_urls() {
        let invalid_rpc_url_missing_slash = "http:/example.com";
        let invalid_rpc_url_other_protocol = "ftp://example.com";
        let is_invalid_missing_slash = super::validate_rpc_url(invalid_rpc_url_missing_slash);
        let is_invalid_other_protocol = super::validate_rpc_url(invalid_rpc_url_other_protocol);
        assert!(!is_invalid_missing_slash);
        assert!(!is_invalid_other_protocol);
    }
}
