use convert_case::{Boundary, Case, Casing};
use core::fmt;
use serde::Serialize;
use std::fmt::Display;

use super::human_config::ColumnNameFormat;
use crate::utils::text::Capitalize;

#[derive(Debug, PartialEq, Clone)]
pub enum Primitive {
    Boolean,
    String,
    Int32,
    BigInt { precision: Option<u32> },
    BigDecimal(Option<(u32, u32)>), // (precision, scale)
    Number,
    Serial,
    Json,
    Date,
    Enum(String),
}

impl Primitive {
    pub fn get_res_field_type_variant(&self) -> String {
        match &self {
            Self::Boolean => "Boolean".to_string(),
            Self::String => "String".to_string(),
            Self::Int32 => "Int32".to_string(),
            Self::BigInt { precision: None } => "BigInt({})".to_string(),
            Self::BigInt {
                precision: Some(precision),
            } => {
                format!("BigInt({{precision: {precision}}})")
            }
            Self::BigDecimal(None) => "BigDecimal({})".to_string(),
            Self::BigDecimal(Some((precision, scale))) => {
                format!("BigDecimal({{config: ({precision}, {scale})}})")
            }
            Self::Serial => "Serial".to_string(),
            Self::Json => "Json".to_string(),
            Self::Date => "Date".to_string(),
            Self::Number => "Number".to_string(),
            Self::Enum(enum_name) => {
                let capitalized_enum_name = enum_name.capitalize();
                format!("Enum({{config: Enums.{capitalized_enum_name}.config->Table.fromGenericEnumConfig}})")
            }
        }
    }
}

impl Serialize for Primitive {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        self.to_string().serialize(serializer)
    }
}

impl Display for Primitive {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.get_res_field_type_variant())
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct Field {
    pub field_name: String,
    pub linked_entity: Option<String>,
    pub is_index: bool,
    pub is_primary_key: bool,
    pub is_nullable: bool,
    pub is_array: bool,
    pub field_type: Primitive,
    pub description: Option<String>,
}

impl Field {
    pub fn db_column_name(&self, column_name_format: ColumnNameFormat) -> String {
        let base = match column_name_format {
            ColumnNameFormat::Original => self.field_name.clone(),
            ColumnNameFormat::SnakeCase => to_snake_case(&self.field_name),
        };
        if self.linked_entity.is_some() {
            format!("{base}_id")
        } else {
            base
        }
    }
}

// Deviates from convert_case's default boundaries in two ways: underscores
// the user wrote are kept verbatim rather than treated as word separators
// (_foo -> _foo, foo__bar -> foo__bar), and digits stay attached to the word
// before them, matching how identifiers like erc20 read: balanceERC20 ->
// balance_erc20 (not balance_erc_20), field1 -> field1, while still
// splitting before a word that starts after a digit: erc20Balance ->
// erc20_balance.
pub fn to_snake_case(name: &str) -> String {
    name.with_boundaries(&[
        Boundary::LowerUpper,
        Boundary::Acronym,
        Boundary::DigitUpper,
    ])
    .to_case(Case::Snake)
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn snake_case_conversion() {
        let cases = [
            ("tokenId", "token_id"),
            ("tokenID", "token_id"),
            ("myURLValue", "my_url_value"),
            // Digits stick to the word before them
            ("field1", "field1"),
            ("erc20Balance", "erc20_balance"),
            ("balanceERC20", "balance_erc20"),
            ("token2Sale", "token2_sale"),
            // Already snake_case names pass through unchanged
            ("token_id", "token_id"),
            ("envio_change", "envio_change"),
            ("id", "id"),
            // Underscores the user wrote are kept verbatim, never split,
            // dropped, or squashed
            ("_foo", "_foo"),
            ("foo_", "foo_"),
            ("foo__bar", "foo__bar"),
            ("_", "_"),
            ("x_X", "x_x"),
            ("fooBar_baz", "foo_bar_baz"),
            ("FOO_BAR", "foo_bar"),
        ];
        for (input, expected) in cases {
            assert_eq!(to_snake_case(input), expected, "snake_case of {input}");
        }
    }

    #[test]
    fn db_column_name_appends_id_suffix_after_conversion() {
        let field = |linked_entity: Option<String>| Field {
            field_name: "tokenOwner".to_string(),
            linked_entity,
            is_index: false,
            is_primary_key: false,
            is_nullable: false,
            is_array: false,
            field_type: Primitive::String,
            description: None,
        };
        assert_eq!(
            field(Some("User".to_string())).db_column_name(ColumnNameFormat::SnakeCase),
            "token_owner_id"
        );
        assert_eq!(
            field(Some("User".to_string())).db_column_name(ColumnNameFormat::Original),
            "tokenOwner_id"
        );
        assert_eq!(
            field(None).db_column_name(ColumnNameFormat::SnakeCase),
            "token_owner"
        );
    }
}
