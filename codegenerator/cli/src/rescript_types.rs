use crate::capitalization::{Capitalize, CapitalizedOptions};
use core::fmt;
use itertools::Itertools;
use serde::Serialize;
use std::fmt::Display;

pub struct RescriptTypeDeclMulti(Vec<RescriptTypeDecl>);

impl RescriptTypeDeclMulti {
    pub fn new(type_declarations: Vec<RescriptTypeDecl>) -> Self {
        //TODO: validation
        //no duplicates,
        //all named types accounted for? (maybe don't want this)
        //at least 1 decl
        Self(type_declarations)
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
                format!("/*Silence warning of label defined in multiple types*/\n@@warning(\"-30\")\n{}type rec {}\n@@warning(\"+30\")", tag_prefix, rec_expr)
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
        //TODO: name validation
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
}

#[derive(Debug, PartialEq, Clone)]
pub struct RescriptRecordField {
    pub name: String,
    pub as_name: Option<String>,
    pub type_ident: RescriptTypeIdent,
}

impl RescriptRecordField {
    pub fn new(name: String, type_ident: RescriptTypeIdent) -> Self {
        //TODO: validate name and add as_name if reserved
        Self {
            name,
            as_name: None,
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
        //TODO: validate uppercase name
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
    Address,
    String,
    Bool,
    //Enums defined in the user's schema
    SchemaEnum(CapitalizedOptions),
    Array(Box<RescriptTypeIdent>),
    Option(Box<RescriptTypeIdent>),
    //Note: tuple is technically an expression not an identifier
    //but it can be inlined and can contain inline tuples in it's parameters
    //so it's best suited here for its purpose
    Tuple(Vec<RescriptTypeIdent>),
    NamedType(String),
    GenericParam(String),
    Generic {
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

    pub fn to_string_decoded_skar(&self) -> String {
        match self {
            RescriptTypeIdent::Array(inner_type) => format!(
                "array<HyperSyncClient.Decoder.decodedSolType<{}>>",
                inner_type.to_string_decoded_skar()
            ),
            RescriptTypeIdent::Tuple(inner_types) => {
                let inner_types_str = inner_types
                    .iter()
                    .map(|inner_type| inner_type.to_string_decoded_skar())
                    .collect::<Vec<String>>()
                    .join(", ");
                format!(
                    "HyperSyncClient.Decoder.decodedSolType<({})>",
                    inner_types_str
                )
            }
            v => {
                format!("HyperSyncClient.Decoder.decodedSolType<{}>", v.to_string())
            }
        }
    }

    fn to_string(&self) -> String {
        match self {
            RescriptTypeIdent::Unit => "unit".to_string(),
            RescriptTypeIdent::Int => "int".to_string(),
            RescriptTypeIdent::Float => "GqlDbCustomTypes.Float.t".to_string(),
            RescriptTypeIdent::BigInt => "Ethers.BigInt.t".to_string(),
            RescriptTypeIdent::Address => "Ethers.ethAddress".to_string(),
            RescriptTypeIdent::String => "string".to_string(),
            RescriptTypeIdent::ID => "id".to_string(),
            RescriptTypeIdent::Bool => "bool".to_string(),
            RescriptTypeIdent::Array(inner_type) => {
                format!("array<{}>", inner_type.to_string())
            }
            RescriptTypeIdent::Option(inner_type) => {
                format!("option<{}>", inner_type.to_string())
            }
            RescriptTypeIdent::Tuple(inner_types) => {
                let inner_types_str = inner_types
                    .iter()
                    .map(|inner_type| inner_type.to_string())
                    .collect::<Vec<String>>()
                    .join(", ");
                format!("({})", inner_types_str)
            }
            RescriptTypeIdent::SchemaEnum(enum_name) => {
                format!("Enums.{}", &enum_name.uncapitalized)
            }
            RescriptTypeIdent::NamedType(name) => name.clone(),
            // Lowercase generic params because of the issue https://github.com/rescript-lang/rescript-compiler/issues/6759
            RescriptTypeIdent::GenericParam(name) => format!("'{}", name.to_lowercase()),
            RescriptTypeIdent::Generic {
                name,
                type_params: params,
            } => {
                let params_joined = params
                    .iter()
                    .map(|p| p.to_string().uncapitalize())
                    .join(", ");
                format!("{name}<{params_joined}>")
            }
        }
    }

    pub fn to_rescript_schema(&self) -> String {
        match self {
            RescriptTypeIdent::Unit => "S.unit".to_string(),
            RescriptTypeIdent::Int => "S.int".to_string(),
            RescriptTypeIdent::Float => "GqlDbCustomTypes.Float.schema".to_string(),
            RescriptTypeIdent::BigInt => "Ethers.BigInt.schema".to_string(),
            RescriptTypeIdent::Address => "Ethers.ethAddressSchema".to_string(),
            RescriptTypeIdent::String => "S.string".to_string(),
            RescriptTypeIdent::ID => "S.string".to_string(),
            RescriptTypeIdent::Bool => "S.bool".to_string(),
            RescriptTypeIdent::Array(inner_type) => {
                format!("S.array({})", inner_type.to_rescript_schema())
            }
            RescriptTypeIdent::Option(inner_type) => {
                format!("S.null({})", inner_type.to_rescript_schema())
            }
            RescriptTypeIdent::Tuple(inner_types) => {
                let inner_str = inner_types
                    .iter()
                    .enumerate()
                    .map(|(index, inner_type)| {
                        format!("s.item({index}, {})", inner_type.to_rescript_schema())
                    })
                    .collect::<Vec<String>>()
                    .join(", ");
                format!("S.tuple((. s) => ({}))", inner_str)
            }
            RescriptTypeIdent::SchemaEnum(enum_name) => {
                format!("Enums.{}Schema", &enum_name.uncapitalized)
            }
            //TODO: ensure these are defined
            RescriptTypeIdent::NamedType(name) | RescriptTypeIdent::GenericParam(name) => {
                format!("{name}Schema")
            }
            RescriptTypeIdent::Generic {
                name,
                type_params: params,
            } => {
                let generic_params = params
                    .iter()
                    .filter_map(|p| {
                        if let RescriptTypeIdent::GenericParam(_) = p {
                            Some(p.to_rescript_schema())
                        } else {
                            None
                        }
                    })
                    .join(", ");

                let param_schemas_joined = params.iter().map(|p| p.to_rescript_schema()).join(", ");

                let schema_composed = format!("make{name}Schema({param_schemas_joined})");
                if generic_params.is_empty() {
                    schema_composed
                } else {
                    //if some parameters are generic return a function that takes schemas of those
                    //parameters
                    format!("({generic_params}) => {schema_composed}")
                }
            }
        }
    }

    pub fn get_default_value_rescript(&self) -> String {
        match self {
            RescriptTypeIdent::Unit => "()".to_string(),
            RescriptTypeIdent::Int => "0".to_string(),
            RescriptTypeIdent::Float => "0.0".to_string(),
            RescriptTypeIdent::BigInt => "Ethers.BigInt.zero".to_string(), //TODO: Migrate to RescriptCore on ReScript migration
            RescriptTypeIdent::Address => "TestHelpers_MockAddresses.defaultAddress".to_string(),
            RescriptTypeIdent::String => "\"foo\"".to_string(),
            RescriptTypeIdent::ID => "\"my_id\"".to_string(),
            RescriptTypeIdent::Bool => "false".to_string(),
            RescriptTypeIdent::Array(_) => "[]".to_string(),
            RescriptTypeIdent::Option(_) => "None".to_string(),
            RescriptTypeIdent::SchemaEnum(enum_name) => {
                format!("Enums.{}Default", &enum_name.uncapitalized)
            }
            RescriptTypeIdent::Tuple(inner_types) => {
                let inner_types_str = inner_types
                    .iter()
                    .map(|inner_type| inner_type.get_default_value_rescript())
                    .collect::<Vec<String>>()
                    .join(", ");

                format!("({})", inner_types_str)
            }
            //TODO: ensure these are defined
            RescriptTypeIdent::NamedType(name) | RescriptTypeIdent::GenericParam(name) => {
                format!("{name}Default")
            }
            RescriptTypeIdent::Generic {
                name,
                type_params: params,
            } => {
                let generics_defaults = params
                    .iter()
                    .filter_map(|p| {
                        if let RescriptTypeIdent::GenericParam(_) = p {
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
            RescriptTypeIdent::Unit => "undefined".to_string(),
            RescriptTypeIdent::Int | RescriptTypeIdent::Float => "0".to_string(),
            RescriptTypeIdent::BigInt => "0n".to_string(),
            RescriptTypeIdent::Address => "Addresses.defaultAddress".to_string(),
            RescriptTypeIdent::String => "\"foo\"".to_string(),
            RescriptTypeIdent::ID => "\"my_id\"".to_string(),
            RescriptTypeIdent::Bool => "false".to_string(),
            RescriptTypeIdent::Array(_) => "[]".to_string(),
            RescriptTypeIdent::Option(_) => "null".to_string(),
            RescriptTypeIdent::SchemaEnum(enum_name) => {
                format!("{}Default", &enum_name.uncapitalized)
            }
            RescriptTypeIdent::Tuple(inner_types) => {
                let inner_types_str = inner_types
                    .iter()
                    .map(|inner_type| inner_type.get_default_value_non_rescript())
                    .join(", ");
                format!("[{}]", inner_types_str)
            }
            //Todo ensure these are defined
            RescriptTypeIdent::NamedType(name) | RescriptTypeIdent::GenericParam(name) => {
                format!("{name}Default")
            }
            RescriptTypeIdent::Generic {
                name,
                type_params: params,
            } => {
                let generics_defaults = params
                    .iter()
                    .filter_map(|p| {
                        if let RescriptTypeIdent::GenericParam(_) = p {
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
    use super::*;
    use pretty_assertions::assert_eq;

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
            type_expr: RescriptTypeExpr::Identifier(RescriptTypeIdent::NamedType(
                "myCustomType".to_string(),
            )),
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
                    type_ident: RescriptTypeIdent::NamedType("myCustomType".to_string()),
                },
                RescriptRecordField::new(
                    "myOptBool".to_string(),
                    RescriptTypeIdent::Option(Box::new(RescriptTypeIdent::Bool)),
                ),
            ]),
            vec![],
        );

        let expected = r#"type myRecord = {@as("reservedWord") reservedWord_: myCustomType, myOptBool: option<bool>}"#.to_string();

        assert_eq!(type_decl.to_string(), expected);
    }

    #[test]
    fn type_decl_multi_to_string() {
        let type_decl_1 = RescriptTypeDecl::new(
            "myRecord".to_string(),
            RescriptTypeExpr::Record(vec![
                RescriptRecordField::new(
                    "fieldA".to_string(),
                    RescriptTypeIdent::NamedType("myCustomType".to_string()),
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

        let expected = "/*Silence warning of label defined in multiple types*/\n@@warning(\"-30\")\ntype rec myRecord = {fieldA: myCustomType, \
                        fieldB: bool}\n and myCustomType = bool\n@@warning(\"+30\")"
            .to_string();

        assert_eq!(type_decl_multi.to_string(), expected);
    }

    #[test]
    fn type_decl_to_string_record_generic() {
        let my_custom_type_ident = RescriptTypeIdent::NamedType("myCustomType".to_string());
        let type_decl = RescriptTypeDecl::new(
            "myRecord".to_string(),
            RescriptTypeExpr::Record(vec![
                RescriptRecordField::new("fieldA".to_string(), my_custom_type_ident.clone()),
                RescriptRecordField::new(
                    "fieldB".to_string(),
                    RescriptTypeIdent::Generic {
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
        let my_custom_type_ident = RescriptTypeIdent::NamedType("myCustomType".to_string());
        let type_decl = RescriptTypeDecl::new(
            "myVariant".to_string(),
            RescriptTypeExpr::Variant(vec![
                RescriptVariantConstr::new("ConstrA".to_string(), my_custom_type_ident.clone()),
                RescriptVariantConstr::new(
                    "ConstrB".to_string(),
                    RescriptTypeIdent::Generic {
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
        let my_custom_type_ident = RescriptTypeIdent::NamedType("myCustomType".to_string());
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

        let expected = "/*Silence warning of label defined in multiple types*/\n@@warning(\"-30\")\n@tag(\"case\") type rec myVariant<'a> = | \
                        ConstrA({payload: myCustomType}) | ConstrB({payload: 'a})\n and \
                        myCustomType = bool\n @tag(\"case\") and myVariant2 = | \
                        ConstrC({payload: bool})\n@@warning(\"+30\")"
            .to_string();

        assert_eq!(type_decl_multi.to_string(), expected);
    }
}
