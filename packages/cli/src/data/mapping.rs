use hypersync_client::net_types::{
    block::BlockField, log::LogField, transaction::TransactionField,
};
use strum::IntoEnumIterator;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnFormat {
    Decimal,
    Hex,
}

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

    pub fn camel_name(self) -> String {
        to_camel(&self.column_name())
    }

    pub fn column_format(self) -> ColumnFormat {
        match self {
            TypedField::Block(f) => match f {
                BlockField::Number
                | BlockField::Size
                | BlockField::GasLimit
                | BlockField::GasUsed
                | BlockField::Timestamp
                | BlockField::Nonce
                | BlockField::Difficulty
                | BlockField::TotalDifficulty
                | BlockField::BaseFeePerGas
                | BlockField::BlobGasUsed
                | BlockField::ExcessBlobGas
                | BlockField::L1BlockNumber
                | BlockField::SendCount => ColumnFormat::Decimal,
                BlockField::Hash
                | BlockField::ParentHash
                | BlockField::Sha3Uncles
                | BlockField::LogsBloom
                | BlockField::TransactionsRoot
                | BlockField::StateRoot
                | BlockField::ReceiptsRoot
                | BlockField::Miner
                | BlockField::ExtraData
                | BlockField::MixHash
                | BlockField::Uncles
                | BlockField::ParentBeaconBlockRoot
                | BlockField::WithdrawalsRoot
                | BlockField::Withdrawals
                | BlockField::SendRoot => ColumnFormat::Hex,
            },
            TypedField::Transaction(f) => match f {
                TransactionField::BlockNumber
                | TransactionField::Gas
                | TransactionField::Nonce
                | TransactionField::TransactionIndex
                | TransactionField::Value
                | TransactionField::CumulativeGasUsed
                | TransactionField::EffectiveGasPrice
                | TransactionField::GasUsed
                | TransactionField::GasPrice
                | TransactionField::V
                | TransactionField::R
                | TransactionField::S
                | TransactionField::MaxPriorityFeePerGas
                | TransactionField::MaxFeePerGas
                | TransactionField::ChainId
                | TransactionField::Type
                | TransactionField::Status
                | TransactionField::YParity
                | TransactionField::L1Fee
                | TransactionField::L1GasPrice
                | TransactionField::L1GasUsed
                | TransactionField::L1FeeScalar
                | TransactionField::GasUsedForL1
                | TransactionField::MaxFeePerBlobGas
                | TransactionField::BlobGasPrice
                | TransactionField::BlobGasUsed
                | TransactionField::DepositNonce
                | TransactionField::DepositReceiptVersion
                | TransactionField::Mint
                | TransactionField::L1BaseFeeScalar
                | TransactionField::L1BlobBaseFee
                | TransactionField::L1BlobBaseFeeScalar
                | TransactionField::L1BlockNumber => ColumnFormat::Decimal,
                TransactionField::BlockHash
                | TransactionField::Hash
                | TransactionField::Input
                | TransactionField::LogsBloom
                | TransactionField::From
                | TransactionField::To
                | TransactionField::ContractAddress
                | TransactionField::Root
                | TransactionField::AccessList
                | TransactionField::AuthorizationList
                | TransactionField::BlobVersionedHashes
                | TransactionField::Sighash
                | TransactionField::SourceHash => ColumnFormat::Hex,
            },
            TypedField::Log(f) => match f {
                LogField::BlockNumber | LogField::TransactionIndex | LogField::LogIndex => {
                    ColumnFormat::Decimal
                }
                LogField::TransactionHash
                | LogField::BlockHash
                | LogField::Address
                | LogField::Data
                | LogField::Removed
                | LogField::Topic0
                | LogField::Topic1
                | LogField::Topic2
                | LogField::Topic3 => ColumnFormat::Hex,
            },
        }
    }
}

fn normalize(s: &str) -> String {
    s.chars()
        .filter(|c| *c != '_')
        .map(|c| c.to_ascii_lowercase())
        .collect()
}

fn resolve_alias(section: Section, normalized: &str) -> Option<TypedField> {
    match (section, normalized) {
        (Section::Log, "srcaddress") => Some(TypedField::Log(LogField::Address)),
        _ => None,
    }
}

pub fn lookup(section: Section, user_input: &str) -> Option<TypedField> {
    let key = normalize(user_input);

    if let Some(field) = resolve_alias(section, &key) {
        return Some(field);
    }

    match section {
        Section::Block => BlockField::iter()
            .find(|f| normalize(f.as_ref()) == key)
            .map(TypedField::Block),
        Section::Transaction => TransactionField::iter()
            .find(|f| normalize(f.as_ref()) == key)
            .map(TypedField::Transaction),
        Section::Log => LogField::iter()
            .find(|f| normalize(f.as_ref()) == key)
            .map(TypedField::Log),
    }
}

fn to_camel(snake: &str) -> String {
    if snake == "address" {
        return "srcAddress".to_string();
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

pub fn valid_indexer_names(section: Section) -> Vec<String> {
    match section {
        Section::Block => BlockField::iter().map(|f| to_camel(f.as_ref())).collect(),
        Section::Transaction => TransactionField::iter()
            .map(|f| to_camel(f.as_ref()))
            .collect(),
        Section::Log => LogField::iter().map(|f| to_camel(f.as_ref())).collect(),
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
    fn lookup_camel_case() {
        assert!(matches!(
            lookup(Section::Block, "gasLimit"),
            Some(TypedField::Block(BlockField::GasLimit))
        ));
        assert!(matches!(
            lookup(Section::Transaction, "transactionIndex"),
            Some(TypedField::Transaction(TransactionField::TransactionIndex))
        ));
    }

    #[test]
    fn lookup_snake_case() {
        assert!(matches!(
            lookup(Section::Block, "gas_limit"),
            Some(TypedField::Block(BlockField::GasLimit))
        ));
        assert!(matches!(
            lookup(Section::Transaction, "transaction_index"),
            Some(TypedField::Transaction(TransactionField::TransactionIndex))
        ));
    }

    #[test]
    fn lookup_all_lowercase() {
        assert!(matches!(
            lookup(Section::Block, "gaslimit"),
            Some(TypedField::Block(BlockField::GasLimit))
        ));
        assert!(matches!(
            lookup(Section::Block, "sha3uncles"),
            Some(TypedField::Block(BlockField::Sha3Uncles))
        ));
    }

    #[test]
    fn lookup_uppercase_mixed() {
        assert!(matches!(
            lookup(Section::Block, "GAS_LIMIT"),
            Some(TypedField::Block(BlockField::GasLimit))
        ));
        assert!(matches!(
            lookup(Section::Block, "GASLIMIT"),
            Some(TypedField::Block(BlockField::GasLimit))
        ));
    }

    #[test]
    fn lookup_src_address_alias() {
        assert!(matches!(
            lookup(Section::Log, "srcAddress"),
            Some(TypedField::Log(LogField::Address))
        ));
        assert!(matches!(
            lookup(Section::Log, "src_address"),
            Some(TypedField::Log(LogField::Address))
        ));
        assert!(matches!(
            lookup(Section::Log, "SRCADDRESS"),
            Some(TypedField::Log(LogField::Address))
        ));
    }

    #[test]
    fn lookup_address_directly() {
        assert!(matches!(
            lookup(Section::Log, "address"),
            Some(TypedField::Log(LogField::Address))
        ));
    }

    #[test]
    fn lookup_topic_fields() {
        assert!(matches!(
            lookup(Section::Log, "topic0"),
            Some(TypedField::Log(LogField::Topic0))
        ));
        assert!(matches!(
            lookup(Section::Log, "TOPIC3"),
            Some(TypedField::Log(LogField::Topic3))
        ));
    }

    #[test]
    fn lookup_unknown_returns_none() {
        assert!(lookup(Section::Block, "bogus").is_none());
        assert!(lookup(Section::Log, "nonexistent").is_none());
    }

    #[test]
    fn valid_names_use_camel_case() {
        let names = valid_indexer_names(Section::Block);
        assert!(names.contains(&"gasLimit".to_string()), "{names:?}");
        assert!(names.contains(&"baseFeePerGas".to_string()), "{names:?}");
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

    #[test]
    fn normalize_strips_underscores_and_lowercases() {
        assert_eq!(normalize("gas_Limit"), "gaslimit");
        assert_eq!(normalize("GAS_LIMIT"), "gaslimit");
        assert_eq!(normalize("gasLimit"), "gaslimit");
        assert_eq!(normalize("topic0"), "topic0");
    }
}
