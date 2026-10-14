//! PostgreSQL refuses a value too large for a btree index on its column with
//! `program_limit_exceeded`, and names neither the column nor the row. Nothing
//! bounds the length of a string an event carries, so any indexed `String`
//! field can hit it.

use super::index_definition::IndexDefinition;

/// The largest entry a btree takes on an 8 kB page. A value is compressed
/// before the check, so a longer one may still fit, but a shorter one always
/// does: whatever was refused is among the values over it.
pub const BTREE_MAX_ITEM_BYTES: usize = 2704;

pub const PROGRAM_LIMIT_EXCEEDED: &str = "54000";

/// 512 UTF-16 units are at most 1536 UTF-8 bytes, under the limit with room
/// left for the other columns of a composite index.
const FIX: &str = "Truncate long values in the handler, e.g. `value.slice(0, 512)`, or stop indexing the field with @index or getWhere.";

const MAX_ID_CHARS: usize = 64;

pub struct Oversized {
    pub column: String,
    pub id: String,
    pub bytes: usize,
}

pub fn explain_insert(table_name: &str, oversized: Option<Oversized>) -> String {
    let what = match oversized {
        Some(Oversized { column, id, bytes }) => {
            let id = if id.chars().count() > MAX_ID_CHARS {
                format!("{}…", id.chars().take(MAX_ID_CHARS).collect::<String>())
            } else {
                id
            };
            format!("\"{column}\" of id \"{id}\" is {bytes} bytes")
        }
        None => "a value is".to_string(),
    };
    format!(
        "Failed to insert items into table \"{table_name}\": {what}, over the {BTREE_MAX_ITEM_BYTES} bytes a PostgreSQL index can hold. {FIX}"
    )
}

pub fn explain_build(definition: &IndexDefinition) -> String {
    let columns = definition
        .columns
        .iter()
        .map(|column| format!("\"{}\"", column.name))
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "Failed to build an index on \"{}\"({columns}): a stored value is over the {BTREE_MAX_ITEM_BYTES} bytes a PostgreSQL index can hold. {FIX}",
        definition.table_name
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_oversized_id_is_shortened_where_it_names_the_row() {
        assert_eq!(
            explain_insert(
                "A",
                Some(Oversized {
                    column: "id".to_string(),
                    id: "a".repeat(3000),
                    bytes: 3000,
                }),
            ),
            format!(
                "Failed to insert items into table \"A\": \"id\" of id \"{}…\" is 3000 bytes, over the 2704 bytes a PostgreSQL index can hold. {FIX}",
                "a".repeat(MAX_ID_CHARS)
            )
        );
    }
}
