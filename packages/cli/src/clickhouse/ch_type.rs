//! ClickHouse column types, parsed from what the server reports in
//! `system.columns`. Reading the type back from the server rather than deriving
//! it from the schema is what makes the binary encoder safe against a table that
//! already existed: `Enum8('SET','DELETE')` is stored as
//! `Enum8('SET' = 1, 'DELETE' = 2)`, and RowBinary carries the numeric value, so
//! guessing the mapping would silently write the wrong variant.

use anyhow::{anyhow, bail, Result};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChType {
    Int8,
    Int16,
    Int32,
    Int64,
    Int128,
    UInt8,
    UInt16,
    UInt32,
    UInt64,
    UInt128,
    Float32,
    Float64,
    Bool,
    String,
    FixedString(usize),
    Uuid,
    Date,
    Date32,
    DateTime,
    /// Ticks of 10^-precision seconds, stored as Int64.
    DateTime64 {
        precision: u32,
    },
    Decimal {
        /// Width of the backing integer in bytes: 4, 8, 16 or 32.
        bytes: usize,
        scale: u32,
    },
    /// Variant name to its stored numeric value, plus the width in bytes (1 or 2).
    Enum {
        bytes: usize,
        variants: Vec<(String, i16)>,
    },
    Nullable(Box<ChType>),
    Array(Box<ChType>),
}

impl ChType {
    /// The variant's numeric value as stored by ClickHouse.
    pub fn enum_value(&self, name: &str) -> Option<i16> {
        match self {
            ChType::Enum { variants, .. } => variants
                .iter()
                .find(|(variant, _)| variant == name)
                .map(|(_, value)| *value),
            _ => None,
        }
    }
}

/// Splits `Decimal(38, 0)` / `Enum8('a' = 1, 'b' = 2)` into its outer name and
/// the argument text, respecting quoted variant names so a `(` or `,` inside a
/// label doesn't end the argument list early.
fn split_parameterized(input: &str) -> Option<(&str, &str)> {
    let open = find_unquoted(input, b'(')?;
    if !input.ends_with(')') {
        return None;
    }
    Some((input[..open].trim(), &input[open + 1..input.len() - 1]))
}

fn find_unquoted(input: &str, needle: u8) -> Option<usize> {
    let bytes = input.as_bytes();
    let mut in_quote = false;
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'\\' if in_quote => i += 1,
            b'\'' => in_quote = !in_quote,
            b if b == needle && !in_quote => return Some(i),
            _ => {}
        }
        i += 1;
    }
    None
}

fn split_args(input: &str) -> Vec<&str> {
    let bytes = input.as_bytes();
    let mut parts = Vec::new();
    let mut in_quote = false;
    let mut depth = 0usize;
    let mut start = 0usize;
    let mut i = 0usize;
    while i < bytes.len() {
        match bytes[i] {
            b'\\' if in_quote => i += 1,
            b'\'' => in_quote = !in_quote,
            b'(' if !in_quote => depth += 1,
            b')' if !in_quote => depth = depth.saturating_sub(1),
            b',' if !in_quote && depth == 0 => {
                parts.push(input[start..i].trim());
                start = i + 1;
            }
            _ => {}
        }
        i += 1;
    }
    parts.push(input[start..].trim());
    parts
}

/// Number of bytes ClickHouse uses for a `Decimal` of the given precision.
fn decimal_bytes(precision: u32) -> Result<usize> {
    match precision {
        1..=9 => Ok(4),
        10..=18 => Ok(8),
        19..=38 => Ok(16),
        39..=76 => Ok(32),
        other => bail!("unsupported Decimal precision {other}"),
    }
}

fn parse_enum_variants(args: &str) -> Result<Vec<(String, i16)>> {
    let mut variants = Vec::new();
    // ClickHouse always reports explicit values, but an unnumbered list is
    // still valid input syntax and auto-numbers from 1.
    let mut next_implicit = 1i16;
    for arg in split_args(args) {
        let (name_part, value_part) = match find_unquoted(arg, b'=') {
            Some(i) => (arg[..i].trim(), Some(arg[i + 1..].trim())),
            None => (arg, None),
        };
        let name = name_part
            .strip_prefix('\'')
            .and_then(|s| s.strip_suffix('\''))
            .ok_or_else(|| anyhow!("malformed enum variant `{arg}`"))?
            .replace("\\'", "'")
            .replace("\\\\", "\\");
        let value = match value_part {
            Some(v) => v.parse::<i16>()?,
            None => next_implicit,
        };
        next_implicit = value + 1;
        variants.push((name, value));
    }
    if variants.is_empty() {
        bail!("enum with no variants");
    }
    Ok(variants)
}

pub fn parse(input: &str) -> Result<ChType> {
    let input = input.trim();
    if let Some((name, args)) = split_parameterized(input) {
        return match name {
            // Only the inner type matters on the wire.
            "LowCardinality" | "SimpleAggregateFunction" => parse(split_args(args).last().unwrap()),
            "Nullable" => Ok(ChType::Nullable(Box::new(parse(args)?))),
            "Array" => Ok(ChType::Array(Box::new(parse(args)?))),
            "FixedString" => Ok(ChType::FixedString(args.trim().parse()?)),
            "DateTime" => Ok(ChType::DateTime),
            "DateTime64" => {
                let parts = split_args(args);
                Ok(ChType::DateTime64 {
                    precision: parts[0].trim().parse()?,
                })
            }
            "Decimal" => {
                let parts = split_args(args);
                if parts.len() != 2 {
                    bail!("Decimal expects (precision, scale), got `{args}`");
                }
                Ok(ChType::Decimal {
                    bytes: decimal_bytes(parts[0].parse()?)?,
                    scale: parts[1].parse()?,
                })
            }
            "Decimal32" | "Decimal64" | "Decimal128" | "Decimal256" => {
                let bytes = match name {
                    "Decimal32" => 4,
                    "Decimal64" => 8,
                    "Decimal128" => 16,
                    _ => 32,
                };
                Ok(ChType::Decimal {
                    bytes,
                    scale: args.trim().parse()?,
                })
            }
            "Enum" | "Enum8" => Ok(ChType::Enum {
                bytes: 1,
                variants: parse_enum_variants(args)?,
            }),
            "Enum16" => Ok(ChType::Enum {
                bytes: 2,
                variants: parse_enum_variants(args)?,
            }),
            other => bail!("unsupported ClickHouse type `{other}`"),
        };
    }

    match input {
        "Int8" => Ok(ChType::Int8),
        "Int16" => Ok(ChType::Int16),
        "Int32" => Ok(ChType::Int32),
        "Int64" => Ok(ChType::Int64),
        "Int128" => Ok(ChType::Int128),
        "UInt8" => Ok(ChType::UInt8),
        "UInt16" => Ok(ChType::UInt16),
        "UInt32" => Ok(ChType::UInt32),
        "UInt64" => Ok(ChType::UInt64),
        "UInt128" => Ok(ChType::UInt128),
        "Float32" => Ok(ChType::Float32),
        "Float64" => Ok(ChType::Float64),
        "Bool" | "Boolean" => Ok(ChType::Bool),
        "String" => Ok(ChType::String),
        "UUID" => Ok(ChType::Uuid),
        "Date" => Ok(ChType::Date),
        "Date32" => Ok(ChType::Date32),
        "DateTime" => Ok(ChType::DateTime),
        other => bail!("unsupported ClickHouse type `{other}`"),
    }
}

/// How the JS side hands a column's values across the napi boundary. Picked from
/// the ClickHouse type so both sides agree without a second type derivation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnKind {
    /// Float64Array, one element per row.
    F64 = 0,
    /// BigUint64Array.
    U64 = 1,
    /// BigInt64Array.
    I64 = 2,
    /// Concatenated text plus per-row UTF-16 lengths. Also carries the JSON of
    /// an `Array` column.
    Text = 3,
}

impl ChType {
    /// The wire kind JS must use for this column.
    pub fn column_kind(&self) -> ColumnKind {
        match self {
            ChType::Nullable(inner) => inner.column_kind(),
            ChType::Int8
            | ChType::Int16
            | ChType::Int32
            | ChType::UInt8
            | ChType::UInt16
            | ChType::UInt32
            | ChType::Float32
            | ChType::Float64
            | ChType::Bool
            | ChType::Date
            | ChType::Date32
            | ChType::DateTime
            | ChType::DateTime64 { .. } => ColumnKind::F64,
            ChType::UInt64 => ColumnKind::U64,
            ChType::Int64 => ColumnKind::I64,
            ChType::String
            | ChType::FixedString(_)
            | ChType::Uuid
            | ChType::Int128
            | ChType::UInt128
            | ChType::Decimal { .. }
            | ChType::Enum { .. } => ColumnKind::Text,
            // An array arrives as the JSON of its elements.
            ChType::Array(_) => ColumnKind::Text,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn parses_scalars() {
        assert_eq!(parse("String").unwrap(), ChType::String);
        assert_eq!(parse("UInt64").unwrap(), ChType::UInt64);
        assert_eq!(parse("Bool").unwrap(), ChType::Bool);
    }

    #[test]
    fn parses_nullable_and_array() {
        assert_eq!(
            parse("Nullable(Array(String))").unwrap(),
            ChType::Nullable(Box::new(ChType::Array(Box::new(ChType::String))))
        );
    }

    #[test]
    fn parses_decimal_widths() {
        assert_eq!(
            parse("Decimal(9, 2)").unwrap(),
            ChType::Decimal { bytes: 4, scale: 2 }
        );
        assert_eq!(
            parse("Decimal(18, 0)").unwrap(),
            ChType::Decimal { bytes: 8, scale: 0 }
        );
        assert_eq!(
            parse("Decimal(38, 0)").unwrap(),
            ChType::Decimal {
                bytes: 16,
                scale: 0
            }
        );
        assert_eq!(
            parse("Decimal64(4)").unwrap(),
            ChType::Decimal { bytes: 8, scale: 4 }
        );
    }

    #[test]
    fn parses_enum_with_server_reported_values() {
        assert_eq!(
            parse("Enum8('SET' = 1, 'DELETE' = 2)").unwrap(),
            ChType::Enum {
                bytes: 1,
                variants: vec![("SET".to_string(), 1), ("DELETE".to_string(), 2)],
            }
        );
    }

    #[test]
    fn auto_numbers_an_unnumbered_enum_from_one() {
        assert_eq!(
            parse("Enum8('SET', 'DELETE')")
                .unwrap()
                .enum_value("DELETE"),
            Some(2)
        );
    }

    #[test]
    fn enum_variant_may_contain_a_comma_or_paren() {
        let parsed = parse("Enum8('a,b' = 7, 'c(d)' = 9)").unwrap();
        assert_eq!(parsed.enum_value("a,b"), Some(7));
        assert_eq!(parsed.enum_value("c(d)"), Some(9));
    }

    #[test]
    fn unwraps_low_cardinality() {
        assert_eq!(parse("LowCardinality(String)").unwrap(), ChType::String);
    }

    #[test]
    fn column_kind_follows_the_type() {
        assert_eq!(parse("Int32").unwrap().column_kind(), ColumnKind::F64);
        assert_eq!(parse("UInt64").unwrap().column_kind(), ColumnKind::U64);
        assert_eq!(
            parse("Nullable(String)").unwrap().column_kind(),
            ColumnKind::Text
        );
        assert_eq!(
            parse("Array(String)").unwrap().column_kind(),
            ColumnKind::Text
        );
        assert_eq!(
            parse("DateTime64(3, 'UTC')").unwrap().column_kind(),
            ColumnKind::F64
        );
    }

    #[test]
    fn rejects_an_unknown_type() {
        assert!(parse("Tuple(String, UInt8)").is_err());
    }
}
