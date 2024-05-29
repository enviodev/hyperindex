use core::fmt;
use serde::Serialize;
use std::fmt::Display;

#[derive(Debug, PartialEq, Clone)]
pub enum Primitive {
    Boolean,
    Text,
    Integer,
    Numeric,
    Serial,
    Json,
    Timestamp,
    Enum(String),
}

impl Primitive {
    pub fn get_res_field_type_variant(&self) -> String {
        match &self {
            Self::Boolean => "Boolean".to_string(),
            Self::Text => "Text".to_string(),
            Self::Integer => "Integer".to_string(),
            Self::Numeric => "Numeric".to_string(),
            Self::Serial => "Serial".to_string(),
            Self::Json => "Json".to_string(),
            Self::Timestamp => "Timestamp".to_string(),
            Self::Enum(enum_name) => format!("Enum(Enums.{enum_name}.enum.name)"),
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
    pub is_linked_entity_field: bool,
    pub is_index: bool,
    pub is_primary_key: bool,
    pub is_nullable: bool,
    pub is_array: bool,
    pub field_type: Primitive,
}