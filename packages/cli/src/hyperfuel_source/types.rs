use hyperfuel_client::{ArrowBatch, ArrowResponse};
use napi::bindgen_prelude::BigInt;
use napi_derive::napi;
use polars_arrow::array::{BinaryArray, Int64Array, StaticArray, UInt64Array, UInt8Array};

#[napi(object)]
pub struct QueryResponse {
    pub archive_height: Option<i64>,
    pub next_block: i64,
    pub total_execution_time: i64,
    pub data: QueryResponseData,
}

#[napi(object)]
pub struct QueryResponseData {
    pub receipts: Vec<Receipt>,
    pub blocks: Option<Vec<Block>>,
}

#[napi(object)]
pub struct Receipt {
    pub receipt_index: i64,
    pub root_contract_id: Option<String>,
    pub tx_id: String,
    pub block_height: i64,
    pub receipt_type: i64,
    pub data: Option<String>,
    pub rb: Option<BigInt>,
    pub val: Option<BigInt>,
    pub sub_id: Option<String>,
    pub amount: Option<BigInt>,
    pub asset_id: Option<String>,
    pub to: Option<String>,
    pub to_address: Option<String>,
}

#[napi(object)]
pub struct Block {
    pub id: String,
    pub height: i64,
    pub time: i64,
}

fn encode_hex(bytes: &[u8]) -> String {
    format!("0x{}", faster_hex::hex_string(bytes))
}

fn hex_at(arr: &Option<&BinaryArray<i32>>, idx: usize) -> Option<String> {
    arr.and_then(|a| a.get(idx)).map(encode_hex)
}

fn u64_at(arr: &Option<&UInt64Array>, idx: usize) -> Option<u64> {
    arr.and_then(|a| a.get(idx))
}

fn u8_at(arr: &Option<&UInt8Array>, idx: usize) -> Option<u8> {
    arr.and_then(|a| a.get(idx))
}

fn i64_at(arr: &Option<&Int64Array>, idx: usize) -> Option<i64> {
    arr.and_then(|a| a.get(idx))
}

fn bigint_at(arr: &Option<&UInt64Array>, idx: usize) -> Option<BigInt> {
    u64_at(arr, idx).map(BigInt::from)
}

fn receipts_from_arrow(batches: &[ArrowBatch]) -> Vec<Receipt> {
    let mut out = Vec::new();
    for batch in batches {
        let receipt_index = batch.column::<UInt64Array>("receipt_index").ok();
        let root_contract_id = batch.column::<BinaryArray<i32>>("root_contract_id").ok();
        let tx_id = batch.column::<BinaryArray<i32>>("tx_id").ok();
        let block_height = batch.column::<UInt64Array>("block_height").ok();
        let receipt_type = batch.column::<UInt8Array>("receipt_type").ok();
        let data = batch.column::<BinaryArray<i32>>("data").ok();
        let rb = batch.column::<UInt64Array>("rb").ok();
        let val = batch.column::<UInt64Array>("val").ok();
        let sub_id = batch.column::<BinaryArray<i32>>("sub_id").ok();
        let amount = batch.column::<UInt64Array>("amount").ok();
        let asset_id = batch.column::<BinaryArray<i32>>("asset_id").ok();
        let to = batch.column::<BinaryArray<i32>>("to").ok();
        let to_address = batch.column::<BinaryArray<i32>>("to_address").ok();

        for idx in 0..batch.chunk.len() {
            out.push(Receipt {
                receipt_index: u64_at(&receipt_index, idx).unwrap_or_default() as i64,
                root_contract_id: hex_at(&root_contract_id, idx),
                tx_id: hex_at(&tx_id, idx).unwrap_or_else(|| "0x".to_string()),
                block_height: u64_at(&block_height, idx).unwrap_or_default() as i64,
                receipt_type: u8_at(&receipt_type, idx).unwrap_or_default() as i64,
                data: hex_at(&data, idx),
                rb: bigint_at(&rb, idx),
                val: bigint_at(&val, idx),
                sub_id: hex_at(&sub_id, idx),
                amount: bigint_at(&amount, idx),
                asset_id: hex_at(&asset_id, idx),
                to: hex_at(&to, idx),
                to_address: hex_at(&to_address, idx),
            });
        }
    }
    out
}

fn blocks_from_arrow(batches: &[ArrowBatch]) -> Vec<Block> {
    let mut out = Vec::new();
    for batch in batches {
        let id = batch.column::<BinaryArray<i32>>("id").ok();
        let height = batch.column::<UInt64Array>("height").ok();
        let time = batch.column::<Int64Array>("time").ok();

        for idx in 0..batch.chunk.len() {
            out.push(Block {
                id: hex_at(&id, idx).unwrap_or_else(|| "0x".to_string()),
                height: u64_at(&height, idx).unwrap_or_default() as i64,
                time: i64_at(&time, idx).unwrap_or_default(),
            });
        }
    }
    out
}

pub(crate) fn convert_response(res: ArrowResponse) -> QueryResponse {
    QueryResponse {
        archive_height: res.archive_height.map(|h| h as i64),
        next_block: res.next_block as i64,
        total_execution_time: res.total_execution_time as i64,
        data: QueryResponseData {
            receipts: receipts_from_arrow(&res.data.receipts),
            blocks: Some(blocks_from_arrow(&res.data.blocks)),
        },
    }
}
