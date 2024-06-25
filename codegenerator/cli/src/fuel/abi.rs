use anyhow::{anyhow, Context, Result};
use fuel_abi_types::abi::program::ProgramABI;
use itertools::Itertools;
use std::{collections::HashMap, fs, path::PathBuf};

use crate::rescript_types::{
    RescriptRecordField, RescriptTypeDecl, RescriptTypeDeclMulti, RescriptTypeExpr,
    RescriptTypeIdent, RescriptVariantConstr,
};

#[derive(Debug, Clone, PartialEq)]
pub struct FuelType {
    pub id: usize,
    pub rescript_type_decl: RescriptTypeDecl,
    abi_type_field: String,
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
}

#[derive(Debug, Clone, PartialEq)]
pub struct Abi {
    pub path_buf: PathBuf,
    pub path: String,
    pub raw: String,
    program: ProgramABI,
    logs: HashMap<String, FuelLog>,
    types: HashMap<usize, FuelType>,
}

impl Abi {
    fn decode_program(raw: &String) -> Result<ProgramABI> {
        let program: ProgramABI = serde_json::from_str(&raw)?;
        Ok(program)
    }

    fn decode_types(program: &ProgramABI) -> Result<HashMap<usize, FuelType>> {
        let mut types_map: HashMap<usize, FuelType> = HashMap::new();

        //eg "generic T" returns "T" for keyword "generic"
        fn extract_value_after_keyword(keyword: &str, input: &str) -> Option<String> {
            if let Some(start) = input.find(keyword) {
                // Calculate the start position of the value after "keyword"
                let value_start = start + keyword.len();
                // Extract the value and trim any leading/trailing whitespace
                let value = input[value_start..].trim();
                if !value.is_empty() {
                    return Some(value.to_string());
                }
            }
            None
        }

        fn mk_type_id_name(type_id: &usize) -> String {
            format!("type_id_{}", type_id)
        }

        let generic_param_name_map = program
            .types
            .iter()
            .filter_map(|type_decl| {
                let generic_param_name =
                    extract_value_after_keyword("generic", &type_decl.type_field)?;
                Some((type_decl.type_id, generic_param_name))
            })
            .collect::<HashMap<usize, String>>();

        let get_unknown_res_type_ident = |type_field: &str| {
            println!("Unhandled type_field \"{}\" in abi", type_field);
            RescriptTypeIdent::NamedType("unknown".to_string())
        };

        let get_unknown_res_type_expr =
            |type_field| RescriptTypeExpr::Identifier(get_unknown_res_type_ident(type_field));

        program
            .types
            .iter()
            .map(|abi_type_decl| {
                if abi_type_decl.type_field.starts_with("generic") {
                    //Generic fields are simple the name of the parameter
                    //like "T", they should not be declared as types in resript
                    return Ok(None);
                }
                let name = mk_type_id_name(&abi_type_decl.type_id);

                let get_first_type_param = || match abi_type_decl
                    .type_parameters
                    .clone()
                    .unwrap_or(vec![])
                    .as_slice()
                {
                    [type_id] => generic_param_name_map.get(type_id).cloned().ok_or(anyhow!(
                        "type_id '{type_id}' should exist in generic_param_name_map"
                    )),
                    params => Err(anyhow!(
                        "Expected single type param but got {}",
                        params.len()
                    )),
                };

                let get_components_name_and_type_ident = || {
                    abi_type_decl
                        .components
                        .clone()
                        .ok_or(anyhow!(
                            "Expected type_id '{}' components to be 'Some'",
                            abi_type_decl.type_id
                        ))?
                        .iter()
                        .map(|comp| {
                            let name = comp.name.clone();
                            let type_ident_name = mk_type_id_name(&comp.type_id);
                            let type_ident = match &comp.type_arguments {
                                //When there are no type arguments it is a named type or a generic param
                                None => generic_param_name_map.get(&comp.type_id).cloned().map_or(
                                    //If the type_id is not a defined generic type it is
                                    //a named type
                                    RescriptTypeIdent::NamedType(type_ident_name),
                                    //if the type_id is in the generic_param_name_map
                                    //it is a generic param
                                    |generic_name| RescriptTypeIdent::GenericParam(generic_name),
                                ),
                                //When there are type arguments it is a generic type
                                Some(typ_args) => {
                                    let type_params = typ_args
                                        .iter()
                                        .map(|ta| {
                                            generic_param_name_map.get(&ta.type_id).cloned().map_or(
                                                //If the type_id is not a defined generic type it is
                                                //a named type
                                                RescriptTypeIdent::NamedType(mk_type_id_name(
                                                    &ta.type_id,
                                                )),
                                                //if the type_id is in the generic_param_name_map
                                                //it is a generic param
                                                |generic_name| {
                                                    RescriptTypeIdent::GenericParam(generic_name)
                                                },
                                            )
                                        })
                                        .collect();
                                    RescriptTypeIdent::Generic {
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
                    match abi_type_decl.type_field.as_str() {
                        "()" => Unit.to_ok_expr(),
                        "bool" => Bool.to_ok_expr(), //Note this is represented as 0 or 1
                        //NOTE: its possible when doing rescript int operations you can
                        //overflow with u32 but its a rare case and likely user will do operation
                        //int ts/js
                        "u8" | "u16" | "u32" => Int.to_ok_expr(),
                        "u64" | "u128" | "u256" | "raw untyped ptr" => BigInt.to_ok_expr(),
                        "b256" | "address" => String.to_ok_expr(),
                        type_field if type_field.starts_with("str[") => String.to_ok_expr(),
                        "struct Vec" => Array(Box::new(GenericParam(
                            get_first_type_param()
                                .context("Failed getting param for struct Vec")?,
                        )))
                        .to_ok_expr(),
                        //TODO: handle nested option since this would need to be flattened to
                        //single level rescript option.
                        "enum Option" => Option(Box::new(GenericParam(
                            get_first_type_param()
                                .context("Failed getting param for enum Option")?,
                        )))
                        .to_ok_expr(),
                        type_field if type_field.starts_with("struct ") => {
                            let record_fields = get_components_name_and_type_ident()
                                .context(format!(
                                    "Failed getting name and identifier from components for \
                                   {type_field}",
                                ))?
                                .into_iter()
                                .map(|(name, type_ident)| {
                                    RescriptRecordField::new(name, type_ident)
                                })
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
                                .map(|(name, type_ident)| {
                                    RescriptVariantConstr::new(name, type_ident)
                                })
                                .collect();
                            Ok(RescriptTypeExpr::Variant(constructors))
                        }
                        type_field if type_field.starts_with("(_,") => {
                            let tuple_types = get_components_name_and_type_ident()
                                .context(format!(
                                    "Failed getting name and identifier from components for \
                                   tuple {type_field}",
                                ))?
                                .into_iter()
                                .map(|(_name, type_ident)| type_ident)
                                .collect();

                            RescriptTypeIdent::Tuple(tuple_types).to_ok_expr()
                        }
                        type_field if type_field.starts_with("[_;") => {
                            //TODO handle fixed array
                            Ok(get_unknown_res_type_expr(type_field))
                        }
                        type_field => {
                            //Unknown
                            Ok(get_unknown_res_type_expr(type_field))
                        }
                    }
                };

                let type_params = abi_type_decl
                    .type_parameters
                    .as_ref()
                    .map_or(Ok(vec![]), |tps| {
                        tps.iter()
                            .map(|tp| {
                                generic_param_name_map
                                    .get(tp)
                                    .ok_or(anyhow!(
                                        "param name for type_id {tp} should exist in \
                                       generic_param_name_map"
                                    ))
                                    .cloned()
                            })
                            .collect::<Result<Vec<_>>>()
                    })
                    .context(format!(
                        "Failed getting type paramater names for type_id '{}'",
                        abi_type_decl.type_id
                    ))?;

                Ok(Some(FuelType {
                    id: abi_type_decl.type_id,
                    abi_type_field: abi_type_decl.type_field.clone(),
                    rescript_type_decl: RescriptTypeDecl::new(name, type_expr?, type_params),
                }))
            })
            .collect::<Result<Vec<Option<FuelType>>>>()
            .context("Failed getting type declarations from fuel abi")?
            .into_iter()
            //Filter out None values since these are declarations we don't want (ie generics)
            .filter_map(|x| x)
            .for_each(|v| {
                types_map.insert(v.id, v);
            });

        Ok(types_map)
    }

    fn decode_logs(
        program: &ProgramABI,
        types: &HashMap<usize, FuelType>,
    ) -> Result<HashMap<String, FuelLog>> {
        let mut logs_map: HashMap<String, FuelLog> = HashMap::new();
        let mut names_count: HashMap<String, u8> = HashMap::new();

        if let Some(logged_types) = &program.logged_types {
            for logged_type in logged_types.iter() {
                let id = logged_type.log_id.clone();
                let type_id = logged_type.application.type_id;
                let logged_type = types.get(&type_id).context("Failed to get logged type")?;

                let event_name = {
                    // Since Event name doesn't consider the type children, there might be duplications.
                    // Prevent it by adding a postfix when an even_name appears more than one time
                    let mut event_name = logged_type.get_event_name();
                    let event_name_count = names_count.get(&event_name).unwrap_or(&0);
                    let event_name_count = event_name_count + 1;
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
                        event_name: event_name,
                        logged_type: logged_type.clone(),
                    },
                );
            }
        } else {
            Err(anyhow!("ABI doesn't contained defined logged types"))?
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
                .get(&t.type_id)
                .cloned()
                .context(format!("Couldn't find decoded type for id {}", t.type_id)),
            None => Err(anyhow!(
                "ABI doesn't contain type for the struct {struct_name}"
            )),
        }
    }

    pub fn get_log_ids_by_type(&self, type_id: usize) -> Vec<String> {
        self.logs
            .values()
            .filter_map(|log| {
                if log.logged_type.id == type_id {
                    Some(log.id.clone())
                } else {
                    None
                }
            })
            .sorted()
            .collect()
    }

    pub fn get_logs(&self) -> Vec<FuelLog> {
        self.logs.values().cloned().collect()
    }

    pub fn to_rescript_type_decl_multi(&self) -> Result<RescriptTypeDeclMulti> {
        let type_declerations = self
            .types
            .values()
            .sorted_by_key(|t| t.id)
            .map(|t| t.rescript_type_decl.clone())
            .collect();

        Ok(RescriptTypeDeclMulti::new(type_declerations))
    }
}
