use anyhow::{Context, Result};
use hyperfuel_client::ArrowBatch;
use napi::bindgen_prelude::BigInt;
use napi_derive::napi;
use polars_arrow::array::{BinaryArray, Int64Array, StaticArray, UInt64Array, UInt8Array};

use crate::hyperfuel_source::parse::ParsedResponse;

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
    pub blocks: Vec<Block>,
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

/// `MissingFields` is the shape the JS side recognizes (via the JSON payload
/// protocol shared with hypersync_source) and converts to
/// `UnexpectedMissingParams`; `Other` falls through to the generic napi error.
#[derive(Debug)]
pub(crate) enum ConvertError {
    MissingFields(Vec<String>),
    Other(anyhow::Error),
}

impl From<anyhow::Error> for ConvertError {
    fn from(e: anyhow::Error) -> Self {
        Self::Other(e)
    }
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

fn bigint_at(arr: &Option<&UInt64Array>, idx: usize) -> Option<BigInt> {
    u64_at(arr, idx).map(BigInt::from)
}

fn i64_field(arr: &Option<&UInt64Array>, idx: usize, name: &str) -> Result<Option<i64>> {
    u64_at(arr, idx)
        .map(|v| v.try_into().with_context(|| format!("{name} overflow")))
        .transpose()
}

fn receipts_from_arrow(batches: &[ArrowBatch]) -> Result<Vec<Receipt>, ConvertError> {
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
            let mut missing: Vec<String> = Vec::new();
            let receipt_index_val = i64_field(&receipt_index, idx, "receipt.receiptIndex")?
                .or_else(|| {
                    missing.push("receipt.receiptIndex".into());
                    None
                });
            let tx_id_val = hex_at(&tx_id, idx).or_else(|| {
                missing.push("receipt.txId".into());
                None
            });
            let block_height_val =
                i64_field(&block_height, idx, "receipt.blockHeight")?.or_else(|| {
                    missing.push("receipt.blockHeight".into());
                    None
                });
            let receipt_type_val = receipt_type.and_then(|a| a.get(idx)).or_else(|| {
                missing.push("receipt.receiptType".into());
                None
            });
            if !missing.is_empty() {
                return Err(ConvertError::MissingFields(missing));
            }

            out.push(Receipt {
                receipt_index: receipt_index_val.unwrap(),
                root_contract_id: hex_at(&root_contract_id, idx),
                tx_id: tx_id_val.unwrap(),
                block_height: block_height_val.unwrap(),
                receipt_type: receipt_type_val.unwrap() as i64,
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
    Ok(out)
}

fn blocks_from_arrow(batches: &[ArrowBatch]) -> Result<Vec<Block>, ConvertError> {
    let mut out = Vec::new();
    for batch in batches {
        let id = batch.column::<BinaryArray<i32>>("id").ok();
        let height = batch.column::<UInt64Array>("height").ok();
        let time = batch.column::<Int64Array>("time").ok();

        for idx in 0..batch.chunk.len() {
            let mut missing: Vec<String> = Vec::new();
            let id_val = hex_at(&id, idx).or_else(|| {
                missing.push("block.id".into());
                None
            });
            let height_val = i64_field(&height, idx, "block.height")?.or_else(|| {
                missing.push("block.height".into());
                None
            });
            let time_val = time.and_then(|a| a.get(idx)).or_else(|| {
                missing.push("block.time".into());
                None
            });
            if !missing.is_empty() {
                return Err(ConvertError::MissingFields(missing));
            }

            out.push(Block {
                id: id_val.unwrap(),
                height: height_val.unwrap(),
                time: time_val.unwrap(),
            });
        }
    }
    Ok(out)
}

pub(crate) fn convert_response(res: ParsedResponse) -> Result<QueryResponse, ConvertError> {
    Ok(QueryResponse {
        archive_height: res.archive_height,
        next_block: res
            .next_block
            .try_into()
            .context("convert next_block")
            .map_err(ConvertError::Other)?,
        total_execution_time: res
            .total_execution_time
            .try_into()
            .context("convert total_execution_time")
            .map_err(ConvertError::Other)?,
        data: QueryResponseData {
            receipts: receipts_from_arrow(&res.receipts)?,
            blocks: blocks_from_arrow(&res.blocks)?,
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use polars_arrow::array::Array;
    use polars_arrow::datatypes::{ArrowDataType, ArrowSchema, Field};
    use polars_arrow::record_batch::RecordBatchT;
    use std::sync::Arc;

    fn make_batch(fields: Vec<(Field, Box<dyn Array>)>) -> ArrowBatch {
        let (schema_fields, arrays): (Vec<_>, Vec<_>) = fields.into_iter().unzip();
        ArrowBatch {
            chunk: Arc::new(RecordBatchT::new(arrays)),
            schema: Arc::new(ArrowSchema::from(schema_fields)),
        }
    }

    fn binary_field(name: &str, values: Vec<Option<&[u8]>>) -> (Field, Box<dyn Array>) {
        (
            Field::new(name, ArrowDataType::Binary, true),
            Box::new(BinaryArray::<i32>::from_iter(values.into_iter())),
        )
    }

    fn u64_field(name: &str, values: Vec<Option<u64>>) -> (Field, Box<dyn Array>) {
        (
            Field::new(name, ArrowDataType::UInt64, true),
            Box::new(UInt64Array::from(values)),
        )
    }

    fn u8_field(name: &str, values: Vec<Option<u8>>) -> (Field, Box<dyn Array>) {
        (
            Field::new(name, ArrowDataType::UInt8, true),
            Box::new(UInt8Array::from(values)),
        )
    }

    fn i64_field(name: &str, values: Vec<Option<i64>>) -> (Field, Box<dyn Array>) {
        (
            Field::new(name, ArrowDataType::Int64, true),
            Box::new(Int64Array::from(values)),
        )
    }

    fn full_receipt_batch() -> ArrowBatch {
        make_batch(vec![
            u64_field("receipt_index", vec![Some(1)]),
            binary_field("tx_id", vec![Some(&[0xab; 32])]),
            u64_field("block_height", vec![Some(42)]),
            u8_field("receipt_type", vec![Some(6)]),
            binary_field("root_contract_id", vec![Some(&[0xcd; 32])]),
            binary_field("data", vec![Some(&[0x01, 0x02])]),
            u64_field("rb", vec![Some(7)]),
        ])
    }

    #[test]
    fn converts_receipts_with_optional_columns_absent() {
        let receipts = receipts_from_arrow(&[full_receipt_batch()]).unwrap();
        assert_eq!(receipts.len(), 1);
        let r = &receipts[0];
        assert_eq!(
            (
                r.receipt_index,
                r.tx_id.as_str(),
                r.block_height,
                r.receipt_type,
                r.root_contract_id.as_deref(),
                r.data.as_deref(),
                r.rb.as_ref().map(|b| b.get_u64().1),
                r.val.as_ref().map(|b| b.get_u64().1),
            ),
            (
                1,
                format!("0x{}", "ab".repeat(32)).as_str(),
                42,
                6,
                Some(format!("0x{}", "cd".repeat(32)).as_str()),
                Some("0x0102"),
                Some(7),
                None,
            )
        );
    }

    #[test]
    fn missing_required_receipt_column_is_typed_error() {
        // tx_id column not in the response at all
        let batch = make_batch(vec![
            u64_field("receipt_index", vec![Some(1)]),
            u64_field("block_height", vec![Some(42)]),
            u8_field("receipt_type", vec![Some(6)]),
        ]);
        match receipts_from_arrow(&[batch]) {
            Err(ConvertError::MissingFields(fields)) => {
                assert_eq!(fields, vec!["receipt.txId".to_string()])
            }
            Err(ConvertError::Other(e)) => panic!("unexpected ConvertError::Other: {e:?}"),
            Ok(_) => panic!("expected MissingFields, got Ok"),
        }
    }

    #[test]
    fn null_required_receipt_value_is_typed_error() {
        let batch = make_batch(vec![
            u64_field("receipt_index", vec![None]),
            binary_field("tx_id", vec![None]),
            u64_field("block_height", vec![Some(42)]),
            u8_field("receipt_type", vec![Some(6)]),
        ]);
        match receipts_from_arrow(&[batch]) {
            Err(ConvertError::MissingFields(fields)) => assert_eq!(
                fields,
                vec![
                    "receipt.receiptIndex".to_string(),
                    "receipt.txId".to_string()
                ]
            ),
            Err(ConvertError::Other(e)) => panic!("unexpected ConvertError::Other: {e:?}"),
            Ok(_) => panic!("expected MissingFields, got Ok"),
        }
    }

    #[test]
    fn missing_block_time_is_typed_error() {
        let batch = make_batch(vec![
            binary_field("id", vec![Some(&[0xee; 32])]),
            u64_field("height", vec![Some(42)]),
        ]);
        match blocks_from_arrow(&[batch]) {
            Err(ConvertError::MissingFields(fields)) => {
                assert_eq!(fields, vec!["block.time".to_string()])
            }
            Err(ConvertError::Other(e)) => panic!("unexpected ConvertError::Other: {e:?}"),
            Ok(_) => panic!("expected MissingFields, got Ok"),
        }
    }

    #[test]
    fn converts_blocks() {
        let batch = make_batch(vec![
            binary_field("id", vec![Some(&[0xee; 32])]),
            u64_field("height", vec![Some(42)]),
            i64_field("time", vec![Some(1745179292)]),
        ]);
        let blocks = blocks_from_arrow(&[batch]).unwrap();
        assert_eq!(blocks.len(), 1);
        assert_eq!(
            (blocks[0].id.as_str(), blocks[0].height, blocks[0].time),
            (format!("0x{}", "ee".repeat(32)).as_str(), 42, 1745179292i64)
        );
    }

    #[test]
    fn empty_batches_convert_to_empty() {
        assert_eq!(receipts_from_arrow(&[]).unwrap().len(), 0);
        assert_eq!(blocks_from_arrow(&[]).unwrap().len(), 0);
    }
}
