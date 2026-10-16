use std::borrow::Cow;

use anyhow::{anyhow, bail, Context, Result};
use bytes::Bytes;

use super::ch_type::ChType;
use crate::columnar::{self, ColumnKind};
use crate::storage::rows::{Cell, ReadKind};

/// One staged column, read straight out of the arena JavaScript filled.
pub struct Column<'a> {
    pub name: &'a str,
    pub ch_type: &'a ChType,
    pub values: &'a columnar::Column,
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

fn put_bytes(out: &mut Vec<u8>, value: &[u8]) {
    put_varint(out, value.len() as u64);
    out.extend_from_slice(value);
}

/// Without its NUL bytes: Postgres keeps none in text, and both stores have to
/// hold the same value for one entity.
pub(super) fn put_string(out: &mut Vec<u8>, value: &str) {
    if value.contains('\0') {
        put_bytes(out, value.replace('\0', "").as_bytes());
    } else {
        put_bytes(out, value.as_bytes());
    }
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
    // Rounded half away from zero on the first dropped digit, as Postgres
    // rounds a numeric(P, S) — the entity lands in both stores, and ClickHouse's
    // own cast, which truncates, would leave this one an ulp under the other.
    let mut round_away = frac_part
        .as_bytes()
        .get(kept_frac)
        .is_some_and(|d| *d >= b'5');
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
            for _ in 0..-shift {
                if value == 0 {
                    round_away = false;
                    break;
                }
                round_away = (value % 10).abs() >= 5;
                value /= 10;
            }
        }
        std::cmp::Ordering::Equal => {}
    }
    if round_away {
        value = value
            .checked_add(if negative { -1 } else { 1 })
            .context("decimal overflows the column's precision")?;
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
        ChType::DateTime64 => (DATETIME64_MIN_MS, DATETIME64_MAX_MS),
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

/// The column's Int64 tick holds far more than the dates ClickHouse gives
/// meaning to: outside 1900-01-01..2299-12-31 the server stores the tick as
/// given and its date functions read it back as some other date.
const DATETIME64_MIN_MS: i128 = -2_208_988_800_000;
const DATETIME64_MAX_MS: i128 = 10_413_791_999_999;

fn iso_millis(ticks: i64) -> String {
    let days = ticks.div_euclid(86_400_000);
    let ms = ticks.rem_euclid(86_400_000);
    // Days since 1970-01-01 to a civil date, via a 400-year era whose day
    // count is fixed; March-based so leap days fall at the end of the year.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        ms / 3_600_000,
        ms / 60_000 % 60,
        ms / 1000 % 60,
        ms % 1000
    )
}

fn put_int(out: &mut Vec<u8>, value: i128, ch_type: &ChType) -> Result<()> {
    let (min, max) = int_bounds(ch_type)?;
    if value < min || value > max {
        if let (ChType::DateTime64, Ok(ticks)) = (ch_type, i64::try_from(value)) {
            bail!(
                "{} is outside the range a DateTime64 column can hold, 1900-01-01 through \
                 2299-12-31",
                iso_millis(ticks)
            );
        }
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
        // A Uint8Array inside a JSON document arrives as its byte values.
        (ChType::Bytes, Value::Array(items)) => {
            let bytes = items
                .iter()
                .map(|item| {
                    item.as_u64()
                        .and_then(|byte| u8::try_from(byte).ok())
                        .with_context(|| format!("`{item}` is not a byte"))
                })
                .collect::<Result<Vec<u8>>>()?;
            put_bytes(out, &bytes)
        }
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
        ChType::String | ChType::Bytes => put_varint(out, 0),
        ChType::Float64 => out.extend_from_slice(&0f64.to_le_bytes()),
        // An Enum's default is its first variant, numbered 1, which is how
        // ClickHouse fills an omitted enum column.
        ChType::Enum { variants } => put_int_raw(out, 1, ChType::enum_bytes(variants)),
        other => out.extend(std::iter::repeat_n(0u8, fixed_width(other)?)),
    }
    Ok(())
}

fn encode_cell(out: &mut Vec<u8>, column: &Column, row: usize) -> Result<()> {
    let (ch_type, is_nullable) = match column.ch_type {
        ChType::Nullable(inner) => {
            if column.values.is_null(row) {
                out.push(1);
                return Ok(());
            }
            out.push(0);
            (inner.as_ref(), true)
        }
        other => (other, false),
    };
    if !is_nullable && column.values.is_null(row) {
        return put_default(out, ch_type);
    }

    let values = column.values;
    match (values.kind(), ch_type) {
        // Nothing registers one: a ClickHouse array is staged as the JSON text
        // of its elements.
        (ColumnKind::List, _) => bail!("a list column is not one this encoder writes yet"),
        (ColumnKind::F64, ChType::Float64) => {
            let value = values.f64_at(row);
            if !value.is_finite() {
                bail!(
                    "{value} is not a value a Float64 column can hold. Store a finite number, \
                     or keep it out of the entity."
                );
            }
            out.extend_from_slice(&value.to_le_bytes())
        }
        (ColumnKind::F64, other) => {
            let value = values.f64_at(row);
            if value.fract() != 0.0 || !value.is_finite() {
                bail!("{value} is not an integer, which a {other:?} column requires");
            }
            put_int(out, value as i128, other)?
        }
        (ColumnKind::U64, ChType::Float64) => {
            out.extend_from_slice(&(values.u64_at(row) as f64).to_le_bytes())
        }
        (ColumnKind::U64, ChType::UInt64) => {
            out.extend_from_slice(&values.u64_at(row).to_le_bytes())
        }
        (ColumnKind::I64, ChType::Int64) => {
            out.extend_from_slice(&values.i64_at(row).to_le_bytes())
        }
        (ColumnKind::U64, other) => put_int(out, values.u64_at(row) as i128, other)?,
        (ColumnKind::I64, other) => put_int(out, values.i64_at(row) as i128, other)?,
        (ColumnKind::Text, ChType::Array(_)) => {
            let parsed: serde_json::Value =
                serde_json::from_slice(values.bytes_at(row)).context("value is not JSON")?;
            encode_json_value(out, ch_type, &parsed)?;
        }
        (ColumnKind::Text, other) => encode_text_scalar(out, other, values.str_at(row)?)?,
        (ColumnKind::Bytes, ChType::Bytes) => put_bytes(out, values.bytes_at(row)),
        (ColumnKind::Bytes, other) => {
            bail!("raw bytes are not a value a {other:?} column can hold")
        }
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

/// A value of one of the indexer's own tables, which Rust writes itself rather
/// than having JavaScript stage it.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Int(i128),
    Text(String),
    #[cfg(test)]
    Bool(bool),
    #[cfg(test)]
    Bytes(Vec<u8>),
    #[cfg(test)]
    Float(f64),
    #[cfg(test)]
    List(Vec<Value>),
}

fn encode_value(out: &mut Vec<u8>, ch_type: &ChType, value: &Value) -> Result<()> {
    match (ch_type, value) {
        (ChType::Nullable(_), Value::Null) => out.push(1),
        (ChType::Nullable(inner), value) => {
            out.push(0);
            encode_value(out, inner, value)?;
        }
        (_, Value::Null) => bail!("null is not a value a {ch_type:?} column can hold"),
        #[cfg(test)]
        (ChType::Array(inner), Value::List(items)) => {
            put_varint(out, items.len() as u64);
            for item in items {
                encode_value(out, inner, item)?;
            }
        }
        #[cfg(test)]
        (ChType::Float64, Value::Float(float)) => out.extend_from_slice(&float.to_le_bytes()),
        #[cfg(test)]
        (ChType::Bool, Value::Bool(bit)) => out.push(u8::from(*bit)),
        (ChType::String, Value::Text(text)) => put_string(out, text),
        #[cfg(test)]
        (ChType::Bytes | ChType::String, Value::Bytes(bytes)) => put_bytes(out, bytes),
        (ChType::Enum { .. } | ChType::Decimal { .. }, Value::Text(text)) => {
            encode_text_scalar(out, ch_type, text)?
        }
        (_, Value::Int(int)) => put_int(out, *int, ch_type)?,
        (_, value) => bail!("{value:?} is not a value a {ch_type:?} column can hold"),
    }
    Ok(())
}

pub fn encode_values(types: &[ChType], rows: &[Vec<Value>]) -> Result<EncodedRows> {
    let mut body = Vec::with_capacity(rows.len() * types.len() * 8);
    let mut row_offsets = Vec::with_capacity(rows.len());
    for (index, row) in rows.iter().enumerate() {
        if row.len() != types.len() {
            bail!(
                "row {index} has {} values for {} columns",
                row.len(),
                types.len()
            );
        }
        row_offsets.push(body.len());
        for (column, (ch_type, value)) in types.iter().zip(row).enumerate() {
            encode_value(&mut body, ch_type, value)
                .with_context(|| format!("encoding column {column} row {index}"))?;
        }
    }
    Ok(EncodedRows {
        body: body.into(),
        row_offsets,
    })
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, length: usize) -> Result<&'a [u8]> {
        let end = self
            .at
            .checked_add(length)
            .filter(|end| *end <= self.bytes.len())
            .with_context(|| {
                format!(
                    "the answer ended {} bytes into a value that needs {length}",
                    self.bytes.len().saturating_sub(self.at)
                )
            })?;
        let taken = &self.bytes[self.at..end];
        self.at = end;
        Ok(taken)
    }

    fn byte(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }

    fn varint(&mut self) -> Result<u64> {
        let mut value = 0u64;
        let mut shift = 0u32;
        loop {
            let byte = self.byte()?;
            value |= u64::from(byte & 0x7F)
                .checked_shl(shift)
                .context("varint is wider than 64 bits")?;
            if byte & 0x80 == 0 {
                return Ok(value);
            }
            shift += 7;
        }
    }

    fn signed(&mut self, width: usize) -> Result<i128> {
        let bytes = self.take(width)?;
        let mut padded = [0u8; 16];
        padded[..width].copy_from_slice(bytes);
        // Sign-extended from the width's own top bit.
        if bytes[width - 1] & 0x80 != 0 {
            padded[width..].fill(0xFF);
        }
        Ok(i128::from_le_bytes(padded))
    }

    fn unsigned(&mut self, width: usize) -> Result<u128> {
        let bytes = self.take(width)?;
        let mut padded = [0u8; 16];
        padded[..width].copy_from_slice(bytes);
        Ok(u128::from_le_bytes(padded))
    }

    fn is_done(&self) -> bool {
        self.at == self.bytes.len()
    }
}

/// A Decimal's integer at its scale, rendered the way Postgres renders a
/// `numeric(P, S)`: every one of its `scale` places written out.
fn decimal_text(value: i128, scale: u32) -> String {
    let negative = value < 0;
    let digits = value.unsigned_abs().to_string();
    let scale = scale as usize;
    let mut rendered = String::with_capacity(digits.len() + scale + 2);
    if negative {
        rendered.push('-');
    }
    if scale == 0 {
        rendered.push_str(&digits);
        return rendered;
    }
    let padded = format!("{digits:0>width$}", width = scale + 1);
    let (whole, fraction) = padded.split_at(padded.len() - scale);
    rendered.push_str(whole);
    rendered.push('.');
    rendered.push_str(fraction);
    rendered
}

/// An integer as what it reads as: text where the column is wider than a
/// JavaScript number keeps exactly, a number otherwise.
fn integer_cell(value: i128, kind: ReadKind) -> Cell<'static> {
    match kind {
        ReadKind::Text => Cell::Str(Cow::Owned(value.to_string())),
        ReadKind::Bool => Cell::Bool(value != 0),
        _ => Cell::Num(value as f64),
    }
}

fn decode_value(
    reader: &mut Reader<'_>,
    ch_type: &ChType,
    kind: ReadKind,
) -> Result<Cell<'static>> {
    Ok(match ch_type {
        ChType::Nullable(inner) => {
            if reader.byte()? != 0 {
                Cell::Null
            } else {
                decode_value(reader, inner, kind)?
            }
        }
        ChType::Array(inner) => {
            let length = reader.varint()? as usize;
            let mut items = Vec::with_capacity(length.min(4096));
            for _ in 0..length {
                items.push(decode_value(reader, inner, kind)?);
            }
            Cell::Arr(items)
        }
        ChType::Bool => Cell::Bool(reader.byte()? != 0),
        ChType::Int32 => integer_cell(reader.signed(4)?, kind),
        ChType::Int64 => integer_cell(reader.signed(8)?, kind),
        ChType::UInt32 => integer_cell(reader.unsigned(4)? as i128, kind),
        ChType::UInt64 => integer_cell(reader.unsigned(8)? as i128, kind),
        ChType::Float64 => Cell::Num(f64::from_le_bytes(
            reader.take(8)?.try_into().expect("took eight bytes"),
        )),
        ChType::DateTime64 => Cell::Timestamp(reader.signed(8)? as f64),
        ChType::Decimal { precision, scale } => Cell::Str(Cow::Owned(decimal_text(
            reader.signed(super::ch_type::decimal_bytes(*precision)?)?,
            *scale,
        ))),
        ChType::Enum { variants } => {
            let number = reader.signed(ChType::enum_bytes(variants))?;
            let variant = usize::try_from(number - 1)
                .ok()
                .and_then(|index| variants.get(index))
                .with_context(|| format!("{number} numbers no variant of {ch_type:?}"))?;
            Cell::Str(Cow::Owned(variant.clone()))
        }
        ChType::String | ChType::Bytes => {
            let length = reader.varint()? as usize;
            let bytes = reader.take(length)?;
            match kind {
                ReadKind::Bytes => Cell::Bytes(Cow::Owned(bytes.to_vec())),
                _ => Cell::Str(Cow::Owned(
                    std::str::from_utf8(bytes)
                        .context("a text column holds bytes that are not UTF-8")?
                        .to_string(),
                )),
            }
        }
    })
}

/// Reads a RowBinary answer whose columns are `columns`: each a type and what
/// its values read as — a list's elements, for an `Array`. Returns every row's
/// cells in turn.
pub fn decode(body: &[u8], columns: &[(ChType, ReadKind)]) -> Result<Vec<Cell<'static>>> {
    let mut reader = Reader { bytes: body, at: 0 };
    let mut cells = Vec::new();
    let mut row = 0usize;
    while !reader.is_done() {
        for (index, (ch_type, kind)) in columns.iter().enumerate() {
            cells.push(
                decode_value(&mut reader, ch_type, *kind)
                    .with_context(|| format!("reading column {index} of row {row}"))?,
            );
        }
        row += 1;
    }
    Ok(cells)
}

/// Appends the rows to what `body` already holds, so several stagings of one
/// table go in one insert.
pub fn encode_into(
    body: &mut Vec<u8>,
    row_offsets: &mut Vec<usize>,
    columns: &[Column],
    rows: usize,
) -> Result<()> {
    for column in columns {
        if column.values.len() != rows {
            bail!(
                "column `{}` has {} values but the batch has {rows} rows",
                column.name,
                column.values.len()
            );
        }
    }
    for row in 0..rows {
        row_offsets.push(body.len());
        for column in columns {
            encode_cell(body, column, row)
                .with_context(|| format!("encoding column `{}` row {row}", column.name))?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clickhouse::ch_type::test_support::parse_type;
    use pretty_assertions::assert_eq;

    /// A column and the arena backing it, so a test can keep owning the values
    /// a borrowed [`Column`] points at.
    struct TestColumn {
        name: String,
        ch_type: ChType,
        arena: columnar::Arena,
    }

    impl TestColumn {
        fn new(name: &str, ch_type: ChType, kind: ColumnKind, rows: usize) -> Self {
            Self {
                name: name.to_string(),
                ch_type,
                arena: columnar::Arena::new(rows.max(1), &[kind]).unwrap(),
            }
        }

        fn set_nulls(&mut self, nulls: &[u8]) {
            for (row, &null) in nulls.iter().enumerate() {
                if null != 0 {
                    self.arena.mark_null(0, row);
                }
            }
        }
    }

    fn encode(columns: &[TestColumn], rows: usize) -> Result<EncodedRows> {
        let borrowed: Vec<Column> = columns
            .iter()
            .map(|column| Column {
                name: &column.name,
                ch_type: &column.ch_type,
                values: &column.arena.columns()[0],
            })
            .collect();
        let (mut body, mut row_offsets) = (Vec::new(), Vec::new());
        encode_into(&mut body, &mut row_offsets, &borrowed, rows)?;
        Ok(EncodedRows {
            body: body.into(),
            row_offsets,
        })
    }

    fn text_column(name: &str, ty: &str, values: &[&str]) -> TestColumn {
        let mut column = TestColumn::new(name, parse_type(ty), ColumnKind::Text, values.len());
        for (row, value) in values.iter().enumerate() {
            column.arena.set_bytes(0, row, value.as_bytes());
        }
        column
    }

    fn f64_column(name: &str, ty: &str, values: &[f64]) -> TestColumn {
        let mut column = TestColumn::new(name, parse_type(ty), ColumnKind::F64, values.len());
        for (row, &value) in values.iter().enumerate() {
            column.arena.set_f64(0, row, value);
        }
        column
    }

    fn u64_column(name: &str, ty: &str, values: &[u64]) -> TestColumn {
        let mut column = TestColumn::new(name, parse_type(ty), ColumnKind::U64, values.len());
        for (row, &value) in values.iter().enumerate() {
            column.arena.set_u64(0, row, value);
        }
        column
    }

    fn bytes_column(name: &str, ty: ChType, values: &[&[u8]]) -> TestColumn {
        let mut column = TestColumn::new(name, ty, ColumnKind::Bytes, values.len());
        for (row, value) in values.iter().enumerate() {
            column.arena.set_bytes(0, row, value);
        }
        column
    }

    #[test]
    fn encodes_raw_bytes_with_a_varint_length() {
        let encoded = encode(
            &[bytes_column(
                "data",
                ChType::Bytes,
                &[&[0xff, 0x00, 0x10], &[]],
            )],
            2,
        )
        .unwrap();
        assert_eq!(
            (encoded.body, encoded.row_offsets),
            (vec![3, 0xff, 0x00, 0x10, 0].into(), vec![0, 4])
        );
    }

    #[test]
    fn a_null_bytes_cell_writes_the_null_marker() {
        let mut column = bytes_column("data", ChType::Nullable(Box::new(ChType::Bytes)), &[&[1]]);
        column.set_nulls(&[1]);
        let encoded = encode(&[column], 1).unwrap();
        assert_eq!(encoded.body, vec![1]);
    }

    #[test]
    fn a_bytes_list_arrives_as_json_byte_values() {
        let mut column = text_column("chunks", "Array(String)", &["[[1,255],[]]"]);
        column.ch_type = ChType::Array(Box::new(ChType::Bytes));
        let encoded = encode(&[column], 1).unwrap();
        assert_eq!(encoded.body, vec![2, 2, 1, 255, 0]);
    }

    #[test]
    fn a_bytes_list_element_past_a_byte_is_an_error() {
        let mut column = text_column("chunks", "Array(String)", &["[[256]]"]);
        column.ch_type = ChType::Array(Box::new(ChType::Bytes));
        let error = encode(&[column], 1).unwrap_err();
        assert_eq!(
            format!("{error:#}"),
            "encoding column `chunks` row 0: `256` is not a byte"
        );
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
        let mut reader = Reader { bytes: &out, at: 0 };
        let mut decoded = Vec::new();
        while !reader.is_done() {
            decoded.push(reader.varint().unwrap());
        }
        assert_eq!(decoded, vec![0, 1, 127, 128, 300, u64::MAX]);
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
        let column = u64_column("checkpoint", "UInt64", &[u64::MAX - 1]);
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

    // Postgres rounds a numeric(P, S) half away from zero, and an entity lands
    // in both stores: the value ClickHouse holds has to be the one Postgres
    // holds, not one ulp under it.
    #[test]
    fn rounds_a_decimal_below_the_column_scale_as_postgres_does() {
        let scaled: Vec<i128> = [
            "1.29", "1.25", "-1.25", "1.24999", "0.05", "-0.05", "9.95", "2.5e-1", "1.25e-1",
            "5e-3",
        ]
        .into_iter()
        .map(|text| decimal_to_i128(text, 1).unwrap())
        .collect();
        assert_eq!(scaled, vec![13, 13, -13, 12, 1, -1, 100, 3, 1, 0]);
    }

    #[test]
    fn a_rounded_decimal_that_outgrows_the_column_is_refused() {
        let err = encode(&[text_column("a", "Decimal(3, 2)", &["9.995"])], 1).unwrap_err();
        assert!(
            format!("{err:#}").contains("out of range"),
            "expected a range error, got: {err:#}"
        );
    }

    #[test]
    fn rounds_a_decimal_array_element_as_postgres_does() {
        let encoded = encode(
            &[text_column(
                "xs",
                "Array(Decimal(18, 2))",
                &["[1.005,\"-1.005\"]"],
            )],
            1,
        )
        .unwrap();
        let mut expected = vec![2];
        for scaled in [101i64, -101] {
            expected.extend_from_slice(&scaled.to_le_bytes());
        }
        assert_eq!(encoded.body, expected);
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
        column.set_nulls(&[1, 0]);
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

    // RowBinary takes any Int64 tick, and ClickHouse stores one past its range
    // without complaint; the date it then reads back is a different one.
    #[test]
    fn rejects_a_date_outside_what_datetime64_represents() {
        let refused: Vec<String> = [253402214400000.0, -2208988800001.0]
            .into_iter()
            .map(|ticks| {
                let err =
                    encode(&[f64_column("t", "DateTime64(3, 'UTC')", &[ticks])], 1).unwrap_err();
                format!("{err:#}")
            })
            .collect();
        assert_eq!(
            refused,
            [
                "encoding column `t` row 0: 9999-12-31T00:00:00.000Z is outside the range a \
                 DateTime64 column can hold, 1900-01-01 through 2299-12-31",
                "encoding column `t` row 0: 1899-12-31T23:59:59.999Z is outside the range a \
                 DateTime64 column can hold, 1900-01-01 through 2299-12-31",
            ]
        );
    }

    #[test]
    fn accepts_the_exact_bounds_of_datetime64() {
        let encoded = encode(
            &[
                f64_column("min", "DateTime64(3, 'UTC')", &[-2208988800000.0]),
                f64_column("max", "DateTime64(3, 'UTC')", &[10413791999999.0]),
            ],
            1,
        )
        .unwrap();
        let mut expected = (-2208988800000i64).to_le_bytes().to_vec();
        expected.extend_from_slice(&10413791999999i64.to_le_bytes());
        assert_eq!(encoded.body, expected);
    }

    #[test]
    fn a_null_marker_on_a_required_column_writes_the_type_default() {
        let mut column = text_column("id", "String", &["", "ab"]);
        column.set_nulls(&[1, 0]);
        let encoded = encode(&[column], 2).unwrap();
        assert_eq!(encoded.body, vec![0, 2, b'a', b'b']);
    }

    #[test]
    fn a_null_marker_defaults_an_enum_to_its_first_variant() {
        let mut column = text_column("e", "Enum8('SET' = 1, 'DELETE' = 2)", &[""]);
        column.set_nulls(&[1]);
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
        assert_eq!(encoded.body, 200i128.to_le_bytes().to_vec());
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

    /// Each value is read as what Postgres hands back for the same field: an
    /// integer wider than a JavaScript number as its digits, a Decimal at its
    /// scale, an enum by name.
    #[test]
    fn reads_back_every_type_the_encoder_writes() {
        let columns = [
            ("Int32", ReadKind::Float, Value::Int(-7)),
            ("UInt32", ReadKind::Text, Value::Int(4_000_000_000)),
            ("UInt64", ReadKind::Text, Value::Int(9_007_199_254_740_993)),
            ("Int64", ReadKind::Text, Value::Int(-3)),
            ("Float64", ReadKind::Float, Value::Float(1.5)),
            ("Bool", ReadKind::Bool, Value::Bool(true)),
            (
                "DateTime64(3, 'UTC')",
                ReadKind::Timestamp,
                Value::Int(1_700_000_000_123),
            ),
            (
                "Decimal(18, 2)",
                ReadKind::Text,
                Value::Text("-12.5".to_string()),
            ),
            (
                "Decimal(38, 0)",
                ReadKind::Text,
                Value::Text("123456789012345678901234567890".to_string()),
            ),
            ("Nullable(String)", ReadKind::Text, Value::Null),
            (
                "Array(Int32)",
                ReadKind::Float,
                Value::List(vec![Value::Int(1), Value::Int(-1)]),
            ),
            (
                "Enum8('SET' = 1, 'DELETE' = 2)",
                ReadKind::Text,
                Value::Text("DELETE".to_string()),
            ),
        ]
        .map(|(ty, kind, value)| (parse_type(ty), kind, value));
        let types = columns
            .iter()
            .map(|(ty, _, _)| ty.clone())
            .collect::<Vec<_>>();
        let encoded = encode_values(
            &types,
            &[columns.iter().map(|(_, _, value)| value.clone()).collect()],
        )
        .unwrap();
        let reads = columns
            .iter()
            .map(|(ty, kind, _)| (ty.clone(), *kind))
            .collect::<Vec<_>>();

        assert_eq!(
            decode(&encoded.body, &reads).unwrap(),
            vec![
                Cell::Num(-7.0),
                Cell::Str("4000000000".into()),
                Cell::Str("9007199254740993".into()),
                Cell::Str("-3".into()),
                Cell::Num(1.5),
                Cell::Bool(true),
                Cell::Timestamp(1_700_000_000_123.0),
                Cell::Str("-12.50".into()),
                Cell::Str("123456789012345678901234567890".into()),
                Cell::Null,
                Cell::Arr(vec![Cell::Num(1.0), Cell::Num(-1.0)]),
                Cell::Str("DELETE".into()),
            ]
        );
    }

    #[test]
    fn a_decimal_reads_with_every_place_its_scale_declares() {
        assert_eq!(
            [
                decimal_text(0, 2),
                decimal_text(5, 2),
                decimal_text(-5, 2),
                decimal_text(150, 2),
                decimal_text(-12345, 0),
            ],
            ["0.00", "0.05", "-0.05", "1.50", "-12345"].map(str::to_string)
        );
    }

    #[test]
    fn bytes_read_back_as_bytes_and_text_as_text() {
        let encoded = encode_values(
            &[ChType::Bytes, ChType::String],
            &[vec![
                Value::Bytes(vec![0, 255]),
                Value::Text("é".to_string()),
            ]],
        )
        .unwrap();
        assert_eq!(
            decode(
                &encoded.body,
                &[
                    (ChType::Bytes, ReadKind::Bytes),
                    (ChType::String, ReadKind::Json)
                ]
            )
            .unwrap(),
            vec![Cell::Bytes(vec![0, 255].into()), Cell::Str("é".into())]
        );
    }

    #[test]
    fn an_answer_that_ends_inside_a_value_is_an_error_not_a_panic() {
        assert_eq!(
            format!(
                "{:#}",
                decode(&[5, b'a'], &[(ChType::String, ReadKind::Text)]).unwrap_err()
            ),
            "reading column 0 of row 0: the answer ended 1 bytes into a value that needs 5"
        );
    }
}
