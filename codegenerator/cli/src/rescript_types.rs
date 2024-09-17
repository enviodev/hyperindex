use crate::{
    constants::reserved_keywords::RESCRIPT_RESERVED_WORDS,
    utils::text::{Capitalize, CapitalizedOptions},
};
use anyhow::{anyhow, Result};
use core::fmt;
use itertools::Itertools;
use serde::Serialize;
use std::{collections::HashSet, fmt::Display};

pub struct RescriptTypeDeclMulti(Vec<RescriptTypeDecl>);

impl RescriptTypeDeclMulti {
    pub fn new(type_declarations: Vec<RescriptTypeDecl>) -> Self {
        // TODO: validation
        //no duplicates,
        //all named types accounted for? (maybe don't want this)
        //at least 1 decl
        Self(type_declarations)
    }

    pub fn to_rescript_schema(&self) -> String {
        let mut sorted: Vec<RescriptTypeDecl> = vec![];
        let mut registered: HashSet<String> = HashSet::new();

        let type_decls_with_deps: Vec<(RescriptTypeDecl, Vec<String>)> = self
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
                    decl.to_rescript_schema(&decl.name)
                )
            })
            .collect::<Vec<String>>()
            .join("\n")
    }

    pub fn to_string(&self) -> String {
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

#[derive(Debug, PartialEq, Clone)]
pub struct RescriptTypeDecl {
    pub name: String,
    pub type_expr: RescriptTypeExpr,
    pub parameters: Vec<String>,
}

impl RescriptTypeDecl {
    pub fn new(name: String, type_expr: RescriptTypeExpr, parameters: Vec<String>) -> Self {
        // TODO: name validation
        //validate unique parameters
        Self {
            name,
            type_expr,
            parameters,
        }
    }

    fn get_tag_string_if_expr_is_variant(&self) -> String {
        if let RescriptTypeExpr::Variant(_) = self.type_expr {
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
            "{}{} = {}",
            &self.name,
            parameters,
            self.type_expr.to_string()
        )
    }

    pub fn to_string(&self) -> String {
        format!(
            "{}type {}",
            self.get_tag_string_if_expr_is_variant(),
            self.to_string_no_type_keyword(),
        )
    }

    pub fn to_rescript_schema(&self, type_name: &String) -> String {
        if self.parameters.is_empty() {
            self.type_expr.to_rescript_schema(type_name)
        } else {
            let params = self
                .parameters
                .iter()
                .map(|param| format!("_{}Schema", param))
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
                self.type_expr.to_rescript_schema(&type_name)
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

#[derive(Debug, PartialEq, Clone)]
pub enum RescriptTypeExpr {
    Identifier(RescriptTypeIdent),
    Record(Vec<RescriptRecordField>),
    Variant(Vec<RescriptVariantConstr>),
}

impl RescriptTypeExpr {
    pub fn to_string(&self) -> String {
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

    pub fn to_rescript_schema(&self, type_name: &String) -> String {
        match self {
            Self::Identifier(type_ident) => type_ident.to_rescript_schema(),
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
                            item.payload.to_rescript_schema()
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
                                field.name,
                                // For raw events we keep the ReScript name,
                                // if we need to serialize to the original name,
                                // then it'll require a flag in the args
                                field.name,
                                field.type_ident.to_rescript_schema()
                            )
                        })
                        .collect::<Vec<String>>()
                        .join(", ");
                    format!("S.object((s): {type_name} => {{{inner_str}}})")
                }
            }
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
pub struct RescriptRecordField {
    pub name: String,
    pub as_name: Option<String>,
    pub type_ident: RescriptTypeIdent,
}

impl RescriptRecordField {
    pub fn to_valid_res_name(s: &str) -> String {
        if s.is_empty() {
            return "_".to_string();
        }

        let first_char = s.chars().next().unwrap();
        match first_char {
            '0'..='9' => return format!("_{}", s),
            _ => (),
        }

        let uncapitalized = s.to_string().uncapitalize();
        if RESCRIPT_RESERVED_WORDS.contains(&uncapitalized.as_str()) {
            format!("{}_", uncapitalized)
        } else {
            uncapitalized
        }
    }

    pub fn new(name: String, type_ident: RescriptTypeIdent) -> Self {
        let res_name = Self::to_valid_res_name(&name);
        Self {
            as_name: if res_name == name { None } else { Some(name) },
            name: res_name,
            type_ident,
        }
    }

    fn to_string(&self) -> String {
        let as_prefix = self
            .as_name
            .clone()
            .map_or("".to_string(), |s| format!("@as(\"{s}\") "));
        format!("{}{}: {}", as_prefix, self.name, self.type_ident)
    }
}

#[derive(Debug, PartialEq, Clone)]
pub struct RescriptVariantConstr {
    name: String,
    payload: RescriptTypeIdent, //Not supporting records here but tuples are currently part of
                                //RescriptTypeIdent
}

impl RescriptVariantConstr {
    pub fn new(name: String, payload: RescriptTypeIdent) -> Self {
        // TODO: validate uppercase name
        Self { name, payload }
    }
}

#[derive(Debug, PartialEq, Clone)]
pub enum RescriptTypeIdent {
    Unit,
    ID,
    Int,
    Float,
    BigInt,
    BigDecimal,
    Address,
    String,
    Bool,
    Timestamp,
    //Enums defined in the user's schema
    SchemaEnum(CapitalizedOptions),
    Array(Box<RescriptTypeIdent>),
    Option(Box<RescriptTypeIdent>),
    //Note: tuple is technically an expression not an identifier
    //but it can be inlined and can contain inline tuples in it's parameters
    //so it's best suited here for its purpose
    Tuple(Vec<RescriptTypeIdent>),
    GenericParam(String),
    TypeApplication {
        name: String,
        type_params: Vec<RescriptTypeIdent>,
    },
}

impl RescriptTypeIdent {
    //Simply an ergonomic shorthand
    pub fn to_expr(self) -> RescriptTypeExpr {
        RescriptTypeExpr::Identifier(self)
    }

    //Simply an ergonomic shorthand
    pub fn to_ok_expr(self) -> anyhow::Result<RescriptTypeExpr> {
        Ok(self.to_expr())
    }

    fn to_string(&self) -> String {
        match self {
            Self::Unit => "unit".to_string(),
            Self::Int => "int".to_string(),
            Self::Float => "GqlDbCustomTypes.Float.t".to_string(),
            Self::BigInt => "bigint".to_string(),
            Self::BigDecimal => "BigDecimal.t".to_string(),
            Self::Address => "Address.t".to_string(),
            Self::String => "string".to_string(),
            Self::ID => "id".to_string(),
            Self::Bool => "bool".to_string(),
            Self::Timestamp => "Js.Date.t".to_string(),
            Self::Array(inner_type) => {
                format!("array<{}>", inner_type.to_string())
            }
            Self::Option(inner_type) => {
                format!("option<{}>", inner_type.to_string())
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

    pub fn to_rescript_schema(&self) -> String {
        match self {
            Self::Unit => "S.literal(%raw(`null`))->S.variant(_ => ())".to_string(),
            Self::Int => "S.int".to_string(),
            Self::Float => "GqlDbCustomTypes.Float.schema".to_string(),
            Self::BigInt => "BigInt.schema".to_string(),
            Self::BigDecimal => "BigDecimal.schema".to_string(),
            Self::Address => "Address.schema".to_string(),
            Self::String => "S.string".to_string(),
            Self::ID => "S.string".to_string(),
            Self::Bool => "S.bool".to_string(),
            Self::Timestamp => {
                // Don't use S.unknown, since it's not serializable to json
                // In a nutshell, this is completely unsafe.
                "S.json(~validate=false)->(Utils.magic: S.t<Js.Json.t> => S.t<Js.Date.t>)"
                    .to_string()
            }
            Self::Array(inner_type) => {
                format!("S.array({})", inner_type.to_rescript_schema())
            }
            Self::Option(inner_type) => {
                format!("S.null({})", inner_type.to_rescript_schema())
            }
            Self::Tuple(inner_types) => {
                let inner_str = inner_types
                    .iter()
                    .enumerate()
                    .map(|(index, inner_type)| {
                        format!("s.item({index}, {})", inner_type.to_rescript_schema())
                    })
                    .collect::<Vec<String>>()
                    .join(", ");
                format!("S.tuple(s => ({}))", inner_str)
            }
            Self::SchemaEnum(enum_name) => {
                format!("Enums.{}.schema", &enum_name.capitalized)
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
                let param_schemas_joined = params.iter().map(|p| p.to_rescript_schema()).join(", ");
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
            | Self::ID
            | Self::Bool
            | Self::Timestamp
            | Self::SchemaEnum(_)
            | Self::GenericParam(_) => vec![],
            Self::TypeApplication { name, .. } => vec![name.clone()],
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
            Self::Float => "0.0".to_string(),
            Self::BigInt => "0n".to_string(),
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
            Self::Unit => "undefined".to_string(),
            Self::Int | Self::Float => "0".to_string(),
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
        match self {
            Self::Option(_) => true,
            _ => false,
        }
    }

    pub fn option(inner_type: Self) -> Self {
        Self::Option(Box::new(inner_type))
    }

    pub fn array(inner_type: Self) -> Self {
        Self::Array(Box::new(inner_type))
    }
}

impl Display for RescriptTypeIdent {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.to_string())
    }
}

///Implementation of Serialize allows handlebars get a stringified
///version of the string representation of the rescript type
impl Serialize for RescriptTypeIdent {
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
            RescriptTypeExpr::Identifier(RescriptTypeIdent::Bool)
                .to_rescript_schema(&"eventArgs".to_string()),
            "S.bool".to_string()
        );
        assert_eq!(
            RescriptTypeExpr::Identifier(RescriptTypeIdent::Int)
                .to_rescript_schema(&"eventArgs".to_string()),
            "S.int".to_string()
        );
        assert_eq!(
            RescriptTypeExpr::Identifier(RescriptTypeIdent::Float)
                .to_rescript_schema(&"eventArgs".to_string()),
            "GqlDbCustomTypes.Float.schema".to_string()
        );
        assert_eq!(
            RescriptTypeExpr::Identifier(RescriptTypeIdent::Unit)
                .to_rescript_schema(&"eventArgs".to_string()),
            "S.literal(%raw(`null`))->S.variant(_ => ())".to_string()
        );
        assert_eq!(
            RescriptTypeExpr::Identifier(RescriptTypeIdent::BigInt)
                .to_rescript_schema(&"eventArgs".to_string()),
            "BigInt.schema".to_string()
        );
        assert_eq!(
            RescriptTypeExpr::Identifier(RescriptTypeIdent::BigDecimal)
                .to_rescript_schema(&"eventArgs".to_string()),
            "BigDecimal.schema".to_string()
        );
        assert_eq!(
            RescriptTypeExpr::Identifier(RescriptTypeIdent::Address)
                .to_rescript_schema(&"eventArgs".to_string()),
            "Address.schema".to_string()
        );
        assert_eq!(
            RescriptTypeExpr::Identifier(RescriptTypeIdent::String)
                .to_rescript_schema(&"eventArgs".to_string()),
            "S.string".to_string()
        );
        assert_eq!(
            RescriptTypeExpr::Identifier(RescriptTypeIdent::ID)
                .to_rescript_schema(&"eventArgs".to_string()),
            "S.string".to_string()
        );
        assert_eq!(
            RescriptTypeExpr::Identifier(RescriptTypeIdent::array(RescriptTypeIdent::Int))
                .to_rescript_schema(&"eventArgs".to_string()),
            "S.array(S.int)".to_string()
        );
        assert_eq!(
            RescriptTypeExpr::Identifier(RescriptTypeIdent::option(RescriptTypeIdent::Int))
                .to_rescript_schema(&"eventArgs".to_string()),
            "S.null(S.int)".to_string()
        );
        assert_eq!(
            RescriptTypeExpr::Identifier(RescriptTypeIdent::Tuple(vec![
                RescriptTypeIdent::Int,
                RescriptTypeIdent::Bool
            ]))
            .to_rescript_schema(&"eventArgs".to_string()),
            "S.tuple(s => (s.item(0, S.int), s.item(1, S.bool)))".to_string()
        );
        assert_eq!(
            RescriptTypeExpr::Variant(vec![
                RescriptVariantConstr::new("ConstrA".to_string(), RescriptTypeIdent::Int),
                RescriptVariantConstr::new("ConstrB".to_string(), RescriptTypeIdent::Bool),
            ])
            .to_rescript_schema(&"eventArgs".to_string()),
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
            RescriptTypeExpr::Record(vec![
                RescriptRecordField::new("fieldA".to_string(), RescriptTypeIdent::Int),
                RescriptRecordField::new("fieldB".to_string(), RescriptTypeIdent::Bool),
            ])
            .to_rescript_schema(&"eventArgs".to_string()),
            "S.object((s): eventArgs => {fieldA: s.field(\"fieldA\", S.int), fieldB: s.field(\"fieldB\", \
             S.bool)})"
                .to_string()
        );
        assert_eq!(
            RescriptTypeExpr::Record(vec![]).to_rescript_schema(&"eventArgs".to_string()),
            "S.object((_): eventArgs => {})".to_string()
        );
    }

    #[test]
    fn type_decl_to_string_primitive() {
        let type_decl = RescriptTypeDecl {
            name: "myBool".to_string(),
            type_expr: RescriptTypeExpr::Identifier(RescriptTypeIdent::Bool),
            parameters: vec![],
        };

        let expected = "type myBool = bool".to_string();

        assert_eq!(type_decl.to_string(), expected);
    }

    #[test]
    fn type_decl_to_string_named_ident() {
        let type_decl = RescriptTypeDecl {
            name: "myAlias".to_string(),
            type_expr: RescriptTypeExpr::Identifier(RescriptTypeIdent::TypeApplication {
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
        let type_decl = RescriptTypeDecl::new(
            "myRecord".to_string(),
            RescriptTypeExpr::Record(vec![
                RescriptRecordField {
                    name: "reservedWord_".to_string(),
                    as_name: Some("reservedWord".to_string()),
                    type_ident: RescriptTypeIdent::TypeApplication {
                        name: "myCustomType".to_string(),
                        type_params: vec![],
                    },
                },
                RescriptRecordField::new(
                    "myOptBool".to_string(),
                    RescriptTypeIdent::option(RescriptTypeIdent::Bool),
                ),
            ]),
            vec![],
        );

        let expected = r#"type myRecord = {@as("reservedWord") reservedWord_: myCustomType, myOptBool: option<bool>}"#.to_string();

        assert_eq!(type_decl.to_string(), expected);
    }

    #[test]
    fn type_decl_with_invalid_rescript_field_names_to_string_record() {
        let type_decl = RescriptTypeDecl::new(
            "myRecord".to_string(),
            RescriptTypeExpr::Record(vec![
                RescriptRecordField::new("module".to_string(), RescriptTypeIdent::Bool),
                RescriptRecordField::new("".to_string(), RescriptTypeIdent::Bool),
                RescriptRecordField::new("1".to_string(), RescriptTypeIdent::Bool),
                RescriptRecordField::new("Capitalized".to_string(), RescriptTypeIdent::Bool),
                // Invalid characters in the middle are not handled correctly. Still keep the test to pin the behaviour.
                RescriptRecordField::new("dashed-field".to_string(), RescriptTypeIdent::Bool),
            ]),
            vec![],
        );

        let expected = r#"type myRecord = {@as("module") module_: bool, @as("") _: bool, @as("1") _1: bool, @as("Capitalized") capitalized: bool, dashed-field: bool}"#.to_string();

        assert_eq!(type_decl.to_string(), expected);
    }

    #[test]
    fn type_decl_multi_to_string() {
        let type_decl_1 = RescriptTypeDecl::new(
            "myRecord".to_string(),
            RescriptTypeExpr::Record(vec![
                RescriptRecordField::new(
                    "fieldA".to_string(),
                    RescriptTypeIdent::TypeApplication {
                        name: "myCustomType".to_string(),
                        type_params: vec![],
                    },
                ),
                RescriptRecordField::new("fieldB".to_string(), RescriptTypeIdent::Bool),
            ]),
            vec![],
        );

        let type_decl_2 = RescriptTypeDecl::new(
            "myCustomType".to_string(),
            RescriptTypeExpr::Identifier(RescriptTypeIdent::Bool),
            vec![],
        );

        let type_decl_multi = RescriptTypeDeclMulti::new(vec![type_decl_1, type_decl_2]);

        let expected = "/*Silence warning of label defined in multiple \
                        types*/\n@@warning(\"-30\")\ntype rec myRecord = {fieldA: myCustomType, \
                        fieldB: bool}\n and myCustomType = bool\n@@warning(\"+30\")"
            .to_string();

        assert_eq!(type_decl_multi.to_string(), expected);
    }

    #[test]
    fn type_decl_to_string_record_generic() {
        let my_custom_type_ident = RescriptTypeIdent::TypeApplication {
            name: "myCustomType".to_string(),
            type_params: vec![],
        };
        let type_decl = RescriptTypeDecl::new(
            "myRecord".to_string(),
            RescriptTypeExpr::Record(vec![
                RescriptRecordField::new("fieldA".to_string(), my_custom_type_ident.clone()),
                RescriptRecordField::new(
                    "fieldB".to_string(),
                    RescriptTypeIdent::TypeApplication {
                        name: "myGenericType".to_string(),
                        type_params: vec![
                            my_custom_type_ident.clone(),
                            RescriptTypeIdent::GenericParam("a".to_string()),
                        ],
                    },
                ),
                RescriptRecordField::new(
                    "fieldC".to_string(),
                    RescriptTypeIdent::GenericParam("b".to_string()),
                ),
            ]),
            vec!["a".to_string(), "b".to_string()],
        );

        let expected = r#"type myRecord<'a, 'b> = {fieldA: myCustomType, fieldB: myGenericType<myCustomType, 'a>, fieldC: 'b}"#.to_string();

        assert_eq!(type_decl.to_string(), expected);
    }

    #[test]
    fn type_decl_to_string_variant() {
        let my_custom_type_ident = RescriptTypeIdent::TypeApplication {
            name: "myCustomType".to_string(),
            type_params: vec![],
        };
        let type_decl = RescriptTypeDecl::new(
            "myVariant".to_string(),
            RescriptTypeExpr::Variant(vec![
                RescriptVariantConstr::new("ConstrA".to_string(), my_custom_type_ident.clone()),
                RescriptVariantConstr::new(
                    "ConstrB".to_string(),
                    RescriptTypeIdent::TypeApplication {
                        name: "myGenericType".to_string(),
                        type_params: vec![
                            my_custom_type_ident.clone(),
                            RescriptTypeIdent::GenericParam("a".to_string()),
                        ],
                    },
                ),
                RescriptVariantConstr::new(
                    "ConstrC".to_string(),
                    RescriptTypeIdent::GenericParam("b".to_string()),
                ),
            ]),
            vec!["a".to_string(), "b".to_string()],
        );

        let expected = r#"@tag("case") type myVariant<'a, 'b> = | ConstrA({payload: myCustomType}) | ConstrB({payload: myGenericType<myCustomType, 'a>}) | ConstrC({payload: 'b})"#.to_string();

        assert_eq!(type_decl.to_string(), expected);
    }

    #[test]
    fn type_decl_multi_variant_to_string() {
        let my_custom_type_ident = RescriptTypeIdent::TypeApplication {
            name: "myCustomType".to_string(),
            type_params: vec![],
        };
        let type_decl_1 = RescriptTypeDecl::new(
            "myVariant".to_string(),
            RescriptTypeExpr::Variant(vec![
                RescriptVariantConstr::new("ConstrA".to_string(), my_custom_type_ident.clone()),
                RescriptVariantConstr::new(
                    "ConstrB".to_string(),
                    RescriptTypeIdent::GenericParam("a".to_string()),
                ),
            ]),
            vec!["a".to_string()],
        );

        let type_decl_2 = RescriptTypeDecl::new(
            "myCustomType".to_string(),
            RescriptTypeExpr::Identifier(RescriptTypeIdent::Bool),
            vec![],
        );

        let type_decl_3 = RescriptTypeDecl::new(
            "myVariant2".to_string(),
            RescriptTypeExpr::Variant(vec![RescriptVariantConstr::new(
                "ConstrC".to_string(),
                RescriptTypeIdent::Bool,
            )]),
            vec![],
        );

        let type_decl_multi =
            RescriptTypeDeclMulti::new(vec![type_decl_1, type_decl_2, type_decl_3]);

        let expected = "/*Silence warning of label defined in multiple \
                        types*/\n@@warning(\"-30\")\n@tag(\"case\") type rec myVariant<'a> = | \
                        ConstrA({payload: myCustomType}) | ConstrB({payload: 'a})\n and \
                        myCustomType = bool\n @tag(\"case\") and myVariant2 = | ConstrC({payload: \
                        bool})\n@@warning(\"+30\")"
            .to_string();

        assert_eq!(type_decl_multi.to_string(), expected);
    }
}
