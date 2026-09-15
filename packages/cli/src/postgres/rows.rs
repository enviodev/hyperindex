//! Turning a result row into the JavaScript values the storage layer expects.
//!
//! The driver this replaces read every column in its text form and parsed that;
//! `tokio_postgres` asks the server for binary instead (its Bind always sends
//! result format 1). So each type is decoded from binary here and rendered into
//! the same JavaScript value the text parser produced, which is what the schemas
//! on the other side are written against. Where the two could differ — `numeric`
//! above all — the text rendering is reproduced digit for digit rather than
//! approximated through a float.
//!
//! Two of those renderings are easy to get wrong by assuming they are numbers:
//! `int8` and `numeric` both arrive as strings, because the driver only parsed
//! OIDs 21, 23, 26, 700 and 701 into JavaScript numbers and left everything else
//! as text.

use std::ffi::CString;

use anyhow::{bail, Context, Result};
use napi::bindgen_prelude::{Null, ToNapiValue, Uint8Array};
use tokio_postgres::types::{FromSql, Kind, Type};

/// A decoded column value, in the shape it will take in JavaScript.
#[derive(Debug, Clone, PartialEq)]
pub enum Cell {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Bytes(Vec<u8>),
    /// Milliseconds since the Unix epoch, becoming a `Date`.
    Timestamp(f64),
    Arr(Vec<Cell>),
    Obj(Vec<(String, Cell)>),
}

/// Days between 2000-01-01, which Postgres counts from, and the Unix epoch.
const POSTGRES_EPOCH_DAYS: i64 = 10957;
const MILLIS_PER_DAY: i64 = 86_400_000;

/// The OIDs decoded as something other than text. The driver this replaces
/// dispatched on these same numbers, and the ones absent here are the reason
/// `int8` and `numeric` come back as strings.
mod oid {
    pub const BOOL: u32 = 16;
    pub const BYTEA: u32 = 17;
    pub const INT8: u32 = 20;
    pub const INT2: u32 = 21;
    pub const INT4: u32 = 23;
    pub const JSON: u32 = 114;
    pub const OID: u32 = 26;
    pub const FLOAT4: u32 = 700;
    pub const FLOAT8: u32 = 701;
    pub const DATE: u32 = 1082;
    pub const TIMESTAMP: u32 = 1114;
    pub const TIMESTAMPTZ: u32 = 1184;
    pub const NUMERIC: u32 = 1700;
    pub const JSONB: u32 = 3802;
}
use oid::*;

const NUMERIC_POSITIVE: u16 = 0x0000;
const NUMERIC_NEGATIVE: u16 = 0x4000;
const NUMERIC_NAN: u16 = 0xC000;
const NUMERIC_POSITIVE_INFINITY: u16 = 0xD000;
const NUMERIC_NEGATIVE_INFINITY: u16 = 0xF000;

fn be_i16(raw: &[u8], at: usize) -> Result<i16> {
    let bytes = raw
        .get(at..at + 2)
        .with_context(|| format!("a value ended before its 16 bits at byte {at}"))?;
    Ok(i16::from_be_bytes([bytes[0], bytes[1]]))
}

fn be_i32(raw: &[u8], at: usize) -> Result<i32> {
    let bytes = raw
        .get(at..at + 4)
        .with_context(|| format!("a value ended before its 32 bits at byte {at}"))?;
    Ok(i32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
}

fn be_i64(raw: &[u8], at: usize) -> Result<i64> {
    let bytes = raw
        .get(at..at + 8)
        .with_context(|| format!("a value ended before its 64 bits at byte {at}"))?;
    Ok(i64::from_be_bytes([
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
    ]))
}

/// Renders `numeric` exactly as Postgres writes it in text.
///
/// The wire form is base-10000: a count of digits, the power of 10000 the first
/// of them sits at, a sign, and how many decimal places the value was declared
/// to carry. That last one is why this cannot go through a float — `1.50` and
/// `1.5` are the same number and different values, and the column stores which
/// one it was.
pub fn numeric_to_string(raw: &[u8]) -> Result<String> {
    let digit_count = be_i16(raw, 0)? as usize;
    let weight = be_i16(raw, 2)? as i32;
    let sign = be_i16(raw, 4)? as u16;
    let scale = be_i16(raw, 6)? as usize;

    match sign {
        NUMERIC_NAN => return Ok("NaN".to_string()),
        NUMERIC_POSITIVE_INFINITY => return Ok("Infinity".to_string()),
        NUMERIC_NEGATIVE_INFINITY => return Ok("-Infinity".to_string()),
        NUMERIC_POSITIVE | NUMERIC_NEGATIVE => {}
        other => bail!("`{other:#06x}` is not a numeric sign"),
    }

    let digits = (0..digit_count)
        .map(|index| be_i16(raw, 8 + index * 2))
        .collect::<Result<Vec<_>>>()?;
    let digit_at = |index: i32| -> i16 {
        if index < 0 {
            0
        } else {
            digits.get(index as usize).copied().unwrap_or(0)
        }
    };

    let mut rendered = String::new();
    if sign == NUMERIC_NEGATIVE {
        rendered.push('-');
    }

    // A negative weight puts every digit after the point, so there is no
    // integer part to write but the leading zero is still part of the number.
    if weight < 0 {
        rendered.push('0');
    } else {
        for index in 0..=weight {
            if index == 0 {
                rendered.push_str(&digit_at(index).to_string());
            } else {
                rendered.push_str(&format!("{:04}", digit_at(index)));
            }
        }
    }

    if scale > 0 {
        rendered.push('.');
        // Four decimal places arrive per digit, so the last one is usually cut
        // part way through — and a value can end before its declared scale
        // does, which is what the zero padding is for.
        let mut fraction = String::new();
        let mut index = weight + 1;
        while fraction.len() < scale {
            fraction.push_str(&format!("{:04}", digit_at(index)));
            index += 1;
        }
        rendered.push_str(&fraction[..scale]);
    }

    Ok(rendered)
}

fn decode_array(raw: &[u8], element: &Type) -> Result<Cell> {
    let dimensions = be_i32(raw, 0)? as usize;
    if dimensions == 0 {
        return Ok(Cell::Arr(Vec::new()));
    }
    let lengths = (0..dimensions)
        .map(|index| Ok(be_i32(raw, 12 + index * 8)? as usize))
        .collect::<Result<Vec<_>>>()?;

    let mut at = 12 + dimensions * 8;
    let total: usize = lengths.iter().product();
    let mut flat = Vec::with_capacity(total);
    for _ in 0..total {
        let length = be_i32(raw, at)?;
        at += 4;
        if length < 0 {
            flat.push(Cell::Null);
            continue;
        }
        let length = length as usize;
        let bytes = raw
            .get(at..at + length)
            .context("an array element ran past the end of the value")?;
        flat.push(decode(element, bytes)?);
        at += length;
    }

    // Postgres flattens a multidimensional array on the wire; the lengths say
    // where to fold it back. Every array a schema can declare is
    // one-dimensional, so this is the general case standing in for one row.
    let mut nested = flat;
    for length in lengths.iter().skip(1).rev() {
        nested = nested
            .chunks(*length)
            .map(|chunk| Cell::Arr(chunk.to_vec()))
            .collect();
    }
    Ok(Cell::Arr(nested))
}

fn json_to_cell(value: serde_json::Value) -> Cell {
    match value {
        serde_json::Value::Null => Cell::Null,
        serde_json::Value::Bool(value) => Cell::Bool(value),
        // A number past what a double holds loses precision here, exactly as it
        // did going through `JSON.parse`.
        serde_json::Value::Number(value) => Cell::Num(value.as_f64().unwrap_or(f64::NAN)),
        serde_json::Value::String(value) => Cell::Str(value),
        serde_json::Value::Array(items) => Cell::Arr(items.into_iter().map(json_to_cell).collect()),
        serde_json::Value::Object(entries) => Cell::Obj(
            entries
                .into_iter()
                .map(|(key, value)| (key, json_to_cell(value)))
                .collect(),
        ),
    }
}

pub fn decode(ty: &Type, raw: &[u8]) -> Result<Cell> {
    if let Kind::Array(element) = ty.kind() {
        return decode_array(raw, element);
    }
    Ok(match ty.oid() {
        BOOL => Cell::Bool(raw.first().copied().unwrap_or(0) != 0),
        BYTEA => Cell::Bytes(raw.to_vec()),
        INT2 => Cell::Num(f64::from(be_i16(raw, 0)?)),
        INT4 | OID => Cell::Num(f64::from(be_i32(raw, 0)?)),
        FLOAT4 => Cell::Num(f64::from(f32::from_bits(be_i32(raw, 0)? as u32))),
        FLOAT8 => Cell::Num(f64::from_bits(be_i64(raw, 0)? as u64)),
        // Not a number: a 64-bit integer does not fit one, and the driver this
        // replaces left it as text for that reason.
        INT8 => Cell::Str(be_i64(raw, 0)?.to_string()),
        NUMERIC => Cell::Str(numeric_to_string(raw)?),
        TIMESTAMP | TIMESTAMPTZ => {
            let micros = be_i64(raw, 0)?;
            Cell::Timestamp((micros / 1000 + POSTGRES_EPOCH_DAYS * MILLIS_PER_DAY) as f64)
        }
        DATE => {
            let days = i64::from(be_i32(raw, 0)?);
            Cell::Timestamp(((days + POSTGRES_EPOCH_DAYS) * MILLIS_PER_DAY) as f64)
        }
        JSON => json_to_cell(serde_json::from_slice(raw).context("a json column is not json")?),
        JSONB => {
            // One version byte, then the same text a `json` column holds.
            let (version, document) = raw.split_first().context("a jsonb column is empty")?;
            if *version != 1 {
                bail!("jsonb version {version} is not one this can read");
            }
            json_to_cell(serde_json::from_slice(document).context("a jsonb column is not json")?)
        }
        // Text, and every type an enum or a domain resolves to. The driver had
        // no parser for these either and handed back the bytes as a string.
        _ => Cell::Str(String::from_utf8(raw.to_vec()).context("a text column is not UTF-8")?),
    })
}

impl<'a> FromSql<'a> for Cell {
    fn from_sql(
        ty: &Type,
        raw: &'a [u8],
    ) -> Result<Self, Box<dyn std::error::Error + Sync + Send>> {
        Ok(decode(ty, raw)?)
    }

    fn from_sql_null(_ty: &Type) -> Result<Self, Box<dyn std::error::Error + Sync + Send>> {
        Ok(Cell::Null)
    }

    fn accepts(_ty: &Type) -> bool {
        true
    }
}

impl ToNapiValue for Cell {
    unsafe fn to_napi_value(
        raw_env: napi::sys::napi_env,
        val: Self,
    ) -> napi::Result<napi::sys::napi_value> {
        match val {
            Cell::Null => Null::to_napi_value(raw_env, Null),
            Cell::Bool(value) => bool::to_napi_value(raw_env, value),
            Cell::Num(value) => f64::to_napi_value(raw_env, value),
            Cell::Str(value) => String::to_napi_value(raw_env, value),
            Cell::Bytes(value) => Uint8Array::to_napi_value(raw_env, Uint8Array::from(value)),
            Cell::Timestamp(millis) => {
                let mut date = std::ptr::null_mut();
                let status = napi::sys::napi_create_date(raw_env, millis, &mut date);
                if status != napi::sys::Status::napi_ok {
                    return Err(napi::Error::from_reason("Failed creating a Date"));
                }
                Ok(date)
            }
            Cell::Arr(items) => Vec::<Cell>::to_napi_value(raw_env, items),
            Cell::Obj(entries) => {
                let mut object = std::ptr::null_mut();
                let status = napi::sys::napi_create_object(raw_env, &mut object);
                if status != napi::sys::Status::napi_ok {
                    return Err(napi::Error::from_reason("Failed creating an object"));
                }
                for (key, value) in entries {
                    let value = Cell::to_napi_value(raw_env, value)?;
                    let key = CString::new(key)
                        .map_err(|_| napi::Error::from_reason("a column name holds a NUL"))?;
                    let status =
                        napi::sys::napi_set_named_property(raw_env, object, key.as_ptr(), value);
                    if status != napi::sys::Status::napi_ok {
                        return Err(napi::Error::from_reason("Failed setting a property"));
                    }
                }
                Ok(object)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds the wire form of a numeric, so the renderer can be checked
    /// against values whose text Postgres is known to produce.
    fn numeric(weight: i16, sign: u16, scale: i16, digits: &[i16]) -> Vec<u8> {
        let mut raw = Vec::new();
        raw.extend_from_slice(&(digits.len() as i16).to_be_bytes());
        raw.extend_from_slice(&weight.to_be_bytes());
        raw.extend_from_slice(&(sign as i16).to_be_bytes());
        raw.extend_from_slice(&scale.to_be_bytes());
        for digit in digits {
            raw.extend_from_slice(&digit.to_be_bytes());
        }
        raw
    }

    #[test]
    fn a_numeric_renders_the_digits_postgres_stored() {
        let rendered = [
            numeric(0, NUMERIC_POSITIVE, 0, &[]),              // 0
            numeric(0, NUMERIC_POSITIVE, 0, &[100]),           // 100
            numeric(1, NUMERIC_POSITIVE, 0, &[1]),             // 10000
            numeric(0, NUMERIC_POSITIVE, 2, &[1, 2500]),       // 1.25
            numeric(-1, NUMERIC_POSITIVE, 1, &[5000]),         // 0.5
            numeric(-1, NUMERIC_POSITIVE, 4, &[1]),            // 0.0001
            numeric(1, NUMERIC_POSITIVE, 4, &[1, 2345, 6789]), // 12345.6789
            numeric(0, NUMERIC_NEGATIVE, 2, &[1, 2500]),       // -1.25
        ]
        .iter()
        .map(|raw| numeric_to_string(raw).unwrap())
        .collect::<Vec<_>>();

        assert_eq!(
            rendered,
            [
                "0",
                "100",
                "10000",
                "1.25",
                "0.5",
                "0.0001",
                "12345.6789",
                "-1.25"
            ]
        );
    }

    /// The scale is part of the value, not of how it is shown: a column
    /// declared to two places keeps both, and a float round trip would lose
    /// them.
    #[test]
    fn a_numeric_keeps_the_zeros_its_scale_declares() {
        assert_eq!(
            (
                numeric_to_string(&numeric(0, NUMERIC_POSITIVE, 2, &[])).unwrap(),
                numeric_to_string(&numeric(0, NUMERIC_POSITIVE, 2, &[1, 5000])).unwrap(),
                numeric_to_string(&numeric(0, NUMERIC_POSITIVE, 8, &[12, 1])).unwrap(),
            ),
            (
                "0.00".to_string(),
                "1.50".to_string(),
                "12.00010000".to_string(),
            )
        );
    }

    #[test]
    fn a_numeric_carries_the_values_that_are_not_numbers() {
        assert_eq!(
            (
                numeric_to_string(&numeric(0, NUMERIC_NAN, 0, &[])).unwrap(),
                numeric_to_string(&numeric(0, NUMERIC_POSITIVE_INFINITY, 0, &[])).unwrap(),
                numeric_to_string(&numeric(0, NUMERIC_NEGATIVE_INFINITY, 0, &[])).unwrap(),
            ),
            (
                "NaN".to_string(),
                "Infinity".to_string(),
                "-Infinity".to_string(),
            )
        );
    }

    /// Both are wide enough to lose digits as a double, which is why the driver
    /// left them as text.
    #[test]
    fn the_wide_integer_types_stay_text() {
        assert_eq!(
            (
                decode(&Type::INT8, &9_007_199_254_740_993i64.to_be_bytes()).unwrap(),
                decode(&Type::INT4, &42i32.to_be_bytes()).unwrap(),
                decode(&Type::INT2, &(-7i16).to_be_bytes()).unwrap(),
            ),
            (
                Cell::Str("9007199254740993".to_string()),
                Cell::Num(42.0),
                Cell::Num(-7.0),
            )
        );
    }

    #[test]
    fn the_epoch_postgres_counts_from_is_not_the_one_javascript_does() {
        assert_eq!(
            (
                decode(&Type::TIMESTAMPTZ, &0i64.to_be_bytes()).unwrap(),
                decode(&Type::DATE, &0i32.to_be_bytes()).unwrap(),
            ),
            (
                // 2000-01-01T00:00:00Z
                Cell::Timestamp(946_684_800_000.0),
                Cell::Timestamp(946_684_800_000.0),
            )
        );
    }

    #[test]
    fn a_jsonb_document_skips_its_version_byte() {
        let mut raw = vec![1u8];
        raw.extend_from_slice(br#"{"a":[1,true,null],"b":"x"}"#);
        assert_eq!(
            decode(&Type::JSONB, &raw).unwrap(),
            Cell::Obj(vec![
                (
                    "a".to_string(),
                    Cell::Arr(vec![Cell::Num(1.0), Cell::Bool(true), Cell::Null])
                ),
                ("b".to_string(), Cell::Str("x".to_string())),
            ])
        );
    }

    #[test]
    fn a_jsonb_version_this_cannot_read_is_refused() {
        assert_eq!(
            decode(&Type::JSONB, &[2u8, b'{', b'}'])
                .unwrap_err()
                .to_string(),
            "jsonb version 2 is not one this can read"
        );
    }

    fn array(element_oid: u32, elements: &[Option<&[u8]>]) -> Vec<u8> {
        let mut raw = Vec::new();
        raw.extend_from_slice(&1i32.to_be_bytes()); // one dimension
        raw.extend_from_slice(&0i32.to_be_bytes()); // no nulls flag
        raw.extend_from_slice(&element_oid.to_be_bytes());
        raw.extend_from_slice(&(elements.len() as i32).to_be_bytes());
        raw.extend_from_slice(&1i32.to_be_bytes()); // lower bound
        for element in elements {
            match element {
                None => raw.extend_from_slice(&(-1i32).to_be_bytes()),
                Some(bytes) => {
                    raw.extend_from_slice(&(bytes.len() as i32).to_be_bytes());
                    raw.extend_from_slice(bytes);
                }
            }
        }
        raw
    }

    #[test]
    fn an_array_decodes_its_elements_and_keeps_the_gaps() {
        let raw = array(
            23,
            &[Some(&1i32.to_be_bytes()), None, Some(&3i32.to_be_bytes())],
        );
        assert_eq!(
            decode(&Type::INT4_ARRAY, &raw).unwrap(),
            Cell::Arr(vec![Cell::Num(1.0), Cell::Null, Cell::Num(3.0)])
        );
    }

    #[test]
    fn an_empty_array_has_no_dimensions() {
        let mut raw = Vec::new();
        raw.extend_from_slice(&0i32.to_be_bytes());
        raw.extend_from_slice(&0i32.to_be_bytes());
        raw.extend_from_slice(&23u32.to_be_bytes());
        assert_eq!(decode(&Type::INT4_ARRAY, &raw).unwrap(), Cell::Arr(vec![]));
    }

    #[test]
    fn a_text_array_holds_its_strings() {
        let raw = array(25, &[Some(b"a"), Some(b""), Some("\u{e9}".as_bytes())]);
        assert_eq!(
            decode(&Type::TEXT_ARRAY, &raw).unwrap(),
            Cell::Arr(vec![
                Cell::Str("a".to_string()),
                Cell::Str(String::new()),
                Cell::Str("\u{e9}".to_string()),
            ])
        );
    }

    #[test]
    fn bytes_come_back_whole() {
        assert_eq!(
            decode(&Type::BYTEA, &[0xde, 0xad, 0x00, 0xbe]).unwrap(),
            Cell::Bytes(vec![0xde, 0xad, 0x00, 0xbe])
        );
    }

    #[test]
    fn a_value_that_ends_early_is_an_error_not_a_panic() {
        assert!(decode(&Type::INT8, &[0, 1]).is_err());
        assert!(numeric_to_string(&[0, 1]).is_err());
    }
}
