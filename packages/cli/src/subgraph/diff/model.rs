use std::collections::BTreeMap;

use anyhow::{anyhow, Result};
use graphql_parser::schema::{Definition, Document, Type, TypeDefinition, Value};

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
            let Some(entity_directive) = object.directives.iter().find(|d| d.name == "entity")
            else {
                continue;
            };
            let timeseries = entity_directive
                .arguments
                .iter()
                .any(|(name, value)| name == "timeseries" && *value == Value::Boolean(true));
            if timeseries || object.directives.iter().any(|d| d.name == "aggregation") {
                skipped.push((
                    object.name.clone(),
                    "timeseries and aggregations aren't indexed by envio".to_string(),
                ));
                continue;
            }

            let types = translation
                .entity_field_types
                .get(&object.name)
                .cloned()
                .unwrap_or_default();
            let order = translation
                .entity_fields
                .get(&object.name)
                .cloned()
                .unwrap_or_default();
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
            entities.push(entity(
                &object.name,
                &order,
                &types,
                &nullable,
                &translation,
            ));
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
                    },
                ],
                skipped: vec![(
                    "Candle".to_string(),
                    "timeseries and aggregations aren't indexed by envio".to_string()
                )],
            }
        );
    }
}
