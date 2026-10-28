//! The statement a batch of rows is inserted with: one array parameter per
//! column, unnested into rows, which is the whole batch in as many parameters
//! as the table has columns.
//!
//! An array column travels as text and is cast once it is a row's own value:
//! unnesting an array of arrays would spread it across the rows instead of
//! keeping it as one value.

use super::ddl::{ColumnSpec, TableSpec};
use super::pg_type::{pg_field_type, ChainIdMode, FieldType};

/// How a column's array of values is cast in an `unnest`. An enum array is sent
/// as text and cast, since a parameter cannot name a type the client did not
/// create; a column of arrays is sent as each row's array literal.
fn unnest_cast(column: &ColumnSpec, pg_schema: &str, chain_id_mode: ChainIdMode) -> String {
    if column.is_array {
        return "TEXT[]".to_string();
    }
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

/// `INSERT ... SELECT ... FROM unnest(...)`, binding the spec's columns in
/// order.
pub fn unnest_query(
    spec: &TableSpec,
    pg_schema: &str,
    append_only: bool,
    numeric_array_as_text: bool,
    chain_id_mode: ChainIdMode,
) -> String {
    let mut names = Vec::with_capacity(spec.columns.len());
    let mut arrays = Vec::with_capacity(spec.columns.len());
    let mut selected = Vec::with_capacity(spec.columns.len());
    for (index, column) in spec.columns.iter().enumerate() {
        names.push(format!("\"{}\"", column.name));
        arrays.push(format!(
            "${}::{}",
            index + 1,
            unnest_cast(column, pg_schema, chain_id_mode)
        ));
        selected.push(if column.is_array {
            format!(
                "u.c{index}::{}",
                pg_field_type(
                    &column.field_type,
                    pg_schema,
                    true,
                    column.is_nullable,
                    numeric_array_as_text,
                    chain_id_mode,
                )
            )
        } else {
            format!("u.c{index}")
        });
    }
    let aliases = (0..spec.columns.len())
        .map(|index| format!("c{index}"))
        .collect::<Vec<_>>();
    format!(
        "INSERT INTO \"{pg_schema}\".\"{}\" ({})\nSELECT {} FROM unnest({}) AS u({}){};",
        spec.table_name,
        names.join(", "),
        selected.join(", "),
        arrays.join(","),
        aliases.join(","),
        on_conflict(&spec.columns, append_only)
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

    fn id() -> ColumnSpec {
        ColumnSpec {
            is_primary_key: true,
            ..column("id", FieldType::String)
        }
    }

    /// An enum cannot be bound as itself and a boolean was never bound as one,
    /// so both go in as something else and are cast.
    #[test]
    fn two_types_are_cast_rather_than_bound_as_themselves() {
        let spec = table(vec![
            id(),
            column("flag", FieldType::Boolean),
            ColumnSpec {
                is_nullable: true,
                ..column(
                    "kind",
                    FieldType::Enum {
                        name: "AccountType".to_string(),
                        variants: vec!["A".to_string()],
                    },
                )
            },
            ColumnSpec {
                is_nullable: true,
                ..column("at", FieldType::Date)
            },
        ]);
        assert_eq!(
            unnest_query(&spec, "test_schema", false, false, ChainIdMode::Int32),
            "INSERT INTO \"test_schema\".\"A\" (\"id\", \"flag\", \"kind\", \"at\")\n\
             SELECT u.c0, u.c1, u.c2, u.c3 FROM unnest($1::TEXT[],$2::BOOLEAN[],\
             $3::TEXT[]::\"test_schema\".AccountType[],\
             $4::TIMESTAMP WITH TIME ZONE[]) AS u(c0,c1,c2,c3)\
             ON CONFLICT(\"id\") DO UPDATE SET \"flag\" = EXCLUDED.\"flag\",\
             \"kind\" = EXCLUDED.\"kind\",\"at\" = EXCLUDED.\"at\";"
        );
    }

    /// Each row's array arrives as its literal, and becomes the column's type
    /// only once it is that row's value.
    #[test]
    fn an_array_column_is_cast_after_the_unnest() {
        let spec = table(vec![
            id(),
            ColumnSpec {
                is_array: true,
                ..column("amounts", FieldType::BigInt { precision: None })
            },
        ]);
        assert_eq!(
            (
                unnest_query(&spec, "s", false, false, ChainIdMode::Int32),
                unnest_query(&spec, "s", false, true, ChainIdMode::Int32),
            ),
            (
                "INSERT INTO \"s\".\"A\" (\"id\", \"amounts\")\nSELECT u.c0, u.c1::NUMERIC[] \
                 FROM unnest($1::TEXT[],$2::TEXT[]) AS u(c0,c1)ON CONFLICT(\"id\") DO UPDATE \
                 SET \"amounts\" = EXCLUDED.\"amounts\";"
                    .to_string(),
                "INSERT INTO \"s\".\"A\" (\"id\", \"amounts\")\nSELECT u.c0, u.c1::TEXT[] \
                 FROM unnest($1::TEXT[],$2::TEXT[]) AS u(c0,c1)ON CONFLICT(\"id\") DO UPDATE \
                 SET \"amounts\" = EXCLUDED.\"amounts\";"
                    .to_string(),
            )
        );
    }

    /// Rows that are only ever appended have no conflict to resolve.
    #[test]
    fn an_append_only_table_takes_no_conflict_clause() {
        assert_eq!(
            unnest_query(&table(vec![id()]), "s", true, false, ChainIdMode::Int32),
            "INSERT INTO \"s\".\"A\" (\"id\")\nSELECT u.c0 FROM unnest($1::TEXT[]) AS u(c0);"
        );
    }

    /// A key with nothing beside it has nothing to overwrite, so the row that
    /// is already there is left as it is.
    #[test]
    fn a_table_that_is_all_key_updates_nothing() {
        assert_eq!(
            unnest_query(&table(vec![id()]), "s", false, false, ChainIdMode::Int32),
            "INSERT INTO \"s\".\"A\" (\"id\")\nSELECT u.c0 FROM unnest($1::TEXT[]) AS u(c0)\
             ON CONFLICT(\"id\") DO NOTHING;"
        );
    }

    #[test]
    fn a_table_with_no_key_has_no_conflict_to_resolve() {
        let spec = table(vec![column("n", FieldType::Int32)]);
        assert_eq!(
            unnest_query(&spec, "s", false, false, ChainIdMode::Int32),
            "INSERT INTO \"s\".\"A\" (\"n\")\nSELECT u.c0 FROM unnest($1::INTEGER[]) AS u(c0);"
        );
    }
}
