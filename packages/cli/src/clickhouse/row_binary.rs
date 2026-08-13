//! RowBinary encoding of columnar input.
//!
//! RowBinary is row-major, so the encoder walks the columns once per row. Values
//! arrive columnar because that is what crosses the napi boundary cheaply: one
//! typed array or one concatenated string per column, instead of a JS object per
//! row.

use anyhow::{anyhow, bail, Context, Result};

use super::ch_type::ChType;

/// One column's values for a batch, already owned by Rust.
#[derive(Debug)]
pub enum ColumnValues {
    F64(Vec<f64>),
    U64(Vec<u64>),
    I64(Vec<i64>),
    /// Concatenated values plus each value's byte range in it.
    Text {
        data: String,
        spans: Vec<(u32, u32)>,
    },
}

impl ColumnValues {
    /// The wire kind these values arrived as, for checking against the column's
    /// ClickHouse type.
    pub fn kind(&self) -> super::ch_type::ColumnKind {
        use super::ch_type::ColumnKind;
        match self {
            ColumnValues::F64(_) => ColumnKind::F64,
            ColumnValues::U64(_) => ColumnKind::U64,
            ColumnValues::I64(_) => ColumnKind::I64,
            ColumnValues::Text { .. } => ColumnKind::Text,
        }
    }

    pub fn len(&self) -> usize {
        match self {
            ColumnValues::F64(v) => v.len(),
            ColumnValues::U64(v) => v.len(),
            ColumnValues::I64(v) => v.len(),
            ColumnValues::Text { spans, .. } => spans.len(),
        }
    }

    fn text_at(&self, row: usize) -> Result<&str> {
        match self {
            ColumnValues::Text { data, spans } => {
                let (start, end) = spans[row];
                Ok(&data[start as usize..end as usize])
            }
            other => bail!("expected a text column, got {other:?}"),
        }
    }
}

#[derive(Debug)]
pub struct Column {
    pub name: String,
    pub ch_type: ChType,
    pub values: ColumnValues,
    /// `1` marks a NULL. Empty when the column has none.
    pub nulls: Vec<u8>,
}

impl Column {
    fn is_null(&self, row: usize) -> bool {
        self.nulls.get(row).copied().unwrap_or(0) != 0
    }
}

/// Splits a concatenated column into per-value byte spans using each value's
/// UTF-16 code-unit length, which is what a JS string reports as `.length`.
///
/// The scan is over UTF-8 bytes, so it cannot index by code unit directly:
/// a character outside the BMP is two UTF-16 units and up to four UTF-8 bytes.
pub fn spans_from_utf16_lengths(data: &str, lengths: &[u32]) -> Result<Vec<(u32, u32)>> {
    let mut spans = Vec::with_capacity(lengths.len());
    let bytes = data.as_bytes();
    let mut offset = 0usize;
    for (row, &len) in lengths.iter().enumerate() {
        let start = offset;
        let mut remaining = len as usize;
        while remaining > 0 {
            if offset >= bytes.len() {
                bail!(
                    "column text ran out at row {row}: expected {len} more UTF-16 units, \
                     buffer is {} bytes",
                    bytes.len()
                );
            }
            let b = bytes[offset];
            // Leading-byte pattern gives the character's UTF-8 width; only a
            // 4-byte sequence is a surrogate pair, i.e. two UTF-16 units.
            let (width, units) = if b < 0x80 {
                (1, 1)
            } else if b < 0xE0 {
                (2, 1)
            } else if b < 0xF0 {
                (3, 1)
            } else {
                (4, 2)
            };
            if units > remaining {
                bail!("column text row {row} splits a surrogate pair");
            }
            offset += width;
            remaining -= units;
        }
        spans.push((start as u32, offset as u32));
    }
    if offset != bytes.len() {
        bail!(
            "column text has {} trailing bytes after {} rows",
            bytes.len() - offset,
            lengths.len()
        );
    }
    Ok(spans)
}

fn put_varint(out: &mut Vec<u8>, mut value: u64) {
    loop {
        let mut byte = (value & 0x7F) as u8;
        value >>= 7;
        if value != 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if value == 0 {
            break;
        }
    }
}

fn put_string(out: &mut Vec<u8>, value: &str) {
    put_varint(out, value.len() as u64);
    out.extend_from_slice(value.as_bytes());
}

/// Parses a decimal literal (`-12.34`, `1e3`, `0x…` excluded) into the scaled
/// integer ClickHouse stores for `Decimal(P, S)`.
fn decimal_to_i128(text: &str, scale: u32) -> Result<i128> {
    let text = text.trim();
    if text.is_empty() {
        return Ok(0);
    }
    // bignumber.js renders large or tiny magnitudes in exponential form.
    let (mantissa, exponent) = match text.find(['e', 'E']) {
        Some(i) => (&text[..i], text[i + 1..].parse::<i32>()?),
        None => (text, 0),
    };
    let (negative, mantissa) = match mantissa.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, mantissa.strip_prefix('+').unwrap_or(mantissa)),
    };
    let (int_part, frac_part) = match mantissa.split_once('.') {
        Some((i, f)) => (i, f),
        None => (mantissa, ""),
    };
    if int_part.is_empty() && frac_part.is_empty() {
        bail!("`{text}` is not a decimal");
    }
    let mut digits = String::with_capacity(int_part.len() + frac_part.len());
    digits.push_str(int_part);
    digits.push_str(frac_part);
    if !digits.bytes().all(|b| b.is_ascii_digit()) {
        bail!("`{text}` is not a decimal");
    }
    // Exponent shifts the point; `scale` then fixes how many fractional digits
    // the stored integer keeps.
    let shift = scale as i32 + exponent - frac_part.len() as i32;
    // An all-zero mantissa trims to the empty string, which `parse` rejects.
    let trimmed = digits.trim_start_matches('0');
    let mut value = if trimmed.is_empty() {
        0i128
    } else {
        trimmed
            .parse::<i128>()
            .map_err(|_| anyhow!("decimal `{text}` overflows Int128"))?
    };
    match shift.cmp(&0) {
        std::cmp::Ordering::Greater => {
            for _ in 0..shift {
                value = value
                    .checked_mul(10)
                    .context("decimal overflows the column's precision")?;
            }
        }
        std::cmp::Ordering::Less => {
            // Truncates toward zero, matching ClickHouse's own cast.
            for _ in 0..-shift {
                value /= 10;
            }
        }
        std::cmp::Ordering::Equal => {}
    }
    Ok(if negative { -value } else { value })
}

fn put_int_raw(out: &mut Vec<u8>, value: i128, bytes: usize) {
    let le = value.to_le_bytes();
    out.extend_from_slice(&le[..bytes.min(16)]);
    if bytes > 16 {
        // Int256/Decimal256: sign-extend past the 128-bit value we carry.
        let fill = if value < 0 { 0xFF } else { 0x00 };
        out.extend(std::iter::repeat_n(fill, bytes - 16));
    }
}

/// What the column accepts. RowBinary is just the raw integer, so nothing on the
/// server side rejects an out-of-range value: it wraps into whatever the bytes
/// happen to mean. The JSONEachRow path this replaced had ClickHouse do the
/// check, so the encoder has to do it here or an `Int!` set to 3e9 lands as a
/// negative number.
fn int_bounds(ch_type: &ChType) -> Result<(i128, i128)> {
    Ok(match ch_type {
        ChType::Int8 => (i8::MIN as i128, i8::MAX as i128),
        ChType::Int16 => (i16::MIN as i128, i16::MAX as i128),
        ChType::Int32 => (i32::MIN as i128, i32::MAX as i128),
        ChType::Int64 => (i64::MIN as i128, i64::MAX as i128),
        ChType::Int128 => (i128::MIN, i128::MAX),
        ChType::UInt8 | ChType::Bool => (0, u8::MAX as i128),
        ChType::UInt16 | ChType::Date => (0, u16::MAX as i128),
        ChType::UInt32 | ChType::DateTime => (0, u32::MAX as i128),
        ChType::UInt64 => (0, u64::MAX as i128),
        // The wire value is 128 bits, so that is the widest we can carry.
        ChType::UInt128 => (0, i128::MAX),
        ChType::Date32 => (i32::MIN as i128, i32::MAX as i128),
        ChType::DateTime64 { .. } => (i64::MIN as i128, i64::MAX as i128),
        // A Decimal's precision, not its byte width, is what it accepts.
        ChType::Decimal { precision, .. } => {
            let limit = 10i128
                .checked_pow(*precision)
                .context("decimal precision is too wide to represent")?
                - 1;
            (-limit, limit)
        }
        ChType::Enum { bytes, .. } => {
            if *bytes == 1 {
                (i8::MIN as i128, i8::MAX as i128)
            } else {
                (i16::MIN as i128, i16::MAX as i128)
            }
        }
        other => bail!("{other:?} is not an integer column"),
    })
}

fn put_int(out: &mut Vec<u8>, value: i128, ch_type: &ChType) -> Result<()> {
    let (min, max) = int_bounds(ch_type)?;
    if value < min || value > max {
        bail!("{value} is out of range for a {ch_type:?} column");
    }
    put_int_raw(out, value, fixed_width(ch_type)?);
    Ok(())
}

fn encode_json_value(out: &mut Vec<u8>, ch_type: &ChType, value: &serde_json::Value) -> Result<()> {
    use serde_json::Value;
    match ch_type {
        ChType::Nullable(inner) => {
            if value.is_null() {
                out.push(1);
            } else {
                out.push(0);
                encode_json_value(out, inner, value)?;
            }
        }
        ChType::Array(inner) => {
            let items = value
                .as_array()
                .context("expected a JSON array for an Array column")?;
            put_varint(out, items.len() as u64);
            for item in items {
                encode_json_value(out, inner, item)?;
            }
        }
        ChType::String => match value {
            Value::String(s) => put_string(out, s),
            other => put_string(out, &other.to_string()),
        },
        ChType::FixedString(width) => {
            let s = value.as_str().unwrap_or_default();
            let mut bytes = s.as_bytes().to_vec();
            bytes.resize(*width, 0);
            out.extend_from_slice(&bytes);
        }
        ChType::Bool => out.push(u8::from(value.as_bool().unwrap_or(false))),
        ChType::Decimal { scale, .. } => {
            let text = match value {
                Value::String(s) => s.clone(),
                other => other.to_string(),
            };
            put_int(out, decimal_to_i128(&text, *scale)?, ch_type)?;
        }
        ChType::Enum { .. } => {
            let name = value
                .as_str()
                .context("expected a string for an Enum column")?;
            let numeric = ch_type
                .enum_value(name)
                .with_context(|| format!("`{name}` is not a variant of the enum column"))?;
            put_int(out, numeric as i128, ch_type)?;
        }
        ChType::Float32 => {
            out.extend_from_slice(&(value.as_f64().unwrap_or(0.0) as f32).to_le_bytes())
        }
        ChType::Float64 => out.extend_from_slice(&value.as_f64().unwrap_or(0.0).to_le_bytes()),
        ChType::Int128 | ChType::UInt128 => {
            let text = match value {
                Value::String(s) => s.clone(),
                other => other.to_string(),
            };
            put_int(out, decimal_to_i128(&text, 0)?, ch_type)?;
        }
        _ => {
            let numeric = match value {
                Value::String(s) => decimal_to_i128(s, 0)?,
                other => other.as_f64().unwrap_or(0.0) as i128,
            };
            put_int(out, numeric, ch_type)?;
        }
    }
    Ok(())
}

/// Byte width of a fixed-size integer-ish type.
fn fixed_width(ch_type: &ChType) -> Result<usize> {
    Ok(match ch_type {
        ChType::Int8 | ChType::UInt8 | ChType::Bool => 1,
        ChType::Int16 | ChType::UInt16 | ChType::Date => 2,
        ChType::Int32 | ChType::UInt32 | ChType::DateTime | ChType::Date32 => 4,
        ChType::Int64 | ChType::UInt64 | ChType::DateTime64 { .. } => 8,
        ChType::Int128 | ChType::UInt128 => 16,
        ChType::Decimal { bytes, .. } | ChType::Enum { bytes, .. } => *bytes,
        ChType::Float32 => 4,
        ChType::Float64 => 8,
        other => bail!("{other:?} has no fixed width"),
    })
}

/// Writes the type's zero value — what ClickHouse would substitute for a column
/// omitted from a JSONEachRow row. A DELETE change carries only its id and
/// checkpoint, so every other column takes this path.
fn put_default(out: &mut Vec<u8>, ch_type: &ChType) -> Result<()> {
    match ch_type {
        ChType::Nullable(_) => out.push(1),
        ChType::Array(_) => put_varint(out, 0),
        ChType::String => put_varint(out, 0),
        ChType::FixedString(width) => out.extend(std::iter::repeat_n(0u8, *width)),
        ChType::Float32 => out.extend_from_slice(&0f32.to_le_bytes()),
        ChType::Float64 => out.extend_from_slice(&0f64.to_le_bytes()),
        // An Enum's default is its first variant, which is how ClickHouse fills
        // an omitted enum column.
        ChType::Enum { bytes, variants } => put_int_raw(out, variants[0].1 as i128, *bytes),
        other => out.extend(std::iter::repeat_n(0u8, fixed_width(other)?)),
    }
    Ok(())
}

fn encode_cell(out: &mut Vec<u8>, column: &Column, row: usize) -> Result<()> {
    let (ch_type, is_nullable) = match &column.ch_type {
        ChType::Nullable(inner) => {
            if column.is_null(row) {
                out.push(1);
                return Ok(());
            }
            out.push(0);
            (inner.as_ref(), true)
        }
        other => (other, false),
    };
    // A non-nullable column with a null marker means the JS side had no value
    // for a required field; the type's zero value is the only thing ClickHouse
    // would have accepted anyway.
    if !is_nullable && column.is_null(row) {
        return put_default(out, ch_type);
    }

    match (&column.values, ch_type) {
        (ColumnValues::F64(v), ChType::Bool) => out.push(u8::from(v[row] != 0.0)),
        (ColumnValues::F64(v), ChType::Float32) => {
            out.extend_from_slice(&(v[row] as f32).to_le_bytes())
        }
        (ColumnValues::F64(v), ChType::Float64) => out.extend_from_slice(&v[row].to_le_bytes()),
        (ColumnValues::F64(v), other) => {
            let value = v[row];
            // A non-integral float would truncate silently; the column has no
            // fractional part to put it in.
            if value.fract() != 0.0 || !value.is_finite() {
                bail!("{value} is not an integer, which a {other:?} column requires");
            }
            put_int(out, value as i128, other)?
        }
        (ColumnValues::U64(v), ChType::Float64) => {
            out.extend_from_slice(&(v[row] as f64).to_le_bytes())
        }
        (ColumnValues::U64(v), other) => put_int(out, v[row] as i128, other)?,
        (ColumnValues::I64(v), other) => put_int(out, v[row] as i128, other)?,
        (ColumnValues::Text { .. }, ChType::Array(_)) => {
            let text = column.values.text_at(row)?;
            let parsed: serde_json::Value = serde_json::from_str(text)
                .with_context(|| format!("column `{}` row {row} is not JSON", column.name))?;
            encode_json_value(out, ch_type, &parsed)?;
        }
        (ColumnValues::Text { .. }, ChType::String) => put_string(out, column.values.text_at(row)?),
        (ColumnValues::Text { .. }, ChType::FixedString(width)) => {
            let mut bytes = column.values.text_at(row)?.as_bytes().to_vec();
            bytes.resize(*width, 0);
            out.extend_from_slice(&bytes);
        }
        (ColumnValues::Text { .. }, ChType::Decimal { scale, .. }) => {
            let text = column.values.text_at(row)?;
            put_int(
                out,
                decimal_to_i128(text, *scale).with_context(|| {
                    format!("column `{}` row {row} is not a decimal", column.name)
                })?,
                ch_type,
            )?;
        }
        (ColumnValues::Text { .. }, ChType::Enum { .. }) => {
            let name = column.values.text_at(row)?;
            let numeric = ch_type.enum_value(name).with_context(|| {
                format!("`{name}` is not a variant of enum column `{}`", column.name)
            })?;
            put_int(out, numeric as i128, ch_type)?;
        }
        (ColumnValues::Text { .. }, other) => {
            let text = column.values.text_at(row)?;
            put_int(out, decimal_to_i128(text, 0)?, other)?;
        }
    }
    Ok(())
}

/// A batch encoded as a RowBinary body, with the byte offset of every row start
/// so a failed insert can be split at a row boundary and retried in halves.
#[derive(Debug)]
pub struct EncodedRows {
    pub body: Vec<u8>,
    pub row_offsets: Vec<u32>,
}

impl EncodedRows {
    pub fn rows(&self) -> usize {
        self.row_offsets.len()
    }

    /// The bytes of rows `start..end`.
    pub fn slice(&self, start: usize, end: usize) -> &[u8] {
        let from = self.row_offsets[start] as usize;
        let to = match self.row_offsets.get(end) {
            Some(offset) => *offset as usize,
            None => self.body.len(),
        };
        &self.body[from..to]
    }
}

/// Encodes `columns` (in target-table order) into a RowBinary body.
pub fn encode(columns: &[Column], rows: usize) -> Result<EncodedRows> {
    for column in columns {
        if column.values.len() != rows {
            bail!(
                "column `{}` has {} values but the batch has {rows} rows",
                column.name,
                column.values.len()
            );
        }
    }
    // Two thirds of the JSONEachRow size is a good enough first guess; growing
    // once beats re-allocating per row.
    let mut body = Vec::with_capacity(rows * columns.len() * 12);
    let mut row_offsets = Vec::with_capacity(rows);
    for row in 0..rows {
        row_offsets.push(body.len() as u32);
        for column in columns {
            encode_cell(&mut body, column, row)
                .with_context(|| format!("encoding column `{}` row {row}", column.name))?;
        }
    }
    Ok(EncodedRows { body, row_offsets })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clickhouse::ch_type;
    use pretty_assertions::assert_eq;

    fn text_column(name: &str, ty: &str, values: &[&str]) -> Column {
        let data: String = values.concat();
        let lengths: Vec<u32> = values
            .iter()
            .map(|v| v.chars().map(char::len_utf16).sum::<usize>() as u32)
            .collect();
        Column {
            name: name.to_string(),
            ch_type: ch_type::parse(ty).unwrap(),
            values: ColumnValues::Text {
                spans: spans_from_utf16_lengths(&data, &lengths).unwrap(),
                data,
            },
            nulls: Vec::new(),
        }
    }

    fn f64_column(name: &str, ty: &str, values: &[f64]) -> Column {
        Column {
            name: name.to_string(),
            ch_type: ch_type::parse(ty).unwrap(),
            values: ColumnValues::F64(values.to_vec()),
            nulls: Vec::new(),
        }
    }

    #[test]
    fn spans_handle_multi_byte_and_surrogate_pairs() {
        // "é" is 1 UTF-16 unit / 2 UTF-8 bytes, "😀" is 2 units / 4 bytes.
        let data = "aé😀b".to_string();
        let spans = spans_from_utf16_lengths(&data, &[1, 1, 2, 1]).unwrap();
        let values: Vec<&str> = spans
            .iter()
            .map(|(s, e)| &data[*s as usize..*e as usize])
            .collect();
        assert_eq!(values, vec!["a", "é", "😀", "b"]);
    }

    #[test]
    fn spans_reject_a_length_that_overruns_the_buffer() {
        assert!(spans_from_utf16_lengths("ab", &[3]).is_err());
    }

    #[test]
    fn spans_reject_trailing_bytes() {
        assert!(spans_from_utf16_lengths("abc", &[1]).is_err());
    }

    #[test]
    fn encodes_a_string_with_a_varint_length() {
        let encoded = encode(&[text_column("id", "String", &["abc"])], 1).unwrap();
        assert_eq!(encoded.body, vec![3, b'a', b'b', b'c']);
    }

    #[test]
    fn encodes_a_long_string_length_as_multi_byte_varint() {
        let long = "x".repeat(300);
        let encoded = encode(&[text_column("id", "String", &[&long])], 1).unwrap();
        assert_eq!(&encoded.body[..2], &[0xAC, 0x02]);
        assert_eq!(encoded.body.len(), 302);
    }

    #[test]
    fn encodes_fixed_width_integers_little_endian() {
        let encoded = encode(
            &[
                f64_column("a", "Int32", &[-2.0]),
                f64_column("b", "UInt8", &[7.0]),
            ],
            1,
        )
        .unwrap();
        assert_eq!(encoded.body, vec![0xFE, 0xFF, 0xFF, 0xFF, 7]);
    }

    #[test]
    fn encodes_uint64_beyond_float_precision_exactly() {
        let column = Column {
            name: "checkpoint".to_string(),
            ch_type: ch_type::parse("UInt64").unwrap(),
            values: ColumnValues::U64(vec![u64::MAX - 1]),
            nulls: Vec::new(),
        };
        let encoded = encode(&[column], 1).unwrap();
        assert_eq!(encoded.body, (u64::MAX - 1).to_le_bytes().to_vec());
    }

    #[test]
    fn encodes_decimal_by_scaling_the_literal() {
        let encoded = encode(
            &[
                text_column("a", "Decimal(9, 2)", &["1.5"]),
                text_column("b", "Decimal(38, 0)", &["-42"]),
            ],
            1,
        )
        .unwrap();
        let mut expected = 150i32.to_le_bytes().to_vec();
        expected.extend_from_slice(&(-42i128).to_le_bytes());
        assert_eq!(encoded.body, expected);
    }

    #[test]
    fn encodes_decimal_in_exponential_notation() {
        let encoded = encode(&[text_column("a", "Decimal(18, 4)", &["1.5e3"])], 1).unwrap();
        assert_eq!(encoded.body, 15_000_000i64.to_le_bytes().to_vec());
    }

    #[test]
    fn truncates_a_decimal_below_the_column_scale() {
        let encoded = encode(&[text_column("a", "Decimal(9, 1)", &["1.29"])], 1).unwrap();
        assert_eq!(encoded.body, 12i32.to_le_bytes().to_vec());
    }

    #[test]
    fn encodes_an_enum_as_its_server_reported_value() {
        let encoded = encode(
            &[text_column(
                "envio_change",
                "Enum8('SET' = 1, 'DELETE' = 2)",
                &["DELETE"],
            )],
            1,
        )
        .unwrap();
        assert_eq!(encoded.body, vec![2]);
    }

    #[test]
    fn rejects_a_value_that_is_not_an_enum_variant() {
        let err = encode(&[text_column("e", "Enum8('SET' = 1)", &["NOPE"])], 1).unwrap_err();
        assert!(format!("{err:#}").contains("not a variant"));
    }

    #[test]
    fn encodes_nullable_with_a_leading_flag() {
        let mut column = text_column("s", "Nullable(String)", &["", "ab"]);
        column.nulls = vec![1, 0];
        let encoded = encode(&[column], 2).unwrap();
        assert_eq!(encoded.body, vec![1, 0, 2, b'a', b'b']);
    }

    #[test]
    fn encodes_an_array_from_json_text() {
        let encoded = encode(&[text_column("xs", "Array(UInt32)", &["[1,2,3]"])], 1).unwrap();
        let mut expected = vec![3];
        for v in [1u32, 2, 3] {
            expected.extend_from_slice(&v.to_le_bytes());
        }
        assert_eq!(encoded.body, expected);
    }

    #[test]
    fn encodes_an_array_of_decimal_strings() {
        let encoded = encode(
            &[text_column(
                "xs",
                "Array(Decimal(38, 0))",
                &["[\"10\",\"20\"]"],
            )],
            1,
        )
        .unwrap();
        let mut expected = vec![2];
        expected.extend_from_slice(&10i128.to_le_bytes());
        expected.extend_from_slice(&20i128.to_le_bytes());
        assert_eq!(encoded.body, expected);
    }

    #[test]
    fn encodes_datetime64_as_millisecond_ticks() {
        let encoded = encode(
            &[f64_column("t", "DateTime64(3, 'UTC')", &[1234567890123.0])],
            1,
        )
        .unwrap();
        assert_eq!(encoded.body, 1234567890123i64.to_le_bytes().to_vec());
    }

    #[test]
    fn a_null_marker_on_a_required_column_writes_the_type_default() {
        let mut column = text_column("id", "String", &["", "ab"]);
        column.nulls = vec![1, 0];
        let encoded = encode(&[column], 2).unwrap();
        assert_eq!(encoded.body, vec![0, 2, b'a', b'b']);
    }

    #[test]
    fn a_null_marker_defaults_an_enum_to_its_first_variant() {
        let mut column = text_column("e", "Enum8('SET' = 1, 'DELETE' = 2)", &[""]);
        column.nulls = vec![1];
        let encoded = encode(&[column], 1).unwrap();
        assert_eq!(encoded.body, vec![1]);
    }

    #[test]
    fn row_offsets_allow_splitting_at_a_row_boundary() {
        let encoded = encode(&[text_column("id", "String", &["a", "bb", "ccc"])], 3).unwrap();
        assert_eq!(encoded.rows(), 3);
        assert_eq!(encoded.slice(0, 1), &[1, b'a']);
        assert_eq!(encoded.slice(1, 3), &[2, b'b', b'b', 3, b'c', b'c', b'c']);
    }

    // RowBinary is the raw integer, so nothing downstream notices a value that
    // does not fit — it silently becomes a different number. These are the cases
    // ClickHouse itself used to reject on the JSONEachRow path.
    #[test]
    fn rejects_an_integer_wider_than_its_column() {
        let too_big = encode(&[f64_column("n", "Int32", &[3e9])], 1).unwrap_err();
        let negative_unsigned = encode(&[f64_column("n", "UInt32", &[-1.0])], 1).unwrap_err();
        assert_eq!(
            (
                format!("{too_big:#}").contains("out of range"),
                format!("{negative_unsigned:#}").contains("out of range")
            ),
            (true, true)
        );
    }

    #[test]
    fn accepts_the_exact_bounds_of_a_column() {
        let encoded = encode(
            &[
                f64_column("min", "Int32", &[f64::from(i32::MIN)]),
                f64_column("max", "UInt32", &[f64::from(u32::MAX)]),
            ],
            1,
        )
        .unwrap();
        let mut expected = i32::MIN.to_le_bytes().to_vec();
        expected.extend_from_slice(&u32::MAX.to_le_bytes());
        assert_eq!(encoded.body, expected);
    }

    // A Decimal's precision bounds it, not the width of its backing integer:
    // Decimal(10, 8) is 8 bytes but only accepts 10 digits.
    #[test]
    fn rejects_a_decimal_past_the_columns_precision() {
        let err = encode(&[text_column("d", "Decimal(10, 8)", &["1e11"])], 1).unwrap_err();
        assert!(
            format!("{err:#}").contains("out of range"),
            "expected a range error, got: {err:#}"
        );
    }

    #[test]
    fn accepts_a_decimal_at_the_columns_precision() {
        let encoded = encode(&[text_column("d", "Decimal(10, 8)", &["99.99999999"])], 1).unwrap();
        assert_eq!(encoded.body, 9_999_999_999i64.to_le_bytes().to_vec());
    }

    // Past the range check too: scaling the literal overflows the 128 bits the
    // encoder carries before there is anything to compare against a bound.
    #[test]
    fn rejects_a_decimal_that_overflows_while_scaling() {
        let err = encode(&[text_column("d", "Decimal(38, 8)", &["1e40"])], 1).unwrap_err();
        assert!(
            format!("{err:#}").contains("overflows"),
            "expected an overflow error, got: {err:#}"
        );
    }

    #[test]
    fn rejects_a_fractional_value_for_an_integer_column() {
        let err = encode(&[f64_column("n", "Int32", &[1.5])], 1).unwrap_err();
        assert!(
            format!("{err:#}").contains("is not an integer"),
            "expected an integrality error, got: {err:#}"
        );
    }

    #[test]
    fn rejects_a_column_shorter_than_the_batch() {
        let err = encode(&[text_column("id", "String", &["a"])], 2).unwrap_err();
        assert!(format!("{err:#}").contains("has 1 values"));
    }
}
