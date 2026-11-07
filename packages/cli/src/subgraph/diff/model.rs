use std::collections::BTreeMap;

use anyhow::{anyhow, Result};
use graphql_parser::schema::{Definition, Document, Type, TypeDefinition};

use crate::subgraph::{errors::Report, schema};

/// How graph-node encodes a value of one stored type, which is what the diff
/// compares on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scalar {
    /// `ID`, `String` and enums: compared verbatim.
    Text,
    Bytes,
    /// `BigInt`, `Int`, `Int8` and `Timestamp`: an integer in any encoding.
    Integer,
    BigDecimal,
    Boolean,
}

impl Scalar {
    fn from_kind(kind: &str) -> Self {
        match kind {
            "Bytes" => Scalar::Bytes,
            "BigInt" | "Int" | "Int8" | "Timestamp" => Scalar::Integer,
            "BigDecimal" => Scalar::BigDecimal,
            "Boolean" => Scalar::Boolean,
            _ => Scalar::Text,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FieldKind {
    Scalar(Scalar),
    /// A relation, compared by the id it points at, which is encoded the way
    /// the target's id is.
    Entity {
        target_id: Scalar,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Field {
    pub name: String,
    pub kind: FieldKind,
    pub list: bool,
    /// Whether the schema lets the field be null (`Account` rather than
    /// `Account!`).
    pub nullable: bool,
    /// The type a relation points at.
    pub target: Option<String>,
    /// The subgraph's own spelling of the type, for messages.
    pub declared: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entity {
    pub name: String,
    pub id: Scalar,
    /// Stored fields other than `id`, in declaration order.
    pub fields: Vec<Field>,
    /// Fields neither side stores, so neither can be compared.
    pub derived: Vec<String>,
    /// How a graph endpoint serves the rows when not as an entity of this
    /// name: an aggregation interval's table.
    pub served: Option<Served>,
}

/// One interval of an `@aggregation`, stored as `<Aggregation>_<interval>`
/// and served as `<collection>(interval: <interval>)`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Served {
    pub type_name: String,
    pub args: String,
}

impl Entity {
    /// The object type a graph endpoint serves the rows as.
    pub fn graph_type(&self) -> &str {
        self.served
            .as_ref()
            .map_or(self.name.as_str(), |served| served.type_name.as_str())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Model {
    pub entities: Vec<Entity>,
    /// Types the schema declares that have no table to compare, with why.
    pub skipped: Vec<(String, String)>,
}

impl Model {
    pub fn from_schema(schema_text: &str) -> Result<Self> {
        let document: Document<'_, String> = graphql_parser::parse_schema(schema_text)
            .map_err(|err| anyhow!("Failed to parse the subgraph schema: {err}"))?;

        // The translator's findings are about what envio can index; the diff
        // only needs the declared field types, which it records regardless.
        let mut discard = Report::new();
        let translation = schema::translate(schema_text, &mut discard);

        let mut entities = Vec::new();
        let mut skipped = Vec::new();
        for definition in &document.definitions {
            let Definition::TypeDefinition(TypeDefinition::Object(object)) = definition else {
                continue;
            };
            if object.name == "_Schema_" {
                continue;
            }
            let nullable: BTreeMap<String, bool> = object
                .fields
                .iter()
                .map(|field| {
                    (
                        field.name.clone(),
                        !matches!(field.field_type, Type::NonNullType(_)),
                    )
                })
                .collect();
            let stored = |name: &str| {
                let types = translation
                    .entity_field_types
                    .get(name)
                    .cloned()
                    .unwrap_or_default();
                let order = translation
                    .entity_fields
                    .get(name)
                    .cloned()
                    .unwrap_or_default();
                entity(name, &order, &types, &nullable, &translation)
            };
            if object.directives.iter().any(|d| d.name == "aggregation") {
                let Some(aggregation) = translation
                    .aggregations
                    .iter()
                    .find(|aggregation| aggregation.name == object.name)
                else {
                    skipped.push((
                        object.name.clone(),
                        "an @aggregation envio can't translate".to_string(),
                    ));
                    continue;
                };
                for interval in &aggregation.intervals {
                    let mut rows = stored(&format!("{}_{interval}", object.name));
                    rows.served = Some(Served {
                        type_name: object.name.clone(),
                        args: format!("interval: {interval}"),
                    });
                    entities.push(rows);
                }
                continue;
            }
            // Timeseries are ordinary immutable entities to both sides.
            if object.directives.iter().any(|d| d.name == "entity") {
                entities.push(stored(&object.name));
            }
        }

        Ok(Model { entities, skipped })
    }
}

fn entity(
    name: &str,
    order: &[String],
    types: &BTreeMap<String, schema::FieldType>,
    nullable: &BTreeMap<String, bool>,
    translation: &schema::SchemaTranslation,
) -> Entity {
    let id_of = |entity: &str| {
        translation
            .entity_field_types
            .get(entity)
            .and_then(|fields| fields.get("id"))
            .map(|id| Scalar::from_kind(&id.kind))
            .unwrap_or(Scalar::Text)
    };

    let mut fields = Vec::new();
    let mut derived = Vec::new();
    for field_name in order {
        if field_name == "id" {
            continue;
        }
        let Some(field_type) = types.get(field_name) else {
            continue;
        };
        if field_type.derived_from.is_some() {
            derived.push(field_name.clone());
            continue;
        }
        let kind = match &field_type.target {
            Some(target) => FieldKind::Entity {
                target_id: id_of(target),
            },
            None => FieldKind::Scalar(Scalar::from_kind(&field_type.kind)),
        };
        let base = field_type.target.as_deref().unwrap_or(&field_type.kind);
        fields.push(Field {
            name: field_name.clone(),
            kind,
            list: field_type.list,
            nullable: nullable.get(field_name).copied().unwrap_or(true),
            target: field_type.target.clone(),
            declared: if field_type.list {
                format!("[{base}]")
            } else {
                base.to_string()
            },
        });
    }

    Entity {
        name: name.to_string(),
        id: id_of(name),
        fields,
        derived,
        served: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn reads_the_types_graph_node_stores() {
        let model = Model::from_schema(
            r#"
interface Named {
  id: Bytes!
  name: String!
}

type Account implements Named @entity {
  id: Bytes!
  name: String!
  balance: BigDecimal!
  holdings: [Token!]!
  tokens: [Token!]! @derivedFrom(field: "owner")
  status: Status
}

type Token @entity(immutable: true) {
  id: ID!
  owner: Account!
  supply: BigInt!
  decimals: Int!
  minted: Timestamp!
  hashes: [Bytes!]!
  frozen: Boolean
}

type Candle @entity(timeseries: true) {
  id: Int8!
  timestamp: Timestamp!
  volume: BigInt!
}

type CandleStats @aggregation(intervals: ["hour", "day"], source: "Candle") {
  id: Int8!
  timestamp: Timestamp!
  volume: BigInt! @aggregate(fn: "sum", arg: "volume")
}

enum Status {
  Active
}
"#,
        )
        .unwrap();

        let field = |name: &str, kind: FieldKind, list: bool, declared: &str| Field {
            name: name.to_string(),
            target: matches!(kind, FieldKind::Entity { .. })
                .then(|| declared.trim_matches(['[', ']']).to_string()),
            kind,
            list,
            nullable: ["status", "frozen"].contains(&name),
            declared: declared.to_string(),
        };
        // A timeseries is stored as it is served; an aggregation is one table
        // per interval, `CandleStats_hour`, which graph-node serves as
        // `candleStats(interval: hour)`.
        let candle = |name: &str, interval: Option<&str>| Entity {
            name: name.to_string(),
            id: Scalar::Integer,
            fields: vec![
                field(
                    "timestamp",
                    FieldKind::Scalar(Scalar::Integer),
                    false,
                    "Timestamp",
                ),
                field(
                    "volume",
                    FieldKind::Scalar(Scalar::Integer),
                    false,
                    "BigInt",
                ),
            ],
            derived: vec![],
            served: interval.map(|interval| Served {
                type_name: "CandleStats".to_string(),
                args: format!("interval: {interval}"),
            }),
        };
        assert_eq!(
            model,
            Model {
                entities: vec![
                    Entity {
                        name: "Account".to_string(),
                        id: Scalar::Bytes,
                        fields: vec![
                            field("name", FieldKind::Scalar(Scalar::Text), false, "String"),
                            field(
                                "balance",
                                FieldKind::Scalar(Scalar::BigDecimal),
                                false,
                                "BigDecimal"
                            ),
                            field(
                                "holdings",
                                FieldKind::Entity {
                                    target_id: Scalar::Text
                                },
                                true,
                                "[Token]"
                            ),
                            field("status", FieldKind::Scalar(Scalar::Text), false, "Status"),
                        ],
                        derived: vec!["tokens".to_string()],
                        served: None,
                    },
                    Entity {
                        name: "Token".to_string(),
                        id: Scalar::Text,
                        fields: vec![
                            field(
                                "owner",
                                FieldKind::Entity {
                                    target_id: Scalar::Bytes
                                },
                                false,
                                "Account"
                            ),
                            field(
                                "supply",
                                FieldKind::Scalar(Scalar::Integer),
                                false,
                                "BigInt"
                            ),
                            field("decimals", FieldKind::Scalar(Scalar::Integer), false, "Int"),
                            field(
                                "minted",
                                FieldKind::Scalar(Scalar::Integer),
                                false,
                                "Timestamp"
                            ),
                            field("hashes", FieldKind::Scalar(Scalar::Bytes), true, "[Bytes]"),
                            field(
                                "frozen",
                                FieldKind::Scalar(Scalar::Boolean),
                                false,
                                "Boolean"
                            ),
                        ],
                        derived: vec![],
                        served: None,
                    },
                    candle("Candle", None),
                    candle("CandleStats_hour", Some("hour")),
                    candle("CandleStats_day", Some("day")),
                ],
                skipped: vec![],
            }
        );
    }
}
