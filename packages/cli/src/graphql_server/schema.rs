use anyhow::anyhow;
use async_graphql::dynamic::{
    Enum, Field, FieldFuture, FieldValue, InputObject, InputValue, Object, Schema, SchemaBuilder,
    TypeRef,
};
use async_graphql::Value;
use serde_json::Value as JsonValue;
use sqlx::postgres::PgPool;
use sqlx::Row;
use std::collections::HashMap;
use std::sync::Arc;

use crate::config_parsing::entity_parsing::{
    Entity, FieldType, GqlScalar, GraphQLEnum, Schema as ParsedSchema,
};

/// Shared context available to all resolvers.
pub struct ServerContext {
    pub pool: PgPool,
    pub pg_schema: String,
    /// entity_name -> list of column names (non-derived fields only)
    pub entity_columns: HashMap<String, Vec<String>>,
    /// entity_name -> { field_name -> linked_entity_name } for FK relationships
    pub entity_relations: HashMap<String, HashMap<String, String>>,
    /// entity_name -> list of DerivedRelation for @derivedFrom fields
    #[allow(dead_code)]
    pub entity_derived: HashMap<String, Vec<DerivedRelation>>,
    /// The parsed schema for type lookups
    #[allow(dead_code)]
    pub parsed_schema: ParsedSchema,
}

#[derive(Clone)]
#[allow(dead_code)]
pub struct DerivedRelation {
    pub field_name: String,
    pub target_entity: String,
    pub target_field: String,
}

/// Build an async-graphql dynamic schema from the parsed entity definitions.
pub fn build_schema(
    parsed_schema: &ParsedSchema,
    pool: PgPool,
    pg_schema: String,
) -> anyhow::Result<Schema> {
    let mut entity_columns: HashMap<String, Vec<String>> = HashMap::new();
    let mut entity_relations: HashMap<String, HashMap<String, String>> = HashMap::new();
    let mut entity_derived: HashMap<String, Vec<DerivedRelation>> = HashMap::new();

    // Pre-compute metadata for each entity
    for (name, entity) in &parsed_schema.entities {
        let mut columns = Vec::new();
        let mut relations = HashMap::new();
        let mut derived = Vec::new();

        for field in &entity.fields {
            match &field.field_type {
                FieldType::DerivedFromField {
                    entity_name,
                    derived_from_field,
                } => {
                    derived.push(DerivedRelation {
                        field_name: field.name.clone(),
                        target_entity: entity_name.clone(),
                        target_field: derived_from_field.clone(),
                    });
                }
                FieldType::RegularField { field_type, .. } => {
                    let scalar = field_type.get_underlying_scalar();
                    if let GqlScalar::Custom(ref custom_name) = scalar {
                        if parsed_schema.entities.contains_key(custom_name) {
                            // Entity FK: stored as {field_name}_id in DB
                            columns.push(format!("{}_id", field.name));
                            relations.insert(field.name.clone(), custom_name.clone());
                        } else {
                            // Enum field: stored directly
                            columns.push(field.name.clone());
                        }
                    } else {
                        columns.push(field.name.clone());
                    }
                }
            }
        }

        entity_columns.insert(name.clone(), columns);
        entity_relations.insert(name.clone(), relations);
        entity_derived.insert(name.clone(), derived);
    }

    let ctx = Arc::new(ServerContext {
        pool,
        pg_schema,
        entity_columns,
        entity_relations,
        entity_derived,
        parsed_schema: parsed_schema.clone(),
    });

    let mut builder = Schema::build("Query", None, None);

    // Register enum types
    for (_enum_name, gql_enum) in &parsed_schema.enums {
        builder = register_enum(builder, gql_enum);
    }

    // Register entity object types
    for (_entity_name, entity) in &parsed_schema.entities {
        builder = register_entity_type(builder, entity, parsed_schema);
    }

    // Register ordering and where input types for each entity
    for (_entity_name, entity) in &parsed_schema.entities {
        builder = register_order_by_enum(builder, entity);
        builder = register_where_input(builder, entity, parsed_schema);
    }

    // Build the root Query type
    let mut query = Object::new("Query");
    for (_entity_name, entity) in &parsed_schema.entities {
        query = register_entity_queries(query, entity, parsed_schema);
    }

    builder = builder.data(ctx).register(query);

    builder
        .finish()
        .map_err(|e| anyhow!("Failed to build GraphQL schema: {}", e))
}

/// Map a GqlScalar to async-graphql TypeRef name.
fn scalar_to_type_ref(scalar: &GqlScalar) -> &'static str {
    match scalar {
        GqlScalar::ID => "ID",
        GqlScalar::String => "String",
        GqlScalar::Int => "Int",
        GqlScalar::Float => "Float",
        GqlScalar::Boolean => "Boolean",
        GqlScalar::BigInt(_) => "String",
        GqlScalar::BigDecimal(_) => "String",
        GqlScalar::Timestamp => "String",
        GqlScalar::Bytes => "String",
        GqlScalar::Json => "JSON",
        GqlScalar::Custom(name) => {
            // Leak is fine here since schema is built once at startup
            Box::leak(name.clone().into_boxed_str())
        }
    }
}

fn register_enum(builder: SchemaBuilder, gql_enum: &GraphQLEnum) -> SchemaBuilder {
    let mut e = Enum::new(&gql_enum.name);
    for val in &gql_enum.values {
        e = e.item(val);
    }
    builder.register(e)
}

fn register_entity_type(
    builder: SchemaBuilder,
    entity: &Entity,
    parsed_schema: &ParsedSchema,
) -> SchemaBuilder {
    let mut obj = Object::new(&entity.name);

    for field in &entity.fields {
        match &field.field_type {
            FieldType::DerivedFromField {
                entity_name,
                derived_from_field,
            } => {
                // @derivedFrom: resolve by querying the related entity table
                let target_entity = entity_name.clone();
                let target_field = derived_from_field.clone();
                let entity_name_owned = entity.name.clone();

                let gql_field = Field::new(
                    &field.name,
                    TypeRef::named_nn_list_nn(&target_entity),
                    move |ctx| {
                        let target_entity = target_entity.clone();
                        let target_field = target_field.clone();
                        let entity_name_owned = entity_name_owned.clone();
                        FieldFuture::new(async move {
                            let server_ctx = ctx.data::<Arc<ServerContext>>()?;
                            let parent = ctx.parent_value.try_downcast_ref::<JsonValue>()?;
                            let parent_id = parent
                                .get("id")
                                .and_then(|v| v.as_str())
                                .ok_or_else(|| async_graphql::Error::new("Missing parent id"))?;

                            // Determine the actual DB column to filter on
                            let filter_col = {
                                let rels = server_ctx.entity_relations.get(&target_entity);
                                if let Some(rels) = rels {
                                    if rels.values().any(|v| v == &entity_name_owned) {
                                        // The target field references our entity via FK
                                        format!("{}_id", target_field)
                                    } else {
                                        target_field.clone()
                                    }
                                } else {
                                    target_field.clone()
                                }
                            };

                            let cols = server_ctx
                                .entity_columns
                                .get(&target_entity)
                                .ok_or_else(|| {
                                    async_graphql::Error::new(format!(
                                        "Unknown entity {}",
                                        target_entity
                                    ))
                                })?;

                            let col_list = cols
                                .iter()
                                .map(|c| format!("\"{}\"", c))
                                .collect::<Vec<_>>()
                                .join(", ");

                            let query = format!(
                                "SELECT {} FROM \"{}\".\"{}\" WHERE \"{}\" = $1",
                                col_list,
                                server_ctx.pg_schema,
                                target_entity,
                                filter_col
                            );

                            let rows = sqlx::query(&query)
                                .bind(parent_id)
                                .fetch_all(&server_ctx.pool)
                                .await
                                .map_err(|e| {
                                    async_graphql::Error::new(format!("DB error: {}", e))
                                })?;

                            let items: Vec<FieldValue> = rows
                                .into_iter()
                                .map(|row| {
                                    let json = row_to_json(&row, cols);
                                    FieldValue::owned_any(json)
                                })
                                .collect();

                            Ok(Some(FieldValue::list(items)))
                        })
                    },
                );
                obj = obj.field(gql_field);
            }

            FieldType::RegularField { field_type, .. } => {
                let scalar = field_type.get_underlying_scalar();
                let is_nullable = field_type.is_optional();
                let is_array = field_type.is_array();

                // Check if this is an entity FK field
                if let GqlScalar::Custom(ref custom_name) = scalar {
                    if parsed_schema.entities.contains_key(custom_name) {
                        // FK relationship: resolve the related entity by loading from DB
                        let related_entity = custom_name.clone();
                        let fk_col = format!("{}_id", field.name);

                        let type_ref = if is_nullable {
                            TypeRef::named(&related_entity)
                        } else {
                            TypeRef::named_nn(&related_entity)
                        };

                        let gql_field = Field::new(&field.name, type_ref, move |ctx| {
                            let related_entity = related_entity.clone();
                            let fk_col = fk_col.clone();
                            FieldFuture::new(async move {
                                let server_ctx = ctx.data::<Arc<ServerContext>>()?;
                                let parent =
                                    ctx.parent_value.try_downcast_ref::<JsonValue>()?;

                                let fk_val = match parent.get(&fk_col) {
                                    Some(JsonValue::String(s)) => s.clone(),
                                    Some(JsonValue::Null) | None => {
                                        return Ok(None);
                                    }
                                    Some(other) => other.to_string().trim_matches('"').to_string(),
                                };

                                let cols = server_ctx
                                    .entity_columns
                                    .get(&related_entity)
                                    .ok_or_else(|| {
                                        async_graphql::Error::new(format!(
                                            "Unknown entity {}",
                                            related_entity
                                        ))
                                    })?;

                                let col_list = cols
                                    .iter()
                                    .map(|c| format!("\"{}\"", c))
                                    .collect::<Vec<_>>()
                                    .join(", ");

                                let query = format!(
                                    "SELECT {} FROM \"{}\".\"{}\" WHERE id = $1 LIMIT 1",
                                    col_list, server_ctx.pg_schema, related_entity,
                                );

                                let row = sqlx::query(&query)
                                    .bind(&fk_val)
                                    .fetch_optional(&server_ctx.pool)
                                    .await
                                    .map_err(|e| {
                                        async_graphql::Error::new(format!("DB error: {}", e))
                                    })?;

                                match row {
                                    Some(row) => {
                                        let json = row_to_json(&row, cols);
                                        Ok(Some(FieldValue::owned_any(json)))
                                    }
                                    None => Ok(None),
                                }
                            })
                        });
                        obj = obj.field(gql_field);
                        continue;
                    }
                }

                // Scalar or enum field: resolve from parent JSON
                let field_name = field.name.clone();
                let scalar_clone = scalar.clone();

                let base_type = scalar_to_type_ref(&scalar).to_string();
                let type_ref = if is_array {
                    if is_nullable {
                        TypeRef::named_list_nn(&base_type)
                    } else {
                        TypeRef::named_nn_list_nn(&base_type)
                    }
                } else if is_nullable {
                    TypeRef::named(&base_type)
                } else {
                    TypeRef::named_nn(&base_type)
                };

                let gql_field = Field::new(&field.name, type_ref, move |ctx| {
                    let field_name = field_name.clone();
                    let scalar_clone = scalar_clone.clone();
                    FieldFuture::new(async move {
                        let parent = ctx.parent_value.try_downcast_ref::<JsonValue>()?;
                        let val = parent.get(&field_name);
                        match val {
                            None | Some(JsonValue::Null) => Ok(None),
                            Some(v) => Ok(Some(json_to_field_value(v, &scalar_clone))),
                        }
                    })
                });
                obj = obj.field(gql_field);
            }
        }
    }

    builder.register(obj)
}

/// Register an `order_by` enum for Hasura-style ordering.
fn register_order_by_enum(builder: SchemaBuilder, _entity: &Entity) -> SchemaBuilder {
    // Global order_by enum (shared Hasura style)
    // Only register once — async-graphql deduplicates by name
    let e = Enum::new("order_by")
        .item("asc")
        .item("asc_nulls_first")
        .item("asc_nulls_last")
        .item("desc")
        .item("desc_nulls_first")
        .item("desc_nulls_last");
    builder.register(e)
}

/// Register a `{Entity}_order_by` input type.
fn register_where_input(
    builder: SchemaBuilder,
    entity: &Entity,
    parsed_schema: &ParsedSchema,
) -> SchemaBuilder {
    // {Entity}_order_by input
    let order_by_name = format!("{}_order_by", entity.name);
    let mut order_input = InputObject::new(&order_by_name);
    for field in &entity.fields {
        if matches!(field.field_type, FieldType::DerivedFromField { .. }) {
            continue;
        }
        let scalar = field.field_type.get_underlying_scalar();
        if let GqlScalar::Custom(ref name) = scalar {
            if parsed_schema.entities.contains_key(name) {
                continue; // Skip FK fields in order_by for MVP
            }
        }
        order_input = order_input.field(InputValue::new(&field.name, TypeRef::named("order_by")));
    }

    // {Entity}_bool_exp input (WHERE)
    let bool_exp_name = format!("{}_bool_exp", entity.name);
    let mut bool_input = InputObject::new(&bool_exp_name);
    // Logical operators
    bool_input = bool_input.field(InputValue::new(
        "_and",
        TypeRef::named_list_nn(&bool_exp_name),
    ));
    bool_input = bool_input.field(InputValue::new(
        "_or",
        TypeRef::named_list_nn(&bool_exp_name),
    ));
    bool_input = bool_input.field(InputValue::new("_not", TypeRef::named(&bool_exp_name)));

    for field in &entity.fields {
        if matches!(field.field_type, FieldType::DerivedFromField { .. }) {
            continue;
        }
        let scalar = field.field_type.get_underlying_scalar();

        // For MVP, support _eq comparison on scalar fields
        let comparison_type = match &scalar {
            GqlScalar::Custom(ref name) if parsed_schema.entities.contains_key(name) => {
                continue; // Skip FK for now
            }
            _ => scalar_to_type_ref(&scalar).to_string(),
        };

        let comp_input_name = format!("{}_comparison_exp", comparison_type);
        // Register comparison input if not already done (async-graphql deduplicates)
        // We just reference it by name

        bool_input = bool_input.field(InputValue::new(&field.name, TypeRef::named(&comp_input_name)));
    }

    let builder = builder.register(order_input).register(bool_input);

    // Register comparison input types for scalars used
    register_comparison_inputs(builder, entity, parsed_schema)
}

fn register_comparison_inputs(
    builder: SchemaBuilder,
    entity: &Entity,
    parsed_schema: &ParsedSchema,
) -> SchemaBuilder {
    let mut builder = builder;
    let mut registered = std::collections::HashSet::new();

    for field in &entity.fields {
        if matches!(field.field_type, FieldType::DerivedFromField { .. }) {
            continue;
        }
        let scalar = field.field_type.get_underlying_scalar();
        if let GqlScalar::Custom(ref name) = scalar {
            if parsed_schema.entities.contains_key(name) {
                continue;
            }
        }

        let type_name = scalar_to_type_ref(&scalar).to_string();
        let comp_name = format!("{}_comparison_exp", type_name);

        if registered.contains(&comp_name) {
            continue;
        }
        registered.insert(comp_name.clone());

        let mut comp = InputObject::new(&comp_name);
        comp = comp.field(InputValue::new("_eq", TypeRef::named(&type_name)));
        comp = comp.field(InputValue::new("_neq", TypeRef::named(&type_name)));
        comp = comp.field(InputValue::new("_gt", TypeRef::named(&type_name)));
        comp = comp.field(InputValue::new("_gte", TypeRef::named(&type_name)));
        comp = comp.field(InputValue::new("_lt", TypeRef::named(&type_name)));
        comp = comp.field(InputValue::new("_lte", TypeRef::named(&type_name)));
        comp = comp.field(InputValue::new(
            "_in",
            TypeRef::named_nn_list_nn(&type_name),
        ));
        comp = comp.field(InputValue::new("_is_null", TypeRef::named("Boolean")));

        builder = builder.register(comp);
    }

    builder
}

/// Register query fields for an entity: list query + by-pk query.
fn register_entity_queries(
    query: Object,
    entity: &Entity,
    _parsed_schema: &ParsedSchema,
) -> Object {
    let entity_name = entity.name.clone();
    let bool_exp_name = format!("{}_bool_exp", entity_name);
    let order_by_name = format!("{}_order_by", entity_name);

    // List query: {Entity}(where: ..., order_by: ..., limit: ..., offset: ...)
    let list_field = Field::new(
        &entity_name,
        TypeRef::named_nn_list_nn(&entity_name),
        {
            let entity_name = entity_name.clone();
            move |ctx| {
                let entity_name = entity_name.clone();
                FieldFuture::new(async move {
                    let server_ctx = ctx.data::<Arc<ServerContext>>()?;
                    let cols = server_ctx.entity_columns.get(&entity_name).ok_or_else(|| {
                        async_graphql::Error::new(format!("Unknown entity {}", entity_name))
                    })?;

                    let col_list = cols
                        .iter()
                        .map(|c| format!("\"{}\"", c))
                        .collect::<Vec<_>>()
                        .join(", ");

                    let mut query = format!(
                        "SELECT {} FROM \"{}\".\"{}\"",
                        col_list, server_ctx.pg_schema, entity_name
                    );

                    let mut params: Vec<String> = Vec::new();

                    // WHERE clause
                    if let Some(where_val) = ctx.args.get("where") {
                        let where_obj: JsonValue =
                            where_val.deserialize().map_err(|e| {
                                async_graphql::Error::new(format!("Invalid where: {:?}", e))
                            })?;
                        if let Some(clause) =
                            build_where_clause(&where_obj, &mut params, &entity_name, server_ctx)
                        {
                            query.push_str(&format!(" WHERE {}", clause));
                        }
                    }

                    // ORDER BY clause
                    if let Some(order_val) = ctx.args.get("order_by") {
                        let order_obj: JsonValue =
                            order_val.deserialize().map_err(|e| {
                                async_graphql::Error::new(format!("Invalid order_by: {:?}", e))
                            })?;
                        if let Some(order_clause) = build_order_clause(&order_obj) {
                            query.push_str(&format!(" ORDER BY {}", order_clause));
                        }
                    }

                    // LIMIT
                    if let Some(limit_val) = ctx.args.get("limit") {
                        let limit: i64 = limit_val.deserialize().map_err(|e| {
                            async_graphql::Error::new(format!("Invalid limit: {:?}", e))
                        })?;
                        query.push_str(&format!(" LIMIT {}", limit));
                    } else {
                        // Default limit to prevent unbounded queries
                        query.push_str(" LIMIT 100");
                    }

                    // OFFSET
                    if let Some(offset_val) = ctx.args.get("offset") {
                        let offset: i64 = offset_val.deserialize().map_err(|e| {
                            async_graphql::Error::new(format!("Invalid offset: {:?}", e))
                        })?;
                        query.push_str(&format!(" OFFSET {}", offset));
                    }

                    let mut sql_query = sqlx::query(&query);
                    for param in &params {
                        sql_query = sql_query.bind(param);
                    }

                    let rows = sql_query.fetch_all(&server_ctx.pool).await.map_err(|e| {
                        async_graphql::Error::new(format!("DB error: {}", e))
                    })?;

                    let items: Vec<FieldValue> = rows
                        .into_iter()
                        .map(|row| {
                            let json = row_to_json(&row, cols);
                            FieldValue::owned_any(json)
                        })
                        .collect();

                    Ok(Some(FieldValue::list(items)))
                })
            }
        },
    )
    .argument(InputValue::new("where", TypeRef::named(&bool_exp_name)))
    .argument(InputValue::new(
        "order_by",
        TypeRef::named_list_nn(&order_by_name),
    ))
    .argument(InputValue::new("limit", TypeRef::named("Int")))
    .argument(InputValue::new("offset", TypeRef::named("Int")));

    // By PK query: {Entity}_by_pk(id: ID!)
    let by_pk_name = format!("{}_by_pk", entity_name);
    let by_pk_field = Field::new(&by_pk_name, TypeRef::named(&entity_name), {
        let entity_name = entity_name.clone();
        move |ctx| {
            let entity_name = entity_name.clone();
            FieldFuture::new(async move {
                let server_ctx = ctx.data::<Arc<ServerContext>>()?;
                let id: String = ctx
                    .args
                    .try_get("id")
                    .map_err(|_| async_graphql::Error::new("id is required"))?
                    .deserialize()
                    .map_err(|e| async_graphql::Error::new(format!("Invalid id: {:?}", e)))?;

                let cols = server_ctx.entity_columns.get(&entity_name).ok_or_else(|| {
                    async_graphql::Error::new(format!("Unknown entity {}", entity_name))
                })?;

                let col_list = cols
                    .iter()
                    .map(|c| format!("\"{}\"", c))
                    .collect::<Vec<_>>()
                    .join(", ");

                let query = format!(
                    "SELECT {} FROM \"{}\".\"{}\" WHERE id = $1 LIMIT 1",
                    col_list, server_ctx.pg_schema, entity_name,
                );

                let row = sqlx::query(&query)
                    .bind(&id)
                    .fetch_optional(&server_ctx.pool)
                    .await
                    .map_err(|e| async_graphql::Error::new(format!("DB error: {}", e)))?;

                match row {
                    Some(row) => {
                        let json = row_to_json(&row, cols);
                        Ok(Some(FieldValue::owned_any(json)))
                    }
                    None => Ok(None),
                }
            })
        }
    })
    .argument(InputValue::new("id", TypeRef::named_nn("ID")));

    query.field(list_field).field(by_pk_field)
}

/// Convert a sqlx Row to a serde_json::Value (Object).
fn row_to_json(row: &sqlx::postgres::PgRow, columns: &[String]) -> JsonValue {
    let mut map = serde_json::Map::new();
    for col_name in columns {
        // Try to get the column value as various types
        let val: JsonValue = try_extract_column(row, col_name);
        map.insert(col_name.clone(), val);
    }
    JsonValue::Object(map)
}

fn try_extract_column(row: &sqlx::postgres::PgRow, col: &str) -> JsonValue {
    // Try text first (covers String, ID, BigInt, BigDecimal, Bytes, Timestamp, enums)
    if let Ok(v) = row.try_get::<Option<String>, _>(col) {
        return match v {
            Some(s) => JsonValue::String(s),
            None => JsonValue::Null,
        };
    }
    // Try i32
    if let Ok(v) = row.try_get::<Option<i32>, _>(col) {
        return match v {
            Some(n) => JsonValue::Number(n.into()),
            None => JsonValue::Null,
        };
    }
    // Try i64
    if let Ok(v) = row.try_get::<Option<i64>, _>(col) {
        return match v {
            Some(n) => JsonValue::Number(n.into()),
            None => JsonValue::Null,
        };
    }
    // Try f64
    if let Ok(v) = row.try_get::<Option<f64>, _>(col) {
        return match v {
            Some(n) => serde_json::Number::from_f64(n)
                .map(JsonValue::Number)
                .unwrap_or(JsonValue::Null),
            None => JsonValue::Null,
        };
    }
    // Try bool
    if let Ok(v) = row.try_get::<Option<bool>, _>(col) {
        return match v {
            Some(b) => JsonValue::Bool(b),
            None => JsonValue::Null,
        };
    }
    // Try json
    if let Ok(v) = row.try_get::<Option<serde_json::Value>, _>(col) {
        return v.unwrap_or(JsonValue::Null);
    }
    JsonValue::Null
}

/// Convert a JSON value to a FieldValue based on the scalar type.
fn json_to_field_value(val: &JsonValue, _scalar: &GqlScalar) -> FieldValue<'static> {
    match val {
        JsonValue::String(s) => FieldValue::from(Value::String(s.clone())),
        JsonValue::Number(n) => {
            if let Some(i) = n.as_i64() {
                FieldValue::from(Value::Number(i.into()))
            } else if let Some(f) = n.as_f64() {
                FieldValue::from(Value::from(f))
            } else {
                FieldValue::from(Value::String(n.to_string()))
            }
        }
        JsonValue::Bool(b) => FieldValue::from(Value::Boolean(*b)),
        JsonValue::Null => FieldValue::from(Value::Null),
        JsonValue::Array(arr) => {
            let items: Vec<FieldValue> = arr
                .iter()
                .map(|item| json_to_field_value(item, _scalar))
                .collect();
            FieldValue::list(items)
        }
        JsonValue::Object(_) => {
            // JSON scalar
            FieldValue::from(Value::String(val.to_string()))
        }
    }
}

/// Build a SQL WHERE clause from a Hasura-style bool_exp JSON.
fn build_where_clause(
    where_obj: &JsonValue,
    params: &mut Vec<String>,
    entity_name: &str,
    ctx: &ServerContext,
) -> Option<String> {
    let obj = where_obj.as_object()?;
    let mut conditions = Vec::new();

    for (key, value) in obj {
        match key.as_str() {
            "_and" => {
                if let JsonValue::Array(items) = value {
                    let sub: Vec<String> = items
                        .iter()
                        .filter_map(|item| {
                            build_where_clause(item, params, entity_name, ctx)
                        })
                        .collect();
                    if !sub.is_empty() {
                        conditions.push(format!("({})", sub.join(" AND ")));
                    }
                }
            }
            "_or" => {
                if let JsonValue::Array(items) = value {
                    let sub: Vec<String> = items
                        .iter()
                        .filter_map(|item| {
                            build_where_clause(item, params, entity_name, ctx)
                        })
                        .collect();
                    if !sub.is_empty() {
                        conditions.push(format!("({})", sub.join(" OR ")));
                    }
                }
            }
            "_not" => {
                if let Some(clause) = build_where_clause(value, params, entity_name, ctx) {
                    conditions.push(format!("NOT ({})", clause));
                }
            }
            field_name => {
                // field_name: { _eq: ..., _gt: ..., etc }
                if let Some(comp_obj) = value.as_object() {
                    // Check if this is an entity FK field — use {field}_id column
                    let col_name = if let Some(rels) = ctx.entity_relations.get(entity_name) {
                        if rels.contains_key(field_name) {
                            format!("{}_id", field_name)
                        } else {
                            field_name.to_string()
                        }
                    } else {
                        field_name.to_string()
                    };

                    for (op, op_val) in comp_obj {
                        match op.as_str() {
                            "_is_null" => {
                                let is_null = op_val.as_bool().unwrap_or(false);
                                if is_null {
                                    conditions
                                        .push(format!("\"{}\" IS NULL", col_name));
                                } else {
                                    conditions
                                        .push(format!("\"{}\" IS NOT NULL", col_name));
                                }
                            }
                            "_in" => {
                                if let JsonValue::Array(arr) = op_val {
                                    let placeholders: Vec<String> = arr
                                        .iter()
                                        .map(|v| {
                                            params.push(json_val_to_string(v));
                                            format!("${}", params.len())
                                        })
                                        .collect();
                                    conditions.push(format!(
                                        "\"{}\" IN ({})",
                                        col_name,
                                        placeholders.join(", ")
                                    ));
                                }
                            }
                            _ => {
                                let sql_op = match op.as_str() {
                                    "_eq" => "=",
                                    "_neq" => "!=",
                                    "_gt" => ">",
                                    "_gte" => ">=",
                                    "_lt" => "<",
                                    "_lte" => "<=",
                                    _ => continue,
                                };
                                params.push(json_val_to_string(op_val));
                                conditions.push(format!(
                                    "\"{}\" {} ${}",
                                    col_name,
                                    sql_op,
                                    params.len()
                                ));
                            }
                        }
                    }
                }
            }
        }
    }

    if conditions.is_empty() {
        None
    } else {
        Some(conditions.join(" AND "))
    }
}

fn json_val_to_string(val: &JsonValue) -> String {
    match val {
        JsonValue::String(s) => s.clone(),
        JsonValue::Number(n) => n.to_string(),
        JsonValue::Bool(b) => b.to_string(),
        _ => val.to_string(),
    }
}

/// Build an ORDER BY clause from a Hasura-style order_by JSON.
fn build_order_clause(order_val: &JsonValue) -> Option<String> {
    let items = match order_val {
        JsonValue::Array(arr) => arr.clone(),
        JsonValue::Object(_) => vec![order_val.clone()],
        _ => return None,
    };

    let mut clauses = Vec::new();
    for item in &items {
        if let Some(obj) = item.as_object() {
            for (field, direction) in obj {
                let dir_str = match direction.as_str() {
                    Some("asc") => "ASC",
                    Some("asc_nulls_first") => "ASC NULLS FIRST",
                    Some("asc_nulls_last") => "ASC NULLS LAST",
                    Some("desc") => "DESC",
                    Some("desc_nulls_first") => "DESC NULLS FIRST",
                    Some("desc_nulls_last") => "DESC NULLS LAST",
                    _ => "ASC",
                };
                clauses.push(format!("\"{}\" {}", field, dir_str));
            }
        }
    }

    if clauses.is_empty() {
        None
    } else {
        Some(clauses.join(", "))
    }
}
