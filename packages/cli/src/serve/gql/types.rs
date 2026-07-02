//! In-memory GraphQL type system for `envio serve`, mirroring the schema
//! Hasura generates. One registry is built per role; it drives validation,
//! planning and introspection alike.

use std::collections::BTreeMap;

#[derive(Clone, Debug, PartialEq)]
pub enum TypeRef {
    Named(String),
    NonNull(Box<TypeRef>),
    List(Box<TypeRef>),
}

impl TypeRef {
    pub fn named(name: &str) -> TypeRef {
        TypeRef::Named(name.to_string())
    }
    pub fn non_null(inner: TypeRef) -> TypeRef {
        TypeRef::NonNull(Box::new(inner))
    }
    pub fn list(inner: TypeRef) -> TypeRef {
        TypeRef::List(Box::new(inner))
    }
    /// [T!]! — the common Hasura list shape.
    pub fn non_null_list_of_non_null(name: &str) -> TypeRef {
        TypeRef::non_null(TypeRef::list(TypeRef::non_null(TypeRef::named(name))))
    }

    pub fn base_name(&self) -> &str {
        match self {
            TypeRef::Named(n) => n,
            TypeRef::NonNull(inner) | TypeRef::List(inner) => inner.base_name(),
        }
    }

    pub fn is_non_null(&self) -> bool {
        matches!(self, TypeRef::NonNull(_))
    }

    /// Type name as printed in Hasura error messages, e.g. `[User_order_by!]`.
    pub fn display(&self) -> String {
        match self {
            TypeRef::Named(n) => n.clone(),
            TypeRef::NonNull(inner) => format!("{}!", inner.display()),
            TypeRef::List(inner) => format!("[{}]", inner.display()),
        }
    }
}

/// What a field means to the planner/executor.
#[derive(Clone, Debug)]
pub enum FieldKind {
    /// Root list field: `User(...): [User!]!`
    SelectMany { table: String },
    /// Root single-row field: `User_by_pk(id: ...)`
    SelectByPk { table: String },
    /// Root aggregate field: `User_aggregate(...)`
    SelectAggregate { table: String },
    /// Subscription streaming field: `User_stream(...)`
    SelectStream { table: String },
    /// Table column.
    Column { column: String },
    /// Object relationship to another table.
    ObjectRel { rel: String },
    /// Array relationship to another table.
    ArrayRel { rel: String },
    /// Array relationship aggregate: `tokens_aggregate`.
    ArrayRelAggregate { rel: String },
    /// `<T>_aggregate.aggregate`
    AggregateBody,
    /// `<T>_aggregate.nodes`
    AggregateNodes,
    /// `count` inside `<T>_aggregate_fields`
    AggregateCount,
    /// `sum`/`avg`/`min`/... inside `<T>_aggregate_fields`
    AggregateOp { op: String },
    /// A column inside `<T>_<op>_fields`
    AggregateOpColumn { op: String, column: String },
    /// Introspection: `__schema`, `__type`; also meta-object fields.
    Introspection,
}

#[derive(Clone, Debug)]
pub struct InputValueDef {
    pub name: String,
    pub description: Option<String>,
    pub ty: TypeRef,
    /// GraphQL-literal-syntax default value, as introspection prints it.
    pub default_value: Option<String>,
}

impl InputValueDef {
    pub fn new(name: &str, description: Option<&str>, ty: TypeRef) -> InputValueDef {
        InputValueDef {
            name: name.to_string(),
            description: description.map(|s| s.to_string()),
            ty,
            default_value: None,
        }
    }
}

#[derive(Clone, Debug)]
pub struct FieldDef {
    pub name: String,
    pub description: Option<String>,
    pub args: Vec<InputValueDef>,
    pub ty: TypeRef,
    pub kind: FieldKind,
}

#[derive(Clone, Debug)]
pub struct EnumValueDef {
    pub name: String,
    pub description: Option<String>,
}

#[derive(Clone, Debug)]
pub enum TypeDef {
    Scalar {
        name: String,
        description: Option<String>,
    },
    Object {
        name: String,
        description: Option<String>,
        fields: Vec<FieldDef>,
    },
    InputObject {
        name: String,
        description: Option<String>,
        fields: Vec<InputValueDef>,
    },
    Enum {
        name: String,
        description: Option<String>,
        values: Vec<EnumValueDef>,
    },
}

impl TypeDef {
    pub fn name(&self) -> &str {
        match self {
            TypeDef::Scalar { name, .. }
            | TypeDef::Object { name, .. }
            | TypeDef::InputObject { name, .. }
            | TypeDef::Enum { name, .. } => name,
        }
    }

    pub fn field(&self, name: &str) -> Option<&FieldDef> {
        match self {
            TypeDef::Object { fields, .. } => fields.iter().find(|f| f.name == name),
            _ => None,
        }
    }

    pub fn input_field(&self, name: &str) -> Option<&InputValueDef> {
        match self {
            TypeDef::InputObject { fields, .. } => fields.iter().find(|f| f.name == name),
            _ => None,
        }
    }
}

/// A role's full GraphQL schema. Types are kept sorted by name (Hasura's
/// introspection ordering).
pub struct Registry {
    pub types: BTreeMap<String, TypeDef>,
    pub query_root: String,
    pub mutation_root: Option<String>,
    pub subscription_root: String,
}

impl Registry {
    pub fn get(&self, name: &str) -> Option<&TypeDef> {
        self.types.get(name)
    }
}
