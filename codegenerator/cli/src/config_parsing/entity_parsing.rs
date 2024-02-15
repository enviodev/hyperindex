use super::{
    system_config::{EntityMap, GraphQlEnumMap},
    validation::{
        check_names_from_schema_for_reserved_words, check_schema_enums_are_valid_postgres,
    },
};
use crate::capitalization::{Capitalize, CapitalizedOptions};
use anyhow::{anyhow, Context};
use ethers::abi::ethabi::ParamType as EthAbiParamType;
use graphql_parser::schema::{
    Definition, Directive, Document, EnumType, EnumValue, Field as ObjField, ObjectType,
    Type as ObjType, TypeDefinition, Value,
};
use serde::{Serialize, Serializer};
use std::{
    collections::HashSet,
    fmt::{self, Display},
    path::PathBuf,
};
use subenum::subenum;

#[derive(Debug, Clone, PartialEq)]
pub struct Schema {
    pub entities: Vec<Entity>,
    pub enums: Vec<GraphQLEnum>,
}

impl Schema {
    pub fn empty() -> Self {
        Schema {
            entities: vec![],
            enums: vec![],
        }
    }

    fn from_document(document: Document<String>) -> anyhow::Result<Self> {
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
            .map(|obj| Entity::from_object(obj))
            .collect::<anyhow::Result<_>>()
            .context("Failed constructing entities in schema from document")?;

        let enums: Vec<GraphQLEnum> = document
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
            .collect::<anyhow::Result<_>>()
            .context("Failed constructing enums in schema from document")?;

        Ok(Schema { entities, enums })
    }

    pub fn parse_from_file(path_to_schema: &PathBuf) -> anyhow::Result<Self> {
        let schema_string = std::fs::read_to_string(&path_to_schema).context(
            format!(
                "EE200: Failed to read schema file at {}. Please ensure that the schema file is placed correctly in the directory.",
                &path_to_schema.to_str().unwrap_or_else(||"bad file path"),
            )
        )?;

        let schema_doc = graphql_parser::parse_schema::<String>(&schema_string)
            .context("EE201: Failed to parse schema as document")?;

        let parsed = Self::from_document(schema_doc)
            .context("Failed converting schema doc to schema struct")?;

        parsed
            .check_schema_for_reserved_words()
            .context("Failed checking if schema contains reserved keywords")?;

        parsed
            .validate_enums_for_postgres_and_duplicates()
            .context("Failed validating enums")?;

        Ok(parsed)
    }

    pub fn check_schema_for_reserved_words(&self) -> anyhow::Result<()> {
        let mut all_names: Vec<String> = Vec::new();
        for entity in &self.entities {
            all_names.push(entity.name.clone());

            for field in &entity.fields {
                all_names.push(field.name.clone());
            }
        }
        for gql_enum in &self.enums {
            all_names.push(gql_enum.name.clone());
            for value in &gql_enum.values {
                all_names.push(value.name.clone());
            }
        }
        let reserved_keywords_used = check_names_from_schema_for_reserved_words(all_names);
        if !reserved_keywords_used.is_empty() {
            return Err(anyhow!(
                "EE210: Schema contains the following reserved keywords: {}",
                reserved_keywords_used.join(", ")
            ));
        }

        Ok(())
    }

    pub fn validate_enums_for_postgres_and_duplicates(&self) -> anyhow::Result<()> {
        let mut enum_names: Vec<String> = Vec::new();
        for gql_enum in &self.enums {
            enum_names.push(gql_enum.name.clone());
        }
        let invalid_enum_names = check_schema_enums_are_valid_postgres(&enum_names);
        if !invalid_enum_names.is_empty() {
            return Err(anyhow!(
                "EE212: Schema contains the following enum names that do not match the following pattern: It must start with a letter. It can only contain letters, numbers, and underscores (no spaces). It must have a maximum length of 63 characters. Invalid names: {}",
                invalid_enum_names.join(", ")
            ));
        }
        let mut duplicate_enum_entity_names: Vec<String> = Vec::new();
        for entity in &self.entities {
            if enum_names.contains(&entity.name.clone()) {
                duplicate_enum_entity_names.push(entity.name.clone());
            }
        }
        if !duplicate_enum_entity_names.is_empty() {
            return Err(anyhow!(
                "EE213: Schema contains the following enums and entities with the same name, all type and enum definitions must be unique in the schema: {}",
                duplicate_enum_entity_names.join(", ")
            ));
        }

        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct GraphQLEnum {
    pub name: String,
    pub values: Vec<GraphQLValue>,
}

impl GraphQLEnum {
    pub fn new(name: String, values: Vec<GraphQLValue>) -> Self {
        GraphQLEnum { name, values }
    }
    fn from_enum(enm: &EnumType<String>) -> anyhow::Result<Self> {
        let name = enm.name.clone();
        let values = enm
            .values
            .iter()
            .map(|value| GraphQLValue::from_enum_value(value))
            .collect::<anyhow::Result<_>>()
            .context("Failed contsructing enums")?;
        Ok(GraphQLEnum::new(name, values))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct GraphQLValue {
    pub name: String,
}

impl GraphQLValue {
    pub fn from_enum_value(enum_value: &EnumValue<String>) -> anyhow::Result<Self> {
        let name = enum_value.name.clone();

        Ok(GraphQLValue { name })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Entity {
    pub name: String,
    pub fields: Vec<Field>,
}

impl Entity {
    fn from_object(obj: &ObjectType<String>) -> anyhow::Result<Self> {
        let name = obj.name.clone();

        let fields = obj
            .fields
            .iter()
            .map(|f| Field::from_obj_field(f))
            .collect::<anyhow::Result<_>>()
            .context("Failed contsructing fields")?;

        Ok(Entity { name, fields })
    }

    pub fn get_related_entities<'a>(
        &'a self,
        other_entities: &'a EntityMap,
        gql_enums: &GraphQlEnumMap,
    ) -> anyhow::Result<Vec<(&'a Field, &'a Self)>> {
        let required_entities_with_field = self
            .fields
            .iter()
            .filter_map(|field| {
                let gql_scalar = field.field_type.get_underlying_scalar();
                if let GqlScalar::Custom(entity_name) = gql_scalar {
                    if gql_enums.contains_key(entity_name) {
                        None
                    } else {
                        let field_and_entity = other_entities
                            .get(entity_name)
                            .map(|entity| (field, entity))
                            .ok_or_else(|| anyhow!("Entity {} does not exist", entity_name));
                        Some(field_and_entity)
                    }
                } else {
                    None
                }
            })
            .collect::<anyhow::Result<_>>()?;

        Ok(required_entities_with_field)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Field {
    pub name: String,
    pub field_type: FieldType,
    pub derived_from_field: Option<String>,
}

impl Field {
    fn from_obj_field(field: &ObjField<String>) -> anyhow::Result<Self> {
        //Get all gql derictives labeled @derivedFrom
        let derived_from_directives = field
            .directives
            .iter()
            .filter(|directive| directive.name == "derivedFrom")
            .collect::<Vec<&Directive<'_, String>>>();

        //Do not allow for multiple @derivedFrom directives
        //If this step is not important and we are fine with just taking the first one
        //in the case of multiple we can just use a find rather than a filter method above
        if derived_from_directives.len() > 1 {
            let msg = anyhow!(
                "EE202: Cannot use more than one @derivedFrom directive at field {}",
                field.name
            );
            return Err(msg);
        }

        let maybe_derived_from_directive = derived_from_directives.get(0);
        let derived_from_field = match maybe_derived_from_directive {
            None => None,
            Some(d) => {
                let field_arg = d.arguments.iter().find(|a| a.0 == "field").ok_or_else(|| {
                    anyhow!(
                        "EE203: No 'field' argument supplied to @derivedFrom directive on field {}",
                        field.name
                    )
                })?;
                match &field_arg.1 {
                        Value::String(val) => Some(val.clone()),
                        _ => Err(anyhow!("EE204: 'field' argument in @derivedFrom directive on field {} needs to contain a string", field.name))?
                    }
            }
        };

        let field_type = FieldType::from_obj_field_type(&field.field_type);

        Ok(Field {
            name: field.name.clone(),
            derived_from_field,
            field_type,
        })
    }
}

#[derive(Debug, PartialEq, Clone)]
pub enum RescriptType {
    ID,
    Int,
    Float,
    BigInt,
    Address,
    String,
    Bool,
    EnumVariant(CapitalizedOptions),
    Array(Box<RescriptType>),
    Option(Box<RescriptType>),
    Tuple(Vec<RescriptType>),
}

impl RescriptType {
    pub fn to_string_decoded_skar(&self) -> String {
        match self {
            RescriptType::Array(inner_type) => format!(
                "array<HyperSyncClient.Decoder.decodedSolType<{}>>",
                inner_type.to_string_decoded_skar()
            ),
            RescriptType::Tuple(inner_types) => {
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
            RescriptType::Int => "int".to_string(),
            RescriptType::Float => "float".to_string(),
            RescriptType::BigInt => "Ethers.BigInt.t".to_string(),
            RescriptType::Address => "Ethers.ethAddress".to_string(),
            RescriptType::String => "string".to_string(),
            RescriptType::ID => "id".to_string(),
            RescriptType::Bool => "bool".to_string(),
            RescriptType::Array(inner_type) => {
                format!("array<{}>", inner_type.to_string())
            }
            RescriptType::Option(inner_type) => {
                format!("option<{}>", inner_type.to_string())
            }
            RescriptType::Tuple(inner_types) => {
                let inner_types_str = inner_types
                    .iter()
                    .map(|inner_type| inner_type.to_string())
                    .collect::<Vec<String>>()
                    .join(", ");
                format!("({})", inner_types_str)
            }
            RescriptType::EnumVariant(enum_name) => enum_name.uncapitalized.clone(),
        }
    }

    pub fn get_default_value_rescript(&self) -> String {
        match self {
            RescriptType::Int => "0".to_string(),
            RescriptType::Float => "0.0".to_string(),
            RescriptType::BigInt => "Ethers.BigInt.zero".to_string(),
            RescriptType::Address => "Ethers.Addresses.defaultAddress".to_string(),
            RescriptType::String => "\"foo\"".to_string(),
            RescriptType::ID => "\"my_id\"".to_string(),
            RescriptType::Bool => "false".to_string(),
            RescriptType::Array(_) => "[]".to_string(),
            RescriptType::Option(_) => "None".to_string(),
            RescriptType::EnumVariant(_) => "defaultEnum".to_string(),
            RescriptType::Tuple(inner_types) => {
                let inner_types_str = inner_types
                    .iter()
                    .map(|inner_type| inner_type.get_default_value_rescript())
                    .collect::<Vec<String>>()
                    .join(", ");

                format!("({})", inner_types_str)
            }
        }
    }

    pub fn get_default_value_non_rescript(&self) -> String {
        match self {
            RescriptType::Int | RescriptType::Float => "0".to_string(),
            RescriptType::BigInt => "0n".to_string(),
            RescriptType::Address => "Addresses.defaultAddress".to_string(),
            RescriptType::String => "\"foo\"".to_string(),
            RescriptType::ID => "\"my_id\"".to_string(),
            RescriptType::Bool => "false".to_string(),
            RescriptType::Array(_) => "[]".to_string(),
            RescriptType::Option(_) => "null".to_string(),
            RescriptType::EnumVariant(_) => "defaultEnum".to_string(),
            RescriptType::Tuple(inner_types) => {
                let inner_types_str = inner_types
                    .iter()
                    .map(|inner_type| inner_type.get_default_value_non_rescript())
                    .collect::<Vec<String>>()
                    .join(", ");

                format!("[{}]", inner_types_str)
            }
        }
    }
}

impl Display for RescriptType {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.to_string())
    }
}

///Implementation of Serialize allows handlebars get a stringified
///version of the string representation of the rescript type
impl Serialize for RescriptType {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        // Serialize as display value
        self.to_string().serialize(serializer)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum FieldType {
    Single(GqlScalar),
    ListType(Box<FieldType>),
    NonNullType(Box<FieldType>),
}

impl FieldType {
    fn from_obj_field_type(field_type: &ObjType<'_, String>) -> Self {
        match field_type {
            ObjType::NamedType(name) => FieldType::Single(name.as_str().into()),
            ObjType::NonNullType(inner) => {
                FieldType::NonNullType(Box::new(Self::from_obj_field_type(inner.as_ref())))
            }
            ObjType::ListType(inner) => {
                FieldType::ListType(Box::new(Self::from_obj_field_type(inner.as_ref())))
            }
        }
    }

    pub fn to_postgres_type(
        &self,
        entities_set: &HashSet<String>,
        gql_enums_set: &HashSet<String>,
        is_derived_from: bool,
    ) -> anyhow::Result<String> {
        let composed_type_name = match self {
        Self::Single(gql_scalar) => {
                gql_scalar.to_postgres_type(entities_set, gql_enums_set)?
        }
        Self::ListType(field_type) => match field_type.as_ref() {
            //Postgres doesn't support nullable types inside of arrays
            Self::NonNullType(field_type) =>
                match (field_type.as_ref(), is_derived_from) {
                    | (Self::Single(GqlScalar::Custom(custom_field)), false) =>
                        Err(anyhow!(
                            "EE211: Arrays of entities is unsupported. Please use one of the methods for referencing entities outlined in the docs. The entity being referenced in the array is '{}'.", custom_field
                        ))?,
                    | _ => format!("{}[]",field_type.to_postgres_type(entities_set, gql_enums_set, is_derived_from)?),
                }
            Self::Single(gql_scalar)   => Err(anyhow!(
                "EE208: Nullable scalars inside lists are unsupported. Please include a '!' after your '{}' scalar", gql_scalar
            ))?,
            Self::ListType(_) => Err(anyhow!("EE209: Nullable multidimensional lists types are unsupported,\
                please include a '!' for your inner list type eg. [[Int!]!]"))?,
        },
        Self::NonNullType(field_type) => format!(
            "{} NOT NULL",
            field_type.to_postgres_type(entities_set,gql_enums_set, is_derived_from)?
        ),
    };
        Ok(composed_type_name)
    }

    pub fn is_optional(&self) -> bool {
        !matches!(self, Self::NonNullType(_))
    }

    pub fn is_array(&self) -> bool {
        matches!(self, Self::ListType(_))
            || matches!(
                self,
                Self::NonNullType(field_type) if field_type.is_array()
            )
    }

    pub fn to_rescript_type(
        &self,
        entities_set: &HashSet<String>,
        gql_enums_name_set: &HashSet<String>,
    ) -> anyhow::Result<RescriptType> {
        let composed_type_name = match self {
            //Only types in here should be non optional
            Self::NonNullType(field_type) => match field_type.as_ref() {
                Self::Single(gql_scalar) => {
                    gql_scalar.to_rescript_type(entities_set, gql_enums_name_set)?
                }
                Self::ListType(field_type) => RescriptType::Array(Box::new(
                    field_type.to_rescript_type(entities_set, gql_enums_name_set)?,
                )),
                //This case shouldn't happen, and should recurse without adding any types if so
                //A double non null would be !! in gql
                Self::NonNullType(field_type) => {
                    field_type.to_rescript_type(entities_set, gql_enums_name_set)?
                }
            },
            //If we match this case it missed the non null path entirely and should be optional
            Self::Single(gql_scalar) => RescriptType::Option(Box::new(
                gql_scalar.to_rescript_type(entities_set, gql_enums_name_set)?,
            )),
            //If we match this case it missed the non null path entirely and should be optional
            Self::ListType(field_type) => RescriptType::Option(Box::new(RescriptType::Array(
                Box::new(field_type.to_rescript_type(entities_set, gql_enums_name_set)?),
            ))),
        };
        Ok(composed_type_name)
    }

    fn get_underlying_scalar(&self) -> &GqlScalar {
        match self {
            Self::Single(gql_scalar) => gql_scalar,
            Self::ListType(field_type) | Self::NonNullType(field_type) => {
                field_type.get_underlying_scalar()
            }
        }
    }

    pub fn is_entity_field(&self) -> bool {
        matches!(self.get_underlying_scalar(), GqlScalar::Custom(_))
    }

    fn to_string(&self) -> String {
        match &self {
            Self::Single(gql_scalar) => gql_scalar.to_string(),
            Self::ListType(field_type) => format!("[{}]", field_type.to_string()),
            Self::NonNullType(field_type) => format!("{}!", field_type.to_string()),
        }
    }
}

// Implement the Display trait for the custom struct
impl fmt::Display for FieldType {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.to_string())
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
    BigInt,
    #[subenum(AdditionalGqlScalar)]
    Bytes,
    Custom(String),
}

pub fn ethabi_type_to_field_type(abi_type: &EthAbiParamType) -> anyhow::Result<FieldType> {
    use FieldType::{ListType, NonNullType, Single};
    match abi_type {
        EthAbiParamType::Uint(_size) | EthAbiParamType::Int(_size) => {
            Ok(NonNullType(Box::new(Single(GqlScalar::BigInt))))
        }
        EthAbiParamType::Bool => Ok(NonNullType(Box::new(Single(GqlScalar::Boolean)))),
        EthAbiParamType::Address
        | EthAbiParamType::Bytes
        | EthAbiParamType::String
        | EthAbiParamType::FixedBytes(_) => Ok(NonNullType(Box::new(Single(GqlScalar::String)))),
        EthAbiParamType::Array(abi_type) | EthAbiParamType::FixedArray(abi_type, _) => {
            let inner_type = ethabi_type_to_field_type(abi_type)?;
            Ok(NonNullType(Box::new(ListType(Box::new(inner_type)))))
        }
        EthAbiParamType::Tuple(_abi_types) => Err(anyhow!(
            "Tuples are not handled currently using contract import."
        )),
    }
}

impl From<&str> for GqlScalar {
    fn from(s: &str) -> Self {
        match s {
            "ID" => GqlScalar::ID,
            "String" => GqlScalar::String,
            "Int" => GqlScalar::Int,
            "Float" => GqlScalar::Float, // Should we allow this type? Rounding issues will abound.
            "Boolean" => GqlScalar::Boolean,
            "BigInt" => GqlScalar::BigInt, // NOTE: we aren't setting precision and scale - see (8.1.2) https://www.postgresql.org/docs/current/datatype-numeric.html
            "Bytes" => GqlScalar::Bytes,
            custom_type => GqlScalar::Custom(custom_type.to_string()),
        }
    }
}

impl GqlScalar {
    fn to_postgres_type(
        &self,
        entities_set: &HashSet<String>,
        gql_enums_name_set: &HashSet<String>,
    ) -> anyhow::Result<String> {
        let converted = match self {
            GqlScalar::ID => "text".to_string(),
            GqlScalar::String => "text".to_string(),
            GqlScalar::Int => "integer".to_string(),
            GqlScalar::Float => "numeric".to_string(), // Should we allow this type? Rounding issues will abound.
            GqlScalar::Boolean => "boolean".to_string(),
            GqlScalar::Bytes => "text".to_string(),
            GqlScalar::BigInt => "numeric".to_string(), // NOTE: we aren't setting precision and scale - see (8.1.2) https://www.postgresql.org/docs/current/datatype-numeric.html
            GqlScalar::Custom(named_type) => {
                if entities_set.contains(named_type) {
                    "text".to_string() //This would be the ID of another defined entity
                } else {
                    if gql_enums_name_set.contains(named_type) {
                        named_type.to_capitalized_options().uncapitalized
                    } else {
                        Err(anyhow!(
                            "EE207: Failed to parse undefined type: {}",
                            named_type
                        ))?
                    }
                }
            }
        };
        Ok(converted)
    }

    fn to_rescript_type(
        &self,
        entities_set: &HashSet<String>,
        gql_enums_name_set: &HashSet<String>,
    ) -> anyhow::Result<RescriptType> {
        let res_type = match self {
            GqlScalar::ID => RescriptType::ID,
            GqlScalar::String => RescriptType::String,
            GqlScalar::Int => RescriptType::Int,
            GqlScalar::BigInt => RescriptType::BigInt,
            GqlScalar::Float => RescriptType::Float,
            GqlScalar::Bytes => RescriptType::String,
            GqlScalar::Boolean => RescriptType::Bool,
            GqlScalar::Custom(entity_or_enum_name) => {
                if entities_set.contains(entity_or_enum_name) {
                    RescriptType::ID
                } else {
                    if gql_enums_name_set.contains(entity_or_enum_name) {
                        RescriptType::EnumVariant(entity_or_enum_name.to_capitalized_options())
                    } else {
                        Err(anyhow!(
                            "EE207: Failed to parse undefined type: {}",
                            entity_or_enum_name
                        ))?
                    }
                }
            }
        };
        Ok(res_type)
    }
}

#[cfg(test)]
mod tests {
    use super::{FieldType, GqlScalar, Schema};
    use std::collections::HashSet;

    #[test]
    fn gql_type_to_rescript_type_string() {
        let empty_set = HashSet::new();
        let rescript_type = FieldType::Single(GqlScalar::String)
            .to_rescript_type(&empty_set, &empty_set)
            .expect("expected rescript option string");

        assert_eq!(rescript_type.to_string(), "option<string>".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_int() {
        let empty_set = HashSet::new();
        let rescript_type = FieldType::Single(GqlScalar::Int)
            .to_rescript_type(&empty_set, &empty_set)
            .expect("expected rescript option string");

        assert_eq!(rescript_type.to_string(), "option<int>".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_non_null_int() {
        let empty_set = HashSet::new();
        let rescript_type = FieldType::NonNullType(Box::new(FieldType::Single(GqlScalar::Int)))
            .to_rescript_type(&empty_set, &empty_set)
            .expect("expected rescript type string");

        assert_eq!(rescript_type.to_string(), "int".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_non_null_array() {
        let empty_set = HashSet::new();
        let rescript_type = FieldType::NonNullType(Box::new(FieldType::ListType(Box::new(
            FieldType::NonNullType(Box::new(FieldType::Single(GqlScalar::Int))),
        ))))
        .to_rescript_type(&empty_set, &empty_set)
        .expect("expected rescript type string");

        assert_eq!(rescript_type.to_string(), "array<int>".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_null_array_int() {
        let empty_set = HashSet::new();

        let rescript_type = FieldType::ListType(Box::new(FieldType::Single(GqlScalar::Int)))
            .to_rescript_type(&empty_set, &empty_set)
            .expect("expected rescript type string");

        assert_eq!(
            rescript_type.to_string(),
            "option<array<option<int>>>".to_owned()
        );
    }

    #[test]
    fn gql_type_to_rescript_type_entity() {
        let mut entity_set = HashSet::new();
        let test_entity_string = String::from("TestEntity");
        let empty_enums_set = HashSet::new();
        entity_set.insert(test_entity_string.clone());
        let rescript_type = FieldType::Single(GqlScalar::Custom(test_entity_string))
            .to_rescript_type(&entity_set, &empty_enums_set)
            .expect("expected rescript type string");

        assert_eq!(rescript_type.to_string(), "option<id>".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_enum() {
        let empty_entity_set = HashSet::new();
        let test_enum_string = String::from("TestEnum");
        let mut enums_set = HashSet::new();
        enums_set.insert(test_enum_string.clone());
        let rescript_type = FieldType::Single(GqlScalar::Custom(test_enum_string))
            .to_rescript_type(&empty_entity_set, &enums_set)
            .expect("expected rescript type string");

        assert_eq!(rescript_type.to_string(), "option<testEnum>".to_owned());
    }

    #[test]
    fn field_type_is_optional_test() {
        let test_scalar = GqlScalar::Custom(String::from("TestEntity"));
        let test_field_type = FieldType::Single(test_scalar);
        assert!(
            test_field_type.is_optional(),
            "single field should have been optional"
        );

        // ListType:
        let test_list_type = FieldType::ListType(Box::new(test_field_type));
        assert!(
            test_list_type.is_optional(),
            "list field should have been optional"
        );

        // NonNullType
        let gql_array_non_null_type = FieldType::NonNullType(Box::new(test_list_type));
        assert!(
            !gql_array_non_null_type.is_optional(),
            "non-null field should not be optioonal"
        );
    }

    fn get_field_type_helper(gql_field_str: &str) -> FieldType {
        let schema_string = format!(
            r#"
        type TestEntity @entity {{
          test_field: {}
        }}
        "#,
            gql_field_str
        );
        let schema_doc = graphql_parser::schema::parse_schema::<String>(&schema_string).unwrap();

        let schema = Schema::from_document(schema_doc).expect("bad schema");

        let test_field = schema.entities[0].fields[0].clone();

        test_field.field_type
    }

    fn gql_type_to_postgres_type_test_helper(gql_field_str: &str) -> String {
        let field_type = get_field_type_helper(gql_field_str);
        let empty_entities_set = HashSet::new();
        let empty_enums_set = HashSet::new();
        field_type
            .to_postgres_type(&empty_entities_set, &empty_enums_set, false)
            .expect("unable to get postgres type")
    }
    #[test]
    fn gql_enum_type_to_postgres_type() {
        let field_type = get_field_type_helper("TestEnum!");
        let empty_entities_set = HashSet::new();
        let test_enum_string = String::from("TestEnum");
        let mut enums_set = HashSet::new();
        enums_set.insert(test_enum_string.clone());
        let pg_type = field_type
            .to_postgres_type(&empty_entities_set, &enums_set, false)
            .expect("unable to get postgres type");
        assert_eq!(pg_type, "testEnum NOT NULL");
    }

    #[test]
    fn gql_single_not_null_array_to_pg_type() {
        let gql_type = "[String!]!";
        let pg_type = gql_type_to_postgres_type_test_helper(gql_type);
        assert_eq!(pg_type, "text[] NOT NULL");
    }

    #[test]
    fn gql_multi_not_null_array_to_pg_type() {
        let gql_type = "[[Int!]!]!";
        let pg_type = gql_type_to_postgres_type_test_helper(gql_type);
        assert_eq!(pg_type, "integer[][] NOT NULL");
    }

    #[test]
    #[should_panic]
    fn gql_single_nullable_array_to_pg_type_should_panic() {
        let gql_type = "[Int]!"; //Nested lists need to be not nullable
        gql_type_to_postgres_type_test_helper(gql_type);
    }

    #[test]
    #[should_panic]
    fn gql_multi_nullable_array_to_pg_type_should_panic() {
        let gql_type = "[[Int!]]!"; //Nested lists need to be not nullable
        gql_type_to_postgres_type_test_helper(gql_type);
    }

    #[test]
    fn test_nullability_to_string() {
        use FieldType::{ListType, NonNullType, Single};
        let scalar = NonNullType(Box::new(ListType(Box::new(Single(GqlScalar::Int)))));

        let expected_output = "[Int]!".to_string();

        assert_eq!(scalar.to_string(), expected_output);
    }

    #[test]
    fn gql_type_to_rescript_nullable() {
        let field_type = get_field_type_helper("Int");

        let empty_entities_set = HashSet::new();
        let empty_enums_set = HashSet::new();
        let rescript_type = field_type
            .to_rescript_type(&empty_entities_set, &empty_enums_set)
            .unwrap();
        assert_eq!("option<int>".to_string(), rescript_type.to_string());
    }

    #[test]
    fn gql_type_to_rescript_array_nullable_string() {
        let field_type = get_field_type_helper("[String]!");

        let empty_entities_set = HashSet::new();
        let empty_enums_set = HashSet::new();
        let rescript_type = field_type
            .to_rescript_type(&empty_entities_set, &empty_enums_set)
            .unwrap();
        assert_eq!(
            "array<option<string>>".to_string(),
            rescript_type.to_string()
        );
    }
}
