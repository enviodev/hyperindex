use regex::Regex;

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
}
