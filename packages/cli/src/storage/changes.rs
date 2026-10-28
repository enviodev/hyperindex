//! What one write group changed: an entity's changes within one chain scope,
//! in the order they were made, as JavaScript staged them. Each store reads
//! what it keeps straight off these rows — Postgres the latest state of every
//! id and the history leading to it, ClickHouse every change.

use std::collections::HashMap;
use std::sync::Arc;

use anyhow::{bail, Result};

use super::schema::{Encoding, Entity};
use crate::columnar::{Arena, Column, ColumnKind};

/// The two columns a change set carries after the entity's fields.
pub const CHECKPOINT: &str = "envio_checkpoint_id";
pub const CHANGE: &str = "envio_change";

/// How a change set is laid out: the entity's fields, the checkpoint each
/// change was made at, and 1 for a change that deletes the entity.
pub fn layout(entity: &Entity) -> (Vec<String>, Vec<ColumnKind>) {
    entity
        .fields
        .iter()
        .map(|field| (field.name.clone(), field.encoding().kind()))
        .chain([
            (CHECKPOINT.to_string(), ColumnKind::I64),
            (CHANGE.to_string(), ColumnKind::F64),
        ])
        .unzip()
}

pub struct ChangeSet {
    pub entity: Arc<Entity>,
    /// The scope's chain, for a per-chain entity.
    pub chain_id: Option<i64>,
    /// Whether the scope's chains keep history for this batch.
    pub keeps_history: bool,
    pub rows: Arena,
    id: usize,
}

/// A row's id, as its column holds it. Two rows name the same entity exactly
/// when these are equal.
#[derive(PartialEq, Eq, Hash, Clone, Copy)]
pub enum Key<'a> {
    Bytes(&'a [u8]),
    Bits(u64),
}

/// The rows Postgres takes from a change set.
#[derive(Debug, Default, PartialEq)]
pub struct Projection {
    /// Each id's latest change, where it sets the entity.
    pub sets: Vec<usize>,
    /// Each id's latest change, where it deletes the entity.
    pub deletes: Vec<usize>,
    /// Every change that becomes a history row, sets and deletes apart.
    pub history_sets: Vec<usize>,
    pub history_deletes: Vec<usize>,
    /// One row per id whose history has to start from its current row first:
    /// every id but those the rollback's diff restored.
    pub backfill: Vec<usize>,
}

impl ChangeSet {
    pub fn new(
        entity: Arc<Entity>,
        chain_id: Option<i64>,
        keeps_history: bool,
        rows: Arena,
    ) -> Result<Self> {
        let (_, kinds) = layout(&entity);
        let staged = rows.columns().iter().map(Column::kind).collect::<Vec<_>>();
        if staged != kinds {
            bail!(
                "The changes of \"{}\" were staged as {staged:?}, not as {kinds:?}",
                entity.name
            );
        }
        if entity.chain_id.is_some() != chain_id.is_some() {
            bail!(
                "The changes of \"{}\" were staged {} a chain",
                entity.name,
                if chain_id.is_some() { "for" } else { "without" }
            );
        }
        let (id, _) = entity.id()?;
        Ok(Self {
            entity,
            chain_id,
            keeps_history,
            rows,
            id,
        })
    }

    pub fn len(&self) -> usize {
        self.rows.rows()
    }

    pub fn fields(&self) -> &[Column] {
        &self.rows.columns()[..self.entity.fields.len()]
    }

    pub fn id_index(&self) -> usize {
        self.id
    }

    pub fn id_column(&self) -> &Column {
        &self.rows.columns()[self.id]
    }

    pub fn checkpoints(&self) -> &Column {
        &self.rows.columns()[self.entity.fields.len()]
    }

    pub fn checkpoint(&self, row: usize) -> i64 {
        self.checkpoints().i64_at(row)
    }

    pub fn is_delete(&self, row: usize) -> bool {
        self.rows.columns()[self.entity.fields.len() + 1].f64_at(row) != 0.0
    }

    pub fn key(&self, row: usize) -> Key<'_> {
        let column = self.id_column();
        match column.kind() {
            ColumnKind::Text | ColumnKind::Bytes => Key::Bytes(column.bytes_at(row)),
            _ => Key::Bits(column.u64_at(row)),
        }
    }

    /// An id as the text its column reads it from.
    pub fn id_text(&self, row: usize) -> Result<String> {
        let column = self.id_column();
        Ok(match self.entity.fields[self.id].encoding() {
            Encoding::Number => column.f64_at(row).to_string(),
            _ => column.str_at(row)?.to_string(),
        })
    }

    /// The latest change of every id, in the order the ids first changed, and
    /// — when the scope keeps history — every change as a history row. A
    /// rollback's diff restores an id's latest state rather than changing it,
    /// so a change at `diff` is no history of its own, and the id it restored
    /// already has the history its backfill would copy.
    pub fn project(&self, diff: Option<i64>) -> Projection {
        let mut latest: HashMap<Key<'_>, usize> = HashMap::with_capacity(self.len());
        let mut order = Vec::with_capacity(self.len());
        let mut restored = std::collections::HashSet::new();
        let mut projection = Projection::default();
        for row in 0..self.len() {
            let key = self.key(row);
            if latest.insert(key, row).is_none() {
                order.push(key);
            }
            if self.keeps_history {
                if Some(self.checkpoint(row)) == diff {
                    restored.insert(key);
                } else if self.is_delete(row) {
                    projection.history_deletes.push(row);
                } else {
                    projection.history_sets.push(row);
                }
            }
        }
        for key in order {
            let row = latest[&key];
            if self.is_delete(row) {
                projection.deletes.push(row);
            } else {
                projection.sets.push(row);
            }
            if self.keeps_history && !restored.contains(&key) {
                projection.backfill.push(row);
            }
        }
        projection
    }
}

#[cfg(test)]
pub mod test_support {
    use super::*;
    use crate::columnar::ColumnSpec;

    pub enum Change<'a> {
        Set(&'a [Option<&'a str>], i64),
        Delete(&'a str, i64),
    }

    /// A change set of an entity whose fields are all text.
    pub fn change_set(
        entity: Arc<Entity>,
        chain_id: Option<i64>,
        keeps_history: bool,
        changes: &[Change],
    ) -> ChangeSet {
        let (names, kinds) = layout(&entity);
        let specs = kinds
            .iter()
            .map(|kind| ColumnSpec::Scalar(*kind))
            .collect::<Vec<_>>();
        let mut arena = Arena::new_filled(changes.len(), &specs);
        let fields = entity.fields.len();
        let (id, _) = entity.id().unwrap();
        for (row, change) in changes.iter().enumerate() {
            let (values, checkpoint, delete): (Vec<Option<&str>>, _, _) = match change {
                Change::Set(values, checkpoint) => (values.to_vec(), *checkpoint, false),
                Change::Delete(entity_id, checkpoint) => (
                    (0..fields)
                        .map(|field| (field == id).then_some(*entity_id))
                        .collect(),
                    *checkpoint,
                    true,
                ),
            };
            for (column, value) in values.iter().enumerate() {
                match value {
                    None => arena.mark_null(column, row),
                    Some(value) => match kinds[column] {
                        ColumnKind::F64 => arena.set_f64(column, row, value.parse().unwrap()),
                        _ => arena.set_bytes(column, row, value.as_bytes()),
                    },
                }
            }
            arena.set_i64(fields, row, checkpoint);
            arena.set_f64(fields + 1, row, if delete { 1.0 } else { 0.0 });
        }
        arena.seal_unlent(&names).unwrap();
        ChangeSet::new(entity, chain_id, keeps_history, arena).unwrap()
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::{change_set, Change};
    use super::*;
    use crate::storage::schema::{Field, FieldType};
    use pretty_assertions::assert_eq;

    fn account() -> Arc<Entity> {
        Arc::new(Entity {
            index: 0,
            name: "Account".to_string(),
            history_table: "envio_history_Account".to_string(),
            fields: vec![
                Field {
                    is_primary_key: true,
                    ..Field::new("id", FieldType::String)
                },
                Field::new("owner", FieldType::String),
            ],
            chain_id: None,
            postgres: true,
            clickhouse: None,
            composite_indexes: vec![],
            derived_from: vec![],
        })
    }

    #[test]
    fn the_latest_change_of_each_id_wins_in_the_order_ids_first_changed() {
        let changes = change_set(
            account(),
            None,
            false,
            &[
                Change::Set(&[Some("b"), Some("x")], 1),
                Change::Set(&[Some("a"), Some("y")], 1),
                Change::Delete("b", 2),
                Change::Set(&[Some("a"), Some("z")], 3),
            ],
        );
        assert_eq!(
            changes.project(None),
            Projection {
                sets: vec![3],
                deletes: vec![2],
                ..Projection::default()
            }
        );
    }

    #[test]
    fn a_change_the_rollback_restored_is_no_history_and_needs_no_backfill() {
        let changes = change_set(
            account(),
            None,
            true,
            &[
                Change::Set(&[Some("a"), Some("restored")], 7),
                Change::Set(&[Some("a"), Some("later")], 8),
                Change::Delete("b", 8),
            ],
        );
        assert_eq!(
            changes.project(Some(7)),
            Projection {
                sets: vec![1],
                deletes: vec![2],
                history_sets: vec![1],
                history_deletes: vec![2],
                backfill: vec![2],
            }
        );
    }
}
