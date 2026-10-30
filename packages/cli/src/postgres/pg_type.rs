pub use crate::config_parsing::system_config::ChainIdMode;

pub use crate::storage::schema::FieldType;

const NUMERIC: &str = "NUMERIC";
const TEXT: &str = "TEXT";

/// The column type as it is written into DDL.
///
/// `is_numeric_array_as_text` is the Hasura workaround from issue #788: Hasura
/// cannot read a `numeric[]`, so a schema tracked by it stores those as `text[]`
/// instead. It applies to arrays alone — a scalar `numeric` it reads fine.
pub fn pg_field_type(
    field_type: &FieldType,
    pg_schema: &str,
    is_array: bool,
    is_nullable: bool,
    is_numeric_array_as_text: bool,
    chain_id_mode: ChainIdMode,
) -> String {
    let column_type = match field_type {
        FieldType::String => TEXT.to_string(),
        FieldType::Boolean => "BOOLEAN".to_string(),
        FieldType::Int32 => "INTEGER".to_string(),
        FieldType::ChainId => match chain_id_mode {
            ChainIdMode::Int32 => "INTEGER".to_string(),
            ChainIdMode::Int64 => "BIGINT".to_string(),
        },
        FieldType::Uint32 | FieldType::UInt52 | FieldType::UInt64 => "BIGINT".to_string(),
        FieldType::SmallInt => "SMALLINT".to_string(),
        FieldType::Bytea => "BYTEA".to_string(),
        FieldType::Number => "DOUBLE PRECISION".to_string(),
        // Scale is always 0 for a BigInt: it holds whole numbers.
        FieldType::BigInt { precision } => match precision {
            Some(precision) => format!("{NUMERIC}({precision}, 0)"),
            None => NUMERIC.to_string(),
        },
        FieldType::BigDecimal { config } => match config {
            Some((precision, scale)) => format!("{NUMERIC}({precision}, {scale})"),
            None => NUMERIC.to_string(),
        },
        FieldType::Serial => "SERIAL".to_string(),
        FieldType::BigSerial => "BIGSERIAL".to_string(),
        FieldType::Json => "JSONB".to_string(),
        // The `NULL` says the column takes one, which a column already does
        // unless told otherwise — but it is what the schemas in the wild were
        // created with, so it stays. Not on an array: there the type names the
        // element, and `TIMESTAMP WITH TIME ZONE NULL[]` is not a type at all.
        FieldType::Date => if is_nullable && !is_array {
            "TIMESTAMP WITH TIME ZONE NULL"
        } else {
            "TIMESTAMP WITH TIME ZONE"
        }
        .to_string(),
        FieldType::Enum { name, .. } => format!("\"{pg_schema}\".{name}"),
    };

    let column_type = if column_type == NUMERIC && is_array && is_numeric_array_as_text {
        TEXT.to_string()
    } else {
        column_type
    };

    if is_array {
        format!("{column_type}[]")
    } else {
        column_type
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn render(field_type: &FieldType, is_array: bool, is_nullable: bool) -> String {
        pg_field_type(
            field_type,
            "public",
            is_array,
            is_nullable,
            false,
            ChainIdMode::Int32,
        )
    }

    #[test]
    fn scalars_render_their_column_type() {
        assert_eq!(
            (
                render(&FieldType::String, false, false),
                render(&FieldType::Bytea, false, false),
                render(&FieldType::Number, false, false),
                render(&FieldType::Json, false, false),
                render(&FieldType::SmallInt, false, false),
                render(&FieldType::Serial, false, false),
                render(&FieldType::BigSerial, false, false),
            ),
            (
                "TEXT".to_string(),
                "BYTEA".to_string(),
                "DOUBLE PRECISION".to_string(),
                "JSONB".to_string(),
                "SMALLINT".to_string(),
                "SERIAL".to_string(),
                "BIGSERIAL".to_string(),
            )
        );
    }

    #[test]
    fn every_unsigned_width_shares_bigint() {
        assert_eq!(
            (
                render(&FieldType::Uint32, false, false),
                render(&FieldType::UInt52, false, false),
                render(&FieldType::UInt64, false, false),
                render(&FieldType::Int32, false, false),
            ),
            (
                "BIGINT".to_string(),
                "BIGINT".to_string(),
                "BIGINT".to_string(),
                "INTEGER".to_string(),
            )
        );
    }

    #[test]
    fn a_chain_id_widens_with_its_mode() {
        assert_eq!(
            (
                pg_field_type(
                    &FieldType::ChainId,
                    "public",
                    false,
                    false,
                    false,
                    ChainIdMode::Int32
                ),
                pg_field_type(
                    &FieldType::ChainId,
                    "public",
                    false,
                    false,
                    false,
                    ChainIdMode::Int64
                ),
            ),
            ("INTEGER".to_string(), "BIGINT".to_string())
        );
    }

    #[test]
    fn precision_and_scale_render_only_when_configured() {
        assert_eq!(
            (
                render(&FieldType::BigInt { precision: None }, false, false),
                render(
                    &FieldType::BigInt {
                        precision: Some(76)
                    },
                    false,
                    false
                ),
                render(&FieldType::BigDecimal { config: None }, false, false),
                render(
                    &FieldType::BigDecimal {
                        config: Some((10, 8))
                    },
                    false,
                    false
                ),
            ),
            (
                "NUMERIC".to_string(),
                "NUMERIC(76, 0)".to_string(),
                "NUMERIC".to_string(),
                "NUMERIC(10, 8)".to_string(),
            )
        );
    }

    #[test]
    fn a_nullable_date_carries_null_in_its_type_but_an_array_of_them_does_not() {
        assert_eq!(
            (
                render(&FieldType::Date, false, false),
                render(&FieldType::Date, false, true),
                render(&FieldType::Date, true, true),
            ),
            (
                "TIMESTAMP WITH TIME ZONE".to_string(),
                "TIMESTAMP WITH TIME ZONE NULL".to_string(),
                "TIMESTAMP WITH TIME ZONE[]".to_string(),
            )
        );
    }

    #[test]
    fn an_enum_is_qualified_by_its_schema() {
        assert_eq!(
            (
                render(
                    &FieldType::Enum {
                        name: "AccountType".to_string(),
                        variants: vec![],
                    },
                    false,
                    false
                ),
                render(
                    &FieldType::Enum {
                        name: "AccountType".to_string(),
                        variants: vec![],
                    },
                    true,
                    false
                ),
            ),
            (
                "\"public\".AccountType".to_string(),
                "\"public\".AccountType[]".to_string(),
            )
        );
    }

    /// Only an unqualified `NUMERIC` becomes text, and only as an array: a
    /// precision makes the type `NUMERIC(p, s)`, which the workaround leaves
    /// alone, and a scalar is read fine either way.
    #[test]
    fn hasura_reads_a_numeric_array_as_text() {
        let as_text = |field_type, is_array| {
            pg_field_type(
                field_type,
                "public",
                is_array,
                false,
                true,
                ChainIdMode::Int32,
            )
        };
        assert_eq!(
            (
                as_text(&FieldType::BigInt { precision: None }, true),
                as_text(&FieldType::BigInt { precision: None }, false),
                as_text(&FieldType::BigDecimal { config: None }, true),
                as_text(
                    &FieldType::BigDecimal {
                        config: Some((10, 8))
                    },
                    true
                ),
                as_text(&FieldType::String, true),
            ),
            (
                "TEXT[]".to_string(),
                "NUMERIC".to_string(),
                "TEXT[]".to_string(),
                "NUMERIC(10, 8)[]".to_string(),
                "TEXT[]".to_string(),
            )
        );
    }
}
