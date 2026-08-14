//! ClickHouse column types, parsed from the type text the caller declared the
//! column with — the same string its `CREATE TABLE` used.
//!
//! Only the types envio's DDL generates are modelled, so what the encoder has to
//! keep correct is exactly what it can be handed. An `Enum` shows why the
//! numbering has to be in the type text: RowBinary carries the variant's number
//! rather than its name. Envio writes those numbers explicitly, and an unnumbered
//! list is rejected here rather than auto-numbered — inferring them would put a
//! second copy of ClickHouse's numbering rule on the encoding side, free to drift
//! from the one the DDL wrote.

use anyhow::{anyhow, bail, Result};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChType {
    Int32,
    Int64,
    UInt32,
    UInt64,
    Float64,
    Bool,
    String,
    /// Ticks of 10^-precision seconds, stored as Int64.
    DateTime64 {
        precision: u32,
    },
    Decimal {
        /// Total digits the column accepts, which bounds the stored integer and
        /// fixes the width of the backing one.
        precision: u32,
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

/// Number of bytes ClickHouse uses for a `Decimal` of the given precision. Envio
/// falls back to `String` past 38 digits, so the 256-bit width never comes up and
/// every Decimal that reaches the encoder fits the 128-bit value it carries.
pub fn decimal_bytes(precision: u32) -> Result<usize> {
    match precision {
        1..=9 => Ok(4),
        10..=18 => Ok(8),
        19..=38 => Ok(16),
        other => bail!("unsupported Decimal precision {other}"),
    }
}

fn parse_enum_variants(args: &str) -> Result<Vec<(String, i16)>> {
    let mut variants = Vec::new();
    for arg in split_args(args) {
        let (name_part, value_part) = match find_unquoted(arg, b'=') {
            Some(i) => (arg[..i].trim(), arg[i + 1..].trim()),
            None => bail!(
                "enum variant `{arg}` has no explicit value; RowBinary carries the \
                 number, so the type text has to state it"
            ),
        };
        let name = name_part
            .strip_prefix('\'')
            .and_then(|s| s.strip_suffix('\''))
            .ok_or_else(|| anyhow!("malformed enum variant `{arg}`"))?
            .replace("\\'", "'")
            .replace("\\\\", "\\");
        variants.push((name, value_part.parse::<i16>()?));
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
            "Nullable" => Ok(ChType::Nullable(Box::new(parse(args)?))),
            "Array" => Ok(ChType::Array(Box::new(parse(args)?))),
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
                let precision: u32 = parts[0].parse()?;
                // Rejects a precision with no valid width here, so every parsed
                // Decimal has one.
                decimal_bytes(precision)?;
                Ok(ChType::Decimal {
                    precision,
                    scale: parts[1].parse()?,
                })
            }
            "Enum8" => Ok(ChType::Enum {
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
        "Int32" => Ok(ChType::Int32),
        "Int64" => Ok(ChType::Int64),
        "UInt32" => Ok(ChType::UInt32),
        "UInt64" => Ok(ChType::UInt64),
        "Float64" => Ok(ChType::Float64),
        "Bool" => Ok(ChType::Bool),
        "String" => Ok(ChType::String),
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
            ChType::Int32
            | ChType::UInt32
            | ChType::Float64
            | ChType::Bool
            | ChType::DateTime64 { .. } => ColumnKind::F64,
            ChType::UInt64 => ColumnKind::U64,
            ChType::Int64 => ColumnKind::I64,
            // An array arrives as the JSON of its elements.
            ChType::String | ChType::Decimal { .. } | ChType::Enum { .. } | ChType::Array(_) => {
                ColumnKind::Text
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn parses_scalars() {
        let parsed = ["String", "UInt64", "Bool"].map(|input| parse(input).unwrap());
        assert_eq!(parsed, [ChType::String, ChType::UInt64, ChType::Bool]);
    }

    #[test]
    fn parses_nullable_and_array() {
        assert_eq!(
            parse("Nullable(Array(String))").unwrap(),
            ChType::Nullable(Box::new(ChType::Array(Box::new(ChType::String))))
        );
    }

    #[test]
    fn parses_decimal_precision_and_scale() {
        let parsed = ["Decimal(9, 2)", "Decimal(18, 0)", "Decimal(38, 3)"]
            .map(|input| parse(input).unwrap());
        assert_eq!(
            parsed,
            [
                ChType::Decimal {
                    precision: 9,
                    scale: 2
                },
                ChType::Decimal {
                    precision: 18,
                    scale: 0
                },
                ChType::Decimal {
                    precision: 38,
                    scale: 3
                },
            ]
        );
    }

    /// The precision alone fixes the width, which is why the type does not carry
    /// it: a pair that disagreed would shift every following column on the wire.
    #[test]
    fn precision_fixes_the_backing_width() {
        let widths = [9u32, 10, 18, 19, 38].map(|precision| decimal_bytes(precision).unwrap());
        assert_eq!(widths, [4, 8, 8, 16, 16]);
    }

    /// Envio falls back to `String` past 38 digits, so a wider Decimal is a
    /// declaration the encoder should refuse rather than silently truncate.
    #[test]
    fn rejects_a_decimal_wider_than_the_value_it_carries() {
        assert_eq!(
            parse("Decimal(50, 3)").unwrap_err().to_string(),
            "unsupported Decimal precision 50"
        );
    }

    #[test]
    fn parses_enum_with_explicit_values() {
        assert_eq!(
            parse("Enum8('SET' = 1, 'DELETE' = 2)").unwrap(),
            ChType::Enum {
                bytes: 1,
                variants: vec![("SET".to_string(), 1), ("DELETE".to_string(), 2)],
            }
        );
    }

    /// Auto-numbering an unnumbered list would be a second copy of ClickHouse's
    /// own rule, which is exactly what writing the numbers into the DDL avoids.
    #[test]
    fn rejects_an_unnumbered_enum_rather_than_inferring_the_numbering() {
        assert_eq!(
            parse("Enum8('SET', 'DELETE')").unwrap_err().to_string(),
            "enum variant `'SET'` has no explicit value; RowBinary carries the number, \
             so the type text has to state it"
        );
    }

    #[test]
    fn enum_variant_may_contain_a_comma_or_paren() {
        let parsed = parse("Enum8('a,b' = 7, 'c(d)' = 9)").unwrap();
        assert_eq!(
            (parsed.enum_value("a,b"), parsed.enum_value("c(d)")),
            (Some(7), Some(9))
        );
    }

    #[test]
    fn column_kind_follows_the_type() {
        let kinds = [
            "Int32",
            "UInt64",
            "Nullable(String)",
            "Array(String)",
            "DateTime64(3, 'UTC')",
        ]
        .map(|input| parse(input).unwrap().column_kind());
        assert_eq!(
            kinds,
            [
                ColumnKind::F64,
                ColumnKind::U64,
                ColumnKind::Text,
                ColumnKind::Text,
                ColumnKind::F64
            ]
        );
    }

    /// The DDL generator emits a closed set of types; anything outside it is a
    /// column envio did not declare, and guessing at its layout would put bytes
    /// on the wire that shift every column after it.
    #[test]
    fn rejects_types_the_ddl_never_emits() {
        let errors = [
            "Tuple(String, UInt8)",
            "Int8",
            "UInt128",
            "Float32",
            "FixedString(4)",
            "Date",
            "DateTime",
            "Decimal64(4)",
            "LowCardinality(String)",
        ]
        .map(|input| parse(input).unwrap_err().to_string());
        assert_eq!(
            errors,
            [
                "unsupported ClickHouse type `Tuple`",
                "unsupported ClickHouse type `Int8`",
                "unsupported ClickHouse type `UInt128`",
                "unsupported ClickHouse type `Float32`",
                "unsupported ClickHouse type `FixedString`",
                "unsupported ClickHouse type `Date`",
                "unsupported ClickHouse type `DateTime`",
                "unsupported ClickHouse type `Decimal64`",
                "unsupported ClickHouse type `LowCardinality`",
            ]
        );
    }
}
