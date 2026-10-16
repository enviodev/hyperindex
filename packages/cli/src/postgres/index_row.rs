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

const INDEXED_BY: &str =
    "The field is indexed by @index in schema.graphql or by a getWhere filter on it.";

/// 512 UTF-16 units are at most 1536 UTF-8 bytes, under the limit with room
/// left for the other columns of a composite index.
const FIX: &str =
    "Truncate the value in the handler, e.g. `value.slice(0, 512)`, or remove that index.";

const MAX_ID_CHARS: usize = 64;
const MAX_VALUE_CHARS: usize = 32;

pub struct Oversized {
    pub column: String,
    pub id: String,
    pub value: String,
    pub bytes: usize,
}

fn shortened(text: &str, max_chars: usize) -> String {
    match text.char_indices().nth(max_chars) {
        Some((end, _)) => format!("{}…", &text[..end]),
        None => text.to_string(),
    }
}

pub fn explain_insert(table_name: &str, oversized: Option<Oversized>) -> String {
    let limit = format!("over the {BTREE_MAX_ITEM_BYTES} bytes a PostgreSQL index can hold");
    match oversized {
        Some(Oversized {
            column,
            id,
            value,
            bytes,
        }) => format!(
            "Failed to write {table_name} with id \"{}\": field \"{column}\" is {bytes} bytes, {limit}. {INDEXED_BY} {FIX} Value: \"{}\"",
            shortened(&id, MAX_ID_CHARS),
            shortened(&value, MAX_VALUE_CHARS),
        ),
        None => format!(
            "Failed to write {table_name} entities: a field value is {limit}. {INDEXED_BY} {FIX}"
        ),
    }
}

pub fn explain_build(definition: &IndexDefinition) -> String {
    let columns = definition
        .columns
        .iter()
        .map(|column| format!("\"{}\"", column.name))
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "Failed to build an index on \"{}\"({columns}): a stored value is over the {BTREE_MAX_ITEM_BYTES} bytes a PostgreSQL index can hold. {INDEXED_BY} {FIX}",
        definition.table_name
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_long_id_and_value_are_shortened() {
        assert_eq!(
            explain_insert(
                "A",
                Some(Oversized {
                    column: "id".to_string(),
                    id: "é".repeat(3000),
                    value: "é".repeat(3000),
                    bytes: 6000,
                }),
            ),
            format!(
                "Failed to write A with id \"{}…\": field \"id\" is 6000 bytes, over the 2704 bytes a PostgreSQL index can hold. {INDEXED_BY} {FIX} Value: \"{}…\"",
                "é".repeat(MAX_ID_CHARS),
                "é".repeat(MAX_VALUE_CHARS),
            )
        );
    }
}
