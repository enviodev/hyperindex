use std::str::FromStr;

use hypersync_client::net_types::{
    block::BlockField, log::LogField, transaction::TransactionField,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Section {
    Block,
    Transaction,
    Log,
}

impl Section {
    pub fn as_indexer_str(self) -> &'static str {
        match self {
            Section::Block => "block",
            Section::Transaction => "transaction",
            Section::Log => "log",
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub enum TypedField {
    Block(BlockField),
    Transaction(TransactionField),
    Log(LogField),
}

impl TypedField {
    pub fn column_name(self) -> String {
        match self {
            TypedField::Block(f) => f.to_string(),
            TypedField::Transaction(f) => f.to_string(),
            TypedField::Log(f) => f.to_string(),
        }
    }
}

fn alias(indexer_name: &str) -> &str {
    match indexer_name {
        "srcAddress" => "address",
        other => other,
    }
}

fn to_snake(camel: &str) -> String {
    let aliased = alias(camel);
    let mut out = String::with_capacity(aliased.len() + 4);
    for (i, ch) in aliased.chars().enumerate() {
        if ch.is_ascii_uppercase() && i > 0 {
            out.push('_');
        }
        out.push(ch.to_ascii_lowercase());
    }
    out
}

fn to_camel(snake: &str) -> String {
    match snake {
        "address" => return "srcAddress".to_string(),
        _ => {}
    }
    let mut out = String::with_capacity(snake.len());
    let mut capitalize_next = false;
    for ch in snake.chars() {
        if ch == '_' {
            capitalize_next = true;
        } else if capitalize_next {
            out.push(ch.to_ascii_uppercase());
            capitalize_next = false;
        } else {
            out.push(ch);
        }
    }
    out
}

pub fn lookup(section: Section, indexer_name: &str) -> Option<TypedField> {
    let snake = to_snake(indexer_name);
    match section {
        Section::Block => BlockField::from_str(&snake).ok().map(TypedField::Block),
        Section::Transaction => TransactionField::from_str(&snake)
            .ok()
            .map(TypedField::Transaction),
        Section::Log => LogField::from_str(&snake).ok().map(TypedField::Log),
    }
}

pub fn valid_indexer_names(section: Section) -> Vec<String> {
    use strum::IntoEnumIterator;
    match section {
        Section::Block => BlockField::iter()
            .map(|f| to_camel(&f.to_string()))
            .collect(),
        Section::Transaction => TransactionField::iter()
            .map(|f| to_camel(&f.to_string()))
            .collect(),
        Section::Log => LogField::iter().map(|f| to_camel(&f.to_string())).collect(),
    }
}

pub fn parse_section(raw: &str) -> Option<Section> {
    match raw {
        "block" => Some(Section::Block),
        "transaction" => Some(Section::Transaction),
        "log" => Some(Section::Log),
        _ => None,
    }
}

pub const ALLOWED_SECTIONS: &[&str] = &["block", "transaction", "log"];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lookup_standard_fields() {
        assert!(matches!(
            lookup(Section::Block, "gasLimit"),
            Some(TypedField::Block(BlockField::GasLimit))
        ));
        assert!(matches!(
            lookup(Section::Transaction, "transactionIndex"),
            Some(TypedField::Transaction(TransactionField::TransactionIndex))
        ));
        assert!(matches!(
            lookup(Section::Log, "topic0"),
            Some(TypedField::Log(LogField::Topic0))
        ));
    }

    #[test]
    fn lookup_src_address_alias() {
        assert!(matches!(
            lookup(Section::Log, "srcAddress"),
            Some(TypedField::Log(LogField::Address))
        ));
    }

    #[test]
    fn lookup_unknown_returns_none() {
        assert!(lookup(Section::Block, "bogus").is_none());
    }

    #[test]
    fn valid_names_include_src_address() {
        let names = valid_indexer_names(Section::Log);
        assert!(names.contains(&"srcAddress".to_string()), "{names:?}");
    }

    #[test]
    fn column_name_is_snake_case() {
        let f = lookup(Section::Block, "gasLimit").unwrap();
        assert_eq!(f.column_name(), "gas_limit");
    }
}
