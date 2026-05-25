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

#[derive(Debug, Clone, Copy)]
pub struct FieldEntry {
    pub indexer_name: &'static str,
    pub section: Section,
    pub field: TypedField,
}

const EVM_FIELDS: &[FieldEntry] = &[
    // block.*
    FieldEntry {
        indexer_name: "number",
        section: Section::Block,
        field: TypedField::Block(BlockField::Number),
    },
    FieldEntry {
        indexer_name: "hash",
        section: Section::Block,
        field: TypedField::Block(BlockField::Hash),
    },
    FieldEntry {
        indexer_name: "parentHash",
        section: Section::Block,
        field: TypedField::Block(BlockField::ParentHash),
    },
    FieldEntry {
        indexer_name: "nonce",
        section: Section::Block,
        field: TypedField::Block(BlockField::Nonce),
    },
    FieldEntry {
        indexer_name: "sha3Uncles",
        section: Section::Block,
        field: TypedField::Block(BlockField::Sha3Uncles),
    },
    FieldEntry {
        indexer_name: "logsBloom",
        section: Section::Block,
        field: TypedField::Block(BlockField::LogsBloom),
    },
    FieldEntry {
        indexer_name: "transactionsRoot",
        section: Section::Block,
        field: TypedField::Block(BlockField::TransactionsRoot),
    },
    FieldEntry {
        indexer_name: "stateRoot",
        section: Section::Block,
        field: TypedField::Block(BlockField::StateRoot),
    },
    FieldEntry {
        indexer_name: "receiptsRoot",
        section: Section::Block,
        field: TypedField::Block(BlockField::ReceiptsRoot),
    },
    FieldEntry {
        indexer_name: "miner",
        section: Section::Block,
        field: TypedField::Block(BlockField::Miner),
    },
    FieldEntry {
        indexer_name: "difficulty",
        section: Section::Block,
        field: TypedField::Block(BlockField::Difficulty),
    },
    FieldEntry {
        indexer_name: "totalDifficulty",
        section: Section::Block,
        field: TypedField::Block(BlockField::TotalDifficulty),
    },
    FieldEntry {
        indexer_name: "extraData",
        section: Section::Block,
        field: TypedField::Block(BlockField::ExtraData),
    },
    FieldEntry {
        indexer_name: "size",
        section: Section::Block,
        field: TypedField::Block(BlockField::Size),
    },
    FieldEntry {
        indexer_name: "gasLimit",
        section: Section::Block,
        field: TypedField::Block(BlockField::GasLimit),
    },
    FieldEntry {
        indexer_name: "gasUsed",
        section: Section::Block,
        field: TypedField::Block(BlockField::GasUsed),
    },
    FieldEntry {
        indexer_name: "timestamp",
        section: Section::Block,
        field: TypedField::Block(BlockField::Timestamp),
    },
    FieldEntry {
        indexer_name: "uncles",
        section: Section::Block,
        field: TypedField::Block(BlockField::Uncles),
    },
    FieldEntry {
        indexer_name: "baseFeePerGas",
        section: Section::Block,
        field: TypedField::Block(BlockField::BaseFeePerGas),
    },
    FieldEntry {
        indexer_name: "blobGasUsed",
        section: Section::Block,
        field: TypedField::Block(BlockField::BlobGasUsed),
    },
    FieldEntry {
        indexer_name: "excessBlobGas",
        section: Section::Block,
        field: TypedField::Block(BlockField::ExcessBlobGas),
    },
    FieldEntry {
        indexer_name: "parentBeaconBlockRoot",
        section: Section::Block,
        field: TypedField::Block(BlockField::ParentBeaconBlockRoot),
    },
    FieldEntry {
        indexer_name: "withdrawalsRoot",
        section: Section::Block,
        field: TypedField::Block(BlockField::WithdrawalsRoot),
    },
    FieldEntry {
        indexer_name: "withdrawals",
        section: Section::Block,
        field: TypedField::Block(BlockField::Withdrawals),
    },
    FieldEntry {
        indexer_name: "l1BlockNumber",
        section: Section::Block,
        field: TypedField::Block(BlockField::L1BlockNumber),
    },
    FieldEntry {
        indexer_name: "sendCount",
        section: Section::Block,
        field: TypedField::Block(BlockField::SendCount),
    },
    FieldEntry {
        indexer_name: "sendRoot",
        section: Section::Block,
        field: TypedField::Block(BlockField::SendRoot),
    },
    FieldEntry {
        indexer_name: "mixHash",
        section: Section::Block,
        field: TypedField::Block(BlockField::MixHash),
    },
    // transaction.*
    FieldEntry {
        indexer_name: "blockHash",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::BlockHash),
    },
    FieldEntry {
        indexer_name: "blockNumber",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::BlockNumber),
    },
    FieldEntry {
        indexer_name: "from",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::From),
    },
    FieldEntry {
        indexer_name: "gas",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::Gas),
    },
    FieldEntry {
        indexer_name: "gasPrice",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::GasPrice),
    },
    FieldEntry {
        indexer_name: "hash",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::Hash),
    },
    FieldEntry {
        indexer_name: "input",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::Input),
    },
    FieldEntry {
        indexer_name: "nonce",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::Nonce),
    },
    FieldEntry {
        indexer_name: "to",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::To),
    },
    FieldEntry {
        indexer_name: "transactionIndex",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::TransactionIndex),
    },
    FieldEntry {
        indexer_name: "value",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::Value),
    },
    FieldEntry {
        indexer_name: "v",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::V),
    },
    FieldEntry {
        indexer_name: "r",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::R),
    },
    FieldEntry {
        indexer_name: "s",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::S),
    },
    FieldEntry {
        indexer_name: "maxPriorityFeePerGas",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::MaxPriorityFeePerGas),
    },
    FieldEntry {
        indexer_name: "maxFeePerGas",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::MaxFeePerGas),
    },
    FieldEntry {
        indexer_name: "chainId",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::ChainId),
    },
    FieldEntry {
        indexer_name: "cumulativeGasUsed",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::CumulativeGasUsed),
    },
    FieldEntry {
        indexer_name: "effectiveGasPrice",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::EffectiveGasPrice),
    },
    FieldEntry {
        indexer_name: "gasUsed",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::GasUsed),
    },
    FieldEntry {
        indexer_name: "contractAddress",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::ContractAddress),
    },
    FieldEntry {
        indexer_name: "logsBloom",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::LogsBloom),
    },
    FieldEntry {
        indexer_name: "type",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::Type),
    },
    FieldEntry {
        indexer_name: "root",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::Root),
    },
    FieldEntry {
        indexer_name: "status",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::Status),
    },
    FieldEntry {
        indexer_name: "sighash",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::Sighash),
    },
    FieldEntry {
        indexer_name: "l1Fee",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::L1Fee),
    },
    FieldEntry {
        indexer_name: "l1GasPrice",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::L1GasPrice),
    },
    FieldEntry {
        indexer_name: "l1GasUsed",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::L1GasUsed),
    },
    FieldEntry {
        indexer_name: "l1FeeScalar",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::L1FeeScalar),
    },
    FieldEntry {
        indexer_name: "gasUsedForL1",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::GasUsedForL1),
    },
    FieldEntry {
        indexer_name: "maxFeePerBlobGas",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::MaxFeePerBlobGas),
    },
    FieldEntry {
        indexer_name: "blobGasPrice",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::BlobGasPrice),
    },
    FieldEntry {
        indexer_name: "blobGasUsed",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::BlobGasUsed),
    },
    FieldEntry {
        indexer_name: "yParity",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::YParity),
    },
    FieldEntry {
        indexer_name: "sourceHash",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::SourceHash),
    },
    FieldEntry {
        indexer_name: "mint",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::Mint),
    },
    FieldEntry {
        indexer_name: "depositNonce",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::DepositNonce),
    },
    FieldEntry {
        indexer_name: "depositReceiptVersion",
        section: Section::Transaction,
        field: TypedField::Transaction(TransactionField::DepositReceiptVersion),
    },
    // log.*
    FieldEntry {
        indexer_name: "removed",
        section: Section::Log,
        field: TypedField::Log(LogField::Removed),
    },
    FieldEntry {
        indexer_name: "logIndex",
        section: Section::Log,
        field: TypedField::Log(LogField::LogIndex),
    },
    FieldEntry {
        indexer_name: "transactionIndex",
        section: Section::Log,
        field: TypedField::Log(LogField::TransactionIndex),
    },
    FieldEntry {
        indexer_name: "transactionHash",
        section: Section::Log,
        field: TypedField::Log(LogField::TransactionHash),
    },
    FieldEntry {
        indexer_name: "blockHash",
        section: Section::Log,
        field: TypedField::Log(LogField::BlockHash),
    },
    FieldEntry {
        indexer_name: "blockNumber",
        section: Section::Log,
        field: TypedField::Log(LogField::BlockNumber),
    },
    FieldEntry {
        indexer_name: "srcAddress",
        section: Section::Log,
        field: TypedField::Log(LogField::Address),
    },
    FieldEntry {
        indexer_name: "data",
        section: Section::Log,
        field: TypedField::Log(LogField::Data),
    },
    FieldEntry {
        indexer_name: "topic0",
        section: Section::Log,
        field: TypedField::Log(LogField::Topic0),
    },
    FieldEntry {
        indexer_name: "topic1",
        section: Section::Log,
        field: TypedField::Log(LogField::Topic1),
    },
    FieldEntry {
        indexer_name: "topic2",
        section: Section::Log,
        field: TypedField::Log(LogField::Topic2),
    },
    FieldEntry {
        indexer_name: "topic3",
        section: Section::Log,
        field: TypedField::Log(LogField::Topic3),
    },
];

pub fn lookup(section: Section, indexer_name: &str) -> Option<FieldEntry> {
    EVM_FIELDS
        .iter()
        .find(|f| f.section == section && f.indexer_name == indexer_name)
        .copied()
}

pub fn valid_indexer_names(section: Section) -> Vec<&'static str> {
    EVM_FIELDS
        .iter()
        .filter(|f| f.section == section)
        .map(|f| f.indexer_name)
        .collect()
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
