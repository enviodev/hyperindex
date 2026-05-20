// use super::chain_helpers;
use super::human_config::{self, evm::HumanConfig};
use crate::constants::reserved_keywords::{
    ENVIO_INTERNAL_RESERVED_POSTGRES_TYPES, JAVASCRIPT_RESERVED_WORDS, RESCRIPT_RESERVED_WORDS,
    TYPESCRIPT_RESERVED_WORDS,
};
use anyhow::{anyhow, Context};
use regex::Regex;
use std::collections::HashSet;

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
fn check_reserved_words(words: &Vec<String>) -> Vec<String> {
    let mut flagged_words = Vec::new();
    // Creating a deduplicated set of reserved words from javascript, typescript and rescript
    let mut set = HashSet::new();
    set.extend(JAVASCRIPT_RESERVED_WORDS.iter());
    set.extend(TYPESCRIPT_RESERVED_WORDS.iter());
    set.extend(RESCRIPT_RESERVED_WORDS.iter());

    let words_set: Vec<&str> = set.into_iter().cloned().collect();

    // Find all alphanumeric words in the YAML string
    for word in words {
        let word = word.as_str();
        if words_set.contains(&word) {
            flagged_words.push(word.to_string());
        }
    }

    flagged_words
}

fn is_valid_identifier(s: &str) -> bool {
    // Check if the string is empty
    if s.is_empty() {
        return false;
    }

    // Check the first character to ensure it's not a digit
    let first_char = s.chars().next().unwrap();
    if let '0'..='9' = first_char {
        return false;
    }

    // Check that all characters are either alphanumeric or an underscore
    for c in s.chars() {
        match c {
            'a'..='z' | 'A'..='Z' | '0'..='9' | '_' => (),
            _ => return false,
        }
    }

    true
}

// Check if all names in the config file are valid.
pub fn validate_names_valid_rescript(
    names_from_config: &Vec<String>,
    part_of_config: String,
) -> anyhow::Result<()> {
    let detected_reserved_words = check_reserved_words(names_from_config);
    if !detected_reserved_words.is_empty() {
        return Err(anyhow!(
            "The config contains reserved words for {} names: {}. They are used for the \
             generated code and must be valid identifiers, containing only alphanumeric \
             characters and underscores.",
            part_of_config,
            detected_reserved_words
                .iter()
                .map(|w| format!("\"{}\"", w))
                .collect::<Vec<_>>()
                .join(", "),
        ));
    }

    let mut invalid_names = Vec::new();
    for name in names_from_config {
        if !is_valid_identifier(name) {
            invalid_names.push(name.to_string());
        }
    }
    if !invalid_names.is_empty() {
        return Err(anyhow!(
            "The config contains invalid characters for {} names: {}. They are used for \
             the generated code and must be valid identifiers, containing only alphanumeric \
             characters and underscores.",
            part_of_config,
            invalid_names
                .iter()
                .map(|w| format!("\"{}\"", w))
                .collect::<Vec<_>>()
                .join(", "),
        ));
    }

    Ok(())
}

impl human_config::evm::Chain {
    pub fn validate_finite_endblock_networks(&self) -> anyhow::Result<()> {
        Ok(())
    }

    pub fn validate_endblock_lte_startblock(&self) -> anyhow::Result<()> {
        if let Some(network_endblock) = self.end_block {
            if network_endblock < self.start_block {
                return Err(anyhow!(
                    "The config file has an endBlock that is less than the startBlock for \
                     network id: {}. The endBlock must be greater than the startBlock.",
                    &self.id.to_string()
                ));
            }
        }
        Ok(())
    }
}

pub fn validate_deserialized_config_yaml(evm_config: &HumanConfig) -> anyhow::Result<()> {
    let mut contract_names = Vec::new();

    if let Some(global_contracts) = &evm_config.contracts {
        for global_contract in global_contracts {
            contract_names.push(global_contract.name.clone());
        }
    }

    for chain in &evm_config.chains {
        // validate endblock is a greater than the startblock
        chain.validate_endblock_lte_startblock()?;
        chain.validate_finite_endblock_networks()?;

        for contract in chain.contracts.as_ref().unwrap_or(&vec![]) {
            if contract.config.as_ref().is_some() {
                contract_names.push(contract.name.clone());
            }

            // Checking if contract addresses are valid addresses
            for contract_address in contract.address.clone().into_iter() {
                if !is_valid_ethereum_address(&contract_address) {
                    return Err(anyhow!(
                        "One of the contract addresses in the config file isn't valid",
                    ));
                }
            }
        }
    }
    // Checking that contract names are non-unique
    if !are_contract_names_unique(&contract_names) {
        return Err(anyhow!(
            "Duplicate contract names detected. All contract names must be unique across all networks, and are case-insensitive. \
     For multichain indexing, consider using a global contract definition. More information is available at: https://docs.envio.dev/docs/HyperIndex/multichain-indexing",
        ));
    }

    validate_names_valid_rescript(&contract_names, "contract".to_string())?;

    Ok(())
}

pub fn is_valid_solana_pubkey(s: &str) -> bool {
    // Base58 alphabet: 1-9, A-H, J-N, P-Z, a-k, m-z (no 0, O, I, l).
    // Encoded 32-byte values are 32-44 chars (typically 43-44).
    let len = s.len();
    if !(32..=44).contains(&len) {
        return false;
    }
    s.bytes().all(|b| {
        matches!(b,
            b'1'..=b'9'
            | b'A'..=b'H'
            | b'J'..=b'N'
            | b'P'..=b'Z'
            | b'a'..=b'k'
            | b'm'..=b'z'
        )
    })
}

pub fn validate_svm_discriminator(s: &str) -> anyhow::Result<()> {
    let hex = s.strip_prefix("0x").unwrap_or(s);
    if !matches!(hex.len(), 2 | 4 | 8 | 16) {
        return Err(anyhow!(
            "discriminator {:?} must be 1, 2, 4, or 8 bytes (i.e. 2, 4, 8, or 16 hex digits \
             after stripping a `0x` prefix), got {} digits",
            s,
            hex.len()
        ));
    }
    if !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(anyhow!("discriminator {:?} contains non-hex characters", s));
    }
    Ok(())
}

pub fn validate_deserialized_svm_config_yaml(
    svm_config: &super::human_config::svm::HumanConfig,
) -> anyhow::Result<()> {
    let mut all_program_names: Vec<String> = Vec::new();

    for chain in &svm_config.chains {
        for program in chain.programs.as_ref().unwrap_or(&vec![]) {
            if !is_valid_solana_pubkey(&program.program_id) {
                return Err(anyhow!(
                    "Program {:?} has an invalid program_id {:?}: must be a base58-encoded \
                     32-byte Solana pubkey",
                    program.name,
                    program.program_id
                ));
            }
            all_program_names.push(program.name.clone());

            let mut instruction_names = std::collections::HashSet::new();
            for instr in &program.instructions {
                if !instruction_names.insert(instr.name.clone()) {
                    return Err(anyhow!(
                        "Program {:?} declares the instruction {:?} more than once",
                        program.name,
                        instr.name
                    ));
                }
                if let Some(discriminator) = &instr.discriminator {
                    validate_svm_discriminator(discriminator).with_context(|| {
                        format!("instruction {:?} in program {:?}", instr.name, program.name)
                    })?;
                }
                for filter in instr.account_filters.as_ref().unwrap_or(&vec![]) {
                    if filter.position > 9 {
                        return Err(anyhow!(
                            "Account filter position {} in instruction {:?} (program {:?}) \
                             must be in 0..=9",
                            filter.position,
                            instr.name,
                            program.name
                        ));
                    }
                    for value in &filter.values {
                        if !is_valid_solana_pubkey(value) {
                            return Err(anyhow!(
                                "Account filter on instruction {:?} (program {:?}) has an \
                                 invalid base58 pubkey {:?}",
                                instr.name,
                                program.name,
                                value
                            ));
                        }
                    }
                }
            }
        }
    }

    if !are_contract_names_unique(&all_program_names) {
        return Err(anyhow!(
            "Duplicate program names detected. All program names must be unique across all \
             chains and are case-insensitive."
        ));
    }
    validate_names_valid_rescript(&all_program_names, "program".to_string())?;

    Ok(())
}

pub fn check_enums_for_internal_reserved_words(enum_name_words: Vec<String>) -> Vec<String> {
    enum_name_words
        .into_iter()
        .filter(|word| ENVIO_INTERNAL_RESERVED_POSTGRES_TYPES.contains(&word.as_str()))
        .collect()
}

// Checking that schema does not include any reserved words
pub fn check_names_from_schema_for_reserved_words(schema_words: Vec<String>) -> Vec<String> {
    // Checking that schema does not include any reserved words
    let mut detected_reserved_words_in_schema = Vec::new();
    // Creating a deduplicated set of reserved words from javascript or rescript
    let mut word_set: HashSet<&str> = HashSet::new();
    word_set.extend(JAVASCRIPT_RESERVED_WORDS.iter());
    word_set.extend(RESCRIPT_RESERVED_WORDS.iter());
    for word in schema_words {
        if word_set.contains(word.as_str()) {
            detected_reserved_words_in_schema.push(word);
        }
    }

    detected_reserved_words_in_schema
}

pub fn check_schema_enums_are_valid_postgres(enum_names: &Vec<String>) -> Vec<String> {
    let mut detected_enum_not_valid = Vec::new();
    for name in enum_names {
        if !is_valid_postgres_db_name(name.as_str()) {
            detected_enum_not_valid.push(name.clone());
        }
    }
    detected_enum_not_valid
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

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
        let words = vec![
            "This".to_string(),
            "is".to_string(),
            "a".to_string(),
            "YAML".to_string(),
            "string".to_string(),
            "with".to_string(),
            "reserved".to_string(),
            "words".to_string(),
            "like".to_string(),
            "break".to_string(),
            "import".to_string(),
            "and".to_string(),
            "symbol".to_string(),
            "plus".to_string(),
            "unreserved".to_string(),
            "word".to_string(),
            "like".to_string(),
            "match.".to_string(),
        ];
        let flagged_words = super::check_reserved_words(&words);
        assert_eq!(
            flagged_words,
            vec!["string", "with", "break", "import", "and", "symbol"]
        );
    }

    #[test]
    fn test_check_no_reserved_words() {
        let words = vec![
            "This".to_string(),
            "is".to_string(),
            "a".to_string(),
            "YAML".to_string(),
            "without".to_string(),
            "reserved".to_string(),
            "words".to_string(),
            "but".to_string(),
            "has".to_string(),
            "words".to_string(),
            "like".to_string(),
            "avocado".to_string(),
            "plus".to_string(),
            "mayo.".to_string(),
        ];
        let flagged_words = super::check_reserved_words(&words);
        let empty_vec: Vec<String> = Vec::new();
        assert_eq!(flagged_words, empty_vec);
    }

    #[test]
    fn test_names_from_schema_for_reserved_words() {
        let names_from_schema = "Greeting id greetings lastGreeting lazy open catch"
            .split(" ")
            .map(|s| s.to_string())
            .collect();
        let flagged_words = super::check_names_from_schema_for_reserved_words(names_from_schema);
        assert_eq!(flagged_words, vec!["lazy", "open", "catch"]);
    }

    #[test]
    fn test_contract_names_validation() {
        let valid_result = super::validate_names_valid_rescript(
            &vec![
                "foo".to_string(),
                "MyContract".to_string(),
                "_Bar".to_string(),
            ],
            "contract".to_string(),
        );
        assert!(valid_result.is_ok());

        let reserved_names = super::validate_names_valid_rescript(
            &vec![
                "foo".to_string(),
                "MyContract".to_string(),
                "_Bar".to_string(),
                "Let".to_string(),
                "module".to_string(),
                "this".to_string(),
                "1".to_string(),
            ],
            "contract".to_string(),
        );
        assert_eq!(
            reserved_names.unwrap_err().to_string(),
            "The config contains reserved words for contract names: \"module\", \"this\". \
             They are used for the generated code and must be valid identifiers, containing only \
             alphanumeric characters and underscores."
        );

        let invalid_names = super::validate_names_valid_rescript(
            &vec![
                "foo".to_string(),
                "MyContract".to_string(),
                "_Bar".to_string(),
                "Let".to_string(),
                "1StartsWithNumber".to_string(),
                "Has1Number".to_string(),
                "Has-Hyphen".to_string(),
                "Has.Dot".to_string(),
                "Has Space".to_string(),
                "Has\"Quote".to_string(),
            ],
            "contract".to_string(),
        );
        assert_eq!(
            invalid_names.unwrap_err().to_string(),
            "The config contains invalid characters for contract names: \
             \"1StartsWithNumber\", \"Has-Hyphen\", \"Has.Dot\", \"Has Space\", \"Has\"Quote\". \
             They are used for the generated code and must be valid identifiers, containing only \
             alphanumeric characters and underscores."
        );
    }

    mod svm {
        use crate::config_parsing::human_config::svm::HumanConfig;
        use crate::config_parsing::validation::{
            is_valid_solana_pubkey, validate_deserialized_svm_config_yaml,
            validate_svm_discriminator,
        };

        const TOKEN_METADATA: &str = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s";

        #[test]
        fn pubkey_accepts_real_program_ids() {
            assert!(is_valid_solana_pubkey(TOKEN_METADATA));
            // System program (32 ones; base58 lower bound).
            assert!(is_valid_solana_pubkey("11111111111111111111111111111111"));
        }

        #[test]
        fn pubkey_rejects_garbage() {
            assert!(!is_valid_solana_pubkey(""));
            assert!(!is_valid_solana_pubkey("short"));
            // Contains '0' which is not in the base58 alphabet.
            assert!(!is_valid_solana_pubkey(
                "0mp02000000000000000000000000000000000000000"
            ));
            // Too long.
            assert!(!is_valid_solana_pubkey(&"1".repeat(64)));
        }

        #[test]
        fn discriminator_accepts_valid_lengths() {
            for s in ["0x0f", "0x0fff", "0x0fffffff", "0x0fffffffffffffff"] {
                assert!(
                    validate_svm_discriminator(s).is_ok(),
                    "expected {s:?} to be valid"
                );
            }
            // Prefix is optional.
            assert!(validate_svm_discriminator("0f").is_ok());
        }

        #[test]
        fn discriminator_rejects_invalid_lengths_and_chars() {
            for s in ["0x", "0x0", "0x012", "0xggggggg"] {
                assert!(
                    validate_svm_discriminator(s).is_err(),
                    "expected {s:?} to be rejected"
                );
            }
        }

        fn parse(yaml: &str) -> HumanConfig {
            serde_yaml::from_str(yaml).unwrap()
        }

        #[test]
        fn validation_accepts_a_minimal_program() {
            let cfg = parse(
                r#"
name: x
ecosystem: svm
chains:
  - rpc: r
    start_block: 0
    programs:
      - name: TokenMetadata
        program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
        instructions:
          - name: UpdateMetadataAccountV2
            discriminator: "0x0f"
"#,
            );
            validate_deserialized_svm_config_yaml(&cfg).unwrap();
        }

        #[test]
        fn validation_rejects_duplicate_instruction_names() {
            let cfg = parse(
                r#"
name: x
ecosystem: svm
chains:
  - rpc: r
    start_block: 0
    programs:
      - name: P
        program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
        instructions:
          - { name: Foo, discriminator: "0x0f" }
          - { name: Foo, discriminator: "0x21" }
"#,
            );
            let err = validate_deserialized_svm_config_yaml(&cfg).unwrap_err();
            assert!(err.to_string().contains("more than once"), "{err}");
        }

        #[test]
        fn validation_rejects_duplicate_program_names_across_chains() {
            let cfg = parse(
                r#"
name: x
ecosystem: svm
chains:
  - rpc: r
    start_block: 0
    programs:
      - name: shared
        program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
        instructions: []
  - rpc: r2
    start_block: 0
    programs:
      - name: SHARED
        program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
        instructions: []
"#,
            );
            let err = validate_deserialized_svm_config_yaml(&cfg).unwrap_err();
            assert!(err.to_string().contains("Duplicate program names"), "{err}");
        }

        #[test]
        fn validation_rejects_account_filter_position_out_of_range() {
            let cfg = parse(
                r#"
name: x
ecosystem: svm
chains:
  - rpc: r
    start_block: 0
    programs:
      - name: P
        program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
        instructions:
          - name: I
            account_filters:
              - position: 10
                values: ["metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"]
"#,
            );
            let err = validate_deserialized_svm_config_yaml(&cfg).unwrap_err();
            assert!(err.to_string().contains("0..=9"), "{err}");
        }

        #[test]
        fn validation_rejects_bad_program_id() {
            let cfg = parse(
                r#"
name: x
ecosystem: svm
chains:
  - rpc: r
    start_block: 0
    programs:
      - name: P
        program_id: not_a_pubkey
        instructions: []
"#,
            );
            let err = validate_deserialized_svm_config_yaml(&cfg).unwrap_err();
            assert!(err.to_string().contains("invalid program_id"), "{err}");
        }
    }
}
