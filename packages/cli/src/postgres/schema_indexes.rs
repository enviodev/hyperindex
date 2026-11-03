//! The indexes an entity schema promises, on the tables Postgres keeps them
//! on.

use std::collections::{BTreeSet, HashSet};

use super::index_definition::{IndexColumn, IndexDefinition, BTREE};
use crate::storage::schema::{Direction, Entity, Schema};

fn single(table_name: &str, column: &str) -> IndexDefinition {
    IndexDefinition {
        table_name: table_name.to_string(),
        columns: vec![IndexColumn {
            name: column.to_string(),
            direction: Direction::Asc,
        }],
        method: BTREE.to_string(),
    }
}

/// The physical tables an index on the entity is built on. A per-chain
/// entity's rows are partitioned by chain, and an index declared on the parent
/// cascades to every partition, which is what a run driving every chain wants:
/// one declaration, one build. An isolated run instead builds on its own
/// chains' partitions only: the planner uses a partition's own index either
/// way, and building one chain's index then neither waits for nor locks the
/// rows of a chain a sibling process drives.
pub fn index_tables(entity: &Entity, partitions: Option<&[i64]>) -> Vec<String> {
    match (&entity.chain_id, partitions) {
        (Some(_), Some(chain_ids)) => chain_ids
            .iter()
            .map(|&chain_id| entity.partition_table_name(chain_id))
            .collect(),
        _ => vec![entity.name.clone()],
    }
}

/// Every index the schema promises for the entities Postgres keeps: an
/// `@index` field, a composite index, or the index backing a derived
/// relationship. With `partitions`, a per-chain entity's index is one per
/// partition of those chains rather than one on the parent.
///
/// Every `@derivedFrom` target among them resolves: config parsing rejects a
/// Postgres entity deriving from one that isn't in Postgres.
pub fn schema_indexes(schema: &Schema, partitions: Option<&[i64]>) -> Vec<IndexDefinition> {
    let entities = schema
        .entities
        .iter()
        .filter(|entity| entity.postgres)
        .collect::<Vec<_>>();
    let mut all = Vec::new();
    for entity in &entities {
        let column = |name: &str| entity.pg_column(name).map(str::to_string);
        // A composite index of one field is a single index all the same.
        let singles = entity
            .fields
            .iter()
            .filter(|field| field.is_index)
            .map(|field| field.pg_column.clone())
            .chain(
                entity
                    .composite_indexes
                    .iter()
                    .filter_map(|index| match index.as_slice() {
                        [field] => column(&field.field),
                        _ => None,
                    }),
            )
            .collect::<BTreeSet<_>>();
        all.extend(singles.iter().map(|column| single(&entity.name, column)));
        all.extend(
            entity
                .composite_indexes
                .iter()
                .filter(|index| index.len() > 1)
                .map(|index| IndexDefinition {
                    table_name: entity.name.clone(),
                    columns: index
                        .iter()
                        .filter_map(|field| {
                            Some(IndexColumn {
                                name: column(&field.field)?,
                                direction: field.direction,
                            })
                        })
                        .collect(),
                    method: BTREE.to_string(),
                }),
        );
    }
    for entity in &entities {
        for derived in &entity.derived_from {
            if let Some(column) = entities
                .iter()
                .find(|target| target.name == derived.entity)
                .and_then(|target| target.pg_column(&derived.field))
            {
                all.push(single(&derived.entity, column));
            }
        }
    }

    // An `@index` field and a derived relationship pointing at it describe the
    // same index, so the list is deduped on identity rather than on name.
    let mut seen = HashSet::new();
    all.into_iter()
        .filter(|definition| seen.insert(definition.key()))
        .flat_map(|definition| {
            let entity = entities
                .iter()
                .find(|entity| entity.name == definition.table_name)
                .expect("an index is on an entity Postgres keeps");
            index_tables(entity, partitions)
                .into_iter()
                .map(move |table_name| IndexDefinition {
                    table_name,
                    ..definition.clone()
                })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config_parsing::system_config::ChainIdMode;
    use crate::storage::schema::test_support::{entity, id};
    use crate::storage::schema::{DerivedFrom, Field, FieldType, IndexField};
    use crate::storage::types::Sequence;
    use pretty_assertions::assert_eq;
    use std::sync::Arc;

    fn schema() -> Schema {
        let mut owner_field = Field::new("owner_id", FieldType::String);
        owner_field.schema_name = "owner".to_string();
        owner_field.pg_column = "owner_id".to_string();
        let mut balance = Field::new("balance", FieldType::Int32);
        balance.is_index = true;
        let mut account = entity("Account", vec![id(), owner_field, balance], Some("chainId"));
        account.composite_indexes = vec![
            vec![IndexField {
                field: "owner".to_string(),
                direction: Direction::Desc,
            }],
            vec![
                IndexField {
                    field: "owner".to_string(),
                    direction: Direction::Asc,
                },
                IndexField {
                    field: "balance".to_string(),
                    direction: Direction::Desc,
                },
            ],
        ];
        let mut owner = entity("Owner", vec![id()], None);
        owner.index = 1;
        owner.derived_from = vec![DerivedFrom {
            entity: "Account".to_string(),
            field: "owner".to_string(),
        }];
        Schema {
            entities: vec![Arc::new(account), Arc::new(owner)],
            enums: Vec::new(),
            sequence: Sequence::SharedAcrossChains,
            chain_id_mode: ChainIdMode::Int32,
        }
    }

    #[test]
    fn every_promised_index_once_on_the_tables_that_hold_it() {
        let described = |partitions: Option<&[i64]>| {
            schema_indexes(&schema(), partitions)
                .iter()
                .map(IndexDefinition::describe)
                .collect::<Vec<_>>()
        };
        assert_eq!(
            (described(None), described(Some(&[1, 10]))),
            (
                vec![
                    "Account(balance) using btree".to_string(),
                    "Account(owner_id) using btree".to_string(),
                    "Account(owner_id, balance DESC) using btree".to_string(),
                ],
                vec![
                    "Account$1(balance) using btree".to_string(),
                    "Account$10(balance) using btree".to_string(),
                    "Account$1(owner_id) using btree".to_string(),
                    "Account$10(owner_id) using btree".to_string(),
                    "Account$1(owner_id, balance DESC) using btree".to_string(),
                    "Account$10(owner_id, balance DESC) using btree".to_string(),
                ]
            )
        );
    }

    /// A derived field is read by looking the owner's id up on the other
    /// table, so the relation is only usable if that column is indexed. Every
    /// spelling of the list points at one column, and the index is emitted
    /// once.
    #[test]
    fn a_derived_lookup_indexes_the_column_it_reads_once() {
        let indexes = |spelling: &str| {
            let config = crate::config_parsing::system_config::SystemConfig::parse_yaml(
                "name: derived-from\nchains:\n  - id: 1\n    start_block: 0\n",
                Some(&format!(
                    "type Parent {{
  id: ID!
  children: {spelling} @derivedFrom(field: \"parent\")
  alias: {spelling} @derivedFrom(field: \"parent\")
}}
type Child {{
  id: ID!
  parent: Parent!
}}"
                )),
                &std::collections::HashMap::new(),
                &std::collections::HashMap::new(),
                false,
            )
            .unwrap();
            let schema =
                Schema::from_config_json(&config.to_public_config_json(false).unwrap()).unwrap();
            schema_indexes(&schema, None)
                .iter()
                .map(IndexDefinition::describe)
                .collect::<Vec<_>>()
        };
        let spellings = ["[Child!]!", "[Child!]", "[Child]!", "[Child]"];
        assert_eq!(
            spellings.map(indexes),
            spellings.map(|_| vec!["Child(parent_id) using btree".to_string()])
        );
    }

    fn described(yaml: &str, graphql: &str) -> Vec<String> {
        let config = crate::config_parsing::system_config::SystemConfig::parse_yaml(
            yaml,
            Some(graphql),
            &std::collections::HashMap::new(),
            &std::collections::HashMap::new(),
            false,
        )
        .unwrap();
        let schema =
            Schema::from_config_json(&config.to_public_config_json(false).unwrap()).unwrap();
        schema_indexes(&schema, None)
            .iter()
            .map(IndexDefinition::describe)
            .collect()
    }

    /// Each `@index(fields:)` keeps the order the entity declares its columns
    /// in and the direction each was given, ascending when none was; a lone
    /// column is a single index rather than a composite one, and only a lone
    /// id is redundant — leading a composite is not.
    #[test]
    fn an_index_directive_keeps_its_columns_order_and_directions() {
        let yaml = "name: entity-index-directive\nchains:\n  - id: 1\n    start_block: 0\n";
        let with = |index: &str| {
            described(
                yaml,
                &format!(
                    "type TestEntity {index} {{
  id: ID!
  tokenId: Int!
  collection: String!
}}"
                ),
            )
        };
        assert_eq!(
            (
                described(
                    yaml,
                    "type TestEntity @index(fields: [\"a\", \"b\"]) @index(fields: [\"b\", \"a\"]) {
  id: ID!
  a: String!
  b: String!
}"
                ),
                with("@index(fields: [[\"tokenId\", \"DESC\"], [\"collection\", \"ASC\"]])"),
                with("@index(fields: [\"tokenId\", [\"collection\", \"DESC\"]])"),
                with("@index(fields: [[\"tokenId\", \"desc\"], [\"collection\", \"asc\"]])"),
                with("@index(fields: [[\"tokenId\", \"DESC\"]])"),
                with("@index(fields: [\"id\", \"tokenId\"])"),
            ),
            (
                vec![
                    "TestEntity(a, b) using btree".to_string(),
                    "TestEntity(b, a) using btree".to_string(),
                ],
                vec!["TestEntity(tokenId DESC, collection) using btree".to_string()],
                vec!["TestEntity(tokenId, collection DESC) using btree".to_string()],
                vec!["TestEntity(tokenId DESC, collection) using btree".to_string()],
                vec!["TestEntity(tokenId) using btree".to_string()],
                vec!["TestEntity(id, tokenId) using btree".to_string()],
            )
        );
    }

    /// https://github.com/enviodev/hyperindex/issues/1542
    ///
    /// The chain column envio appends to a per-chain entity is a column an
    /// index can name like any other.
    #[test]
    fn an_index_names_the_appended_chain_column() {
        assert_eq!(
            described(
                "name: per-chain\ndisable_default_cross_chain: true\nchains:\n  - id: 1\n    start_block: 0\n",
                "type Transfer @index(fields: [\"chainId\", \"timestamp\"]) {
  id: ID!
  timestamp: Timestamp!
}"
            ),
            vec!["Transfer(chainId, timestamp) using btree".to_string()]
        );
    }
}
