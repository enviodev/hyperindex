use std::fmt;

use anyhow::{bail, Result};

use crate::config_parsing::system_config::ChainIdMode;

/// How wide an `Enum` column's variant list can get before it needs two bytes.
/// ClickHouse's `Enum8` spans -128..=127, but envio numbers from 1, so 127 is
/// what a one-byte column holds.
const MAX_ENUM8_VARIANTS: usize = 127;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChType {
    Int32,
    Int64,
    UInt32,
    UInt64,
    Float64,
    Bool,
    String,
    /// Milliseconds since the epoch. The precision is fixed at 3 rather than
    /// carried: `Date` is the only field type that lands here and JS measures
    /// time in milliseconds, so a column of any other precision would silently
    /// read back off by a factor of ten per digit.
    DateTime64,
    Decimal {
        precision: u32,
        scale: u32,
    },
    /// Variants in the order they are numbered: RowBinary carries a variant's
    /// number rather than its name, and the number is its position.
    Enum {
        variants: Vec<String>,
    },
    Nullable(Box<ChType>),
    Array(Box<ChType>),
}

/// Past this many digits ClickHouse needs a 256-bit Decimal, which is wider
/// than the `i128` the encoder carries — so envio stores those as `String`.
pub const MAX_DECIMAL_PRECISION: u32 = 38;

impl ChType {
    pub fn enum_value(&self, name: &str) -> Option<i16> {
        match self {
            ChType::Enum { variants } => variants
                .iter()
                .position(|variant| variant == name)
                .map(|index| index as i16 + 1),
            _ => None,
        }
    }

    pub fn enum_bytes(variants: &[String]) -> usize {
        if variants.len() <= MAX_ENUM8_VARIANTS {
            1
        } else {
            2
        }
    }
}

/// Bytes ClickHouse uses for a `Decimal` of the given precision. Every Decimal
/// the derivation produces is capped at [`MAX_DECIMAL_PRECISION`], so the
/// 256-bit width never comes up and the value always fits the `i128` carrying it.
pub fn decimal_bytes(precision: u32) -> Result<usize> {
    match precision {
        1..=9 => Ok(4),
        10..=18 => Ok(8),
        19..=MAX_DECIMAL_PRECISION => Ok(16),
        other => bail!("unsupported Decimal precision {other}"),
    }
}

#[derive(Debug, Clone)]
pub struct FieldSpec {
    pub field_type: String,
    pub is_nullable: bool,
    pub is_array: bool,
    pub precision: Option<u32>,
    pub scale: Option<u32>,
    pub enum_variants: Option<Vec<String>>,
}

/// The Decimal a bounded numeric field fits in, or `String` when no Decimal is
/// wide enough. Deciding on [`decimal_bytes`] rather than on the precision
/// bound is what makes every `Decimal` this returns one the encoder has a width
/// for. A scale past the precision has no Decimal either: ClickHouse requires
/// `S <= P`.
fn decimal_or_string(precision: Option<u32>, scale: u32) -> ChType {
    match precision {
        Some(precision) if decimal_bytes(precision).is_ok() && scale <= precision => {
            ChType::Decimal { precision, scale }
        }
        _ => ChType::String,
    }
}

/// Whether a bounded numeric field lands in a `String` column rather than a
/// `Decimal` — the case that sorts lexicographically instead of numerically, so
/// sorting-key validation has to refuse it. Shares [`decimal_or_string`] with
/// the type derivation, which is what keeps the two from disagreeing about a
/// precision neither bound mentions.
pub fn stored_as_string(precision: Option<u32>, scale: u32) -> bool {
    matches!(decimal_or_string(precision, scale), ChType::String)
}

impl FieldSpec {
    pub fn ch_type(&self, chain_id_mode: ChainIdMode) -> Result<ChType> {
        let base = match self.field_type.as_str() {
            "String" | "Json" => ChType::String,
            "Boolean" => ChType::Bool,
            "Uint32" => ChType::UInt32,
            "UInt52" | "UInt64" => ChType::UInt64,
            "Int32" | "Serial" => ChType::Int32,
            "BigSerial" => ChType::Int64,
            "Number" => ChType::Float64,
            "Date" => ChType::DateTime64,
            "ChainId" => match chain_id_mode {
                ChainIdMode::Int32 => ChType::Int32,
                ChainIdMode::Int64 => ChType::UInt64,
            },
            "BigInt" => decimal_or_string(self.precision, 0),
            "BigDecimal" => match (self.precision, self.scale) {
                (Some(precision), Some(scale)) => decimal_or_string(Some(precision), scale),
                _ => ChType::String,
            },
            "Enum" => {
                let variants = self.enum_variants.clone().unwrap_or_default();
                if variants.is_empty() {
                    bail!("an Enum field has no variants");
                }
                if variants.len() > i16::MAX as usize {
                    bail!("an Enum field has {} variants, more than a ClickHouse Enum16 column can number", variants.len());
                }
                ChType::Enum { variants }
            }
            other => bail!("unsupported field type `{other}`"),
        };
        if self.is_array {
            // ClickHouse refuses `Nullable(Array(T))` outright, so a nullable
            // list has nowhere to go: the alternatives both lose the
            // distinction the schema drew — an absent list would come back as
            // an empty one, or every element would become nullable.
            if self.is_nullable {
                bail!(
                    "a nullable list has no ClickHouse type: `Nullable(Array(...))` is not a \
                     type ClickHouse accepts. Make the field a non-null list (`[T!]!`) to \
                     store it here"
                );
            }
            return Ok(ChType::Array(Box::new(base)));
        }
        // A Json column holds the document's text, and JSON carries a `null` of
        // its own — so a nullable one would give the field two ways to say
        // nothing, only one of which reads back as a document.
        Ok(if self.is_nullable && self.field_type != "Json" {
            ChType::Nullable(Box::new(base))
        } else {
            base
        })
    }
}

impl fmt::Display for ChType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ChType::Int32 => f.write_str("Int32"),
            ChType::Int64 => f.write_str("Int64"),
            ChType::UInt32 => f.write_str("UInt32"),
            ChType::UInt64 => f.write_str("UInt64"),
            ChType::Float64 => f.write_str("Float64"),
            ChType::Bool => f.write_str("Bool"),
            ChType::String => f.write_str("String"),
            ChType::DateTime64 => f.write_str("DateTime64(3, 'UTC')"),
            ChType::Decimal { precision, scale } => write!(f, "Decimal({precision},{scale})"),
            ChType::Enum { variants } => {
                let width = if ChType::enum_bytes(variants) == 1 {
                    8
                } else {
                    16
                };
                write!(f, "Enum{width}(")?;
                for (index, variant) in variants.iter().enumerate() {
                    if index > 0 {
                        f.write_str(", ")?;
                    }
                    // Numbered explicitly: RowBinary carries the number, so
                    // leaving it to ClickHouse's own numbering would make the
                    // encoder depend on a server rule rather than on this text.
                    write!(f, "{} = {}", super::literal(variant), index + 1)?;
                }
                f.write_str(")")
            }
            ChType::Nullable(inner) => write!(f, "Nullable({inner})"),
            ChType::Array(inner) => write!(f, "Array({inner})"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnKind {
    F64 = 0,
    U64 = 1,
    I64 = 2,
    Text = 3,
}

impl ChType {
    pub fn column_kind(&self) -> ColumnKind {
        match self {
            ChType::Nullable(inner) => inner.column_kind(),
            ChType::Int32
            | ChType::UInt32
            | ChType::Float64
            | ChType::Bool
            | ChType::DateTime64 => ColumnKind::F64,
            ChType::UInt64 => ColumnKind::U64,
            ChType::Int64 => ColumnKind::I64,
            ChType::String | ChType::Decimal { .. } | ChType::Enum { .. } | ChType::Array(_) => {
                ColumnKind::Text
            }
        }
    }
}

#[cfg(test)]
pub(crate) mod test_support {
    use super::*;

    pub fn field(field_type: &str) -> FieldSpec {
        FieldSpec {
            field_type: field_type.to_string(),
            is_nullable: false,
            is_array: false,
            precision: None,
            scale: None,
            enum_variants: None,
        }
    }

    pub fn rendered(spec: &FieldSpec) -> String {
        spec.ch_type(ChainIdMode::Int32).unwrap().to_string()
    }

    pub fn parse_type(text: &str) -> ChType {
        let text = text.trim();
        let Some((name, args)) = text.split_once('(').map(|(name, rest)| {
            (
                name,
                rest.strip_suffix(')')
                    .expect("a parenthesised type ends in )"),
            )
        }) else {
            return match text {
                "Int32" => ChType::Int32,
                "Int64" => ChType::Int64,
                "UInt32" => ChType::UInt32,
                "UInt64" => ChType::UInt64,
                "Float64" => ChType::Float64,
                "Bool" => ChType::Bool,
                "String" => ChType::String,
                other => panic!("test type `{other}` is not one the DDL emits"),
            };
        };
        match name {
            "Nullable" => ChType::Nullable(Box::new(parse_type(args))),
            "Array" => ChType::Array(Box::new(parse_type(args))),
            "DateTime64" => ChType::DateTime64,
            "Decimal" => {
                let (precision, scale) = args.split_once(',').expect("Decimal(P, S)");
                ChType::Decimal {
                    precision: precision.trim().parse().unwrap(),
                    scale: scale.trim().parse().unwrap(),
                }
            }
            "Enum8" | "Enum16" => ChType::Enum {
                variants: parse_enum_variants(args),
            },
            other => panic!("test type `{other}` is not one the DDL emits"),
        }
    }

    fn parse_enum_variants(args: &str) -> Vec<String> {
        let mut variants = Vec::new();
        let mut chars = args.chars().peekable();
        while let Some(character) = chars.next() {
            if character != '\'' {
                continue;
            }
            let mut variant = String::new();
            loop {
                match chars.next().expect("a variant literal is closed") {
                    '\\' => variant.push(chars.next().expect("an escape carries a character")),
                    '\'' if chars.peek() == Some(&'\'') => {
                        chars.next();
                        variant.push('\'');
                    }
                    '\'' => break,
                    other => variant.push(other),
                }
            }
            variants.push(variant);
        }
        variants
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::*;
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn every_field_type_renders_its_column_type() {
        let rendered_types = [
            "String",
            "Json",
            "Boolean",
            "Uint32",
            "UInt52",
            "UInt64",
            "Int32",
            "Serial",
            "BigSerial",
            "Number",
            "Date",
        ]
        .map(|field_type| rendered(&field(field_type)));
        assert_eq!(
            rendered_types,
            [
                "String",
                "String",
                "Bool",
                "UInt32",
                "UInt64",
                "UInt64",
                "Int32",
                "Int32",
                "Int64",
                "Float64",
                "DateTime64(3, 'UTC')",
            ]
        );
    }

    #[test]
    fn a_date_column_is_always_millisecond_precision() {
        assert_eq!(rendered(&field("Date")), "DateTime64(3, 'UTC')");
    }

    #[test]
    fn chain_id_follows_the_configured_mode() {
        let modes = [ChainIdMode::Int32, ChainIdMode::Int64]
            .map(|mode| field("ChainId").ch_type(mode).unwrap().to_string());
        assert_eq!(modes, ["Int32", "UInt64"]);
    }

    #[test]
    fn rejects_a_nullable_list() {
        let error = FieldSpec {
            is_array: true,
            is_nullable: true,
            ..field("String")
        }
        .ch_type(ChainIdMode::Int32)
        .unwrap_err();
        assert_eq!(
            error.to_string(),
            "a nullable list has no ClickHouse type: `Nullable(Array(...))` is not a type \
             ClickHouse accepts. Make the field a non-null list (`[T!]!`) to store it here"
        );
    }

    #[test]
    fn a_nullable_json_column_still_holds_the_documents_text() {
        let types = ["Json", "String"].map(|field_type| {
            rendered(&FieldSpec {
                is_nullable: true,
                ..field(field_type)
            })
        });
        assert_eq!(types, ["String", "Nullable(String)"]);
    }

    #[test]
    fn wraps_a_non_null_list_in_array() {
        let spec = FieldSpec {
            is_array: true,
            ..field("String")
        };
        assert_eq!(rendered(&spec), "Array(String)");
    }

    #[test]
    fn numeric_precision_decides_decimal_or_string() {
        let rendered_types = [
            FieldSpec {
                precision: Some(38),
                ..field("BigInt")
            },
            FieldSpec {
                precision: Some(39),
                ..field("BigInt")
            },
            FieldSpec {
                precision: Some(0),
                ..field("BigInt")
            },
            field("BigInt"),
            FieldSpec {
                precision: Some(10),
                scale: Some(8),
                ..field("BigDecimal")
            },
            FieldSpec {
                precision: Some(39),
                scale: Some(2),
                ..field("BigDecimal")
            },
            FieldSpec {
                precision: Some(10),
                scale: Some(11),
                ..field("BigDecimal")
            },
            field("BigDecimal"),
        ]
        .map(|spec| rendered(&spec));
        assert_eq!(
            rendered_types,
            [
                "Decimal(38,0)",
                "String",
                "String",
                "String",
                "Decimal(10,8)",
                "String",
                "String",
                "String",
            ]
        );
    }

    /// The sorting-key validator refuses what stores as a String, so the two
    /// have to agree on every precision — including the ones outside
    /// `decimal_bytes`, which a plain `precision <= 38` bound reads as numeric.
    #[test]
    fn the_sorting_key_predicate_agrees_with_the_column_it_renders() {
        let cases = [
            (Some(38), 0),
            (Some(39), 0),
            (Some(0), 0),
            (None, 0),
            (Some(10), 8),
            (Some(10), 11),
        ];
        let rendered_as_string = cases.map(|(precision, scale)| {
            rendered(&FieldSpec {
                precision,
                scale: Some(scale),
                ..field("BigDecimal")
            }) == "String"
        });

        assert_eq!(
            cases.map(|(precision, scale)| stored_as_string(precision, scale)),
            rendered_as_string
        );
    }

    #[test]
    fn enum_numbering_matches_between_ddl_and_encoder() {
        let ch_type = FieldSpec {
            enum_variants: Some(vec!["SET".to_string(), "DELETE".to_string()]),
            ..field("Enum")
        }
        .ch_type(ChainIdMode::Int32)
        .unwrap();
        assert_eq!(
            (
                ch_type.to_string(),
                ch_type.enum_value("SET"),
                ch_type.enum_value("DELETE"),
                ch_type.enum_value("MISSING")
            ),
            (
                "Enum8('SET' = 1, 'DELETE' = 2)".to_string(),
                Some(1),
                Some(2),
                None
            )
        );
    }

    #[test]
    fn a_variant_list_past_enum8_widens_to_enum16() {
        let widths = [127, 128].map(|count| {
            let variants: Vec<String> = (0..count).map(|i| format!("V{i}")).collect();
            let bytes = ChType::enum_bytes(&variants);
            let rendered = FieldSpec {
                enum_variants: Some(variants),
                ..field("Enum")
            }
            .ch_type(ChainIdMode::Int32)
            .unwrap()
            .to_string();
            (bytes, rendered.starts_with("Enum16("))
        });
        assert_eq!(widths, [(1, false), (2, true)]);
    }

    #[test]
    fn escapes_a_quote_or_backslash_in_a_variant_name() {
        let ch_type = FieldSpec {
            enum_variants: Some(vec!["it's".to_string(), "back\\slash".to_string()]),
            ..field("Enum")
        }
        .ch_type(ChainIdMode::Int32)
        .unwrap();
        assert_eq!(
            ch_type.to_string(),
            r"Enum8('it''s' = 1, 'back\\slash' = 2)"
        );
    }

    #[test]
    fn rejects_an_enum_with_no_variants() {
        let error = FieldSpec {
            enum_variants: Some(vec![]),
            ..field("Enum")
        }
        .ch_type(ChainIdMode::Int32)
        .unwrap_err();
        assert_eq!(error.to_string(), "an Enum field has no variants");
    }

    #[test]
    fn rejects_a_field_type_the_mapping_does_not_cover() {
        let error = field("Tuple").ch_type(ChainIdMode::Int32).unwrap_err();
        assert_eq!(error.to_string(), "unsupported field type `Tuple`");
    }

    #[test]
    fn precision_fixes_the_backing_width() {
        let widths = [9u32, 10, 18, 19, 38].map(|precision| decimal_bytes(precision).unwrap());
        assert_eq!(widths, [4, 8, 8, 16, 16]);
    }

    #[test]
    fn column_kind_follows_the_type() {
        let kinds = [
            field("Int32"),
            field("UInt64"),
            FieldSpec {
                is_nullable: true,
                ..field("String")
            },
            FieldSpec {
                is_array: true,
                ..field("String")
            },
            field("Date"),
            field("BigSerial"),
        ]
        .map(|spec| spec.ch_type(ChainIdMode::Int32).unwrap().column_kind());
        assert_eq!(
            kinds,
            [
                ColumnKind::F64,
                ColumnKind::U64,
                ColumnKind::Text,
                ColumnKind::Text,
                ColumnKind::F64,
                ColumnKind::I64,
            ]
        );
    }
}
