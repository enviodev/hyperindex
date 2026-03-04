use async_graphql::dataloader::Loader;
use serde_json::Value as JsonValue;
use sqlx::Row;
use std::collections::HashMap;
use std::sync::Arc;

use super::schema::{row_to_json, ServerContext};

/// Key for batching FK lookups: load one related entity row by its id.
#[derive(Clone, Hash, Eq, PartialEq, Debug)]
pub struct FkKey {
    pub entity_name: String,
    pub id: String,
}

/// Batches FK lookups across all entity types into per-entity `WHERE id IN (...)` queries.
pub struct FkLoader {
    pub ctx: Arc<ServerContext>,
}

impl Loader<FkKey> for FkLoader {
    type Value = JsonValue;
    type Error = Arc<sqlx::Error>;

    async fn load(&self, keys: &[FkKey]) -> Result<HashMap<FkKey, Self::Value>, Self::Error> {
        // Group keys by entity_name
        let mut by_entity: HashMap<&str, Vec<&str>> = HashMap::new();
        for key in keys {
            by_entity
                .entry(&key.entity_name)
                .or_default()
                .push(&key.id);
        }

        let mut results = HashMap::new();

        for (entity_name, ids) in &by_entity {
            let cols = match self.ctx.entity_columns.get(*entity_name) {
                Some(c) => c,
                None => continue,
            };

            let col_list = cols
                .iter()
                .map(|c| format!("\"{}\"", c))
                .collect::<Vec<_>>()
                .join(", ");

            // Build parameterized IN clause
            let placeholders: Vec<String> = (1..=ids.len()).map(|i| format!("${}", i)).collect();
            let query = format!(
                "SELECT {} FROM \"{}\".\"{}\" WHERE \"id\" IN ({})",
                col_list,
                self.ctx.pg_schema,
                entity_name,
                placeholders.join(", ")
            );

            let mut sql_query = sqlx::query(&query);
            for id in ids {
                sql_query = sql_query.bind(*id);
            }

            let rows = sql_query.fetch_all(&self.ctx.pool).await?;

            for row in rows {
                let json = row_to_json(&row, cols);
                if let Some(id_val) = json.get("id").and_then(|v| v.as_str()) {
                    results.insert(
                        FkKey {
                            entity_name: entity_name.to_string(),
                            id: id_val.to_string(),
                        },
                        json,
                    );
                }
            }
        }

        Ok(results)
    }
}

/// Key for batching @derivedFrom lookups: load child rows by parent id.
#[derive(Clone, Hash, Eq, PartialEq, Debug)]
pub struct DerivedKey {
    pub target_entity: String,
    pub filter_column: String,
    pub parent_id: String,
}

/// Batches @derivedFrom lookups into per-(entity, column) `WHERE col IN (...)` queries.
/// Returns Vec<JsonValue> because one parent can have multiple derived children.
pub struct DerivedLoader {
    pub ctx: Arc<ServerContext>,
}

impl Loader<DerivedKey> for DerivedLoader {
    type Value = Vec<JsonValue>;
    type Error = Arc<sqlx::Error>;

    async fn load(
        &self,
        keys: &[DerivedKey],
    ) -> Result<HashMap<DerivedKey, Self::Value>, Self::Error> {
        // Group by (target_entity, filter_column)
        let mut by_group: HashMap<(&str, &str), Vec<&str>> = HashMap::new();
        for key in keys {
            by_group
                .entry((&key.target_entity, &key.filter_column))
                .or_default()
                .push(&key.parent_id);
        }

        let mut results: HashMap<DerivedKey, Vec<JsonValue>> = HashMap::new();
        // Pre-fill empty vecs so that missing parents still get an empty list
        for key in keys {
            results.entry(key.clone()).or_default();
        }

        for ((entity_name, filter_col), parent_ids) in &by_group {
            let cols = match self.ctx.entity_columns.get(*entity_name) {
                Some(c) => c,
                None => continue,
            };

            let col_list = cols
                .iter()
                .map(|c| format!("\"{}\"", c))
                .collect::<Vec<_>>()
                .join(", ");

            // Include the filter column in the SELECT so we can group results back
            let needs_filter_col = !cols.iter().any(|c| c == *filter_col);
            let select_list = if needs_filter_col {
                format!("{}, \"{}\"", col_list, filter_col)
            } else {
                col_list
            };

            let placeholders: Vec<String> =
                (1..=parent_ids.len()).map(|i| format!("${}", i)).collect();
            let query = format!(
                "SELECT {} FROM \"{}\".\"{}\" WHERE \"{}\" IN ({})",
                select_list,
                self.ctx.pg_schema,
                entity_name,
                filter_col,
                placeholders.join(", ")
            );

            let mut sql_query = sqlx::query(&query);
            for pid in parent_ids {
                sql_query = sql_query.bind(*pid);
            }

            let rows = sql_query.fetch_all(&self.ctx.pool).await?;

            for row in rows {
                let json = row_to_json(&row, cols);
                // Extract the filter column value to map back to the parent
                let parent_id_val: Option<String> = row.try_get(*filter_col).ok();
                if let Some(pid) = parent_id_val {
                    let key = DerivedKey {
                        target_entity: entity_name.to_string(),
                        filter_column: filter_col.to_string(),
                        parent_id: pid,
                    };
                    results.entry(key).or_default().push(json);
                }
            }
        }

        Ok(results)
    }
}
