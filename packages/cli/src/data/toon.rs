use std::fmt::Write;

use hypersync_client::format::Hex;
use hypersync_client::net_types::{
    block::BlockField, log::LogField, transaction::TransactionField,
};
use hypersync_client::simple_types;
use hypersync_client::QueryResponse;

use super::field_selection::{Column, Selection};
use super::mapping::{Section, TypedField};

/// One tabular block in TOON form:
///
///     name[N]{col1,col2}:
///       v1,v2
///       v1,v2
pub fn render_table(name: &str, columns: &[&str], rows: &[Vec<String>]) -> String {
    let mut out = String::new();
    let _ = write!(out, "{name}[{n}]{{", n = rows.len());
    for (i, c) in columns.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(c);
    }
    out.push_str("}:\n");
    for row in rows {
        out.push_str("  ");
        for (i, cell) in row.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&escape_cell(cell));
        }
        out.push('\n');
    }
    out
}

fn escape_cell(s: &str) -> String {
    let needs_quoting = s.contains(',')
        || s.contains('\n')
        || s.contains('"')
        || s.starts_with(' ')
        || s.ends_with(' ');
    if !needs_quoting {
        return s.to_string();
    }
    let escaped = s.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

/// Render a native `QueryResponse` into TOON, one block per section.
pub fn render_query_response(selection: &Selection, response: &QueryResponse) -> String {
    let mut section_order: Vec<Section> = Vec::new();
    for col in &selection.columns {
        if !section_order.contains(&col.section) {
            section_order.push(col.section);
        }
    }

    let mut out = String::new();
    for section in section_order {
        let cols: Vec<&Column> = selection
            .columns
            .iter()
            .filter(|c| c.section == section)
            .collect();
        let col_names: Vec<&str> = cols.iter().map(|c| c.indexer_name.as_str()).collect();
        let plural = match section {
            Section::Block => "blocks",
            Section::Transaction => "transactions",
            Section::Log => "logs",
        };

        let mut rows: Vec<Vec<String>> = Vec::new();
        match section {
            Section::Block => {
                for batch in &response.data.blocks {
                    for block in batch {
                        let row: Vec<String> = cols
                            .iter()
                            .map(|c| match c.field {
                                TypedField::Block(f) => block_field_to_string(block, f),
                                _ => String::new(),
                            })
                            .collect();
                        rows.push(row);
                    }
                }
            }
            Section::Transaction => {
                for batch in &response.data.transactions {
                    for tx in batch {
                        let row: Vec<String> = cols
                            .iter()
                            .map(|c| match c.field {
                                TypedField::Transaction(f) => tx_field_to_string(tx, f),
                                _ => String::new(),
                            })
                            .collect();
                        rows.push(row);
                    }
                }
            }
            Section::Log => {
                for batch in &response.data.logs {
                    for log in batch {
                        let row: Vec<String> = cols
                            .iter()
                            .map(|c| match c.field {
                                TypedField::Log(f) => log_field_to_string(log, f),
                                _ => String::new(),
                            })
                            .collect();
                        rows.push(row);
                    }
                }
            }
        }

        out.push_str(&render_table(plural, &col_names, &rows));
    }
    out
}

fn opt_hex<T: Hex>(v: &Option<T>) -> String {
    match v {
        Some(val) => val.encode_hex(),
        None => String::new(),
    }
}

fn opt_u64(v: Option<u64>) -> String {
    match v {
        Some(n) => n.to_string(),
        None => String::new(),
    }
}

fn block_field_to_string(block: &simple_types::Block, field: BlockField) -> String {
    match field {
        BlockField::Number => opt_u64(block.number),
        BlockField::Hash => opt_hex(&block.hash),
        BlockField::ParentHash => opt_hex(&block.parent_hash),
        BlockField::Nonce => opt_hex(&block.nonce),
        BlockField::Sha3Uncles => opt_hex(&block.sha3_uncles),
        BlockField::LogsBloom => opt_hex(&block.logs_bloom),
        BlockField::TransactionsRoot => opt_hex(&block.transactions_root),
        BlockField::StateRoot => opt_hex(&block.state_root),
        BlockField::ReceiptsRoot => opt_hex(&block.receipts_root),
        BlockField::Miner => opt_hex(&block.miner),
        BlockField::Difficulty => opt_hex(&block.difficulty),
        BlockField::TotalDifficulty => opt_hex(&block.total_difficulty),
        BlockField::ExtraData => opt_hex(&block.extra_data),
        BlockField::Size => opt_hex(&block.size),
        BlockField::GasLimit => opt_hex(&block.gas_limit),
        BlockField::GasUsed => opt_hex(&block.gas_used),
        BlockField::Timestamp => opt_hex(&block.timestamp),
        BlockField::Uncles => match &block.uncles {
            Some(v) => {
                let strs: Vec<String> = v.iter().map(|h| h.encode_hex()).collect();
                format!("[{}]", strs.join(","))
            }
            None => String::new(),
        },
        BlockField::BaseFeePerGas => opt_hex(&block.base_fee_per_gas),
        BlockField::BlobGasUsed => opt_hex(&block.blob_gas_used),
        BlockField::ExcessBlobGas => opt_hex(&block.excess_blob_gas),
        BlockField::ParentBeaconBlockRoot => opt_hex(&block.parent_beacon_block_root),
        BlockField::WithdrawalsRoot => opt_hex(&block.withdrawals_root),
        BlockField::Withdrawals => match &block.withdrawals {
            Some(_) => "<withdrawals>".to_string(),
            None => String::new(),
        },
        BlockField::L1BlockNumber => block.l1_block_number.map_or(String::new(), |n| {
            let v: u64 = n.into();
            v.to_string()
        }),
        BlockField::SendCount => opt_hex(&block.send_count),
        BlockField::SendRoot => opt_hex(&block.send_root),
        BlockField::MixHash => opt_hex(&block.mix_hash),
    }
}

fn tx_field_to_string(tx: &simple_types::Transaction, field: TransactionField) -> String {
    match field {
        TransactionField::BlockHash => opt_hex(&tx.block_hash),
        TransactionField::BlockNumber => tx.block_number.map_or(String::new(), |n| {
            let v: u64 = n.into();
            v.to_string()
        }),
        TransactionField::From => opt_hex(&tx.from),
        TransactionField::Gas => opt_hex(&tx.gas),
        TransactionField::GasPrice => opt_hex(&tx.gas_price),
        TransactionField::Hash => opt_hex(&tx.hash),
        TransactionField::Input => opt_hex(&tx.input),
        TransactionField::Nonce => opt_hex(&tx.nonce),
        TransactionField::To => opt_hex(&tx.to),
        TransactionField::TransactionIndex => tx.transaction_index.map_or(String::new(), |n| {
            let v: u64 = n.into();
            v.to_string()
        }),
        TransactionField::Value => opt_hex(&tx.value),
        TransactionField::V => opt_hex(&tx.v),
        TransactionField::R => opt_hex(&tx.r),
        TransactionField::S => opt_hex(&tx.s),
        TransactionField::YParity => opt_hex(&tx.y_parity),
        TransactionField::MaxPriorityFeePerGas => opt_hex(&tx.max_priority_fee_per_gas),
        TransactionField::MaxFeePerGas => opt_hex(&tx.max_fee_per_gas),
        TransactionField::ChainId => opt_hex(&tx.chain_id),
        TransactionField::AccessList => match &tx.access_list {
            Some(_) => "<access_list>".to_string(),
            None => String::new(),
        },
        TransactionField::AuthorizationList => match &tx.authorization_list {
            Some(_) => "<authorization_list>".to_string(),
            None => String::new(),
        },
        TransactionField::MaxFeePerBlobGas => opt_hex(&tx.max_fee_per_blob_gas),
        TransactionField::BlobVersionedHashes => match &tx.blob_versioned_hashes {
            Some(v) => {
                let strs: Vec<String> = v.iter().map(|h| h.encode_hex()).collect();
                format!("[{}]", strs.join(","))
            }
            None => String::new(),
        },
        TransactionField::CumulativeGasUsed => opt_hex(&tx.cumulative_gas_used),
        TransactionField::EffectiveGasPrice => opt_hex(&tx.effective_gas_price),
        TransactionField::GasUsed => opt_hex(&tx.gas_used),
        TransactionField::ContractAddress => opt_hex(&tx.contract_address),
        TransactionField::LogsBloom => opt_hex(&tx.logs_bloom),
        TransactionField::Type => tx.type_.map_or(String::new(), |t| {
            let v: u8 = t.into();
            v.to_string()
        }),
        TransactionField::Root => opt_hex(&tx.root),
        TransactionField::Status => tx.status.map_or(String::new(), |s| s.to_u8().to_string()),
        TransactionField::L1Fee => opt_hex(&tx.l1_fee),
        TransactionField::L1GasPrice => opt_hex(&tx.l1_gas_price),
        TransactionField::L1GasUsed => opt_hex(&tx.l1_gas_used),
        TransactionField::L1FeeScalar => tx.l1_fee_scalar.map_or(String::new(), |v| v.to_string()),
        TransactionField::GasUsedForL1 => opt_hex(&tx.gas_used_for_l1),
        TransactionField::BlobGasPrice => opt_hex(&tx.blob_gas_price),
        TransactionField::BlobGasUsed => opt_hex(&tx.blob_gas_used),
        TransactionField::DepositNonce => opt_hex(&tx.deposit_nonce),
        TransactionField::DepositReceiptVersion => opt_hex(&tx.deposit_receipt_version),
        TransactionField::L1BaseFeeScalar => opt_hex(&tx.l1_base_fee_scalar),
        TransactionField::L1BlobBaseFee => opt_hex(&tx.l1_blob_base_fee),
        TransactionField::L1BlobBaseFeeScalar => opt_hex(&tx.l1_blob_base_fee_scalar),
        TransactionField::L1BlockNumber => opt_hex(&tx.l1_block_number),
        TransactionField::Mint => opt_hex(&tx.mint),
        TransactionField::Sighash => opt_hex(&tx.sighash),
        TransactionField::SourceHash => opt_hex(&tx.source_hash),
    }
}

fn log_field_to_string(log: &simple_types::Log, field: LogField) -> String {
    match field {
        LogField::Removed => log.removed.map_or(String::new(), |b| b.to_string()),
        LogField::LogIndex => log.log_index.map_or(String::new(), |n| {
            let v: u64 = n.into();
            v.to_string()
        }),
        LogField::TransactionIndex => log.transaction_index.map_or(String::new(), |n| {
            let v: u64 = n.into();
            v.to_string()
        }),
        LogField::TransactionHash => opt_hex(&log.transaction_hash),
        LogField::BlockHash => opt_hex(&log.block_hash),
        LogField::BlockNumber => log.block_number.map_or(String::new(), |n| {
            let v: u64 = n.into();
            v.to_string()
        }),
        LogField::Address => opt_hex(&log.address),
        LogField::Data => opt_hex(&log.data),
        LogField::Topic0 => log
            .topics
            .first()
            .and_then(|t| t.as_ref())
            .map_or(String::new(), |t| t.encode_hex()),
        LogField::Topic1 => log
            .topics
            .get(1)
            .and_then(|t| t.as_ref())
            .map_or(String::new(), |t| t.encode_hex()),
        LogField::Topic2 => log
            .topics
            .get(2)
            .and_then(|t| t.as_ref())
            .map_or(String::new(), |t| t.encode_hex()),
        LogField::Topic3 => log
            .topics
            .get(3)
            .and_then(|t| t.as_ref())
            .map_or(String::new(), |t| t.encode_hex()),
    }
}

pub fn render_height(value: i64) -> String {
    render_table("height", &["value"], &[vec![value.to_string()]])
}

pub fn render_archive_height(value: i64) -> String {
    render_table("archiveHeight", &["value"], &[vec![value.to_string()]])
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn quotes_cells_with_commas() {
        let s = render_table("t", &["a"], &[vec!["x,y".into()]]);
        assert_eq!(s, "t[1]{a}:\n  \"x,y\"\n");
    }
}
