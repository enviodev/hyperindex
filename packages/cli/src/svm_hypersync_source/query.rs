use anyhow::Result;
use hypersync_solana_net_types::{
    field_selection::{
        AccountActivityField, BlockField, InstructionField, LogField, RewardField,
        SolanaFieldSelection, TransactionField,
    },
    query as net, Address, LogKind,
};
use napi_derive::napi;

/// Top-level Solana HyperSync query.
///
/// Mirrors `hypersync_solana_net_types::query::SolanaQuery` with JS-friendly
/// numeric types (`i64` instead of `u64`).
#[napi(object)]
#[derive(Default, Clone)]
pub struct SvmQuery {
    pub from_slot: i64,
    pub to_slot: Option<i64>,
    pub instruction_calls: Option<Vec<InstructionSelection>>,
    pub transactions: Option<Vec<TransactionSelection>>,
    pub logs: Option<Vec<LogSelection>>,
    pub account_activity: Option<Vec<AccountActivitySelection>>,
    pub include_all_blocks: Option<bool>,
    pub fields: Option<FieldSelection>,
    pub max_num_blocks: Option<i64>,
    pub max_num_transactions: Option<i64>,
    pub max_num_instructions: Option<i64>,
    pub max_num_logs: Option<i64>,
    pub max_num_account_activity: Option<i64>,
}

/// Filter for selecting rows of the unified `account_activity` table (the
/// merged replacement for the removed `balances`/`token_balances` tables).
#[napi(object)]
#[derive(Default, Clone)]
pub struct AccountActivitySelection {
    /// "native" and/or "token"; empty matches every row.
    pub kind: Option<Vec<String>>,
    pub account: Option<Vec<String>>,
    pub mint: Option<Vec<String>>,
    pub owner: Option<Vec<String>>,
    pub program_id: Option<Vec<String>>,
}

/// Filter for selecting instruction calls. All non-empty fields are AND-ed: an
/// instruction must match at least one value in every non-empty field.
#[napi(object)]
#[derive(Default, Clone)]
pub struct InstructionSelection {
    pub executing_account: Option<Vec<String>>,
    /// 1-byte instruction-data prefix, hex-encoded ("0x" optional).
    pub d1: Option<Vec<String>>,
    pub d2: Option<Vec<String>>,
    pub d4: Option<Vec<String>>,
    /// 8-byte Anchor discriminator, hex-encoded.
    pub d8: Option<Vec<String>>,
    pub a0: Option<Vec<String>>,
    pub a1: Option<Vec<String>>,
    pub a2: Option<Vec<String>>,
    pub a3: Option<Vec<String>>,
    pub a4: Option<Vec<String>>,
    pub a5: Option<Vec<String>>,
    pub a6: Option<Vec<String>>,
    pub a7: Option<Vec<String>>,
    pub a8: Option<Vec<String>>,
    pub a9: Option<Vec<String>>,
    pub is_inner: Option<bool>,
    /// Filter on the success of the PARENT transaction (tri-state: absent
    /// matches both).
    pub tx_success: Option<bool>,
}

#[napi(object)]
#[derive(Default, Clone)]
pub struct TransactionSelection {
    pub fee_payer: Option<Vec<String>>,
    pub success: Option<bool>,
}

#[napi(object)]
#[derive(Default, Clone)]
pub struct LogSelection {
    pub program_id: Option<Vec<String>>,
    pub kind: Option<Vec<String>>,
}

/// Per-table field selection. Each field accepts a list of column names; an
/// empty / absent list means "all columns for that table".
#[napi(object)]
#[derive(Default, Clone)]
pub struct FieldSelection {
    pub block: Option<Vec<String>>,
    pub transaction: Option<Vec<String>>,
    pub instruction_call: Option<Vec<String>>,
    pub log: Option<Vec<String>>,
    pub account_activity: Option<Vec<String>>,
    pub reward: Option<Vec<String>>,
}

fn parse_fields<F>(values: Option<Vec<String>>, table: &str) -> Result<Vec<F>>
where
    F: std::str::FromStr,
{
    values
        .unwrap_or_default()
        .into_iter()
        .map(|name| {
            name.parse::<F>()
                .map_err(|_| anyhow::anyhow!("unknown field name {:?} for {} table", name, table))
        })
        .collect()
}

fn parse_addresses(values: Option<Vec<String>>, field: &str) -> Result<Vec<Address>> {
    values
        .unwrap_or_default()
        .into_iter()
        .map(|value| {
            value
                .parse::<Address>()
                .map_err(|e| anyhow::anyhow!("invalid pubkey {:?} for {}: {}", value, field, e))
        })
        .collect()
}

impl TryFrom<FieldSelection> for SolanaFieldSelection {
    type Error = anyhow::Error;

    fn try_from(f: FieldSelection) -> Result<Self> {
        let mut account_activity =
            parse_fields::<AccountActivityField>(f.account_activity, "account_activity")?;
        // Our caller only lists account_activity columns when token balances
        // are actually wanted (see SvmHyperSyncSource.res); an empty list must
        // stay untouched. Otherwise force `account` in — the store keys
        // balance rows by account regardless of what the caller selected.
        if !account_activity.is_empty()
            && !account_activity.contains(&AccountActivityField::Account)
        {
            account_activity.push(AccountActivityField::Account);
        }
        Ok(Self {
            block: parse_fields::<BlockField>(f.block, "block")?,
            transaction: parse_fields::<TransactionField>(f.transaction, "transaction")?,
            instruction_call: parse_fields::<InstructionField>(
                f.instruction_call,
                "instruction_call",
            )?,
            log: parse_fields::<LogField>(f.log, "log")?,
            account_activity,
            reward: parse_fields::<RewardField>(f.reward, "reward")?,
        })
    }
}

impl TryFrom<InstructionSelection> for net::InstructionSelection {
    type Error = anyhow::Error;

    fn try_from(s: InstructionSelection) -> Result<Self> {
        Ok(Self {
            executing_account: parse_addresses(s.executing_account, "executing_account")?,
            d1: s.d1.unwrap_or_default(),
            d2: s.d2.unwrap_or_default(),
            d4: s.d4.unwrap_or_default(),
            d8: s.d8.unwrap_or_default(),
            a0: parse_addresses(s.a0, "a0")?,
            a1: parse_addresses(s.a1, "a1")?,
            a2: parse_addresses(s.a2, "a2")?,
            a3: parse_addresses(s.a3, "a3")?,
            a4: parse_addresses(s.a4, "a4")?,
            a5: parse_addresses(s.a5, "a5")?,
            a6: parse_addresses(s.a6, "a6")?,
            a7: parse_addresses(s.a7, "a7")?,
            a8: parse_addresses(s.a8, "a8")?,
            a9: parse_addresses(s.a9, "a9")?,
            is_inner: s.is_inner,
            tx_success: s.tx_success,
        })
    }
}

impl TryFrom<TransactionSelection> for net::TransactionSelection {
    type Error = anyhow::Error;

    fn try_from(s: TransactionSelection) -> Result<Self> {
        Ok(Self {
            fee_payer: parse_addresses(s.fee_payer, "fee_payer")?,
            transaction_id: Vec::new(),
            transaction_index: Vec::new(),
            success: s.success,
        })
    }
}

impl TryFrom<LogSelection> for net::LogSelection {
    type Error = anyhow::Error;

    fn try_from(s: LogSelection) -> Result<Self> {
        Ok(Self {
            program_id: parse_addresses(s.program_id, "program_id")?,
            kind: s
                .kind
                .unwrap_or_default()
                .into_iter()
                .map(|k| {
                    k.parse::<LogKind>()
                        .map_err(|e| anyhow::anyhow!("invalid log kind: {}", e))
                })
                .collect::<Result<_>>()?,
        })
    }
}

impl TryFrom<AccountActivitySelection> for net::AccountActivitySelection {
    type Error = anyhow::Error;

    fn try_from(s: AccountActivitySelection) -> Result<Self> {
        Ok(Self {
            kind: s
                .kind
                .unwrap_or_default()
                .into_iter()
                .map(|k| match k.as_str() {
                    "native" => Ok(net::ActivityKind::Native),
                    "token" => Ok(net::ActivityKind::Token),
                    other => Err(anyhow::anyhow!("invalid activity kind {:?}", other)),
                })
                .collect::<Result<_>>()?,
            account: parse_addresses(s.account, "account")?,
            transaction_id: Vec::new(),
            mint: parse_addresses(s.mint, "mint")?,
            owner: parse_addresses(s.owner, "owner")?,
            program_id: parse_addresses(s.program_id, "program_id")?,
            is_signer: None,
            is_writable: None,
            is_fee_payer: None,
            from_lookup_table: None,
        })
    }
}

fn try_map_selections<T, U>(items: Option<Vec<T>>) -> Result<Vec<U>>
where
    U: TryFrom<T, Error = anyhow::Error>,
{
    items
        .unwrap_or_default()
        .into_iter()
        .map(U::try_from)
        .collect()
}

impl TryFrom<SvmQuery> for net::SolanaQuery {
    type Error = anyhow::Error;

    fn try_from(q: SvmQuery) -> Result<Self> {
        anyhow::ensure!(q.from_slot >= 0, "from_slot must be non-negative");
        Ok(Self {
            from_slot: q.from_slot as u64,
            to_slot: q
                .to_slot
                .map(|v| {
                    anyhow::ensure!(v >= 0, "to_slot must be non-negative");
                    Ok(v as u64)
                })
                .transpose()?,
            instruction_calls: try_map_selections(q.instruction_calls)?,
            transactions: try_map_selections(q.transactions)?,
            logs: try_map_selections(q.logs)?,
            account_activity: try_map_selections(q.account_activity)?,
            include_all_blocks: q.include_all_blocks.unwrap_or_default(),
            field_selection: q
                .fields
                .map(TryInto::try_into)
                .transpose()?
                .unwrap_or_default(),
            max_num_blocks: q.max_num_blocks.filter(|v| *v >= 0).map(|v| v as usize),
            max_num_transactions: q
                .max_num_transactions
                .filter(|v| *v >= 0)
                .map(|v| v as usize),
            max_num_instructions: q
                .max_num_instructions
                .filter(|v| *v >= 0)
                .map(|v| v as usize),
            max_num_logs: q.max_num_logs.filter(|v| *v >= 0).map(|v| v as usize),
            max_num_account_activity: q
                .max_num_account_activity
                .filter(|v| *v >= 0)
                .map(|v| v as usize),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn field_selection(account_activity: Option<Vec<String>>) -> SolanaFieldSelection {
        FieldSelection {
            account_activity,
            ..Default::default()
        }
        .try_into()
        .expect("valid field selection")
    }

    #[test]
    fn account_is_force_added_when_account_activity_is_selected() {
        let selection = field_selection(Some(vec!["mint".to_string()]));
        assert_eq!(
            selection.account_activity,
            vec![AccountActivityField::Mint, AccountActivityField::Account]
        );
    }

    #[test]
    fn account_is_not_duplicated_when_already_selected() {
        let selection = field_selection(Some(vec!["account".to_string(), "mint".to_string()]));
        assert_eq!(
            selection.account_activity,
            vec![AccountActivityField::Account, AccountActivityField::Mint]
        );
    }

    #[test]
    fn empty_account_activity_selection_stays_empty() {
        // An empty list opts the query OUT of account-activity rows entirely
        // (server-side merge-mode semantics); force-adding `account` here
        // would wrongly opt every query into fetching them.
        assert!(field_selection(None).account_activity.is_empty());
        assert!(field_selection(Some(vec![])).account_activity.is_empty());
    }

    #[test]
    fn instruction_selection_serializes_with_wave2_names() {
        let q = SvmQuery {
            from_slot: 0,
            instruction_calls: Some(vec![InstructionSelection {
                executing_account: Some(vec![
                    "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA".to_string()
                ]),
                tx_success: Some(true),
                ..Default::default()
            }]),
            ..Default::default()
        };
        let net_query: net::SolanaQuery = q.try_into().expect("valid query");
        let json = serde_json::to_string(&net_query).expect("serialize");
        let summary = (
            json.contains("instruction_calls"),
            json.contains("executing_account"),
            json.contains("\"tx_success\":true"),
            json.contains("is_committed") || json.contains("program_id"),
        );
        assert_eq!(summary, (true, true, true, false));
    }

    #[test]
    fn malformed_pubkey_in_selection_is_an_error() {
        let q = SvmQuery {
            from_slot: 0,
            instruction_calls: Some(vec![InstructionSelection {
                executing_account: Some(vec!["not-base58!".to_string()]),
                ..Default::default()
            }]),
            ..Default::default()
        };
        let err = net::SolanaQuery::try_from(q).expect_err("must reject bad pubkey");
        assert!(err.to_string().contains("executing_account"));
    }
}
