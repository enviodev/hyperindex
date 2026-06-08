use anyhow::Result;
use hypersync_solana_net_types::{
    field_selection::{
        BalanceField, BlockField, InstructionField, LogField, RewardField, SolanaFieldSelection,
        TokenBalanceField, TransactionField,
    },
    query as net,
};
use napi_derive::napi;

/// Top-level Solana HyperSync query.
///
/// Mirrors `hypersync_solana_net_types::query::SolanaQuery` with JS-friendly
/// numeric types (`i64` instead of `u64`).
#[napi(object)]
#[derive(Default, Clone)]
pub struct SolanaQuery {
    pub from_slot: i64,
    pub to_slot: Option<i64>,
    pub instructions: Option<Vec<InstructionSelection>>,
    pub transactions: Option<Vec<TransactionSelection>>,
    pub logs: Option<Vec<LogSelection>>,
    pub balances: Option<Vec<BalanceSelection>>,
    pub token_balances: Option<Vec<TokenBalanceSelection>>,
    pub include_all_blocks: Option<bool>,
    /// Return native SOL balances for the matched result set without requiring
    /// `include_all_blocks`.
    pub include_balances: Option<bool>,
    /// Return SPL token balances for the matched result set without requiring
    /// `include_all_blocks`.
    pub include_token_balances: Option<bool>,
    pub fields: Option<FieldSelection>,
    pub max_num_blocks: Option<i64>,
    pub max_num_transactions: Option<i64>,
    pub max_num_instructions: Option<i64>,
    pub max_num_logs: Option<i64>,
    pub max_num_balances: Option<i64>,
    pub max_num_token_balances: Option<i64>,
    /// Per-program Borsh schemas. When present, `get` decodes each returned
    /// instruction whose `program_id` matches one of these, attaching `decoded`.
    /// Purely client-side: ignored by the wire-query conversion below.
    pub program_schemas: Option<Vec<ProgramSchemaRef>>,
}

/// Reference to a program's registered Borsh schema. `schema_handle` is the
/// index returned by `register_program_schema`.
#[napi(object)]
#[derive(Default, Clone)]
pub struct ProgramSchemaRef {
    pub program_id: String,
    pub schema_handle: u32,
}

#[napi(object)]
#[derive(Default, Clone)]
pub struct BalanceSelection {
    pub account: Option<Vec<String>>,
}

#[napi(object)]
#[derive(Default, Clone)]
pub struct TokenBalanceSelection {
    pub account: Option<Vec<String>>,
    pub mint: Option<Vec<String>>,
    pub owner: Option<Vec<String>>,
    pub program_id: Option<Vec<String>>,
}

/// Filter for selecting instructions. All non-empty fields are AND-ed: an
/// instruction must match at least one value in every non-empty field.
#[napi(object)]
#[derive(Default, Clone)]
pub struct InstructionSelection {
    pub program_id: Option<Vec<String>>,
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
    pub include_transaction: Option<bool>,
    pub include_logs: Option<bool>,
    /// Also return native SOL balances for matched txs (scoped join).
    pub include_balances: Option<bool>,
    /// Also return SPL token balances for matched txs (scoped join).
    pub include_token_balances: Option<bool>,
}

#[napi(object)]
#[derive(Default, Clone)]
pub struct TransactionSelection {
    pub fee_payer: Option<Vec<String>>,
    pub success: Option<bool>,
    pub include_instructions: Option<bool>,
    pub include_balances: Option<bool>,
    pub include_token_balances: Option<bool>,
}

#[napi(object)]
#[derive(Default, Clone)]
pub struct LogSelection {
    pub program_id: Option<Vec<String>>,
    pub kind: Option<Vec<String>>,
    pub include_transaction: Option<bool>,
    pub include_instruction: Option<bool>,
    pub include_balances: Option<bool>,
    pub include_token_balances: Option<bool>,
}

/// Per-table field selection. Each field accepts a list of column names; an
/// empty / absent list means "all columns for that table".
#[napi(object)]
#[derive(Default, Clone)]
pub struct FieldSelection {
    pub block: Option<Vec<String>>,
    pub transaction: Option<Vec<String>>,
    pub instruction: Option<Vec<String>>,
    pub log: Option<Vec<String>>,
    pub balance: Option<Vec<String>>,
    pub token_balance: Option<Vec<String>>,
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

impl TryFrom<FieldSelection> for SolanaFieldSelection {
    type Error = anyhow::Error;

    fn try_from(f: FieldSelection) -> Result<Self> {
        Ok(Self {
            block: parse_fields::<BlockField>(f.block, "block")?,
            transaction: parse_fields::<TransactionField>(f.transaction, "transaction")?,
            instruction: parse_fields::<InstructionField>(f.instruction, "instruction")?,
            log: parse_fields::<LogField>(f.log, "log")?,
            balance: parse_fields::<BalanceField>(f.balance, "balance")?,
            token_balance: parse_fields::<TokenBalanceField>(f.token_balance, "token_balance")?,
            reward: parse_fields::<RewardField>(f.reward, "reward")?,
        })
    }
}

impl From<InstructionSelection> for net::InstructionSelection {
    fn from(s: InstructionSelection) -> Self {
        Self {
            program_id: s.program_id.unwrap_or_default(),
            d1: s.d1.unwrap_or_default(),
            d2: s.d2.unwrap_or_default(),
            d4: s.d4.unwrap_or_default(),
            d8: s.d8.unwrap_or_default(),
            a0: s.a0.unwrap_or_default(),
            a1: s.a1.unwrap_or_default(),
            a2: s.a2.unwrap_or_default(),
            a3: s.a3.unwrap_or_default(),
            a4: s.a4.unwrap_or_default(),
            a5: s.a5.unwrap_or_default(),
            a6: s.a6.unwrap_or_default(),
            a7: s.a7.unwrap_or_default(),
            a8: s.a8.unwrap_or_default(),
            a9: s.a9.unwrap_or_default(),
            is_inner: s.is_inner,
            include_transaction: s.include_transaction.unwrap_or_default(),
            include_logs: s.include_logs.unwrap_or_default(),
            include_inner_instructions: false,
            include_balances: s.include_balances.unwrap_or_default(),
            include_token_balances: s.include_token_balances.unwrap_or_default(),
        }
    }
}

impl From<TransactionSelection> for net::TransactionSelection {
    fn from(s: TransactionSelection) -> Self {
        Self {
            fee_payer: s.fee_payer.unwrap_or_default(),
            success: s.success,
            include_instructions: s.include_instructions.unwrap_or_default(),
            include_balances: s.include_balances.unwrap_or_default(),
            include_token_balances: s.include_token_balances.unwrap_or_default(),
        }
    }
}

impl From<LogSelection> for net::LogSelection {
    fn from(s: LogSelection) -> Self {
        Self {
            program_id: s.program_id.unwrap_or_default(),
            kind: s.kind.unwrap_or_default(),
            include_transaction: s.include_transaction.unwrap_or_default(),
            include_instruction: s.include_instruction.unwrap_or_default(),
            include_balances: s.include_balances.unwrap_or_default(),
            include_token_balances: s.include_token_balances.unwrap_or_default(),
        }
    }
}

impl From<BalanceSelection> for net::BalanceSelection {
    fn from(s: BalanceSelection) -> Self {
        Self {
            account: s.account.unwrap_or_default(),
        }
    }
}

impl From<TokenBalanceSelection> for net::TokenBalanceSelection {
    fn from(s: TokenBalanceSelection) -> Self {
        Self {
            account: s.account.unwrap_or_default(),
            mint: s.mint.unwrap_or_default(),
            owner: s.owner.unwrap_or_default(),
            program_id: s.program_id.unwrap_or_default(),
        }
    }
}

impl TryFrom<SolanaQuery> for net::SolanaQuery {
    type Error = anyhow::Error;

    fn try_from(q: SolanaQuery) -> Result<Self> {
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
            instructions: q
                .instructions
                .unwrap_or_default()
                .into_iter()
                .map(Into::into)
                .collect(),
            transactions: q
                .transactions
                .unwrap_or_default()
                .into_iter()
                .map(Into::into)
                .collect(),
            logs: q
                .logs
                .unwrap_or_default()
                .into_iter()
                .map(Into::into)
                .collect(),
            balances: q
                .balances
                .unwrap_or_default()
                .into_iter()
                .map(Into::into)
                .collect(),
            token_balances: q
                .token_balances
                .unwrap_or_default()
                .into_iter()
                .map(Into::into)
                .collect(),
            include_all_blocks: q.include_all_blocks.unwrap_or_default(),
            include_balances: q.include_balances.unwrap_or_default(),
            include_token_balances: q.include_token_balances.unwrap_or_default(),
            fields: q
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
            max_num_balances: q.max_num_balances.filter(|v| *v >= 0).map(|v| v as usize),
            max_num_token_balances: q
                .max_num_token_balances
                .filter(|v| *v >= 0)
                .map(|v| v as usize),
        })
    }
}
