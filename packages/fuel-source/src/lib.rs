use std::{num::NonZeroU64, sync::Arc, time::Duration};

use anyhow::{anyhow, Context, Result};
use hyperfuel_client::Client;
use hyperfuel_format::Hex;
use hyperfuel_net_types::{FieldSelection, Query};
use napi::bindgen_prelude::BigInt;
use napi_derive::napi;
use url::Url;

const HTTP_REQ_TIMEOUT_MILLIS: u64 = 30_000;

const RETRY_MAX_ATTEMPTS: usize = 5;
const RETRY_INITIAL_BACKOFF_MS: u64 = 100;
const RETRY_BACKOFF_MULTIPLIER: u64 = 4;

const BLOCK_NOT_FOUND_DELAY_MS: u64 = 100;

fn receipt_field_set() -> std::collections::BTreeSet<String> {
    [
        "tx_id",
        "block_height",
        "root_contract_id",
        "data",
        "receipt_index",
        "receipt_type",
        "rb",
        "sub_id",
        "val",
        "amount",
        "to_address",
        "asset_id",
        "to",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

fn block_field_set() -> std::collections::BTreeSet<String> {
    ["id", "height", "time"]
        .iter()
        .map(|s| s.to_string())
        .collect()
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct Config {
    pub url: String,
    pub api_token: String,
}

#[napi(object)]
#[derive(Default, Clone, Debug)]
pub struct ReceiptSelection {
    pub root_contract_id: Option<Vec<String>>,
    pub receipt_type: Option<Vec<u8>>,
    pub tx_status: Option<Vec<u8>>,
    pub rb: Option<Vec<BigInt>>,
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct Block {
    pub id: String,
    pub time: i64,
    pub height: i64,
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct Receipt {
    pub receipt_index: i64,
    pub root_contract_id: Option<String>,
    pub tx_id: String,
    pub tx_status: u8,
    pub block_height: i64,
    pub to: Option<String>,
    pub to_address: Option<String>,
    pub amount: Option<BigInt>,
    pub asset_id: Option<String>,
    pub val: Option<BigInt>,
    pub rb: Option<BigInt>,
    pub receipt_type: u8,
    pub data: Option<String>,
    pub sub_id: Option<String>,
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct Item {
    pub transaction_id: String,
    pub contract_id: String,
    pub receipt: Receipt,
    pub receipt_index: i64,
    pub block: Block,
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct LogsQueryPage {
    pub items: Vec<Item>,
    pub next_block: i64,
    pub archive_height: i64,
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct BlockDataWithTimestamp {
    pub block_number: i64,
    pub block_timestamp: i64,
    pub block_hash: String,
}

#[napi]
pub struct HyperfuelClient {
    inner: Arc<Client>,
}

#[napi]
impl HyperfuelClient {
    #[napi(constructor)]
    pub fn new(cfg: Config) -> napi::Result<Self> {
        let url = Url::parse(&cfg.url)
            .with_context(|| format!("parsing url {}", cfg.url))
            .map_err(into_napi_err)?;

        let inner_cfg = hyperfuel_client::Config {
            url,
            bearer_token: Some(cfg.api_token),
            http_req_timeout_millis: NonZeroU64::new(HTTP_REQ_TIMEOUT_MILLIS).unwrap(),
        };

        let inner = Client::new(inner_cfg)
            .context("build hyperfuel client")
            .map_err(into_napi_err)?;

        Ok(Self {
            inner: Arc::new(inner),
        })
    }

    #[napi]
    pub async fn get_logs(
        &self,
        from_block: i64,
        to_block_exclusive: Option<i64>,
        receipts_selection: Vec<ReceiptSelection>,
    ) -> napi::Result<LogsQueryPage> {
        let receipts = receipts_selection
            .into_iter()
            .map(convert_receipt_selection)
            .collect();

        let query = Query {
            from_block: u64::try_from(from_block).unwrap_or(0),
            to_block: to_block_exclusive.map(|t| u64::try_from(t).unwrap_or(0)),
            receipts,
            field_selection: FieldSelection {
                receipt: receipt_field_set(),
                block: block_field_set(),
                ..Default::default()
            },
            ..Default::default()
        };

        let resp = self
            .inner
            .get_selected_data(&query)
            .await
            .context("get_selected_data")
            .map_err(into_napi_err)?;

        Ok(build_logs_page(resp))
    }

    #[napi]
    pub async fn query_block_data(
        &self,
        block_number: i64,
    ) -> napi::Result<Option<BlockDataWithTimestamp>> {
        let target = u64::try_from(block_number).unwrap_or(0);

        let query = Query {
            from_block: target,
            to_block: Some(target + 1),
            // The server requires non-null input/output selections in some
            // historical block ranges; pass empty selections to mirror
            // existing behavior.
            inputs: vec![Default::default()],
            outputs: vec![Default::default()],
            include_all_blocks: true,
            field_selection: FieldSelection {
                block: block_field_set(),
                ..Default::default()
            },
            ..Default::default()
        };

        loop {
            let resp = retry_with_backoff(|| self.inner.get_selected_data(&query))
                .await
                .map_err(into_napi_err)?;

            if resp.next_block <= target {
                tokio::time::sleep(Duration::from_millis(BLOCK_NOT_FOUND_DELAY_MS)).await;
                continue;
            }

            let block = match resp.data.blocks.into_iter().next() {
                Some(b) => b,
                None => return Ok(None),
            };

            return Ok(Some(BlockDataWithTimestamp {
                block_number: u64_to_i64(*block.height),
                block_timestamp: u64_to_i64(*block.time),
                block_hash: block.id.encode_hex(),
            }));
        }
    }
}

fn convert_receipt_selection(sel: ReceiptSelection) -> hyperfuel_net_types::ReceiptSelection {
    let root_contract_id = sel
        .root_contract_id
        .unwrap_or_default()
        .into_iter()
        .filter_map(|s| parse_hash(&s))
        .collect();
    let rb = sel
        .rb
        .unwrap_or_default()
        .into_iter()
        .map(|b| b.get_u64().1)
        .collect();
    hyperfuel_net_types::ReceiptSelection {
        root_contract_id,
        receipt_type: sel.receipt_type.unwrap_or_default(),
        tx_status: sel.tx_status.unwrap_or_default(),
        rb,
        ..Default::default()
    }
}

fn parse_hash(s: &str) -> Option<hyperfuel_format::Hash> {
    hyperfuel_format::Hash::decode_hex(s).ok()
}

fn build_logs_page(resp: hyperfuel_client::QueryResponseTyped) -> LogsQueryPage {
    let hyperfuel_client::QueryResponseTyped {
        archive_height,
        next_block,
        data,
        ..
    } = resp;

    let mut blocks_by_height: std::collections::HashMap<u64, Block> =
        std::collections::HashMap::with_capacity(data.blocks.len());
    for b in data.blocks {
        let height: u64 = *b.height;
        blocks_by_height.insert(
            height,
            Block {
                id: b.id.encode_hex(),
                time: u64_to_i64(*b.time),
                height: u64_to_i64(height),
            },
        );
    }

    let mut items = Vec::with_capacity(data.receipts.len());
    for r in data.receipts {
        let Some(root_contract_id) = r.root_contract_id.as_ref() else {
            continue;
        };
        let block_height: u64 = *r.block_height;
        let Some(block) = blocks_by_height.get(&block_height).cloned() else {
            continue;
        };
        let contract_id = root_contract_id.encode_hex();
        let receipt_index = u64_to_i64(*r.receipt_index);
        let tx_id = r.tx_id.encode_hex();
        let receipt = Receipt {
            receipt_index,
            root_contract_id: Some(contract_id.clone()),
            tx_id: tx_id.clone(),
            tx_status: r.tx_status.as_u8(),
            block_height: u64_to_i64(block_height),
            to: r.to.as_ref().map(|d| d.encode_hex()),
            to_address: r.to_address.as_ref().map(|d| d.encode_hex()),
            amount: r.amount.map(uint_to_bigint),
            asset_id: r.asset_id.as_ref().map(|d| d.encode_hex()),
            val: r.val.map(uint_to_bigint),
            rb: r.rb.map(uint_to_bigint),
            receipt_type: r.receipt_type.to_u8(),
            data: r.data.as_ref().map(|d| d.encode_hex()),
            sub_id: r.sub_id.as_ref().map(|d| d.encode_hex()),
        };
        items.push(Item {
            transaction_id: tx_id,
            contract_id,
            receipt,
            receipt_index,
            block,
        });
    }

    LogsQueryPage {
        items,
        next_block: u64_to_i64(next_block),
        archive_height: archive_height.map(u64_to_i64).unwrap_or(0),
    }
}

fn uint_to_bigint(v: hyperfuel_format::UInt) -> BigInt {
    let n: u64 = *v;
    n.into()
}

fn u64_to_i64(v: u64) -> i64 {
    v.try_into().unwrap_or(i64::MAX)
}

fn into_napi_err(e: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{:?}", e))
}

async fn retry_with_backoff<T, F, Fut>(mut op: F) -> Result<T>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    let mut backoff = RETRY_INITIAL_BACKOFF_MS;
    let mut last_err: Option<anyhow::Error> = None;
    for _ in 0..=RETRY_MAX_ATTEMPTS {
        match op().await {
            Ok(v) => return Ok(v),
            Err(e) => {
                last_err = Some(e);
                tokio::time::sleep(Duration::from_millis(backoff)).await;
                backoff = backoff.saturating_mul(RETRY_BACKOFF_MULTIPLIER);
            }
        }
    }
    Err(last_err.unwrap_or_else(|| anyhow!("retry: unknown error")))
}
