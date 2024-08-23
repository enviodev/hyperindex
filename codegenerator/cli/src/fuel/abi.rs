use anyhow::{anyhow, Context, Result};
use fuel_abi_types::abi::program::{ConcreteTypeId, MetadataTypeId, TypeId};
use fuel_abi_types::abi::unified_program::{UnifiedProgramABI, UnifiedTypeApplication};
use itertools::Itertools;
use std::{collections::HashMap, fs, path::PathBuf};

use crate::rescript_types::{
    RescriptRecordField, RescriptTypeDecl, RescriptTypeDeclMulti, RescriptTypeExpr,
    RescriptTypeIdent, RescriptVariantConstr,
};

#[derive(Debug, Clone, PartialEq)]
pub struct FuelType {
    pub id: TypeId,
    pub rescript_type_decl: RescriptTypeDecl,
    pub abi_type_field: String,
}

impl FuelType {
    fn get_event_name(self: &Self) -> String {
        match self.abi_type_field.as_str() {
            "()" => "UnitLog",
            "bool" => "BoolLog",
            "u8" => "U8Log",
            "u16" => "U16Log",
            "u32" => "U32Log",
            "u64" => "U64Log",
            "u128" => "U128Log",
            "raw untyped ptr" => "RawUntypedPtrLog",
            "b256" => "B256Log",
            "address" => "AddressLog",
            "Vec" => "VecLog",
            "str" => "StrLog",
            type_field if type_field.starts_with("str[") => "StrLog",
            "enum Option" => "OptionLog",
            type_field if type_field.starts_with("struct ") => type_field
                .strip_prefix("struct ")
                .unwrap_or_else(|| "StructLog"),
            type_field if type_field.starts_with("enum ") => type_field
                .strip_prefix("enum ")
                .unwrap_or_else(|| "EnumLog"),
            type_field if type_field.starts_with("(_,") => "TupleLog",
            type_field if type_field.starts_with("[_;") => "ArrayLog",
            _ => "UnknownLog",
        }
        .to_string()
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct FuelLog {
    pub id: String,
    pub logged_type: FuelType,
    pub event_name: String,
    pub data_type: RescriptTypeIdent,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Abi {
    pub path_buf: PathBuf,
    pub path: String,
    pub raw: String,
    program: UnifiedProgramABI,
    logs: HashMap<String, FuelLog>,
    types: HashMap<TypeId, FuelType>,
}

impl Abi {
    fn decode_program(raw: &String) -> Result<UnifiedProgramABI> {
        Ok(UnifiedProgramABI::from_json_abi(raw)?)
    }

    fn decode_types(program: &UnifiedProgramABI) -> Result<HashMap<TypeId, FuelType>> {
        let mut types_map: HashMap<TypeId, FuelType> = HashMap::new();

        fn mk_type_id_name(type_id: &TypeId) -> String {
            match type_id {
                TypeId::Concrete(ConcreteTypeId(id)) => format!("concrete_type_id_{}", id),
                TypeId::Metadata(MetadataTypeId(id)) => format!("metadata_type_id_{}", id),
            }
        }

        let get_unknown_res_type_ident = |type_field: &str| {
            println!("Unhandled type_field \"{}\" in abi", type_field);
            RescriptTypeIdent::TypeApplication {
                name: "unknown".to_string(),
                type_params: vec![],
            }
        };

        let get_unknown_res_type_expr =
            |type_field| RescriptTypeExpr::Identifier(get_unknown_res_type_ident(type_field));

        for type_decl in &program.types {
            if type_decl.type_field.starts_with("generic") {
                continue;
            }

            let type_id = TypeId::Metadata(MetadataTypeId(type_decl.type_id));
            let name = mk_type_id_name(&type_id);

            let get_first_type_param = || match &type_decl.type_parameters {
                Some(args) if args.len() == 1 => {
                    Ok(mk_type_id_name(&TypeId::Metadata(MetadataTypeId(args[0]))))
                }
                Some(args) => Err(anyhow!("Expected single type param but got {}", args.len())),
                None => Err(anyhow!("Expected type parameters, but found None")),
            };

            let get_components_name_and_type_ident = || {
                type_decl
                    .components
                    .as_ref()
                    .ok_or(anyhow!(
                        "Expected type_id '{:?}' components to be 'Some'",
                        type_id
                    ))?
                    .iter()
                    .map(|comp| {
                        let name = comp.name.clone();
                        let type_ident_name =
                            mk_type_id_name(&TypeId::Metadata(MetadataTypeId(comp.type_id)));
                        let type_ident = match &comp.type_arguments {
                            None => RescriptTypeIdent::TypeApplication {
                                name: type_ident_name,
                                type_params: vec![],
                            },
                            Some(typ_args) => {
                                let type_params = typ_args
                                    .iter()
                                    .map(|ta| RescriptTypeIdent::TypeApplication {
                                        name: mk_type_id_name(&TypeId::Metadata(MetadataTypeId(
                                            ta.type_id,
                                        ))),
                                        type_params: vec![],
                                    })
                                    .collect();
                                RescriptTypeIdent::TypeApplication {
                                    name: type_ident_name,
                                    type_params,
                                }
                            }
                        };
                        Ok((name, type_ident))
                    })
                    .collect::<Result<Vec<_>>>()
            };

            let type_expr: Result<RescriptTypeExpr> = {
                use RescriptTypeIdent::*;
                match type_decl.type_field.as_str() {
                    "()" => Unit.to_ok_expr(),
                    "bool" => Bool.to_ok_expr(), //Note this is represented as 0 or 1
                    //NOTE: its possible when doing rescript int operations you can
                    //overflow with u32 but its a rare case and likely user will do operation
                    //int ts/js
                    "u8" | "u16" | "u32" => Int.to_ok_expr(),
                    "u64" | "u128" | "u256" | "raw untyped ptr" => BigInt.to_ok_expr(),
                    "b256" | "address" => String.to_ok_expr(),
                    "str" => String.to_ok_expr(),
                    type_field if type_field.starts_with("str[") => String.to_ok_expr(),
                    "struct Vec" => Array(Box::new(GenericParam(
                        get_first_type_param().context("Failed getting param for struct Vec")?,
                    )))
                    .to_ok_expr(),
                    "enum Option" => Option(Box::new(GenericParam(
                        get_first_type_param().context("Failed getting param for enum Option")?,
                    )))
                    .to_ok_expr(),
                    type_field if type_field.starts_with("struct ") => {
                        let record_fields = get_components_name_and_type_ident()
                            .context(format!(
                                "Failed getting name and identifier from components for \
                                 {type_field}",
                            ))?
                            .into_iter()
                            .map(|(name, type_ident)| RescriptRecordField::new(name, type_ident))
                            .collect();
                        Ok(RescriptTypeExpr::Record(record_fields))
                    }
                    type_field if type_field.starts_with("enum ") => {
                        let constructors = get_components_name_and_type_ident()
                            .context(format!(
                                "Failed getting name and identifier from components for \
                                 {type_field}",
                            ))?
                            .into_iter()
                            .map(|(name, type_ident)| RescriptVariantConstr::new(name, type_ident))
                            .collect();
                        Ok(RescriptTypeExpr::Variant(constructors))
                    }
                    type_field if type_field.starts_with("(_,") => {
                        let tuple_types = get_components_name_and_type_ident()
                            .context(format!(
                                "Failed getting name and identifier from components for tuple \
                                 {type_field}",
                            ))?
                            .into_iter()
                            .map(|(_name, type_ident)| type_ident)
                            .collect();

                        RescriptTypeIdent::Tuple(tuple_types).to_ok_expr()
                    }
                    type_field if type_field.starts_with("[_;") => {
                        let components = get_components_name_and_type_ident().context(format!(
                            "Failed getting name and identifier from components for \
                                 {type_field}",
                        ))?;
                        let element_name_and_type_ident = components
                            .first()
                            .ok_or(anyhow!("Missing array element type component"))?;
                        Array(Box::new(element_name_and_type_ident.1.clone())).to_ok_expr()
                    }
                    type_field => {
                        //Unknown
                        Ok(get_unknown_res_type_expr(type_field))
                    }
                }
            };

            let type_params = type_decl
                .type_parameters
                .as_ref()
                .map_or(Ok(vec![]), |tps| {
                    tps.iter()
                        .map(|tp| Ok(mk_type_id_name(&TypeId::Metadata(MetadataTypeId(*tp)))))
                        .collect::<Result<Vec<_>>>()
                })
                .context(format!(
                    "Failed getting type parameter names for type_id '{:?}'",
                    type_id
                ))?;

            types_map.insert(
                type_id.clone(),
                FuelType {
                    id: type_id.clone(),
                    abi_type_field: type_decl.type_field.clone(),
                    rescript_type_decl: RescriptTypeDecl::new(name, type_expr?, type_params),
                },
            );
        }

        Ok(types_map)
    }

    fn get_type_application(
        abi_application: &UnifiedTypeApplication,
        types: &HashMap<TypeId, FuelType>,
    ) -> Result<RescriptTypeIdent> {
        let fuel_type = types
            .get(&TypeId::Metadata(MetadataTypeId(abi_application.type_id)))
            .context("Failed to get logged type")?;
        Ok(RescriptTypeIdent::TypeApplication {
            name: fuel_type.rescript_type_decl.name.clone(),
            type_params: match &abi_application.type_arguments {
                Some(vec) => vec
                    .iter()
                    .map(|a| Self::get_type_application(a, types))
                    .collect::<Result<Vec<_>>>()?,
                None => vec![],
            },
        })
    }

    fn decode_logs(
        program: &UnifiedProgramABI,
        types: &HashMap<TypeId, FuelType>,
    ) -> Result<HashMap<String, FuelLog>> {
        let mut logs_map: HashMap<String, FuelLog> = HashMap::new();
        let mut names_count: HashMap<String, u8> = HashMap::new();

        if let Some(logged_types) = &program.logged_types {
            for abi_log in logged_types.iter() {
                let id = abi_log.log_id.clone();
                let type_id = TypeId::Metadata(MetadataTypeId(abi_log.application.type_id));
                let logged_type = types.get(&type_id).context("Failed to get logged type")?;

                let event_name = {
                    // Since Event name doesn't consider the type children, there might be duplications.
                    // Prevent it by adding a postfix when an event_name appears more than one time
                    let mut event_name = logged_type.get_event_name();
                    // Extract only the last segment of the event name - NOTE: we can
                    event_name = event_name
                        .split("::")
                        .last()
                        .unwrap_or(&event_name)
                        .to_string();
                    let event_name_count = names_count.get(&event_name).unwrap_or(&0);
                    let event_name_count = event_name_count + 1;
                    // TODO: since we now have the namespace of these sway structs, we wouldn't need to append numbers at the end in future versions (we can use the namespace to differentiate them)
                    if event_name_count > 1 {
                        event_name = format!("{event_name}{}", event_name_count)
                    }
                    names_count.insert(event_name.clone(), event_name_count);
                    event_name
                };

                logs_map.insert(
                    id.clone(),
                    FuelLog {
                        id,
                        event_name,
                        data_type: Self::get_type_application(&abi_log.application, types)?,
                        logged_type: logged_type.clone(),
                    },
                );
            }
        } else {
            Err(anyhow!("ABI doesn't contain defined logged types"))?
        }

        Ok(logs_map)
    }

    pub fn parse(path_buf: PathBuf) -> Result<Self> {
        let path = path_buf
            .to_str()
            .context("The ABI file path is invalid Unicode")?
            .to_string();
        let raw = fs::read_to_string(&path_buf)
            .context(format!("Failed to read Fuel ABI file at \"{}\"", path))?;
        let program = Self::decode_program(&raw).context(format!(
            "Failed to decode program of Fuel ABI file at \"{}\"",
            path
        ))?;
        let types = Self::decode_types(&program).context(format!(
            "Failed to decode types of Fuel ABI file at \"{}\"",
            path
        ))?;
        let logs = Self::decode_logs(&program, &types).context(format!(
            "Failed to decode logs of Fuel ABI file at \"{}\"",
            path
        ))?;
        Ok(Self {
            path,
            path_buf,
            raw,
            program,
            logs,
            types,
        })
    }

    pub fn get_log(&self, log_id: &String) -> Result<FuelLog> {
        match self.logs.get(log_id) {
            Some(log) => Ok(log.clone()),
            None => Err(anyhow!("ABI doesn't contain logged type with id {log_id}")),
        }
    }

    pub fn get_type_by_struct_name(&self, struct_name: String) -> Result<FuelType> {
        let type_name_struct = format!("struct {struct_name}");
        let type_name_enum = format!("enum {struct_name}");
        match self
            .program
            .types
            .iter()
            .find(|t| t.type_field == type_name_struct || t.type_field == type_name_enum)
        {
            Some(t) => self
                .types
                .get(&TypeId::Metadata(MetadataTypeId(t.type_id)))
                .cloned()
                .context(format!("Couldn't find decoded type for id {}", t.type_id)),
            None => Err(anyhow!(
                "ABI doesn't contain type for the struct {struct_name}"
            )),
        }
    }

    pub fn get_log_by_type(&self, type_id: TypeId) -> Result<FuelLog> {
        self.logs
            .values()
            .find(|&log| log.logged_type.id == type_id)
            .cloned()
            .ok_or(anyhow!("Failed to find log by type id {type_id:?}"))
    }

    pub fn get_logs(&self) -> Vec<FuelLog> {
        self.logs.values().cloned().collect()
    }

    pub fn to_rescript_type_decl_multi(&self) -> Result<RescriptTypeDeclMulti> {
        let type_declerations = self
            .types
            .values()
            .sorted_by_key(|t| match &t.id {
                TypeId::Concrete(ConcreteTypeId(id)) => id.clone(),
                TypeId::Metadata(MetadataTypeId(id)) => id.to_string(),
            })
            .map(|t| t.rescript_type_decl.clone())
            .collect();

        Ok(RescriptTypeDeclMulti::new(type_declerations))
    }
}
