//! Which `event.transaction` and `event.block` fields a project's mappings
//! actually read.
//!
//! graph-ts populates both objects in full, so without this every event selects
//! every field. On HyperSync that is close to free; over RPC it forces a whole
//! block with its transactions to be fetched per block, which is the difference
//! between indexing and waiting.
//!
//! The scan is textual and deliberately timid: anything that isn't a plain
//! `.transaction.field` / `.block.field` read — an alias, a computed key, the
//! object passed somewhere — gives up and selects everything, because selecting
//! too little is a wrong answer and selecting too much is only slow.

use std::path::Path;

use crate::config_parsing::human_config::evm::{BlockField, TransactionField};

/// Every mapping source under the project. Reading the whole tree rather than
/// following imports is what makes the scan sound: a helper in another file is
/// scanned whether or not the entry point admits to importing it.
pub fn gather(root: &Path) -> Vec<String> {
    fn walk(dir: &Path, out: &mut Vec<String>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if path.is_dir() {
                if !matches!(name.as_ref(), "node_modules" | ".envio" | "build" | ".git") {
                    walk(&path, out);
                }
            } else if matches!(
                path.extension().and_then(|e| e.to_str()),
                Some("ts") | Some("js") | Some("mts") | Some("mjs")
            ) {
                if let Ok(source) = std::fs::read_to_string(&path) {
                    out.push(source);
                }
            }
        }
    }

    let mut sources = Vec::new();
    walk(root, &mut sources);
    sources
}

/// `None` means the mappings do something this scan can't account for, so the
/// full selection stands.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct FieldUsage {
    pub transaction: Option<Vec<TransactionField>>,
    pub block: Option<Vec<BlockField>>,
}

/// graph-ts `ethereum.Transaction` -> what envio selects for it.
fn transaction_field(name: &str) -> Option<TransactionField> {
    Some(match name {
        "hash" => TransactionField::Hash,
        "index" => TransactionField::TransactionIndex,
        "from" => TransactionField::From,
        "to" => TransactionField::To,
        "value" => TransactionField::Value,
        "gasLimit" => TransactionField::Gas,
        "gasPrice" => TransactionField::GasPrice,
        "input" => TransactionField::Input,
        "nonce" => TransactionField::Nonce,
        _ => return None,
    })
}

/// graph-ts `ethereum.Block` -> what envio selects for it. `number`, `hash` and
/// `timestamp` are always present, so they select nothing extra.
fn block_field(name: &str) -> Option<Option<BlockField>> {
    Some(match name {
        "number" | "hash" | "timestamp" => None,
        "parentHash" => Some(BlockField::ParentHash),
        "unclesHash" => Some(BlockField::Sha3Uncles),
        "author" => Some(BlockField::Miner),
        "stateRoot" => Some(BlockField::StateRoot),
        "transactionsRoot" => Some(BlockField::TransactionsRoot),
        "receiptsRoot" => Some(BlockField::ReceiptsRoot),
        "gasUsed" => Some(BlockField::GasUsed),
        "gasLimit" => Some(BlockField::GasLimit),
        "difficulty" => Some(BlockField::Difficulty),
        "totalDifficulty" => Some(BlockField::TotalDifficulty),
        "size" => Some(BlockField::Size),
        "baseFeePerGas" => Some(BlockField::BaseFeePerGas),
        _ => return None,
    })
}

fn is_ident_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_' || c == '$'
}

/// The identifier read off `source` immediately after `.<property>`, or `None`
/// when what follows isn't a plain property read.
fn read_after(source: &str, property_end: usize) -> Option<&str> {
    let rest = &source[property_end..];
    let mut chars = rest.char_indices();
    let (_, first) = chars.next()?;
    if first != '.' {
        return None;
    }
    let start = property_end + 1;
    let end = source[start..]
        .find(|c: char| !is_ident_char(c))
        .map(|offset| start + offset)
        .unwrap_or(source.len());
    if end == start {
        None
    } else {
        Some(&source[start..end])
    }
}

/// Every `.<property>` occurrence that isn't part of a longer identifier.
fn occurrences<'a>(source: &'a str, property: &str) -> Vec<usize> {
    let needle = format!(".{property}");
    let mut found = Vec::new();
    let mut from = 0;
    while let Some(offset) = source[from..].find(&needle) {
        let start = from + offset;
        let end = start + needle.len();
        let follows_identifier = source[end..].chars().next().is_some_and(is_ident_char);
        let preceded_by_dot = source[..start].ends_with('.');
        if !follows_identifier && !preceded_by_dot {
            found.push(end);
        }
        from = end;
    }
    found
}

pub fn scan(sources: &[String]) -> FieldUsage {
    let mut transaction = Some(Vec::new());
    let mut block = Some(Vec::new());

    for source in sources {
        for end in occurrences(source, "transaction") {
            match read_after(source, end).and_then(transaction_field) {
                Some(field) => {
                    if let Some(fields) = transaction.as_mut() {
                        if !fields.contains(&field) {
                            fields.push(field);
                        }
                    }
                }
                None => transaction = None,
            }
        }

        for end in occurrences(source, "block") {
            match read_after(source, end).and_then(block_field) {
                Some(Some(field)) => {
                    if let Some(fields) = block.as_mut() {
                        if !fields.contains(&field) {
                            fields.push(field);
                        }
                    }
                }
                Some(None) => {}
                None => block = None,
            }
        }
    }

    FieldUsage { transaction, block }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scan_one(source: &str) -> FieldUsage {
        scan(&[source.to_string()])
    }

    #[test]
    fn selects_only_the_fields_a_mapping_reads() {
        let usage = scan_one(
            r#"
            export function handleTransfer(event: Transfer): void {
              const entity = new TransferEvent(event.transaction.hash.toHexString());
              entity.timestamp = event.block.timestamp.toI32();
              entity.gas = event.transaction.gasLimit;
              entity.miner = event.block.author;
            }
            "#,
        );
        assert_eq!(
            usage,
            FieldUsage {
                transaction: Some(vec![TransactionField::Hash, TransactionField::Gas]),
                block: Some(vec![BlockField::Miner]),
            }
        );
    }

    #[test]
    fn selects_nothing_when_the_mapping_touches_neither() {
        let usage = scan_one(
            r#"
            export function handleTransfer(event: Transfer): void {
              const entity = new TransferEvent(event.logIndex.toString());
              entity.from = event.params.from;
            }
            "#,
        );
        assert_eq!(
            usage,
            FieldUsage {
                transaction: Some(vec![]),
                block: Some(vec![]),
            }
        );
    }

    #[test]
    fn gives_up_on_an_alias() {
        let usage = scan_one("const tx = event.transaction;\nentity.hash = tx.hash;");
        assert_eq!(usage.transaction, None);
        assert_eq!(usage.block, Some(vec![]));
    }

    #[test]
    fn gives_up_on_a_computed_key() {
        assert_eq!(scan_one(r#"event.block["number"]"#).block, None);
    }

    #[test]
    fn gives_up_on_a_field_it_does_not_know() {
        assert_eq!(scan_one("event.block.withdrawalsRoot").block, None);
        assert_eq!(scan_one("event.transaction.maxFeePerGas").transaction, None);
    }

    #[test]
    fn ignores_longer_identifiers_and_nested_reads() {
        // `transactionLogIndex` and `blockNumber` are their own properties, and
        // `receipt.transaction` is not the event's.
        let usage = scan_one("event.transactionLogIndex; log.blockNumber; a.b.transaction.hash;");
        assert_eq!(
            usage,
            FieldUsage {
                transaction: Some(vec![TransactionField::Hash]),
                block: Some(vec![]),
            }
        );
    }

    #[test]
    fn one_ambiguous_file_gives_up_for_all_of_them() {
        let usage = scan(&[
            "event.transaction.hash".to_string(),
            "helper(event.transaction)".to_string(),
        ]);
        assert_eq!(usage.transaction, None);
    }
}
