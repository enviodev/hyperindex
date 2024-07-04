use convert_case::{Case, Casing};
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct CapitalizedOptions {
    pub capitalized: String,
    pub uncapitalized: String,
    pub original: String,
}

pub trait Capitalize {
    fn capitalize(&self) -> String;

    fn uncapitalize(&self) -> String;

    fn to_capitalized_options(&self) -> CapitalizedOptions;
}

impl Capitalize for String {
    fn capitalize(&self) -> String {
        let mut chars = self.chars();
        match chars.next() {
            None => String::new(),
            Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        }
    }
    fn uncapitalize(&self) -> String {
        let mut chars = self.chars();
        match chars.next() {
            None => String::new(),
            Some(first) => first.to_lowercase().collect::<String>() + chars.as_str(),
        }
    }

    fn to_capitalized_options(&self) -> CapitalizedOptions {
        let capitalized = self.capitalize();
        let uncapitalized = self.uncapitalize();

        CapitalizedOptions {
            capitalized,
            uncapitalized,
            original: self.clone(),
        }
    }
}

pub struct CaseOptions {
    pub pascal: String,
    pub snake: String,
    pub camel: String,
}

impl CaseOptions {
    pub fn new(s: &str) -> Self {
        Self {
            pascal: s.to_case(Case::Pascal),
            snake: s.to_case(Case::Snake),
            camel: s.to_case(Case::Camel),
        }
    }
}

impl From<String> for CaseOptions {
    fn from(value: String) -> Self {
        Self::new(&value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn string_capitalize() {
        let string = String::from("hello");
        let capitalized = string.capitalize();
        assert_eq!(capitalized, "Hello");
    }

    #[test]
    fn string_uncapitalize() {
        let string = String::from("Hello");
        let uncapitalized = string.uncapitalize();
        assert_eq!(uncapitalized, "hello");
    }

    #[test]
    fn string_to_capitalization_options() {
        let string = String::from("Hello");
        let capitalization_options = string.to_capitalized_options();
        assert_eq!(capitalization_options.uncapitalized, "hello");
        assert_eq!(capitalization_options.capitalized, "Hello");
        assert_eq!(capitalization_options.original, "Hello");
    }

    #[test]
    fn string_camel_to_capitalization_options() {
        let string = String::from("camelCase");
        let capitalization_options = string.to_capitalized_options();
        assert_eq!(capitalization_options.uncapitalized, "camelCase");
        assert_eq!(capitalization_options.capitalized, "CamelCase");
        assert_eq!(capitalization_options.original, "camelCase");
    }

    #[test]
    fn casing_works() {
        let case_options = CaseOptions::new("TransactionIndex");
        assert_eq!(case_options.snake, "transaction_index");
        assert_eq!(case_options.pascal, "TransactionIndex");
        assert_eq!(case_options.camel, "transactionIndex");
    }
}
