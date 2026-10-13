//! The two statements a batch of rows is inserted with.
//!
//! Which one a table takes is decided by what it holds, not by preference: a
//! table with an array column cannot be unnested, because unnesting an array
//! spreads it across the rows instead of keeping it as one value.

use super::ddl::{ColumnSpec, TableSpec};
use super::pg_type::{pg_field_type, ChainIdMode, FieldType};
use crate::columnar::ColumnKind;

/// Which arena slot a staged column's values travel in, and so what the
/// unnest's cast for it reads.
///
/// A boolean travels as the number 1 or 0, which Postgres reads as a boolean.
/// Everything a double cannot hold exactly — a bigint, a decimal, a timestamp —
/// travels as text, as does an enum, whose cast names the type.
pub fn staged_kind(field_type: &FieldType) -> ColumnKind {
    match field_type {
        FieldType::Boolean
        | FieldType::Int32
        | FieldType::Uint32
        | FieldType::UInt52
        | FieldType::SmallInt
        | FieldType::Number
        | FieldType::ChainId
        | FieldType::Serial
        | FieldType::BigSerial => ColumnKind::F64,
        FieldType::Bytea => ColumnKind::Bytes,
        FieldType::String
        | FieldType::UInt64
        | FieldType::BigInt { .. }
        | FieldType::BigDecimal { .. }
        | FieldType::Json
        | FieldType::Date
        | FieldType::Enum { .. } => ColumnKind::Text,
    }
}

/// How a column's array of values is cast in an `unnest`. An enum array is sent
/// as text and cast, since a parameter cannot name a type the client did not
/// create.
pub fn unnest_cast(column: &ColumnSpec, pg_schema: &str, chain_id_mode: ChainIdMode) -> String {
    let array_type = pg_field_type(
        &column.field_type,
        pg_schema,
        true,
        column.is_nullable,
        false,
        chain_id_mode,
    );
    match column.field_type {
        FieldType::Enum { .. } => format!("TEXT[]::{array_type}"),
        _ => array_type,
    }
}

/// A column every row of an insert takes the same literal for, written into
/// the statement rather than bound.
pub struct Constant<'a> {
    pub column: &'a str,
    pub literal: &'a str,
}

/// What an insert does with a row whose primary key is already there.
///
/// Nothing, when there is no key to conflict on or the caller says the rows are
/// append-only; otherwise every column outside the key is overwritten. A key
/// with no other column beside it has nothing to overwrite, so the conflict is
/// taken and ignored.
fn on_conflict(columns: &[ColumnSpec], constants: &[Constant], append_only: bool) -> String {
    let primary_key = columns
        .iter()
        .filter(|column| column.is_primary_key)
        .map(|column| format!("\"{}\"", column.name))
        .collect::<Vec<_>>();
    if append_only || primary_key.is_empty() {
        return String::new();
    }
    let updates = columns
        .iter()
        .filter(|column| !column.is_primary_key)
        .map(|column| column.name.as_str())
        .chain(constants.iter().map(|constant| constant.column))
        .map(|name| format!("\"{name}\" = EXCLUDED.\"{name}\""))
        .collect::<Vec<_>>();
    let action = if updates.is_empty() {
        "NOTHING".to_string()
    } else {
        format!("UPDATE SET {}", updates.join(","))
    };
    format!("ON CONFLICT({}) DO {action}", primary_key.join(","))
}

fn names(columns: &[ColumnSpec], constants: &[Constant]) -> String {
    columns
        .iter()
        .map(|column| format!("\"{}\"", column.name))
        .chain(
            constants
                .iter()
                .map(|constant| format!("\"{}\"", constant.column)),
        )
        .collect::<Vec<_>>()
        .join(", ")
}

/// `INSERT ... SELECT * FROM unnest(...)`: one array parameter per column,
/// which is the whole batch in as many parameters as the table has columns.
pub fn unnest_query(
    spec: &TableSpec,
    pg_schema: &str,
    constants: &[Constant],
    append_only: bool,
    chain_id_mode: ChainIdMode,
) -> String {
    let arrays = spec
        .columns
        .iter()
        .enumerate()
        .map(|(index, column)| {
            format!(
                "${}::{}",
                index + 1,
                unnest_cast(column, pg_schema, chain_id_mode)
            )
        })
        .collect::<Vec<_>>();
    let selected = std::iter::once("*")
        .chain(constants.iter().map(|constant| constant.literal))
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "INSERT INTO \"{pg_schema}\".\"{}\" ({})\nSELECT {selected} FROM unnest({}){};",
        spec.table_name,
        names(&spec.columns, constants),
        arrays.join(","),
        on_conflict(&spec.columns, constants, append_only)
    )
}

/// `INSERT ... VALUES (...), (...)`: every cell its own parameter.
///
/// The placeholders are numbered column by column rather than row by row —
/// every row's first column, then every row's second — because that is the
/// order the values are bound in.
pub fn values_query(
    spec: &TableSpec,
    pg_schema: &str,
    constants: &[Constant],
    rows: usize,
) -> String {
    let columns = spec.columns.len();
    let placeholders = (1..=rows)
        .map(|row| {
            let cells = (0..columns)
                .map(|column| format!("${}", column * rows + row))
                .chain(
                    constants
                        .iter()
                        .map(|constant| constant.literal.to_string()),
                )
                .collect::<Vec<_>>();
            format!("({})", cells.join(","))
        })
        .collect::<Vec<_>>();
    format!(
        "INSERT INTO \"{pg_schema}\".\"{}\" ({})\nVALUES{}{};",
        spec.table_name,
        names(&spec.columns, constants),
        placeholders.join(","),
        on_conflict(&spec.columns, constants, false)
    )
}

/// How many rows the statement binding a parameter per cell takes at once. The
/// wire protocol counts a statement's parameters in an unsigned 16-bit field,
/// so a wide enough table runs out of them before it runs out of rows, and the
/// server would refuse the whole statement.
pub fn values_rows_per_statement(columns: usize) -> usize {
    const MAX_ROWS: usize = 500;
    const MAX_PARAMS: usize = 65535;
    (MAX_PARAMS / columns.max(1)).clamp(1, MAX_ROWS)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn column(name: &str, field_type: FieldType) -> ColumnSpec {
        ColumnSpec {
            name: name.to_string(),
            field_type,
            is_array: false,
            is_nullable: false,
            is_primary_key: false,
            default_value: None,
        }
    }

    fn table(columns: Vec<ColumnSpec>) -> TableSpec {
        TableSpec {
            table_name: "A".to_string(),
            columns,
            partition_by_column: None,
        }
    }

    /// An enum cannot be bound as itself and a boolean was never bound as one,
    /// so both go in as something else and are cast.
    #[test]
    fn two_types_are_cast_rather_than_bound_as_themselves() {
        let spec = table(vec![
            ColumnSpec {
                is_primary_key: true,
                ..column("id", FieldType::String)
            },
            column("flag", FieldType::Boolean),
            ColumnSpec {
                is_nullable: true,
                ..column(
                    "kind",
                    FieldType::Enum {
                        name: "AccountType".to_string(),
                    },
                )
            },
            ColumnSpec {
                is_nullable: true,
                ..column("at", FieldType::Date)
            },
        ]);
        assert_eq!(
            unnest_query(&spec, "test_schema", &[], false, ChainIdMode::Int32),
            "INSERT INTO \"test_schema\".\"A\" (\"id\", \"flag\", \"kind\", \"at\")\n\
             SELECT * FROM unnest($1::TEXT[],$2::BOOLEAN[],\
             $3::TEXT[]::\"test_schema\".AccountType[],\
             $4::TIMESTAMP WITH TIME ZONE[])\
             ON CONFLICT(\"id\") DO UPDATE SET \"flag\" = EXCLUDED.\"flag\",\
             \"kind\" = EXCLUDED.\"kind\",\"at\" = EXCLUDED.\"at\";"
        );
    }

    /// Rows that are only ever appended have no conflict to resolve.
    #[test]
    fn an_append_only_table_takes_no_conflict_clause() {
        let spec = table(vec![ColumnSpec {
            is_primary_key: true,
            ..column("id", FieldType::String)
        }]);
        assert_eq!(
            unnest_query(&spec, "s", &[], true, ChainIdMode::Int32),
            "INSERT INTO \"s\".\"A\" (\"id\")\nSELECT * FROM unnest($1::TEXT[]);"
        );
    }

    /// A key with nothing beside it has nothing to overwrite, so the row that
    /// is already there is left as it is.
    #[test]
    fn a_table_that_is_all_key_updates_nothing() {
        let spec = table(vec![ColumnSpec {
            is_primary_key: true,
            ..column("id", FieldType::String)
        }]);
        assert_eq!(
            unnest_query(&spec, "s", &[], false, ChainIdMode::Int32),
            "INSERT INTO \"s\".\"A\" (\"id\")\nSELECT * FROM unnest($1::TEXT[])\
             ON CONFLICT(\"id\") DO NOTHING;"
        );
    }

    #[test]
    fn a_table_with_no_key_has_no_conflict_to_resolve() {
        let spec = table(vec![column("n", FieldType::Int32)]);
        assert_eq!(
            unnest_query(&spec, "s", &[], false, ChainIdMode::Int32),
            "INSERT INTO \"s\".\"A\" (\"n\")\nSELECT * FROM unnest($1::INTEGER[]);"
        );
    }

    /// Every row's first column, then every row's second — the order the values
    /// are bound in, not the order they are written in.
    #[test]
    fn values_are_numbered_column_by_column() {
        let spec = table(vec![
            ColumnSpec {
                is_primary_key: true,
                ..column("id", FieldType::String)
            },
            column("b_id", FieldType::String),
            ColumnSpec {
                is_nullable: true,
                ..column("optional", FieldType::String)
            },
        ]);
        assert_eq!(
            values_query(&spec, "test_schema", &[], 2),
            "INSERT INTO \"test_schema\".\"A\" (\"id\", \"b_id\", \"optional\")\n\
             VALUES($1,$3,$5),($2,$4,$6)\
             ON CONFLICT(\"id\") DO UPDATE SET \"b_id\" = EXCLUDED.\"b_id\",\
             \"optional\" = EXCLUDED.\"optional\";"
        );
    }

    #[test]
    fn one_row_numbers_its_cells_in_order() {
        let spec = table(vec![
            ColumnSpec {
                is_primary_key: true,
                ..column("id", FieldType::String)
            },
            column("c_id", FieldType::String),
        ]);
        assert_eq!(
            values_query(&spec, "test_schema", &[], 1),
            "INSERT INTO \"test_schema\".\"A\" (\"id\", \"c_id\")\n\
             VALUES($1,$2)ON CONFLICT(\"id\") DO UPDATE SET \"c_id\" = EXCLUDED.\"c_id\";"
        );
    }
}

#[cfg(test)]
mod constant_tests {
    use super::*;

    fn column(name: &str, field_type: FieldType, is_primary_key: bool) -> ColumnSpec {
        ColumnSpec {
            name: name.to_string(),
            field_type,
            is_array: false,
            is_nullable: false,
            is_primary_key,
            default_value: None,
        }
    }

    fn history() -> TableSpec {
        TableSpec {
            table_name: "envio_history_A".to_string(),
            columns: vec![
                column("id", FieldType::String, true),
                column("count", FieldType::Int32, false),
                column("envio_checkpoint_id", FieldType::UInt64, true),
            ],
            partition_by_column: None,
        }
    }

    const SET: [Constant; 1] = [Constant {
        column: "envio_change",
        literal: "'SET'",
    }];

    /// The constant is selected beside the unnested columns and overwritten
    /// with them, so a row a delete wrote at the same checkpoint becomes a set.
    #[test]
    fn a_constant_column_is_written_and_overwritten_with_the_rest() {
        assert_eq!(
            (
                unnest_query(&history(), "s", &SET, false, ChainIdMode::Int32),
                values_query(&history(), "s", &SET, 2),
            ),
            (
                "INSERT INTO \"s\".\"envio_history_A\" (\"id\", \"count\", \
                 \"envio_checkpoint_id\", \"envio_change\")\nSELECT *, 'SET' FROM \
                 unnest($1::TEXT[],$2::INTEGER[],$3::BIGINT[])ON \
                 CONFLICT(\"id\",\"envio_checkpoint_id\") DO UPDATE SET \"count\" = \
                 EXCLUDED.\"count\",\"envio_change\" = EXCLUDED.\"envio_change\";"
                    .to_string(),
                "INSERT INTO \"s\".\"envio_history_A\" (\"id\", \"count\", \
                 \"envio_checkpoint_id\", \"envio_change\")\nVALUES($1,$3,$5,'SET'),\
                 ($2,$4,$6,'SET')ON CONFLICT(\"id\",\"envio_checkpoint_id\") DO UPDATE SET \
                 \"count\" = EXCLUDED.\"count\",\"envio_change\" = EXCLUDED.\"envio_change\";"
                    .to_string(),
            )
        );
    }

    #[test]
    fn a_wide_table_takes_fewer_rows_per_statement() {
        assert_eq!(
            [2, 131, 132, 1000, 70000].map(values_rows_per_statement),
            [500, 500, 496, 65, 1]
        );
    }
}
