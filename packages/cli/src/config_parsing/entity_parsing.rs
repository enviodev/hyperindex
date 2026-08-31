use super::{
    field_types::{Field as PGField, Primitive as PGPrimitive},
    validation::{check_names_from_schema_for_reserved_words, is_valid_postgres_db_name},
};
use crate::{
    constants::project_paths::DEFAULT_SCHEMA_PATH,
    hbs_templating::codegen_templates::DerivedFieldTemplate,
    project_paths::{path_utils, ParsedProjectPaths},
    type_schema::TypeIdent,
    utils::{text::Capitalize, unique_hashmap},
};
use alloy_dyn_abi::DynSolType;
use anyhow::{anyhow, Context};
use graphql_parser::schema::{
    Definition, Directive, Document, EnumType, Field as ObjField, ObjectType, Type as ObjType,
    TypeDefinition, Value,
};
use graphql_parser::Pos;
use serde::{Serialize, Serializer};
use std::{
    borrow::Cow,
    collections::{HashMap, HashSet},
    fmt::{self},
    path::PathBuf,
};
use subenum::subenum;

#[derive(Debug, Clone, PartialEq)]
pub struct Schema {
    pub entities: HashMap<String, Entity>,
    pub enums: HashMap<String, GraphQLEnum>,
}

enum TypeDef<'a> {
    Entity(&'a Entity),
    Enum,
}

impl Schema {
    pub fn empty() -> Self {
        Schema {
            entities: HashMap::new(),
            enums: HashMap::new(),
        }
    }

    /// Entities in name order, so a validation error doesn't depend on which
    /// one the hash map happened to yield first.
    pub fn entities_by_name(&self) -> Vec<&Entity> {
        let mut entities: Vec<&Entity> = self.entities.values().collect();
        entities.sort_by(|a, b| a.name.cmp(&b.name));
        entities
    }

    pub fn new(entities: Vec<Entity>, enums: Vec<GraphQLEnum>) -> anyhow::Result<Self> {
        let entities = unique_hashmap::from_vec_no_duplicates(
            entities.into_iter().map(|e| (e.name.clone(), e)).collect(),
        )
        .context("Found entities with duplicate names")?;
        let enums = unique_hashmap::from_vec_no_duplicates(
            enums.into_iter().map(|e| (e.name.clone(), e)).collect(),
        )
        .context("Found enums with duplicate names")?;

        Self { entities, enums }.validate()
    }

    fn from_document(
        document: Document<String>,
        default_scope: DefaultChainScope,
        source: &str,
    ) -> anyhow::Result<Self> {
        let entities = document
            .definitions
            .iter()
            .filter_map(|d| match d {
                Definition::TypeDefinition(type_def) => Some(type_def),
                _ => None,
            })
            .filter_map(|type_def| match type_def {
                TypeDefinition::Object(obj) => Some(obj),
                _ => None,
            })
            .map(|obj| Entity::from_object(obj, default_scope, source))
            .collect::<anyhow::Result<Vec<Entity>>>()?;

        let enums = document
            .definitions
            .iter()
            .filter_map(|d| match d {
                Definition::TypeDefinition(type_def) => Some(type_def),
                _ => None,
            })
            .filter_map(|type_def| match type_def {
                TypeDefinition::Enum(obj) => Some(obj),
                _ => None,
            })
            .map(|obj| GraphQLEnum::from_enum(obj))
            .collect::<anyhow::Result<Vec<GraphQLEnum>>>()
            .context("Failed constructing enums in schema from document")?;

        Self::new(entities, enums)
    }

    pub fn parse_from_file(
        project_paths: &ParsedProjectPaths,
        maybe_custom_path: &Option<String>,
        default_scope: DefaultChainScope,
    ) -> anyhow::Result<Self> {
        let configured_path = schema_source_label(maybe_custom_path);

        let schema_path = path_utils::get_config_path_relative_to_root(
            project_paths,
            PathBuf::from(&configured_path),
        )
        .context("Failed creating a relative path to schema")?;

        let schema_string = std::fs::read_to_string(&schema_path).context(format!(
            "Failed to read schema file at {}. Please ensure that the schema file is placed \
             correctly in the directory.",
            schema_path.to_str().unwrap_or("bad file path"),
        ))?;

        // Errors name the schema by the path the project actually uses, so a
        // `schema:` override in config.yaml points at the file the user edited.
        // A schema outside the project root keeps the path as configured rather
        // than falling back to an absolute one, which would differ per machine.
        let source = project_paths
            .relative_to_root(&schema_path)
            .map(|relative| relative.display().to_string())
            .unwrap_or(configured_path);

        Self::from_string_at(&schema_string, default_scope, &source)
    }

    pub fn from_string(
        schema_string: &str,
        default_scope: DefaultChainScope,
    ) -> anyhow::Result<Self> {
        Self::from_string_at(schema_string, default_scope, DEFAULT_SCHEMA_PATH)
    }

    pub fn from_string_at(
        schema_string: &str,
        default_scope: DefaultChainScope,
        source: &str,
    ) -> anyhow::Result<Self> {
        // graphql_parser counts a comment line's `\r` and its `\n` as two line
        // breaks, so a CRLF schema with comments reports positions past where
        // the error is.
        let schema_string = if schema_string.contains('\r') {
            Cow::Owned(schema_string.replace("\r\n", "\n"))
        } else {
            Cow::Borrowed(schema_string)
        };
        let schema_doc = graphql_parser::parse_schema::<String>(&schema_string)
            .context("Failed to parse schema as document")?;

        Self::from_document(schema_doc, default_scope, source)
    }

    fn validate(self) -> anyhow::Result<Self> {
        self.check_schema_for_reserved_words()?
            .check_duplicate_naming_between_enums_and_entities()?
            .check_capitalized_entity_name_collisions()?
            .check_related_type_defs_exist()?
            .validate_entity_field_types()
    }

    fn get_all_enum_type_names(&self) -> Vec<String> {
        self.enums.keys().cloned().collect()
    }
    fn get_all_enum_values(&self) -> Vec<String> {
        self.enums.values().flat_map(|v| v.values.clone()).collect()
    }
    fn get_all_entity_type_names(&self) -> Vec<String> {
        self.entities.keys().cloned().collect()
    }

    fn check_schema_for_reserved_words(self) -> anyhow::Result<Self> {
        let all_names = [
            self.get_all_enum_type_names(),
            self.get_all_enum_values(),
            self.get_all_entity_type_names(),
        ]
        .concat();

        // TODO: It'd be nice to check field names not having __proto__ name
        // I don't think any other field names should be restricted
        match check_names_from_schema_for_reserved_words(all_names) {
            reserved_enum_types_used if reserved_enum_types_used.is_empty() => Ok(self),
            reserved_enum_types_used => Err(anyhow!(
                "Schema contains the following reserved keywords: {}",
                reserved_enum_types_used.join(", ")
            )),
        }
    }

    fn check_duplicate_naming_between_enums_and_entities(self) -> anyhow::Result<Self> {
        let duplicate_names = self
            .get_all_enum_type_names()
            .into_iter()
            .filter(|k| self.entities.contains_key(k))
            .collect::<Vec<_>>();
        if !duplicate_names.is_empty() {
            Err(anyhow!(
                "Schema contains the following enums and entities with the same name, all type \
                 definitions must be unique in the schema: {}",
                duplicate_names.join(", ")
            ))
        } else {
            Ok(self)
        }
    }

    // The handler context and generated types expose each entity under its
    // capitalized name, so entities whose names differ only by the first
    // letter's case (e.g. `user` and `User`) would map to the same accessor
    // and silently shadow each other at runtime.
    fn check_capitalized_entity_name_collisions(self) -> anyhow::Result<Self> {
        let mut by_capitalized: HashMap<String, Vec<String>> = HashMap::new();
        for name in self.entities.keys() {
            by_capitalized
                .entry(name.capitalize())
                .or_default()
                .push(name.clone());
        }

        let mut collisions = by_capitalized
            .into_iter()
            .filter(|(_, names)| names.len() > 1)
            .map(|(capitalized, mut names)| {
                names.sort();
                format!("{} (from {})", capitalized, names.join(", "))
            })
            .collect::<Vec<_>>();

        if collisions.is_empty() {
            Ok(self)
        } else {
            collisions.sort();
            Err(anyhow!(
                "Schema contains entities whose names collide when capitalized. Each entity is \
                 exposed on the handler context under its capitalized name, so these must be \
                 unique: {}",
                collisions.join("; ")
            ))
        }
    }

    /// Resolves a field's scalar to what its column actually stores: a relation
    /// stores the referenced entity's id, every other scalar stores itself.
    /// Storage validation has to reason about the stored column type, which for
    /// a relation is not the schema-level type.
    pub fn resolve_stored_scalar(&self, scalar: &GqlScalar) -> anyhow::Result<GqlScalar> {
        match scalar {
            GqlScalar::Custom(name) => match self.try_get_type_def(name)? {
                TypeDef::Entity(entity) => entity.get_id_scalar(),
                TypeDef::Enum => Ok(scalar.clone()),
            },
            _ => Ok(scalar.clone()),
        }
    }

    fn try_get_type_def(&self, name: &String) -> anyhow::Result<TypeDef<'_>> {
        match (self.entities.get(name), self.enums.get(name)) {
            (None, None) => Err(anyhow!("No type definition '{}' exists in schema", name)),
            (Some(_), Some(_)) => Err(anyhow!(
                "Both an enum and an entity type definition '{}' exist in schema",
                name
            )),
            (Some(entity), None) => Ok(TypeDef::Entity(entity)),
            (None, Some(_)) => Ok(TypeDef::Enum),
        }
    }

    /// The storage kind an id scalar maps to, or `None` for a scalar that can't
    /// hold an id. Two ids are interchangeable when their kinds match: `ID` and
    /// `String` share a text column, and a BigInt's precision only sets the
    /// column width, not its type.
    fn id_scalar_kind(scalar: &GqlScalar) -> Option<&'static str> {
        match scalar {
            GqlScalar::ID | GqlScalar::String => Some("String"),
            GqlScalar::Int => Some("Int"),
            GqlScalar::BigInt(_) => Some("BigInt"),
            _ => None,
        }
    }

    fn check_related_type_defs_exist(self) -> anyhow::Result<Self> {
        for entity in self.entities.values() {
            for rel in entity.get_relationships() {
                match &rel {
                    Relationship::TypeDef { name } => {
                        let _ = self.try_get_type_def(name)?;
                    }
                    Relationship::DerivedFrom {
                        name,
                        derived_from_field,
                    } => {
                        let type_def = self.try_get_type_def(name)?;

                        match type_def {
                            TypeDef::Enum => Err(anyhow!(
                                "Cannot derive field {derived_from_field} from enum {name}. \
                                 derivedFrom is intended to be used with Entity type definitions"
                            ))?,
                            TypeDef::Entity(derived_entity) => {
                                match derived_entity.get_field(derived_from_field) {
                                    None => Err(anyhow!(
                                        "Derived field {derived_from_field} does not exist on \
                                         entity {name}."
                                    ))?,
                                    Some(field) => {
                                        let scalar = field.field_type.get_underlying_scalar();
                                        match &scalar {
                                            // A relation back to this entity stores its id, so the
                                            // two columns match by construction.
                                            GqlScalar::Custom(related)
                                                if related == &entity.name => {}
                                            // Hasura maps this entity's `id` onto the derived column
                                            // (see the `"id": relationalKey` mapping in Hasura.res),
                                            // so a scalar column has to hold the same kind of id.
                                            _ => {
                                                let entity_id_scalar = entity.get_id_scalar()?;
                                                // The entity's id is validated to an id scalar, so
                                                // its kind is always known; a mismatch (or a field
                                                // that isn't an id scalar at all) fails here.
                                                if Self::id_scalar_kind(&scalar)
                                                    != Self::id_scalar_kind(&entity_id_scalar)
                                                {
                                                    Err(anyhow!(
                                                        "Derived field '{derived_from_field}' on \
                                                         entity '{name}' is a {scalar}, but it is \
                                                         matched against the id of '{0}', which \
                                                         is a {entity_id_scalar}. Give it the \
                                                         same type as '{0}'.id, or make it an \
                                                         Object relationship with Entity '{0}'.",
                                                        entity.name
                                                    ))?
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        Ok(self)
    }

    /// For all entities validate the defined field types.
    ///
    /// This function will return an error if there is a defined related type where the type does
    /// not exist on the schema.
    fn validate_entity_field_types(self) -> anyhow::Result<Self> {
        for e in self.entities.values() {
            e.validate_field_types(&self)?;
        }
        Ok(self)
    }
}

/// `schema.graphql:12:3` — where in the schema an error was raised, so an
/// editor or terminal can jump straight to it. `Pos` is 1-based and renders as
/// `line:column`. Used as anyhow context, which supplies the `: ` that follows.
fn at(source: &str, position: Pos) -> String {
    format!("{source}:{position}")
}

/// How errors name the schema when the file itself isn't resolved against a
/// project on disk: the `schema:` path config.yaml set, normalized so
/// `./db/schema.graphql` reads the way the project would write it.
pub fn schema_source_label(configured_path: &Option<String>) -> String {
    match configured_path {
        Some(path) => path_utils::normalize_path(PathBuf::from(path))
            .display()
            .to_string(),
        None => DEFAULT_SCHEMA_PATH.to_string(),
    }
}

fn backtick_list<'a>(names: impl IntoIterator<Item = &'a str>) -> String {
    names
        .into_iter()
        .map(|name| format!("`{name}`"))
        .collect::<Vec<_>>()
        .join(", ")
}

/// One shape for every directive reference error, so the fix is always in the
/// same place: a single indented line after the problem.
fn directive_error(
    entity: &str,
    directive: &str,
    problem: &str,
    suggestion: &str,
) -> anyhow::Error {
    anyhow!("Invalid `{directive}` on `{entity}`: {problem}.\n  {suggestion}")
}

/// A column an entity directive named, together with the field it resolved to.
/// The chain id envio appends has no `Field` behind it.
struct ResolvedColumn<'a> {
    column: EntityColumn,
    field: Option<&'a Field>,
}

/// Resolves the column names an entity directive lists against the columns the
/// entity's table actually has: the fields it declares, plus the chain id envio
/// appends to a per-chain entity.
struct ColumnResolver<'a> {
    entity: &'a str,
    fields: &'a [Field],
    default_scope: DefaultChainScope,
    cross_chain: bool,
}

impl<'a> ColumnResolver<'a> {
    /// Only a per-chain entity gets the chain id appended, so only there can a
    /// directive name it.
    fn has_chain_id_column(&self) -> bool {
        !self.default_scope.is_cross_chain(self.cross_chain)
    }

    fn resolve(&self, directive: &str, column: &str) -> anyhow::Result<ResolvedColumn<'a>> {
        if let Some(field) = self.fields.iter().find(|f| f.name == column) {
            if field.field_type.is_derived_from() {
                return Err(directive_error(
                    self.entity,
                    directive,
                    &format!("`{column}` is a @derivedFrom field, which has no column"),
                    "Use a stored field instead.",
                ));
            }
            return Ok(ResolvedColumn {
                column: EntityColumn::Declared(column.to_string()),
                field: Some(field),
            });
        }
        if self.has_chain_id_column() && column == CHAIN_ID_FIELD_NAME {
            return Ok(ResolvedColumn {
                column: EntityColumn::ChainId,
                field: None,
            });
        }
        Err(directive_error(
            self.entity,
            directive,
            &format!("`{column}` is not a column of the entity"),
            &self.unknown_column_suggestion(column),
        ))
    }

    /// Resolves a directive's column list, rejecting a column listed twice.
    /// `builds` names what the list is building, for the error. Order is kept,
    /// so a caller with per-column data can pair it back on by position.
    fn resolve_distinct(
        &self,
        directive: &str,
        builds: &str,
        columns: impl IntoIterator<Item = String>,
    ) -> anyhow::Result<Vec<ResolvedColumn<'a>>> {
        let columns: Vec<String> = columns.into_iter().collect();
        let mut seen: HashSet<&str> = HashSet::new();
        columns
            .iter()
            .map(|written_as| {
                if !seen.insert(written_as.as_str()) {
                    return Err(directive_error(
                        self.entity,
                        directive,
                        &format!("`{written_as}` is listed twice"),
                        &format!(
                            "List each column once — repeating it adds nothing to the {builds}."
                        ),
                    ));
                }
                self.resolve(directive, written_as)
            })
            .collect()
    }

    fn unknown_column_suggestion(&self, column: &str) -> String {
        if RESERVED_CHAIN_ID_FIELD_NAMES.contains(&column) {
            // What makes the entity cross-chain decides the fix: dropping
            // `@crossChain` only yields a chain column when entities are
            // per-chain without it.
            return match (self.cross_chain, self.default_scope) {
                (_, _) if self.has_chain_id_column() => format!(
                    "Spell the chain column as `{CHAIN_ID_FIELD_NAME}`, the way it's named in the \
                     schema, whatever `column_name_format` the storage uses."
                ),
                (true, DefaultChainScope::PerChain) => format!(
                    "envio only appends a chain column to per-chain entities, and `{}` is \
                     `@crossChain`. Drop `@crossChain`, or declare a `{CHAIN_ID_FIELD_NAME}` field \
                     yourself.",
                    self.entity
                ),
                (true, DefaultChainScope::CrossChain) => format!(
                    "envio only appends a chain column to per-chain entities, and entities are \
                     cross-chain unless config.yaml sets `disable_default_cross_chain: true`. Set \
                     it and drop `@crossChain`, or declare a `{CHAIN_ID_FIELD_NAME}` field \
                     yourself."
                ),
                (false, _) => format!(
                    "envio only appends a chain column to per-chain entities, and entities are \
                     cross-chain unless config.yaml sets `disable_default_cross_chain: true`. Set \
                     it, or declare a `{CHAIN_ID_FIELD_NAME}` field yourself."
                ),
            };
        }

        // Derived fields are left out: they have no column, so pointing at one
        // would only trade this error for another. `id` is listed, since every
        // directive here takes it alongside another column — but not when it is
        // all the entity has, where naming it is the next error instead.
        let stored = || {
            self.fields
                .iter()
                .filter(|f| !f.field_type.is_derived_from())
        };
        if !self.has_chain_id_column() && !stored().any(|f| f.name != ID_FIELD_NAME) {
            return "The entity declares no columns besides `id`.".to_string();
        }

        let mut available: Vec<&str> = stored().map(|f| f.name.as_str()).collect();
        if self.has_chain_id_column() {
            available.push(CHAIN_ID_FIELD_NAME);
        }
        format!("Available columns: {}.", backtick_list(available))
    }
}

fn resolve_order_by(
    resolver: &ColumnResolver,
    columns: Vec<String>,
) -> anyhow::Result<Vec<EntityColumn>> {
    let resolved = resolver.resolve_distinct(ORDER_BY_DIRECTIVE, "sorting key", columns)?;

    // `id` narrows a sorting key that leads with something coarser, so it is
    // only redundant on its own — that is the key ClickHouse already gets.
    if let [only] = resolved.as_slice() {
        if only.column.field_name() == ID_FIELD_NAME {
            return Err(directive_error(
                resolver.entity,
                ORDER_BY_DIRECTIVE,
                "`id` on its own is already the sorting key when no `orderBy` is given",
                "Drop the `orderBy`, or add the columns to sort by alongside `id`.",
            ));
        }
    }

    resolved
        .into_iter()
        .map(|resolved| {
            check_clickhouse_sortable(resolver.entity, &resolved)?;
            Ok(resolved.column)
        })
        .collect()
}

/// ClickHouse rejects Nullable and Array columns in the sorting key
/// (`allow_nullable_key` is off by default, arrays are never allowed). The
/// appended chain id is a plain non-null integer, so only a declared field can
/// trip either.
fn check_clickhouse_sortable(entity: &str, resolved: &ResolvedColumn) -> anyhow::Result<()> {
    let Some(field) = resolved.field else {
        return Ok(());
    };
    let name = &field.name;

    if field.field_type.is_optional() {
        return Err(directive_error(
            entity,
            ORDER_BY_DIRECTIVE,
            &format!("`{name}` is nullable, and ClickHouse won't sort by a nullable column"),
            "Make the field non-nullable to sort by it.",
        ));
    }
    if field.field_type.is_array() {
        return Err(directive_error(
            entity,
            ORDER_BY_DIRECTIVE,
            &format!("`{name}` is an array, and ClickHouse won't sort by an array column"),
            "Sort by a scalar field instead.",
        ));
    }
    Ok(())
}

/// An `@index` over one column is a plain single index, and the entity may
/// already have that one covered.
fn check_worth_indexing(entity: &str, only: &ResolvedColumn) -> anyhow::Result<()> {
    match &only.column {
        EntityColumn::Declared(name) if name == ID_FIELD_NAME => Err(directive_error(
            entity,
            INDEX_DIRECTIVE,
            "`id` is the primary key, so it is already indexed",
            "Remove the `@index` directive on it.",
        )),
        EntityColumn::Declared(name)
            if only
                .field
                .is_some_and(|field| field.field_type.has_indexed_directive()) =>
        {
            Err(directive_error(
                entity,
                INDEX_DIRECTIVE,
                &format!("`{name}` is already marked `@index` on the field"),
                &format!(
                    "Keep one of them — the `@index` on the field, or `@index(fields: \
                     [\"{name}\"])` on the entity."
                ),
            ))
        }
        EntityColumn::ChainId => Err(directive_error(
            entity,
            INDEX_DIRECTIVE,
            &format!(
                "`{CHAIN_ID_FIELD_NAME}` is part of the primary key envio appends to every \
                 per-chain entity, so it is already indexed"
            ),
            &format!(
                "List it with another column, e.g. `@index(fields: [\"{CHAIN_ID_FIELD_NAME}\", \
                 \"timestamp\"])`."
            ),
        )),
        EntityColumn::Declared(_) => Ok(()),
    }
}

impl MultiFieldIndex {
    fn resolve(
        resolver: &ColumnResolver,
        columns: Vec<(String, IndexFieldDirection)>,
    ) -> anyhow::Result<Self> {
        let entity = resolver.entity;
        if columns.is_empty() {
            return Err(directive_error(
                entity,
                INDEX_DIRECTIVE,
                "no columns are listed",
                "List the columns to index, e.g. `@index(fields: [\"tokenId\", \"owner\"])`.",
            ));
        }

        let (names, directions): (Vec<String>, Vec<IndexFieldDirection>) =
            columns.into_iter().unzip();
        let resolved = resolver.resolve_distinct(INDEX_DIRECTIVE, "index", names)?;

        if let [only] = resolved.as_slice() {
            check_worth_indexing(entity, only)?;
        }

        Ok(Self(
            resolved
                .into_iter()
                .zip(directions)
                .map(|(resolved, direction)| IndexField {
                    column: resolved.column,
                    direction,
                })
                .collect(),
        ))
    }

    fn render_columns(&self) -> String {
        backtick_list(self.0.iter().map(|f| f.column.field_name()))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct GraphQLEnum {
    pub name: String,
    pub values: Vec<String>,
    pub description: Option<String>,
}

impl GraphQLEnum {
    pub fn new(
        name: String,
        values: Vec<String>,
        description: Option<String>,
    ) -> anyhow::Result<Self> {
        Self {
            name,
            values,
            description,
        }
        .valididate()
    }

    fn valididate(self) -> anyhow::Result<Self> {
        self.check_duplicate_values()?.check_valid_postgres_name()
    }

    fn check_duplicate_values(self) -> anyhow::Result<Self> {
        let mut value_set: HashSet<String> = self.values.clone().into_iter().collect();

        let duplicate_values = self
            .values
            .clone()
            .into_iter()
            .filter(|value| value_set.insert(value.clone()))
            .collect::<Vec<_>>();

        if !duplicate_values.is_empty() {
            Err(anyhow!(
                "Schema enum has duplicate values. Enum: {}, duplicate values: {}",
                self.name,
                duplicate_values.join(", ")
            ))
        } else {
            Ok(self)
        }
    }

    fn check_valid_postgres_name(self) -> anyhow::Result<Self> {
        let values_to_check = [vec![self.name.clone()], self.values.clone()].concat();
        let invalid_names = values_to_check
            .into_iter()
            .filter(|v| !is_valid_postgres_db_name(v))
            .collect::<Vec<_>>();

        if !invalid_names.is_empty() {
            Err(anyhow!(
                "Schema contains the enum names and/or values that does not match the following \
                 pattern: It must start with a letter. It can only contain letters, numbers, and \
                 underscores (no spaces). It must have a maximum length of 63 characters. Invalid \
                 names: '{}'",
                invalid_names.join(", ")
            ))
        } else {
            Ok(self)
        }
    }
    fn from_enum(enm: &EnumType<String>) -> anyhow::Result<Self> {
        let name = enm.name.clone();
        let values = enm
            .values
            .iter()
            .map(|value| value.name.clone())
            .collect::<Vec<String>>();
        Self::new(name, values, enm.description.clone())
    }
}

/// A data skipping index on the entity's ClickHouse history table, emitted
/// into the DDL as `INDEX <name> <expr> TYPE <type> GRANULARITY <granularity>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClickHouseSkippingIndex {
    pub name: String,
    /// Raw ClickHouse expression the index is built over.
    pub expr: String,
    /// Raw ClickHouse index type passed through verbatim — e.g.
    /// `bloom_filter(0.01)`, `set(100)`, `minmax` — so no type is ruled out.
    pub index_type: String,
    /// `GRANULARITY` clause; omitted leaves ClickHouse's default of 1.
    pub granularity: Option<u32>,
}

/// Per-entity tuning of the ClickHouse history table layout, written as an
/// object argument of the `@storage` directive:
/// `@storage(clickhouse: {partitionBy: "toYYYYMM(timestamp)", orderBy:
/// ["timestamp"], ttl: "timestamp + INTERVAL 2 YEAR", skippingIndexes: [{name:
/// "idx_from", expr: "fromAddress", type: "bloom_filter(0.01)"}]})`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ClickHouseTableOptions {
    /// Raw ClickHouse expression emitted as `PARTITION BY <expr>`.
    pub partition_by: Option<String>,
    /// Columns that lead the history table's sorting key, replacing the default
    /// `id` prefix. `envio_checkpoint_id` stays appended, so the key becomes
    /// `ORDER BY (<order_by...>, envio_checkpoint_id)`.
    pub order_by: Option<Vec<EntityColumn>>,
    /// Raw ClickHouse expression emitted as `TTL <expr>`.
    pub ttl: Option<String>,
    /// Data skipping indexes emitted into the table's column list.
    pub skipping_indexes: Option<Vec<ClickHouseSkippingIndex>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClickHouseEntityStorage {
    Enabled(bool),
    Options(ClickHouseTableOptions),
}

impl ClickHouseEntityStorage {
    pub fn is_enabled(&self) -> bool {
        match self {
            Self::Enabled(enabled) => *enabled,
            Self::Options(_) => true,
        }
    }
}

/// What an entity is when it says nothing itself: shared across chains, or
/// per-chain because config.yaml sets `disable_default_cross_chain: true`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DefaultChainScope {
    CrossChain,
    PerChain,
}

impl DefaultChainScope {
    /// Whether an entity's rows are shared across chains. `@crossChain` shares
    /// whatever the default is; the per-chain entities are the ones envio
    /// appends the chain-id column to.
    pub fn is_cross_chain(self, cross_chain_directive: bool) -> bool {
        cross_chain_directive || self.is_cross_chain_by_default()
    }

    /// The same question for an entity that carries no directive, which is what
    /// the internal config JSON stores for the runtime to read.
    pub fn is_cross_chain_by_default(self) -> bool {
        self == Self::CrossChain
    }
}

/// Postgres silently truncates longer identifiers, which can collide two
/// distinct columns and breaks the Hasura `custom_name` mapping, keyed by the
/// untruncated name.
pub const MAX_PG_IDENTIFIER_LENGTH: usize = 63;

/// The name envio gives the chain-id column it appends to a per-chain entity.
/// Storage may spell the column differently (`column_name_format: snake_case`),
/// but a directive always names it the way the schema would.
pub const CHAIN_ID_FIELD_NAME: &str = "chainId";

/// Every entity's primary key.
pub const ID_FIELD_NAME: &str = "id";

const INDEX_DIRECTIVE: &str = "@index";
const ORDER_BY_DIRECTIVE: &str = "clickhouse.orderBy";

/// Every spelling the appended column can take. Kept in step with
/// `chainIdColumnName` in `Config.res`, which is what names the column in
/// storage — a `column_name_format` added there needs its spelling here, or the
/// name it produces is neither reserved nor recognized in a directive.
pub const RESERVED_CHAIN_ID_FIELD_NAMES: [&str; 2] = [CHAIN_ID_FIELD_NAME, "chain_id"];

/// A column an entity directive (`@index`, `@storage(clickhouse: {orderBy})`)
/// may name: a field the schema declares, or the chain id envio appends to a
/// per-chain entity. Only [`Entity::from_object`] builds one, so a resolved
/// [`Entity`] cannot carry a directive naming a column its table lacks.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum EntityColumn {
    Declared(String),
    ChainId,
}

impl EntityColumn {
    /// The name the runtime resolves the column by. Both `Table.getFieldByName`
    /// and ClickHouse's `columnByFieldName` key on schema field names, and the
    /// appended chain id keeps `chainId` there whatever storage spells it.
    pub fn field_name(&self) -> &str {
        match self {
            Self::Declared(name) => name,
            Self::ChainId => CHAIN_ID_FIELD_NAME,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entity {
    pub name: String,
    pub fields: Vec<Field>,
    pub multi_field_indexes: Vec<MultiFieldIndex>,
    pub description: Option<String>,
    pub postgres: Option<bool>,
    pub clickhouse: Option<ClickHouseEntityStorage>,
    // `@crossChain` on the entity. Only meaningful when the config sets
    // `disable_default_cross_chain: true`; otherwise codegen rejects it.
    pub cross_chain: bool,
    // `@internal` on the entity: stored and usable in handlers as normal, but
    // never exposed through the GraphQL API (no Hasura tracking).
    pub internal: bool,
}

impl Entity {
    /// Whether the entity's rows are shared across chains, which decides
    /// whether envio appends the chain-id column to its table.
    pub fn is_cross_chain(&self, default_scope: DefaultChainScope) -> bool {
        default_scope.is_cross_chain(self.cross_chain)
    }

    /// Builds the entity from its GraphQL definition, resolving directive
    /// column references as it goes. `default_scope` decides whether the
    /// entity gets the chain-id column envio appends, which is why the document
    /// alone can't be turned into an `Entity`.
    fn from_object(
        obj: &ObjectType<String>,
        default_scope: DefaultChainScope,
        source: &str,
    ) -> anyhow::Result<Self> {
        let name = &obj.name;
        let at_entity = at(source, obj.position);

        let has_id = obj.fields.iter().any(|field| field.name == ID_FIELD_NAME);
        if !has_id {
            return Err(anyhow!(
                "{at_entity}: No 'id' field found on entity {name}. Please add an 'id' field to \
                 your entity."
            ));
        }

        let fields = obj
            .fields
            .iter()
            .map(|field| {
                Field::from_obj_field(field).with_context(|| {
                    format!(
                        "{}: Failed parsing field {} on entity {name}",
                        at(source, field.position),
                        field.name
                    )
                })
            })
            .collect::<anyhow::Result<Vec<Field>>>()?;

        validate_entity_shape(name, &fields).with_context(|| at_entity.clone())?;

        let cross_chain = parse_flag_directive(obj, "crossChain", source)?;
        let internal = parse_flag_directive(obj, "internal", source)?;
        let resolver = ColumnResolver {
            entity: name,
            fields: &fields,
            default_scope,
            cross_chain,
        };

        let mut multi_field_indexes: Vec<MultiFieldIndex> = Vec::new();
        for directive in obj.directives.iter().filter(|d| d.name == "index") {
            let at_directive = at(source, directive.position);
            let columns = parse_index_directive_columns(directive)
                .with_context(|| format!("{at_directive}: Invalid `@index` on `{name}`"))?;
            let index = MultiFieldIndex::resolve(&resolver, columns)
                .with_context(|| at_directive.clone())?;
            if multi_field_indexes.contains(&index) {
                return Err(directive_error(
                    name,
                    "@index",
                    &format!(
                        "the index over {} is declared twice",
                        index.render_columns()
                    ),
                    "Remove the duplicate `@index` directive.",
                ))
                .context(at_directive);
            }
            multi_field_indexes.push(index);
        }

        let (postgres, clickhouse) = parse_storage_directive(obj, &resolver, source)?;

        Ok(Self {
            name: name.to_string(),
            fields,
            multi_field_indexes,
            description: obj.description.clone(),
            postgres,
            clickhouse,
            cross_chain,
            internal,
        })
    }
}

/// The column names an `@index(fields: [...])` directive lists, each with the
/// direction it asked for. Names are still as written — resolving them needs
/// the entity's fields.
fn parse_index_directive_columns(
    directive: &Directive<'_, String>,
) -> anyhow::Result<Vec<(String, IndexFieldDirection)>> {
    match directive.arguments.iter().find(|(key, _)| key == "fields") {
        Some((_, Value::List(fields))) => fields
            .iter()
            .map(|v| match v {
                Value::String(field_name) => Ok((field_name.clone(), IndexFieldDirection::Asc)),
                Value::List(parts) => {
                    if parts.len() != 2 {
                        return Err(anyhow!(
                            "Index field with direction must be a list of exactly 2 elements: \
                             [\"fieldName\", \"ASC\" or \"DESC\"]. Got {} elements.",
                            parts.len()
                        ));
                    }
                    let field_name = match &parts[0] {
                        Value::String(name) => name.clone(),
                        _ => {
                            return Err(anyhow!(
                                "First element of index field must be a string field name"
                            ))
                        }
                    };
                    let direction = match &parts[1] {
                        Value::String(dir) => match dir.to_uppercase().as_str() {
                            "ASC" => IndexFieldDirection::Asc,
                            "DESC" => IndexFieldDirection::Desc,
                            _ => {
                                return Err(anyhow!(
                                    "Index direction must be \"ASC\" or \"DESC\", got \"{}\"",
                                    dir
                                ))
                            }
                        },
                        _ => {
                            return Err(anyhow!(
                                "Second element of index field must be a string direction (\"ASC\" \
                                 or \"DESC\")"
                            ))
                        }
                    };
                    Ok((field_name, direction))
                }
                _ => Err(anyhow!(
                    "Listed index field should be a string or a list of [\"fieldName\", \"ASC\" or \
                     \"DESC\"]"
                )),
            })
            .collect::<anyhow::Result<Vec<_>>>()
            .context("Failed to get fields in index"),
        _ => Err(anyhow!(
            "Invalid @index directive. Please ensure index has a key of fields with a list of \
             strings matching field names in your entity. Eg. @index(fields: [\"fieldA\", \
             \"fieldB\"]) or @index(fields: [[\"fieldA\", \"DESC\"], [\"fieldB\", \"ASC\"]])"
        )),
    }
}

impl Entity {
    pub fn has_storage_directive(&self) -> bool {
        self.postgres.is_some() || self.clickhouse.is_some()
    }

    /// Whether this entity's rows are written to ClickHouse. A storage
    /// directive's omitted backend resolves to false at runtime (Config.res
    /// `Option.getOr(false)`), so a directive routes to ClickHouse only when it
    /// enables the backend — a boolean `true` or the table options object.
    /// Without a directive the entity follows the backend's `default`.
    pub fn uses_clickhouse(&self, clickhouse_default: bool) -> bool {
        if self.has_storage_directive() {
            self.clickhouse.as_ref().is_some_and(|c| c.is_enabled())
        } else {
            clickhouse_default
        }
    }

    /// Returns the fields of this [`Entity`] in schema-defined order.
    pub fn get_fields(&self) -> Vec<&Field> {
        self.fields.iter().collect()
    }

    /// Returns a field by name, if it exists.
    pub fn get_field(&self, name: &str) -> Option<&Field> {
        self.fields.iter().find(|f| f.name == name)
    }

    /// The scalar type of this entity's `id` field. Foreign keys that reference
    /// this entity adopt this scalar, so the id and its `_id` columns stay the
    /// same type. Parsing validates the id is a supported non-derived scalar,
    /// so this never resolves to a relation or derived field.
    pub fn get_id_scalar(&self) -> anyhow::Result<GqlScalar> {
        let id_field = self
            .get_field(ID_FIELD_NAME)
            .ok_or_else(|| anyhow!("Entity {} is missing an 'id' field", self.name))?;
        match &id_field.field_type {
            FieldType::RegularField { field_type, .. } => Ok(field_type.get_underlying_scalar()),
            FieldType::DerivedFromField { .. } => Err(anyhow!(
                "Entity {} has a derived 'id' field, which is unsupported",
                self.name
            )),
        }
    }

    pub fn get_relationships(&self) -> Vec<Relationship> {
        let derived_from_fields: Vec<Relationship> = self
            .get_fields()
            .into_iter()
            .filter_map(|f| match &f.field_type {
                FieldType::DerivedFromField {
                    entity_name,
                    derived_from_field,
                } => Some(Relationship::DerivedFrom {
                    name: entity_name.clone(),
                    derived_from_field: derived_from_field.clone(),
                }),
                _ => None,
            })
            .collect();
        let object_relationship_fields: Vec<Relationship> = self
            .get_fields()
            .into_iter()
            .filter_map(|f| f.get_relationship())
            .collect();

        [derived_from_fields, object_relationship_fields].concat()
    }

    pub fn get_related_entities<'a>(
        &'a self,
        schema: &'a Schema,
    ) -> anyhow::Result<Vec<(&'a Field, &'a Self)>> {
        let related_entities_with_field = self
            .get_fields()
            .into_iter()
            .filter_map(|field| {
                let gql_scalar = field.field_type.get_underlying_scalar();
                if let GqlScalar::Custom(name) = gql_scalar {
                    schema.try_get_type_def(&name).map_or_else(
                        |e| Some(Err(e)),
                        |type_def| match type_def {
                            TypeDef::Entity(entity) => Some(Ok((field, entity))),
                            TypeDef::Enum => None,
                        },
                    )
                } else {
                    None
                }
            })
            .collect::<anyhow::Result<_>>()?;

        Ok(related_entities_with_field)
    }

    /// Validate each field type in an the given entity
    ///
    /// This function will return an error if there is a defined related type where the type does
    /// not exist on the schema.
    fn validate_field_types(&self, schema: &Schema) -> anyhow::Result<()> {
        for field in self.get_fields() {
            field.validate_field_type(schema)?;
        }
        Ok(())
    }

    ///Returns defined multi field indexes where definitions
    ///have > 1 fields.
    pub fn get_composite_indexes(&self) -> Vec<Vec<IndexField>> {
        self.multi_field_indexes
            .iter()
            .cloned()
            .filter_map(|multi_field_index| {
                if multi_field_index.0.len() > 1 {
                    Some(multi_field_index.0)
                } else {
                    None
                }
            })
            .collect()
    }
}

/// Checks that hold for the entity on its own, before any config is in play.
fn validate_entity_shape(name: &str, fields: &[Field]) -> anyhow::Result<()> {
    let mut field_names_set = HashSet::new();
    for field in fields {
        if !field_names_set.insert(&field.name) {
            return Err(anyhow!(
                "Found fields with duplicate names on Entity {name}: '{}'",
                field.name
            ));
        }
    }

    // The `id` column and every foreign key that references it must share a
    // type, and the storage/codegen layers only implement a fixed set of id
    // scalars. Reject anything outside that set up front so the mismatch never
    // reaches codegen.
    if let Some(id_field) = fields.iter().find(|f| f.name == ID_FIELD_NAME) {
        match &id_field.field_type {
            FieldType::DerivedFromField { .. } => {
                return Err(anyhow!(
                    "The 'id' field on entity {name} cannot be a @derivedFrom field."
                ));
            }
            FieldType::RegularField { field_type, .. } => {
                if field_type.is_optional() {
                    return Err(anyhow!(
                        "The 'id' field on entity {name} must be non-nullable, e.g. 'id: ID!'."
                    ));
                }
                if field_type.is_array() {
                    return Err(anyhow!("The 'id' field on entity {name} cannot be a list."));
                }
                match field_type.get_underlying_scalar() {
                    GqlScalar::ID | GqlScalar::String | GqlScalar::Int | GqlScalar::BigInt(_) => {}
                    other => {
                        return Err(anyhow!(
                            "The 'id' field on entity {name} has unsupported type '{other}'. An \
                             entity id must be one of: ID, String, Int, BigInt."
                        ));
                    }
                }
            }
        }
    }

    if name.len() > MAX_PG_IDENTIFIER_LENGTH {
        return Err(anyhow!(
            "Entity name '{name}' is too long. It must be less than {} characters.",
            MAX_PG_IDENTIFIER_LENGTH + 1
        ));
    }

    Ok(())
}

const STORAGE_DIRECTIVE_HINT: &str =
    "Expected args from {postgres, clickhouse}: `postgres` takes a boolean, `clickhouse` takes a \
     boolean or a table options object, e.g. @storage(postgres: true, clickhouse: true) or \
     @storage(clickhouse: {partitionBy: \"toYYYYMM(timestamp)\", orderBy: [\"timestamp\"], ttl: \
     \"timestamp + INTERVAL 2 YEAR\"}).";

/// Parse an optional argument-free entity directive (`@crossChain`,
/// `@internal`): present at most once, with no arguments. Their semantics are
/// checked elsewhere — `@crossChain` legality depends on the config's
/// `disable_default_cross_chain`, and `@internal` relationship rules live in
/// `system_config.rs`.
fn parse_flag_directive(
    obj: &ObjectType<String>,
    directive_name: &str,
    source: &str,
) -> anyhow::Result<bool> {
    let directives: Vec<&Directive<'_, String>> = obj
        .directives
        .iter()
        .filter(|directive| directive.name == directive_name)
        .collect();

    match directives.as_slice() {
        [] => Ok(false),
        [directive] => {
            if let Some((arg_name, _)) = directive.arguments.first() {
                return Err(anyhow!(
                    "Invalid @{directive_name} directive on `{}`. It takes no arguments, but got \
                     `{}`.",
                    obj.name,
                    arg_name
                ))
                .context(at(source, directive.position));
            }
            Ok(true)
        }
        [_, duplicate, ..] => Err(anyhow!(
            "Invalid @{directive_name} directive on `{}`. Only one @{directive_name} directive is \
             allowed per entity.",
            obj.name
        ))
        .context(at(source, duplicate.position)),
    }
}

/// Parse the optional `@storage` directive on an entity. Returns the
/// `(postgres, clickhouse)` values as the user wrote them; `None` for an
/// unmentioned backend. The `clickhouse` arg accepts a boolean or a
/// ClickHouse table options object (the object form implies the backend is
/// enabled). Cross-entity checks (backend-not-globally-enabled,
/// missing-in-multi-storage-mode) happen later in `system_config.rs`.
fn parse_storage_directive(
    obj: &ObjectType<String>,
    resolver: &ColumnResolver,
    source: &str,
) -> anyhow::Result<(Option<bool>, Option<ClickHouseEntityStorage>)> {
    let mut storage_directives = obj
        .directives
        .iter()
        .filter(|directive| directive.name == "storage");

    let Some(directive) = storage_directives.next() else {
        return Ok((None, None));
    };

    if let Some(duplicate) = storage_directives.next() {
        return Err(anyhow!(
            "Invalid @storage directive on `{}`. Only one @storage directive is allowed per \
             entity. {STORAGE_DIRECTIVE_HINT}",
            obj.name
        ))
        .context(at(source, duplicate.position));
    }

    parse_storage_arguments(obj, directive, resolver).context(at(source, directive.position))
}

fn parse_storage_arguments(
    obj: &ObjectType<String>,
    directive: &Directive<'_, String>,
    resolver: &ColumnResolver,
) -> anyhow::Result<(Option<bool>, Option<ClickHouseEntityStorage>)> {
    let mut postgres: Option<bool> = None;
    let mut clickhouse: Option<ClickHouseEntityStorage> = None;

    for (arg_name, arg_value) in &directive.arguments {
        let is_duplicate = match arg_name.as_str() {
            "postgres" => postgres.is_some(),
            "clickhouse" => clickhouse.is_some(),
            other => {
                return Err(anyhow!(
                    "Invalid @storage directive on `{}`. Unknown argument `{}`. \
                     {STORAGE_DIRECTIVE_HINT}",
                    obj.name,
                    other
                ));
            }
        };
        if is_duplicate {
            return Err(anyhow!(
                "Invalid @storage directive on `{}`. Argument `{}` is specified more than once. \
                 {STORAGE_DIRECTIVE_HINT}",
                obj.name,
                arg_name
            ));
        }
        match (arg_name.as_str(), arg_value) {
            ("postgres", Value::Boolean(b)) => postgres = Some(*b),
            ("postgres", _) => {
                return Err(anyhow!(
                    "Invalid @storage directive on `{}`. Argument `postgres` must be a boolean. \
                     {STORAGE_DIRECTIVE_HINT}",
                    obj.name
                ));
            }
            ("clickhouse", Value::Boolean(b)) => {
                clickhouse = Some(ClickHouseEntityStorage::Enabled(*b))
            }
            ("clickhouse", Value::Object(arg_fields)) => {
                let options = parse_clickhouse_table_options(arg_fields, resolver)?;
                // An options object with nothing set only enables the backend,
                // so normalize it to the boolean form: it serializes identically
                // to `clickhouse: true` and won't diff a stored config.
                clickhouse = Some(if options == ClickHouseTableOptions::default() {
                    ClickHouseEntityStorage::Enabled(true)
                } else {
                    ClickHouseEntityStorage::Options(options)
                });
            }
            ("clickhouse", _) => {
                return Err(anyhow!(
                    "Invalid @storage directive on `{}`. Argument `clickhouse` must be a boolean \
                     or a table options object. {STORAGE_DIRECTIVE_HINT}",
                    obj.name
                ));
            }
            _ => unreachable!("arg_name is validated above"),
        }
    }

    let enables_anything = matches!(postgres, Some(true))
        || clickhouse
            .as_ref()
            .is_some_and(ClickHouseEntityStorage::is_enabled);
    if !enables_anything {
        return Err(anyhow!(
            "@storage on `{}` enables no storage. At least one of {{postgres, clickhouse}} must \
             be true.",
            obj.name
        ));
    }

    Ok((postgres, clickhouse))
}

fn parse_clickhouse_table_options(
    arg_fields: &std::collections::BTreeMap<String, Value<'_, String>>,
    resolver: &ColumnResolver,
) -> anyhow::Result<ClickHouseTableOptions> {
    let entity_name = resolver.entity;
    let expression = |key: &str, value: &Value<'_, String>| match value {
        Value::String(expr) if !expr.trim().is_empty() => Ok(expr.trim().to_string()),
        _ => Err(anyhow!(
            "Invalid @storage directive on `{entity_name}`. `clickhouse.{key}` must be a \
             non-empty string with a ClickHouse expression, e.g. clickhouse: {{{key}: \
             \"toYYYYMM(timestamp)\"}}."
        )),
    };

    let mut options = ClickHouseTableOptions::default();
    for (key, value) in arg_fields {
        match key.as_str() {
            "partitionBy" => options.partition_by = Some(expression(key, value)?),
            "ttl" => options.ttl = Some(expression(key, value)?),
            "orderBy" => {
                let field_names = match value {
                    Value::List(items) if !items.is_empty() => items
                        .iter()
                        .map(|item| match item {
                            Value::String(field_name) => Ok(field_name.trim().to_string()),
                            _ => Err(anyhow!(
                                "Invalid @storage directive on `{entity_name}`. \
                                 `clickhouse.orderBy` must be a list of entity field names, e.g. \
                                 clickhouse: {{orderBy: [\"timestamp\"]}}."
                            )),
                        })
                        .collect::<anyhow::Result<Vec<String>>>()?,
                    _ => {
                        return Err(anyhow!(
                            "Invalid @storage directive on `{entity_name}`. `clickhouse.orderBy` \
                             must be a non-empty list of entity field names, e.g. clickhouse: \
                             {{orderBy: [\"timestamp\"]}}."
                        ));
                    }
                };
                options.order_by = Some(resolve_order_by(resolver, field_names)?);
            }
            "skippingIndexes" => {
                let items = match value {
                    Value::List(items) if !items.is_empty() => items,
                    _ => {
                        return Err(anyhow!(
                            "Invalid @storage directive on `{entity_name}`. `clickhouse.skippingIndexes` \
                             must be a non-empty list of index objects, \
                             {CLICKHOUSE_SKIPPING_INDEX_HINT}."
                        ));
                    }
                };
                let indices = items
                    .iter()
                    .map(|item| match item {
                        Value::Object(index_fields) => {
                            parse_clickhouse_skipping_index(entity_name, index_fields)
                        }
                        _ => Err(anyhow!(
                            "Invalid @storage directive on `{entity_name}`. `clickhouse.skippingIndexes` \
                             must be a list of index objects, {CLICKHOUSE_SKIPPING_INDEX_HINT}."
                        )),
                    })
                    .collect::<anyhow::Result<Vec<ClickHouseSkippingIndex>>>()?;
                let mut seen = HashSet::new();
                for index in &indices {
                    if !seen.insert(&index.name) {
                        return Err(anyhow!(
                            "Invalid @storage directive on `{entity_name}`. `clickhouse.skippingIndexes` \
                             lists index name `{}` more than once.",
                            index.name
                        ));
                    }
                }
                options.skipping_indexes = Some(indices);
            }
            other => {
                return Err(anyhow!(
                    "Invalid @storage directive on `{entity_name}`. Unknown `clickhouse` option \
                     `{other}`. Expected options from {{partitionBy, orderBy, ttl, skippingIndexes}}, \
                     e.g. clickhouse: {{partitionBy: \"toYYYYMM(timestamp)\", orderBy: \
                     [\"timestamp\"], ttl: \"timestamp + INTERVAL 2 YEAR\"}}."
                ));
            }
        }
    }

    Ok(options)
}

const CLICKHOUSE_SKIPPING_INDEX_HINT: &str =
    "e.g. clickhouse: {skippingIndexes: [{name: \"idx_from\", expr: \
                                          \"fromAddress\", type: \"bloom_filter(0.01)\", \
                                          granularity: 4}]}";

fn parse_clickhouse_skipping_index(
    entity_name: &str,
    fields: &std::collections::BTreeMap<String, Value<'_, String>>,
) -> anyhow::Result<ClickHouseSkippingIndex> {
    let string_value = |key: &str, value: &Value<'_, String>| {
        match value {
        Value::String(s) if !s.trim().is_empty() => Ok(s.trim().to_string()),
        _ => Err(anyhow!(
            "Invalid @storage directive on `{entity_name}`. `clickhouse.skippingIndexes` entry field \
             `{key}` must be a non-empty string, {CLICKHOUSE_SKIPPING_INDEX_HINT}."
        )),
    }
    };

    let mut name = None;
    let mut expr = None;
    let mut index_type = None;
    let mut granularity = None;
    for (key, value) in fields {
        match key.as_str() {
            "name" => name = Some(string_value(key, value)?),
            "expr" => expr = Some(string_value(key, value)?),
            "type" => index_type = Some(string_value(key, value)?),
            "granularity" => {
                let parsed = match value {
                    Value::Int(i) => i.as_i64().filter(|v| (1..=i64::from(u32::MAX)).contains(v)),
                    _ => None,
                };
                match parsed {
                    Some(v) => granularity = Some(v as u32),
                    None => {
                        return Err(anyhow!(
                            "Invalid @storage directive on `{entity_name}`. `clickhouse.skippingIndexes` \
                             entry field `granularity` must be a positive integer, \
                             {CLICKHOUSE_SKIPPING_INDEX_HINT}."
                        ));
                    }
                }
            }
            other => {
                return Err(anyhow!(
                    "Invalid @storage directive on `{entity_name}`. Unknown `clickhouse.skippingIndexes` \
                     entry field `{other}`. Expected fields from {{name, expr, type, \
                     granularity}}, {CLICKHOUSE_SKIPPING_INDEX_HINT}."
                ));
            }
        }
    }

    let require = |value: Option<String>, key: &str| {
        value.ok_or_else(|| {
            anyhow!(
                "Invalid @storage directive on `{entity_name}`. `clickhouse.skippingIndexes` entry is \
                 missing required field `{key}`, {CLICKHOUSE_SKIPPING_INDEX_HINT}."
            )
        })
    };
    let name = require(name, "name")?;
    // The name is backtick-quoted in the emitted DDL, so restrict it to
    // identifier characters to keep the statement well-formed.
    let valid_name = name
        .chars()
        .enumerate()
        .all(|(i, c)| c == '_' || c.is_ascii_alphabetic() || (i > 0 && c.is_ascii_digit()));
    if !valid_name {
        return Err(anyhow!(
            "Invalid @storage directive on `{entity_name}`. `clickhouse.skippingIndexes` name `{name}` \
             must contain only alphanumeric characters and underscores, and must not start with \
             a digit."
        ));
    }
    Ok(ClickHouseSkippingIndex {
        name,
        expr: require(expr, "expr")?,
        index_type: require(index_type, "type")?,
        granularity,
    })
}

///  used to get the positive integers in the directives from the GraphQL schema.
fn get_positive_integer(arg_value: &Value<String>) -> anyhow::Result<u32> {
    match arg_value {
        Value::Int(i) => {
            let val = i.as_i64().context("Failed to convert value to i64")?;
            if val < 0 {
                return Err(anyhow!("Value must be a positive integer"));
            }
            Ok(val as u32)
        }
        _ => Err(anyhow!("Value must be an integer")),
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Field {
    pub name: String,
    pub field_type: FieldType,
    pub description: Option<String>,
}

impl Field {
    fn from_obj_field(field: &ObjField<String>) -> anyhow::Result<Self> {
        // Collect directives
        let derived_from_directives = field
            .directives
            .iter()
            .filter(|&directive| directive.name == "derivedFrom")
            .collect::<Vec<&Directive<'_, String>>>();

        let indexed_directives = field
            .directives
            .iter()
            .filter(|&directive| directive.name == "index")
            .collect::<Vec<&Directive<'_, String>>>();

        let config_directives = field
            .directives
            .iter()
            .filter(|&directive| directive.name == "config")
            .collect::<Vec<&Directive<'_, String>>>();

        // Validate directive usage
        let derived_from_count = derived_from_directives.len();
        let indexed_count = indexed_directives.len();
        let config_count = config_directives.len();

        if derived_from_count > 1 || indexed_count > 1 || config_count > 1 {
            return Err(anyhow!(
                "Cannot use more than one of the same directive on field {}",
                field.name
            ));
        }

        if derived_from_count > 0 && indexed_count > 0 {
            return Err(anyhow!(
                "A field cannot be both @derivedFrom and @index: {}",
                field.name
            ));
        }

        if (field.name == "id" || field.name == "ID")
            && (indexed_count > 0 || derived_from_count > 0)
        {
            return Err(anyhow!(
                "The field 'id' or 'ID' cannot be indexed or derivedFrom. Please remove the \
                 @index or @derivedFrom directive from field {}",
                field.name
            ));
        }

        let maybe_derived_from_directive = derived_from_directives.first();
        let derived_from_field = match maybe_derived_from_directive {
            None => None,
            Some(d) => {
                let field_arg = d.arguments.iter().find(|a| a.0 == "field").ok_or_else(|| {
                    anyhow!(
                        "No 'field' argument supplied to @derivedFrom directive on field {}",
                        field.name
                    )
                })?;
                match &field_arg.1 {
                    Value::String(val) => Some(val.clone()),
                    _ => Err(anyhow!(
                        "'field' argument in @derivedFrom directive on field {} needs to contain \
                         a string",
                        field.name
                    ))?,
                }
            }
        };

        let is_indexed = indexed_count > 0;

        // Parse the field type into UserDefinedFieldType
        let underlying_scalar = UserDefinedFieldType::from_obj_field_type(
            &field.field_type,
            &PgTypeModifications::default(),
        )
        .get_underlying_scalar();

        let mut pg_type_modifications = PgTypeModifications::default();

        // Process @config
        if let Some(config_directive) = config_directives.first() {
            match underlying_scalar {
                GqlScalar::BigInt(_) => {
                    // Process precision for BigInt
                    if config_directive.arguments.len() != 1 {
                        return Err(anyhow!(
                            "The config directive on a BigInt should only take a single integer \
                             argument called 'precision'. Field '{}'",
                            field.name
                        ));
                    }
                    let (arg_name, arg_value) = config_directive.arguments.first().unwrap();
                    if arg_name != "precision" {
                        return Err(anyhow!(
                            "The config directive on a BigInt should only have a 'precision' \
                             parameter. Unknown parameter '{}'. Field '{}'",
                            arg_name,
                            field.name
                        ));
                    }
                    let precision = get_positive_integer(arg_value).context(format!(
                        "Parsing precision.digits directive on BigInt field with field name {}",
                        field.name
                    ))?;
                    pg_type_modifications.big_int_precision = Some(precision);
                }
                GqlScalar::BigDecimal(_) => {
                    // Process precision and scale for BigDecimal
                    let mut precision: Option<u32> = None;
                    let mut scale: Option<u32> = None;
                    let mut unknown_params = Vec::new();

                    for (arg_name, arg_value) in &config_directive.arguments {
                        match arg_name.as_str() {
                            "precision" => {
                                precision =
                                    Some(get_positive_integer(arg_value).context(format!(
                                        "Parsing numeric.precision directive on BigDecimal with \
                                         field name {}",
                                        field.name
                                    ))?);
                            }
                            "scale" => {
                                scale = Some(get_positive_integer(arg_value).context(format!(
                                    "Parsing numeric.scale directive on BigDecimal with field \
                                     name {}",
                                    field.name
                                ))?);
                            }
                            unknown_param => {
                                unknown_params.push(unknown_param);
                            }
                        }
                    }

                    if !unknown_params.is_empty() {
                        return Err(anyhow!(
                            "The config directive on a BigDecimal should only have 'precision' \
                             and 'scale' parameters. Unknown parameter(s) '{}'. Field '{}'",
                            unknown_params.join(", "),
                            field.name
                        ));
                    }

                    if precision.is_none() || scale.is_none() {
                        return Err(anyhow!(
                            "The config directive on a BigDecimal must have both 'precision' and \
                             'scale' parameters. Field '{}'",
                            field.name
                        ));
                    }

                    pg_type_modifications.big_decimal_precision_scale =
                        Some((precision.unwrap(), scale.unwrap()));
                }
                _ => {
                    return Err(anyhow!(
                        "The config directive is only applicable to BigInt and BigDecimal scalar \
                         types. Field '{}'",
                        field.name
                    ));
                }
            }
        }

        let params = FieldTypeParams {
            derived_from_field,
            has_indexed_directive: is_indexed,
            pg_type_modifications,
        };

        let field_type = FieldType::from_obj_field_type(&field.field_type, params)?;

        Ok(Field {
            name: field.name.clone(),
            field_type,
            description: field.description.clone(),
        })
    }

    fn get_relationship(&self) -> Option<Relationship> {
        match self.field_type.get_underlying_scalar() {
            GqlScalar::Custom(name) => Some(Relationship::TypeDef { name: name.clone() }),
            _ => None,
        }
    }

    fn validate_field_type(&self, schema: &Schema) -> anyhow::Result<()> {
        self.field_type.validate_type(schema)
    }

    pub fn get_relational_key(&self, schema: &Schema) -> anyhow::Result<String> {
        match &self.field_type {
            FieldType::DerivedFromField {
                derived_from_field,
                entity_name,
            } => {
                let entity_field = schema
                    .entities
                    .get(entity_name)
                    .ok_or_else(|| anyhow!("Unexpected, entity {entity_name} does not exist"))?
                    .get_field(derived_from_field)
                    .ok_or_else(|| {
                        anyhow!(
                            "Unexpected, field {derived_from_field} does not exist on entity \
                             {entity_name}"
                        )
                    })?;

                match entity_field.field_type.get_underlying_scalar() {
                    //In the case where there is a recipracol lookup, the actual
                    //underlying field contains _id at the end
                    GqlScalar::Custom(name)
                        if matches!(schema.try_get_type_def(&name)?, TypeDef::Entity(_)) =>
                    {
                        Ok(format!("{derived_from_field}_id"))
                    }
                    //In the case where its just an an ID or a string,
                    //just keep the the field as is from what was
                    //defined in @derivedFrom
                    GqlScalar::ID | GqlScalar::String => Ok(derived_from_field.clone()),
                    _ => Err(anyhow!(
                        "Unexpected, derived from field is neither an ID, String or bidirectional \
                         relationship"
                    ))?,
                }
            }

            FieldType::RegularField { .. } => Ok(self.name.clone()),
        }
    }

    pub fn is_indexed_field(&self, entity: &Entity) -> bool {
        let has_indexed_directive = self.field_type.has_indexed_directive();
        let has_single_field_index_directive = entity
            .multi_field_indexes
            .iter()
            .filter_map(MultiFieldIndex::as_single)
            .any(|column| matches!(column, EntityColumn::Declared(name) if name == &self.name));

        has_indexed_directive || has_single_field_index_directive
    }

    pub fn is_derived_lookup_field(&self, entity: &Entity, schema: &Schema) -> bool {
        schema.entities.values().any(|entity_inner| {
            entity_inner.get_fields().iter().any(|field| {
                matches!(
                    &field.field_type,
                    FieldType::DerivedFromField {
                        entity_name,
                        derived_from_field
                    } if entity_name == &entity.name && derived_from_field == &self.name
                )
            })
        })
    }

    pub fn is_primary_key(&self) -> bool {
        self.name.as_str().to_lowercase() == "id"
    }

    ///Returns None if it is a derived field
    pub fn get_postgres_field(
        &self,
        schema: &Schema,
        entity: &Entity,
    ) -> anyhow::Result<Option<PGField>> {
        match &self.field_type {
            FieldType::DerivedFromField { .. } => Ok(None),
            FieldType::RegularField {
                field_type: gql_field_type,
                ..
            } => Ok(Some(PGField {
                field_name: self.name.clone(),
                field_type: gql_field_type.to_underlying_postgres_primitive(schema)?,
                is_array: gql_field_type.is_array(),
                is_index: self.is_indexed_field(entity),
                linked_entity: gql_field_type.get_linked_entity(schema)?,
                is_primary_key: self.is_primary_key(),
                is_nullable: gql_field_type.is_optional(),
                description: self.description.clone(),
            })),
        }
    }

    pub fn get_derived_from_field(&self) -> Option<DerivedFieldTemplate> {
        match &self.field_type {
            FieldType::DerivedFromField {
                entity_name,
                derived_from_field,
            } => Some(DerivedFieldTemplate {
                field_name: self.name.clone(),
                derived_from_field: derived_from_field.clone(),
                derived_from_entity: entity_name.clone(),
                description: self.description.clone(),
            }),
            FieldType::RegularField { .. } => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum IndexFieldDirection {
    Asc,
    Desc,
}

impl IndexFieldDirection {
    /// The spelling the generated ReScript and the stored config share, as
    /// opposed to `Display`, which renders the lowercase SQL keyword.
    pub fn as_pascal_str(&self) -> &'static str {
        match self {
            Self::Asc => "Asc",
            Self::Desc => "Desc",
        }
    }
}

impl fmt::Display for IndexFieldDirection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            IndexFieldDirection::Asc => write!(f, "asc"),
            IndexFieldDirection::Desc => write!(f, "desc"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct IndexField {
    pub column: EntityColumn,
    pub direction: IndexFieldDirection,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct MultiFieldIndex(Vec<IndexField>);

impl MultiFieldIndex {
    pub fn get_index_fields(&self) -> &[IndexField] {
        &self.0
    }

    fn as_single(&self) -> Option<&EntityColumn> {
        match self.0.as_slice() {
            [only] => Some(&only.column),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum UserDefinedFieldType {
    Single(GqlScalar),
    ListType(Box<UserDefinedFieldType>),
    NonNullType(Box<UserDefinedFieldType>),
}

impl UserDefinedFieldType {
    fn from_obj_field_type(
        obj_field_type: &ObjType<'_, String>,
        pg_type_modifications: &PgTypeModifications,
    ) -> Self {
        match obj_field_type {
            ObjType::NamedType(name) => {
                UserDefinedFieldType::Single(GqlScalar::from_str(name, pg_type_modifications))
            }
            ObjType::NonNullType(obj_field_type) => UserDefinedFieldType::NonNullType(Box::new(
                Self::from_obj_field_type(obj_field_type, pg_type_modifications),
            )),
            ObjType::ListType(obj_field_type) => UserDefinedFieldType::ListType(Box::new(
                Self::from_obj_field_type(obj_field_type, pg_type_modifications),
            )),
        }
    }

    pub fn validate_type(&self, schema: &Schema) -> anyhow::Result<()> {
        match self {
            Self::Single(_) => Ok(()),
            Self::ListType(field_type) => match field_type.as_ref() {
                //Postgres doesn't support nullable types inside of arrays
                Self::NonNullType(inner_field_type) => match inner_field_type.as_ref() {
                    //Don't allow non derived from enity relationships inside arrays
                    Self::Single(GqlScalar::Custom(name))
                        if matches!(schema.try_get_type_def(name)?, TypeDef::Entity(_)) =>
                    {
                        Err(anyhow!(
                            "The [{name}!]! field type requires an explicit @derivedFrom. Alternatively, check methods for referencing entities outlined in the docs. https://docs.envio.dev/docs/HyperIndex/schema#relationships-one-to-many-derivedfrom"
                        ))
                    }
                    //TODO: add support for these types
                    //currently we would need to use explicid casts in the queries to make these
                    //work https://github.com/porsager/postgres/pull/392
                    Self::Single(GqlScalar::Boolean) => {
                        Err(anyhow!("Arrays of booleans are not yet supported."))
                    }
                    Self::Single(GqlScalar::Timestamp) => {
                        Err(anyhow!("Arrays of timestamps are not yet supported."))
                    }
                    _ => field_type.validate_type(schema),
                },
                Self::Single(gql_scalar) => Err(anyhow!(
                    "Nullable scalars inside lists are unsupported. Please include a '!' \
                     after your '{}' scalar",
                    gql_scalar
                )),
                Self::ListType(_) => Err(anyhow!(
                    "Nullable multidimensional lists types are unsupported, please include \
                     a '!' for your inner list type eg. [[Int!]!]"
                )),
            },
            Self::NonNullType(field_type) => match field_type.as_ref() {
                Self::NonNullType(_) => Err(anyhow!(
                    "Nested Not Null types are unsupported. Please remove any sequential '!' \
                     symbols after types in schema"
                )),
                _ => field_type.validate_type(schema),
            },
        }
    }

    pub fn to_underlying_postgres_primitive(&self, schema: &Schema) -> anyhow::Result<PGPrimitive> {
        match self {
            Self::Single(gql_scalar) => gql_scalar.to_underlying_postgres_primitive(schema),
            Self::ListType(field_type) | Self::NonNullType(field_type) => {
                field_type.to_underlying_postgres_primitive(schema)
            }
        }
    }

    pub fn is_optional(&self) -> bool {
        !matches!(self, Self::NonNullType(_))
    }

    pub fn is_array(&self) -> bool {
        match self {
            Self::ListType(_) => true,
            Self::NonNullType(field_type) => field_type.is_array(),
            Self::Single(_) => false,
        }
    }

    pub fn to_rescript_type(&self, schema: &Schema) -> anyhow::Result<TypeIdent> {
        let composed_type_name = match self {
            //Only types in here should be non optional
            Self::NonNullType(field_type) => match field_type.as_ref() {
                Self::Single(gql_scalar) => gql_scalar.to_rescript_type(schema)?,
                Self::ListType(field_type) => {
                    TypeIdent::Array(Box::new(field_type.to_rescript_type(schema)?))
                }
                //This case shouldn't happen, and should recurse without adding any types if so
                //A double non null would be !! in gql
                Self::NonNullType(field_type) => field_type.to_rescript_type(schema)?,
            },
            //If we match this case it missed the non null path entirely and should be optional
            Self::Single(gql_scalar) => {
                TypeIdent::Option(Box::new(gql_scalar.to_rescript_type(schema)?))
            }
            //If we match this case it missed the non null path entirely and should be optional
            Self::ListType(field_type) => TypeIdent::Option(Box::new(TypeIdent::Array(Box::new(
                field_type.to_rescript_type(schema)?,
            )))),
        };
        Ok(composed_type_name)
    }

    fn get_underlying_scalar(&self) -> GqlScalar {
        match self {
            Self::Single(gql_scalar) => gql_scalar.clone(),
            Self::ListType(field_type) | Self::NonNullType(field_type) => {
                field_type.get_underlying_scalar()
            }
        }
    }

    pub fn is_entity_field(&self, schema: &Schema) -> anyhow::Result<bool> {
        self.get_underlying_scalar().is_entity(schema)
    }

    ///Returns None if field is not a linked entity and   Some(<ENTITY_NAME>) if it is
    pub fn get_linked_entity(&self, schema: &Schema) -> anyhow::Result<Option<String>> {
        self.get_underlying_scalar().get_linked_entity(schema)
    }

    fn to_string_internal(&self) -> String {
        match &self {
            Self::Single(gql_scalar) => gql_scalar.to_string(),
            Self::ListType(field_type) => format!("[{}]", field_type),
            Self::NonNullType(field_type) => format!("{}!", field_type),
        }
    }

    fn strip_non_null(&self) -> &Self {
        match self {
            Self::NonNullType(inner) => inner.as_ref(),
            other => other,
        }
    }

    /// Returns the name of the entity a @derivedFrom field looks up, or None
    /// when the field isn't shaped like one.
    ///
    /// The nullability the field is written with carries no meaning: the lookup
    /// is computed from the other side of the relation, so `[Child!]!`,
    /// `[Child!]`, `[Child]!` and `[Child]` all name the same one-to-many
    /// relation and are all generated as `[Child!]!`. The list itself does carry
    /// meaning — a derived field is exposed as a list everywhere it surfaces, so
    /// the one-to-one `Child @derivedFrom(...)` is refused rather than quietly
    /// answered with an array.
    fn get_name_of_derived_from_entity(&self) -> Option<String> {
        match self.strip_non_null() {
            Self::ListType(item) => match item.strip_non_null() {
                Self::Single(GqlScalar::Custom(name)) => Some(name.clone()),
                _ => None,
            },
            _ => None,
        }
    }

    pub fn from_dyn_sol_type(sol_type: &DynSolType) -> anyhow::Result<Self> {
        match sol_type {
            DynSolType::Uint(_) | DynSolType::Int(_) => Ok(Self::NonNullType(Box::new(
                Self::Single(GqlScalar::BigInt(None)),
            ))),
            DynSolType::Bool => Ok(Self::NonNullType(Box::new(Self::Single(
                GqlScalar::Boolean,
            )))),
            DynSolType::Address
            | DynSolType::Bytes
            | DynSolType::String
            | DynSolType::FixedBytes(_) => {
                Ok(Self::NonNullType(Box::new(Self::Single(GqlScalar::String))))
            }
            DynSolType::Function => Err(anyhow!("Unsupported contract import type 'function'")),
            // Tuples (structs), `tuple[]`, and `tuple[N]` all flow through as
            // JSON entity columns so the contract-import path handles every
            // ABI shape uniformly — the handler assigns the structured event
            // value directly, and the entity row stores the nested object as
            // JSON without needing invented column names for nested fields.
            DynSolType::Tuple(_) => Ok(Self::NonNullType(Box::new(Self::Single(GqlScalar::Json)))),
            DynSolType::Array(inner) | DynSolType::FixedArray(inner, _) => {
                match inner.as_ref() {
                    DynSolType::Tuple(_) => {
                        Ok(Self::NonNullType(Box::new(Self::Single(GqlScalar::Json))))
                    }
                    DynSolType::Array(_) | DynSolType::FixedArray(_, _) => {
                        Err(anyhow!("Unhandled contract import type 'array of array'"))
                    }
                    // Primitive-element arrays map to `[Scalar!]!`.
                    DynSolType::Bool
                    | DynSolType::Int(_)
                    | DynSolType::Uint(_)
                    | DynSolType::FixedBytes(_)
                    | DynSolType::Address
                    | DynSolType::Bytes
                    | DynSolType::String => {
                        let inner_type = Self::from_dyn_sol_type(inner)
                            .context("Unhandled contract import nested type in array")?;
                        Ok(Self::NonNullType(Box::new(Self::ListType(Box::new(
                            inner_type,
                        )))))
                    }
                    DynSolType::Function => {
                        Err(anyhow!("Unsupported contract import type 'function'"))
                    }
                }
            }
        }
    }
}

// Implement the Display trait for the custom struct
impl fmt::Display for UserDefinedFieldType {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.to_string_internal())
    }
}

impl Serialize for UserDefinedFieldType {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(self.to_string().as_str())
    }
}

#[derive(Default)]
pub struct PgTypeModifications {
    pub big_int_precision: Option<u32>,
    pub big_decimal_precision_scale: Option<(u32, u32)>,
}

pub struct FieldTypeParams {
    pub derived_from_field: Option<String>,
    pub has_indexed_directive: bool,
    pub pg_type_modifications: PgTypeModifications,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum FieldType {
    DerivedFromField {
        entity_name: String,
        derived_from_field: String,
    },
    RegularField {
        field_type: UserDefinedFieldType,
        has_indexed_directive: bool,
    },
}

impl FieldType {
    fn to_user_defined_field_type(&self) -> UserDefinedFieldType {
        match self {
            Self::RegularField { field_type: t, .. } => t.clone(),
            Self::DerivedFromField { entity_name, .. } => {
                use UserDefinedFieldType::*;
                NonNullType(Box::new(ListType(Box::new(NonNullType(Box::new(Single(
                    GqlScalar::Custom(entity_name.clone()),
                )))))))
            }
        }
    }

    fn from_obj_field_type(
        obj_field_type: &ObjType<'_, String>,
        params: FieldTypeParams,
    ) -> anyhow::Result<Self> {
        let field_type = UserDefinedFieldType::from_obj_field_type(
            obj_field_type,
            &params.pg_type_modifications,
        );

        match params.derived_from_field {
            None => Ok(Self::RegularField {
                field_type,
                has_indexed_directive: params.has_indexed_directive,
            }),
            Some(derived_from_field) => match field_type.get_name_of_derived_from_entity() {
                None => {
                    let example_str = Self::DerivedFromField {
                        entity_name: "<ENTITY_NAME>".to_string(),
                        derived_from_field,
                    }
                    .to_string();

                    Err(anyhow!(
                        "Field marked with @derivedFrom directive does not meet the required \
                         structure. Field should be a list of entities, for example: {example_str}"
                    ))
                }
                Some(entity_name) => Ok(Self::DerivedFromField {
                    entity_name,
                    derived_from_field,
                }),
            },
        }
    }

    pub fn validate_type(&self, schema: &Schema) -> anyhow::Result<()> {
        match self {
            Self::DerivedFromField { .. } => Ok(()), //Already validated
            Self::RegularField { field_type: t, .. } => t.validate_type(schema),
        }
    }

    pub fn is_optional(&self) -> bool {
        self.to_user_defined_field_type().is_optional()
    }

    pub fn is_derived_from(&self) -> bool {
        matches!(self, Self::DerivedFromField { .. })
    }

    fn has_indexed_directive(&self) -> bool {
        match self {
            Self::DerivedFromField { .. } => false,
            Self::RegularField {
                has_indexed_directive,
                ..
            } => *has_indexed_directive,
        }
    }

    pub fn is_array(&self) -> bool {
        match self {
            Self::DerivedFromField { .. } => true,
            Self::RegularField { field_type: t, .. } => t.is_array(),
        }
    }

    pub fn to_rescript_type(&self, schema: &Schema) -> anyhow::Result<TypeIdent> {
        self.to_user_defined_field_type().to_rescript_type(schema)
    }

    pub fn get_underlying_scalar(&self) -> GqlScalar {
        self.to_user_defined_field_type().get_underlying_scalar()
    }

    pub fn is_entity_field(&self, schema: &Schema) -> anyhow::Result<bool> {
        self.to_user_defined_field_type().is_entity_field(schema)
    }

    fn to_string_internal(&self) -> String {
        match self {
            Self::DerivedFromField {
                derived_from_field, ..
            } => {
                let field_str = self.to_user_defined_field_type().to_string();
                format!("{field_str} @derivedFrom(field: \"{derived_from_field}\")")
            }
            Self::RegularField { field_type: t, .. } => t.to_string(),
        }
    }

    pub fn from_dyn_sol_type(sol_type: &DynSolType) -> anyhow::Result<Self> {
        Ok(Self::RegularField {
            field_type: UserDefinedFieldType::from_dyn_sol_type(sol_type)?,
            has_indexed_directive: false,
        })
    }
}

// Implement the Display trait for the custom struct
impl fmt::Display for FieldType {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.to_string_internal())
    }
}

impl Serialize for FieldType {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(self.to_string().as_str())
    }
}

#[subenum(BuiltInGqlScalar, AdditionalGqlScalar)]
#[derive(Debug, Clone, PartialEq, strum_macros::Display, Eq, Hash)]
pub enum GqlScalar {
    #[subenum(BuiltInGqlScalar)]
    ID,
    #[subenum(BuiltInGqlScalar)]
    String,
    #[subenum(BuiltInGqlScalar)]
    Int,
    #[subenum(BuiltInGqlScalar)]
    Float,
    #[subenum(BuiltInGqlScalar)]
    Boolean,
    #[subenum(AdditionalGqlScalar)]
    BigInt(Option<u32>), // Optional argument, max digits (base 10) this number can have.
    #[subenum(AdditionalGqlScalar)]
    BigDecimal(Option<(u32, u32)>),
    #[subenum(AdditionalGqlScalar)]
    Timestamp,
    #[subenum(AdditionalGqlScalar)]
    Bytes,
    #[subenum(AdditionalGqlScalar)]
    Json,
    #[strum(to_string = "{0}")]
    Custom(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct BigIntPrecisionScale {
    pub precision: Option<u32>,
    pub scale: Option<u32>,
}

#[derive(Debug, Clone)]
pub enum Relationship {
    TypeDef {
        name: String,
    },
    DerivedFrom {
        name: String,
        derived_from_field: String,
    },
}

impl GqlScalar {
    fn is_entity(&self, schema: &Schema) -> anyhow::Result<bool> {
        match self {
            GqlScalar::Custom(name) => {
                Ok(matches!(schema.try_get_type_def(name)?, TypeDef::Entity(_)))
            }
            _ => Ok(false),
        }
    }

    fn from_str(name: &str, pg_type_modifications: &PgTypeModifications) -> Self {
        match name {
            "ID" => GqlScalar::ID,
            "String" => GqlScalar::String,
            "Int" => GqlScalar::Int,
            "Float" => GqlScalar::Float,
            "Boolean" => GqlScalar::Boolean,
            "BigInt" => GqlScalar::BigInt(pg_type_modifications.big_int_precision),
            "BigDecimal" => {
                GqlScalar::BigDecimal(pg_type_modifications.big_decimal_precision_scale)
            }
            "Timestamp" => GqlScalar::Timestamp,
            "Bytes" => GqlScalar::Bytes,
            "Json" => GqlScalar::Json,
            name => GqlScalar::Custom(name.to_string()),
        }
    }

    pub fn to_underlying_postgres_primitive(&self, schema: &Schema) -> anyhow::Result<PGPrimitive> {
        let converted = match self {
            GqlScalar::ID => PGPrimitive::String,
            GqlScalar::String => PGPrimitive::String,
            GqlScalar::Int => PGPrimitive::Int32,
            GqlScalar::Float => PGPrimitive::Number, // Should we allow this type? Rounding issues will abound.
            GqlScalar::Boolean => PGPrimitive::Boolean,
            GqlScalar::Bytes => PGPrimitive::String,
            GqlScalar::Json => PGPrimitive::Json,
            GqlScalar::BigInt(precision) => PGPrimitive::BigInt {
                precision: *precision,
            },
            GqlScalar::BigDecimal(precision_and_scale) => {
                PGPrimitive::BigDecimal(*precision_and_scale)
            }
            GqlScalar::Timestamp => PGPrimitive::Date,
            GqlScalar::Custom(name) => match schema.try_get_type_def(name)? {
                // A relation stores the referenced entity's id, so the foreign
                // key column takes that id's Postgres type. `linked_entity`
                // still marks it as a relation for the `_id` suffix and Hasura.
                TypeDef::Entity(entity) => entity
                    .get_id_scalar()?
                    .to_underlying_postgres_primitive(schema)?,
                TypeDef::Enum => PGPrimitive::Enum(name.clone()),
            },
        };
        Ok(converted)
    }

    fn to_rescript_type(&self, schema: &Schema) -> anyhow::Result<TypeIdent> {
        let res_type = match self {
            GqlScalar::ID => TypeIdent::ID,
            GqlScalar::String => TypeIdent::String,
            GqlScalar::Int => TypeIdent::Int,
            GqlScalar::BigInt(_) => TypeIdent::BigInt,
            GqlScalar::BigDecimal(_) => TypeIdent::BigDecimal,
            GqlScalar::Float => TypeIdent::Float,
            GqlScalar::Bytes => TypeIdent::String,
            GqlScalar::Json => TypeIdent::Json,
            GqlScalar::Boolean => TypeIdent::Bool,
            GqlScalar::Timestamp => TypeIdent::Timestamp,
            GqlScalar::Custom(name) => match schema.try_get_type_def(name)? {
                // A foreign key adopts the referenced entity's id type so the
                // relation is keyed on matching types on both sides. An `ID`
                // target resolves to the concrete `string` rather than the `id`
                // alias: every entity module declares its own `type id`, which
                // shadows the shared alias and would silently retype a string
                // foreign key as the owning entity's numeric id.
                TypeDef::Entity(entity) => match entity.get_id_scalar()? {
                    GqlScalar::ID => TypeIdent::String,
                    id_scalar => id_scalar.to_rescript_type(schema)?,
                },
                TypeDef::Enum => TypeIdent::SchemaEnum(name.to_capitalized_options()),
            },
        };
        Ok(res_type)
    }

    fn get_linked_entity(&self, schema: &Schema) -> anyhow::Result<Option<String>> {
        let opt_entity_name = match self {
            Self::Custom(name) => match schema.try_get_type_def(name)? {
                TypeDef::Entity(entity) => Some(entity.name.clone()),
                TypeDef::Enum => None,
            },
            _ => None,
        };

        Ok(opt_entity_name)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        anyhow, ClickHouseEntityStorage, ClickHouseSkippingIndex, ClickHouseTableOptions,
        DefaultChainScope, Entity, EntityColumn, Field, FieldType, GqlScalar, GraphQLEnum, Schema,
        UserDefinedFieldType, DEFAULT_SCHEMA_PATH,
    };
    use crate::config_parsing::field_types::Primitive as PGPrimitive;
    use graphql_parser::schema::{parse_schema, Definition, Document, ObjectType, TypeDefinition};

    fn setup_document(schema: &str) -> anyhow::Result<Document<'_, String>> {
        parse_schema::<String>(schema).map_err(|e| anyhow!("Failed to parse schema: {:?}", e))
    }

    fn get_entities_from_document(gql_doc: Document<String>) -> Vec<ObjectType<String>> {
        gql_doc
            .definitions
            .into_iter()
            .filter_map(|d| {
                if let Definition::TypeDefinition(TypeDefinition::Object(obj)) = d {
                    Some(obj)
                } else {
                    None
                }
            })
            .collect()
    }

    fn get_first_entity_from_string(schema_str: &str) -> ObjectType<'_, String> {
        let gql_doc = setup_document(schema_str).unwrap();
        let entities = get_entities_from_document(gql_doc);
        entities.first().unwrap().clone()
    }

    #[test]
    fn gql_type_to_rescript_type_string() {
        let empty_schema = Schema::empty();
        let rescript_type = UserDefinedFieldType::Single(GqlScalar::String)
            .to_rescript_type(&empty_schema)
            .expect("expected rescript option string");

        assert_eq!(rescript_type.to_string(), "option<string>".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_int() {
        let empty_schema = Schema::empty();
        let rescript_type = UserDefinedFieldType::Single(GqlScalar::Int)
            .to_rescript_type(&empty_schema)
            .expect("expected rescript option string");

        assert_eq!(rescript_type.to_string(), "option<int>".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_non_null_int() {
        let empty_schema = Schema::empty();
        let rescript_type = UserDefinedFieldType::NonNullType(Box::new(
            UserDefinedFieldType::Single(GqlScalar::Int),
        ))
        .to_rescript_type(&empty_schema)
        .expect("expected rescript type string");

        assert_eq!(rescript_type.to_string(), "int".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_non_null_array() {
        let empty_schema = Schema::empty();
        let rescript_type = UserDefinedFieldType::NonNullType(Box::new(
            UserDefinedFieldType::ListType(Box::new(UserDefinedFieldType::NonNullType(Box::new(
                UserDefinedFieldType::Single(GqlScalar::Int),
            )))),
        ))
        .to_rescript_type(&empty_schema)
        .expect("expected rescript type string");

        assert_eq!(rescript_type.to_string(), "array<int>".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_null_array_int() {
        let empty_schema = Schema::empty();

        let rescript_type =
            UserDefinedFieldType::ListType(Box::new(UserDefinedFieldType::Single(GqlScalar::Int)))
                .to_rescript_type(&empty_schema)
                .expect("expected rescript type string");

        assert_eq!(
            rescript_type.to_string(),
            "option<array<option<int>>>".to_owned()
        );
    }

    #[test]
    fn gql_type_to_rescript_type_entity() {
        // A relation resolves to the referenced entity's id rescript type. A
        // String-id target yields `string`, an Int-id target yields `int`.
        let schema_str = r#"
type Referencer {
  id: ID!
  stringRelated: StringEntity
  numericRelated: NumericEntity!
}

type StringEntity {
  id: ID!
}

type NumericEntity {
  id: Int!
}
        "#;
        let schema = Schema::from_string(schema_str, DefaultChainScope::CrossChain).unwrap();
        let referencer = schema.entities.get("Referencer").unwrap();

        // Foreign keys render as the concrete id scalar, never the `id` alias:
        // each entity module declares its own `type id`, so a numeric-id entity
        // holding a relation to a string-id entity would otherwise resolve that
        // foreign key to its own numeric `id` while the column stays text.
        let string_related = referencer.get_field("stringRelated").unwrap();
        assert_eq!(
            string_related
                .field_type
                .to_rescript_type(&schema)
                .unwrap()
                .to_string(),
            "option<string>".to_owned()
        );

        let numeric_related = referencer.get_field("numericRelated").unwrap();
        assert_eq!(
            numeric_related
                .field_type
                .to_rescript_type(&schema)
                .unwrap()
                .to_string(),
            "int".to_owned()
        );
    }

    #[test]
    fn gql_type_to_rescript_type_enum() {
        let name = String::from("TestEnum");
        let test_enum = GraphQLEnum::new(name.clone(), vec![], None).unwrap();
        let schema = Schema::new(vec![], vec![test_enum]).unwrap();
        let rescript_type = UserDefinedFieldType::Single(GqlScalar::Custom(name))
            .to_rescript_type(&schema)
            .expect("expected rescript type string");

        assert_eq!(
            rescript_type.to_string(),
            "option<Enums.TestEnum.t>".to_owned()
        );
    }

    #[test]
    fn field_type_is_optional_test() {
        let test_scalar = GqlScalar::Custom(String::from("TestEntity"));
        let test_field_type = UserDefinedFieldType::Single(test_scalar);
        assert!(
            test_field_type.is_optional(),
            "single field should have been optional"
        );

        // ListType:
        let test_list_type = UserDefinedFieldType::ListType(Box::new(test_field_type));
        assert!(
            test_list_type.is_optional(),
            "list field should have been optional"
        );

        // NonNullType
        let gql_array_non_null_type = UserDefinedFieldType::NonNullType(Box::new(test_list_type));
        assert!(
            !gql_array_non_null_type.is_optional(),
            "non-null field should not be optional"
        );
    }

    fn get_field_type_helper_with_additional(
        gql_field_str: &str,
        enum_types: Vec<GraphQLEnum>,
    ) -> FieldType {
        let enum_type_defs: String = enum_types
            .iter()
            .map(|e| format!("enum {} {{\n{}\n}}", e.name, e.values.join("\n")))
            .collect::<Vec<_>>()
            .join("\n");

        let schema_string = format!(
            r#"
        type TestEntity {{
          id: ID!
          test_field: {gql_field_str}
        }}
        {enum_type_defs}
        "#,
        );
        let schema_doc = graphql_parser::schema::parse_schema::<String>(&schema_string).unwrap();

        let schema = Schema::from_document(
            schema_doc,
            DefaultChainScope::CrossChain,
            DEFAULT_SCHEMA_PATH,
        )
        .expect("bad schema");

        let test_field = schema
            .entities
            .get("TestEntity")
            .expect("No test entity in schema")
            .get_field("test_field")
            .expect("No field test_field on entity")
            .clone();

        test_field.field_type
    }

    fn get_field_type_helper(gql_field_str: &str) -> FieldType {
        get_field_type_helper_with_additional(gql_field_str, vec![])
    }

    #[test]
    fn gql_enum_type_to_pgprimitive() {
        let name = String::from("TestEnum");
        let test_enum =
            GraphQLEnum::new(name.clone(), vec!["TEST_VALUE".to_string()], None).unwrap();
        let field_type =
            get_field_type_helper_with_additional("TestEnum!", vec![test_enum.clone()]);
        let schema = Schema::new(vec![], vec![test_enum]).unwrap();
        let pg_primitive = field_type
            .to_user_defined_field_type()
            .to_underlying_postgres_primitive(&schema)
            .expect("unable to get postgres primitive");
        assert_eq!(pg_primitive, PGPrimitive::Enum("TestEnum".to_string()));
    }

    #[test]
    fn gql_single_not_null_array_to_pgprimitive() {
        let gql_type = "[String!]!";
        let field_type = get_field_type_helper(gql_type);
        let empty_schema = Schema::empty();
        let pg_primitive = field_type
            .to_user_defined_field_type()
            .to_underlying_postgres_primitive(&empty_schema)
            .expect("unable to get postgres primitive");
        assert_eq!(pg_primitive, PGPrimitive::String);
        assert!(field_type.to_user_defined_field_type().is_array());
    }

    #[test]
    fn gql_multi_not_null_array_to_pgprimitive() {
        let gql_type = "[[Int!]!]!";
        let field_type = get_field_type_helper(gql_type);
        let empty_schema = Schema::empty();
        let pg_primitive = field_type
            .to_user_defined_field_type()
            .to_underlying_postgres_primitive(&empty_schema)
            .expect("unable to get postgres primitive");
        assert_eq!(pg_primitive, PGPrimitive::Int32);
        assert!(field_type.to_user_defined_field_type().is_array());
    }

    #[test]
    #[should_panic]
    fn gql_single_nullable_array_to_pgprimitive_should_panic() {
        let gql_type = "[Int]!"; // Nested lists need to be not nullable
        let field_type = get_field_type_helper(gql_type);
        let empty_schema = Schema::empty();
        let _pg_primitive = field_type
            .to_user_defined_field_type()
            .to_underlying_postgres_primitive(&empty_schema)
            .expect("should panic due to validation error");
    }

    #[test]
    #[should_panic]
    fn gql_multi_nullable_array_to_pgprimitive_should_panic() {
        let gql_type = "[[Int!]]!"; // Nested lists need to be not nullable
        let field_type = get_field_type_helper(gql_type);
        let empty_schema = Schema::empty();
        let _pg_primitive = field_type
            .to_user_defined_field_type()
            .to_underlying_postgres_primitive(&empty_schema)
            .expect("should panic due to validation error");
    }

    #[test]
    fn test_nullability_to_string() {
        use UserDefinedFieldType::{ListType, NonNullType, Single};
        let scalar = NonNullType(Box::new(ListType(Box::new(Single(GqlScalar::Int)))));

        let expected_output = "[Int]!".to_string();

        assert_eq!(scalar.to_string(), expected_output);
    }

    #[test]
    fn gql_type_to_rescript_nullable() {
        let field_type = get_field_type_helper("Int");

        let empty_schema = Schema::empty();
        let rescript_type = field_type.to_rescript_type(&empty_schema).unwrap();
        assert_eq!("option<int>".to_string(), rescript_type.to_string());
    }

    #[test]
    #[ignore = "We don't support list types with nullable scalars due to postgres limitations"]
    fn gql_type_to_rescript_array_nullable_string() {
        let field_type = get_field_type_helper("[String]!");

        let empty_schema = Schema::empty();
        let rescript_type = field_type.to_rescript_type(&empty_schema).unwrap();
        assert_eq!(
            "array<option<string>>".to_string(),
            rescript_type.to_string()
        );
    }

    #[test]
    fn test_get_postgres_field_basic() {
        let schema_str = r#"
type TestEntity {
  id: ID!
  name: String! @index
}
        "#;
        let gql_doc = setup_document(schema_str).unwrap();
        let schema =
            Schema::from_document(gql_doc, DefaultChainScope::CrossChain, DEFAULT_SCHEMA_PATH)
                .unwrap();
        let entity = schema.entities.get("TestEntity").unwrap();
        let field = entity.get_field("name").unwrap();
        let pg_field = field
            .get_postgres_field(&schema, entity)
            .expect("Failed to get postgres field")
            .unwrap();

        assert_eq!(pg_field.field_name, "name");
        assert_eq!(pg_field.field_type, PGPrimitive::String);
        assert!(pg_field.is_index);
        assert!(!pg_field.is_array);
        assert!(!pg_field.is_nullable);
        assert_eq!(pg_field.linked_entity, None);
    }

    #[test]
    fn test_get_postgres_field_with_linked_entity() {
        let schema_str = r#"
type TestEntity {
  id: ID!
  relatedEntity: RelatedEntity!
  numericRelated: NumericEntity!
}

type RelatedEntity {
  id: ID!
}

type NumericEntity {
  id: Int!
}
        "#;
        let gql_doc = setup_document(schema_str).unwrap();
        let schema =
            Schema::from_document(gql_doc, DefaultChainScope::CrossChain, DEFAULT_SCHEMA_PATH)
                .unwrap();
        let entity = schema.entities.get("TestEntity").unwrap();

        // A foreign key adopts the referenced entity's id type. A String-id
        // relation stays String, while an Int-id relation becomes Int32 — both
        // still carry `linked_entity` for the `_id` naming and Hasura relation.
        let field = entity.get_field("relatedEntity").unwrap();
        let pg_field = field
            .get_postgres_field(&schema, entity)
            .expect("Failed to get postgres field")
            .unwrap();

        assert_eq!(pg_field.field_name, "relatedEntity");
        assert_eq!(pg_field.field_type, PGPrimitive::String);
        assert!(!pg_field.is_index);
        assert!(!pg_field.is_array);
        assert!(!pg_field.is_nullable);
        assert_eq!(pg_field.linked_entity, Some("RelatedEntity".to_string()));

        let numeric_field = entity.get_field("numericRelated").unwrap();
        let numeric_pg_field = numeric_field
            .get_postgres_field(&schema, entity)
            .expect("Failed to get postgres field")
            .unwrap();

        assert_eq!(numeric_pg_field.field_type, PGPrimitive::Int32);
        assert_eq!(
            numeric_pg_field.linked_entity,
            Some("NumericEntity".to_string())
        );
    }

    #[test]
    fn test_get_postgres_field_array_type() {
        let schema_str = r#"
type TestEntity {
  id: ID!
  tags: [String!]!
}
        "#;
        let gql_doc = setup_document(schema_str).unwrap();
        let schema =
            Schema::from_document(gql_doc, DefaultChainScope::CrossChain, DEFAULT_SCHEMA_PATH)
                .unwrap();
        let entity = schema.entities.get("TestEntity").unwrap();
        let field = entity.get_field("tags").unwrap();
        let pg_field = field
            .get_postgres_field(&schema, entity)
            .expect("Failed to get postgres field")
            .unwrap();

        assert_eq!(pg_field.field_name, "tags");
        assert_eq!(pg_field.field_type, PGPrimitive::String);
        assert!(!pg_field.is_index);
        assert!(pg_field.is_array);
        assert!(!pg_field.is_nullable);
        assert_eq!(pg_field.linked_entity, None);
    }

    #[test]
    fn test_get_postgres_field_enum_type() {
        let schema_str = r#"
enum Status {
  ACTIVE
  INACTIVE
}

type TestEntity {
  id: ID!
  status: Status!
}
        "#;
        let gql_doc = setup_document(schema_str).unwrap();
        let schema =
            Schema::from_document(gql_doc, DefaultChainScope::CrossChain, DEFAULT_SCHEMA_PATH)
                .unwrap();
        let entity = schema.entities.get("TestEntity").unwrap();
        let field = entity.get_field("status").unwrap();
        let pg_field = field
            .get_postgres_field(&schema, entity)
            .expect("Failed to get postgres field")
            .unwrap();

        assert_eq!(pg_field.field_name, "status");
        assert_eq!(pg_field.field_type, PGPrimitive::Enum("Status".to_string()));
        assert!(!pg_field.is_index);
        assert!(!pg_field.is_array);
        assert!(!pg_field.is_nullable);
        assert_eq!(pg_field.linked_entity, None);
    }

    #[test]
    fn rejects_entities_that_collide_when_capitalized() {
        let schema_str = r#"
type user { id: ID! }
type User { id: ID! }
        "#;
        let err = Schema::from_string(schema_str, DefaultChainScope::CrossChain)
            .expect_err("expected a capitalized entity-name collision error");
        let message = format!("{err:#}");
        assert!(
            message.contains("collide when capitalized")
                && message.contains("User (from User, user)"),
            "unexpected error: {message}"
        );
    }

    // Hasura matches the deriving entity's `id` against the derived column, so a
    // scalar derived-from field has to hold the same kind of id.
    #[test]
    fn rejects_derived_from_scalar_that_mismatches_the_deriving_entity_id() {
        let schema_str = r#"
type Parent {
  id: ID!
  children: [Child!]! @derivedFrom(field: "parentId")
}
type Child {
  id: ID!
  parentId: Int!
}
        "#;
        let err = Schema::from_string(schema_str, DefaultChainScope::CrossChain)
            .expect_err("expected a derivedFrom id-type mismatch error");
        let message = format!("{err:#}");
        assert!(
            message.contains("Derived field 'parentId' on entity 'Child'")
                && message.contains("matched against the id of 'Parent'"),
            "unexpected error: {message}"
        );
    }

    #[test]
    fn allows_derived_from_scalars_matching_the_deriving_entity_id() {
        // Int id derived from an Int column, BigInt id from a BigInt column
        // (precision only sets the width), and a String id from an `ID` column —
        // `ID` and `String` share a text column, so they stay interchangeable.
        let schema_str = r#"
type NumericParent {
  id: Int!
  children: [NumericChild!]! @derivedFrom(field: "parentId")
}
type NumericChild {
  id: ID!
  parentId: Int!
}

type BigParent {
  id: BigInt!
  children: [BigChild!]! @derivedFrom(field: "parentId")
}
type BigChild {
  id: ID!
  parentId: BigInt! @config(precision: 20)
}

type StringParent {
  id: String!
  children: [StringChild!]! @derivedFrom(field: "parentId")
}
type StringChild {
  id: ID!
  parentId: ID!
}
        "#;
        let schema = Schema::from_string(schema_str, DefaultChainScope::CrossChain).unwrap();
        assert_eq!(schema.entities.len(), 6);
    }

    // A relation back to the deriving entity stores that entity's id, so it
    // matches by construction whatever the id scalar is.
    #[test]
    fn allows_derived_from_object_relationship_for_a_numeric_id() {
        let schema_str = r#"
type NumericParent {
  id: Int!
  children: [NumericChild!]! @derivedFrom(field: "parent")
}
type NumericChild {
  id: ID!
  parent: NumericParent!
}
        "#;
        let schema = Schema::from_string(schema_str, DefaultChainScope::CrossChain).unwrap();
        assert_eq!(schema.entities.len(), 2);
    }

    #[test]
    fn allows_entities_that_are_unique_when_capitalized() {
        let schema_str = r#"
type user { id: ID! }
type post { id: ID! }
        "#;
        let schema = Schema::from_string(schema_str, DefaultChainScope::CrossChain).unwrap();
        assert_eq!(schema.entities.len(), 2);
    }

    #[test]
    fn test_decimal_precision_config_happy_path() {
        let schema_str = r#"
    type Entity {
        id: ID!
        exampleBigInt: BigInt @config(precision: 76)
        exampleBigIntRequired: BigInt! @config(precision: 77)
        exampleBigIntArray: [BigInt!] @config(precision: 78)
        exampleBigIntArrayRequired: [BigInt!]! @config(precision: 79)
        exampleBigDecimal: BigDecimal @config(precision: 80, scale: 5)
        exampleBigDecimalRequired: BigDecimal! @config(precision: 81, scale: 5)
        exampleBigDecimalArray: [BigDecimal!] @config(precision: 82, scale: 5)
        exampleBigDecimalArrayRequired: [BigDecimal!]! @config(precision: 83, scale: 5)
        exampleBigDecimalOtherOrder: BigDecimal! @config(scale: 6, precision: 84)
    }
    "#;

        let gql_doc = setup_document(schema_str).expect("Failed to parse schema");
        let schema =
            Schema::from_document(gql_doc, DefaultChainScope::CrossChain, DEFAULT_SCHEMA_PATH)
                .expect("Failed to create schema");

        // Verify that the schema contains the entity and fields as expected
        let entity = schema.entities.get("Entity").expect("Entity not found");

        // Helper function -  tests that the types of each field is what we expect
        fn check_field_type(
            field: &Field,
            expected_scalar: &str, // "BigInt" or "BigDecimal"
            expected_precision: Option<u32>,
            expected_scale: Option<u32>,
            is_required: bool,
            is_array: bool,
        ) {
            match &field.field_type {
                FieldType::RegularField { field_type, .. } => {
                    //  In this test, we strip this type from the outside to the inside like an onion and check that each layer is correct.
                    let mut current_type = field_type;

                    // Handle non-null types
                    if is_required {
                        match current_type {
                            UserDefinedFieldType::NonNullType(inner) => {
                                current_type = inner.as_ref();
                            }
                            _ => panic!("Field '{}' is expected to be non-null", field.name),
                        }
                    } else if matches!(current_type, UserDefinedFieldType::NonNullType(_)) {
                        panic!("Field '{}' should be nullable", field.name);
                    }

                    // Handle array types
                    if is_array {
                        match current_type {
                            UserDefinedFieldType::ListType(inner) => {
                                current_type = inner.as_ref();
                            }
                            _ => panic!("Field '{}' is expected to be an array", field.name),
                        }
                        // Array elements should be non-null (e.g., [Type!])
                        match current_type {
                            UserDefinedFieldType::NonNullType(inner) => {
                                current_type = inner.as_ref();
                            }
                            _ => panic!(
                                "Array elements of field '{}' are expected to be non-null",
                                field.name
                            ),
                        }
                    } else if matches!(current_type, UserDefinedFieldType::ListType(_)) {
                        panic!("Field '{}' should not be an array", field.name);
                    }

                    // Check the scalar type and precision/scale
                    match current_type {
                        UserDefinedFieldType::Single(scalar) => match (scalar, expected_scalar) {
                            (GqlScalar::BigInt(Some(precision)), "BigInt") => {
                                if let Some(expected_precision) = expected_precision {
                                    assert_eq!(
                                        *precision, expected_precision,
                                        "Field '{}' has precision {}, expected {}",
                                        field.name, precision, expected_precision
                                    );
                                } else {
                                    panic!("Expected precision for BigInt field '{}'", field.name);
                                }
                            }
                            (GqlScalar::BigDecimal(Some((precision, scale))), "BigDecimal") => {
                                if let (Some(expected_precision), Some(expected_scale)) =
                                    (expected_precision, expected_scale)
                                {
                                    assert_eq!(
                                        (*precision, *scale),
                                        (expected_precision, expected_scale),
                                        "Field '{}' has precision {}, scale {}, expected \
                                         precision {}, scale {}",
                                        field.name,
                                        precision,
                                        scale,
                                        expected_precision,
                                        expected_scale
                                    );
                                } else {
                                    panic!(
                                        "Expected precision and scale for BigDecimal field '{}'",
                                        field.name
                                    );
                                }
                            }
                            _ => panic!(
                                "Field '{}' has unexpected scalar type or missing precision/scale",
                                field.name
                            ),
                        },
                        _ => panic!("Field '{}' has unexpected field type", field.name),
                    }
                }
                _ => panic!("Field '{}' is not a regular field", field.name),
            }
        }

        // Now use the helper function to test all fields

        // BigInt fields
        check_field_type(
            entity.get_field("exampleBigInt").expect("Field not found"),
            "BigInt",
            Some(76),
            None,
            false, // is_required
            false, // is_array
        );

        check_field_type(
            entity
                .get_field("exampleBigIntRequired")
                .expect("Field not found"),
            "BigInt",
            Some(77),
            None,
            true,  // is_required
            false, // is_array
        );

        check_field_type(
            entity
                .get_field("exampleBigIntArray")
                .expect("Field not found"),
            "BigInt",
            Some(78),
            None,
            false, // is_required
            true,  // is_array
        );

        check_field_type(
            entity
                .get_field("exampleBigIntArrayRequired")
                .expect("Field not found"),
            "BigInt",
            Some(79),
            None,
            true, // is_required
            true, // is_array
        );

        // BigDecimal fields
        check_field_type(
            entity
                .get_field("exampleBigDecimal")
                .expect("Field not found"),
            "BigDecimal",
            Some(80),
            Some(5),
            false, // is_required
            false, // is_array
        );

        check_field_type(
            entity
                .get_field("exampleBigDecimalRequired")
                .expect("Field not found"),
            "BigDecimal",
            Some(81),
            Some(5),
            true,  // is_required
            false, // is_array
        );

        check_field_type(
            entity
                .get_field("exampleBigDecimalArray")
                .expect("Field not found"),
            "BigDecimal",
            Some(82),
            Some(5),
            false, // is_required
            true,  // is_array
        );

        check_field_type(
            entity
                .get_field("exampleBigDecimalArrayRequired")
                .expect("Field not found"),
            "BigDecimal",
            Some(83),
            Some(5),
            true, // is_required
            true, // is_array
        );

        // exampleBigDecimalOtherOrder
        check_field_type(
            entity
                .get_field("exampleBigDecimalOtherOrder")
                .expect("Field not found"),
            "BigDecimal",
            Some(84),
            Some(6),
            true,  // is_required
            false, // is_array
        );
    }

    #[test]
    fn test_fields_preserve_schema_order() {
        let schema_str = r#"
type TestEntity {
  id: ID!
  zebra: String!
  apple: String!
  mango: String!
}
        "#;
        let gql_doc = setup_document(schema_str).unwrap();
        let schema =
            Schema::from_document(gql_doc, DefaultChainScope::CrossChain, DEFAULT_SCHEMA_PATH)
                .unwrap();
        let entity = schema.entities.get("TestEntity").unwrap();

        let field_names: Vec<&str> = entity
            .get_fields()
            .iter()
            .map(|f| f.name.as_str())
            .collect();
        assert_eq!(field_names, vec!["id", "zebra", "apple", "mango"]);
    }

    #[test]
    fn test_fields_preserve_schema_order_complex() {
        let schema_str = r#"
type TestEntity {
  id: ID!
  zField: String!
  aField: Int!
  mField: Boolean!
  bField: BigInt!
}

type OtherEntity {
  id: ID!
  lastField: String!
  firstField: String!
}
        "#;
        let gql_doc = setup_document(schema_str).unwrap();
        let schema =
            Schema::from_document(gql_doc, DefaultChainScope::CrossChain, DEFAULT_SCHEMA_PATH)
                .unwrap();

        let test_entity = schema.entities.get("TestEntity").unwrap();
        let test_field_names: Vec<&str> = test_entity
            .get_fields()
            .iter()
            .map(|f| f.name.as_str())
            .collect();
        assert_eq!(
            test_field_names,
            vec!["id", "zField", "aField", "mField", "bField"]
        );

        let other_entity = schema.entities.get("OtherEntity").unwrap();
        let other_field_names: Vec<&str> = other_entity
            .get_fields()
            .iter()
            .map(|f| f.name.as_str())
            .collect();
        assert_eq!(other_field_names, vec!["id", "lastField", "firstField"]);
    }

    #[test]
    fn test_get_field_lookup() {
        let schema_str = r#"
type TestEntity {
  id: ID!
  name: String!
  value: Int!
}
        "#;
        let gql_doc = setup_document(schema_str).unwrap();
        let schema =
            Schema::from_document(gql_doc, DefaultChainScope::CrossChain, DEFAULT_SCHEMA_PATH)
                .unwrap();
        let entity = schema.entities.get("TestEntity").unwrap();

        // Test existing fields
        assert!(entity.get_field("id").is_some());
        assert!(entity.get_field("name").is_some());
        assert!(entity.get_field("value").is_some());

        // Test non-existing field
        assert!(entity.get_field("nonexistent").is_none());

        // Verify field content
        let name_field = entity.get_field("name").unwrap();
        assert_eq!(name_field.name, "name");
    }

    #[test]
    fn test_descriptions_extracted_from_schema() {
        let schema_str = r#"
"A user of the protocol"
type User {
  "The user's unique identifier (Ethereum address)"
  id: ID!
  "Total amount the user has staked"
  balance: BigInt!
  "Tokens owned by this user"
  tokens: [Token!]! @derivedFrom(field: "owner")
}

"An NFT token"
type Token {
  id: ID!
  owner: User!
}

"Status of an entity"
enum Status {
  ACTIVE
  INACTIVE
}
        "#;
        let gql_doc = setup_document(schema_str).unwrap();
        let schema =
            Schema::from_document(gql_doc, DefaultChainScope::CrossChain, DEFAULT_SCHEMA_PATH)
                .unwrap();

        let user = schema.entities.get("User").unwrap();
        assert_eq!(user.description.as_deref(), Some("A user of the protocol"));

        let id_field = user.get_field("id").unwrap();
        assert_eq!(
            id_field.description.as_deref(),
            Some("The user's unique identifier (Ethereum address)")
        );

        let balance_field = user.get_field("balance").unwrap();
        assert_eq!(
            balance_field.description.as_deref(),
            Some("Total amount the user has staked")
        );

        let tokens_field = user.get_field("tokens").unwrap();
        assert_eq!(
            tokens_field.description.as_deref(),
            Some("Tokens owned by this user")
        );

        let token = schema.entities.get("Token").unwrap();
        assert_eq!(token.description.as_deref(), Some("An NFT token"));
        assert_eq!(token.get_field("owner").unwrap().description, None);

        let status = schema.enums.get("Status").unwrap();
        assert_eq!(status.description.as_deref(), Some("Status of an entity"));
    }

    // --- @storage directive (per-entity storage routing) ---

    #[test]
    fn storage_directive_omitted_leaves_fields_none() {
        let schema_str = r#"
type TestEntity { id: ID! }
        "#;
        let entity = Entity::from_object(
            &get_first_entity_from_string(schema_str),
            DefaultChainScope::CrossChain,
            DEFAULT_SCHEMA_PATH,
        )
        .unwrap();
        assert_eq!(
            (
                entity.postgres,
                entity.clickhouse.clone(),
                entity.has_storage_directive()
            ),
            (None, None, false)
        );
    }

    #[test]
    fn storage_directive_postgres_only() {
        let schema_str = r#"
type TestEntity @storage(postgres: true) { id: ID! }
        "#;
        let entity = Entity::from_object(
            &get_first_entity_from_string(schema_str),
            DefaultChainScope::CrossChain,
            DEFAULT_SCHEMA_PATH,
        )
        .unwrap();
        assert_eq!(
            (
                entity.postgres,
                entity.clickhouse.clone(),
                entity.has_storage_directive()
            ),
            (Some(true), None, true)
        );
    }

    #[test]
    fn storage_directive_both_backends() {
        let schema_str = r#"
type TestEntity @storage(postgres: true, clickhouse: true) { id: ID! }
        "#;
        let entity = Entity::from_object(
            &get_first_entity_from_string(schema_str),
            DefaultChainScope::CrossChain,
            DEFAULT_SCHEMA_PATH,
        )
        .unwrap();
        assert_eq!(
            (entity.postgres, entity.clickhouse),
            (Some(true), Some(ClickHouseEntityStorage::Enabled(true)))
        );
    }

    // --- @storage(clickhouse: {...}) table options ---
    // The full partitionBy/orderBy/ttl options object is exercised end-to-end
    // (YAML + schema -> parser -> Config.res -> DDL) in `ClickHouse_test.res`.

    #[test]
    fn storage_directive_clickhouse_options_are_each_optional() {
        let schema_str = r#"
type TestEntity @storage(clickhouse: {partitionBy: "toYYYYMM(timestamp)"}) {
  id: ID!
  timestamp: Timestamp!
}
        "#;
        let entity = Entity::from_object(
            &get_first_entity_from_string(schema_str),
            DefaultChainScope::CrossChain,
            DEFAULT_SCHEMA_PATH,
        )
        .unwrap();
        assert_eq!(
            entity.clickhouse,
            Some(ClickHouseEntityStorage::Options(ClickHouseTableOptions {
                partition_by: Some("toYYYYMM(timestamp)".to_string()),
                order_by: None,
                ttl: None,
                skipping_indexes: None,
            }))
        );
    }

    #[test]
    fn storage_directive_clickhouse_empty_options_counts_as_enabled() {
        let schema_str = r#"
type TestEntity @storage(clickhouse: {}) { id: ID! }
        "#;
        let entity = Entity::from_object(
            &get_first_entity_from_string(schema_str),
            DefaultChainScope::CrossChain,
            DEFAULT_SCHEMA_PATH,
        )
        .unwrap();
        let clickhouse = entity.clickhouse.unwrap();
        // Empty options normalize to the boolean form so they don't diff a
        // config persisted as `clickhouse: true`.
        assert_eq!(
            (clickhouse.clone(), clickhouse.is_enabled(), entity.postgres),
            (ClickHouseEntityStorage::Enabled(true), true, None)
        );
    }

    #[test]
    fn storage_directive_clickhouse_options_with_linked_entity_order_by() {
        let schema_str = r#"
type TestEntity @storage(clickhouse: {orderBy: ["token", "timestamp"]}) {
  id: ID!
  token: Token!
  timestamp: Timestamp!
}
type Token { id: ID! }
        "#;
        let entity = Entity::from_object(
            &get_first_entity_from_string(schema_str),
            DefaultChainScope::CrossChain,
            DEFAULT_SCHEMA_PATH,
        )
        .unwrap();
        assert_eq!(
            entity.clickhouse,
            Some(ClickHouseEntityStorage::Options(ClickHouseTableOptions {
                partition_by: None,
                order_by: Some(vec![
                    EntityColumn::Declared("token".to_string()),
                    EntityColumn::Declared("timestamp".to_string()),
                ]),
                ttl: None,
                skipping_indexes: None,
            }))
        );
    }

    #[test]
    fn storage_directive_clickhouse_skipping_indexes() {
        let schema_str = r#"
type TestEntity @storage(clickhouse: {skippingIndexes: [
  {name: "idx_from", expr: "fromAddress", type: "bloom_filter(0.01)", granularity: 4},
  {name: "idx_amount", expr: "amount", type: "minmax"}
]}) {
  id: ID!
  fromAddress: String!
  amount: BigInt!
}
        "#;
        let entity = Entity::from_object(
            &get_first_entity_from_string(schema_str),
            DefaultChainScope::CrossChain,
            DEFAULT_SCHEMA_PATH,
        )
        .unwrap();
        assert_eq!(
            entity.clickhouse,
            Some(ClickHouseEntityStorage::Options(ClickHouseTableOptions {
                skipping_indexes: Some(vec![
                    ClickHouseSkippingIndex {
                        name: "idx_from".to_string(),
                        expr: "fromAddress".to_string(),
                        index_type: "bloom_filter(0.01)".to_string(),
                        granularity: Some(4),
                    },
                    ClickHouseSkippingIndex {
                        name: "idx_amount".to_string(),
                        expr: "amount".to_string(),
                        index_type: "minmax".to_string(),
                        granularity: None,
                    },
                ]),
                ..ClickHouseTableOptions::default()
            }))
        );
    }

    #[test]
    fn storage_directive_clickhouse_skipping_indexes_errors() {
        let assert_error_contains = |schema_str: &str, expected: &str| {
            let err = Entity::from_object(
                &get_first_entity_from_string(schema_str),
                DefaultChainScope::CrossChain,
                DEFAULT_SCHEMA_PATH,
            )
            .expect_err(&format!("expected error containing '{expected}'"));
            let message = format!("{err:#}");
            assert!(
                message.contains(expected),
                "expected error containing '{expected}', got: {message}"
            );
        };

        assert_error_contains(
            r#"type TestEntity @storage(clickhouse: {skippingIndexes: []}) { id: ID! }"#,
            "`clickhouse.skippingIndexes` must be a non-empty list",
        );
        assert_error_contains(
            r#"type TestEntity @storage(clickhouse: {skippingIndexes: ["idx"]}) { id: ID! }"#,
            "`clickhouse.skippingIndexes` must be a list of index objects",
        );
        assert_error_contains(
            r#"type TestEntity @storage(clickhouse: {skippingIndexes: [{name: "idx", type: "minmax"}]}) { id: ID! }"#,
            "missing required field `expr`",
        );
        assert_error_contains(
            r#"type TestEntity @storage(clickhouse: {skippingIndexes: [{name: "idx", expr: "", type: "minmax"}]}) { id: ID! }"#,
            "`expr` must be a non-empty string",
        );
        assert_error_contains(
            r#"type TestEntity @storage(clickhouse: {skippingIndexes: [{name: "idx", expr: "id", type: "minmax", size: 1}]}) { id: ID! }"#,
            "Unknown `clickhouse.skippingIndexes` entry field `size`",
        );
        assert_error_contains(
            r#"type TestEntity @storage(clickhouse: {skippingIndexes: [{name: "idx", expr: "id", type: "minmax", granularity: 0}]}) { id: ID! }"#,
            "`granularity` must be a positive integer",
        );
        assert_error_contains(
            r#"type TestEntity @storage(clickhouse: {skippingIndexes: [{name: "bad name", expr: "id", type: "minmax"}]}) { id: ID! }"#,
            "must contain only alphanumeric characters and underscores",
        );
        assert_error_contains(
            r#"type TestEntity @storage(clickhouse: {skippingIndexes: [
  {name: "idx", expr: "id", type: "minmax"},
  {name: "idx", expr: "id", type: "set(100)"}
]}) { id: ID! }"#,
            "lists index name `idx` more than once",
        );
    }

    // --- @internal directive (hide entity from the GraphQL API) ---

    #[test]
    fn internal_directive_omitted_defaults_to_false() {
        let schema_str = r#"
type TestEntity { id: ID! }
        "#;
        let entity = Entity::from_object(
            &get_first_entity_from_string(schema_str),
            DefaultChainScope::CrossChain,
            DEFAULT_SCHEMA_PATH,
        )
        .unwrap();
        assert_eq!(entity.internal, false);
    }

    #[test]
    fn internal_directive_sets_flag() {
        let schema_str = r#"
type TestEntity @internal { id: ID! }
        "#;
        let entity = Entity::from_object(
            &get_first_entity_from_string(schema_str),
            DefaultChainScope::CrossChain,
            DEFAULT_SCHEMA_PATH,
        )
        .unwrap();
        assert_eq!(entity.internal, true);
    }

    #[test]
    fn internal_directive_errors() {
        let assert_error_contains = |schema_str: &str, expected: &str| {
            let err = Entity::from_object(
                &get_first_entity_from_string(schema_str),
                DefaultChainScope::CrossChain,
                DEFAULT_SCHEMA_PATH,
            )
            .expect_err(&format!("expected error containing '{expected}'"));
            let message = format!("{err:#}");
            assert!(
                message.contains(expected),
                "expected error containing '{expected}', got: {message}"
            );
        };

        assert_error_contains(
            r#"type TestEntity @internal(foo: true) { id: ID! }"#,
            "Invalid @internal directive on `TestEntity`. It takes no arguments, but got `foo`.",
        );
        assert_error_contains(
            r#"type TestEntity @internal @internal { id: ID! }"#,
            "Only one @internal directive is allowed per entity.",
        );
    }

    #[test]
    fn storage_directive_clickhouse_options_errors() {
        let assert_error_contains = |schema_str: &str, expected: &str| {
            let err = Entity::from_object(
                &get_first_entity_from_string(schema_str),
                DefaultChainScope::CrossChain,
                DEFAULT_SCHEMA_PATH,
            )
            .expect_err(&format!("expected error containing '{expected}'"));
            let message = format!("{err:#}");
            assert!(
                message.contains(expected),
                "expected error containing '{expected}', got: {message}"
            );
        };

        assert_error_contains(
            r#"type TestEntity @storage(clickhouse: {unknownOption: "x"}) { id: ID! }"#,
            "Unknown `clickhouse` option `unknownOption`",
        );
        assert_error_contains(
            r#"type TestEntity @storage(clickhouse: {partitionBy: ""}) { id: ID! }"#,
            "`clickhouse.partitionBy` must be a non-empty string",
        );
        assert_error_contains(
            r#"type TestEntity @storage(clickhouse: {ttl: true}) { id: ID! }"#,
            "`clickhouse.ttl` must be a non-empty string",
        );
        assert_error_contains(
            r#"type TestEntity @storage(clickhouse: {orderBy: []}) { id: ID! }"#,
            "`clickhouse.orderBy` must be a non-empty list",
        );
        assert_error_contains(
            r#"type TestEntity @storage(clickhouse: {orderBy: "timestamp"}) { id: ID! }"#,
            "`clickhouse.orderBy` must be a non-empty list",
        );
        assert_error_contains(
            r#"type TestEntity @storage(clickhouse: 42) { id: ID! }"#,
            "must be a boolean or a table options object",
        );
        assert_error_contains(
            r#"type TestEntity @storage(postgres: {default: true}) { id: ID! }"#,
            "`postgres` must be a boolean",
        );
    }
}
