use anyhow::{bail, Context, Result};

use super::ch_type::{ChType, FieldSpec};
use super::ddl::{self, ColumnSpec, EntitySpec, SkippingIndexSpec};
use crate::config_parsing::system_config::ChainIdMode;
use crate::storage::rows::{ColumnRead, ReadKind};
use crate::storage::schema::{Entity, Field, FieldType};
use crate::storage::types::CHANGE_COLUMN;

pub struct Column {
    pub name: String,
    pub row_name: String,
    pub field: Field,
    pub ch_type: ChType,
    /// What a value reads back as — a list's elements, for a list.
    pub read: ReadKind,
}

/// Where one column of a history row comes from in a staged change set.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    /// The entity's field at this position.
    Field(usize),
    /// The chain the change set was written for.
    ChainId,
    Checkpoint,
    Change,
}

/// An entity as ClickHouse keeps it: every change a row of its history table.
pub struct Table {
    pub columns: Vec<Column>,
    /// What a history row carries, in order: the entity's columns, then the
    /// checkpoint and the change.
    pub staged: Vec<(String, ChType)>,
    /// Where each of `staged` comes from.
    pub sources: Vec<Source>,
    pub insert_query: String,
    pub entity: EntitySpec,
}

impl FieldSpec {
    /// What a stored value reads back as: whatever Postgres hands back for the
    /// same field, so a row decodes the same from either store. A 64-bit
    /// integer and an unbounded number are text there, since a JavaScript
    /// number would lose their digits.
    pub fn read_kind(&self, chain_id_mode: ChainIdMode) -> ReadKind {
        match self.field_type {
            FieldType::Boolean => ReadKind::Bool,
            FieldType::Int32 | FieldType::Serial | FieldType::SmallInt | FieldType::Number => {
                ReadKind::Float
            }
            FieldType::ChainId => match chain_id_mode {
                ChainIdMode::Int32 => ReadKind::Float,
                ChainIdMode::Int64 => ReadKind::Text,
            },
            FieldType::Bytea => ReadKind::Bytes,
            FieldType::Json => ReadKind::Json,
            FieldType::Date => ReadKind::Timestamp,
            _ => ReadKind::Text,
        }
    }
}

impl Table {
    pub fn new(entity: &Entity, database: &str, chain_id_mode: ChainIdMode) -> Result<Self> {
        let context = format!("ClickHouse table `{}`", entity.name);
        let options = entity.clickhouse.clone().unwrap_or_default();
        let chain_id = entity.chain_id.as_ref().map(|chain_id| chain_id.field());
        let mut columns = Vec::with_capacity(entity.fields.len() + 1);
        let mut specs = Vec::with_capacity(entity.fields.len() + 1);
        let mut sources = Vec::with_capacity(entity.fields.len() + 3);
        for (source, field) in entity
            .fields
            .iter()
            .enumerate()
            .map(|(index, field)| (Source::Field(index), field))
            .chain(chain_id.iter().map(|field| (Source::ChainId, field)))
        {
            let spec = ColumnSpec {
                name: field.ch_column.clone(),
                field_name: field.schema_name.clone(),
                field: field.clone(),
            };
            let (_, ch_type) = spec.typed(chain_id_mode, &context)?;
            columns.push(Column {
                name: field.ch_column.clone(),
                row_name: field.pg_column.clone(),
                read: field.read_kind(chain_id_mode),
                field: field.clone(),
                ch_type,
            });
            specs.push(spec);
            sources.push(source);
        }
        if columns.is_empty() {
            bail!("{context} was registered with no columns");
        }
        sources.extend([Source::Checkpoint, Source::Change]);
        let entity = EntitySpec {
            name: entity.name.clone(),
            history_table: entity.history_table.clone(),
            columns: specs,
            chain_id_column: chain_id.map(|field| field.ch_column),
            partition_by: options.partition_by,
            order_by: options.order_by,
            ttl: options.ttl,
            skipping_indexes: options
                .skipping_indexes
                .into_iter()
                .map(|index| SkippingIndexSpec {
                    name: index.name,
                    expr: index.expr,
                    index_type: index.index_type,
                    granularity: index.granularity,
                })
                .collect(),
        };
        let staged = entity.history_columns(chain_id_mode)?;
        let insert_query = ddl::insert_query(
            database,
            &entity.history_table,
            staged.iter().map(|(name, _)| name),
        );
        Ok(Self {
            columns,
            staged,
            sources,
            insert_query,
            entity,
        })
    }

    pub fn column(&self, row_name: &str) -> Option<&Column> {
        self.columns
            .iter()
            .find(|column| column.row_name == row_name)
    }

    pub fn key_columns(&self) -> Result<Vec<&Column>> {
        self.entity
            .key()
            .iter()
            .map(|name| {
                self.columns
                    .iter()
                    .find(|column| &column.name == name)
                    .with_context(|| format!("\"{}\" has no column `{name}`", self.entity.name))
            })
            .collect()
    }

    /// How a row of the table's columns decodes, and what it reads as.
    pub fn reads(&self) -> (Vec<(ChType, ReadKind)>, Vec<ColumnRead>) {
        self.columns
            .iter()
            .map(|column| {
                let read = if column.field.is_array {
                    ColumnRead::list(&column.row_name, column.read)
                } else {
                    ColumnRead::scalar(&column.row_name, column.read)
                };
                ((column.ch_type.clone(), column.read), read)
            })
            .unzip()
    }

    /// [`Self::reads`] of a history row, which carries its change too.
    pub fn history_reads(&self) -> (Vec<(ChType, ReadKind)>, Vec<ColumnRead>) {
        let (mut types, mut reads) = self.reads();
        types.push((ddl::change_type(), ReadKind::Text));
        reads.push(ColumnRead::scalar(CHANGE_COLUMN, ReadKind::Text));
        (types, reads)
    }
}

#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use crate::clickhouse::ch_type::test_support::field;
    use crate::storage::schema::{test_support::entity, ChainIdColumn};

    pub fn column(name: &str, field_type: &str) -> Field {
        Field {
            name: name.to_string(),
            schema_name: name.to_string(),
            pg_column: name.to_string(),
            ch_column: name.to_string(),
            ..field(field_type)
        }
    }

    pub fn entity_input(name: &str, fields: Vec<Field>) -> Entity {
        entity(name, fields, None)
    }

    /// An entity whose owner column is renamed, and whose balance is an
    /// unbounded BigInt kept as text.
    pub fn account() -> Table {
        Table::new(
            &entity_input(
                "Account",
                vec![
                    column("id", "String"),
                    Field {
                        ch_column: "owner_name".to_string(),
                        ..column("ownerName", "String")
                    },
                    column("balance", "BigInt"),
                ],
            ),
            "db",
            ChainIdMode::Int32,
        )
        .unwrap()
    }

    pub fn per_chain_account() -> Table {
        Table::new(
            &Entity {
                chain_id: Some(ChainIdColumn {
                    pg_column: "chainId".to_string(),
                    ch_column: "chain_id".to_string(),
                }),
                ..entity_input("Account", vec![column("id", "String")])
            },
            "db",
            ChainIdMode::Int32,
        )
        .unwrap()
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::*;
    use super::*;
    use pretty_assertions::assert_eq;

    /// What a value reads back as is what Postgres hands back for the same
    /// field, so a row parses the same whichever store answered.
    #[test]
    fn values_read_back_as_postgres_returns_them() {
        let read = |field_type: &str, chain_id_mode| {
            crate::clickhouse::ch_type::test_support::field(field_type).read_kind(chain_id_mode)
        };
        assert_eq!(
            [
                read("Uint32", ChainIdMode::Int32),
                read("UInt52", ChainIdMode::Int32),
                read("Int32", ChainIdMode::Int32),
                read("ChainId", ChainIdMode::Int32),
                read("ChainId", ChainIdMode::Int64),
                read("BigDecimal", ChainIdMode::Int32),
                read("Json", ChainIdMode::Int32),
                read("Date", ChainIdMode::Int32),
                read("Bytea", ChainIdMode::Int32),
                read("Boolean", ChainIdMode::Int32),
            ],
            [
                ReadKind::Text,
                ReadKind::Text,
                ReadKind::Float,
                ReadKind::Float,
                ReadKind::Text,
                ReadKind::Text,
                ReadKind::Json,
                ReadKind::Timestamp,
                ReadKind::Bytes,
                ReadKind::Bool,
            ]
        );
    }

    #[test]
    fn an_entity_stages_its_history_row() {
        let table = account();
        assert_eq!(
            (
                table.entity.history_table.as_str(),
                table
                    .staged
                    .iter()
                    .map(|(name, _)| name.as_str())
                    .collect::<Vec<_>>(),
                table.insert_query.as_str(),
            ),
            (
                "envio_history_Account",
                vec![
                    "id",
                    "owner_name",
                    "balance",
                    "envio_checkpoint_id",
                    "envio_change"
                ],
                "INSERT INTO `db`.`envio_history_Account` (`id`, `owner_name`, `balance`, \
                 `envio_checkpoint_id`, `envio_change`) FORMAT RowBinary"
            )
        );
    }

    #[test]
    fn a_type_the_store_cannot_hold_is_refused_at_registration() {
        let refused = Table::new(
            &entity_input("Account", vec![column("id", "SmallInt")]),
            "db",
            ChainIdMode::Int32,
        )
        .err()
        .map(|error| format!("{error:#}"));
        assert_eq!(
            refused,
            Some(
                "Column `id` of ClickHouse table `Account`: ClickHouse doesn't support the \
                 internal SmallInt column type"
                    .to_string()
            )
        );
    }

    /// The entity's table as ClickHouse keeps it, read from the config a user
    /// writes the way the runtime reads it.
    fn from_config(yaml: &str, graphql: &str, entity: &str) -> Table {
        let config = crate::config_parsing::system_config::SystemConfig::parse_yaml(
            yaml,
            Some(graphql),
            &std::collections::HashMap::new(),
            &std::collections::HashMap::new(),
            false,
        )
        .unwrap();
        let schema = crate::storage::schema::Schema::from_config_json(
            &config.to_public_config_json(false).unwrap(),
        )
        .unwrap();
        let entity = schema
            .entities
            .iter()
            .find(|candidate| candidate.name == entity)
            .unwrap();
        Table::new(entity, "db", schema.chain_id_mode).unwrap()
    }

    fn per_chain_yaml(column_name_format: &str) -> String {
        format!(
            "name: per-chain-directive-fields
disable_default_cross_chain: true
storage:
  postgres:
    default: true
  clickhouse:
    default: true
    column_name_format: {column_name_format}
chains:
  - id: 1
    start_block: 0
  - id: 137
    start_block: 0
"
        )
    }

    /// What the sorting key and the columns come to: each column's name and
    /// type, the chain column envio appended, and the `orderBy` as written.
    type Shape = (Vec<(String, String)>, Option<String>, Option<Vec<String>>);

    fn shape(table: &Table) -> Shape {
        (
            table
                .columns
                .iter()
                .map(|column| (column.name.clone(), column.ch_type.to_string()))
                .collect(),
            table.entity.chain_id_column.clone(),
            table.entity.order_by.clone(),
        )
    }

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    /// A bounded BigInt stores as a Decimal, which sorts numerically, and id
    /// leads a sorting key that narrows further.
    #[test]
    fn a_sorting_key_names_the_columns_the_schema_lists() {
        let yaml = "name: order-by
storage:
  postgres:
    default: true
  clickhouse:
    default: true
chains:
  - id: 1
    start_block: 0
";
        assert_eq!(
            (
                shape(&from_config(
                    yaml,
                    "type Token @storage(clickhouse: {orderBy: [\"id\", \"timestamp\"]}) {
  id: ID!
  timestamp: Timestamp!
}",
                    "Token",
                )),
                shape(&from_config(
                    yaml,
                    "type Token @storage(clickhouse: {orderBy: [\"amount\"]}) {
  id: ID!
  amount: BigInt! @config(precision: 38)
}",
                    "Token",
                )),
            ),
            (
                (
                    vec![
                        ("id".to_string(), "String".to_string()),
                        ("timestamp".to_string(), "DateTime64(3, 'UTC')".to_string()),
                    ],
                    None,
                    Some(strings(&["id", "timestamp"])),
                ),
                (
                    vec![
                        ("id".to_string(), "String".to_string()),
                        ("amount".to_string(), "Decimal(38,0)".to_string()),
                    ],
                    None,
                    Some(strings(&["amount"])),
                ),
            )
        );
    }

    /// https://github.com/enviodev/hyperindex/issues/1542
    ///
    /// The chain column envio appends is a column like any other: an
    /// `orderBy` names it by its schema spelling, keeps its position, and may
    /// name it alone. A declared `chainId` on a cross-chain entity is the
    /// user's own column, which nothing stamps on a write.
    #[test]
    fn the_appended_chain_column_sorts_like_any_other() {
        let transfer = |order_by: &str, cross_chain: bool, chain_id_field: bool| {
            shape(&from_config(
                &per_chain_yaml("snake_case"),
                &format!(
                    "type Transfer{} @storage(clickhouse: {{orderBy: [{order_by}]}}) {{
  id: ID!{}
  timestamp: Timestamp!
}}",
                    if cross_chain { " @crossChain" } else { "" },
                    if chain_id_field {
                        "\n  chainId: Int!"
                    } else {
                        ""
                    },
                ),
                "Transfer",
            ))
        };
        let per_chain_columns = vec![
            ("id".to_string(), "String".to_string()),
            ("timestamp".to_string(), "DateTime64(3, 'UTC')".to_string()),
            ("chain_id".to_string(), "Int32".to_string()),
        ];
        assert_eq!(
            [
                transfer("\"chainId\", \"timestamp\"", false, false),
                transfer("\"chainId\"", false, false),
                transfer("\"timestamp\", \"chainId\"", false, false),
                transfer("\"chainId\", \"timestamp\"", true, true),
            ],
            [
                (
                    per_chain_columns.clone(),
                    Some("chain_id".to_string()),
                    Some(strings(&["chainId", "timestamp"])),
                ),
                (
                    per_chain_columns.clone(),
                    Some("chain_id".to_string()),
                    Some(strings(&["chainId"])),
                ),
                (
                    per_chain_columns,
                    Some("chain_id".to_string()),
                    Some(strings(&["timestamp", "chainId"])),
                ),
                (
                    vec![
                        ("id".to_string(), "String".to_string()),
                        ("chain_id".to_string(), "Int32".to_string()),
                        ("timestamp".to_string(), "DateTime64(3, 'UTC')".to_string()),
                    ],
                    None,
                    Some(strings(&["chainId", "timestamp"])),
                ),
            ]
        );
    }

    /// The chain-id mode decides whether a per-chain entity's chain column is
    /// an Int32 or a UInt64, from the widest chain id in the config.
    #[test]
    fn a_chain_column_widens_with_the_chain_ids() {
        let chain_type = |id: &str| {
            let table = from_config(
                &format!(
                    "name: per-chain
disable_default_cross_chain: true
storage:
  clickhouse:
    default: true
chains:
  - id: {id}
    rpc: https://rpc.example.test
    start_block: 0
"
                ),
                "type Transfer {
  id: ID!
  amount: BigInt! @config(precision: 38)
}",
                "Transfer",
            );
            table
                .columns
                .iter()
                .find(|column| column.name == "chainId")
                .unwrap()
                .ch_type
                .to_string()
        };
        assert_eq!(
            (chain_type("2147483647"), chain_type("2494104990")),
            ("Int32".to_string(), "UInt64".to_string())
        );
    }
}
