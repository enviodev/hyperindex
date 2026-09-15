//! Statements against the tables the indexer keeps for itself.
//!
//! These name their columns rather than deriving them: the tables are declared
//! on the other side of the boundary, alongside the schemas that serialize their
//! rows, and declaring them twice is how the two would drift.

/// `UPDATE ... SET each column ... WHERE id = $1`.
///
/// The row is named by `$1` and the columns follow it, so a caller binds the id
/// first and then the values in the order it asked for the columns.
pub fn update_by_id_query(
    pg_schema: &str,
    table: &str,
    id_column: &str,
    columns: &[String],
) -> String {
    let assignments = columns
        .iter()
        .enumerate()
        .map(|(index, column)| format!("\"{column}\" = ${}", index + 2))
        .collect::<Vec<_>>();
    format!(
        "UPDATE \"{pg_schema}\".\"{table}\"\nSET {}\nWHERE \"{id_column}\" = $1;",
        assignments.join(",\n    ")
    )
}

/// Moves every chain's checkpoint in one statement, from two parallel arrays of
/// chain ids and the ids they reached.
pub fn set_by_unnest_query(
    pg_schema: &str,
    table: &str,
    id_column: &str,
    set_column: &str,
    id_array_type: &str,
    value_array_type: &str,
    relation: &str,
) -> String {
    format!(
        "UPDATE \"{pg_schema}\".\"{table}\"\n\
         SET \"{set_column}\" = {relation}.checkpoint_id\n\
         FROM unnest($1::{id_array_type},$2::{value_array_type}) AS {relation}(chain_id, \
         checkpoint_id)\n\
         WHERE \"{table}\".\"{id_column}\" = {relation}.chain_id;"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn columns(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| name.to_string()).collect()
    }

    /// The id is `$1` and the values follow, which is the order they are bound
    /// in rather than the order they are written in.
    #[test]
    fn an_update_numbers_its_columns_after_the_row_it_names() {
        assert_eq!(
            update_by_id_query(
                "test_schema",
                "envio_chains",
                "id",
                &columns(&[
                    "buffer_block",
                    "first_event_block",
                    "ready_at",
                    "_is_hyper_sync"
                ])
            ),
            "UPDATE \"test_schema\".\"envio_chains\"\n\
             SET \"buffer_block\" = $2,\n    \
             \"first_event_block\" = $3,\n    \
             \"ready_at\" = $4,\n    \
             \"_is_hyper_sync\" = $5\n\
             WHERE \"id\" = $1;"
        );
    }

    #[test]
    fn one_column_still_starts_at_the_second_parameter() {
        assert_eq!(
            update_by_id_query("s", "t", "id", &columns(&["only"])),
            "UPDATE \"s\".\"t\"\nSET \"only\" = $2\nWHERE \"id\" = $1;"
        );
    }

    #[test]
    fn every_chain_moves_in_one_statement() {
        assert_eq!(
            set_by_unnest_query(
                "s",
                "envio_chains",
                "id",
                "checkpoint_id",
                "INTEGER[]",
                "BIGINT[]",
                "envio_frontier"
            ),
            "UPDATE \"s\".\"envio_chains\"\n\
             SET \"checkpoint_id\" = envio_frontier.checkpoint_id\n\
             FROM unnest($1::INTEGER[],$2::BIGINT[]) AS envio_frontier(chain_id, checkpoint_id)\n\
             WHERE \"envio_chains\".\"id\" = envio_frontier.chain_id;"
        );
    }
}
