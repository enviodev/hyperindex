use super::chain::ChainKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Section {
    Block,
    Transaction,
    Log,
    Receipt,
    Input,
    Output,
}

impl Section {
    pub fn as_indexer_str(self) -> &'static str {
        match self {
            Section::Block => "block",
            Section::Transaction => "transaction",
            Section::Log => "log",
            Section::Receipt => "receipt",
            Section::Input => "input",
            Section::Output => "output",
        }
    }

    pub fn as_hs_key(self) -> &'static str {
        match self {
            Section::Block => "block",
            Section::Transaction => "transaction",
            Section::Log => "log",
            Section::Receipt => "receipt",
            Section::Input => "input",
            Section::Output => "output",
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct FieldEntry {
    pub indexer_name: &'static str,
    pub hs_name: &'static str,
    pub section: Section,
}

const EVM_FIELDS: &[FieldEntry] = &[
    // block.* — from HyperSyncJsonApi.QueryTypes.blockFieldOptions
    FieldEntry {
        indexer_name: "number",
        hs_name: "number",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "hash",
        hs_name: "hash",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "parentHash",
        hs_name: "parent_hash",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "nonce",
        hs_name: "nonce",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "sha3Uncles",
        hs_name: "sha3_uncles",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "logsBloom",
        hs_name: "logs_bloom",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "transactionsRoot",
        hs_name: "transactions_root",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "stateRoot",
        hs_name: "state_root",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "receiptsRoot",
        hs_name: "receipts_root",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "miner",
        hs_name: "miner",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "difficulty",
        hs_name: "difficulty",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "totalDifficulty",
        hs_name: "total_difficulty",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "extraData",
        hs_name: "extra_data",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "size",
        hs_name: "size",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "gasLimit",
        hs_name: "gas_limit",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "gasUsed",
        hs_name: "gas_used",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "timestamp",
        hs_name: "timestamp",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "uncles",
        hs_name: "uncles",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "baseFeePerGas",
        hs_name: "base_fee_per_gas",
        section: Section::Block,
    },
    // transaction.* — from HyperSyncJsonApi.QueryTypes.transactionFieldOptions
    FieldEntry {
        indexer_name: "blockHash",
        hs_name: "block_hash",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "blockNumber",
        hs_name: "block_number",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "from",
        hs_name: "from",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "gas",
        hs_name: "gas",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "gasPrice",
        hs_name: "gas_price",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "hash",
        hs_name: "hash",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "input",
        hs_name: "input",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "nonce",
        hs_name: "nonce",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "to",
        hs_name: "to",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "transactionIndex",
        hs_name: "transaction_index",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "value",
        hs_name: "value",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "v",
        hs_name: "v",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "r",
        hs_name: "r",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "s",
        hs_name: "s",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "maxPriorityFeePerGas",
        hs_name: "max_priority_fee_per_gas",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "maxFeePerGas",
        hs_name: "max_fee_per_gas",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "chainId",
        hs_name: "chain_id",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "cumulativeGasUsed",
        hs_name: "cumulative_gas_used",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "effectiveGasPrice",
        hs_name: "effective_gas_price",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "gasUsed",
        hs_name: "gas_used",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "contractAddress",
        hs_name: "contract_address",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "logsBloom",
        hs_name: "logs_bloom",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "type",
        hs_name: "type",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "root",
        hs_name: "root",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "status",
        hs_name: "status",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "sighash",
        hs_name: "sighash",
        section: Section::Transaction,
    },
    // log.* — from HyperSyncJsonApi.QueryTypes.logFieldOptions
    FieldEntry {
        indexer_name: "removed",
        hs_name: "removed",
        section: Section::Log,
    },
    FieldEntry {
        indexer_name: "logIndex",
        hs_name: "log_index",
        section: Section::Log,
    },
    FieldEntry {
        indexer_name: "transactionIndex",
        hs_name: "transaction_index",
        section: Section::Log,
    },
    FieldEntry {
        indexer_name: "transactionHash",
        hs_name: "transaction_hash",
        section: Section::Log,
    },
    FieldEntry {
        indexer_name: "blockHash",
        hs_name: "block_hash",
        section: Section::Log,
    },
    FieldEntry {
        indexer_name: "blockNumber",
        hs_name: "block_number",
        section: Section::Log,
    },
    // `srcAddress` is the indexer-side name used in event handlers; HS uses `address`.
    FieldEntry {
        indexer_name: "srcAddress",
        hs_name: "address",
        section: Section::Log,
    },
    FieldEntry {
        indexer_name: "data",
        hs_name: "data",
        section: Section::Log,
    },
    FieldEntry {
        indexer_name: "topic0",
        hs_name: "topic0",
        section: Section::Log,
    },
    FieldEntry {
        indexer_name: "topic1",
        hs_name: "topic1",
        section: Section::Log,
    },
    FieldEntry {
        indexer_name: "topic2",
        hs_name: "topic2",
        section: Section::Log,
    },
    FieldEntry {
        indexer_name: "topic3",
        hs_name: "topic3",
        section: Section::Log,
    },
];

const FUEL_FIELDS: &[FieldEntry] = &[
    // block.* — from HyperFuelClient.QueryTypes.blockFieldOptions
    FieldEntry {
        indexer_name: "id",
        hs_name: "id",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "daHeight",
        hs_name: "da_height",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "transactionsCount",
        hs_name: "transactions_count",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "messageReceiptCount",
        hs_name: "message_receipt_count",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "transactionsRoot",
        hs_name: "transactions_root",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "messageReceiptRoot",
        hs_name: "message_receipt_root",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "height",
        hs_name: "height",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "prevRoot",
        hs_name: "prev_root",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "time",
        hs_name: "time",
        section: Section::Block,
    },
    FieldEntry {
        indexer_name: "applicationHash",
        hs_name: "application_hash",
        section: Section::Block,
    },
    // transaction.* — from HyperFuelClient.QueryTypes.transactionFieldOptions
    FieldEntry {
        indexer_name: "id",
        hs_name: "id",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "blockHeight",
        hs_name: "block_height",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "inputAssetIds",
        hs_name: "input_asset_ids",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "inputContracts",
        hs_name: "input_contracts",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "inputContractUtxoId",
        hs_name: "input_contract_utxo_id",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "inputContractBalanceRoot",
        hs_name: "input_contract_balance_root",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "inputContractStateRoot",
        hs_name: "input_contract_state_root",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "inputContractTxPointerBlockHeight",
        hs_name: "input_contract_tx_pointer_block_height",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "inputContractTxPointerTxIndex",
        hs_name: "input_contract_tx_pointer_tx_index",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "inputContract",
        hs_name: "input_contract",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "gasPrice",
        hs_name: "gas_price",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "gasLimit",
        hs_name: "gas_limit",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "maturity",
        hs_name: "maturity",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "mintAmount",
        hs_name: "mint_amount",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "mintAssetId",
        hs_name: "mint_asset_id",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "txPointerBlockHeight",
        hs_name: "tx_pointer_block_height",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "txPointerTxIndex",
        hs_name: "tx_pointer_tx_index",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "txType",
        hs_name: "tx_type",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "outputContractInputIndex",
        hs_name: "output_contract_input_index",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "outputContractBalanceRoot",
        hs_name: "output_contract_balance_root",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "outputContractStateRoot",
        hs_name: "output_contract_state_root",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "witnesses",
        hs_name: "witnesses",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "receiptsRoot",
        hs_name: "receipts_root",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "status",
        hs_name: "status",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "time",
        hs_name: "time",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "reason",
        hs_name: "reason",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "script",
        hs_name: "script",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "scriptData",
        hs_name: "script_data",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "bytecodeWitnessIndex",
        hs_name: "bytecode_witness_index",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "bytecodeLength",
        hs_name: "bytecode_length",
        section: Section::Transaction,
    },
    FieldEntry {
        indexer_name: "salt",
        hs_name: "salt",
        section: Section::Transaction,
    },
    // receipt.* — from HyperFuelClient.QueryTypes.receiptFieldOptions
    FieldEntry {
        indexer_name: "txId",
        hs_name: "tx_id",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "txStatus",
        hs_name: "tx_status",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "blockHeight",
        hs_name: "block_height",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "pc",
        hs_name: "pc",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "is",
        hs_name: "is",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "to",
        hs_name: "to",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "toAddress",
        hs_name: "to_address",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "amount",
        hs_name: "amount",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "assetId",
        hs_name: "asset_id",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "gas",
        hs_name: "gas",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "param1",
        hs_name: "param1",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "param2",
        hs_name: "param2",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "val",
        hs_name: "val",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "ptr",
        hs_name: "ptr",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "digest",
        hs_name: "digest",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "reason",
        hs_name: "reason",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "ra",
        hs_name: "ra",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "rb",
        hs_name: "rb",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "rc",
        hs_name: "rc",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "rd",
        hs_name: "rd",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "len",
        hs_name: "len",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "receiptType",
        hs_name: "receipt_type",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "receiptIndex",
        hs_name: "receipt_index",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "result",
        hs_name: "result",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "gasUsed",
        hs_name: "gas_used",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "data",
        hs_name: "data",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "sender",
        hs_name: "sender",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "recipient",
        hs_name: "recipient",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "nonce",
        hs_name: "nonce",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "contractId",
        hs_name: "contract_id",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "rootContractId",
        hs_name: "root_contract_id",
        section: Section::Receipt,
    },
    FieldEntry {
        indexer_name: "subId",
        hs_name: "sub_id",
        section: Section::Receipt,
    },
];

pub fn fields_for(kind: ChainKind) -> &'static [FieldEntry] {
    match kind {
        ChainKind::Evm => EVM_FIELDS,
        ChainKind::Fuel => FUEL_FIELDS,
    }
}

pub fn lookup(kind: ChainKind, section: Section, indexer_name: &str) -> Option<FieldEntry> {
    fields_for(kind)
        .iter()
        .find(|f| f.section == section && f.indexer_name == indexer_name)
        .copied()
}

pub fn valid_indexer_names(kind: ChainKind, section: Section) -> Vec<&'static str> {
    fields_for(kind)
        .iter()
        .filter(|f| f.section == section)
        .map(|f| f.indexer_name)
        .collect()
}

pub fn parse_section(kind: ChainKind, raw: &str) -> Option<Section> {
    let s = match raw {
        "block" => Section::Block,
        "transaction" => Section::Transaction,
        "log" => Section::Log,
        "receipt" => Section::Receipt,
        "input" => Section::Input,
        "output" => Section::Output,
        _ => return None,
    };
    let allowed: &[Section] = match kind {
        ChainKind::Evm => &[Section::Block, Section::Transaction, Section::Log],
        ChainKind::Fuel => &[
            Section::Block,
            Section::Transaction,
            Section::Receipt,
            Section::Input,
            Section::Output,
        ],
    };
    if allowed.contains(&s) {
        Some(s)
    } else {
        None
    }
}

pub fn allowed_sections(kind: ChainKind) -> &'static [&'static str] {
    match kind {
        ChainKind::Evm => &["block", "transaction", "log"],
        ChainKind::Fuel => &["block", "transaction", "receipt", "input", "output"],
    }
}
