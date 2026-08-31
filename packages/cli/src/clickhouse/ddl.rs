use std::collections::HashMap;
use std::fmt::Write as _;
use std::sync::LazyLock;

use anyhow::{bail, Result};
use napi_derive::napi;
use regex::{Captures, Regex};

use super::ch_type::{ChType, FieldSpec};
use super::{literal, quoted};
use crate::config_parsing::system_config::ChainIdMode;

#[derive(Debug, Clone)]
pub struct ColumnSpec {
    pub name: String,
    pub field_name: String,
    pub field: FieldSpec,
}

#[napi(object)]
#[derive(Debug, Clone)]
pub struct SkippingIndexSpec {
    pub name: String,
    pub expr: String,
    pub index_type: String,
    pub granularity: Option<u32>,
}

#[derive(Debug, Clone)]
pub struct EntitySpec {
    pub name: String,
    pub history_table: String,
    pub columns: Vec<ColumnSpec>,
    pub chain_id_column: Option<String>,
    pub partition_by: Option<String>,
    pub order_by: Option<Vec<String>>,
    pub ttl: Option<String>,
    pub skipping_indexes: Vec<SkippingIndexSpec>,
}

#[napi(object)]
#[derive(Debug, Clone)]
pub struct HistorySchema {
    pub id_column: String,
    pub checkpoint_id_column: String,
    pub change_column: String,
    pub change_variants: Vec<String>,
    pub set_variant: String,
    pub checkpoints_table: String,
    /// Columns of the checkpoints table a resume reads to decide which
    /// checkpoints each chain's recorded progress already covers.
    pub checkpoint_chain_id_column: String,
    pub checkpoint_block_number_column: String,
    pub history_table_prefix: String,
}

#[derive(Debug, Clone, Copy)]
pub struct Topology {
    pub replicated: bool,
    /// Whether table-level DDL carries its own `ON CLUSTER`. A `Replicated`
    /// database engine propagates DDL through its own log, and combining the two
    /// is rejected — so the clause is only for the plain-database case.
    pub ddl_on_cluster: bool,
}

impl Topology {
    fn engine(&self) -> &'static str {
        if self.replicated {
            "ReplicatedMergeTree"
        } else {
            "MergeTree()"
        }
    }

    pub fn on_cluster(&self) -> &'static str {
        on_cluster_clause(self.ddl_on_cluster)
    }

    /// ReplicatedMergeTree drops an insert whose block hash is already in
    /// Keeper, and mutations don't clear those hashes. Crash recovery trims the
    /// history tail past the committed Postgres checkpoint and replays it, so an
    /// identical replayed block would be discarded while still reporting success
    /// — a permanent gap nothing surfaces. Trim-then-replay is what makes
    /// recovery correct here, and the duplicates dedup would have caught are
    /// already collapsed by the view's `LIMIT 1 BY`. Plain MergeTree goes by
    /// `non_replicated_deduplication_window` (0 by default), so it needs no
    /// clause.
    fn settings(&self) -> &'static str {
        if self.replicated {
            "\nSETTINGS replicated_deduplication_window = 0"
        } else {
            ""
        }
    }
}

/// A plain database created with ON CLUSTER doesn't turn subsequent DDL into
/// cluster-wide statements; ClickHouse keeps no "this database is clustered"
/// flag. Without a Replicated database engine, every CREATE must carry its own
/// ON CLUSTER to reach all replicas, otherwise it runs only on the connected
/// node. The '{cluster}' macro resolves to each node's configured cluster name.
pub fn on_cluster_clause(on_cluster: bool) -> &'static str {
    if on_cluster {
        " ON CLUSTER '{cluster}'"
    } else {
        ""
    }
}

pub fn database_engine_name(engine_spec: &str) -> &str {
    engine_spec
        .trim()
        .split('(')
        .next()
        .unwrap_or_default()
        .split(' ')
        .next()
        .unwrap_or_default()
        .trim()
}

impl HistorySchema {
    fn trailing_columns(&self) -> Vec<(String, ChType)> {
        vec![
            (self.checkpoint_id_column.clone(), ChType::UInt64),
            (
                self.change_column.clone(),
                ChType::Enum {
                    variants: self.change_variants.clone(),
                },
            ),
        ]
    }
}

impl ColumnSpec {
    pub fn typed(&self, chain_id_mode: ChainIdMode, context: &str) -> Result<(String, ChType)> {
        let ch_type = self
            .field
            .ch_type(chain_id_mode)
            .map_err(|error| error.context(format!("Column `{}` of {context}", self.name)))?;
        Ok((self.name.clone(), ch_type))
    }
}

impl EntitySpec {
    pub fn history_columns(
        &self,
        history: &HistorySchema,
        chain_id_mode: ChainIdMode,
    ) -> Result<Vec<(String, ChType)>> {
        let context = format!("entity `{}`", self.name);
        let mut columns = self
            .columns
            .iter()
            .map(|column| column.typed(chain_id_mode, &context))
            .collect::<Result<Vec<_>>>()?;
        columns.extend(history.trailing_columns());
        Ok(columns)
    }

    fn column_by_field_name(&self) -> HashMap<&str, &str> {
        self.columns
            .iter()
            .map(|column| (column.field_name.as_str(), column.name.as_str()))
            .collect()
    }
}

static EXPRESSION_TOKEN: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`|"(?:[^"\\]|\\.)*"|[A-Za-z_][A-Za-z0-9_]*"#)
        .expect("expression token regex")
});

fn resolve_expression_columns(expression: &str, columns: &HashMap<&str, &str>) -> String {
    EXPRESSION_TOKEN
        .replace_all(expression, |captures: &Captures| {
            let token = &captures[0];
            match columns.get(token) {
                Some(column) => quoted(column),
                None => token.to_string(),
            }
        })
        .into_owned()
}

pub fn create_history_table(
    entity: &EntitySpec,
    database: &str,
    history: &HistorySchema,
    topology: Topology,
    chain_id_mode: ChainIdMode,
) -> Result<String> {
    let columns = entity.history_columns(history, chain_id_mode)?;
    let definitions: Vec<String> = columns
        .iter()
        .map(|(name, ch_type)| format!("{} {ch_type}", quoted(name)))
        .collect();

    let by_field_name = entity.column_by_field_name();

    let order_by = match &entity.order_by {
        Some(field_names) => {
            let mut resolved = Vec::with_capacity(field_names.len());
            for field_name in field_names {
                match by_field_name.get(field_name.as_str()) {
                    Some(column) => resolved.push(quoted(column)),
                    None => bail!(
                        "ClickHouse orderBy field \"{field_name}\" is not defined on entity \"{}\"",
                        entity.name
                    ),
                }
            }
            format!(
                "{}, {}",
                resolved.join(", "),
                quoted(&history.checkpoint_id_column)
            )
        }
        None => format!(
            "{}, {}",
            quoted(&history.id_column),
            quoted(&history.checkpoint_id_column)
        ),
    };

    let partition_by = match &entity.partition_by {
        Some(expression) => format!(
            "\nPARTITION BY {}",
            resolve_expression_columns(expression, &by_field_name)
        ),
        None => String::new(),
    };
    let ttl = match &entity.ttl {
        Some(expression) => format!(
            "\nTTL {}",
            resolve_expression_columns(expression, &by_field_name)
        ),
        None => String::new(),
    };

    let mut indexes = String::new();
    for index in &entity.skipping_indexes {
        let granularity = match index.granularity {
            Some(granularity) => format!(" GRANULARITY {granularity}"),
            None => String::new(),
        };
        write!(
            indexes,
            ",\n  INDEX {} {} TYPE {}{granularity}",
            quoted(&index.name),
            resolve_expression_columns(&index.expr, &by_field_name),
            index.index_type
        )
        .expect("writing to a String cannot fail");
    }

    Ok(format!(
        "CREATE TABLE IF NOT EXISTS {}.{}{} (\n  {}{indexes}\n)\nENGINE = {}{partition_by}\nORDER BY ({order_by}){ttl}{}",
        quoted(database),
        quoted(&entity.history_table),
        topology.on_cluster(),
        definitions.join(",\n  "),
        topology.engine(),
        topology.settings(),
    ))
}

pub fn create_checkpoints_table(
    columns: &[(String, ChType)],
    database: &str,
    history: &HistorySchema,
    topology: Topology,
) -> String {
    let definitions: Vec<String> = columns
        .iter()
        .map(|(name, ch_type)| format!("  {} {ch_type}", quoted(name)))
        .collect();
    format!(
        "CREATE TABLE IF NOT EXISTS {}.{}{} (\n{}\n)\nENGINE = {}\nORDER BY ({}){}",
        quoted(database),
        quoted(&history.checkpoints_table),
        topology.on_cluster(),
        definitions.join(",\n"),
        topology.engine(),
        quoted(&history.id_column),
        topology.settings(),
    )
}

pub fn create_view(
    entity: &EntitySpec,
    database: &str,
    history: &HistorySchema,
    topology: Topology,
) -> String {
    let mut dedup_key = vec![quoted(&history.id_column)];
    if let Some(chain_id_column) = &entity.chain_id_column {
        dedup_key.push(quoted(chain_id_column));
    }

    let entity_fields: Vec<String> = entity
        .columns
        .iter()
        .map(|column| quoted(&column.name))
        .collect();
    let entity_fields = entity_fields.join(", ");

    format!(
        "CREATE VIEW IF NOT EXISTS {db}.{}{} AS\nSELECT {entity_fields}\nFROM (\n  SELECT {entity_fields}, {}\n  FROM {db}.{}\n  WHERE {} <= (SELECT max({}) FROM {db}.{})\n  ORDER BY {} DESC\n  LIMIT 1 BY {}\n)\nWHERE {} = {}",
        quoted(&entity.name),
        topology.on_cluster(),
        quoted(&history.change_column),
        quoted(&entity.history_table),
        quoted(&history.checkpoint_id_column),
        quoted(&history.id_column),
        quoted(&history.checkpoints_table),
        quoted(&history.checkpoint_id_column),
        dedup_key.join(", "),
        quoted(&history.change_column),
        literal(&history.set_variant),
        db = quoted(database),
    )
}

pub fn insert_query(
    database: &str,
    table: &str,
    columns: impl Iterator<Item = impl AsRef<str>>,
) -> String {
    let names: Vec<String> = columns.map(|name| quoted(name.as_ref())).collect();
    format!(
        "INSERT INTO {}.{} ({}) FORMAT RowBinary",
        quoted(database),
        quoted(table),
        names.join(", ")
    )
}

/// Trims one history table's rows past the checkpoint being resumed from.
///
/// `ALTER ... DELETE` schedules a mutation rather than running one, so without
/// `mutations_sync` the statement returns while the rows are still there and
/// resume would report a rewind it has only asked for. Waiting for every
/// replica (`2`) is what makes the storage actually be at the checkpoint by the
/// time the indexer starts writing again.
pub fn trim_history_table(
    database: &str,
    table: &str,
    history: &HistorySchema,
    checkpoint_id: &str,
) -> String {
    format!(
        "ALTER TABLE {}.{} DELETE WHERE {} > {checkpoint_id} SETTINGS mutations_sync = 2",
        quoted(database),
        quoted(table),
        quoted(&history.checkpoint_id_column)
    )
}

/// Trims the checkpoints past the one being resumed from.
///
/// `DELETE FROM` is a lightweight delete, which `mutations_sync` has no say
/// over — `lightweight_deletes_sync` is the setting that makes the statement
/// wait for the rows to actually be masked. Named explicitly rather than left to
/// the server default, which a profile is free to set to 0: resume would then
/// return with checkpoints still above the frontier, and replayed rows would
/// become readable through a checkpoint that no longer covers them.
pub fn trim_checkpoints(database: &str, history: &HistorySchema, checkpoint_id: &str) -> String {
    format!(
        "DELETE FROM {}.{} WHERE {} > {checkpoint_id} SETTINGS lightweight_deletes_sync = 2",
        quoted(database),
        quoted(&history.checkpoints_table),
        quoted(&history.id_column)
    )
}

#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use crate::clickhouse::ch_type::test_support::field;

    pub fn history_schema() -> HistorySchema {
        HistorySchema {
            id_column: "id".to_string(),
            checkpoint_id_column: "envio_checkpoint_id".to_string(),
            change_column: "envio_change".to_string(),
            change_variants: vec!["SET".to_string(), "DELETE".to_string()],
            set_variant: "SET".to_string(),
            checkpoints_table: "envio_checkpoints".to_string(),
            checkpoint_chain_id_column: "chain_id".to_string(),
            checkpoint_block_number_column: "block_number".to_string(),
            history_table_prefix: "envio_history_".to_string(),
        }
    }

    pub fn plain() -> Topology {
        Topology {
            replicated: false,
            ddl_on_cluster: false,
        }
    }

    pub fn replicated() -> Topology {
        Topology {
            replicated: true,
            ddl_on_cluster: true,
        }
    }

    pub fn column(name: &str, field_type: &str) -> ColumnSpec {
        ColumnSpec {
            name: name.to_string(),
            field_name: name.to_string(),
            field: field(field_type),
        }
    }

    pub fn entity(name: &str, columns: Vec<ColumnSpec>) -> EntitySpec {
        EntitySpec {
            name: name.to_string(),
            history_table: format!("envio_history_{name}"),
            columns,
            chain_id_column: None,
            partition_by: None,
            order_by: None,
            ttl: None,
            skipping_indexes: Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::*;
    use super::*;
    use crate::clickhouse::ch_type::test_support::field;
    use pretty_assertions::assert_eq;

    fn typed(columns: &[ColumnSpec]) -> Vec<(String, ChType)> {
        columns
            .iter()
            .map(|column| {
                column
                    .typed(ChainIdMode::Int32, "the checkpoints table")
                    .unwrap()
            })
            .collect()
    }

    fn render(entity: &EntitySpec, topology: Topology) -> String {
        create_history_table(
            entity,
            "test_db",
            &history_schema(),
            topology,
            ChainIdMode::Int32,
        )
        .unwrap()
    }

    #[test]
    fn creates_a_history_table_with_the_checkpoint_and_change_columns_appended() {
        let entity = entity(
            "Account",
            vec![column("id", "String"), column("balance", "Int32")],
        );
        assert_eq!(
            render(&entity, plain()),
            "CREATE TABLE IF NOT EXISTS `test_db`.`envio_history_Account` (\n  \
             `id` String,\n  \
             `balance` Int32,\n  \
             `envio_checkpoint_id` UInt64,\n  \
             `envio_change` Enum8('SET' = 1, 'DELETE' = 2)\n\
             )\n\
             ENGINE = MergeTree()\n\
             ORDER BY (`id`, `envio_checkpoint_id`)"
        );
    }

    #[test]
    fn a_replicated_table_carries_the_engine_cluster_and_dedup_settings() {
        let entity = entity("Account", vec![column("id", "String")]);
        assert_eq!(
            render(&entity, replicated()),
            "CREATE TABLE IF NOT EXISTS `test_db`.`envio_history_Account` ON CLUSTER '{cluster}' (\n  \
             `id` String,\n  \
             `envio_checkpoint_id` UInt64,\n  \
             `envio_change` Enum8('SET' = 1, 'DELETE' = 2)\n\
             )\n\
             ENGINE = ReplicatedMergeTree\n\
             ORDER BY (`id`, `envio_checkpoint_id`)\n\
             SETTINGS replicated_deduplication_window = 0"
        );
    }

    #[test]
    fn table_options_resolve_field_names_to_columns() {
        let mut entity = entity(
            "Account",
            vec![
                column("id", "String"),
                ColumnSpec {
                    name: "created_at".to_string(),
                    field_name: "createdAt".to_string(),
                    field: field("Date"),
                },
            ],
        );
        entity.order_by = Some(vec!["createdAt".to_string()]);
        entity.partition_by = Some("toYYYYMM(createdAt)".to_string());
        entity.ttl = Some("createdAt + INTERVAL 1 MONTH".to_string());
        entity.skipping_indexes = vec![SkippingIndexSpec {
            name: "idx_created".to_string(),
            expr: "createdAt".to_string(),
            index_type: "minmax".to_string(),
            granularity: Some(4),
        }];
        assert_eq!(
            render(&entity, plain()),
            "CREATE TABLE IF NOT EXISTS `test_db`.`envio_history_Account` (\n  \
             `id` String,\n  \
             `created_at` DateTime64(3, 'UTC'),\n  \
             `envio_checkpoint_id` UInt64,\n  \
             `envio_change` Enum8('SET' = 1, 'DELETE' = 2),\n  \
             INDEX `idx_created` `created_at` TYPE minmax GRANULARITY 4\n\
             )\n\
             ENGINE = MergeTree()\n\
             PARTITION BY toYYYYMM(`created_at`)\n\
             ORDER BY (`created_at`, `envio_checkpoint_id`)\n\
             TTL `created_at` + INTERVAL 1 MONTH"
        );
    }

    #[test]
    fn expression_rewriting_leaves_everything_that_is_not_a_field_alone() {
        let columns = HashMap::from([("createdAt", "created_at"), ("kind", "kind")]);
        let resolved = [
            "toYYYYMM(createdAt)",
            "kind = 'createdAt'",
            "`createdAt` + 1",
            "toStartOfDay(createdAt) + INTERVAL 7 DAY",
            "toYYYYMM(\"created_at\")",
            "kind = 'a' || \"createdAt\"",
            // ClickHouse reads C-style escapes inside a literal, so a \' does
            // not end one and nothing inside is a bare identifier.
            r"kind = 'a\'createdAt b'",
        ]
        .map(|expression| resolve_expression_columns(expression, &columns));
        assert_eq!(
            resolved,
            [
                "toYYYYMM(`created_at`)",
                "`kind` = 'createdAt'",
                "`createdAt` + 1",
                "toStartOfDay(`created_at`) + INTERVAL 7 DAY",
                "toYYYYMM(\"created_at\")",
                "`kind` = 'a' || \"createdAt\"",
                r"`kind` = 'a\'createdAt b'",
            ]
        );
    }

    #[test]
    fn rejects_an_order_by_field_the_entity_does_not_have() {
        let mut entity = entity("Account", vec![column("id", "String")]);
        entity.order_by = Some(vec!["missing".to_string()]);
        assert_eq!(
            create_history_table(
                &entity,
                "test_db",
                &history_schema(),
                plain(),
                ChainIdMode::Int32
            )
            .unwrap_err()
            .to_string(),
            "ClickHouse orderBy field \"missing\" is not defined on entity \"Account\""
        );
    }

    #[test]
    fn creates_the_checkpoints_table() {
        let columns = [
            column("id", "UInt64"),
            column("chain_id", "ChainId"),
            column("block_number", "Int32"),
            ColumnSpec {
                field: FieldSpec {
                    is_nullable: true,
                    ..field("String")
                },
                ..column("block_hash", "String")
            },
        ];
        assert_eq!(
            create_checkpoints_table(&typed(&columns), "test_db", &history_schema(), plain()),
            "CREATE TABLE IF NOT EXISTS `test_db`.`envio_checkpoints` (\n  \
             `id` UInt64,\n  \
             `chain_id` Int32,\n  \
             `block_number` Int32,\n  \
             `block_hash` Nullable(String)\n\
             )\n\
             ENGINE = MergeTree()\n\
             ORDER BY (`id`)"
        );
    }

    #[test]
    fn a_replicated_checkpoints_table_carries_the_engine_cluster_and_dedup_settings() {
        let columns = [column("id", "UInt64")];
        assert_eq!(
            create_checkpoints_table(&typed(&columns), "test_db", &history_schema(), replicated()),
            "CREATE TABLE IF NOT EXISTS `test_db`.`envio_checkpoints` ON CLUSTER '{cluster}' (\n  \
             `id` UInt64\n\
             )\n\
             ENGINE = ReplicatedMergeTree\n\
             ORDER BY (`id`)\n\
             SETTINGS replicated_deduplication_window = 0"
        );
    }

    #[test]
    fn creates_a_view_over_the_history_table() {
        let entity = entity(
            "Account",
            vec![column("id", "String"), column("balance", "Int32")],
        );
        assert_eq!(
            create_view(&entity, "test_db", &history_schema(), plain()),
            "CREATE VIEW IF NOT EXISTS `test_db`.`Account` AS\n\
             SELECT `id`, `balance`\n\
             FROM (\n  \
             SELECT `id`, `balance`, `envio_change`\n  \
             FROM `test_db`.`envio_history_Account`\n  \
             WHERE `envio_checkpoint_id` <= (SELECT max(`id`) FROM `test_db`.`envio_checkpoints`)\n  \
             ORDER BY `envio_checkpoint_id` DESC\n  \
             LIMIT 1 BY `id`\n\
             )\n\
             WHERE `envio_change` = 'SET'"
        );
    }

    #[test]
    fn a_replicated_view_is_created_on_the_cluster() {
        let entity = entity("Account", vec![column("id", "String")]);
        assert_eq!(
            create_view(&entity, "test_db", &history_schema(), replicated())
                .lines()
                .next(),
            Some("CREATE VIEW IF NOT EXISTS `test_db`.`Account` ON CLUSTER '{cluster}' AS")
        );
    }

    #[test]
    fn a_per_chain_entity_dedups_on_id_and_chain() {
        let mut entity = entity(
            "Account",
            vec![column("id", "String"), column("chain_id", "ChainId")],
        );
        entity.chain_id_column = Some("chain_id".to_string());
        assert!(create_view(&entity, "test_db", &history_schema(), plain())
            .contains("LIMIT 1 BY `id`, `chain_id`"));
    }

    #[test]
    fn strips_arguments_and_settings_from_a_database_engine() {
        let names = [
            "Replicated('/p','{shard}','{replica}') SETTINGS x=1",
            "Replicated SETTINGS x=1",
            "  Atomic  ",
        ]
        .map(database_engine_name);
        assert_eq!(names, ["Replicated", "Replicated", "Atomic"]);
    }

    #[test]
    fn names_every_column_the_insert_sends_and_escapes_them() {
        assert_eq!(
            insert_query(
                "db",
                "envio_history_Account",
                ["id", "bal`ance", r"back\slash"].iter()
            ),
            concat!(
                "INSERT INTO `db`.`envio_history_Account` ",
                r"(`id`, `bal``ance`, `back\\slash`) FORMAT RowBinary"
            )
        );
    }

    #[test]
    fn trims_history_and_checkpoints_past_a_checkpoint() {
        let history = history_schema();
        assert_eq!(
            (
                trim_history_table("db", "envio_history_Account", &history, "42"),
                trim_checkpoints("db", &history, "42")
            ),
            (
                "ALTER TABLE `db`.`envio_history_Account` DELETE WHERE \
                 `envio_checkpoint_id` > 42 SETTINGS mutations_sync = 2"
                    .to_string(),
                "DELETE FROM `db`.`envio_checkpoints` WHERE `id` > 42 \
                 SETTINGS lightweight_deletes_sync = 2"
                    .to_string()
            )
        );
    }
}
