use anyhow::{anyhow, Context, Result};
use hyperfuel_client::format::{Hash, Hex};
use hyperfuel_client::net_types;
use napi::bindgen_prelude::BigInt;
use napi_derive::napi;

/// Query for retrieving Fuel receipts and their blocks.
#[napi(object)]
#[derive(Default)]
pub struct Query {
    pub from_block: i64,
    #[napi(js_name = "toBlock")]
    pub to_block_exclusive: Option<i64>,
    pub receipts: Option<Vec<ReceiptSelection>>,
    pub field_selection: FieldSelection,
}

#[napi(object)]
#[derive(Default)]
pub struct ReceiptSelection {
    pub root_contract_id: Option<Vec<String>>,
    pub receipt_type: Option<Vec<u8>>,
    pub rb: Option<Vec<BigInt>>,
    pub tx_status: Option<Vec<u8>>,
}

#[napi(object)]
#[derive(Default)]
pub struct FieldSelection {
    pub block: Option<Vec<String>>,
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
            receipt_type: s.receipt_type.unwrap_or_default(),
            rb: bigints_to_u64(s.rb),
            tx_status: s.tx_status.unwrap_or_default(),
            ..Default::default()
        })
    }
}

impl From<FieldSelection> for net_types::FieldSelection {
    fn from(f: FieldSelection) -> Self {
        net_types::FieldSelection {
            block: f.block.unwrap_or_default().into_iter().collect(),
            receipt: f.receipt.unwrap_or_default().into_iter().collect(),
            ..Default::default()
        }
    }
}

impl TryFrom<Query> for net_types::Query {
    type Error = anyhow::Error;

    fn try_from(q: Query) -> Result<Self> {
        let from_block = u64::try_from(q.from_block).context("from_block must be >= 0")?;
        let to_block = q
            .to_block_exclusive
            .map(|b| u64::try_from(b).context("toBlock must be >= 0"))
            .transpose()?;
        let receipts = q
            .receipts
            .unwrap_or_default()
            .into_iter()
            .map(TryInto::try_into)
            .collect::<Result<Vec<_>>>()?;

        Ok(net_types::Query {
            from_block,
            to_block,
            receipts,
            field_selection: q.field_selection.into(),
            ..Default::default()
        })
    }
}
