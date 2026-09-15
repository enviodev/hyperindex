//! Reading an entity's history back to where a reorg left it.
//!
//! Both statements below ask the same question from opposite sides. One finds
//! the row each key had at the target, so it can be restored; the other finds
//! the keys that did not exist then, so they can be removed. Between them they
//! account for every row the rolled-back range touched.

use anyhow::{bail, Result};

/// How checkpoint ids are handed out, which decides what a row is compared
/// against.
///
/// Under one shared counter every chain is held to a single id. Per chain the
/// ids are not comparable across chains, so each row is compared against its own
/// chain's — which is what the joined-in relation carries.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Sequence {
    SharedAcrossChains,
    PerChain,
}

impl Sequence {
    pub fn parse(value: &str) -> Result<Self> {
        match value {
            "SharedAcrossChains" => Ok(Sequence::SharedAcrossChains),
            "PerChain" => Ok(Sequence::PerChain),
            other => bail!("`{other}` is not a checkpoint sequence"),
        }
    }
}

/// The pieces a statement splices in to read its bound as `checkpoint_id`.
///
/// A prune and a rollback of the internal tables splice the same relation in
/// with `USING` rather than `JOIN`; those forms arrive with the statements that
/// need them.
#[derive(Debug)]
pub struct Bounds {
    pub join: String,
    pub checkpoint_id: String,
}

/// The chain ids are cast to the widest integer type rather than the column's
/// own: nothing indexes the join, so the values only have to compare.
const RELATION: &str = "unnest($1::BIGINT[],$2::BIGINT[]) AS envio_bounds(chain_id, checkpoint_id)";

pub fn bounds(
    sequence: Sequence,
    chain_id_column: Option<&str>,
    table_ref: &str,
) -> Result<Bounds> {
    match (sequence, chain_id_column) {
        (Sequence::SharedAcrossChains, _) => Ok(Bounds {
            join: String::new(),
            checkpoint_id: "$1".to_string(),
        }),
        (Sequence::PerChain, Some(column)) => {
            let chain_match = format!("envio_bounds.chain_id = {table_ref}.\"{column}\"");
            Ok(Bounds {
                join: format!(" JOIN {RELATION} ON {chain_match}"),
                checkpoint_id: "envio_bounds.checkpoint_id".to_string(),
            })
        }
        (Sequence::PerChain, None) => bail!(
            "Internal error: per-chain checkpoint bounds can't bound a table with no chain-id \
             column. Only a schema whose entities are all per-chain has them."
        ),
    }
}

/// What a history table is asked about.
pub struct HistoryQuery {
    pub pg_schema: String,
    pub history_table: String,
    /// The entity's own columns, which the restore reads back.
    pub data_columns: Vec<String>,
    /// What identifies a row. A per-chain entity's rows are only comparable
    /// within a chain, so its identity is the id and the chain rather than the
    /// id alone.
    pub key_columns: Vec<String>,
    pub chain_id_column: Option<String>,
    pub checkpoint_column: String,
    pub change_column: String,
}

impl HistoryQuery {
    /// Every column is qualified. The per-chain bounds relation joined in has a
    /// `chain_id` of its own, which a snake_case chain column would share.
    fn table_ref(&self) -> String {
        format!("\"{}\"", self.history_table)
    }

    fn qualified(&self, columns: &[String]) -> String {
        let table_ref = self.table_ref();
        columns
            .iter()
            .map(|column| format!("{table_ref}.\"{column}\""))
            .collect::<Vec<_>>()
            .join(", ")
    }

    /// Matches the inner table's row against the outer one on identity.
    fn key_match(&self) -> String {
        let table_ref = self.table_ref();
        self.key_columns
            .iter()
            .map(|column| format!("h.\"{column}\" = {table_ref}.\"{column}\""))
            .collect::<Vec<_>>()
            .join(" AND ")
    }

    /// The row each key held at the target, for keys that changed after it.
    ///
    /// The newest row at or before the target per key, which `DISTINCT ON` with
    /// the matching `ORDER BY` picks. The `EXISTS` is what limits it to keys the
    /// rolled-back range actually touched.
    pub fn pre_target_rows(&self, sequence: Sequence) -> Result<String> {
        let table_ref = self.table_ref();
        let bounds = bounds(sequence, self.chain_id_column.as_deref(), &table_ref)?;
        let keys = self.qualified(&self.key_columns);
        Ok(format!(
            "SELECT DISTINCT ON ({keys}) {data}, {table_ref}.\"{change}\"\n  \
             FROM \"{schema}\".\"{history}\"{join}\n  \
             WHERE {table_ref}.\"{checkpoint}\" <= {bound}\n    \
             AND EXISTS (\n      \
             SELECT 1\n      \
             FROM \"{schema}\".\"{history}\" h\n      \
             WHERE {key_match}\n        \
             AND h.\"{checkpoint}\" > {bound}\n    \
             )\n  \
             ORDER BY {keys}, {table_ref}.\"{checkpoint}\" DESC",
            data = self.qualified(&self.data_columns),
            change = self.change_column,
            schema = self.pg_schema,
            history = self.history_table,
            join = bounds.join,
            checkpoint = self.checkpoint_column,
            bound = bounds.checkpoint_id,
            key_match = self.key_match(),
        ))
    }

    /// The keys that were created after the target and have no history before
    /// it, so rolling back leaves nothing of them to restore.
    ///
    /// A DELETE row at or before the target is not one of these: the restore
    /// query returns it, and what it means is decided there.
    pub fn removed_ids(&self, sequence: Sequence) -> Result<String> {
        let table_ref = self.table_ref();
        let bounds = bounds(sequence, self.chain_id_column.as_deref(), &table_ref)?;
        Ok(format!(
            "SELECT DISTINCT {keys}\n  \
             FROM \"{schema}\".\"{history}\"{join}\n  \
             WHERE {table_ref}.\"{checkpoint}\" > {bound}\n    \
             AND NOT EXISTS (\n      \
             SELECT 1\n      \
             FROM \"{schema}\".\"{history}\" h\n      \
             WHERE {key_match}\n        \
             AND h.\"{checkpoint}\" <= {bound}\n    \
             )",
            keys = self.qualified(&self.key_columns),
            schema = self.pg_schema,
            history = self.history_table,
            join = bounds.join,
            checkpoint = self.checkpoint_column,
            bound = bounds.checkpoint_id,
            key_match = self.key_match(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn counter_history() -> HistoryQuery {
        HistoryQuery {
            pg_schema: "public".to_string(),
            history_table: "envio_history_Counter".to_string(),
            data_columns: ["id", "chainId", "count"].map(str::to_string).to_vec(),
            key_columns: ["id", "chainId"].map(str::to_string).to_vec(),
            chain_id_column: Some("chainId".to_string()),
            checkpoint_column: "envio_checkpoint_id".to_string(),
            change_column: "envio_change".to_string(),
        }
    }

    /// The text the ReScript this replaces produced, for a per-chain entity
    /// under one shared counter.
    #[test]
    fn removed_ids_reads_as_it_did() {
        assert_eq!(
            counter_history()
                .removed_ids(Sequence::SharedAcrossChains)
                .unwrap(),
            "SELECT DISTINCT \"envio_history_Counter\".\"id\", \
             \"envio_history_Counter\".\"chainId\"\n  \
             FROM \"public\".\"envio_history_Counter\"\n  \
             WHERE \"envio_history_Counter\".\"envio_checkpoint_id\" > $1\n    \
             AND NOT EXISTS (\n      \
             SELECT 1\n      \
             FROM \"public\".\"envio_history_Counter\" h\n      \
             WHERE h.\"id\" = \"envio_history_Counter\".\"id\" AND h.\"chainId\" = \
             \"envio_history_Counter\".\"chainId\"\n        \
             AND h.\"envio_checkpoint_id\" <= $1\n    \
             )"
        );
    }

    /// Both have to name the same columns in the same order, or the rows the
    /// `DISTINCT ON` keeps are not the ones the `ORDER BY` puts first.
    #[test]
    fn the_restore_dedups_and_orders_on_the_same_key() {
        let query = counter_history()
            .pre_target_rows(Sequence::SharedAcrossChains)
            .unwrap();
        assert_eq!(
            (
                query.contains(
                    "SELECT DISTINCT ON (\"envio_history_Counter\".\"id\", \
                     \"envio_history_Counter\".\"chainId\")"
                ),
                query.contains(
                    "ORDER BY \"envio_history_Counter\".\"id\", \
                     \"envio_history_Counter\".\"chainId\", \
                     \"envio_history_Counter\".\"envio_checkpoint_id\" DESC"
                ),
            ),
            (true, true)
        );
    }

    /// An entity that no chain owns is keyed on its id alone.
    #[test]
    fn a_cross_chain_entity_is_keyed_on_its_id() {
        let history = HistoryQuery {
            history_table: "envio_history_Global".to_string(),
            data_columns: ["id", "count"].map(str::to_string).to_vec(),
            key_columns: vec!["id".to_string()],
            chain_id_column: None,
            ..counter_history()
        };
        assert_eq!(
            history.removed_ids(Sequence::SharedAcrossChains).unwrap(),
            "SELECT DISTINCT \"envio_history_Global\".\"id\"\n  \
             FROM \"public\".\"envio_history_Global\"\n  \
             WHERE \"envio_history_Global\".\"envio_checkpoint_id\" > $1\n    \
             AND NOT EXISTS (\n      \
             SELECT 1\n      \
             FROM \"public\".\"envio_history_Global\" h\n      \
             WHERE h.\"id\" = \"envio_history_Global\".\"id\"\n        \
             AND h.\"envio_checkpoint_id\" <= $1\n    \
             )"
        );
    }

    /// Per chain, each row is held to its own chain's id rather than to one
    /// shared bound, so the relation carrying them is joined in.
    #[test]
    fn per_chain_bounds_join_the_ids_in() {
        let query = counter_history().removed_ids(Sequence::PerChain).unwrap();
        assert_eq!(
            (
                query.contains(
                    " JOIN unnest($1::BIGINT[],$2::BIGINT[]) AS envio_bounds(chain_id, \
                     checkpoint_id) ON envio_bounds.chain_id = \
                     \"envio_history_Counter\".\"chainId\""
                ),
                query.contains("> envio_bounds.checkpoint_id"),
                query.contains("$1\n"),
            ),
            (true, true, false)
        );
    }

    /// Only a schema whose entities are all per-chain counts per chain, so a
    /// table with no chain column cannot be bounded that way.
    #[test]
    fn per_chain_bounds_need_a_chain_column() {
        assert!(bounds(Sequence::PerChain, None, "\"t\"")
            .unwrap_err()
            .to_string()
            .contains("can't bound a table with no chain-id column"));
    }
}
