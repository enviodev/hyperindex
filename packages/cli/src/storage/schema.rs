//! The entities as storage keeps them, resolved once from the config the CLI
//! hands the runtime. Every store derives its tables from these, and every
//! batch JavaScript stages follows the layout they declare, so the runtime
//! never describes a table itself.

use std::collections::BTreeMap;
use std::sync::Arc;

use anyhow::{anyhow, bail, Context, Result};
use serde::Deserialize;

use super::types::Sequence;
use crate::columnar::ColumnKind;
use crate::config_parsing::human_config::ColumnNameFormat;
use crate::config_parsing::system_config::ChainIdMode;

/// The schema's scalars, as the table model names them. `BigInt` and
/// `BigDecimal` carry the precision and scale a `@config` directive set, which
/// only they can be given.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum FieldType {
    String,
    Boolean,
    Uint32,
    UInt52,
    SmallInt,
    Bytea,
    UInt64,
    Int32,
    ChainId,
    Number,
    BigInt { precision: Option<u32> },
    BigDecimal { config: Option<(u32, u32)> },
    Serial,
    BigSerial,
    Json,
    Date,
    Enum { name: String, variants: Vec<String> },
}

/// How a value has to arrive in a staged batch: what JavaScript turns it into,
/// and so the slot it travels in. One encoding per value whatever store keeps
/// it — each store converts from it on its own side.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[napi_derive::napi(string_enum)]
pub enum Encoding {
    /// A JavaScript number.
    Number,
    /// 1 or 0.
    Bool,
    /// Milliseconds since the Unix epoch.
    Date,
    Text,
    /// A bigint's decimal digits.
    Digits,
    /// A decimal's digits, never in exponent notation.
    Decimal,
    /// A JSON document's text, keys sorted.
    Document,
    Bytes,
    /// The JSON text of the list, every element in its own encoding and a
    /// list of bytes as its byte values.
    List,
}

impl Encoding {
    pub fn kind(self) -> ColumnKind {
        match self {
            Encoding::Number | Encoding::Bool | Encoding::Date => ColumnKind::F64,
            Encoding::Text
            | Encoding::Digits
            | Encoding::Decimal
            | Encoding::Document
            | Encoding::List => ColumnKind::Text,
            Encoding::Bytes => ColumnKind::Bytes,
        }
    }
}

impl FieldType {
    /// How one value of the type is encoded, a list's elements included.
    pub fn encoding(&self) -> Encoding {
        match self {
            FieldType::Boolean => Encoding::Bool,
            FieldType::Int32
            | FieldType::Uint32
            | FieldType::UInt52
            | FieldType::SmallInt
            | FieldType::Number
            | FieldType::ChainId
            | FieldType::Serial => Encoding::Number,
            FieldType::Date => Encoding::Date,
            FieldType::String | FieldType::Enum { .. } => Encoding::Text,
            FieldType::BigInt { .. } | FieldType::UInt64 | FieldType::BigSerial => Encoding::Digits,
            FieldType::BigDecimal { .. } => Encoding::Decimal,
            FieldType::Json => Encoding::Document,
            FieldType::Bytea => Encoding::Bytes,
        }
    }
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Field {
    /// What handlers and getWhere name it: an entity reference's carries
    /// `_id`.
    pub name: String,
    /// What schema.graphql names it, which is what an index or a
    /// `@storage(clickhouse: {...})` expression refers to it by.
    pub schema_name: String,
    pub pg_column: String,
    pub ch_column: String,
    pub field_type: FieldType,
    pub is_array: bool,
    pub is_nullable: bool,
    pub is_primary_key: bool,
    pub is_index: bool,
    pub default_value: Option<String>,
}

impl Field {
    pub fn new(name: &str, field_type: FieldType) -> Self {
        Self {
            name: name.to_string(),
            schema_name: name.to_string(),
            pg_column: name.to_string(),
            ch_column: name.to_string(),
            field_type,
            is_array: false,
            is_nullable: false,
            is_primary_key: false,
            is_index: false,
            default_value: None,
        }
    }

    pub fn encoding(&self) -> Encoding {
        if self.is_array {
            Encoding::List
        } else {
            self.field_type.encoding()
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Direction {
    Asc,
    Desc,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct IndexField {
    /// The schema field, as `@index` names it.
    pub field: String,
    pub direction: Direction,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct DerivedFrom {
    pub entity: String,
    pub field: String,
}

#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct ClickHouseOptions {
    pub partition_by: Option<String>,
    pub order_by: Option<Vec<String>>,
    pub ttl: Option<String>,
    pub skipping_indexes: Vec<SkippingIndex>,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct SkippingIndex {
    pub name: String,
    pub expr: String,
    pub index_type: String,
    pub granularity: Option<u32>,
}

/// The column a per-chain entity's rows carry their chain in. It completes the
/// key, but no handler sees it: a batch's rows take it from the chain they
/// were written for.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct ChainIdColumn {
    pub pg_column: String,
    pub ch_column: String,
}

impl ChainIdColumn {
    pub fn field(&self) -> Field {
        Field {
            pg_column: self.pg_column.clone(),
            ch_column: self.ch_column.clone(),
            is_primary_key: true,
            ..Field::new(CHAIN_ID_FIELD, FieldType::ChainId)
        }
    }
}

pub const CHAIN_ID_FIELD: &str = "chainId";
pub const ID_FIELD: &str = "id";
const HISTORY_TABLE_PREFIX: &str = "envio_history_";
const MAX_PG_TABLE_NAME_LENGTH: usize = 63;

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Entity {
    /// Its position in the config, which is how the runtime names it.
    pub index: usize,
    /// The schema's name for it, which its Postgres table and its ClickHouse
    /// view are called by.
    pub name: String,
    pub history_table: String,
    /// What a row stores, in the order a staged batch lays the values out.
    pub fields: Vec<Field>,
    pub chain_id: Option<ChainIdColumn>,
    pub postgres: bool,
    pub clickhouse: Option<ClickHouseOptions>,
    pub composite_indexes: Vec<Vec<IndexField>>,
    /// Fields resolved from the other side of a relationship, which nothing
    /// stores.
    pub derived_from: Vec<DerivedFrom>,
}

/// Postgres truncates identifiers past its limit on its own, which would
/// collapse two long names onto one. Cutting the readable half and keeping
/// `unique_suffix` whole makes every generated name distinct by construction,
/// so the suffix has to be something already unique to the table it names.
pub fn fit_pg_table_name(full_name: &str, unique_suffix: &str) -> String {
    if full_name.len() > MAX_PG_TABLE_NAME_LENGTH {
        let keep = MAX_PG_TABLE_NAME_LENGTH.saturating_sub(unique_suffix.len());
        let mut cut = keep.min(full_name.len());
        while !full_name.is_char_boundary(cut) {
            cut -= 1;
        }
        format!("{}{unique_suffix}", &full_name[..cut])
    } else {
        full_name.to_string()
    }
}

impl Entity {
    pub fn id(&self) -> Result<(usize, &Field)> {
        self.fields
            .iter()
            .enumerate()
            .find(|(_, field)| field.name == ID_FIELD)
            .ok_or_else(|| anyhow!("Entity \"{}\" has no id field", self.name))
    }

    /// The Postgres column an index or a relationship names by its schema
    /// spelling: a declared field's, or the chain column envio appends to a
    /// per-chain entity.
    pub fn pg_column(&self, schema_name: &str) -> Option<&str> {
        self.fields
            .iter()
            .find(|field| field.schema_name == schema_name)
            .map(|field| field.pg_column.as_str())
            .or_else(|| {
                self.chain_id
                    .as_ref()
                    .filter(|_| schema_name == CHAIN_ID_FIELD)
                    .map(|chain_id| chain_id.pg_column.as_str())
            })
    }

    /// A per-chain entity's rows are partitioned by the chain that owns them,
    /// so a chain-filtered read scans one chain's partition rather than the
    /// whole table. `$` can't occur in a GraphQL entity name, so a partition
    /// name can never collide with the table another entity claims; past the
    /// identifier limit the entity index keeps what survives truncation
    /// unique.
    pub fn partition_table_name(&self, chain_id: i64) -> String {
        fit_pg_table_name(
            &format!("{}${chain_id}", self.name),
            &format!("${}${chain_id}", self.index),
        )
    }
}

/// A Date's milliseconds as the ISO instant a timestamp column reads.
pub fn iso_millis(ms: i64) -> String {
    let days = ms.div_euclid(86_400_000);
    let ms = ms.rem_euclid(86_400_000);
    // Days since 1970-01-01 to a civil date, via a 400-year era whose day
    // count is fixed; March-based so leap days fall at the end of the year.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        ms / 3_600_000,
        ms / 60_000 % 60,
        ms / 1000 % 60,
        ms % 1000
    )
}

pub const RAW_EVENTS_TABLE: &str = "raw_events";

/// What a raw event row stores, in the order a staged batch lays it out. The
/// `serial` key is the table's own.
pub fn raw_event_fields() -> Vec<Field> {
    let field = Field::new;
    vec![
        field("chain_id", FieldType::ChainId),
        field("event_id", FieldType::UInt64),
        field("event_name", FieldType::String),
        field("contract_name", FieldType::String),
        field("block_number", FieldType::Int32),
        field("log_index", FieldType::Int32),
        field("src_address", FieldType::String),
        field("block_hash", FieldType::String),
        field("block_timestamp", FieldType::Int32),
        field("block_fields", FieldType::Json),
        field("transaction_fields", FieldType::Json),
        field("params", FieldType::Json),
    ]
}

pub fn raw_events_key() -> Field {
    Field {
        is_nullable: true,
        is_primary_key: true,
        ..Field::new("serial", FieldType::BigSerial)
    }
}

/// Every effect's cache keeps the same two columns, whatever its output.
pub fn effect_cache_fields() -> Vec<Field> {
    vec![
        Field {
            is_primary_key: true,
            ..Field::new("id", FieldType::String)
        },
        Field {
            is_nullable: true,
            ..Field::new("output", FieldType::Json)
        },
    ]
}

/// `$` can't occur in a GraphQL entity name, so it marks where a truncated
/// name stops and the index that keeps it unique begins.
pub fn history_table_name(entity_name: &str, entity_index: usize) -> String {
    fit_pg_table_name(
        &format!("{HISTORY_TABLE_PREFIX}{entity_name}"),
        &format!("${entity_index}"),
    )
}

#[derive(Debug)]
pub struct Schema {
    pub entities: Vec<Arc<Entity>>,
    pub enums: Vec<(String, Vec<String>)>,
    pub sequence: Sequence,
    pub chain_id_mode: ChainIdMode,
}

impl Schema {
    pub fn empty(chain_id_mode: ChainIdMode) -> Self {
        Self {
            entities: Vec::new(),
            enums: Vec::new(),
            sequence: Sequence::PerChain,
            chain_id_mode,
        }
    }

    pub fn entity(&self, index: u32) -> Result<&Arc<Entity>> {
        self.entities
            .get(index as usize)
            .ok_or_else(|| anyhow!("The schema has no entity {index}"))
    }

    /// The entities, enums and storage settings of the config the CLI wrote,
    /// read the way the runtime reads them: whatever the CLI left out because
    /// it is the default is resolved here, to the same default.
    pub fn from_config_json(json: &str) -> Result<Self> {
        let config: ConfigJson =
            serde_json::from_str(json).context("Failed reading the config's entities")?;
        config.resolve()
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConfigJson {
    #[serde(default = "default_chain_id_mode")]
    chain_id_mode: ChainIdMode,
    #[serde(default = "default_true")]
    default_cross_chain: bool,
    storage: StorageJson,
    #[serde(default)]
    enums: BTreeMap<String, Vec<String>>,
    #[serde(default)]
    entities: Vec<EntityJson>,
}

fn default_chain_id_mode() -> ChainIdMode {
    ChainIdMode::Int32
}

fn default_true() -> bool {
    true
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StorageJson {
    postgres: bool,
    #[serde(default)]
    clickhouse: bool,
    postgres_column_name_format: Option<ColumnNameFormat>,
    clickhouse_column_name_format: Option<ColumnNameFormat>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EntityJson {
    name: String,
    cross_chain: Option<bool>,
    storage: Option<EntityStorageJson>,
    properties: Vec<PropertyJson>,
    #[serde(default)]
    derived_fields: Vec<DerivedFieldJson>,
    #[serde(default, rename = "compositeIndices")]
    composite_indexes: Vec<Vec<CompositeIndexJson>>,
}

#[derive(Deserialize)]
struct EntityStorageJson {
    postgres: Option<bool>,
    clickhouse: Option<ClickHouseStorageJson>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum ClickHouseStorageJson {
    Enabled(bool),
    Options(ClickHouseOptionsJson),
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClickHouseOptionsJson {
    partition_by: Option<String>,
    order_by: Option<Vec<String>>,
    ttl: Option<String>,
    skipping_indexes: Option<Vec<SkippingIndexJson>>,
}

#[derive(Deserialize)]
struct SkippingIndexJson {
    name: String,
    expr: String,
    #[serde(rename = "type")]
    index_type: String,
    granularity: Option<u32>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PropertyJson {
    name: String,
    postgres_db_name: Option<String>,
    clickhouse_db_name: Option<String>,
    #[serde(rename = "type")]
    field_type: String,
    #[serde(default)]
    is_nullable: bool,
    #[serde(default)]
    is_array: bool,
    #[serde(default)]
    is_index: bool,
    linked_entity: Option<String>,
    #[serde(rename = "enum")]
    enum_name: Option<String>,
    precision: Option<u32>,
    scale: Option<u32>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DerivedFieldJson {
    derived_from_entity: String,
    derived_from_field: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CompositeIndexJson {
    field_name: String,
    direction: String,
}

fn chain_id_column_name(format: Option<ColumnNameFormat>) -> String {
    match format.unwrap_or(ColumnNameFormat::Original) {
        ColumnNameFormat::Original => CHAIN_ID_FIELD.to_string(),
        ColumnNameFormat::SnakeCase => "chain_id".to_string(),
    }
}

impl ConfigJson {
    fn resolve(self) -> Result<Schema> {
        let chain_id = ChainIdColumn {
            pg_column: chain_id_column_name(self.storage.postgres_column_name_format),
            ch_column: chain_id_column_name(self.storage.clickhouse_column_name_format),
        };
        let entities = self
            .entities
            .into_iter()
            .enumerate()
            .map(|(index, entity)| {
                let name = entity.name.clone();
                entity
                    .resolve(
                        index,
                        &self.enums,
                        &self.storage,
                        self.default_cross_chain,
                        &chain_id,
                    )
                    .with_context(|| format!("Failed reading entity \"{name}\""))
                    .map(Arc::new)
            })
            .collect::<Result<Vec<_>>>()?;
        // A cross-chain entity has rows any chain's reorg can reach, so its
        // checkpoints have to be comparable across chains.
        let sequence = if entities.iter().any(|entity| entity.chain_id.is_none()) {
            Sequence::SharedAcrossChains
        } else {
            Sequence::PerChain
        };
        Ok(Schema {
            entities,
            enums: self.enums.into_iter().collect(),
            sequence,
            chain_id_mode: self.chain_id_mode,
        })
    }
}

impl EntityJson {
    fn resolve(
        self,
        index: usize,
        enums: &BTreeMap<String, Vec<String>>,
        storage: &StorageJson,
        default_cross_chain: bool,
        chain_id: &ChainIdColumn,
    ) -> Result<Entity> {
        let fields = self
            .properties
            .into_iter()
            .map(|property| property.resolve(enums))
            .collect::<Result<Vec<_>>>()?;
        let (postgres, clickhouse) = match self.storage {
            None => (
                storage.postgres,
                storage.clickhouse.then(ClickHouseOptions::default),
            ),
            Some(directive) => (
                directive.postgres.unwrap_or(false),
                match directive.clickhouse {
                    None | Some(ClickHouseStorageJson::Enabled(false)) => None,
                    Some(ClickHouseStorageJson::Enabled(true)) => {
                        Some(ClickHouseOptions::default())
                    }
                    Some(ClickHouseStorageJson::Options(options)) => Some(ClickHouseOptions {
                        partition_by: options.partition_by,
                        order_by: options.order_by,
                        ttl: options.ttl,
                        skipping_indexes: options
                            .skipping_indexes
                            .unwrap_or_default()
                            .into_iter()
                            .map(|index| SkippingIndex {
                                name: index.name,
                                expr: index.expr,
                                index_type: index.index_type,
                                granularity: index.granularity,
                            })
                            .collect(),
                    }),
                },
            ),
        };
        let composite_indexes = self
            .composite_indexes
            .into_iter()
            .map(|index| {
                index
                    .into_iter()
                    .map(|field| {
                        Ok(IndexField {
                            field: field.field_name,
                            direction: match field.direction.as_str() {
                                "Asc" => Direction::Asc,
                                "Desc" => Direction::Desc,
                                other => bail!("`{other}` is not an index direction"),
                            },
                        })
                    })
                    .collect::<Result<Vec<_>>>()
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(Entity {
            index,
            history_table: history_table_name(&self.name, index),
            name: self.name,
            fields,
            chain_id: (!self.cross_chain.unwrap_or(default_cross_chain)).then(|| chain_id.clone()),
            postgres,
            clickhouse,
            composite_indexes,
            derived_from: self
                .derived_fields
                .into_iter()
                .map(|field| DerivedFrom {
                    entity: field.derived_from_entity,
                    field: field.derived_from_field,
                })
                .collect(),
        })
    }
}

impl PropertyJson {
    fn resolve(self, enums: &BTreeMap<String, Vec<String>>) -> Result<Field> {
        let field_type = match self.field_type.as_str() {
            "string" => FieldType::String,
            "bytes" => FieldType::Bytea,
            "boolean" => FieldType::Boolean,
            "int" => FieldType::Int32,
            "bigint" => FieldType::BigInt {
                precision: self.precision,
            },
            "bigdecimal" => FieldType::BigDecimal {
                config: self
                    .precision
                    .map(|precision| (precision, self.scale.unwrap_or(0))),
            },
            "float" => FieldType::Number,
            "serial" => FieldType::Serial,
            "json" => FieldType::Json,
            "date" => FieldType::Date,
            "enum" => {
                let name = self
                    .enum_name
                    .ok_or_else(|| anyhow!("Field \"{}\" names no enum", self.name))?;
                let variants = enums
                    .get(&name)
                    .ok_or_else(|| anyhow!("The config has no enum \"{name}\""))?
                    .clone();
                FieldType::Enum { name, variants }
            }
            other => bail!("Field \"{}\" has an unknown type `{other}`", self.name),
        };
        let name = match self.linked_entity {
            Some(_) => format!("{}_id", self.name),
            None => self.name.clone(),
        };
        Ok(Field {
            pg_column: self.postgres_db_name.unwrap_or_else(|| name.clone()),
            ch_column: self.clickhouse_db_name.unwrap_or_else(|| name.clone()),
            is_primary_key: self.name == ID_FIELD,
            schema_name: self.name,
            name,
            field_type,
            is_array: self.is_array,
            is_nullable: self.is_nullable,
            is_index: self.is_index,
            default_value: None,
        })
    }
}

#[cfg(test)]
pub mod test_support {
    use super::*;

    pub fn id() -> Field {
        Field {
            is_primary_key: true,
            ..Field::new(ID_FIELD, FieldType::String)
        }
    }

    /// An entity both stores keep, per-chain when `chain_id` names its column.
    pub fn entity(name: &str, fields: Vec<Field>, chain_id: Option<&str>) -> Entity {
        Entity {
            index: 0,
            name: name.to_string(),
            history_table: history_table_name(name, 0),
            fields,
            chain_id: chain_id.map(|column| ChainIdColumn {
                pg_column: column.to_string(),
                ch_column: column.to_string(),
            }),
            postgres: true,
            clickhouse: Some(ClickHouseOptions::default()),
            composite_indexes: Vec::new(),
            derived_from: Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config_parsing::system_config::SystemConfig;
    use pretty_assertions::assert_eq;
    use std::collections::HashMap;

    fn schema_of(yaml: &str, graphql: &str) -> Schema {
        let config =
            SystemConfig::parse_yaml(yaml, Some(graphql), &HashMap::new(), &HashMap::new(), false)
                .unwrap();
        Schema::from_config_json(&config.to_public_config_json(false).unwrap()).unwrap()
    }

    const YAML: &str = r#"
name: test
chains:
  - id: 1
    start_block: 0
    contracts: []
"#;

    #[test]
    fn an_entity_resolves_from_the_config_the_cli_writes() {
        let schema = schema_of(
            &format!(
                "{YAML}disable_default_cross_chain: true\nstorage:\n  postgres:\n    column_name_format: snake_case\n"
            ),
            r#"
enum Kind { A B }
type Owner @crossChain { id: ID! }
type Account {
  id: ID!
  owner: Owner!
  balanceRaw: BigInt! @index
  kind: Kind
  tags: [String!]!
}
"#,
        );
        let account = schema
            .entities
            .iter()
            .find(|entity| entity.name == "Account")
            .unwrap();
        assert_eq!(
            (
                schema.sequence,
                account.history_table.clone(),
                account.chain_id.clone(),
                account
                    .fields
                    .iter()
                    .map(|field| (
                        field.name.clone(),
                        field.pg_column.clone(),
                        field.encoding(),
                        field.is_index
                    ))
                    .collect::<Vec<_>>(),
                account.fields[3].field_type.clone(),
            ),
            (
                Sequence::SharedAcrossChains,
                "envio_history_Account".to_string(),
                Some(ChainIdColumn {
                    pg_column: "chain_id".to_string(),
                    ch_column: "chainId".to_string(),
                }),
                vec![
                    ("id".to_string(), "id".to_string(), Encoding::Text, false),
                    (
                        "owner_id".to_string(),
                        "owner_id".to_string(),
                        Encoding::Text,
                        false
                    ),
                    (
                        "balanceRaw".to_string(),
                        "balance_raw".to_string(),
                        Encoding::Digits,
                        true
                    ),
                    (
                        "kind".to_string(),
                        "kind".to_string(),
                        Encoding::Text,
                        false
                    ),
                    (
                        "tags".to_string(),
                        "tags".to_string(),
                        Encoding::List,
                        false
                    ),
                ],
                FieldType::Enum {
                    name: "Kind".to_string(),
                    variants: vec!["A".to_string(), "B".to_string()]
                },
            )
        );
    }

    #[test]
    fn a_long_name_keeps_its_unique_suffix_whole() {
        let name = "A".repeat(70);
        assert_eq!(
            (
                history_table_name(&name, 12),
                history_table_name("Short", 0)
            ),
            (
                format!("envio_history_{}$12", "A".repeat(46)),
                "envio_history_Short".to_string()
            )
        );
    }

    /// `$` can't appear in a GraphQL entity name, so a partition can never
    /// take a name another entity's table claims. Past 63 bytes the readable
    /// half is cut and the entity index keeps what's left unique.
    #[test]
    fn a_partition_is_named_by_its_chain_and_fits_the_identifier_limit() {
        let long_name = format!("CounterWith60CharacterName{}", "_".repeat(34));
        let schema = schema_of(
            &format!("{YAML}disable_default_cross_chain: true\n"),
            &format!(
                "type Counter {{ id: ID! }}\ntype {long_name} {{ id: ID! }}\ntype Global @crossChain {{ id: ID! }}"
            ),
        );
        let names =
            |entity: &Entity| [1, 137].map(|chain_id| entity.partition_table_name(chain_id));
        let long = &schema.entities[1];
        assert_eq!(
            (
                names(&schema.entities[0]),
                names(long),
                schema.entities[2].chain_id.is_none(),
            ),
            (
                ["Counter$1".to_string(), "Counter$137".to_string()],
                [
                    format!("{long_name}$1"),
                    format!("{}$1$137", &long_name[..63 - "$1$137".len()]),
                ],
                true,
            )
        );
    }
}
