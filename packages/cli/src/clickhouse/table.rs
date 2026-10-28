use anyhow::{bail, Context, Result};
use napi_derive::napi;

use super::ch_type::{ChType, FieldSpec};
use super::ddl::{self, ColumnSpec, EntitySpec, SkippingIndexSpec};
use crate::columnar::ColumnKind;
use crate::config_parsing::system_config::ChainIdMode;
use crate::storage::rows::{ColumnRead, ReadKind};
use crate::storage::types::CHANGE_COLUMN;

#[napi(object)]
#[derive(Clone)]
pub struct ClickHouseColumnInput {
    pub name: String,
    /// What rows read the column back as, which is the name the other side
    /// parses them by. Omitted when it matches `name`.
    pub row_name: Option<String>,
    /// The schema field, which `@storage(clickhouse: {...})` expressions name.
    /// Omitted when it matches `name`.
    pub field_name: Option<String>,
    pub field_type: String,
    pub is_nullable: bool,
    pub is_array: bool,
    pub precision: Option<u32>,
    pub scale: Option<u32>,
    pub enum_variants: Option<Vec<String>>,
}

#[napi(object)]
#[derive(Clone)]
pub struct ClickHouseTableInput {
    /// The entity's name, which its view is called by.
    pub name: String,
    /// Where the entity's rows are kept.
    pub history_table: String,
    pub columns: Vec<ClickHouseColumnInput>,
    pub chain_id_column: Option<String>,
    pub partition_by: Option<String>,
    pub order_by: Option<Vec<String>>,
    pub ttl: Option<String>,
    pub skipping_indexes: Option<Vec<SkippingIndexSpec>>,
}

pub struct Column {
    pub name: String,
    pub row_name: String,
    pub field: FieldSpec,
    pub ch_type: ChType,
    /// What a value reads back as — a list's elements, for a list.
    pub read: ReadKind,
}

/// An entity as ClickHouse keeps it: every change a row of its history table.
pub struct Table {
    pub columns: Vec<Column>,
    /// What a staged batch carries, in order: the entity's columns, then the
    /// checkpoint and the change.
    pub staged: Vec<(String, ChType)>,
    pub insert_query: String,
    pub entity: EntitySpec,
}

impl FieldSpec {
    /// What a stored value reads back as: whatever Postgres hands back for the
    /// same field, so a row decodes the same from either store. A 64-bit integer
    /// and an unbounded number are text there, since a JavaScript number would
    /// lose their digits.
    pub fn read_kind(&self, chain_id_mode: ChainIdMode) -> ReadKind {
        match self.field_type.as_str() {
            "Boolean" => ReadKind::Bool,
            "Int32" | "Serial" | "SmallInt" | "Number" => ReadKind::Float,
            "ChainId" => match chain_id_mode {
                ChainIdMode::Int32 => ReadKind::Float,
                ChainIdMode::Int64 => ReadKind::Text,
            },
            "Bytea" => ReadKind::Bytes,
            "Json" => ReadKind::Json,
            "Date" => ReadKind::Timestamp,
            _ => ReadKind::Text,
        }
    }
}

impl Table {
    pub fn new(
        input: ClickHouseTableInput,
        database: &str,
        chain_id_mode: ChainIdMode,
    ) -> Result<Self> {
        let context = format!("ClickHouse table `{}`", input.name);
        let mut columns = Vec::with_capacity(input.columns.len());
        let mut specs = Vec::with_capacity(input.columns.len());
        for column in input.columns {
            let field = FieldSpec {
                field_type: column.field_type,
                is_nullable: column.is_nullable,
                is_array: column.is_array,
                precision: column.precision,
                scale: column.scale,
                enum_variants: column.enum_variants,
            };
            let spec = ColumnSpec {
                field_name: column.field_name.unwrap_or_else(|| column.name.clone()),
                name: column.name.clone(),
                field: field.clone(),
            };
            let (_, ch_type) = spec.typed(chain_id_mode, &context)?;
            columns.push(Column {
                row_name: column.row_name.unwrap_or_else(|| column.name.clone()),
                read: field.read_kind(chain_id_mode),
                name: column.name,
                field,
                ch_type,
            });
            specs.push(spec);
        }
        if columns.is_empty() {
            bail!("{context} was registered with no columns");
        }
        let entity = EntitySpec {
            name: input.name,
            history_table: input.history_table,
            columns: specs,
            chain_id_column: input.chain_id_column,
            partition_by: input.partition_by,
            order_by: input.order_by,
            ttl: input.ttl,
            skipping_indexes: input.skipping_indexes.unwrap_or_default(),
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

    /// The staged columns' names, kinds and whether each is nullable, in order.
    pub fn staged_layout(&self) -> (Vec<String>, Vec<ColumnKind>, Vec<bool>) {
        let mut names = Vec::with_capacity(self.staged.len());
        let mut kinds = Vec::with_capacity(self.staged.len());
        let mut nullable = Vec::with_capacity(self.staged.len());
        for (name, ch_type) in &self.staged {
            names.push(name.clone());
            kinds.push(ch_type.column_kind());
            nullable.push(matches!(ch_type, ChType::Nullable(_)));
        }
        (names, kinds, nullable)
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

    pub fn column(name: &str, field_type: &str) -> ClickHouseColumnInput {
        ClickHouseColumnInput {
            name: name.to_string(),
            row_name: None,
            field_name: None,
            field_type: field_type.to_string(),
            is_nullable: false,
            is_array: false,
            precision: None,
            scale: None,
            enum_variants: None,
        }
    }

    pub fn entity_input(name: &str, columns: Vec<ClickHouseColumnInput>) -> ClickHouseTableInput {
        ClickHouseTableInput {
            name: name.to_string(),
            history_table: format!("envio_history_{name}"),
            columns,
            chain_id_column: None,
            partition_by: None,
            order_by: None,
            ttl: None,
            skipping_indexes: None,
        }
    }

    /// An entity whose owner column is renamed, and whose balance is an
    /// unbounded BigInt kept as text.
    pub fn account() -> Table {
        Table::new(
            entity_input(
                "Account",
                vec![
                    column("id", "String"),
                    ClickHouseColumnInput {
                        row_name: Some("ownerName".to_string()),
                        field_name: Some("ownerName".to_string()),
                        ..column("owner_name", "String")
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
            ClickHouseTableInput {
                chain_id_column: Some("chain_id".to_string()),
                ..entity_input(
                    "Account",
                    vec![
                        column("id", "String"),
                        ClickHouseColumnInput {
                            row_name: Some("chainId".to_string()),
                            ..column("chain_id", "ChainId")
                        },
                    ],
                )
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
            entity_input("Account", vec![column("id", "Tuple")]),
            "db",
            ChainIdMode::Int32,
        )
        .err()
        .map(|error| format!("{error:#}"));
        assert_eq!(
            refused,
            Some(
                "Column `id` of ClickHouse table `Account`: unsupported field type `Tuple`"
                    .to_string()
            )
        );
    }
}
