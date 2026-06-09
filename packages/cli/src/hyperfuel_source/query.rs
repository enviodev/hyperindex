use anyhow::{anyhow, Context, Result};
use hyperfuel_client::format::{Hash, Hex};
use hyperfuel_client::net_types;
use napi::bindgen_prelude::BigInt;
use napi_derive::napi;
use std::collections::BTreeSet;

/// Query for retrieving Fuel data.
#[napi(object)]
#[derive(Default)]
pub struct Query {
    pub from_block: i64,
    #[napi(js_name = "toBlock")]
    pub to_block_exclusive: Option<i64>,
    pub receipts: Option<Vec<ReceiptSelection>>,
    pub inputs: Option<Vec<InputSelection>>,
    pub outputs: Option<Vec<OutputSelection>>,
    pub include_all_blocks: Option<bool>,
    pub field_selection: FieldSelection,
    pub max_num_blocks: Option<i64>,
    pub max_num_transactions: Option<i64>,
}

#[napi(object)]
#[derive(Default)]
pub struct ReceiptSelection {
    pub root_contract_id: Option<Vec<String>>,
    pub to_address: Option<Vec<String>>,
    pub asset_id: Option<Vec<String>>,
    pub receipt_type: Option<Vec<u8>>,
    pub sender: Option<Vec<String>>,
    pub recipient: Option<Vec<String>>,
    pub contract_id: Option<Vec<String>>,
    pub ra: Option<Vec<BigInt>>,
    pub rb: Option<Vec<BigInt>>,
    pub rc: Option<Vec<BigInt>>,
    pub rd: Option<Vec<BigInt>>,
    pub tx_status: Option<Vec<u8>>,
}

#[napi(object)]
#[derive(Default)]
pub struct InputSelection {
    pub owner: Option<Vec<String>>,
    pub asset_id: Option<Vec<String>>,
    pub contract: Option<Vec<String>>,
    pub sender: Option<Vec<String>>,
    pub recipient: Option<Vec<String>>,
    pub input_type: Option<Vec<u8>>,
    pub tx_status: Option<Vec<u8>>,
}

#[napi(object)]
#[derive(Default)]
pub struct OutputSelection {
    pub to: Option<Vec<String>>,
    pub asset_id: Option<Vec<String>>,
    pub contract: Option<Vec<String>>,
    pub output_type: Option<Vec<u8>>,
    pub tx_status: Option<Vec<u8>>,
}

#[napi(object)]
#[derive(Default)]
pub struct FieldSelection {
    pub block: Option<Vec<String>>,
    pub transaction: Option<Vec<String>>,
    pub receipt: Option<Vec<String>>,
}

fn parse_hashes(v: Option<Vec<String>>) -> Result<Vec<Hash>> {
    v.unwrap_or_default()
        .into_iter()
        .map(|s| Hash::decode_hex(&s).map_err(|e| anyhow!("failed to parse hash {s}: {e:?}")))
        .collect()
}

fn bigints_to_u64(v: Option<Vec<BigInt>>) -> Vec<u64> {
    v.unwrap_or_default()
        .into_iter()
        .map(|b| b.get_u64().1)
        .collect()
}

impl TryFrom<ReceiptSelection> for net_types::ReceiptSelection {
    type Error = anyhow::Error;

    fn try_from(s: ReceiptSelection) -> Result<Self> {
        Ok(net_types::ReceiptSelection {
            root_contract_id: parse_hashes(s.root_contract_id)?,
            to: Vec::new(),
            to_address: parse_hashes(s.to_address)?,
            asset_id: parse_hashes(s.asset_id)?,
            receipt_type: s.receipt_type.unwrap_or_default(),
            sender: parse_hashes(s.sender)?,
            recipient: parse_hashes(s.recipient)?,
            contract_id: parse_hashes(s.contract_id)?,
            ra: bigints_to_u64(s.ra),
            rb: bigints_to_u64(s.rb),
            rc: bigints_to_u64(s.rc),
            rd: bigints_to_u64(s.rd),
            tx_status: s.tx_status.unwrap_or_default(),
            tx_type: Vec::new(),
        })
    }
}

impl TryFrom<InputSelection> for net_types::InputSelection {
    type Error = anyhow::Error;

    fn try_from(s: InputSelection) -> Result<Self> {
        Ok(net_types::InputSelection {
            owner: parse_hashes(s.owner)?,
            asset_id: parse_hashes(s.asset_id)?,
            contract: parse_hashes(s.contract)?,
            sender: parse_hashes(s.sender)?,
            recipient: parse_hashes(s.recipient)?,
            input_type: s.input_type.unwrap_or_default(),
            tx_status: s.tx_status.unwrap_or_default(),
            tx_type: Vec::new(),
        })
    }
}

impl TryFrom<OutputSelection> for net_types::OutputSelection {
    type Error = anyhow::Error;

    fn try_from(s: OutputSelection) -> Result<Self> {
        Ok(net_types::OutputSelection {
            to: parse_hashes(s.to)?,
            asset_id: parse_hashes(s.asset_id)?,
            contract: parse_hashes(s.contract)?,
            output_type: s.output_type.unwrap_or_default(),
            tx_status: s.tx_status.unwrap_or_default(),
            tx_type: Vec::new(),
        })
    }
}

impl From<FieldSelection> for net_types::FieldSelection {
    fn from(f: FieldSelection) -> Self {
        net_types::FieldSelection {
            block: f.block.unwrap_or_default().into_iter().collect(),
            transaction: f.transaction.unwrap_or_default().into_iter().collect(),
            receipt: f.receipt.unwrap_or_default().into_iter().collect(),
            input: BTreeSet::new(),
            output: BTreeSet::new(),
        }
    }
}

fn try_collect<T, U>(v: Option<Vec<T>>) -> Result<Vec<U>>
where
    T: TryInto<U, Error = anyhow::Error>,
{
    v.unwrap_or_default()
        .into_iter()
        .map(TryInto::try_into)
        .collect()
}

impl TryFrom<Query> for net_types::Query {
    type Error = anyhow::Error;

    fn try_from(q: Query) -> Result<Self> {
        let from_block = u64::try_from(q.from_block).context("from_block must be >= 0")?;
        let to_block = q
            .to_block_exclusive
            .map(|b| u64::try_from(b).context("toBlock must be >= 0"))
            .transpose()?;

        Ok(net_types::Query {
            from_block,
            to_block,
            receipts: try_collect(q.receipts)?,
            inputs: try_collect(q.inputs)?,
            outputs: try_collect(q.outputs)?,
            include_all_blocks: q.include_all_blocks.unwrap_or(false),
            field_selection: q.field_selection.into(),
            max_num_blocks: q.max_num_blocks.map(|n| n as usize),
            max_num_transactions: q.max_num_transactions.map(|n| n as usize),
            max_num_receipts: None,
            max_num_inputs: None,
            max_num_outputs: None,
            join_mode: net_types::JoinMode::Default,
        })
    }
}
