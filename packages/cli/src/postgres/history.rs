//! An entity's history: the row it had at every checkpoint that changed it,
//! kept while a reorg could still reach back to it.
//!
//! Rolling back asks the same question from two sides. One statement finds the
//! row each key had at the target, so it can be restored; the other finds the
//! keys that did not exist then, so they can be removed. Between them they
//! account for every row the rolled-back range touched.

use anyhow::{bail, Result};

pub const CHECKPOINT_COLUMN: &str = "envio_checkpoint_id";
pub const CHANGE_COLUMN: &str = "envio_change";
pub const CHANGE_TYPE: &str = "ENVIO_HISTORY_CHANGE";
pub const SET: &str = "SET";
pub const DELETE: &str = "DELETE";

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

/// The pieces a statement splices in to read its bound as `checkpoint_id`: a
/// join for a select, a `USING` for a delete.
#[derive(Debug)]
pub struct Bounds {
    pub join: String,
    pub using: String,
    pub using_match: String,
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
            using: String::new(),
            using_match: String::new(),
            checkpoint_id: "$1".to_string(),
        }),
        (Sequence::PerChain, Some(column)) => {
            let chain_match = format!("envio_bounds.chain_id = {table_ref}.\"{column}\"");
            Ok(Bounds {
                join: format!(" JOIN {RELATION} ON {chain_match}"),
                using: format!(" USING {RELATION}"),
                using_match: format!(" AND {chain_match}"),
                checkpoint_id: "envio_bounds.checkpoint_id".to_string(),
            })
        }
        (Sequence::PerChain, None) => bail!(
            "Internal error: per-chain checkpoint bounds can't bound a table with no chain-id \
             column. Only a schema whose entities are all per-chain has them."
        ),
    }
}

/// An entity's history table, and what its statements need to know about the
/// entity it follows.
pub struct History {
    pub entity_table: String,
    pub history_table: String,
    /// The entity's own columns, in the order its table declares them.
    pub data_columns: Vec<String>,
    /// Set for a per-chain entity. Its rows are only comparable within a chain,
    /// so its identity is the id and the chain rather than the id alone.
    pub chain_id_column: Option<String>,
    pub id_pg_type: String,
}

impl History {
    pub fn key_columns(&self) -> Vec<String> {
        let mut keys = vec!["id".to_string()];
        keys.extend(self.chain_id_column.iter().cloned());
        keys
    }

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

    fn key_match(&self, left: &str, right: &str) -> String {
        self.key_columns()
            .iter()
            .map(|column| format!("{left}.\"{column}\" = {right}.\"{column}\""))
            .collect::<Vec<_>>()
            .join(" AND ")
    }

    fn bounds(&self, sequence: Sequence, table_ref: &str) -> Result<Bounds> {
        bounds(sequence, self.chain_id_column.as_deref(), table_ref)
    }

    /// The row each key held at the target, for keys that changed after it.
    ///
    /// The newest row at or before the target per key, which `DISTINCT ON` with
    /// the matching `ORDER BY` picks. The `EXISTS` is what limits it to keys the
    /// rolled-back range actually touched.
    pub fn pre_target_rows(&self, pg_schema: &str, sequence: Sequence) -> Result<String> {
        let table_ref = self.table_ref();
        let bounds = self.bounds(sequence, &table_ref)?;
        let keys = self.qualified(&self.key_columns());
        Ok(format!(
            "SELECT DISTINCT ON ({keys}) {data}, {table_ref}.\"{CHANGE_COLUMN}\"\n  \
             FROM \"{pg_schema}\".\"{history}\"{join}\n  \
             WHERE {table_ref}.\"{CHECKPOINT_COLUMN}\" <= {bound}\n    \
             AND EXISTS (\n      \
             SELECT 1\n      \
             FROM \"{pg_schema}\".\"{history}\" h\n      \
             WHERE {key_match}\n        \
             AND h.\"{CHECKPOINT_COLUMN}\" > {bound}\n    \
             )\n  \
             ORDER BY {keys}, {table_ref}.\"{CHECKPOINT_COLUMN}\" DESC",
            data = self.qualified(&self.data_columns),
            history = self.history_table,
            join = bounds.join,
            bound = bounds.checkpoint_id,
            key_match = self.key_match("h", &table_ref),
        ))
    }

    /// The keys that were created after the target and have no history before
    /// it, so rolling back leaves nothing of them to restore.
    ///
    /// A DELETE row at or before the target is not one of these: the restore
    /// query returns it, and what it means is decided there.
    pub fn removed_ids(&self, pg_schema: &str, sequence: Sequence) -> Result<String> {
        let table_ref = self.table_ref();
        let bounds = self.bounds(sequence, &table_ref)?;
        Ok(format!(
            "SELECT DISTINCT {keys}\n  \
             FROM \"{pg_schema}\".\"{history}\"{join}\n  \
             WHERE {table_ref}.\"{CHECKPOINT_COLUMN}\" > {bound}\n    \
             AND NOT EXISTS (\n      \
             SELECT 1\n      \
             FROM \"{pg_schema}\".\"{history}\" h\n      \
             WHERE {key_match}\n        \
             AND h.\"{CHECKPOINT_COLUMN}\" <= {bound}\n    \
             )",
            keys = self.qualified(&self.key_columns()),
            history = self.history_table,
            join = bounds.join,
            bound = bounds.checkpoint_id,
            key_match = self.key_match("h", &table_ref),
        ))
    }

    /// Forgets everything after the target, which the rollback is about to
    /// write again.
    pub fn rollback(&self, pg_schema: &str, sequence: Sequence) -> Result<String> {
        let table_ref = format!("\"{pg_schema}\".\"{}\"", self.history_table);
        let bounds = self.bounds(sequence, &table_ref)?;
        Ok(format!(
            "DELETE FROM {table_ref}{using} WHERE \"{CHECKPOINT_COLUMN}\" > {bound}{using_match};",
            using = bounds.using,
            bound = bounds.checkpoint_id,
            using_match = bounds.using_match,
        ))
    }

    /// Records a delete as a history row: the id and the checkpoint it happened
    /// at, and nothing else, from `$1` ids and `$2` checkpoint ids.
    ///
    /// Every data column is NULL because a delete says what the row stopped
    /// being, not what it was. The exception is the chain column of a per-chain
    /// entity, which is part of the history key — a row keyed on a NULL chain
    /// would not be the row that was deleted — and which is bound as `$3` when
    /// the write names a chain.
    pub fn insert_delete_rows(&self, pg_schema: &str, with_chain: bool) -> String {
        let chain_id_column = self.chain_id_column.as_deref().filter(|_| with_chain);
        let mut names = self.data_columns.clone();
        names.push(CHECKPOINT_COLUMN.to_string());
        names.push(CHANGE_COLUMN.to_string());
        let selected = names
            .iter()
            .map(|column| {
                if column == "id" {
                    "u.id".to_string()
                } else if column == CHECKPOINT_COLUMN {
                    format!("u.{CHECKPOINT_COLUMN}")
                } else if column == CHANGE_COLUMN {
                    format!("'{DELETE}'")
                } else if chain_id_column == Some(column.as_str()) {
                    "$3".to_string()
                } else {
                    "NULL".to_string()
                }
            })
            .collect::<Vec<_>>();
        format!(
            "INSERT INTO \"{pg_schema}\".\"{history}\" ({names})\nSELECT {selected}\nFROM \
             UNNEST($1::{id}[], $2::BIGINT[]) AS u(id, {CHECKPOINT_COLUMN})",
            history = self.history_table,
            names = quoted(&names),
            selected = selected.join(", "),
            id = self.id_pg_type,
        )
    }

    /// An entity changed for the first time since history started being kept
    /// has no row to roll back to. Its current row is copied in at checkpoint 0
    /// before the change lands, for the `$1` ids that have none.
    ///
    /// The chain is written into the statement rather than bound: this scans
    /// the entity table, which is partitioned by it, and Postgres only prunes a
    /// cached plan on a constant.
    pub fn backfill(&self, pg_schema: &str, chain_id: Option<i64>) -> String {
        let history = format!("\"{pg_schema}\".\"{}\"", self.history_table);
        let chain_filter = match (&self.chain_id_column, chain_id) {
            (Some(column), Some(chain_id)) => format!(" AND e.\"{column}\" = {chain_id}"),
            _ => String::new(),
        };
        let data = quoted(&self.data_columns);
        let selected = self
            .data_columns
            .iter()
            .map(|column| format!("e.\"{column}\""))
            .collect::<Vec<_>>()
            .join(", ");
        format!(
            "INSERT INTO {history} ({data}, \"{CHECKPOINT_COLUMN}\", \"{CHANGE_COLUMN}\")\n\
             SELECT {selected}, 0, '{SET}'\n\
             FROM \"{pg_schema}\".\"{entity}\" e\n\
             JOIN UNNEST($1::{id}[]) AS t(id) ON e.id = t.id{chain_filter}\n\
             WHERE NOT EXISTS (SELECT 1 FROM {history} h WHERE {key_match});",
            entity = self.entity_table,
            id = self.id_pg_type,
            key_match = self.key_match("h", "e"),
        )
    }

    /// Deletes the entity rows of the `$1` ids. A per-chain entity's delete
    /// names its chain, written in for the same reason as the backfill's.
    pub fn delete_entities(&self, pg_schema: &str, chain_id: Option<i64>) -> String {
        let chain_filter = match (&self.chain_id_column, chain_id) {
            (Some(column), Some(chain_id)) => format!(" AND \"{column}\" = {chain_id}"),
            _ => String::new(),
        };
        format!(
            "DELETE FROM \"{pg_schema}\".\"{}\" WHERE id = ANY($1::{}[]){chain_filter};",
            self.entity_table, self.id_pg_type
        )
    }

    /// Keeps only what a rollback could still reach: per key, the newest row at
    /// or before the safe checkpoint (the anchor) and everything after it — and
    /// not even the anchor when nothing came after it, since the entity table
    /// then already holds that state.
    ///
    /// Whether a key still has a row above the safe checkpoint is an aggregate
    /// over the same groups as the anchor, so it's computed in the one pass
    /// rather than as a per-row correlated lookup. The DELETE's `<=` on the row
    /// keeps the rows above the safe checkpoint out of the join.
    ///
    /// Per-chain bounds are joined in rather than run as a statement each: the
    /// anchors aggregate the whole table however narrow the bound is, and
    /// history carries no index to narrow the scan with.
    pub fn prune(&self, pg_schema: &str, sequence: Sequence) -> Result<String> {
        let history = format!("\"{pg_schema}\".\"{}\"", self.history_table);
        let bounds = self.bounds(sequence, "t")?;
        let keys = self
            .key_columns()
            .iter()
            .map(|column| format!("t.\"{column}\""))
            .collect::<Vec<_>>()
            .join(", ");
        let bound = bounds.checkpoint_id;
        Ok(format!(
            "WITH anchors AS (\n  \
             SELECT {keys},\n    \
             MAX(t.{CHECKPOINT_COLUMN}) FILTER (WHERE t.{CHECKPOINT_COLUMN} <= {bound}) AS \
             keep_checkpoint_id,\n    \
             bool_or(t.{CHECKPOINT_COLUMN} > {bound}) AS has_above,\n    \
             MIN({bound}) AS safe_checkpoint_id\n  \
             FROM {history} t{join}\n  \
             GROUP BY {keys}\n\
             )\n\
             DELETE FROM {history} d\n\
             USING anchors a\n\
             WHERE {key_match}\n  \
             AND d.{CHECKPOINT_COLUMN} <= a.safe_checkpoint_id\n  \
             AND (d.{CHECKPOINT_COLUMN} < a.keep_checkpoint_id OR NOT a.has_above);",
            join = bounds.join,
            key_match = self.key_match("d", "a"),
        ))
    }
}

pub fn quoted(columns: &[String]) -> String {
    columns
        .iter()
        .map(|column| format!("\"{column}\""))
        .collect::<Vec<_>>()
        .join(", ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn counter() -> History {
        History {
            entity_table: "Counter".to_string(),
            history_table: "envio_history_Counter".to_string(),
            data_columns: ["id", "chainId", "count"].map(str::to_string).to_vec(),
            chain_id_column: Some("chainId".to_string()),
            id_pg_type: "TEXT".to_string(),
        }
    }

    fn global() -> History {
        History {
            entity_table: "Global".to_string(),
            history_table: "envio_history_Global".to_string(),
            data_columns: ["id", "count"].map(str::to_string).to_vec(),
            chain_id_column: None,
            ..counter()
        }
    }

    /// A per-chain entity under one shared counter.
    #[test]
    fn removed_ids_reads_as_it_did() {
        assert_eq!(
            counter()
                .removed_ids("public", Sequence::SharedAcrossChains)
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
        let query = counter()
            .pre_target_rows("public", Sequence::SharedAcrossChains)
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
        assert_eq!(
            global()
                .removed_ids("public", Sequence::SharedAcrossChains)
                .unwrap(),
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
        let query = counter().removed_ids("public", Sequence::PerChain).unwrap();
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

    /// A delete says what the row stopped being, so every data column is NULL.
    #[test]
    fn a_delete_row_carries_nothing_but_its_key() {
        assert_eq!(
            global().insert_delete_rows("public", false),
            "INSERT INTO \"public\".\"envio_history_Global\" (\"id\", \"count\", \
             \"envio_checkpoint_id\", \"envio_change\")\n\
             SELECT u.id, NULL, u.envio_checkpoint_id, 'DELETE'\n\
             FROM UNNEST($1::TEXT[], $2::BIGINT[]) AS u(id, envio_checkpoint_id)"
        );
    }

    /// The chain is part of the history key, so it is bound rather than nulled —
    /// a row keyed on a NULL chain is not the row that was deleted.
    #[test]
    fn a_per_chain_delete_row_keeps_its_chain() {
        assert_eq!(
            counter().insert_delete_rows("public", true),
            "INSERT INTO \"public\".\"envio_history_Counter\" (\"id\", \"chainId\", \"count\", \
             \"envio_checkpoint_id\", \"envio_change\")\n\
             SELECT u.id, $3, NULL, u.envio_checkpoint_id, 'DELETE'\n\
             FROM UNNEST($1::TEXT[], $2::BIGINT[]) AS u(id, envio_checkpoint_id)"
        );
    }

    /// The scan of the partitioned entity table names the chain as a constant,
    /// and a history row is matched on the whole key.
    #[test]
    fn a_backfill_copies_rows_with_no_history_yet() {
        assert_eq!(
            counter().backfill("public", Some(7)),
            "INSERT INTO \"public\".\"envio_history_Counter\" (\"id\", \"chainId\", \"count\", \
             \"envio_checkpoint_id\", \"envio_change\")\n\
             SELECT e.\"id\", e.\"chainId\", e.\"count\", 0, 'SET'\n\
             FROM \"public\".\"Counter\" e\n\
             JOIN UNNEST($1::TEXT[]) AS t(id) ON e.id = t.id AND e.\"chainId\" = 7\n\
             WHERE NOT EXISTS (SELECT 1 FROM \"public\".\"envio_history_Counter\" h WHERE \
             h.\"id\" = e.\"id\" AND h.\"chainId\" = e.\"chainId\");"
        );
    }

    #[test]
    fn a_delete_names_a_per_chain_entitys_chain() {
        assert_eq!(
            (
                counter().delete_entities("public", Some(137)),
                global().delete_entities("public", Some(137)),
            ),
            (
                "DELETE FROM \"public\".\"Counter\" WHERE id = ANY($1::TEXT[]) AND \"chainId\" \
                 = 137;"
                    .to_string(),
                "DELETE FROM \"public\".\"Global\" WHERE id = ANY($1::TEXT[]);".to_string(),
            )
        );
    }

    #[test]
    fn a_rollback_deletes_above_each_chains_bound() {
        assert_eq!(
            (
                global()
                    .rollback("s", Sequence::SharedAcrossChains)
                    .unwrap(),
                counter().rollback("s", Sequence::PerChain).unwrap(),
            ),
            (
                "DELETE FROM \"s\".\"envio_history_Global\" WHERE \"envio_checkpoint_id\" > $1;"
                    .to_string(),
                "DELETE FROM \"s\".\"envio_history_Counter\" USING unnest($1::BIGINT[],\
                 $2::BIGINT[]) AS envio_bounds(chain_id, checkpoint_id) WHERE \
                 \"envio_checkpoint_id\" > envio_bounds.checkpoint_id AND \
                 envio_bounds.chain_id = \"s\".\"envio_history_Counter\".\"chainId\";"
                    .to_string(),
            )
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
