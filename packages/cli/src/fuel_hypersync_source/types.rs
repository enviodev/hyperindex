//! HyperFuel's block and receipt tables, read in place: a row is a set of
//! borrows into the response's columns, so a receipt no registration keeps
//! costs nothing to read.

use anyhow::{Context, Result};
use arrow::array::{BinaryArray, Int64Array, RecordBatch, UInt64Array, UInt8Array};

use crate::arrow_columns::{bytes_at, column, primitive_at, u64_at};

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

/// A value that has to fit an `i64`, as JS reads it.
fn i64_value(value: Option<u64>, name: &str) -> Result<Option<u64>> {
    value
        .map(|value| {
            i64::try_from(value).with_context(|| format!("{name} overflow"))?;
            Ok(value)
        })
        .transpose()
}

/// `value`, or `None` with `name` noted missing.
fn required<T>(value: Option<T>, name: &str, missing: &mut Vec<String>) -> Option<T> {
    if value.is_none() {
        missing.push(name.to_string());
    }
    value
}

pub(crate) struct BlockColumns<'a> {
    id: Option<&'a BinaryArray>,
    height: Option<&'a UInt64Array>,
    time: Option<&'a Int64Array>,
}

pub(crate) struct BlockRow<'a> {
    pub(crate) id: &'a [u8],
    pub(crate) height: u64,
    pub(crate) time: i64,
}

impl<'a> BlockColumns<'a> {
    pub(crate) fn of(batch: &'a RecordBatch) -> Result<Self> {
        Ok(BlockColumns {
            id: column(batch, "id")?,
            height: column(batch, "height")?,
            time: column(batch, "time")?,
        })
    }

    pub(crate) fn row(&self, row: usize) -> Result<BlockRow<'a>, ConvertError> {
        let mut missing = Vec::new();
        let id = required(bytes_at(self.id, row), "block.id", &mut missing);
        let height = required(
            i64_value(u64_at(self.height, row), "block.height")?,
            "block.height",
            &mut missing,
        );
        let time = required(primitive_at(self.time, row), "block.time", &mut missing);
        match (id, height, time) {
            (Some(id), Some(height), Some(time)) => Ok(BlockRow { id, height, time }),
            _ => Err(ConvertError::MissingFields(missing)),
        }
    }
}

pub(crate) struct ReceiptColumns<'a> {
    receipt_index: Option<&'a UInt64Array>,
    root_contract_id: Option<&'a BinaryArray>,
    tx_id: Option<&'a BinaryArray>,
    block_height: Option<&'a UInt64Array>,
    receipt_type: Option<&'a UInt8Array>,
    data: Option<&'a BinaryArray>,
    rb: Option<&'a UInt64Array>,
    val: Option<&'a UInt64Array>,
    sub_id: Option<&'a BinaryArray>,
    amount: Option<&'a UInt64Array>,
    asset_id: Option<&'a BinaryArray>,
    to: Option<&'a BinaryArray>,
    to_address: Option<&'a BinaryArray>,
}

/// One receipt's fields, borrowed from the columns. The ids are raw bytes.
pub(crate) struct ReceiptRow<'a> {
    pub(crate) receipt_index: u64,
    pub(crate) root_contract_id: Option<&'a [u8]>,
    pub(crate) tx_id: &'a [u8],
    pub(crate) block_height: u64,
    pub(crate) receipt_type: u8,
    pub(crate) data: Option<&'a [u8]>,
    pub(crate) rb: Option<u64>,
    pub(crate) val: Option<u64>,
    pub(crate) sub_id: Option<&'a [u8]>,
    pub(crate) amount: Option<u64>,
    pub(crate) asset_id: Option<&'a [u8]>,
    pub(crate) to: Option<&'a [u8]>,
    pub(crate) to_address: Option<&'a [u8]>,
}

impl<'a> ReceiptColumns<'a> {
    pub(crate) fn of(batch: &'a RecordBatch) -> Result<Self> {
        Ok(ReceiptColumns {
            receipt_index: column(batch, "receipt_index")?,
            root_contract_id: column(batch, "root_contract_id")?,
            tx_id: column(batch, "tx_id")?,
            block_height: column(batch, "block_height")?,
            receipt_type: column(batch, "receipt_type")?,
            data: column(batch, "data")?,
            rb: column(batch, "rb")?,
            val: column(batch, "val")?,
            sub_id: column(batch, "sub_id")?,
            amount: column(batch, "amount")?,
            asset_id: column(batch, "asset_id")?,
            to: column(batch, "to")?,
            to_address: column(batch, "to_address")?,
        })
    }

    /// The receipt at `row`; one without a field every receipt has fails the
    /// page, kept or not.
    pub(crate) fn row(&self, row: usize) -> Result<ReceiptRow<'a>, ConvertError> {
        let mut missing = Vec::new();
        let receipt_index = required(
            i64_value(u64_at(self.receipt_index, row), "receipt.receiptIndex")?,
            "receipt.receiptIndex",
            &mut missing,
        );
        let tx_id = required(bytes_at(self.tx_id, row), "receipt.txId", &mut missing);
        let block_height = required(
            i64_value(u64_at(self.block_height, row), "receipt.blockHeight")?,
            "receipt.blockHeight",
            &mut missing,
        );
        let receipt_type = required(
            primitive_at(self.receipt_type, row),
            "receipt.receiptType",
            &mut missing,
        );
        let (Some(receipt_index), Some(tx_id), Some(block_height), Some(receipt_type)) =
            (receipt_index, tx_id, block_height, receipt_type)
        else {
            return Err(ConvertError::MissingFields(missing));
        };
        Ok(ReceiptRow {
            receipt_index,
            root_contract_id: bytes_at(self.root_contract_id, row),
            tx_id,
            block_height,
            receipt_type,
            data: bytes_at(self.data, row),
            rb: u64_at(self.rb, row),
            val: u64_at(self.val, row),
            sub_id: bytes_at(self.sub_id, row),
            amount: u64_at(self.amount, row),
            asset_id: bytes_at(self.asset_id, row),
            to: bytes_at(self.to, row),
            to_address: bytes_at(self.to_address, row),
        })
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use arrow::array::ArrayRef;

    use super::*;

    fn batch(columns: Vec<(&str, ArrayRef)>) -> RecordBatch {
        RecordBatch::try_from_iter(columns).unwrap()
    }

    fn binary(values: Vec<Option<&[u8]>>) -> ArrayRef {
        Arc::new(BinaryArray::from(values))
    }

    fn u64s(values: Vec<Option<u64>>) -> ArrayRef {
        Arc::new(UInt64Array::from(values))
    }

    fn u8s(values: Vec<Option<u8>>) -> ArrayRef {
        Arc::new(UInt8Array::from(values))
    }

    fn i64s(values: Vec<Option<i64>>) -> ArrayRef {
        Arc::new(Int64Array::from(values))
    }

    fn receipt_rows(batch: &RecordBatch) -> Result<Vec<String>, ConvertError> {
        let columns = ReceiptColumns::of(batch)?;
        (0..batch.num_rows())
            .map(|row| {
                let receipt = columns.row(row)?;
                Ok(format!(
                    "{} {} {} {} {:?} {:?} {:?} {:?}",
                    receipt.receipt_index,
                    crate::hex::to_hex(receipt.tx_id),
                    receipt.block_height,
                    receipt.receipt_type,
                    receipt.root_contract_id.map(crate::hex::to_hex),
                    receipt.data,
                    receipt.rb,
                    receipt.val,
                ))
            })
            .collect()
    }

    fn missing(result: Result<Vec<String>, ConvertError>) -> Vec<String> {
        match result {
            Err(ConvertError::MissingFields(fields)) => fields,
            Err(ConvertError::Other(e)) => panic!("unexpected ConvertError::Other: {e:?}"),
            Ok(rows) => panic!("expected MissingFields, got {rows:?}"),
        }
    }

    #[test]
    fn reads_a_receipt_with_optional_columns_absent() {
        let receipts = batch(vec![
            ("receipt_index", u64s(vec![Some(1)])),
            ("tx_id", binary(vec![Some(&[0xab; 2])])),
            ("block_height", u64s(vec![Some(42)])),
            ("receipt_type", u8s(vec![Some(6)])),
            ("root_contract_id", binary(vec![Some(&[0xcd; 2])])),
            ("data", binary(vec![Some(&[0x01, 0x02])])),
            ("rb", u64s(vec![Some(7)])),
        ]);
        assert_eq!(
            receipt_rows(&receipts).unwrap(),
            vec!["1 0xabab 42 6 Some(\"0xcdcd\") Some([1, 2]) Some(7) None".to_string()]
        );
    }

    #[test]
    fn a_missing_required_receipt_column_is_a_missing_field() {
        let receipts = batch(vec![
            ("receipt_index", u64s(vec![Some(1)])),
            ("block_height", u64s(vec![Some(42)])),
            ("receipt_type", u8s(vec![Some(6)])),
        ]);
        assert_eq!(
            missing(receipt_rows(&receipts)),
            vec!["receipt.txId".to_string()]
        );
    }

    #[test]
    fn a_null_required_receipt_value_is_a_missing_field() {
        let receipts = batch(vec![
            ("receipt_index", u64s(vec![None])),
            ("tx_id", binary(vec![None])),
            ("block_height", u64s(vec![Some(42)])),
            ("receipt_type", u8s(vec![Some(6)])),
        ]);
        assert_eq!(
            missing(receipt_rows(&receipts)),
            vec![
                "receipt.receiptIndex".to_string(),
                "receipt.txId".to_string()
            ]
        );
    }

    #[test]
    fn a_block_without_its_time_is_a_missing_field() {
        let blocks = batch(vec![
            ("id", binary(vec![Some(&[0xee; 32])])),
            ("height", u64s(vec![Some(42)])),
        ]);
        let result = BlockColumns::of(&blocks).unwrap().row(0).map(|_| ());
        assert!(
            matches!(&result, Err(ConvertError::MissingFields(fields)) if fields == &["block.time"]),
            "{result:?}"
        );
    }

    #[test]
    fn reads_a_block() {
        let blocks = batch(vec![
            ("id", binary(vec![Some(&[0xee; 2])])),
            ("height", u64s(vec![Some(42)])),
            ("time", i64s(vec![Some(1745179292)])),
        ]);
        let block = BlockColumns::of(&blocks).unwrap().row(0).unwrap();
        assert_eq!(
            (crate::hex::to_hex(block.id), block.height, block.time),
            ("0xeeee".to_string(), 42, 1745179292)
        );
    }
}
