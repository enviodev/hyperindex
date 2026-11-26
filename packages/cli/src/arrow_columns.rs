//! Typed access to the columns of a HyperSync Arrow table, by the names and
//! types the server serves them under.
//!
//! A column the response doesn't carry reads as null in every row, the way a
//! deselected field does. A column of another type is an error.

use anyhow::{Context, Result};
use arrow::array::{Array, BinaryArray, RecordBatch, UInt64Array};

pub(crate) fn column<'a, T: Array + 'static>(
    batch: &'a RecordBatch,
    name: &str,
) -> Result<Option<&'a T>> {
    match batch.column_by_name(name) {
        None => Ok(None),
        Some(column) => column
            .as_any()
            .downcast_ref::<T>()
            .map(Some)
            .with_context(|| {
                format!(
                    "column {name}: expected {}, found {}",
                    std::any::type_name::<T>(),
                    column.data_type()
                )
            }),
    }
}

pub(crate) fn u64_at(column: Option<&UInt64Array>, row: usize) -> Option<u64> {
    primitive_at(column, row)
}

pub(crate) fn primitive_at<T: arrow::datatypes::ArrowPrimitiveType>(
    column: Option<&arrow::array::PrimitiveArray<T>>,
    row: usize,
) -> Option<T::Native> {
    column
        .filter(|column| column.is_valid(row))
        .map(|column| column.value(row))
}

pub(crate) fn bytes_at(column: Option<&BinaryArray>, row: usize) -> Option<&[u8]> {
    column
        .filter(|column| column.is_valid(row))
        .map(|column| column.value(row))
}

/// The value at `row` when it's exactly `length` bytes, as hashes and
/// addresses must be.
pub(crate) fn fixed_bytes_at<'a>(
    column: Option<&'a BinaryArray>,
    row: usize,
    length: usize,
    field: &str,
) -> Result<Option<&'a [u8]>> {
    match bytes_at(column, row) {
        Some(bytes) if bytes.len() != length => {
            anyhow::bail!("{field} must be {length} bytes, got {}", bytes.len())
        }
        bytes => Ok(bytes),
    }
}
