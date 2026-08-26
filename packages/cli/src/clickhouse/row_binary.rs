use std::borrow::Cow;

use anyhow::{anyhow, bail, Context, Result};
use bytes::Bytes;

use super::ch_type::ChType;
use super::ch_type::ColumnKind;

#[derive(Debug)]
pub enum ColumnValues {
    F64(Vec<f64>),
    U64(Vec<u64>),
    I64(Vec<i64>),
    Text(Vec<String>),
}

impl ColumnValues {
    pub fn kind(&self) -> ColumnKind {
        match self {
            ColumnValues::F64(_) => ColumnKind::F64,
            ColumnValues::U64(_) => ColumnKind::U64,
            ColumnValues::I64(_) => ColumnKind::I64,
            ColumnValues::Text(_) => ColumnKind::Text,
        }
    }

    pub fn len(&self) -> usize {
        match self {
            ColumnValues::F64(v) => v.len(),
            ColumnValues::U64(v) => v.len(),
            ColumnValues::I64(v) => v.len(),
            ColumnValues::Text(v) => v.len(),
        }
    }
}

#[derive(Debug)]
pub struct Column<'a> {
    pub name: Cow<'a, str>,
    pub ch_type: Cow<'a, ChType>,
    pub values: ColumnValues,
    pub nulls: Vec<u8>,
}

impl Column<'_> {
    fn is_null(&self, row: usize) -> bool {
        self.nulls.get(row).copied().unwrap_or(0) != 0
    }
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

#[cfg(test)]
pub fn read_varint(bytes: &[u8]) -> Result<(u64, usize)> {
    let mut value = 0u64;
    let mut shift = 0u32;
    for (read, &byte) in bytes.iter().enumerate() {
        value |= u64::from(byte & 0x7F)
            .checked_shl(shift)
            .context("varint is wider than 64 bits")?;
        if byte & 0x80 == 0 {
            return Ok((value, read + 1));
        }
        shift += 7;
    }
    bail!("varint runs past the end of the buffer")
}

fn put_string(out: &mut Vec<u8>, value: &str) {
    put_varint(out, value.len() as u64);
    out.extend_from_slice(value.as_bytes());
}

fn decimal_to_i128(text: &str, scale: u32) -> Result<i128> {
    let text = text.trim();
    if text.is_empty() {
        bail!("a Decimal column cannot hold an empty value");
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
    let kept_frac =
        (i64::from(scale) + i64::from(exponent)).clamp(0, frac_part.len() as i64) as usize;
    let mut magnitude = 0u128;
    let mut digits = 0usize;
    for (part, kept) in [(int_part, int_part.len()), (frac_part, kept_frac)] {
        for (index, byte) in part.bytes().enumerate() {
            if !byte.is_ascii_digit() {
                bail!("`{text}` is not a decimal");
            }
            digits += 1;
            if index >= kept {
                continue;
            }
            magnitude = magnitude
                .checked_mul(10)
                .and_then(|shifted| shifted.checked_add(u128::from(byte - b'0')))
                .ok_or_else(|| anyhow!("decimal `{text}` overflows Int128"))?;
        }
    }
    if digits == 0 {
        bail!("`{text}` is not a decimal");
    }
    let shift = i64::from(scale) + i64::from(exponent) - kept_frac as i64;
    // Parsed unsigned: i128::MIN's magnitude is one past i128::MAX, so parsing
    // the digits as i128 and negating afterwards would reject a legal value.
    let mut value = match negative {
        true if magnitude <= (i128::MAX as u128) + 1 => (magnitude as i128).wrapping_neg(),
        false if magnitude <= i128::MAX as u128 => magnitude as i128,
        _ => bail!("decimal `{text}` overflows Int128"),
    };
    match shift.cmp(&0) {
        std::cmp::Ordering::Greater => {
            for _ in 0..shift {
                if value == 0 {
                    break;
                }
                value = value
                    .checked_mul(10)
                    .context("decimal overflows the column's precision")?;
            }
        }
        std::cmp::Ordering::Less => {
            // Truncates toward zero, matching ClickHouse's own cast.
            for _ in 0..-shift {
                if value == 0 {
                    break;
                }
                value /= 10;
            }
        }
        std::cmp::Ordering::Equal => {}
    }
    Ok(value)
}

fn put_int_raw(out: &mut Vec<u8>, value: i128, bytes: usize) {
    out.extend_from_slice(&value.to_le_bytes()[..bytes]);
}

const POW10: [i128; 39] = {
    let mut table = [1i128; 39];
    let mut i = 1;
    while i < table.len() {
        table[i] = table[i - 1] * 10;
        i += 1;
    }
    table
};

/// What the column accepts. RowBinary is just the raw integer, so nothing on the
/// server side rejects an out-of-range value: it wraps into whatever the bytes
/// happen to mean. Checking here is the only check there is — without it an
/// `Int!` set to 3e9 lands as a negative number.
fn int_bounds(ch_type: &ChType) -> Result<(i128, i128)> {
    Ok(match ch_type {
        ChType::Int32 => (i32::MIN as i128, i32::MAX as i128),
        ChType::Int64 => (i64::MIN as i128, i64::MAX as i128),
        ChType::Bool => (0, 1),
        ChType::UInt32 => (0, u32::MAX as i128),
        ChType::UInt64 => (0, u64::MAX as i128),
        ChType::DateTime64 => (i64::MIN as i128, i64::MAX as i128),
        ChType::Decimal { precision, .. } => {
            let limit = POW10
                .get(*precision as usize)
                .context("Decimal precision is wider than the value the encoder carries")?;
            (1 - limit, limit - 1)
        }
        ChType::Enum { variants } => {
            let width_max = if ChType::enum_bytes(variants) == 1 {
                i8::MAX as i128
            } else {
                i16::MAX as i128
            };
            (1, (variants.len() as i128).min(width_max))
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

fn encode_text_scalar(out: &mut Vec<u8>, ch_type: &ChType, text: &str) -> Result<()> {
    match ch_type {
        ChType::String => put_string(out, text),
        ChType::Decimal { scale, .. } => put_int(out, decimal_to_i128(text, *scale)?, ch_type)?,
        ChType::Enum { .. } => {
            let numeric = ch_type
                .enum_value(text)
                .with_context(|| format!("`{text}` is not a variant of the enum column"))?;
            put_int(out, numeric as i128, ch_type)?;
        }
        other => put_int(out, decimal_to_i128(text, 0)?, other)?,
    }
    Ok(())
}

fn json_integer(number: &serde_json::Number, ch_type: &ChType) -> Result<i128> {
    if let Some(value) = number.as_i64() {
        return Ok(i128::from(value));
    }
    if let Some(value) = number.as_u64() {
        return Ok(i128::from(value));
    }
    let float = number
        .as_f64()
        .with_context(|| format!("`{number}` is not a number a {ch_type:?} column can hold"))?;
    if !float.is_finite() || float.fract() != 0.0 {
        bail!("{float} is not an integer, which a {ch_type:?} column requires");
    }
    Ok(float as i128)
}

fn encode_json_value(out: &mut Vec<u8>, ch_type: &ChType, value: &serde_json::Value) -> Result<()> {
    use serde_json::Value;
    match (ch_type, value) {
        (ChType::Nullable(inner), _) => {
            if value.is_null() {
                out.push(1);
            } else {
                out.push(0);
                encode_json_value(out, inner, value)?;
            }
        }
        // Outside a Nullable column RowBinary has nowhere to put a null, and
        // writing the type's default would store a value the handler never set.
        (_, Value::Null) => bail!("null is not a value a {ch_type:?} element can hold"),
        (ChType::Array(inner), _) => {
            let items = value
                .as_array()
                .context("expected a JSON array for an Array column")?;
            put_varint(out, items.len() as u64);
            for item in items {
                encode_json_value(out, inner, item)?;
            }
        }
        (ChType::Bool, Value::Bool(bit)) => out.push(u8::from(*bit)),
        (ChType::Float64, Value::Number(number)) => {
            let float = number
                .as_f64()
                .context("a Float64 element must be a finite JSON number")?;
            out.extend_from_slice(&float.to_le_bytes())
        }
        (ChType::String, Value::String(text)) => put_string(out, text),
        (ChType::String, _) => put_string(out, &value.to_string()),
        (ChType::Enum { .. } | ChType::Decimal { .. }, Value::String(text)) => {
            encode_text_scalar(out, ch_type, text)?
        }
        (ChType::Decimal { scale, .. }, Value::Number(number)) => {
            let scaled = match number
                .as_i64()
                .map(i128::from)
                .or_else(|| number.as_u64().map(i128::from))
            {
                Some(value) => POW10
                    .get(*scale as usize)
                    .and_then(|factor| value.checked_mul(*factor))
                    .context("decimal overflows the column's precision")?,
                None => decimal_to_i128(&number.to_string(), *scale)?,
            };
            put_int(out, scaled, ch_type)?
        }
        (ChType::Enum { .. }, _) => {
            bail!("`{value}` is not a value a {ch_type:?} element can hold")
        }
        (_, Value::Number(number)) => put_int(out, json_integer(number, ch_type)?, ch_type)?,
        _ => bail!("`{value}` is not a value a {ch_type:?} element can hold"),
    }
    Ok(())
}

fn fixed_width(ch_type: &ChType) -> Result<usize> {
    Ok(match ch_type {
        ChType::Bool => 1,
        ChType::Int32 | ChType::UInt32 => 4,
        ChType::Int64 | ChType::UInt64 | ChType::DateTime64 => 8,
        ChType::Float64 => 8,
        ChType::Decimal { precision, .. } => super::ch_type::decimal_bytes(*precision)?,
        ChType::Enum { variants } => ChType::enum_bytes(variants),
        other => bail!("{other:?} has no fixed width"),
    })
}

fn put_default(out: &mut Vec<u8>, ch_type: &ChType) -> Result<()> {
    match ch_type {
        ChType::Nullable(_) => out.push(1),
        ChType::Array(_) => put_varint(out, 0),
        ChType::String => put_varint(out, 0),
        ChType::Float64 => out.extend_from_slice(&0f64.to_le_bytes()),
        // An Enum's default is its first variant, numbered 1, which is how
        // ClickHouse fills an omitted enum column.
        ChType::Enum { variants } => put_int_raw(out, 1, ChType::enum_bytes(variants)),
        other => out.extend(std::iter::repeat_n(0u8, fixed_width(other)?)),
    }
    Ok(())
}

fn encode_cell(out: &mut Vec<u8>, column: &Column, row: usize) -> Result<()> {
    let (ch_type, is_nullable) = match column.ch_type.as_ref() {
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
    if !is_nullable && column.is_null(row) {
        return put_default(out, ch_type);
    }

    match (&column.values, ch_type) {
        (ColumnValues::F64(v), ChType::Float64) => {
            let value = v[row];
            if !value.is_finite() {
                bail!(
                    "{value} is not a value a Float64 column can hold. Store a finite number, \
                     or keep it out of the entity."
                );
            }
            out.extend_from_slice(&value.to_le_bytes())
        }
        (ColumnValues::F64(v), other) => {
            let value = v[row];
            if value.fract() != 0.0 || !value.is_finite() {
                bail!("{value} is not an integer, which a {other:?} column requires");
            }
            put_int(out, value as i128, other)?
        }
        (ColumnValues::U64(v), ChType::Float64) => {
            out.extend_from_slice(&(v[row] as f64).to_le_bytes())
        }
        (ColumnValues::U64(v), ChType::UInt64) => out.extend_from_slice(&v[row].to_le_bytes()),
        (ColumnValues::I64(v), ChType::Int64) => out.extend_from_slice(&v[row].to_le_bytes()),
        (ColumnValues::U64(v), other) => put_int(out, v[row] as i128, other)?,
        (ColumnValues::I64(v), other) => put_int(out, v[row] as i128, other)?,
        (ColumnValues::Text(v), ChType::Array(_)) => {
            let parsed: serde_json::Value =
                serde_json::from_str(&v[row]).context("value is not JSON")?;
            encode_json_value(out, ch_type, &parsed)?;
        }
        (ColumnValues::Text(v), other) => encode_text_scalar(out, other, &v[row])?,
    }
    Ok(())
}

#[derive(Debug)]
pub struct EncodedRows {
    pub body: Bytes,
    pub row_offsets: Vec<usize>,
}

impl EncodedRows {
    pub fn rows(&self) -> usize {
        self.row_offsets.len()
    }

    pub fn slice(&self, start: usize, end: usize) -> Bytes {
        let from = self.row_offsets[start];
        let to = match self.row_offsets.get(end) {
            Some(offset) => *offset,
            None => self.body.len(),
        };
        self.body.slice(from..to)
    }
}

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
    let mut body = Vec::with_capacity(rows * columns.len() * 12);
    let mut row_offsets = Vec::with_capacity(rows);
    for row in 0..rows {
        row_offsets.push(body.len());
        for column in columns {
            encode_cell(&mut body, column, row)
                .with_context(|| format!("encoding column `{}` row {row}", column.name))?;
        }
    }
    Ok(EncodedRows {
        body: body.into(),
        row_offsets,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clickhouse::ch_type::test_support::parse_type;
    use pretty_assertions::assert_eq;

    fn owned_column(name: &str, ty: &str, values: ColumnValues) -> Column<'static> {
        Column {
            name: Cow::Owned(name.to_string()),
            ch_type: Cow::Owned(parse_type(ty)),
            values,
            nulls: Vec::new(),
        }
    }

    fn text_column(name: &str, ty: &str, values: &[&str]) -> Column<'static> {
        owned_column(
            name,
            ty,
            ColumnValues::Text(values.iter().map(|v| v.to_string()).collect()),
        )
    }

    fn f64_column(name: &str, ty: &str, values: &[f64]) -> Column<'static> {
        owned_column(name, ty, ColumnValues::F64(values.to_vec()))
    }

    #[test]
    fn encodes_multi_byte_characters_by_their_utf8_length() {
        let encoded = encode(&[text_column("id", "String", &["é😀"])], 1).unwrap();
        assert_eq!(encoded.body, "\u{6}é😀".as_bytes());
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
        assert_eq!(
            (&encoded.body[..2], encoded.body.len()),
            (&[0xAC, 0x02][..], 302)
        );
    }

    #[test]
    fn reads_back_the_varints_it_writes() {
        let mut out = Vec::new();
        for value in [0u64, 1, 127, 128, 300, u64::MAX] {
            put_varint(&mut out, value);
        }
        let mut decoded = Vec::new();
        let mut offset = 0;
        while offset < out.len() {
            let (value, read) = read_varint(&out[offset..]).unwrap();
            decoded.push(value);
            offset += read;
        }
        assert_eq!(decoded, vec![0, 1, 127, 128, 300, u64::MAX]);
    }

    #[test]
    fn a_truncated_varint_is_an_error_not_a_panic() {
        assert_eq!(
            read_varint(&[0x80]).unwrap_err().to_string(),
            "varint runs past the end of the buffer"
        );
    }

    #[test]
    fn encodes_fixed_width_integers_little_endian() {
        let encoded = encode(
            &[
                f64_column("a", "Int32", &[-2.0]),
                f64_column("b", "Bool", &[1.0]),
            ],
            1,
        )
        .unwrap();
        assert_eq!(encoded.body, vec![0xFE, 0xFF, 0xFF, 0xFF, 1]);
    }

    #[test]
    fn encodes_uint64_beyond_float_precision_exactly() {
        let column = owned_column(
            "checkpoint",
            "UInt64",
            ColumnValues::U64(vec![u64::MAX - 1]),
        );
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
    fn an_absurd_exponent_settles_instead_of_running_out_the_shift() {
        let tiny = encode(&[text_column("a", "Decimal(18, 4)", &["1e-1000000000"])], 1).unwrap();
        let huge = encode(&[text_column("a", "Decimal(18, 4)", &["1e1000000000"])], 1);
        assert_eq!(
            (tiny.body, huge.is_err()),
            (0i64.to_le_bytes().to_vec().into(), true)
        );
    }

    #[test]
    fn truncates_a_decimal_below_the_column_scale() {
        let encoded = encode(&[text_column("a", "Decimal(9, 1)", &["1.29"])], 1).unwrap();
        assert_eq!(encoded.body, 12i32.to_le_bytes().to_vec());
    }

    #[test]
    fn encodes_an_enum_as_its_declared_value() {
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
    fn rejects_an_enum_element_given_as_a_number() {
        let err = encode(
            &[text_column(
                "kinds",
                "Array(Enum8('SET' = 1, 'DELETE' = 2))",
                &["[1]"],
            )],
            1,
        )
        .unwrap_err();
        assert_eq!(
            format!("{err:#}"),
            "encoding column `kinds` row 0: `1` is not a value a Enum { variants: [\"SET\", \
             \"DELETE\"] } element can hold"
        );
    }

    #[test]
    fn encodes_an_enum_element_that_names_its_variant() {
        let encoded = encode(
            &[text_column(
                "kinds",
                "Array(Enum8('SET' = 1, 'DELETE' = 2))",
                &["[\"DELETE\",\"SET\"]"],
            )],
            1,
        )
        .unwrap();
        assert_eq!(encoded.body, vec![2, 2, 1]);
    }

    #[test]
    fn rejects_a_discriminant_no_enum_variant_uses() {
        let ch_type = ChType::Enum {
            variants: vec!["SET".to_string(), "DELETE".to_string()],
        };
        let refused: Vec<bool> = [0i128, 1, 2, 3]
            .into_iter()
            .map(|value| put_int(&mut Vec::new(), value, &ch_type).is_err())
            .collect();
        assert_eq!(refused, vec![true, false, false, true]);
    }

    #[test]
    fn rejects_an_enum_discriminant_wider_than_its_storage() {
        let ch_type = ChType::Enum {
            variants: (0..=i16::MAX as usize + 1)
                .map(|index| index.to_string())
                .collect(),
        };
        let refused: Vec<bool> = [1i128, i16::MAX as i128, i16::MAX as i128 + 1]
            .into_iter()
            .map(|value| put_int(&mut Vec::new(), value, &ch_type).is_err())
            .collect();
        assert_eq!(refused, vec![false, false, true]);
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
    fn rejects_a_number_a_bool_column_cannot_hold() {
        let err = encode(&[text_column("flags", "Array(Bool)", &["[7]"])], 1).unwrap_err();
        assert_eq!(
            format!("{err:#}"),
            "encoding column `flags` row 0: 7 is out of range for a Bool column"
        );
    }

    #[test]
    fn rejects_a_scalar_number_a_bool_column_cannot_hold() {
        let err = encode(&[f64_column("flag", "Bool", &[7.0])], 1).unwrap_err();
        assert_eq!(
            format!("{err:#}"),
            "encoding column `flag` row 0: 7 is out of range for a Bool column"
        );
    }

    #[test]
    fn rejects_an_empty_decimal_string() {
        let err = encode(&[text_column("d", "Decimal(38, 0)", &[""])], 1).unwrap_err();
        assert_eq!(
            format!("{err:#}"),
            "encoding column `d` row 0: a Decimal column cannot hold an empty value"
        );
    }

    #[test]
    fn rejects_a_non_finite_float_for_a_bool_column() {
        let err = encode(&[f64_column("flag", "Bool", &[f64::NAN])], 1).unwrap_err();
        assert_eq!(
            format!("{err:#}"),
            "encoding column `flag` row 0: NaN is not an integer, which a Bool column requires"
        );
    }

    #[test]
    fn rejects_a_non_finite_float_for_a_float_column() {
        let refused: Vec<String> = [f64::NAN, f64::INFINITY, f64::NEG_INFINITY]
            .into_iter()
            .map(|value| {
                let err = encode(&[f64_column("latest", "Float64", &[value])], 1).unwrap_err();
                format!("{err:#}")
            })
            .collect();
        assert_eq!(
            refused,
            ["NaN", "inf", "-inf"]
                .map(|value| format!(
                    "encoding column `latest` row 0: {value} is not a value a Float64 column can \
                     hold. Store a finite number, or keep it out of the entity."
                ))
                .to_vec()
        );
    }

    #[test]
    fn encodes_a_finite_float() {
        let encoded = encode(&[f64_column("latest", "Float64", &[1.5])], 1).unwrap();
        assert_eq!(encoded.body, 1.5f64.to_le_bytes().to_vec());
    }

    #[test]
    fn a_json_element_of_a_string_array_is_stored_as_its_text() {
        let encoded = encode(
            &[text_column(
                "xs",
                "Array(String)",
                &[r#"[{"a":1},2,true,"s"]"#],
            )],
            1,
        )
        .unwrap();
        let mut expected = vec![4];
        for value in [r#"{"a":1}"#, "2", "true", "s"] {
            expected.push(value.len() as u8);
            expected.extend_from_slice(value.as_bytes());
        }
        assert_eq!(encoded.body, expected);
    }

    #[test]
    fn encodes_decimal_array_elements_given_as_json_numbers() {
        let encoded = encode(
            &[text_column("xs", "Array(Decimal(18, 2))", &["[10,-3,1.5]"])],
            1,
        )
        .unwrap();
        let mut expected = vec![3];
        for scaled in [1_000i64, -300, 150] {
            expected.extend_from_slice(&scaled.to_le_bytes());
        }
        assert_eq!(encoded.body, expected);
    }

    #[test]
    fn rejects_a_decimal_array_element_the_column_cannot_hold() {
        let encoded = encode(
            &[text_column("xs", "Array(Decimal(9, 2))", &["[99999999]"])],
            1,
        );
        assert!(
            encoded.is_err(),
            "expected the column's precision to refuse the value"
        );
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
    fn encodes_a_uint64_array_element_past_float_precision() {
        let encoded = encode(
            &[text_column(
                "xs",
                "Array(UInt64)",
                &["[18446744073709551615]"],
            )],
            1,
        )
        .unwrap();
        let mut expected = vec![1];
        expected.extend_from_slice(&u64::MAX.to_le_bytes());
        assert_eq!(encoded.body, expected);
    }

    #[test]
    fn rejects_a_fractional_array_element_for_an_integer_column() {
        let err = encode(&[text_column("xs", "Array(Int32)", &["[1.5]"])], 1).unwrap_err();
        assert_eq!(
            format!("{err:#}").contains("is not an integer"),
            true,
            "expected an integrality error, got: {err:#}"
        );
    }

    // A null has no representation in a non-nullable element, so it has to be
    // refused rather than rendered: the text "null" would store verbatim in an
    // Array(String) and mean nothing anywhere else.
    #[test]
    fn rejects_a_null_element_for_a_non_nullable_inner_type() {
        let strings =
            encode(&[text_column("xs", "Array(String)", &["[\"a\",null]"])], 1).unwrap_err();
        let ints = encode(&[text_column("xs", "Array(Int32)", &["[null]"])], 1).unwrap_err();
        assert_eq!(
            (
                format!("{strings:#}").contains("null is not a value"),
                format!("{ints:#}").contains("null is not a value")
            ),
            (true, true),
            "expected null-element errors, got: {strings:#} / {ints:#}"
        );
    }

    #[test]
    fn encodes_a_null_element_where_the_inner_type_is_nullable() {
        let encoded = encode(
            &[text_column("xs", "Array(Nullable(UInt32))", &["[null,7]"])],
            1,
        )
        .unwrap();
        let mut expected = vec![2, 1, 0];
        expected.extend_from_slice(&7u32.to_le_bytes());
        assert_eq!(encoded.body, expected);
    }

    #[test]
    fn rejects_an_element_of_the_wrong_json_shape() {
        let err = encode(&[text_column("xs", "Array(Float64)", &["[true]"])], 1).unwrap_err();
        assert_eq!(
            format!("{err:#}").contains("is not a value a Float64 element can hold"),
            true,
            "expected a shape error, got: {err:#}"
        );
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
        assert_eq!(
            (
                encoded.rows(),
                encoded.slice(0, 1).to_vec(),
                encoded.slice(1, 3).to_vec()
            ),
            (3, vec![1, b'a'], vec![2, b'b', b'b', 3, b'c', b'c', b'c'])
        );
    }

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
    fn rejects_an_array_element_wider_than_its_column() {
        let err = encode(&[text_column("xs", "Array(Int32)", &["[3000000000]"])], 1).unwrap_err();
        assert_eq!(
            format!("{err:#}").contains("out of range"),
            true,
            "expected a range error, got: {err:#}"
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

    #[test]
    fn rejects_a_decimal_that_overflows_while_scaling() {
        let err = encode(&[text_column("d", "Decimal(38, 8)", &["1e40"])], 1).unwrap_err();
        assert!(
            format!("{err:#}").contains("overflows"),
            "expected an overflow error, got: {err:#}"
        );
    }

    #[test]
    fn a_decimal_padded_with_leading_zeros_keeps_its_value() {
        let padded = format!("{}42", "0".repeat(60));
        let encoded = encode(&[text_column("d", "Decimal(38, 0)", &[&padded])], 1).unwrap();
        assert_eq!(encoded.body, 42i128.to_le_bytes().to_vec());
    }

    #[test]
    fn a_decimal_with_more_fractional_digits_than_the_scale_keeps_its_value() {
        let value = format!("1.{}", "9".repeat(60));
        let encoded = encode(&[text_column("d", "Decimal(38, 2)", &[&value])], 1).unwrap();
        assert_eq!(encoded.body, 199i128.to_le_bytes().to_vec());
    }

    #[test]
    fn rejects_a_non_digit_among_the_truncated_digits_of_a_decimal() {
        let err = encode(&[text_column("d", "Decimal(38, 2)", &["1.23x"])], 1).unwrap_err();
        assert!(
            format!("{err:#}").contains("is not a decimal"),
            "expected a parse error, got: {err:#}"
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
