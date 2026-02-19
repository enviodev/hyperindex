use crate::{
    constants::reserved_keywords::RESCRIPT_RESERVED_WORDS,
    utils::text::{Capitalize, CapitalizedOptions},
};
use anyhow::{anyhow, Result};
use core::fmt;
use itertools::Itertools;
use serde::Serialize;
use std::{collections::HashSet, fmt::Display};

pub struct TypeDeclMulti(Vec<TypeDecl>);

#[derive(Debug, PartialEq, Clone)]
pub enum SchemaMode {
    ForDb,
    ForFieldSelection,
}

impl TypeDeclMulti {
    pub fn new(type_declarations: Vec<TypeDecl>) -> Self {
        // TODO: validation
        //no duplicates,
        //all named types accounted for? (maybe don't want this)
        //at least 1 decl
        Self(type_declarations)
    }

    pub fn to_rescript_schema(&self, mode: &SchemaMode) -> String {
        let mut sorted: Vec<TypeDecl> = vec![];
        let mut registered: HashSet<String> = HashSet::new();

        let type_decls_with_deps: Vec<(TypeDecl, Vec<String>)> = self
            .0
            .iter()
            .map(|decl| {
                let deps = decl.type_expr.dependencies();
                (decl.clone(), deps)
            })
            .collect();

        // Not the most optimised algorithm, but it's simple and works:
        // Iterate over the type declarations and add them to
        // the sorted list if all their dependencies already added - repeat
        while sorted.len() < type_decls_with_deps.len() {
            for (decl, deps) in &type_decls_with_deps {
                if !registered.contains(&decl.name)
                    && deps.iter().all(|dep| registered.contains(dep))
                {
                    sorted.push(decl.clone());
                    registered.insert(decl.name.clone());
                }
            }
        }

        sorted
            .iter()
            .map(|decl| {
                format!(
                    "let {}Schema = {}",
                    decl.name,
                    decl.to_rescript_schema(&decl.name, mode)
                )
            })
            .collect::<Vec<String>>()
            .join("\n")
    }

    fn to_string_internal(&self) -> String {
        match self.0.as_slice() {
            [single_decl] => single_decl.to_string(),
            multiple_declarations => {
                //mutually recursive definitioin
                let mut tag_prefix = "".to_string();
                let rec_expr = multiple_declarations
                    .iter()
                    .enumerate()
                    .map(|(i, type_decl)| {
                        let inner_tag_prefix = type_decl.get_tag_string_if_expr_is_variant();
                        let prefix = if i != 0 {
                            format!("{}and ", inner_tag_prefix)
                        } else {
                            //set the top level tag prefix for the first item
                            tag_prefix = inner_tag_prefix;
                            "".to_string()
                        };
                        format!("{}{}", prefix, type_decl.to_string_no_type_keyword())
                    })
                    .join("\n ");
                format!(
                    "/*Silence warning of label defined in multiple \
                     types*/\n@@warning(\"-30\")\n{}type rec {}\n@@warning(\"+30\")",
                    tag_prefix, rec_expr
                )
            }
        }
    }
}

impl Display for TypeDeclMulti {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.to_string_internal())
    }
}

#[derive(Debug, PartialEq, Clone)]
pub struct TypeDecl {
    pub name: String,
    pub type_expr: TypeExpr,
    pub parameters: Vec<String>,
}

impl TypeDecl {
    pub fn new(name: String, type_expr: TypeExpr, parameters: Vec<String>) -> Self {
        // TODO: name validation
        //validate unique parameters
        Self {
            name,
            type_expr,
            parameters,
        }
    }

    fn get_tag_string_if_expr_is_variant(&self) -> String {
        if let TypeExpr::Variant(_) = self.type_expr {
            "@tag(\"case\") ".to_string()
        } else {
            "".to_string()
        }
    }

    fn to_string_no_type_keyword(&self) -> String {
        let parameters = if self.parameters.is_empty() {
            "".to_string()
        } else {
            // Lowercase generic params because of the issue https://github.com/rescript-lang/rescript-compiler/issues/6759
            let param_names_joined = self
                .parameters
                .iter()
                .map(|p| format!("'{}", p.to_lowercase()))
                .join(", ");
            format!("<{param_names_joined}>")
        };
        format!(
            "{type_name}{parameters} = {type_expr}",
            type_name = &self.name,
            type_expr = self.type_expr
        )
    }

    fn to_string_internal(&self) -> String {
        format!(
            "{}type {}",
            self.get_tag_string_if_expr_is_variant(),
            self.to_string_no_type_keyword(),
        )
    }

    pub fn to_rescript_schema(&self, type_name: &String, mode: &SchemaMode) -> String {
        if self.parameters.is_empty() {
            self.type_expr.to_rescript_schema(type_name, mode)
        } else {
            let params = self
                .parameters
                .iter()
                .map(|param| format!("_{param}Schema: S.t<'{param}>"))
                .collect::<Vec<String>>()
                .join(", ");
            let type_name = format!(
                "{type_name}<{}>",
                self.parameters
                    .iter()
                    .map(|param| format!("'{}", param))
                    .join(", ")
            );
            format!(
                "({}) => {}",
                params,
                self.type_expr.to_rescript_schema(&type_name, mode)
            )
        }
    }

    pub fn to_usage(&self, arguments: Vec<String>) -> Result<String> {
        if self.parameters.len() != arguments.len() {
            Err(anyhow!(
                "Failed to use type {}. The number of arguments is different from number of \
                 parameters.",
                self.name
            ))?
        }
        let arguments_code = if arguments.is_empty() {
            "".to_string()
        } else {
            // Lowercase generic params because of the issue https://github.com/rescript-lang/rescript-compiler/issues/6759
            let args_joined = arguments.join(", ");
            format!("<{args_joined}>")
        };
        Ok(format!("{}{arguments_code}", &self.name))
    }
}

impl Display for TypeDecl {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.to_string_internal())
    }
}

#[derive(Debug, PartialEq, Clone)]
pub enum TypeExpr {
    Identifier(TypeIdent),
    Record(Vec<RecordField>),
    Variant(Vec<VariantConstr>),
}

impl Display for TypeExpr {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.to_string_internal())
    }
}

impl TypeExpr {
    fn to_string_internal(&self) -> String {
        match self {
            Self::Identifier(type_ident) => type_ident.to_string(),
            Self::Record(params) => {
                let params_str = params.iter().map(|p| p.to_string()).join(", ");
                format!("{{{params_str}}}")
            }
            Self::Variant(constructors) => constructors
                .iter()
                .map(|constr| {
                    let constr_name = &constr.name;
                    let constr_payload = constr.payload.to_string();
                    format!("| {constr_name}({{payload: {constr_payload}}})")
                })
                .join(" "),
        }
    }

    pub fn to_rescript_schema(&self, type_name: &String, mode: &SchemaMode) -> String {
        match self {
            Self::Identifier(type_ident) => type_ident.to_rescript_schema(mode),
            Self::Variant(items) => {
                let item_schemas = items
                    .iter()
                    .map(|item| {
                        format!(
                            r#"S.object((s): {type_name} =>
{{
  s.tag("case", "{}")
  {}({{payload: s.field("payload", {})}})
}})"#,
                            item.name,
                            item.name,
                            item.payload.to_rescript_schema(mode)
                        )
                    })
                    .collect::<Vec<String>>()
                    .join(", ");
                format!("S.union([{}])", item_schemas)
            }
            Self::Record(fields) => {
                if fields.is_empty() {
                    format!("S.object((_): {} => {{}})", type_name)
                } else {
                    let inner_str = fields
                        .iter()
                        .map(|field| {
                            format!(
                                "{}: s.field(\"{}\", {})",
                                &field.name,
                                // For raw events we keep the ReScript name,
                                // if we need to serialize to the original name,
                                // then it'll require a flag in the args
                                field
                                    .as_name
                                    .as_ref()
                                    .map_or(field.name.as_str(), |name| name.as_str()),
                                field.type_ident.to_rescript_schema(mode)
                            )
                        })
                        .collect::<Vec<String>>()
                        .join(", ");
                    format!("S.object((s): {type_name} => {{{inner_str}}})")
                }
            }
        }
    }

    pub fn to_ts_type_string(&self) -> String {
        match self {
            Self::Identifier(type_ident) => type_ident.to_ts_type_string(),
            Self::Record(fields) => {
                if fields.is_empty() {
                    "{}".to_string()
                } else {
                    let fields_str = fields
                        .iter()
                        .map(|field| {
                            let field_name = field
                                .as_name
                                .as_ref()
                                .map_or(field.name.as_str(), |name| name.as_str());
                            format!("{}: {}", field_name, field.type_ident.to_ts_type_string())
                        })
                        .collect::<Vec<String>>()
                        .join("; ");
                    format!("{{ {} }}", fields_str)
                }
            }
            Self::Variant(constructors) => constructors
                .iter()
                .map(|constr| {
                    format!(
                        "{{ case: \"{}\"; payload: {} }}",
                        constr.name,
                        constr.payload.to_ts_type_string()
                    )
                })
                .collect::<Vec<String>>()
                .join(" | "),
        }
    }

    pub fn dependencies(&self) -> Vec<String> {
        match self {
            Self::Identifier(type_ident) => type_ident.dependencies(),
            Self::Variant(items) => items
                .iter()
                .flat_map(|item| item.payload.dependencies())
                .collect(),
            Self::Record(fields) => fields
                .iter()
                .flat_map(|field| field.type_ident.dependencies())
                .collect(),
        }
    }
}

#[derive(Debug, PartialEq, Clone)]
pub struct RecordField {
    pub name: String,
    pub as_name: Option<String>,
    pub type_ident: TypeIdent,
}

impl RecordField {
    pub fn to_valid_rescript_name(s: &str) -> String {
        if s.is_empty() {
            return "_".to_string();
        }

        let first_char = s.chars().next().unwrap();
        if let '0'..='9' = first_char {
            return format!("_{}", s);
        }

        let uncapitalized = s.to_string().uncapitalize();
        if RESCRIPT_RESERVED_WORDS.contains(&uncapitalized.as_str()) {
            format!("{}_", uncapitalized)
        } else {
            uncapitalized
        }
    }

    pub fn new(name: String, type_ident: TypeIdent) -> Self {
        let res_name = Self::to_valid_rescript_name(&name);
        Self {
            as_name: if res_name == name { None } else { Some(name) },
            name: res_name,
            type_ident,
        }
    }

    fn to_string_internal(&self) -> String {
        let as_prefix = self
            .as_name
            .clone()
            .map_or("".to_string(), |s| format!("@as(\"{s}\") "));
        format!("{}{}: {}", as_prefix, self.name, self.type_ident)
    }
}

impl Display for RecordField {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.to_string_internal())
    }
}

#[derive(Debug, PartialEq, Clone)]
pub struct VariantConstr {
    pub name: String,
    pub payload: TypeIdent, //Not supporting records here but tuples are currently part of
                            //TypeIdent
}

impl VariantConstr {
    pub fn new(name: String, payload: TypeIdent) -> Self {
        // TODO: validate uppercase name
        Self { name, payload }
    }
}

#[derive(Debug, PartialEq, Clone, Eq, Hash)]
pub enum TypeIdent {
    Unit,
    ID,
    Int,
    Float,
    BigInt,
    BigDecimal,
    Address,
    String,
    Json,
    Bool,
    Unknown,
    Timestamp,
    //Enums defined in the user's schema
    SchemaEnum(CapitalizedOptions),
    Array(Box<TypeIdent>),
    Option(Box<TypeIdent>),
    //Note: tuple is technically an expression not an identifier
    //but it can be inlined and can contain inline tuples in it's parameters
    //so it's best suited here for its purpose
    Tuple(Vec<TypeIdent>),
    GenericParam(String),
    TypeApplication {
        name: String,
        type_params: Vec<TypeIdent>,
    },
}

impl TypeIdent {
    //Simply an ergonomic shorthand
    pub fn get_expr(self) -> TypeExpr {
        TypeExpr::Identifier(self)
    }

    //Simply an ergonomic shorthand
    pub fn get_ok_expr(self) -> anyhow::Result<TypeExpr> {
        Ok(self.get_expr())
    }

    /// Recursively builds the ReScript string representation of the type
    fn to_string_internal(&self) -> String {
        match self {
            Self::Unit => "unit".to_string(),
            Self::Int => "int".to_string(),
            Self::Float => "float".to_string(),
            Self::BigInt => "bigint".to_string(),
            Self::Unknown => "unknown".to_string(),
            Self::BigDecimal => "BigDecimal.t".to_string(),
            Self::Address => "Address.t".to_string(),
            Self::String => "string".to_string(),
            Self::Json => "Js.Json.t".to_string(),
            Self::ID => "id".to_string(),
            Self::Bool => "bool".to_string(),
            Self::Timestamp => "Js.Date.t".to_string(),
            Self::Array(inner_type) => {
                format!("array<{}>", inner_type)
            }
            Self::Option(inner_type) => {
                format!("option<{}>", inner_type)
            }
            Self::Tuple(inner_types) => {
                let inner_types_str = inner_types
                    .iter()
                    .map(|inner_type| inner_type.to_string())
                    .collect::<Vec<String>>()
                    .join(", ");
                format!("({})", inner_types_str)
            }
            Self::SchemaEnum(enum_name) => {
                format!("Enums.{}.t", &enum_name.capitalized)
            }
            // Lowercase generic params because of the issue https://github.com/rescript-lang/rescript-compiler/issues/6759
            Self::GenericParam(name) => format!("'{}", name.to_lowercase()),
            Self::TypeApplication {
                name,
                type_params: params,
            } => {
                if params.is_empty() {
                    name.clone()
                } else {
                    let params_joined = params
                        .iter()
                        .map(|p| p.to_string().uncapitalize())
                        .join(", ");
                    format!("{name}<{params_joined}>")
                }
            }
        }
    }

    /// Recursively builds the TypeScript string representation of the type
    pub fn to_ts_type_string(&self) -> String {
        match self {
            Self::Unit => "undefined".to_string(),
            Self::Int => "number".to_string(),
            Self::Float => "number".to_string(),
            Self::BigInt => "bigint".to_string(),
            Self::Unknown => "unknown".to_string(),
            Self::BigDecimal => "BigDecimal".to_string(),
            Self::Address => "Address".to_string(),
            Self::String => "string".to_string(),
            Self::Json => "unknown".to_string(),
            Self::ID => "string".to_string(),
            Self::Bool => "boolean".to_string(),
            Self::Timestamp => "Date".to_string(),
            Self::Array(inner_type) => {
                let inner_ts = inner_type.to_ts_type_string();
                // Wrap in parens if the inner type is a union (Option generates union)
                if inner_type.is_option() {
                    format!("readonly ({})[]", inner_ts)
                } else {
                    format!("readonly {}[]", inner_ts)
                }
            }
            Self::Option(inner_type) => {
                format!("{} | undefined", inner_type.to_ts_type_string())
            }
            Self::Tuple(inner_types) => {
                let inner_types_str = inner_types
                    .iter()
                    .map(|inner_type| inner_type.to_ts_type_string())
                    .collect::<Vec<String>>()
                    .join(", ");
                format!("[{}]", inner_types_str)
            }
            Self::SchemaEnum(enum_name) => {
                format!("Enums[\"{}\"]", &enum_name.original)
            }
            Self::GenericParam(name) => name.clone(),
            Self::TypeApplication {
                name,
                type_params: params,
            } => {
                if params.is_empty() {
                    name.clone()
                } else {
                    let params_joined = params
                        .iter()
                        .map(|p| p.to_ts_type_string())
                        .join(", ");
                    format!("{name}<{params_joined}>")
                }
            }
        }
    }

    pub fn to_rescript_schema(&self, mode: &SchemaMode) -> String {
        match self {
            Self::Unit => "S.literal(%raw(`null`))->S.shape(_ => ())".to_string(),
            Self::Int => "S.int".to_string(),
            Self::Unknown => "S.unknown".to_string(),
            Self::Float => "S.float".to_string(),
            Self::BigInt => match mode {
                SchemaMode::ForDb => "Utils.BigInt.schema".to_string(),
                SchemaMode::ForFieldSelection => "Utils.BigInt.nativeSchema".to_string(),
            },
            Self::BigDecimal => "BigDecimal.schema".to_string(),
            Self::Address => "Address.schema".to_string(),
            Self::String => "S.string".to_string(),
            Self::Json => "S.json(~validate=false)".to_string(),
            Self::ID => "S.string".to_string(),
            Self::Bool => "S.bool".to_string(),
            Self::Timestamp => "Utils.Schema.dbDate".to_string(),
            Self::Array(inner_type) => {
                format!("S.array({})", inner_type.to_rescript_schema(mode))
            }
            Self::Option(inner_type) => {
                let schema = match mode {
                    SchemaMode::ForDb => "S.null".to_string(),
                    SchemaMode::ForFieldSelection => "S.nullable".to_string(),
                };
                format!("{schema}({})", inner_type.to_rescript_schema(mode))
            }
            Self::Tuple(inner_types) => {
                let inner_str = inner_types
                    .iter()
                    .enumerate()
                    .map(|(index, inner_type)| {
                        format!("s.item({index}, {})", inner_type.to_rescript_schema(mode))
                    })
                    .collect::<Vec<String>>()
                    .join(", ");
                format!("S.tuple(s => ({}))", inner_str)
            }
            Self::SchemaEnum(enum_name) => {
                format!("Enums.{}.config.schema", &enum_name.capitalized)
            }
            // TODO: ensure these are defined
            Self::GenericParam(name) => {
                format!("_{name}Schema")
            }
            Self::TypeApplication { name, type_params } if type_params.is_empty() => {
                format!("{name}Schema")
            }
            Self::TypeApplication {
                name,
                type_params: params,
            } => {
                let param_schemas_joined =
                    params.iter().map(|p| p.to_rescript_schema(mode)).join(", ");
                format!("{name}Schema({param_schemas_joined})")
            }
        }
    }

    pub fn dependencies(&self) -> Vec<String> {
        match self {
            Self::Unit
            | Self::Int
            | Self::Float
            | Self::BigInt
            | Self::BigDecimal
            | Self::Address
            | Self::String
            | Self::Unknown
            | Self::ID
            | Self::Bool
            | Self::Timestamp
            | Self::Json
            | Self::SchemaEnum(_)
            | Self::GenericParam(_) => vec![],
            Self::TypeApplication {
                name, type_params, ..
            } => {
                let mut deps = vec![name.clone()];
                for param in type_params {
                    deps.extend(param.dependencies());
                }
                deps
            }
            Self::Array(inner_type) | Self::Option(inner_type) => inner_type.dependencies(),
            Self::Tuple(inner_types) => inner_types
                .iter()
                .flat_map(|inner_type| inner_type.dependencies())
                .collect(),
        }
    }

    pub fn get_default_value_rescript(&self) -> String {
        match self {
            Self::Unit => "()".to_string(),
            Self::Int => "0".to_string(),
            Self::Unknown => "%raw(`undefined`)".to_string(),
            Self::Float => "0.0".to_string(),
            Self::BigInt => "0n".to_string(),
            Self::Json => "%raw(`{}`)".to_string(),
            Self::BigDecimal => "BigDecimal.zero".to_string(),
            Self::Address => "TestHelpers_MockAddresses.defaultAddress".to_string(),
            Self::String => "\"foo\"".to_string(),
            Self::ID => "\"my_id\"".to_string(),
            Self::Bool => "false".to_string(),
            Self::Timestamp => "Js.Date.fromFloat(0.)".to_string(),
            Self::Array(_) => "[]".to_string(),
            Self::Option(_) => "None".to_string(),
            Self::SchemaEnum(enum_name) => {
                format!("Enums.{}.default", &enum_name.capitalized)
            }
            Self::Tuple(inner_types) => {
                let inner_types_str = inner_types
                    .iter()
                    .map(|inner_type| inner_type.get_default_value_rescript())
                    .collect::<Vec<String>>()
                    .join(", ");

                format!("({})", inner_types_str)
            }
            // TODO: ensure these are defined
            Self::GenericParam(name) => {
                format!("{name}Default")
            }
            Self::TypeApplication { name, type_params } if type_params.is_empty() => {
                format!("{name}Default")
            }
            Self::TypeApplication {
                name,
                type_params: params,
            } => {
                let generics_defaults = params
                    .iter()
                    .filter_map(|p| {
                        if let Self::GenericParam(_) = p {
                            Some(p.get_default_value_rescript())
                        } else {
                            None
                        }
                    })
                    .join(", ");

                let param_defaults_joined = params
                    .iter()
                    .map(|p| p.get_default_value_rescript())
                    .join(", ");

                let default_composed = format!("make{name}Default({param_defaults_joined})");
                if generics_defaults.is_empty() {
                    default_composed
                } else {
                    //if some parameters are generic return a function that takes schemas of those
                    //parameters
                    format!("({generics_defaults}) => {default_composed}")
                }
            }
        }
    }

    pub fn get_default_value_non_rescript(&self) -> String {
        match self {
            Self::Unit | Self::Unknown => "undefined".to_string(),
            Self::Int | Self::Float => "0".to_string(),
            Self::Json => "{}".to_string(),
            Self::BigInt => "0n".to_string(),
            Self::BigDecimal => "// default value not required since BigDecimal doesn't exist on \
                                 contracts for contract import"
                .to_string(),
            Self::Address => "Addresses.defaultAddress".to_string(),
            Self::String => "\"foo\"".to_string(),
            Self::ID => "\"my_id\"".to_string(),
            Self::Bool => "false".to_string(),
            Self::Timestamp => "new Date(0)".to_string(),
            Self::Array(_) => "[]".to_string(),
            Self::Option(_) => "null".to_string(),
            Self::SchemaEnum(enum_name) => {
                format!("{}Default", &enum_name.uncapitalized)
            }
            Self::Tuple(inner_types) => {
                let inner_types_str = inner_types
                    .iter()
                    .map(|inner_type| inner_type.get_default_value_non_rescript())
                    .join(", ");
                format!("[{}]", inner_types_str)
            }
            // TODO: ensure these are defined
            Self::GenericParam(name) => {
                format!("{name}Default")
            }
            Self::TypeApplication { name, type_params } if type_params.is_empty() => {
                format!("{name}Default")
            }
            Self::TypeApplication {
                name,
                type_params: params,
            } => {
                let generics_defaults = params
                    .iter()
                    .filter_map(|p| {
                        if let Self::GenericParam(_) = p {
                            Some(p.get_default_value_non_rescript())
                        } else {
                            None
                        }
                    })
                    .join(", ");

                let param_defaults_joined = params
                    .iter()
                    .map(|p| p.get_default_value_non_rescript())
                    .join(", ");

                let default_composed = format!("make{name}Default({param_defaults_joined})");
                if generics_defaults.is_empty() {
                    default_composed
                } else {
                    //if some parameters are generic return a function that takes schemas of those
                    //parameters
                    format!("({generics_defaults}) => {default_composed}")
                }
            }
        }
    }

    pub fn is_option(&self) -> bool {
        matches!(self, Self::Option(_))
    }

    pub fn option(inner_type: Self) -> Self {
        Self::Option(Box::new(inner_type))
    }

    pub fn array(inner_type: Self) -> Self {
        Self::Array(Box::new(inner_type))
    }
}

impl Display for TypeIdent {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.to_string_internal())
    }
}

///Implementation of Serialize allows handlebars get a stringified
///version of the string representation of the rescript type
impl Serialize for TypeIdent {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        // Serialize as display value
        self.to_string().serialize(serializer)
    }
}

#[cfg(test)]
mod tests {
    use std::vec;

    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn test_to_rescript_schema() {
        assert_eq!(
            TypeExpr::Identifier(TypeIdent::Bool)
                .to_rescript_schema(&"eventArgs".to_string(), &SchemaMode::ForDb),
            "S.bool".to_string()
        );
        assert_eq!(
            TypeExpr::Identifier(TypeIdent::Int)
                .to_rescript_schema(&"eventArgs".to_string(), &SchemaMode::ForDb),
            "S.int".to_string()
        );
        assert_eq!(
            TypeExpr::Identifier(TypeIdent::Float)
                .to_rescript_schema(&"eventArgs".to_string(), &SchemaMode::ForDb),
            "S.float".to_string()
        );
        assert_eq!(
            TypeExpr::Identifier(TypeIdent::Unit)
                .to_rescript_schema(&"eventArgs".to_string(), &SchemaMode::ForDb),
            "S.literal(%raw(`null`))->S.shape(_ => ())".to_string()
        );
        assert_eq!(
            TypeExpr::Identifier(TypeIdent::BigInt)
                .to_rescript_schema(&"eventArgs".to_string(), &SchemaMode::ForDb),
            "Utils.BigInt.schema".to_string()
        );
        assert_eq!(
            TypeExpr::Identifier(TypeIdent::BigInt).to_rescript_schema(
                &"eventArgs".to_string(),
                &SchemaMode::ForFieldSelection
            ),
            "Utils.BigInt.nativeSchema".to_string()
        );
        assert_eq!(
            TypeExpr::Identifier(TypeIdent::BigDecimal)
                .to_rescript_schema(&"eventArgs".to_string(), &SchemaMode::ForDb),
            "BigDecimal.schema".to_string()
        );
        assert_eq!(
            TypeExpr::Identifier(TypeIdent::Address)
                .to_rescript_schema(&"eventArgs".to_string(), &SchemaMode::ForDb),
            "Address.schema".to_string()
        );
        assert_eq!(
            TypeExpr::Identifier(TypeIdent::String)
                .to_rescript_schema(&"eventArgs".to_string(), &SchemaMode::ForDb),
            "S.string".to_string()
        );
        assert_eq!(
            TypeExpr::Identifier(TypeIdent::ID)
                .to_rescript_schema(&"eventArgs".to_string(), &SchemaMode::ForDb),
            "S.string".to_string()
        );
        assert_eq!(
            TypeExpr::Identifier(TypeIdent::array(TypeIdent::Int))
                .to_rescript_schema(&"eventArgs".to_string(), &SchemaMode::ForDb),
            "S.array(S.int)".to_string()
        );
        assert_eq!(
            TypeExpr::Identifier(TypeIdent::option(TypeIdent::BigInt))
                .to_rescript_schema(&"eventArgs".to_string(), &SchemaMode::ForDb),
            "S.null(Utils.BigInt.schema)".to_string()
        );
        assert_eq!(
            TypeExpr::Identifier(TypeIdent::option(TypeIdent::BigInt))
                .to_rescript_schema(&"eventArgs".to_string(), &SchemaMode::ForFieldSelection),
            "S.nullable(Utils.BigInt.nativeSchema)".to_string()
        );
        assert_eq!(
            TypeExpr::Identifier(TypeIdent::Tuple(vec![TypeIdent::Int, TypeIdent::Bool]))
                .to_rescript_schema(&"eventArgs".to_string(), &SchemaMode::ForDb),
            "S.tuple(s => (s.item(0, S.int), s.item(1, S.bool)))".to_string()
        );
        assert_eq!(
            TypeExpr::Variant(vec![
                VariantConstr::new("ConstrA".to_string(), TypeIdent::Int),
                VariantConstr::new("ConstrB".to_string(), TypeIdent::Bool),
            ])
            .to_rescript_schema(&"eventArgs".to_string(), &SchemaMode::ForDb),
            r#"S.union([S.object((s): eventArgs =>
{
  s.tag("case", "ConstrA")
  ConstrA({payload: s.field("payload", S.int)})
}), S.object((s): eventArgs =>
{
  s.tag("case", "ConstrB")
  ConstrB({payload: s.field("payload", S.bool)})
})])"#
                .to_string()
        );
        assert_eq!(
            TypeExpr::Record(vec![
                RecordField::new("fieldA".to_string(), TypeIdent::Int),
                RecordField::new("fieldB".to_string(), TypeIdent::Bool),
            ])
            .to_rescript_schema(&"eventArgs".to_string(), &SchemaMode::ForDb),
            "S.object((s): eventArgs => {fieldA: s.field(\"fieldA\", S.int), fieldB: \
             s.field(\"fieldB\", S.bool)})"
                .to_string()
        );
        assert_eq!(
            TypeExpr::Record(vec![])
                .to_rescript_schema(&"eventArgs".to_string(), &SchemaMode::ForDb),
            "S.object((_): eventArgs => {})".to_string()
        );
    }

    #[test]
    fn type_decl_to_string_primitive() {
        let type_decl = TypeDecl {
            name: "myBool".to_string(),
            type_expr: TypeExpr::Identifier(TypeIdent::Bool),
            parameters: vec![],
        };

        let expected = "type myBool = bool".to_string();

        assert_eq!(type_decl.to_string(), expected);
    }

    #[test]
    fn type_decl_to_string_named_ident() {
        let type_decl = TypeDecl {
            name: "myAlias".to_string(),
            type_expr: TypeExpr::Identifier(TypeIdent::TypeApplication {
                name: "myCustomType".to_string(),
                type_params: vec![],
            }),
            parameters: vec![],
        };

        let expected = "type myAlias = myCustomType".to_string();

        assert_eq!(type_decl.to_string(), expected);
    }

    #[test]
    fn type_decl_to_string_record() {
        let type_decl = TypeDecl::new(
            "myRecord".to_string(),
            TypeExpr::Record(vec![
                RecordField {
                    name: "reservedWord_".to_string(),
                    as_name: Some("reservedWord".to_string()),
                    type_ident: TypeIdent::TypeApplication {
                        name: "myCustomType".to_string(),
                        type_params: vec![],
                    },
                },
                RecordField::new(
                    "myOptBool".to_string(),
                    TypeIdent::option(TypeIdent::Bool),
                ),
            ]),
            vec![],
        );

        let expected = r#"type myRecord = {@as("reservedWord") reservedWord_: myCustomType, myOptBool: option<bool>}"#.to_string();

        assert_eq!(type_decl.to_string(), expected);
    }

    #[test]
    fn type_decl_with_invalid_rescript_field_names_to_string_record() {
        let type_decl = TypeDecl::new(
            "myRecord".to_string(),
            TypeExpr::Record(vec![
                RecordField::new("module".to_string(), TypeIdent::Bool),
                RecordField::new("".to_string(), TypeIdent::Bool),
                RecordField::new("1".to_string(), TypeIdent::Bool),
                RecordField::new("Capitalized".to_string(), TypeIdent::Bool),
                // Invalid characters in the middle are not handled correctly. Still keep the test to pin the behaviour.
                RecordField::new("dashed-field".to_string(), TypeIdent::Bool),
            ]),
            vec![],
        );

        let expected = r#"type myRecord = {@as("module") module_: bool, @as("") _: bool, @as("1") _1: bool, @as("Capitalized") capitalized: bool, dashed-field: bool}"#.to_string();

        assert_eq!(type_decl.to_string(), expected);
    }

    #[test]
    fn type_decl_multi_to_string() {
        let type_decl_1 = TypeDecl::new(
            "myRecord".to_string(),
            TypeExpr::Record(vec![
                RecordField::new(
                    "fieldA".to_string(),
                    TypeIdent::TypeApplication {
                        name: "myCustomType".to_string(),
                        type_params: vec![],
                    },
                ),
                RecordField::new("fieldB".to_string(), TypeIdent::Bool),
            ]),
            vec![],
        );

        let type_decl_2 = TypeDecl::new(
            "myCustomType".to_string(),
            TypeExpr::Identifier(TypeIdent::Bool),
            vec![],
        );

        let type_decl_multi = TypeDeclMulti::new(vec![type_decl_1, type_decl_2]);

        let expected = "/*Silence warning of label defined in multiple \
                        types*/\n@@warning(\"-30\")\ntype rec myRecord = {fieldA: myCustomType, \
                        fieldB: bool}\n and myCustomType = bool\n@@warning(\"+30\")"
            .to_string();

        assert_eq!(type_decl_multi.to_string(), expected);
    }

    #[test]
    fn type_decl_to_string_record_generic() {
        let my_custom_type_ident = TypeIdent::TypeApplication {
            name: "myCustomType".to_string(),
            type_params: vec![],
        };
        let type_decl = TypeDecl::new(
            "myRecord".to_string(),
            TypeExpr::Record(vec![
                RecordField::new("fieldA".to_string(), my_custom_type_ident.clone()),
                RecordField::new(
                    "fieldB".to_string(),
                    TypeIdent::TypeApplication {
                        name: "myGenericType".to_string(),
                        type_params: vec![
                            my_custom_type_ident.clone(),
                            TypeIdent::GenericParam("a".to_string()),
                        ],
                    },
                ),
                RecordField::new(
                    "fieldC".to_string(),
                    TypeIdent::GenericParam("b".to_string()),
                ),
            ]),
            vec!["a".to_string(), "b".to_string()],
        );

        let expected = r#"type myRecord<'a, 'b> = {fieldA: myCustomType, fieldB: myGenericType<myCustomType, 'a>, fieldC: 'b}"#.to_string();

        assert_eq!(type_decl.to_string(), expected);
    }

    #[test]
    fn type_decl_to_string_variant() {
        let my_custom_type_ident = TypeIdent::TypeApplication {
            name: "myCustomType".to_string(),
            type_params: vec![],
        };
        let type_decl = TypeDecl::new(
            "myVariant".to_string(),
            TypeExpr::Variant(vec![
                VariantConstr::new("ConstrA".to_string(), my_custom_type_ident.clone()),
                VariantConstr::new(
                    "ConstrB".to_string(),
                    TypeIdent::TypeApplication {
                        name: "myGenericType".to_string(),
                        type_params: vec![
                            my_custom_type_ident.clone(),
                            TypeIdent::GenericParam("a".to_string()),
                        ],
                    },
                ),
                VariantConstr::new(
                    "ConstrC".to_string(),
                    TypeIdent::GenericParam("b".to_string()),
                ),
            ]),
            vec!["a".to_string(), "b".to_string()],
        );

        let expected = r#"@tag("case") type myVariant<'a, 'b> = | ConstrA({payload: myCustomType}) | ConstrB({payload: myGenericType<myCustomType, 'a>}) | ConstrC({payload: 'b})"#.to_string();

        assert_eq!(type_decl.to_string(), expected);
    }

    #[test]
    fn type_decl_multi_variant_to_string() {
        let my_custom_type_ident = TypeIdent::TypeApplication {
            name: "myCustomType".to_string(),
            type_params: vec![],
        };
        let type_decl_1 = TypeDecl::new(
            "myVariant".to_string(),
            TypeExpr::Variant(vec![
                VariantConstr::new("ConstrA".to_string(), my_custom_type_ident.clone()),
                VariantConstr::new(
                    "ConstrB".to_string(),
                    TypeIdent::GenericParam("a".to_string()),
                ),
            ]),
            vec!["a".to_string()],
        );

        let type_decl_2 = TypeDecl::new(
            "myCustomType".to_string(),
            TypeExpr::Identifier(TypeIdent::Bool),
            vec![],
        );

        let type_decl_3 = TypeDecl::new(
            "myVariant2".to_string(),
            TypeExpr::Variant(vec![VariantConstr::new(
                "ConstrC".to_string(),
                TypeIdent::Bool,
            )]),
            vec![],
        );

        let type_decl_multi =
            TypeDeclMulti::new(vec![type_decl_1, type_decl_2, type_decl_3]);

        let expected = "/*Silence warning of label defined in multiple \
                        types*/\n@@warning(\"-30\")\n@tag(\"case\") type rec myVariant<'a> = | \
                        ConstrA({payload: myCustomType}) | ConstrB({payload: 'a})\n and \
                        myCustomType = bool\n @tag(\"case\") and myVariant2 = | ConstrC({payload: \
                        bool})\n@@warning(\"+30\")"
            .to_string();

        assert_eq!(type_decl_multi.to_string(), expected);
    }

    #[test]
    fn test_recursive_type_application_dependencies() {
        let type19 = TypeIdent::TypeApplication {
            name: "type19".to_string(),
            type_params: vec![TypeIdent::TypeApplication {
                name: "type18".to_string(),
                type_params: vec![TypeIdent::TypeApplication {
                    name: "type17".to_string(),
                    type_params: vec![],
                }],
            }],
        };

        let deps = type19.dependencies();

        assert_eq!(
            deps,
            vec![
                "type19".to_string(),
                "type18".to_string(),
                "type17".to_string()
            ]
        );
    }

    // TypeScript type string tests

    #[test]
    fn test_to_ts_type_string_primitives() {
        assert_eq!(TypeIdent::Unit.to_ts_type_string(), "undefined");
        assert_eq!(TypeIdent::Int.to_ts_type_string(), "number");
        assert_eq!(TypeIdent::Float.to_ts_type_string(), "number");
        assert_eq!(TypeIdent::BigInt.to_ts_type_string(), "bigint");
        assert_eq!(TypeIdent::BigDecimal.to_ts_type_string(), "BigDecimal");
        assert_eq!(TypeIdent::Address.to_ts_type_string(), "Address");
        assert_eq!(TypeIdent::String.to_ts_type_string(), "string");
        assert_eq!(TypeIdent::Json.to_ts_type_string(), "unknown");
        assert_eq!(TypeIdent::ID.to_ts_type_string(), "string");
        assert_eq!(TypeIdent::Bool.to_ts_type_string(), "boolean");
        assert_eq!(TypeIdent::Unknown.to_ts_type_string(), "unknown");
        assert_eq!(TypeIdent::Timestamp.to_ts_type_string(), "Date");
    }

    #[test]
    fn test_to_ts_type_string_containers() {
        assert_eq!(
            TypeIdent::array(TypeIdent::Int).to_ts_type_string(),
            "readonly number[]"
        );
        assert_eq!(
            TypeIdent::option(TypeIdent::String).to_ts_type_string(),
            "string | undefined"
        );
        assert_eq!(
            TypeIdent::Tuple(vec![TypeIdent::Int, TypeIdent::Bool]).to_ts_type_string(),
            "[number, boolean]"
        );
        // Nested containers
        assert_eq!(
            TypeIdent::array(TypeIdent::option(TypeIdent::Int)).to_ts_type_string(),
            "readonly (number | undefined)[]"
        );
    }

    #[test]
    fn test_to_ts_type_string_schema_enum() {
        let enum_name = CapitalizedOptions {
            capitalized: "MyEnum".to_string(),
            uncapitalized: "myEnum".to_string(),
            original: "MyEnum".to_string(),
        };
        assert_eq!(
            TypeIdent::SchemaEnum(enum_name).to_ts_type_string(),
            "Enums[\"MyEnum\"]"
        );
    }

    #[test]
    fn test_to_ts_type_string_generic_param() {
        assert_eq!(
            TypeIdent::GenericParam("T".to_string()).to_ts_type_string(),
            "T"
        );
    }

    #[test]
    fn test_to_ts_type_string_type_application() {
        assert_eq!(
            TypeIdent::TypeApplication {
                name: "MyType".to_string(),
                type_params: vec![],
            }
            .to_ts_type_string(),
            "MyType"
        );
        assert_eq!(
            TypeIdent::TypeApplication {
                name: "MyGeneric".to_string(),
                type_params: vec![TypeIdent::Int, TypeIdent::String],
            }
            .to_ts_type_string(),
            "MyGeneric<number, string>"
        );
    }

    #[test]
    fn test_to_ts_type_string_record_expr() {
        assert_eq!(TypeExpr::Record(vec![]).to_ts_type_string(), "{}");
        assert_eq!(
            TypeExpr::Record(vec![
                RecordField::new("fieldA".to_string(), TypeIdent::Int),
                RecordField::new("fieldB".to_string(), TypeIdent::Bool),
            ])
            .to_ts_type_string(),
            "{ fieldA: number; fieldB: boolean }"
        );
    }

    #[test]
    fn test_to_ts_type_string_variant_expr() {
        assert_eq!(
            TypeExpr::Variant(vec![
                VariantConstr::new("ConstrA".to_string(), TypeIdent::Int),
                VariantConstr::new("ConstrB".to_string(), TypeIdent::Bool),
            ])
            .to_ts_type_string(),
            "{ case: \"ConstrA\"; payload: number } | { case: \"ConstrB\"; payload: boolean }"
        );
    }

    #[test]
    fn test_to_ts_type_string_identifier_expr() {
        assert_eq!(
            TypeExpr::Identifier(TypeIdent::Int).to_ts_type_string(),
            "number"
        );
    }
}
