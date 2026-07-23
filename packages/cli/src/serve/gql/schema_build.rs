//! Builds the per-role GraphQL type registry from the server model,
//! reproducing Hasura's generated schema shape exactly: naming, argument
//! order, descriptions, and role gating (aggregates, table visibility).

use super::types::*;
use crate::serve::model::{Column, Scalar, ServerModel, Table};
use crate::serve::pg_catalog::RelationKind;
use std::collections::BTreeMap;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Role {
    Admin,
    Public,
}

pub struct RoleSchema {
    pub registry: Registry,
    pub role: Role,
}

fn scalar_type_name(c: &Column) -> String {
    c.scalar.gql_name(&c.pg_type)
}

/// Column output type, e.g. `String!`, `[String!]!`, `numeric`.
fn column_type_ref(c: &Column) -> TypeRef {
    let base = TypeRef::named(&scalar_type_name(c));
    let inner = if c.is_array {
        TypeRef::list(TypeRef::non_null(base))
    } else {
        base
    };
    if c.nullable {
        inner
    } else {
        TypeRef::non_null(inner)
    }
}

fn visible_tables(model: &ServerModel, role: Role) -> Vec<&Table> {
    model
        .tables
        .iter()
        .filter(|t| role == Role::Admin || !t.admin_only)
        .collect()
}

fn aggregations_enabled(table: &Table, role: Role) -> bool {
    role == Role::Admin || table.public_aggregations
}

/// Whether the table gets a `<T>_by_pk` root field.
fn has_by_pk(table: &Table) -> bool {
    !table.primary_key.is_empty() && table.kind == RelationKind::Table
}

fn select_args(table_name: &str) -> Vec<InputValueDef> {
    vec![
        InputValueDef::new(
            "distinct_on",
            Some("distinct select on columns"),
            TypeRef::list(TypeRef::non_null(TypeRef::named(&format!(
                "{table_name}_select_column"
            )))),
        ),
        InputValueDef::new(
            "limit",
            Some("limit the number of rows returned"),
            TypeRef::named("Int"),
        ),
        InputValueDef::new(
            "offset",
            Some("skip the first n rows. Use only with order_by"),
            TypeRef::named("Int"),
        ),
        InputValueDef::new(
            "order_by",
            Some("sort the rows by one or more columns"),
            TypeRef::list(TypeRef::non_null(TypeRef::named(&format!(
                "{table_name}_order_by"
            )))),
        ),
        InputValueDef::new(
            "where",
            Some("filter the rows returned"),
            TypeRef::named(&format!("{table_name}_bool_exp")),
        ),
    ]
}

/// The numeric aggregate operations in Hasura's field order within
/// `<T>_aggregate_fields` (alphabetical among all ops).
fn numeric_ops() -> Vec<&'static str> {
    vec![
        "avg",
        "stddev",
        "stddev_pop",
        "stddev_samp",
        "sum",
        "var_pop",
        "var_samp",
        "variance",
    ]
}

/// Result scalar of an aggregate op over a column.
fn agg_op_result_type(op: &str, c: &Column) -> TypeRef {
    match op {
        // sum keeps the column's scalar; everything else yields Float.
        "sum" => TypeRef::named(&scalar_type_name(c)),
        "min" | "max" => column_min_max_type(c),
        _ => TypeRef::named("Float"),
    }
}

fn column_min_max_type(c: &Column) -> TypeRef {
    TypeRef::named(&scalar_type_name(c))
}

/// Columns eligible for min/max fields (Hasura: all comparable scalars,
/// excluding json/jsonb; arrays are excluded as well). `Scalar::Other`
/// covers pg types like bytea with no min/max in Postgres — including them
/// would generate fields whose execution PG rejects.
fn min_max_columns(table: &Table) -> Vec<&Column> {
    table
        .columns
        .iter()
        .filter(|c| {
            !c.is_array
                && !matches!(
                    c.scalar,
                    Scalar::Jsonb | Scalar::Json | Scalar::Boolean | Scalar::Other
                )
        })
        .collect()
}

fn numeric_columns(table: &Table) -> Vec<&Column> {
    table
        .columns
        .iter()
        .filter(|c| !c.is_array && c.scalar.is_numeric())
        .collect()
}

/// Per-op aggregate column groups in Hasura's order: `max`/`min` over
/// comparable columns, then the numeric ops over numeric columns. A group
/// whose column set is empty is omitted entirely (Hasura emits no op field
/// or per-op type for it). Shared by the `_aggregate_fields` and
/// `_aggregate_order_by` builders, which differ only in the node shape each
/// (op, columns) pair expands to.
fn aggregate_op_groups(table: &Table) -> Vec<(&'static str, Vec<&Column>)> {
    let mut groups: Vec<(&'static str, Vec<&Column>)> = Vec::new();
    let min_max = min_max_columns(table);
    if !min_max.is_empty() {
        for op in ["max", "min"] {
            groups.push((op, min_max.clone()));
        }
    }
    let numeric = numeric_columns(table);
    if !numeric.is_empty() {
        for op in numeric_ops() {
            groups.push((op, numeric.clone()));
        }
    }
    groups
}

/// Tables that are the remote side of some array relationship visible to
/// this role — they need `<T>_aggregate_order_by` (+ per-op order_by input
/// types), regardless of allow_aggregations.
fn aggregate_order_by_targets(model: &ServerModel, role: Role) -> Vec<String> {
    let mut names: Vec<String> = vec![];
    for t in visible_tables(model, role) {
        for rel in &t.array_relationships {
            if !names.contains(&rel.remote_table) {
                names.push(rel.remote_table.clone());
            }
        }
    }
    names
}

/// Whether any visible table's bool_exp needs `<rel>_aggregate` predicates
/// for this remote table (admin only — gated by allow_aggregations of the
/// remote table).
fn aggregate_bool_exp_targets(model: &ServerModel, role: Role) -> Vec<String> {
    let mut names: Vec<String> = vec![];
    for t in visible_tables(model, role) {
        for rel in &t.array_relationships {
            let remote_aggregatable = model
                .table(&rel.remote_table)
                .map(|rt| aggregations_enabled(rt, role))
                .unwrap_or(false);
            if remote_aggregatable && !names.contains(&rel.remote_table) {
                names.push(rel.remote_table.clone());
            }
        }
    }
    names
}

pub fn build(model: &ServerModel, role: Role) -> Registry {
    build_internal(model, role).0
}

/// Startup validation: fails when a user entity name collides with a
/// generated/built-in type name (like Hasura fails table tracking on
/// conflicts). The admin registry is a superset of every role's types, so
/// checking it covers all roles.
pub fn check_type_collisions(model: &ServerModel) -> anyhow::Result<()> {
    let (_, mut collisions) = build_internal(model, Role::Admin);
    if collisions.is_empty() {
        return Ok(());
    }
    collisions.sort();
    collisions.dedup();
    Err(anyhow::anyhow!(
        "GraphQL type name collision(s): {}. An entity in schema.graphql clashes with a built-in or generated type name (e.g. \"<Entity>_aggregate\", \"<Entity>_bool_exp\", scalar or root type names). Rename the conflicting entity.",
        collisions.join(", ")
    ))
}

fn build_internal(model: &ServerModel, role: Role) -> (Registry, Vec<String>) {
    let mut b = Builder {
        model,
        role,
        types: BTreeMap::new(),
        collisions: Vec::new(),
    };
    b.build_base_scalars_and_enums();

    let tables = visible_tables(model, role);
    for table in &tables {
        b.build_table_types(table);
    }
    for name in aggregate_order_by_targets(model, role) {
        if let Some(t) = model.table(&name) {
            b.build_aggregate_order_by_types(t);
        }
    }
    for name in aggregate_bool_exp_targets(model, role) {
        if let Some(t) = model.table(&name) {
            b.build_aggregate_bool_exp_types(t);
        }
    }
    b.build_roots(&tables);
    b.build_meta_types();

    (
        Registry {
            types: b.types,
            query_root: "query_root".to_string(),
            mutation_root: None,
            subscription_root: "subscription_root".to_string(),
        },
        b.collisions,
    )
}

/// A synthetic column used to force on-demand creation of a shared
/// `<scalar>_comparison_exp` type that is referenced unconditionally.
fn stub_column(pg_type: &str, scalar: Scalar) -> Column {
    Column {
        api_name: "_".into(),
        db_name: "_".into(),
        pg_type: pg_type.into(),
        pg_type_schema: "pg_catalog".into(),
        scalar,
        is_array: false,
        nullable: true,
        description: None,
    }
}

struct Builder<'a> {
    model: &'a ServerModel,
    role: Role,
    types: BTreeMap<String, TypeDef>,
    /// Names that were defined twice (or squatted by a user entity) —
    /// nothing in the builder legitimately re-adds a name, so any duplicate
    /// is a genuine collision surfaced by check_type_collisions.
    collisions: Vec<String>,
}

impl<'a> Builder<'a> {
    fn add(&mut self, def: TypeDef) {
        let name = def.name().to_string();
        if self.types.insert(name.clone(), def).is_some() {
            self.collisions.push(name);
        }
    }

    fn add_scalar(&mut self, name: &str) {
        match self.types.get(name) {
            None => self.add(TypeDef::Scalar {
                name: name.to_string(),
                description: None,
            }),
            Some(TypeDef::Scalar { .. }) => {}
            Some(_) => self.collisions.push(name.to_string()),
        }
    }

    fn build_base_scalars_and_enums(&mut self) {
        for s in ["Boolean", "Float", "Int", "String"] {
            self.add_scalar(s);
        }
        self.add(TypeDef::Enum {
            name: "order_by".to_string(),
            description: Some("column ordering options".to_string()),
            values: vec![
                EnumValueDef {
                    name: "asc".into(),
                    description: Some("in ascending order, nulls last".into()),
                },
                EnumValueDef {
                    name: "asc_nulls_first".into(),
                    description: Some("in ascending order, nulls first".into()),
                },
                EnumValueDef {
                    name: "asc_nulls_last".into(),
                    description: Some("in ascending order, nulls last".into()),
                },
                EnumValueDef {
                    name: "desc".into(),
                    description: Some("in descending order, nulls first".into()),
                },
                EnumValueDef {
                    name: "desc_nulls_first".into(),
                    description: Some("in descending order, nulls first".into()),
                },
                EnumValueDef {
                    name: "desc_nulls_last".into(),
                    description: Some("in descending order, nulls last".into()),
                },
            ],
        });
        self.add(TypeDef::Enum {
            name: "cursor_ordering".to_string(),
            description: Some("ordering argument of a cursor".to_string()),
            values: vec![
                EnumValueDef {
                    name: "ASC".into(),
                    description: Some("ascending ordering of the cursor".into()),
                },
                EnumValueDef {
                    name: "DESC".into(),
                    description: Some("descending ordering of the cursor".into()),
                },
            ],
        });
    }

    /// `<scalar>_comparison_exp`, shared across tables; created on demand.
    fn comparison_exp_name(&mut self, c: &Column) -> String {
        let scalar = scalar_type_name(c);
        self.add_scalar(&scalar);
        let name = if c.is_array {
            format!("{scalar}_array_comparison_exp")
        } else {
            format!("{scalar}_comparison_exp")
        };
        if let Some(existing) = self.types.get(&name) {
            if !matches!(existing, TypeDef::InputObject { .. }) {
                self.collisions.push(name.clone());
            }
            return name;
        }

        let value_ty = if c.is_array {
            TypeRef::list(TypeRef::non_null(TypeRef::named(&scalar)))
        } else {
            TypeRef::named(&scalar)
        };
        let list_ty = TypeRef::list(TypeRef::non_null(value_ty.clone()));

        let mut fields: Vec<InputValueDef> = Vec::new();
        let mut push = |n: &str, d: Option<&str>, ty: TypeRef| {
            fields.push(InputValueDef::new(n, d, ty));
        };

        if c.is_array {
            push(
                "_contained_in",
                Some("is the array contained in the given array value"),
                value_ty.clone(),
            );
            push(
                "_contains",
                Some("does the array contain the given value"),
                value_ty.clone(),
            );
        }
        if c.scalar == Scalar::Jsonb && !c.is_array {
            push("_cast", None, TypeRef::named("jsonb_cast_exp"));
            self.build_jsonb_cast_exp();
            push(
                "_contained_in",
                Some("is the column contained in the given json value"),
                value_ty.clone(),
            );
            push(
                "_contains",
                Some("does the column contain the given json value at the top level"),
                value_ty.clone(),
            );
        }
        push("_eq", None, value_ty.clone());
        push("_gt", None, value_ty.clone());
        push("_gte", None, value_ty.clone());
        if c.scalar == Scalar::Jsonb && !c.is_array {
            push(
                "_has_key",
                Some("does the string exist as a top-level key in the column"),
                TypeRef::named("String"),
            );
            push(
                "_has_keys_all",
                Some("do all of these strings exist as top-level keys in the column"),
                TypeRef::list(TypeRef::non_null(TypeRef::named("String"))),
            );
            push(
                "_has_keys_any",
                Some("do any of these strings exist as top-level keys in the column"),
                TypeRef::list(TypeRef::non_null(TypeRef::named("String"))),
            );
        }
        if c.scalar == Scalar::String && !c.is_array {
            push(
                "_ilike",
                Some("does the column match the given case-insensitive pattern"),
                TypeRef::named(&scalar),
            );
        }
        push("_in", None, list_ty.clone());
        if c.scalar == Scalar::String && !c.is_array {
            push(
                "_iregex",
                Some("does the column match the given POSIX regular expression, case insensitive"),
                TypeRef::named(&scalar),
            );
        }
        push("_is_null", None, TypeRef::named("Boolean"));
        if c.scalar == Scalar::String && !c.is_array {
            push(
                "_like",
                Some("does the column match the given pattern"),
                TypeRef::named(&scalar),
            );
        }
        push("_lt", None, value_ty.clone());
        push("_lte", None, value_ty.clone());
        push("_neq", None, value_ty.clone());
        if c.scalar == Scalar::String && !c.is_array {
            push(
                "_nilike",
                Some("does the column NOT match the given case-insensitive pattern"),
                TypeRef::named(&scalar),
            );
        }
        push("_nin", None, list_ty);
        if c.scalar == Scalar::String && !c.is_array {
            push(
                "_niregex",
                Some(
                    "does the column NOT match the given POSIX regular expression, case insensitive",
                ),
                TypeRef::named(&scalar),
            );
            push(
                "_nlike",
                Some("does the column NOT match the given pattern"),
                TypeRef::named(&scalar),
            );
            push(
                "_nregex",
                Some(
                    "does the column NOT match the given POSIX regular expression, case sensitive",
                ),
                TypeRef::named(&scalar),
            );
            push(
                "_nsimilar",
                Some("does the column NOT match the given SQL regular expression"),
                TypeRef::named(&scalar),
            );
            push(
                "_regex",
                Some("does the column match the given POSIX regular expression, case sensitive"),
                TypeRef::named(&scalar),
            );
            push(
                "_similar",
                Some("does the column match the given SQL regular expression"),
                TypeRef::named(&scalar),
            );
        }

        // Hasura sorts comparison-exp fields alphabetically.
        fields.sort_by(|a, b| a.name.cmp(&b.name));

        self.add(TypeDef::InputObject {
            name: name.clone(),
            description: Some(format!(
                "Boolean expression to compare columns of type \"{scalar}\". All fields are combined with logical 'AND'."
            )),
            fields,
        });
        name
    }

    fn build_jsonb_cast_exp(&mut self) {
        if let Some(existing) = self.types.get("jsonb_cast_exp") {
            if !matches!(existing, TypeDef::InputObject { .. }) {
                self.collisions.push("jsonb_cast_exp".to_string());
            }
            return;
        }
        // The String member references String_comparison_exp; make sure it
        // exists.
        let cmp = self.comparison_exp_name(&stub_column("text", Scalar::String));
        self.add(TypeDef::InputObject {
            name: "jsonb_cast_exp".to_string(),
            description: None,
            fields: vec![InputValueDef::new("String", None, TypeRef::named(&cmp))],
        });
    }

    fn build_table_types(&mut self, table: &Table) {
        let t = &table.name;
        let role = self.role;

        // Object type
        let mut fields: Vec<FieldDef> = Vec::new();
        for c in &table.columns {
            let mut args = vec![];
            if matches!(c.scalar, Scalar::Jsonb | Scalar::Json) && !c.is_array {
                args.push(InputValueDef::new(
                    "path",
                    Some("JSON select path"),
                    TypeRef::named("String"),
                ));
            }
            fields.push(FieldDef {
                name: c.api_name.clone(),
                description: c.description.clone(),
                args,
                ty: column_type_ref(c),
                kind: FieldKind::Column {
                    column: c.api_name.clone(),
                },
            });
        }
        for rel in &table.object_relationships {
            let Some(remote) = self.model.table(&rel.remote_table) else {
                continue;
            };
            // Hasura's manual object relationships are always nullable, even
            // when the fk column is NOT NULL, because they don't prove
            // existence (pinned by snapshot: Gravatar.owner: User).
            fields.push(FieldDef {
                name: rel.name.clone(),
                description: Some("An object relationship".to_string()),
                args: vec![],
                ty: TypeRef::named(&remote.name),
                kind: FieldKind::ObjectRel {
                    rel: rel.name.clone(),
                },
            });
        }
        for rel in &table.array_relationships {
            let Some(remote) = self.model.table(&rel.remote_table) else {
                continue;
            };
            fields.push(FieldDef {
                name: rel.name.clone(),
                description: Some("An array relationship".to_string()),
                args: select_args(&remote.name),
                ty: TypeRef::non_null_list_of_non_null(&remote.name),
                kind: FieldKind::ArrayRel {
                    rel: rel.name.clone(),
                },
            });
            if aggregations_enabled(remote, role) {
                fields.push(FieldDef {
                    name: format!("{}_aggregate", rel.name),
                    description: Some("An aggregate relationship".to_string()),
                    args: select_args(&remote.name),
                    ty: TypeRef::non_null(TypeRef::named(&format!("{}_aggregate", remote.name))),
                    kind: FieldKind::ArrayRelAggregate {
                        rel: rel.name.clone(),
                    },
                });
            }
        }
        fields.sort_by(|a, b| a.name.cmp(&b.name));
        self.add(TypeDef::Object {
            name: t.clone(),
            description: Some(
                table
                    .description
                    .clone()
                    .unwrap_or_else(|| format!("columns and relationships of \"{t}\"")),
            ),
            fields,
        });

        // bool_exp
        let mut bool_fields: Vec<InputValueDef> = vec![
            InputValueDef::new(
                "_and",
                None,
                TypeRef::list(TypeRef::non_null(TypeRef::named(&format!("{t}_bool_exp")))),
            ),
            InputValueDef::new("_not", None, TypeRef::named(&format!("{t}_bool_exp"))),
            InputValueDef::new(
                "_or",
                None,
                TypeRef::list(TypeRef::non_null(TypeRef::named(&format!("{t}_bool_exp")))),
            ),
        ];
        for c in &table.columns {
            let cmp = self.comparison_exp_name(c);
            bool_fields.push(InputValueDef::new(&c.api_name, None, TypeRef::named(&cmp)));
        }
        for rel in &table.object_relationships {
            bool_fields.push(InputValueDef::new(
                &rel.name,
                None,
                TypeRef::named(&format!("{}_bool_exp", rel.remote_table)),
            ));
        }
        for rel in &table.array_relationships {
            bool_fields.push(InputValueDef::new(
                &rel.name,
                None,
                TypeRef::named(&format!("{}_bool_exp", rel.remote_table)),
            ));
            let remote_aggregatable = self
                .model
                .table(&rel.remote_table)
                .map(|rt| aggregations_enabled(rt, role))
                .unwrap_or(false);
            if remote_aggregatable {
                bool_fields.push(InputValueDef::new(
                    &format!("{}_aggregate", rel.name),
                    None,
                    TypeRef::named(&format!("{}_aggregate_bool_exp", rel.remote_table)),
                ));
            }
        }
        bool_fields.sort_by(|a, b| a.name.cmp(&b.name));
        self.add(TypeDef::InputObject {
            name: format!("{t}_bool_exp"),
            description: Some(format!(
                "Boolean expression to filter rows from the table \"{t}\". All fields are combined with a logical 'AND'."
            )),
            fields: bool_fields,
        });

        // order_by
        let mut order_fields: Vec<InputValueDef> = table
            .columns
            .iter()
            .map(|c| InputValueDef::new(&c.api_name, None, TypeRef::named("order_by")))
            .collect();
        for rel in &table.object_relationships {
            order_fields.push(InputValueDef::new(
                &rel.name,
                None,
                TypeRef::named(&format!("{}_order_by", rel.remote_table)),
            ));
        }
        for rel in &table.array_relationships {
            order_fields.push(InputValueDef::new(
                &format!("{}_aggregate", rel.name),
                None,
                TypeRef::named(&format!("{}_aggregate_order_by", rel.remote_table)),
            ));
        }
        order_fields.sort_by(|a, b| a.name.cmp(&b.name));
        self.add(TypeDef::InputObject {
            name: format!("{t}_order_by"),
            description: Some(format!(
                "Ordering options when selecting data from \"{t}\"."
            )),
            fields: order_fields,
        });

        // select_column enum
        let mut col_values: Vec<EnumValueDef> = table
            .columns
            .iter()
            .map(|c| EnumValueDef {
                name: c.api_name.clone(),
                description: Some("column name".to_string()),
            })
            .collect();
        col_values.sort_by(|a, b| a.name.cmp(&b.name));
        self.add(TypeDef::Enum {
            name: format!("{t}_select_column"),
            description: Some(format!("select columns of table \"{t}\"")),
            values: col_values,
        });

        // stream cursor inputs
        self.add(TypeDef::InputObject {
            name: format!("{t}_stream_cursor_input"),
            description: Some(format!("Streaming cursor of the table \"{t}\"")),
            fields: vec![
                InputValueDef::new(
                    "initial_value",
                    Some("Stream column input with initial value"),
                    TypeRef::non_null(TypeRef::named(&format!("{t}_stream_cursor_value_input"))),
                ),
                InputValueDef::new(
                    "ordering",
                    Some("cursor ordering"),
                    TypeRef::named("cursor_ordering"),
                ),
            ],
        });
        let mut cursor_fields: Vec<InputValueDef> = table
            .columns
            .iter()
            .map(|c| {
                let base = TypeRef::named(&scalar_type_name(c));
                let ty = if c.is_array {
                    TypeRef::list(TypeRef::non_null(base))
                } else {
                    base
                };
                InputValueDef::new(&c.api_name, c.description.as_deref(), ty)
            })
            .collect();
        cursor_fields.sort_by(|a, b| a.name.cmp(&b.name));
        self.add(TypeDef::InputObject {
            name: format!("{t}_stream_cursor_value_input"),
            description: Some(
                "Initial value of the column from where the streaming should start".to_string(),
            ),
            fields: cursor_fields,
        });

        // aggregate types (only when this role can aggregate this table)
        if aggregations_enabled(table, role) {
            self.build_aggregate_types(table);
        }
    }

    fn build_aggregate_types(&mut self, table: &Table) {
        let t = &table.name;
        self.add(TypeDef::Object {
            name: format!("{t}_aggregate"),
            description: Some(format!("aggregated selection of \"{t}\"")),
            fields: vec![
                FieldDef {
                    name: "aggregate".to_string(),
                    description: None,
                    args: vec![],
                    ty: TypeRef::named(&format!("{t}_aggregate_fields")),
                    kind: FieldKind::AggregateBody,
                },
                FieldDef {
                    name: "nodes".to_string(),
                    description: None,
                    args: vec![],
                    ty: TypeRef::non_null_list_of_non_null(t),
                    kind: FieldKind::AggregateNodes,
                },
            ],
        });

        let mut agg_fields: Vec<FieldDef> = vec![FieldDef {
            name: "count".to_string(),
            description: None,
            args: vec![
                InputValueDef::new(
                    "columns",
                    None,
                    TypeRef::list(TypeRef::non_null(TypeRef::named(&format!(
                        "{t}_select_column"
                    )))),
                ),
                InputValueDef::new("distinct", None, TypeRef::named("Boolean")),
            ],
            ty: TypeRef::non_null(TypeRef::named("Int")),
            kind: FieldKind::AggregateCount,
        }];
        for (op, cols) in aggregate_op_groups(table) {
            agg_fields.push(FieldDef {
                name: op.to_string(),
                description: None,
                args: vec![],
                ty: TypeRef::named(&format!("{t}_{op}_fields")),
                kind: FieldKind::AggregateOp { op: op.to_string() },
            });
            let mut op_fields: Vec<FieldDef> = cols
                .iter()
                .map(|c| FieldDef {
                    name: c.api_name.clone(),
                    description: c.description.clone(),
                    args: vec![],
                    ty: agg_op_result_type(op, c),
                    kind: FieldKind::AggregateOpColumn {
                        op: op.to_string(),
                        column: c.api_name.clone(),
                    },
                })
                .collect();
            op_fields.sort_by(|a, b| a.name.cmp(&b.name));
            self.add(TypeDef::Object {
                name: format!("{t}_{op}_fields"),
                description: Some(format!("aggregate {op} on columns")),
                fields: op_fields,
            });
        }
        agg_fields.sort_by(|a, b| a.name.cmp(&b.name));
        self.add(TypeDef::Object {
            name: format!("{t}_aggregate_fields"),
            description: Some(format!("aggregate fields of \"{t}\"")),
            fields: agg_fields,
        });
    }

    /// `<T>_aggregate_order_by` + per-op order_by inputs, for tables that
    /// are the remote side of array relationships.
    fn build_aggregate_order_by_types(&mut self, table: &Table) {
        let t = &table.name;
        if let Some(existing) = self.types.get(&format!("{t}_aggregate_order_by")) {
            if !matches!(existing, TypeDef::InputObject { .. }) {
                self.collisions.push(format!("{t}_aggregate_order_by"));
            }
            return;
        }
        let mut fields: Vec<InputValueDef> = vec![InputValueDef::new(
            "count",
            None,
            TypeRef::named("order_by"),
        )];

        for (op, cols) in aggregate_op_groups(table) {
            fields.push(InputValueDef::new(
                op,
                None,
                TypeRef::named(&format!("{t}_{op}_order_by")),
            ));
            let mut op_fields: Vec<InputValueDef> = cols
                .iter()
                .map(|c| InputValueDef::new(&c.api_name, None, TypeRef::named("order_by")))
                .collect();
            op_fields.sort_by(|a, b| a.name.cmp(&b.name));
            self.add(TypeDef::InputObject {
                name: format!("{t}_{op}_order_by"),
                description: Some(format!("order by {op}() on columns of table \"{t}\"")),
                fields: op_fields,
            });
        }
        fields.sort_by(|a, b| a.name.cmp(&b.name));
        self.add(TypeDef::InputObject {
            name: format!("{t}_aggregate_order_by"),
            description: Some(format!("order by aggregate values of table \"{t}\"")),
            fields,
        });
    }

    /// `<T>_aggregate_bool_exp` types for aggregate predicates in bool_exps
    /// (admin, or aggregatable tables).
    fn build_aggregate_bool_exp_types(&mut self, table: &Table) {
        let t = &table.name;
        if let Some(existing) = self.types.get(&format!("{t}_aggregate_bool_exp")) {
            if !matches!(existing, TypeDef::InputObject { .. }) {
                self.collisions.push(format!("{t}_aggregate_bool_exp"));
            }
            return;
        }
        let bool_cols: Vec<&Column> = table
            .columns
            .iter()
            .filter(|c| !c.is_array && c.scalar == Scalar::Boolean)
            .collect();

        let mut fields: Vec<InputValueDef> = Vec::new();
        for (op, cols) in [("bool_and", &bool_cols), ("bool_or", &bool_cols)] {
            if cols.is_empty() {
                continue;
            }
            // The `predicate` field below references Boolean_comparison_exp
            // unconditionally; guarantee it exists even if no visible table
            // column created it on demand.
            self.comparison_exp_name(&stub_column("bool", Scalar::Boolean));
            fields.push(InputValueDef::new(
                op,
                None,
                TypeRef::named(&format!("{t}_aggregate_bool_exp_{op}")),
            ));
            let sel_name =
                format!("{t}_select_column_{t}_aggregate_bool_exp_{op}_arguments_columns");
            let mut sel_values: Vec<EnumValueDef> = cols
                .iter()
                .map(|c| EnumValueDef {
                    name: c.api_name.clone(),
                    description: Some("column name".to_string()),
                })
                .collect();
            sel_values.sort_by(|a, b| a.name.cmp(&b.name));
            self.add(TypeDef::Enum {
                name: sel_name.clone(),
                description: Some(format!(
                    "select \"{t}_aggregate_bool_exp_{op}_arguments_columns\" columns of table \"{t}\""
                )),
                values: sel_values,
            });
            self.add(TypeDef::InputObject {
                name: format!("{t}_aggregate_bool_exp_{op}"),
                description: None,
                fields: vec![
                    InputValueDef::new(
                        "arguments",
                        None,
                        TypeRef::non_null(TypeRef::named(&sel_name)),
                    ),
                    InputValueDef::new("distinct", None, TypeRef::named("Boolean")),
                    InputValueDef::new("filter", None, TypeRef::named(&format!("{t}_bool_exp"))),
                    InputValueDef::new(
                        "predicate",
                        None,
                        TypeRef::non_null(TypeRef::named("Boolean_comparison_exp")),
                    ),
                ],
            });
        }
        // The count `predicate` references Int_comparison_exp
        // unconditionally; without this, a schema with no int4 column would
        // reference a type that was never registered.
        self.comparison_exp_name(&stub_column("int4", Scalar::Int));
        fields.push(InputValueDef::new(
            "count",
            None,
            TypeRef::named(&format!("{t}_aggregate_bool_exp_count")),
        ));
        self.add(TypeDef::InputObject {
            name: format!("{t}_aggregate_bool_exp_count"),
            description: None,
            fields: vec![
                InputValueDef::new(
                    "arguments",
                    None,
                    TypeRef::list(TypeRef::non_null(TypeRef::named(&format!(
                        "{t}_select_column"
                    )))),
                ),
                InputValueDef::new("distinct", None, TypeRef::named("Boolean")),
                InputValueDef::new("filter", None, TypeRef::named(&format!("{t}_bool_exp"))),
                InputValueDef::new(
                    "predicate",
                    None,
                    TypeRef::non_null(TypeRef::named("Int_comparison_exp")),
                ),
            ],
        });
        fields.sort_by(|a, b| a.name.cmp(&b.name));
        self.add(TypeDef::InputObject {
            name: format!("{t}_aggregate_bool_exp"),
            description: None,
            fields,
        });
    }

    /// The `__Schema`/`__Type`/... meta types as Hasura reports them in its
    /// own `types` list. Hasura's shapes are degenerate — list fields carry
    /// their bare element type, and most nullable/scalar fields (even
    /// `isRepeatable` and `isDeprecated`) come out as `String!`; reproduced
    /// verbatim from the introspection-full-*.json oracle. There is no
    /// `__DirectiveLocation` type: `locations` is `String!` too.
    fn build_meta_types(&mut self) {
        fn meta_field(name: &str, ty: TypeRef) -> FieldDef {
            FieldDef {
                name: name.to_string(),
                description: None,
                args: vec![],
                ty,
                kind: FieldKind::Introspection,
            }
        }
        fn string_nn() -> TypeRef {
            TypeRef::non_null(TypeRef::named("String"))
        }

        self.add(TypeDef::Object {
            name: "__Directive".to_string(),
            description: None,
            fields: vec![
                meta_field("args", TypeRef::named("__InputValue")),
                meta_field("description", string_nn()),
                meta_field("isRepeatable", string_nn()),
                meta_field("locations", string_nn()),
                meta_field("name", string_nn()),
            ],
        });
        self.add(TypeDef::Object {
            name: "__EnumValue".to_string(),
            description: None,
            fields: vec![
                meta_field("deprecationReason", string_nn()),
                meta_field("description", string_nn()),
                meta_field("isDeprecated", string_nn()),
                meta_field("name", string_nn()),
            ],
        });
        self.add(TypeDef::Object {
            name: "__Field".to_string(),
            description: None,
            fields: vec![
                meta_field("args", TypeRef::named("__InputValue")),
                meta_field("deprecationReason", string_nn()),
                meta_field("description", string_nn()),
                meta_field("isDeprecated", string_nn()),
                meta_field("name", string_nn()),
                meta_field("type", TypeRef::named("__Type")),
            ],
        });
        self.add(TypeDef::Object {
            name: "__InputValue".to_string(),
            description: None,
            fields: vec![
                meta_field("defaultValue", string_nn()),
                meta_field("description", string_nn()),
                meta_field("name", string_nn()),
                meta_field("type", TypeRef::named("__Type")),
            ],
        });
        self.add(TypeDef::Object {
            name: "__Schema".to_string(),
            description: None,
            fields: vec![
                meta_field("description", string_nn()),
                meta_field("directives", TypeRef::named("__Directive")),
                meta_field("mutationType", TypeRef::named("__Type")),
                meta_field("queryType", TypeRef::named("__Type")),
                meta_field("subscriptionType", TypeRef::named("__Type")),
                meta_field("types", TypeRef::named("__Type")),
            ],
        });
        let include_deprecated = {
            let mut arg = InputValueDef::new("includeDeprecated", None, TypeRef::named("Boolean"));
            arg.default_value = Some("false".to_string());
            arg
        };
        self.add(TypeDef::Object {
            name: "__Type".to_string(),
            description: None,
            fields: vec![
                meta_field("description", string_nn()),
                FieldDef {
                    name: "enumValues".to_string(),
                    description: None,
                    args: vec![include_deprecated.clone()],
                    ty: TypeRef::named("__EnumValue"),
                    kind: FieldKind::Introspection,
                },
                FieldDef {
                    name: "fields".to_string(),
                    description: None,
                    args: vec![include_deprecated],
                    ty: TypeRef::named("__Field"),
                    kind: FieldKind::Introspection,
                },
                meta_field("inputFields", TypeRef::named("__InputValue")),
                meta_field("interfaces", TypeRef::named("__Type")),
                meta_field("kind", TypeRef::non_null(TypeRef::named("__TypeKind"))),
                meta_field("name", string_nn()),
                meta_field("ofType", TypeRef::named("__Type")),
                meta_field("possibleTypes", TypeRef::named("__Type")),
            ],
        });
        self.add(TypeDef::Enum {
            name: "__TypeKind".to_string(),
            description: None,
            values: [
                "ENUM",
                "INPUT_OBJECT",
                "INTERFACE",
                "LIST",
                "NON_NULL",
                "OBJECT",
                "SCALAR",
                "UNION",
            ]
            .iter()
            .map(|n| EnumValueDef {
                name: n.to_string(),
                description: None,
            })
            .collect(),
        });
    }

    fn build_roots(&mut self, tables: &[&Table]) {
        let mut query_fields: Vec<FieldDef> = Vec::new();
        let mut sub_fields: Vec<FieldDef> = Vec::new();

        for table in tables {
            let t = &table.name;
            let select = FieldDef {
                name: t.clone(),
                description: Some(format!("fetch data from the table: \"{t}\"")),
                args: select_args(t),
                ty: TypeRef::non_null_list_of_non_null(t),
                kind: FieldKind::SelectMany { table: t.clone() },
            };
            query_fields.push(select.clone());
            sub_fields.push(select);

            if aggregations_enabled(table, self.role) {
                let agg = FieldDef {
                    name: format!("{t}_aggregate"),
                    description: Some(format!("fetch aggregated fields from the table: \"{t}\"")),
                    args: select_args(t),
                    ty: TypeRef::non_null(TypeRef::named(&format!("{t}_aggregate"))),
                    kind: FieldKind::SelectAggregate { table: t.clone() },
                };
                query_fields.push(agg.clone());
                sub_fields.push(agg);
            }

            if has_by_pk(table) {
                let args: Vec<InputValueDef> = table
                    .primary_key
                    .iter()
                    .filter_map(|pk_db| {
                        let c = table.columns.iter().find(|c| &c.db_name == pk_db)?;
                        Some(InputValueDef::new(
                            &c.api_name,
                            None,
                            TypeRef::non_null(TypeRef::named(&scalar_type_name(c))),
                        ))
                    })
                    .collect();
                let by_pk = FieldDef {
                    name: format!("{t}_by_pk"),
                    description: Some(format!(
                        "fetch data from the table: \"{t}\" using primary key columns"
                    )),
                    args,
                    ty: TypeRef::named(t),
                    kind: FieldKind::SelectByPk { table: t.clone() },
                };
                query_fields.push(by_pk.clone());
                sub_fields.push(by_pk);
            }

            sub_fields.push(FieldDef {
                name: format!("{t}_stream"),
                description: Some(format!(
                    "fetch data from the table in a streaming manner: \"{t}\""
                )),
                args: vec![
                    InputValueDef::new(
                        "batch_size",
                        Some("maximum number of rows returned in a single batch"),
                        TypeRef::non_null(TypeRef::named("Int")),
                    ),
                    InputValueDef::new(
                        "cursor",
                        Some("cursor to stream the results returned by the query"),
                        TypeRef::non_null(TypeRef::list(TypeRef::named(&format!(
                            "{t}_stream_cursor_input"
                        )))),
                    ),
                    InputValueDef::new(
                        "where",
                        Some("filter the rows returned"),
                        TypeRef::named(&format!("{t}_bool_exp")),
                    ),
                ],
                ty: TypeRef::non_null_list_of_non_null(t),
                kind: FieldKind::SelectStream { table: t.clone() },
            });
        }

        query_fields.sort_by(|a, b| a.name.cmp(&b.name));
        sub_fields.sort_by(|a, b| a.name.cmp(&b.name));

        self.add(TypeDef::Object {
            name: "query_root".to_string(),
            description: None,
            fields: query_fields,
        });
        self.add(TypeDef::Object {
            name: "subscription_root".to_string(),
            description: None,
            fields: sub_fields,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::serve::model::{ArrayRelationship, Column, Scalar, ServerModel, Table};

    fn col(api: &str, pg_type: &str, scalar: Scalar) -> Column {
        Column {
            api_name: api.to_string(),
            db_name: api.to_string(),
            pg_type: pg_type.to_string(),
            pg_type_schema: "pg_catalog".to_string(),
            scalar,
            is_array: false,
            nullable: false,
            description: None,
        }
    }

    fn table(name: &str, columns: Vec<Column>) -> Table {
        Table {
            name: name.to_string(),
            kind: crate::serve::pg_catalog::RelationKind::Table,
            description: None,
            columns,
            primary_key: vec!["id".to_string()],
            object_relationships: vec![],
            array_relationships: vec![],
            admin_only: false,
            public_aggregations: false,
        }
    }

    fn model(tables: Vec<Table>) -> ServerModel {
        let mut tables = tables;
        tables.sort_by(|a, b| a.name.cmp(&b.name));
        ServerModel {
            tables,
            pg_schema: "public".to_string(),
            response_limit: None,
        }
    }

    /// No table has an int4 or bool column, yet the count/bool predicates of
    /// `<T>_aggregate_bool_exp_*` reference Int/Boolean_comparison_exp.
    #[test]
    fn aggregate_bool_exp_predicate_types_always_registered() {
        let mut owner = table("Owner", vec![col("id", "text", Scalar::String)]);
        owner.array_relationships.push(ArrayRelationship {
            name: "pets".to_string(),
            remote_table: "Pet".to_string(),
            remote_db_column: "owner_id".to_string(),
        });
        let mut pet = table(
            "Pet",
            vec![
                col("id", "text", Scalar::String),
                col("owner_id", "text", Scalar::String),
                col("vaccinated", "bool", Scalar::Boolean),
            ],
        );
        pet.public_aggregations = true;
        let registry = build(&model(vec![owner, pet]), Role::Public);
        assert_eq!(
            (
                registry.get("Pet_aggregate_bool_exp_count").is_some(),
                registry.get("Int_comparison_exp").is_some(),
                registry.get("Boolean_comparison_exp").is_some(),
            ),
            (true, true, true)
        );
    }

    /// bytea-like columns (Scalar::Other) have no min/max in Postgres; they
    /// must not appear in `<T>_min_fields`/`<T>_max_fields`.
    #[test]
    fn other_scalar_columns_excluded_from_min_max() {
        let mut t = table(
            "Blob",
            vec![
                col("id", "text", Scalar::String),
                col("payload", "bytea", Scalar::Other),
            ],
        );
        t.public_aggregations = true;
        let registry = build(&model(vec![t]), Role::Public);
        let min_fields = match registry.get("Blob_min_fields") {
            Some(TypeDef::Object { fields, .. }) => {
                fields.iter().map(|f| f.name.clone()).collect::<Vec<_>>()
            }
            _ => panic!("Blob_min_fields missing"),
        };
        assert_eq!(min_fields, vec!["id".to_string()]);
    }

    #[test]
    fn min_max_omitted_when_only_other_columns() {
        let mut t = table("Blob", vec![col("payload", "bytea", Scalar::Other)]);
        t.public_aggregations = true;
        let registry = build(&model(vec![t]), Role::Public);
        assert_eq!(
            (
                registry.get("Blob_min_fields").is_none(),
                registry.get("Blob_max_fields").is_none()
            ),
            (true, true)
        );
    }
}
