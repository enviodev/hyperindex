//! Building a table's DDL from its column list.

use anyhow::Result;

use super::pg_type::{pg_field_type, ChainIdMode, FieldType};

/// One column of a table, as the caller describes it. `name` is already the
/// database name — a `column_name_format` rename is resolved before the spec is
/// built, so nothing here has to know the schema field it came from.
pub struct ColumnSpec {
    pub name: String,
    pub field_type: FieldType,
    pub is_array: bool,
    pub is_nullable: bool,
    pub is_primary_key: bool,
    pub default_value: Option<String>,
}

pub struct TableSpec {
    pub table_name: String,
    pub columns: Vec<ColumnSpec>,
    /// Set for a per-chain entity, whose rows are split into one partition per
    /// chain. Names the column the list partitions on.
    pub partition_by_column: Option<String>,
}

/// `CREATE TABLE IF NOT EXISTS` for the spec.
///
/// A column that carries a default takes it in place of `NOT NULL`: the default
/// is what makes the column safe to omit, and the two were never emitted
/// together.
pub fn create_table_query(
    spec: &TableSpec,
    pg_schema: &str,
    is_numeric_array_as_text: bool,
    chain_id_mode: ChainIdMode,
) -> Result<String> {
    let columns = spec
        .columns
        .iter()
        .map(|column| {
            let column_type = pg_field_type(
                &column.field_type,
                pg_schema,
                column.is_array,
                column.is_nullable,
                is_numeric_array_as_text,
                chain_id_mode,
            );
            let suffix = match &column.default_value {
                Some(default_value) => format!(" DEFAULT {default_value}"),
                None => {
                    if column.is_nullable {
                        String::new()
                    } else {
                        " NOT NULL".to_string()
                    }
                }
            };
            format!("\"{}\" {column_type}{suffix}", column.name)
        })
        .collect::<Vec<_>>()
        .join(", ");

    let primary_key = spec
        .columns
        .iter()
        .filter(|column| column.is_primary_key)
        .map(|column| format!("\"{}\"", column.name))
        .collect::<Vec<_>>();
    let primary_key = if primary_key.is_empty() {
        String::new()
    } else {
        format!(", PRIMARY KEY({})", primary_key.join(", "))
    };

    let partition_by = match &spec.partition_by_column {
        Some(column) => format!(" PARTITION BY LIST (\"{column}\")"),
        None => String::new(),
    };

    Ok(format!(
        "CREATE TABLE IF NOT EXISTS \"{pg_schema}\".\"{}\"({columns}{primary_key}){partition_by};",
        spec.table_name
    ))
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

    fn render(spec: &TableSpec) -> String {
        create_table_query(spec, "test_schema", false, ChainIdMode::Int32).unwrap()
    }

    #[test]
    fn a_table_names_its_columns_and_primary_key() {
        let spec = TableSpec {
            table_name: "A".to_string(),
            columns: vec![
                ColumnSpec {
                    is_primary_key: true,
                    ..column("id", FieldType::String)
                },
                ColumnSpec {
                    is_nullable: true,
                    ..column("optional", FieldType::String)
                },
                column("count", FieldType::BigInt { precision: None }),
            ],
            partition_by_column: None,
        };
        assert_eq!(
            render(&spec),
            "CREATE TABLE IF NOT EXISTS \"test_schema\".\"A\"(\"id\" TEXT NOT NULL, \
             \"optional\" TEXT, \"count\" NUMERIC NOT NULL, PRIMARY KEY(\"id\"));"
        );
    }

    #[test]
    fn a_default_stands_in_for_not_null() {
        let spec = TableSpec {
            table_name: "A".to_string(),
            columns: vec![ColumnSpec {
                default_value: Some("0".to_string()),
                ..column("count", FieldType::Int32)
            }],
            partition_by_column: None,
        };
        assert_eq!(
            render(&spec),
            "CREATE TABLE IF NOT EXISTS \"test_schema\".\"A\"(\"count\" INTEGER DEFAULT 0);"
        );
    }

    #[test]
    fn a_composite_primary_key_keeps_its_column_order() {
        let spec = TableSpec {
            table_name: "A".to_string(),
            columns: vec![
                ColumnSpec {
                    is_primary_key: true,
                    ..column("id", FieldType::String)
                },
                ColumnSpec {
                    is_primary_key: true,
                    ..column("chain_id", FieldType::ChainId)
                },
            ],
            partition_by_column: Some("chain_id".to_string()),
        };
        assert_eq!(
            render(&spec),
            "CREATE TABLE IF NOT EXISTS \"test_schema\".\"A\"(\"id\" TEXT NOT NULL, \
             \"chain_id\" INTEGER NOT NULL, PRIMARY KEY(\"id\", \"chain_id\")) \
             PARTITION BY LIST (\"chain_id\");"
        );
    }

    #[test]
    fn a_table_with_no_primary_key_declares_none() {
        let spec = TableSpec {
            table_name: "raw_events".to_string(),
            columns: vec![column("payload", FieldType::Json)],
            partition_by_column: None,
        };
        assert_eq!(
            render(&spec),
            "CREATE TABLE IF NOT EXISTS \"test_schema\".\"raw_events\"(\"payload\" JSONB NOT NULL);"
        );
    }
}
