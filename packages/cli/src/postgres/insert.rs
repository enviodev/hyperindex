//! The two statements a batch of rows is inserted with.
//!
//! Which one a table takes is decided by what it holds, not by preference: a
//! table with an array column cannot be unnested, because unnesting an array
//! spreads it across the rows instead of keeping it as one value.

use super::ddl::{ColumnSpec, TableSpec};
use super::pg_type::{pg_field_type, ChainIdMode, FieldType};

/// How a column's array of values is cast in an `unnest`.
///
/// Two types are not handed over as themselves. An enum array is sent as text
/// and cast, since the driver has no way to name a type it did not create; a
/// boolean array is sent as integers, which is what the driver being replaced
/// bound them as.
fn unnest_cast(column: &ColumnSpec, pg_schema: &str, chain_id_mode: ChainIdMode) -> String {
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
        FieldType::Boolean => format!("INTEGER[]::{array_type}"),
        _ => array_type,
    }
}

fn quoted_names(columns: &[ColumnSpec]) -> Vec<String> {
    columns
        .iter()
        .map(|column| format!("\"{}\"", column.name))
        .collect()
}

/// What an insert does with a row whose primary key is already there.
///
/// Nothing, when there is no key to conflict on or the caller says the rows are
/// append-only; otherwise every column outside the key is overwritten. A key
/// with no other column beside it has nothing to overwrite, so the conflict is
/// taken and ignored.
fn on_conflict(columns: &[ColumnSpec], append_only: bool) -> String {
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
        .map(|column| format!("\"{0}\" = EXCLUDED.\"{0}\"", column.name))
        .collect::<Vec<_>>();
    let action = if updates.is_empty() {
        "NOTHING".to_string()
    } else {
        format!("UPDATE SET {}", updates.join(","))
    };
    format!("ON CONFLICT({}) DO {action}", primary_key.join(","))
}

/// `INSERT ... SELECT * FROM unnest(...)`: one array parameter per column,
/// which is the whole batch in as many parameters as the table has columns.
pub fn unnest_query(
    spec: &TableSpec,
    pg_schema: &str,
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
    format!(
        "INSERT INTO \"{pg_schema}\".\"{}\" ({})\nSELECT * FROM unnest({}){};",
        spec.table_name,
        quoted_names(&spec.columns).join(", "),
        arrays.join(","),
        on_conflict(&spec.columns, append_only)
    )
}

/// `INSERT ... VALUES (...), (...)`: every cell its own parameter.
///
/// The placeholders are numbered column by column rather than row by row —
/// every row's first column, then every row's second — because that is the
/// order the values are bound in.
pub fn values_query(spec: &TableSpec, pg_schema: &str, rows: usize) -> String {
    let columns = spec.columns.len();
    let placeholders = (1..=rows)
        .map(|row| {
            let cells = (0..columns)
                .map(|column| format!("${}", column * rows + row))
                .collect::<Vec<_>>();
            format!("({})", cells.join(","))
        })
        .collect::<Vec<_>>();
    format!(
        "INSERT INTO \"{pg_schema}\".\"{}\" ({})\nVALUES{}{};",
        spec.table_name,
        quoted_names(&spec.columns).join(", "),
        placeholders.join(","),
        on_conflict(&spec.columns, false)
    )
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
            unnest_query(&spec, "test_schema", false, ChainIdMode::Int32),
            "INSERT INTO \"test_schema\".\"A\" (\"id\", \"flag\", \"kind\", \"at\")\n\
             SELECT * FROM unnest($1::TEXT[],$2::INTEGER[]::BOOLEAN[],\
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
            unnest_query(&spec, "s", true, ChainIdMode::Int32),
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
            unnest_query(&spec, "s", false, ChainIdMode::Int32),
            "INSERT INTO \"s\".\"A\" (\"id\")\nSELECT * FROM unnest($1::TEXT[])\
             ON CONFLICT(\"id\") DO NOTHING;"
        );
    }

    #[test]
    fn a_table_with_no_key_has_no_conflict_to_resolve() {
        let spec = table(vec![column("n", FieldType::Int32)]);
        assert_eq!(
            unnest_query(&spec, "s", false, ChainIdMode::Int32),
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
            values_query(&spec, "test_schema", 2),
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
            values_query(&spec, "test_schema", 1),
            "INSERT INTO \"test_schema\".\"A\" (\"id\", \"c_id\")\n\
             VALUES($1,$2)ON CONFLICT(\"id\") DO UPDATE SET \"c_id\" = EXCLUDED.\"c_id\";"
        );
    }
}
