use regex::Regex;
use std::collections::HashSet;

use super::constants::RESERVED_WORDS;

// It must start with a letter or underscore.
// It can contain letters, numbers, and underscores.
// It must have a maximum length of 63 characters (the first character + 62 subsequent characters)
pub fn is_valid_postgres_db_name(name: &str) -> bool {
    let re = Regex::new(r"^[a-zA-Z_][a-zA-Z0-9_]{0,62}$").unwrap();
    re.is_match(name)
}

pub fn is_valid_ethereum_address(address: &str) -> bool {
    let re = Regex::new(r"^0x[0-9a-fA-F]{40}$").unwrap();
    re.is_match(address)
}

pub fn are_valid_ethereum_addresses(addresses: &[String]) -> bool {
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
pub fn are_contract_names_unique(contract_names: &[String]) -> bool {
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
pub fn check_reserved_words(input_string: &str) -> Vec<String> {
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
pub fn validate_rpc_url(url: &str) -> bool {
    // Check URL format
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return false;
    }
    return true;
}

pub fn validate_rpc_urls_from_config(urls: &[String]) -> bool {
    for url in urls {
        if !validate_rpc_url(url) {
            return false;
        }
    }
    true
}

#[cfg(test)]
mod tests {
    #[test]
    fn valid_postgres_db_name() {
        let valid_name = "_helloPotter";
        let is_valid = super::is_valid_postgres_db_name(valid_name);
        assert_eq!(is_valid, true);
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
        assert_eq!(is_not_valid_space, false);
        assert_eq!(is_not_valid_long, false);
        assert_eq!(is_not_special_chars, false);
    }

    #[test]
    fn valid_ethereum_address() {
        let pure_number_address =
            super::is_valid_ethereum_address("0x1234567890123456789012345678901234567890");
        let mixed_case_address =
            super::is_valid_ethereum_address("0xabcdefABCDEF1234567890123456789012345678");
        assert_eq!(pure_number_address, true);
        assert_eq!(mixed_case_address, true);
    }

    #[test]
    fn invalid_ethereum_address() {
        let invalid_length_address =
            super::is_valid_ethereum_address("0x123456789012345678901234567890123456789");
        let invalid_characters =
            super::is_valid_ethereum_address("0xzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz");
        let invalid_start =
            super::is_valid_ethereum_address("123456789012345678901234567890123456789");
        assert_eq!(invalid_length_address, false);
        assert_eq!(invalid_characters, false);
        assert_eq!(invalid_start, false);
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
        assert_eq!(unique_contract_names, true);
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
        assert_eq!(non_unique_contract_names, false);
    }

    #[test]
    fn test_check_reserved_words() {
        let yaml_string =
            "This is a YAML string with reserved words like break, import, and match.";
        let flagged_words = super::check_reserved_words(yaml_string);
        assert_eq!(
            flagged_words,
            vec!["with", "break", "import", "and", "match"]
        );
    }

    #[test]
    fn test_check_no_reserved_words() {
        let yaml_string =
            "This is a YAML string without reserved words but has words like avocado plus mayo.";
        let flagged_words = super::check_reserved_words(yaml_string);
        let empty_vec: Vec<String> = Vec::new();
        assert_eq!(flagged_words, empty_vec);
    }
    fn test_valid_rpc_urls() {
        let valid_rpc_url_1 =
            "https://eth-mainnet.g.alchemy.com/v2/T7uPV59s7knYTOUardPPX0hq7n7_rQwv";
        let valid_rpc_url_2 = "https://api.example.org:8080";
        let valid_rpc_url_3 = "https://eth.com/rpc-endpoint";
        let is_valid_url_1 = super::validate_rpc_url(valid_rpc_url_1);
        let is_valid_url_2 = super::validate_rpc_url(valid_rpc_url_2);
        let is_valid_url_3 = super::validate_rpc_url(valid_rpc_url_3);
        assert_eq!(is_valid_url_1, true);
        // assert_eq!(is_valid_url_2, true);
        // assert_eq!(is_valid_url_3, true);
    }

    #[test]
    fn test_invalid_rpc_urls() {
        let invalid_rpc_url_missing_slash = "http:/example.com";
        let invalid_rpc_url_other_protocol = "ftp://example.com";

        let is_invalid_missing_slash = super::validate_rpc_url(invalid_rpc_url_missing_slash);
        let is_invalid_other_protocol = super::validate_rpc_url(invalid_rpc_url_other_protocol);
        assert_eq!(is_invalid_missing_slash, false);
        assert_eq!(is_invalid_other_protocol, false);
    }
}
