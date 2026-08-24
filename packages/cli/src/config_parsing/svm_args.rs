//! Borsh type grammar for `internal_config.json`. Not part of user YAML;
//! instruction layouts come from the IDL.

use hypersync_client_solana::decode::{FieldType, NamedField};
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ArgDef {
    pub name: String,
    #[serde(rename = "type")]
    pub ty: ArgType,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(untagged)]
pub enum ArgType {
    Primitive(ArgPrimitive),
    Composite(ArgComposite),
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum ArgPrimitive {
    Bool,
    U8,
    U16,
    U32,
    U64,
    U128,
    I8,
    I16,
    I32,
    I64,
    I128,
    F32,
    F64,
    String,
    Bytes,
    Pubkey,
    #[serde(rename = "publicKey")]
    PublicKey,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(deny_unknown_fields)]
pub enum ArgComposite {
    #[serde(rename = "option")]
    Option(Box<ArgType>),
    #[serde(rename = "vec")]
    Vec(Box<ArgType>),
    #[serde(rename = "array")]
    Array(Box<ArgType>, usize),
    #[serde(rename = "defined")]
    Defined(String),
    #[serde(rename = "struct")]
    Struct(Vec<ArgDef>),
    #[serde(rename = "enum")]
    Enum(Vec<ArgEnumVariant>),
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ArgEnumVariant {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fields: Option<Vec<ArgDef>>,
}

pub fn field_type_to_arg_type(ty: &FieldType) -> ArgType {
    match ty {
        FieldType::Bool => ArgType::Primitive(ArgPrimitive::Bool),
        FieldType::U8 => ArgType::Primitive(ArgPrimitive::U8),
        FieldType::U16 => ArgType::Primitive(ArgPrimitive::U16),
        FieldType::U32 => ArgType::Primitive(ArgPrimitive::U32),
        FieldType::U64 => ArgType::Primitive(ArgPrimitive::U64),
        FieldType::U128 => ArgType::Primitive(ArgPrimitive::U128),
        FieldType::I8 => ArgType::Primitive(ArgPrimitive::I8),
        FieldType::I16 => ArgType::Primitive(ArgPrimitive::I16),
        FieldType::I32 => ArgType::Primitive(ArgPrimitive::I32),
        FieldType::I64 => ArgType::Primitive(ArgPrimitive::I64),
        FieldType::I128 => ArgType::Primitive(ArgPrimitive::I128),
        FieldType::F32 => ArgType::Primitive(ArgPrimitive::F32),
        FieldType::F64 => ArgType::Primitive(ArgPrimitive::F64),
        FieldType::String => ArgType::Primitive(ArgPrimitive::String),
        FieldType::Bytes => ArgType::Primitive(ArgPrimitive::Bytes),
        FieldType::Pubkey => ArgType::Primitive(ArgPrimitive::Pubkey),
        FieldType::Option(inner) => {
            ArgType::Composite(ArgComposite::Option(Box::new(field_type_to_arg_type(inner))))
        }
        FieldType::Vec(inner) => {
            ArgType::Composite(ArgComposite::Vec(Box::new(field_type_to_arg_type(inner))))
        }
        FieldType::Array { ty, len } => ArgType::Composite(ArgComposite::Array(
            Box::new(field_type_to_arg_type(ty)),
            *len,
        )),
        FieldType::Defined(name) => ArgType::Composite(ArgComposite::Defined(name.clone())),
        FieldType::Struct(fields) => ArgType::Composite(ArgComposite::Struct(
            fields.iter().map(named_field_to_arg_def).collect(),
        )),
        FieldType::Enum(variants) => ArgType::Composite(ArgComposite::Enum(
            variants
                .iter()
                .map(|v| ArgEnumVariant {
                    name: v.name.clone(),
                    fields: v
                        .fields
                        .as_ref()
                        .map(|fs| fs.iter().map(named_field_to_arg_def).collect()),
                })
                .collect(),
        )),
    }
}

pub fn named_field_to_arg_def(nf: &NamedField) -> ArgDef {
    ArgDef {
        name: nf.name.clone(),
        ty: field_type_to_arg_type(&nf.ty),
    }
}
