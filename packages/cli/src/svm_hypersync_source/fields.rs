//! Handler `fields` → HyperSync query columns.
//!
//! One table per SVM payload surface. A handler name is the public API;
//! `columns` are the extra HyperSync fields it needs. Join keys are injected
//! when the table is opted in (any selected name), not listed per field —
//! except the transaction table, which stays empty when the only selected
//! names are store keys (`transactionIndex`) or the companion-table bit
//! (`accountActivities`).
//!
//! Table opt-in is `!columns.is_empty()`. There is no parallel `needs_*` flag.

use anyhow::{Context, Result};

pub struct HandlerField {
    pub js_name: &'static str,
    pub columns: &'static [&'static str],
}

pub const TRANSACTION: &[HandlerField] = &[
    HandlerField {
        js_name: "transactionIndex",
        columns: &[],
    },
    HandlerField {
        js_name: "signature",
        columns: &["transaction_id"],
    },
    HandlerField {
        js_name: "feePayer",
        columns: &["fee_payer"],
    },
    HandlerField {
        js_name: "success",
        columns: &["success"],
    },
    HandlerField {
        js_name: "err",
        columns: &["err"],
    },
    HandlerField {
        js_name: "fee",
        columns: &["fee"],
    },
    HandlerField {
        js_name: "computeUnitsConsumed",
        columns: &["compute_units_consumed"],
    },
    HandlerField {
        js_name: "accountKeys",
        columns: &["account_keys"],
    },
    HandlerField {
        js_name: "recentBlockhash",
        columns: &["recent_blockhash"],
    },
    HandlerField {
        js_name: "version",
        columns: &["version"],
    },
    HandlerField {
        js_name: "allSignatures",
        columns: &["signatures"],
    },
    HandlerField {
        js_name: "accountActivities",
        columns: &[],
    },
];

pub const BLOCK: &[HandlerField] = &[
    HandlerField {
        js_name: "slot",
        columns: &[],
    },
    HandlerField {
        js_name: "time",
        columns: &[],
    },
    HandlerField {
        js_name: "hash",
        columns: &[],
    },
    HandlerField {
        js_name: "height",
        columns: &["block_height"],
    },
    HandlerField {
        js_name: "parentSlot",
        columns: &["parent_slot"],
    },
    HandlerField {
        js_name: "parentHash",
        columns: &["parent_blockhash"],
    },
];

pub const ACCOUNT_ACTIVITY: &[HandlerField] = &[
    HandlerField {
        js_name: "address",
        columns: &[],
    },
    HandlerField {
        js_name: "transactionAccountIndex",
        columns: &["account_index"],
    },
    HandlerField {
        js_name: "isSigner",
        columns: &["is_signer"],
    },
    HandlerField {
        js_name: "isWritable",
        columns: &["is_writable"],
    },
    HandlerField {
        js_name: "lamports.pre",
        columns: &["pre_balance"],
    },
    HandlerField {
        js_name: "lamports.post",
        columns: &["post_balance"],
    },
    HandlerField {
        js_name: "token.mint",
        columns: &["mint"],
    },
    HandlerField {
        js_name: "token.owner",
        columns: &["mint", "pre_owner", "post_owner"],
    },
    HandlerField {
        js_name: "token.decimals",
        columns: &["mint", "token_decimals"],
    },
    HandlerField {
        js_name: "token.preAmount",
        columns: &["mint", "pre_token_balance"],
    },
    HandlerField {
        js_name: "token.postAmount",
        columns: &["mint", "post_token_balance"],
    },
];

pub const LOG: &[HandlerField] = &[
    HandlerField {
        js_name: "kind",
        columns: &["kind"],
    },
    HandlerField {
        js_name: "message",
        columns: &["message"],
    },
];

/// Instruction handler fields do not add HyperSync columns of their own.
/// Routing uses [`INSTRUCTION_REQUIRED`]; `accounts` / `accountArguments`
/// add `account_arguments` when selected. `programId` / `data` / `path` /
/// `isInner` are payload-only — already covered by the required query set.
pub const INSTRUCTION: &[HandlerField] = &[
    HandlerField {
        js_name: "args",
        columns: &[],
    },
    HandlerField {
        js_name: "accounts",
        columns: &[],
    },
    HandlerField {
        js_name: "accountArguments",
        columns: &[],
    },
    HandlerField {
        js_name: "programId",
        columns: &[],
    },
    HandlerField {
        js_name: "data",
        columns: &[],
    },
    HandlerField {
        js_name: "path",
        columns: &[],
    },
    HandlerField {
        js_name: "isInner",
        columns: &[],
    },
];

pub const BLOCK_KEYS: &[&str] = &["slot", "blockhash", "block_time"];
pub const TX_KEYS: &[&str] = &["slot", "transaction_index"];
pub const ACTIVITY_KEYS: &[&str] = &["slot", "transaction_index", "account"];
pub const LOG_KEYS: &[&str] = &["slot", "transaction_index", "instruction_address"];

/// Always fetched for routing and join keys. Handler `fields.instruction`
/// then decides which of `programId` / `data` / `path` / `isInner` land on
/// the payload. HyperSync column is `instruction_address`; handler field is `path`.
///
/// `d1`–`d8` and `a0`–`a9` are not listed — prefixes are derived from `data`,
/// and account filters ride the query selection, not the response columns.
pub const INSTRUCTION_REQUIRED: &[&str] = &[
    "slot",
    "transaction_index",
    "instruction_address",
    "executing_account",
    "data",
    "is_inner",
    "tx_success",
];

pub fn push_unique(columns: &mut Vec<&'static str>, column: &'static str) {
    if !columns.contains(&column) {
        columns.push(column);
    }
}

fn extra_columns(table: &[HandlerField], selected: &[String]) -> Result<Vec<&'static str>> {
    let mut columns = Vec::new();
    for name in selected {
        let field = table
            .iter()
            .find(|field| field.js_name == name.as_str())
            .with_context(|| format!("unknown field {name:?}"))?;
        for &column in field.columns {
            push_unique(&mut columns, column);
        }
    }
    Ok(columns)
}

fn with_keys(keys: &[&'static str], extras: &[&'static str]) -> Vec<&'static str> {
    let mut columns = keys.to_vec();
    for &column in extras {
        push_unique(&mut columns, column);
    }
    columns
}

/// Transaction table columns, or empty when nothing on the stored row is read.
pub fn transaction_query_columns(selected: &[String]) -> Result<Vec<&'static str>> {
    let extras = extra_columns(TRANSACTION, selected)?;
    if extras.is_empty() {
        Ok(Vec::new())
    } else {
        Ok(with_keys(TX_KEYS, &extras))
    }
}

/// Account-activity columns including join keys. Empty iff no activity field
/// was selected — including `address`, which is the companion-table key.
pub fn account_activity_query_columns(selected: &[String]) -> Result<Vec<&'static str>> {
    if selected.is_empty() {
        Ok(Vec::new())
    } else {
        Ok(with_keys(
            ACTIVITY_KEYS,
            &extra_columns(ACCOUNT_ACTIVITY, selected)?,
        ))
    }
}

pub fn log_query_columns(selected: &[String]) -> Result<Vec<&'static str>> {
    if selected.is_empty() {
        Ok(Vec::new())
    } else {
        Ok(with_keys(LOG_KEYS, &extra_columns(LOG, selected)?))
    }
}

/// Extra block columns on top of the always-fetched slot/hash/time trio.
pub fn block_extra_columns(selected: &[String]) -> Result<Vec<&'static str>> {
    extra_columns(BLOCK, selected)
}

pub fn instruction_query_columns(
    selected: &[String],
    has_account_filters: bool,
) -> Result<Vec<&'static str>> {
    let _ = extra_columns(INSTRUCTION, selected)?;
    let mut columns = INSTRUCTION_REQUIRED.to_vec();
    if has_account_filters
        || selected
            .iter()
            .any(|name| name == "accounts" || name == "accountArguments")
    {
        push_unique(&mut columns, "account_arguments");
    }
    Ok(columns)
}

pub fn selects(selected: &[String], name: &str) -> bool {
    selected.iter().any(|field| field == name)
}

#[cfg(test)]
mod tests {
    use std::str::FromStr;

    use hypersync_solana_net_types::field_selection::{
        AccountActivityField, BlockField, InstructionField, LogField, TransactionField,
    };
    use strum::VariantArray;

    use super::*;
    use crate::block_store::SvmBlockField;
    use crate::transaction_store::SvmTxField;

    fn names(table: &[HandlerField]) -> Vec<&'static str> {
        table.iter().map(|field| field.js_name).collect()
    }

    fn dts() -> String {
        std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../envio/index.d.ts"))
            .expect("read index.d.ts")
    }

    fn dts_string_union(src: &str, type_name: &str) -> Vec<String> {
        let marker = format!("export type {type_name} =");
        let start = src.find(&marker).unwrap_or_else(|| panic!("{type_name}"));
        let rest = &src[start + marker.len()..];
        let end = rest.find("export type").unwrap_or(rest.len());
        let mut names = Vec::new();
        let mut chars = rest[..end].chars().peekable();
        while let Some(c) = chars.next() {
            if c == '"' {
                let mut name = String::new();
                for c in chars.by_ref() {
                    if c == '"' {
                        break;
                    }
                    name.push(c);
                }
                names.push(name);
            }
        }
        names
    }

    fn parse_all<F: FromStr>(columns: &[&str], table: &str)
    where
        F::Err: std::fmt::Debug,
    {
        for column in columns {
            F::from_str(column).unwrap_or_else(|_| panic!("{table} column {column:?}"));
        }
    }

    #[test]
    fn transaction_names_match_store_ordinals() {
        assert_eq!(
            names(TRANSACTION),
            SvmTxField::VARIANTS
                .iter()
                .map(|field| field.name())
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn block_names_match_store_ordinals() {
        assert_eq!(
            names(BLOCK),
            SvmBlockField::VARIANTS
                .iter()
                .map(|field| field.name())
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn handler_names_match_public_unions() {
        let dts = dts();
        assert_eq!(
            names(ACCOUNT_ACTIVITY),
            dts_string_union(&dts, "SvmAccountActivityFieldName")
        );
        assert_eq!(names(LOG), dts_string_union(&dts, "SvmLogFieldName"));
        assert_eq!(
            names(INSTRUCTION),
            dts_string_union(&dts, "SvmInstructionFieldName")
        );
        assert_eq!(
            names(TRANSACTION)
                .into_iter()
                .filter(|name| *name != "accountActivities")
                .collect::<Vec<_>>(),
            dts_string_union(&dts, "SvmTransactionFieldName")
        );
        assert_eq!(names(BLOCK), dts_string_union(&dts, "SvmBlockFieldName"));
    }

    fn quoted_names_between(src: &str, start_marker: &str, end_marker: &str) -> Vec<String> {
        let start = src
            .find(start_marker)
            .unwrap_or_else(|| panic!("{start_marker}"));
        let rest = &src[start + start_marker.len()..];
        let end = rest
            .find(end_marker)
            .unwrap_or_else(|| panic!("{end_marker}"));
        let mut names = Vec::new();
        let mut chars = rest[..end].chars().peekable();
        while let Some(c) = chars.next() {
            if c == '"' {
                let mut name = String::new();
                for c in chars.by_ref() {
                    if c == '"' {
                        break;
                    }
                    name.push(c);
                }
                names.push(name);
            }
        }
        names
    }

    #[test]
    fn handler_names_match_event_config_builder() {
        let res = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../envio/src/EventConfigBuilder.res"
        ))
        .expect("read EventConfigBuilder.res");
        assert_eq!(
            names(INSTRUCTION),
            quoted_names_between(
                &res,
                "let validSvmInstructionFields",
                "let validSvmTransactionFields"
            )
        );
        assert_eq!(
            names(TRANSACTION)
                .into_iter()
                .filter(|name| *name != "accountActivities")
                .collect::<Vec<_>>(),
            quoted_names_between(
                &res,
                "let validSvmTransactionFields",
                "let validSvmAccountActivityFields"
            )
        );
        assert_eq!(
            names(ACCOUNT_ACTIVITY),
            quoted_names_between(
                &res,
                "let validSvmAccountActivityFields",
                "let validSvmBlockFields"
            )
        );
        assert_eq!(
            names(BLOCK),
            quoted_names_between(&res, "let validSvmBlockFields", "let validSvmLogFields")
        );
        assert_eq!(
            names(LOG),
            quoted_names_between(
                &res,
                "let validSvmLogFields",
                "let resolveSvmInlineFieldSelection"
            )
        );
    }

    #[test]
    fn query_columns_are_hypersync_fields() {
        for field in TRANSACTION {
            parse_all::<TransactionField>(field.columns, "transaction");
        }
        for field in BLOCK {
            parse_all::<BlockField>(field.columns, "block");
        }
        for field in ACCOUNT_ACTIVITY {
            parse_all::<AccountActivityField>(field.columns, "account_activity");
        }
        for field in LOG {
            parse_all::<LogField>(field.columns, "log");
        }
        parse_all::<TransactionField>(TX_KEYS, "transaction keys");
        parse_all::<BlockField>(BLOCK_KEYS, "block keys");
        parse_all::<AccountActivityField>(ACTIVITY_KEYS, "account_activity keys");
        parse_all::<LogField>(LOG_KEYS, "log keys");
        parse_all::<InstructionField>(INSTRUCTION_REQUIRED, "instruction required");
        parse_all::<InstructionField>(&["account_arguments"], "instruction extra");
    }

    #[test]
    fn address_only_still_opts_into_the_activity_table() {
        assert_eq!(
            account_activity_query_columns(&["address".to_string()]).unwrap(),
            ACTIVITY_KEYS
        );
    }

    #[test]
    fn empty_activity_selection_fetches_no_activity_columns() {
        assert!(account_activity_query_columns(&[]).unwrap().is_empty());
    }

    #[test]
    fn lamports_pre_does_not_fetch_post() {
        assert_eq!(
            account_activity_query_columns(&["lamports.pre".to_string()]).unwrap(),
            vec!["slot", "transaction_index", "account", "pre_balance"]
        );
    }

    #[test]
    fn transaction_index_alone_fetches_no_transaction_table() {
        assert!(transaction_query_columns(&["transactionIndex".to_string()])
            .unwrap()
            .is_empty());
    }

    #[test]
    fn instruction_required_does_not_fetch_prefixes_or_positional_accounts() {
        for column in [
            "d1",
            "d2",
            "d4",
            "d8",
            "a0",
            "a1",
            "executing_account_index",
        ] {
            assert!(
                !INSTRUCTION_REQUIRED.contains(&column),
                "{column} should not be a required instruction column"
            );
        }
    }

    #[test]
    fn instruction_account_columns_are_opt_in() {
        assert_eq!(
            instruction_query_columns(&[], false).unwrap(),
            INSTRUCTION_REQUIRED
        );
        assert!(instruction_query_columns(&["accounts".to_string()], false)
            .unwrap()
            .contains(&"account_arguments"));
        assert!(instruction_query_columns(&[], true)
            .unwrap()
            .contains(&"account_arguments"));
        assert!(!instruction_query_columns(&["args".to_string()], false)
            .unwrap()
            .contains(&"account_arguments"));
    }
}
