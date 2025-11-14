use core::fmt;
use serde::Serialize;
use std::fmt::Display;

#[derive(Debug, PartialEq, Clone)]
pub enum Primitive {
    Boolean,
    String,
    Int32,
    BigInt { precision: Option<u32> },
    BigDecimal(Option<(u32, u32)>), // (precision, scale)
    Number,
    Serial,
    Json,
    Date,
    Enum(String),
    Entity(String),
}

impl Primitive {
    pub fn get_res_field_type_variant(&self) -> String {
        match &self {
            Self::Boolean => "Boolean".to_string(),
            Self::String => "String".to_string(),
            Self::Int32 => "Int32".to_string(),
            Self::BigInt { precision: None } => "BigInt({})".to_string(),
            Self::BigInt {
                precision: Some(precision),
            } => {
                format!("BigInt({{precision: {precision}}})")
            }
            Self::BigDecimal(None) => "BigDecimal({})".to_string(),
            Self::BigDecimal(Some((precision, scale))) => {
                format!("BigDecimal({{config: ({precision}, {scale})}})")
            }
            Self::Serial => "Serial".to_string(),
            Self::Json => "Json".to_string(),
            Self::Date => "Date".to_string(),
            Self::Number => "Number".to_string(),
            Self::Enum(enum_name) => format!("Enum({{name: \"{enum_name}\"}})"),
            Self::Entity(entity_name) => format!("Entity({{name: \"{entity_name}\"}})"),
        }
    }
}

impl Serialize for Primitive {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        self.to_string().serialize(serializer)
    }
}

impl Display for Primitive {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.get_res_field_type_variant())
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct Field {
    pub field_name: String,
    pub linked_entity: Option<String>,
    pub is_index: bool,
    pub is_primary_key: bool,
    pub is_nullable: bool,
    pub is_array: bool,
    pub field_type: Primitive,
    pub res_schema_code: String,
}
