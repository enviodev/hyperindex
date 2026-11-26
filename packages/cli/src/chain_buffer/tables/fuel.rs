//! Fuel tables: receipts and blocks, what fills them from a source's rows,
//! and how their cells read back as the fields handlers select. Fuel has no
//! transactions table of its own: an item carries its transaction id.

use anyhow::{Context, Result};
use strum::VariantArray;

use super::table::{make_key, ChunkBuilder, ColumnKind, RowRef, Schema, MAX_POSITION};
use crate::chain_buffer::deliver::{build_columns, cells, utf8, Column, Columns};

pub(crate) mod receipt_column {
    pub(crate) const RECEIPT_TYPE: usize = 0;
    /// The emitting contract's id, as bytes.
    pub(crate) const ROOT_CONTRACT_ID: usize = 1;
    pub(crate) const TX_ID: usize = 2;
    pub(crate) const RB: usize = 3;
    pub(crate) const DATA: usize = 4;
    pub(crate) const VAL: usize = 5;
    pub(crate) const SUB_ID: usize = 6;
    pub(crate) const AMOUNT: usize = 7;
    pub(crate) const ASSET_ID: usize = 8;
    pub(crate) const TO: usize = 9;
    pub(crate) const TO_ADDRESS: usize = 10;
}

/// Receipts keyed by block height and receipt index. The hex-text fields are
/// kept as the source spelled them.
pub(crate) fn receipts_schema() -> Schema {
    Schema {
        columns: vec![
            ColumnKind::U32,
            ColumnKind::Var,
            ColumnKind::Var,
            ColumnKind::U64,
            ColumnKind::Var,
            ColumnKind::U64,
            ColumnKind::Var,
            ColumnKind::U64,
            ColumnKind::Var,
            ColumnKind::Var,
            ColumnKind::Var,
        ],
        has_tiebreak: false,
        has_fetched: false,
    }
}

/// A receipt as the source returns it.
pub(crate) struct ReceiptInput<'a> {
    pub(crate) block_height: u64,
    pub(crate) receipt_index: u64,
    pub(crate) receipt_type: u8,
    pub(crate) root_contract_id: &'a [u8],
    pub(crate) tx_id: &'a str,
    pub(crate) rb: Option<u64>,
    pub(crate) data: Option<&'a [u8]>,
    pub(crate) val: Option<u64>,
    pub(crate) sub_id: Option<&'a str>,
    pub(crate) amount: Option<u64>,
    pub(crate) asset_id: Option<&'a str>,
    pub(crate) to: Option<&'a str>,
    pub(crate) to_address: Option<&'a str>,
}

pub(crate) fn push_receipt(builder: &mut ChunkBuilder, receipt: &ReceiptInput) -> Result<()> {
    use receipt_column::*;
    anyhow::ensure!(
        receipt.receipt_index <= MAX_POSITION,
        "receipt.receiptIndex {} is past what the buffer keys hold",
        receipt.receipt_index
    );
    builder.push_row(make_key(receipt.block_height, receipt.receipt_index), 0, 0);
    builder.set_u64(RECEIPT_TYPE, receipt.receipt_type as u64);
    builder.set_bytes(ROOT_CONTRACT_ID, receipt.root_contract_id);
    builder.set_bytes(TX_ID, receipt.tx_id.as_bytes());
    builder.set_optional_u64(RB, receipt.rb);
    builder.set_optional_bytes(DATA, receipt.data);
    builder.set_optional_u64(VAL, receipt.val);
    builder.set_optional_bytes(SUB_ID, receipt.sub_id.map(str::as_bytes));
    builder.set_optional_u64(AMOUNT, receipt.amount);
    builder.set_optional_bytes(ASSET_ID, receipt.asset_id.map(str::as_bytes));
    builder.set_optional_bytes(TO, receipt.to.map(str::as_bytes));
    builder.set_optional_bytes(TO_ADDRESS, receipt.to_address.map(str::as_bytes));
    Ok(())
}

/// A stored receipt's fields as matching and decoding read them.
pub(crate) struct ReceiptView<'a> {
    pub(crate) block_height: u64,
    pub(crate) receipt_index: u64,
    pub(crate) receipt_type: u8,
    pub(crate) root_contract_id: &'a [u8],
    pub(crate) tx_id: &'a [u8],
    pub(crate) rb: Option<u64>,
    pub(crate) data: Option<&'a [u8]>,
    pub(crate) val: Option<u64>,
    pub(crate) sub_id: Option<&'a [u8]>,
    pub(crate) amount: Option<u64>,
    pub(crate) asset_id: Option<&'a [u8]>,
    pub(crate) to: Option<&'a [u8]>,
    pub(crate) to_address: Option<&'a [u8]>,
}

impl<'a> ReceiptView<'a> {
    pub(crate) fn of_row(row: &RowRef<'a>) -> Option<ReceiptView<'a>> {
        use receipt_column::*;
        let row = *row;
        Some(ReceiptView {
            block_height: row.block_number(),
            receipt_index: row.position(),
            receipt_type: row.u64_at(RECEIPT_TYPE)? as u8,
            root_contract_id: row.bytes_at(ROOT_CONTRACT_ID)?,
            tx_id: row.bytes_at(TX_ID)?,
            rb: row.u64_at(RB),
            data: row.bytes_at(DATA),
            val: row.u64_at(VAL),
            sub_id: row.bytes_at(SUB_ID),
            amount: row.u64_at(AMOUNT),
            asset_id: row.bytes_at(ASSET_ID),
            to: row.bytes_at(TO),
            to_address: row.bytes_at(TO_ADDRESS),
        })
    }

    pub(crate) fn src_address(&self) -> String {
        crate::hex::to_hex(self.root_contract_id)
    }

    pub(crate) fn tx_id(&self) -> String {
        utf8(self.tx_id)
    }
}

/// Block field codes shared with ReScript by ordinal: the order mirrors
/// `Fuel.res` `blockFields`, and the ordinal is the field's bit in a
/// selection mask and its column in the blocks table.
#[derive(Clone, Copy, PartialEq, Eq, Debug, VariantArray)]
#[repr(i32)]
pub enum FuelBlockField {
    Height = 0,
    Id = 1,
    Time = 2,
}

impl FuelBlockField {
    pub fn name(self) -> &'static str {
        match self {
            FuelBlockField::Height => "height",
            FuelBlockField::Id => "id",
            FuelBlockField::Time => "time",
        }
    }
}

pub(crate) fn blocks_schema() -> Schema {
    Schema {
        columns: vec![ColumnKind::U64, ColumnKind::Var, ColumnKind::U64],
        has_tiebreak: false,
        has_fetched: true,
    }
}

pub(crate) const BLOCK_HASH_COLUMN: usize = FuelBlockField::Id as usize;
const BLOCK_TIME_COLUMN: usize = FuelBlockField::Time as usize;
const EVERY_BLOCK_FIELD: u64 = 0b111;

/// Appends a block. `id` is its hash; a block a source saw only by height
/// and hash leaves `time` out.
pub(crate) fn push_block(
    builder: &mut ChunkBuilder,
    height: u64,
    id: Option<&[u8]>,
    time: Option<i64>,
) {
    builder.push_row(make_key(height, 0), 0, EVERY_BLOCK_FIELD);
    builder.set_optional_bytes(BLOCK_HASH_COLUMN, id);
    builder.set_optional_u64(BLOCK_TIME_COLUMN, time.map(|time| time as u64));
}

pub(crate) fn block_timestamp(row: &RowRef) -> Option<i64> {
    row.u64_at(BLOCK_TIME_COLUMN).map(|time| time as i64)
}

/// A JS block id back to its bytes.
pub(crate) fn hash_bytes(text: &str) -> Result<Vec<u8>> {
    crate::hex::decode_prefixed(text, "block.id")
}

fn block_column(
    field: FuelBlockField,
    rows: &[Option<RowRef>],
    numbers: &[u64],
    masks: &[u64],
) -> Result<Column> {
    let bit = 1u64 << field as u32;
    let column = field as usize;
    Ok(match field {
        FuelBlockField::Height => Column::I64(
            numbers
                .iter()
                .zip(masks)
                .map(|(number, mask)| (mask & bit != 0).then_some(*number as i64))
                .collect(),
        ),
        FuelBlockField::Id => Column::Str(cells(rows, masks, bit, |row| {
            Ok(row.bytes_at(column).map(crate::hex::to_hex))
        })?),
        FuelBlockField::Time => Column::I64(cells(rows, masks, bit, |row| {
            Ok(row.u64_at(column).map(|time| time as i64))
        })?),
    })
}

/// The selected fields of the blocks at `numbers`, each row decoding the
/// fields its own mask sets.
pub(crate) fn block_columns(
    rows: &[Option<RowRef>],
    numbers: &[u64],
    masks: &[u64],
) -> Result<Columns> {
    build_columns(
        FuelBlockField::VARIANTS,
        masks,
        rows.len(),
        |field| field as u32,
        |field| field.name(),
        |field| block_column(field, rows, numbers, masks),
    )
    .context("decoding Fuel blocks")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chain_buffer::tables::table::Table;

    #[test]
    fn a_receipt_reads_back_as_stored() {
        let mut table = Table::new(receipts_schema());
        let mut builder = table.builder();
        push_receipt(
            &mut builder,
            &ReceiptInput {
                block_height: 42,
                receipt_index: 3,
                receipt_type: 6,
                root_contract_id: &[0xab; 32],
                tx_id: "0x01",
                rb: Some(7),
                data: Some(&[1, 2]),
                val: None,
                sub_id: None,
                amount: None,
                asset_id: None,
                to: None,
                to_address: None,
            },
        )
        .unwrap();
        table.merge(builder.finish());
        let row = table.find(make_key(42, 3), 0).unwrap();
        let view = ReceiptView::of_row(&row).unwrap();
        assert_eq!(
            (
                view.block_height,
                view.receipt_index,
                view.receipt_type,
                view.src_address(),
                view.tx_id(),
                view.rb,
                view.data,
                view.val,
            ),
            (
                42,
                3,
                6,
                format!("0x{}", "ab".repeat(32)),
                "0x01".to_string(),
                Some(7),
                Some(&[1u8, 2][..]),
                None,
            )
        );
    }
}
