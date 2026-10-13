//! PostgreSQL refuses a value too large for a btree index on its column with
//! `program_limit_exceeded`, and names neither the column nor the row it came
//! from. Nothing bounds the length of a string an event carries, so this is
//! reachable from any indexed `String` field, and the refusal has to say which
//! one and what to change.

use super::index_definition::IndexDefinition;

/// The largest entry a btree takes on an 8 kB page. A value is compressed
/// before the check, so a longer one may still fit, but a shorter one always
/// does: whatever was refused is among the values over it.
pub const BTREE_MAX_ITEM_BYTES: usize = 2704;

pub const PROGRAM_LIMIT_EXCEEDED: &str = "54000";

const REMEDY: &str = "Remove @index from the field, along with any composite @index or getWhere filter covering it, or keep values that long out of it, for example by truncating them in the handler.";

/// The id is a stored value too, and can be the oversized one.
const MAX_ID_CHARS: usize = 64;

#[derive(Debug, PartialEq)]
pub struct Oversized {
    pub columns: Vec<String>,
    pub id: String,
    pub bytes: usize,
}

/// The first row whose key in one of `indexes` is over the limit.
/// `bytes(column, row)` is how large the stored value is, `id(row)` which
/// entity the row is.
pub fn find(
    indexes: &[Vec<String>],
    column_names: &[&str],
    rows: usize,
    bytes: impl Fn(usize, usize) -> usize,
    id: impl Fn(usize) -> String,
) -> Option<Oversized> {
    // An index on a column the insert doesn't write can't be what refused it.
    let positions = indexes
        .iter()
        .filter_map(|columns| {
            columns
                .iter()
                .map(|column| column_names.iter().position(|name| name == column))
                .collect::<Option<Vec<_>>>()
                .map(|positions| (columns, positions))
        })
        .collect::<Vec<_>>();
    (0..rows).find_map(|row| {
        positions.iter().find_map(|(columns, positions)| {
            let total = positions
                .iter()
                .map(|&column| bytes(column, row))
                .sum::<usize>();
            (total > BTREE_MAX_ITEM_BYTES).then(|| Oversized {
                columns: columns.to_vec(),
                id: id(row),
                bytes: total,
            })
        })
    })
}

impl Oversized {
    pub fn explain(&self) -> String {
        let id = if self.id.chars().count() > MAX_ID_CHARS {
            format!(
                "{}…",
                self.id.chars().take(MAX_ID_CHARS).collect::<String>()
            )
        } else {
            self.id.clone()
        };
        let what = match self.columns.as_slice() {
            [column] => format!("the \"{column}\" column of id \"{id}\" holds"),
            columns => format!(
                "the {} columns of id \"{id}\" together hold",
                quoted(columns)
            ),
        };
        format!(
            "{what} {} bytes, more than the {BTREE_MAX_ITEM_BYTES} bytes PostgreSQL can index. {REMEDY}",
            self.bytes
        )
    }
}

pub fn explain_build(definition: &IndexDefinition) -> String {
    let columns = definition
        .columns
        .iter()
        .map(|column| column.name.clone())
        .collect::<Vec<_>>();
    format!(
        "Failed to build an index on \"{}\"({}): a stored value is larger than the {BTREE_MAX_ITEM_BYTES} bytes PostgreSQL can index. {REMEDY}",
        definition.table_name,
        columns
            .iter()
            .map(|column| format!("\"{column}\""))
            .collect::<Vec<_>>()
            .join(", ")
    )
}

fn quoted(columns: &[String]) -> String {
    let quoted = columns
        .iter()
        .map(|column| format!("\"{column}\""))
        .collect::<Vec<_>>();
    match quoted.split_last() {
        Some((last, rest)) if !rest.is_empty() => format!("{} and {last}", rest.join(", ")),
        _ => quoted.join(""),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn index(columns: &[&str]) -> Vec<String> {
        columns.iter().map(|column| column.to_string()).collect()
    }

    /// Two columns that each fit can still make a key that doesn't.
    #[test]
    fn a_composite_key_counts_its_columns_together() {
        let sizes = [[2, 2], [2000, 1000]];
        assert_eq!(
            find(
                &[index(&["id"]), index(&["name", "owner_id"])],
                &["id", "name", "owner_id"],
                2,
                |column, row| if column == 0 {
                    2
                } else {
                    sizes[row][column - 1]
                },
                |row| format!("e{row}"),
            ),
            Some(Oversized {
                columns: index(&["name", "owner_id"]),
                id: "e1".to_string(),
                bytes: 3000,
            })
        );
    }

    #[test]
    fn a_key_at_the_limit_fits() {
        assert_eq!(
            find(
                &[index(&["name"])],
                &["id", "name"],
                1,
                |_, _| BTREE_MAX_ITEM_BYTES,
                |_| "e".to_string(),
            ),
            None
        );
    }

    #[test]
    fn an_index_on_a_column_not_written_is_skipped() {
        assert_eq!(
            find(
                &[index(&["other"])],
                &["id", "name"],
                1,
                |_, _| 10_000,
                |_| "e".to_string(),
            ),
            None
        );
    }

    #[test]
    fn an_oversized_id_is_shortened_where_it_names_the_row() {
        let oversized = Oversized {
            columns: index(&["id"]),
            id: "a".repeat(3000),
            bytes: 3000,
        };
        assert_eq!(
            oversized.explain(),
            format!(
                "the \"id\" column of id \"{}…\" holds 3000 bytes, more than the 2704 bytes PostgreSQL can index. {REMEDY}",
                "a".repeat(MAX_ID_CHARS)
            )
        );
    }

    #[test]
    fn a_composite_key_names_every_column() {
        let oversized = Oversized {
            columns: index(&["a", "b", "c"]),
            id: "e".to_string(),
            bytes: 3000,
        };
        assert_eq!(
            oversized.explain(),
            format!("the \"a\", \"b\" and \"c\" columns of id \"e\" together hold 3000 bytes, more than the 2704 bytes PostgreSQL can index. {REMEDY}")
        );
    }
}
