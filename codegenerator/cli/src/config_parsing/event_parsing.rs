use alloy_dyn_abi::DynSolType;
use itertools::Itertools;

use crate::config_parsing::abi_compat::EventParam;
use crate::type_schema::{RecordField, SchemaMode, TypeIdent};

pub struct EthereumEventParam<'a> {
    pub name: &'a str,
    abi_type: &'a DynSolType,
}

impl<'a> From<&'a EventParam> for EthereumEventParam<'a> {
    fn from(abi_param: &'a EventParam) -> EthereumEventParam<'a> {
        EthereumEventParam {
            name: &abi_param.name,
            abi_type: &abi_param.kind,
        }
    }
}

impl EthereumEventParam<'_> {
    /// Returns the depth of the nested type
    /// A value type would return 0
    /// An array or tuple type would have a nested type
    /// Tuple depth is only calculated on the first element of the tuple
    /// as this corrisponds with the check on SingleOrMultiple in the rescript code
    pub fn get_nested_type_depth(&self) -> usize {
        fn rec(param: &DynSolType, accum: usize) -> usize {
            match param {
                DynSolType::Tuple(params) => match params.first() {
                    Some(p) => rec(p, accum + 1),
                    None => accum,
                },
                DynSolType::Array(p) | DynSolType::FixedArray(p, _) => rec(p, accum + 1),
                _ => accum,
            }
        }
        rec(self.abi_type, 0)
    }

    pub fn get_topic_encoder(&self) -> String {
        struct IsValueEncoder(bool);
        struct IsNestedType(bool);
        fn rec(param: &DynSolType, is_nested_type: IsNestedType) -> (String, IsValueEncoder) {
            fn value_encoder(encoder: &str) -> (String, IsValueEncoder) {
                (encoder.to_string(), IsValueEncoder(true))
            }
            fn non_value_encoder(encoder: &str) -> (String, IsValueEncoder) {
                (encoder.to_string(), IsValueEncoder(false))
            }
            match &param {
                DynSolType::String | DynSolType::Bytes if !is_nested_type.0 => {
                    //In the case of a string or bytes param we simply create a keccak256 hash of the value
                    //unless it is a nested type inside a tuple or array
                    non_value_encoder("TopicFilter.castToHexUnsafe")
                }
                // Since we have bytes as a string type,
                // they should already be passed to event filters as a hex
                // NOTE: This is tested only for the bytes32 type
                // Might need to keccak256 for bigger size or pad for smaller size
                DynSolType::FixedBytes(_) if !is_nested_type.0 => {
                    value_encoder("TopicFilter.castToHexUnsafe")
                }
                DynSolType::Address => value_encoder("TopicFilter.fromAddress"),
                DynSolType::Uint(_) => value_encoder("TopicFilter.fromBigInt"),
                DynSolType::Int(_) => value_encoder("TopicFilter.fromSignedBigInt"),
                DynSolType::Bytes | DynSolType::FixedBytes(_) => {
                    value_encoder("TopicFilter.fromBytes")
                }
                DynSolType::Bool => value_encoder("TopicFilter.fromBool"),
                DynSolType::String => value_encoder("TopicFilter.fromString"),
                DynSolType::Tuple(params) => {
                    //TODO: test for nested tuples
                    let tuple_arg = "tuple";
                    let params_applied = params
                        .iter()
                        .enumerate()
                        .map(|(i, p)| {
                            let (param_encoder, _) = rec(p, IsNestedType(true));
                            format!(
                                "{tuple_arg}->Utils.Tuple.get({i})->Belt.Option.\
                                 getUnsafe->{param_encoder}"
                            )
                        })
                        .collect::<Vec<_>>()
                        .join(", ");

                    non_value_encoder(
                        format!("({tuple_arg}) => TopicFilter.concat([{params_applied}])").as_str(),
                    )
                }
                DynSolType::Array(p) | DynSolType::FixedArray(p, _) => {
                    let (param_encoder, _) = rec(p, IsNestedType(true));
                    non_value_encoder(
                        format!(
                            "(arr) => TopicFilter.concat(arr->Belt.Array.map({param_encoder}))"
                        )
                        .as_str(),
                    )
                }
                DynSolType::Function => {
                    unreachable!("Function type should be filtered out before reaching here")
                }
            }
        }
        match rec(self.abi_type, IsNestedType(false)) {
            (encoder, IsValueEncoder(false)) => {
                format!("(value) => TopicFilter.keccak256(value->{encoder})")
            }
            (encoder, IsValueEncoder(true)) => encoder,
        }
    }
}

pub fn abi_to_rescript_type(param: &EthereumEventParam) -> TypeIdent {
    match &param.abi_type {
        DynSolType::Uint(_) => TypeIdent::BigInt,
        DynSolType::Int(_) => TypeIdent::BigInt,
        DynSolType::Bool => TypeIdent::Bool,
        DynSolType::Address => TypeIdent::Address,
        DynSolType::Bytes => TypeIdent::String,
        DynSolType::String => TypeIdent::String,
        DynSolType::FixedBytes(_) => TypeIdent::String,
        DynSolType::Function => {
            unreachable!("Function type should be filtered out before reaching here")
        }
        DynSolType::Array(abi_type) => {
            let sub_param = EthereumEventParam {
                abi_type,
                name: param.name,
            };
            TypeIdent::Array(Box::new(abi_to_rescript_type(&sub_param)))
        }
        DynSolType::FixedArray(abi_type, _) => {
            let sub_param = EthereumEventParam {
                abi_type,
                name: param.name,
            };

            TypeIdent::Array(Box::new(abi_to_rescript_type(&sub_param)))
        }
        DynSolType::Tuple(abi_types) => {
            let rescript_types: Vec<TypeIdent> = abi_types
                .iter()
                .map(|abi_type| {
                    let ethereum_param = EthereumEventParam {
                        // Note the name doesn't matter since it's creating tuple without keys
                        //   it is only included so that the type is the same for recursion.
                        name: "",
                        abi_type,
                    };

                    abi_to_rescript_type(&ethereum_param)
                })
                .collect();

            TypeIdent::Tuple(rescript_types)
        }
    }
}

/// Represents an auxiliary type declaration generated for a Solidity struct type.
/// When a tuple in the ABI has all named components (i.e., it represents a Solidity struct),
/// a separate named record type is generated instead of an unnamed tuple.
#[derive(Debug, Clone)]
pub struct AuxTypeDecl {
    pub name: String,
    pub fields: Vec<RecordField>,
}

impl AuxTypeDecl {
    /// Generate the ReScript type declaration string (with @genType annotation)
    pub fn to_type_decl_string(&self) -> String {
        let fields_str = self.fields.iter().map(|f| f.to_string()).join(", ");
        format!("@genType\ntype {} = {{{}}}", self.name, fields_str)
    }

    /// Generate the ReScript schema declaration string.
    /// Uses S.tuple to read from a JSON array (which is how ABI-decoded structs arrive at runtime)
    /// but produces a record with named fields.
    pub fn to_schema_decl_string(&self, mode: &SchemaMode) -> String {
        let inner_str = self
            .fields
            .iter()
            .enumerate()
            .map(|(index, field)| {
                format!(
                    "{}: s.item({index}, {})",
                    field.name,
                    field.type_ident.to_rescript_schema(mode)
                )
            })
            .join(", ");
        format!(
            "let {}Schema = S.tuple((s): {} => {{{inner_str}}})",
            self.name, self.name
        )
    }

    /// Generate the fromArray converter function for HyperSync compatibility.
    /// Converts a raw array (from ABI decoding) to a named record.
    pub fn to_from_array_decl_string(&self) -> String {
        let fields_str = self
            .fields
            .iter()
            .enumerate()
            .map(|(index, field)| {
                let conversion = Self::field_from_array_conversion(&field.type_ident, index);
                format!("{}: {}", field.name, conversion)
            })
            .join(", ");
        format!(
            "let {name}_fromArray = (arr: array<unknown>): {name} => {{{fields_str}}}",
            name = self.name
        )
    }

    /// Generate the ReScript default value declaration
    pub fn to_default_decl_string(&self) -> String {
        let fields_str = self
            .fields
            .iter()
            .map(|f| format!("{}: {}", f.name, f.type_ident.get_default_value_rescript()))
            .join(", ");
        format!(
            "let {}Default: {} = {{{fields_str}}}",
            self.name, self.name
        )
    }

    /// Generate conversion code for a single field when converting from an array.
    fn field_from_array_conversion(type_ident: &TypeIdent, index: usize) -> String {
        match type_ident {
            TypeIdent::TypeApplication {
                name, type_params, ..
            } if type_params.is_empty() => {
                // This field is itself a struct type - use its fromArray converter
                format!(
                    "arr->Js.Array2.unsafe_get({index})->\
                     (Utils.magic: 'a => array<unknown>)->\
                     {name}_fromArray"
                )
            }
            TypeIdent::Array(inner) => match inner.as_ref() {
                TypeIdent::TypeApplication {
                    name, type_params, ..
                } if type_params.is_empty() => {
                    // Array of struct types - map with fromArray converter
                    format!(
                        "arr->Js.Array2.unsafe_get({index})->\
                         (Utils.magic: 'a => array<array<unknown>>)->\
                         Belt.Array.map({name}_fromArray)"
                    )
                }
                _ => {
                    format!("arr->Js.Array2.unsafe_get({index})->Utils.magic")
                }
            },
            _ => {
                format!("arr->Js.Array2.unsafe_get({index})->Utils.magic")
            }
        }
    }
}

/// Check if an event param represents a named struct (all components have non-empty names).
fn is_named_struct(param: &EventParam) -> bool {
    !param.components.is_empty() && param.components.iter().all(|c| !c.name.is_empty())
}

/// Convert an ABI type to a ReScript type, generating named record types for Solidity structs.
///
/// When a tuple has all named components (indicating a Solidity struct), this function
/// generates a separate named record type declaration (AuxTypeDecl) and returns a
/// TypeApplication reference to it. Unnamed tuples remain as TypeIdent::Tuple.
///
/// The `prefix` parameter is used to generate unique type names for nested structs
/// (e.g., "eventArgs" for top-level, "eventArgs_commonParams" for nested).
pub fn abi_to_rescript_type_with_structs(
    param: &EventParam,
    prefix: &str,
) -> (TypeIdent, Vec<AuxTypeDecl>) {
    match &param.kind {
        DynSolType::Tuple(abi_types) if is_named_struct(param) => {
            let struct_name = format!("{}_{}", prefix, RecordField::to_valid_rescript_name(&param.name));
            let mut all_aux_decls = vec![];

            let fields: Vec<RecordField> = param
                .components
                .iter()
                .zip(abi_types.iter())
                .map(|(comp, _abi_type)| {
                    let (inner_type, inner_aux) =
                        abi_to_rescript_type_with_structs(comp, &struct_name);
                    all_aux_decls.extend(inner_aux);
                    RecordField::new(comp.name.clone(), inner_type)
                })
                .collect();

            all_aux_decls.push(AuxTypeDecl {
                name: struct_name.clone(),
                fields,
            });

            (
                TypeIdent::TypeApplication {
                    name: struct_name,
                    type_params: vec![],
                },
                all_aux_decls,
            )
        }
        DynSolType::Array(inner_abi_type) | DynSolType::FixedArray(inner_abi_type, _) => {
            // For arrays, the components describe the inner element type
            let inner_param = EventParam {
                name: param.name.clone(),
                kind: *inner_abi_type.clone(),
                indexed: false,
                components: param.components.clone(),
            };
            let (inner_type, aux) = abi_to_rescript_type_with_structs(&inner_param, prefix);
            (TypeIdent::Array(Box::new(inner_type)), aux)
        }
        _ => {
            // For non-struct types, use the original conversion
            let eth_param = EthereumEventParam {
                name: &param.name,
                abi_type: &param.kind,
            };
            (abi_to_rescript_type(&eth_param), vec![])
        }
    }
}

/// Generate the HyperSync conversion expression for a single event parameter value.
/// For struct types, this generates code to convert the raw array to a named record.
/// For non-struct types, it uses Utils.magic directly.
pub fn hypersync_field_conversion(type_ident: &TypeIdent) -> String {
    match type_ident {
        TypeIdent::TypeApplication {
            name, type_params, ..
        } if type_params.is_empty() => {
            // Struct type - convert array to record using fromArray
            format!(
                "HyperSyncClient.Decoder.toUnderlying->\
                 (Utils.magic: 'a => array<unknown>)->\
                 {name}_fromArray"
            )
        }
        TypeIdent::Array(inner) => match inner.as_ref() {
            TypeIdent::TypeApplication {
                name, type_params, ..
            } if type_params.is_empty() => {
                // Array of struct types
                format!(
                    "HyperSyncClient.Decoder.toUnderlying->\
                     (Utils.magic: 'a => array<array<unknown>>)->\
                     Belt.Array.map({name}_fromArray)"
                )
            }
            _ => {
                "HyperSyncClient.Decoder.toUnderlying->Utils.magic".to_string()
            }
        },
        _ => "HyperSyncClient.Decoder.toUnderlying->Utils.magic".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::{abi_to_rescript_type, abi_to_rescript_type_with_structs, EthereumEventParam};
    use crate::config_parsing::abi_compat;
    use crate::config_parsing::abi_compat::EventParam;
    use alloy_dyn_abi::DynSolType;

    #[test]
    fn test_record_type_array() {
        let array_string_type = DynSolType::Array(Box::new(DynSolType::String));
        let param = EthereumEventParam {
            abi_type: &array_string_type,
            name: "myArray",
        };

        let parsed_rescript_string = abi_to_rescript_type(&param);

        assert_eq!(
            parsed_rescript_string.to_string(),
            String::from("array<string>")
        )
    }

    #[test]
    fn test_record_type_fixed_array() {
        let array_fixed_arr_type = DynSolType::FixedArray(Box::new(DynSolType::String), 1);
        let param = EthereumEventParam {
            abi_type: &array_fixed_arr_type,
            name: "myArrayFixed",
        };
        let parsed_rescript_string = abi_to_rescript_type(&param);

        assert_eq!(
            parsed_rescript_string.to_string(),
            String::from("array<string>")
        )
    }

    #[test]
    fn test_record_type_tuple() {
        let tuple_type = DynSolType::Tuple(vec![DynSolType::String, DynSolType::Uint(256)]);
        let param = EthereumEventParam {
            abi_type: &tuple_type,
            name: "myArrayFixed",
        };

        let parsed_rescript_string = abi_to_rescript_type(&param);

        assert_eq!(
            parsed_rescript_string.to_string(),
            String::from("(string, bigint)")
        )
    }

    #[test]
    fn test_abi_default_rescript_int() {
        let event = abi_compat::parse_event(
            "event MyEvent(address user, uint256 amount, (bool, address) myTuple, bytes[] myArr)",
        )
        .expect("parsing event");

        let params: Vec<EthereumEventParam> = event.inputs.iter().map(|p| p.into()).collect();
        let user_address = &params[0];
        let amount_uint256 = &params[1];
        let tuple_bool_string = &params[2];
        let bytes_arr = &params[3];

        let user_address_res_type = abi_to_rescript_type(user_address);
        let amount_uint256_res_type = abi_to_rescript_type(amount_uint256);
        let tuple_bool_string_res_type = abi_to_rescript_type(tuple_bool_string);
        let bytes_arr_res_type = abi_to_rescript_type(bytes_arr);

        assert_eq!(user_address_res_type.to_string(), "Address.t".to_string());
        assert_eq!(amount_uint256_res_type.to_string(), "bigint".to_string());
        assert_eq!(
            tuple_bool_string_res_type.to_string(),
            "(bool, Address.t)".to_string()
        );
        assert_eq!(bytes_arr_res_type.to_string(), "array<string>".to_string());

        assert_eq!(
            user_address_res_type.get_default_value_rescript(),
            "TestHelpers_MockAddresses.defaultAddress".to_string()
        );
        assert_eq!(
            amount_uint256_res_type.get_default_value_rescript(),
            "0n".to_string()
        );
        assert_eq!(
            tuple_bool_string_res_type.get_default_value_rescript(),
            "(false, TestHelpers_MockAddresses.defaultAddress)".to_string()
        );
        assert_eq!(
            bytes_arr_res_type.get_default_value_rescript(),
            "[]".to_string()
        );
    }

    #[test]
    fn test_named_struct_generates_record_type() {
        let param = EventParam {
            name: "data".to_string(),
            kind: DynSolType::Tuple(vec![DynSolType::Address, DynSolType::Uint(256)]),
            indexed: false,
            components: vec![
                EventParam::new("funder".to_string(), DynSolType::Address, false),
                EventParam::new("amount".to_string(), DynSolType::Uint(256), false),
            ],
        };

        let (type_ident, aux_decls) = abi_to_rescript_type_with_structs(&param, "eventArgs");

        // Should generate a TypeApplication reference
        assert_eq!(type_ident.to_string(), "eventArgs_data");
        assert_eq!(aux_decls.len(), 1);
        assert_eq!(aux_decls[0].name, "eventArgs_data");
        assert_eq!(aux_decls[0].fields.len(), 2);
        assert_eq!(aux_decls[0].fields[0].name, "funder");
        assert_eq!(aux_decls[0].fields[1].name, "amount");
    }

    #[test]
    fn test_unnamed_tuple_stays_as_tuple() {
        let param = EventParam {
            name: "data".to_string(),
            kind: DynSolType::Tuple(vec![DynSolType::Uint(256), DynSolType::Bool]),
            indexed: false,
            // Empty names = unnamed tuple
            components: vec![
                EventParam::new("".to_string(), DynSolType::Uint(256), false),
                EventParam::new("".to_string(), DynSolType::Bool, false),
            ],
        };

        let (type_ident, aux_decls) = abi_to_rescript_type_with_structs(&param, "eventArgs");

        // Should remain a tuple
        assert_eq!(type_ident.to_string(), "(bigint, bool)");
        assert!(aux_decls.is_empty());
    }

    #[test]
    fn test_array_of_named_structs() {
        let param = EventParam {
            name: "tranches".to_string(),
            kind: DynSolType::Array(Box::new(DynSolType::Tuple(vec![
                DynSolType::Uint(128),
                DynSolType::Uint(40),
            ]))),
            indexed: false,
            components: vec![
                EventParam::new("amount".to_string(), DynSolType::Uint(128), false),
                EventParam::new("timestamp".to_string(), DynSolType::Uint(40), false),
            ],
        };

        let (type_ident, aux_decls) = abi_to_rescript_type_with_structs(&param, "eventArgs");

        // Should be array of the struct type
        assert_eq!(type_ident.to_string(), "array<eventArgs_tranches>");
        assert_eq!(aux_decls.len(), 1);
        assert_eq!(aux_decls[0].name, "eventArgs_tranches");
    }

    #[test]
    fn test_nested_named_structs() {
        let param = EventParam {
            name: "data".to_string(),
            kind: DynSolType::Tuple(vec![
                DynSolType::Address,
                DynSolType::Tuple(vec![DynSolType::Uint(256), DynSolType::Uint(256)]),
            ]),
            indexed: false,
            components: vec![
                EventParam::new("funder".to_string(), DynSolType::Address, false),
                EventParam {
                    name: "amounts".to_string(),
                    kind: DynSolType::Tuple(vec![
                        DynSolType::Uint(256),
                        DynSolType::Uint(256),
                    ]),
                    indexed: false,
                    components: vec![
                        EventParam::new("deposit".to_string(), DynSolType::Uint(256), false),
                        EventParam::new("brokerFee".to_string(), DynSolType::Uint(256), false),
                    ],
                },
            ],
        };

        let (type_ident, aux_decls) = abi_to_rescript_type_with_structs(&param, "eventArgs");

        assert_eq!(type_ident.to_string(), "eventArgs_data");
        // Inner struct first, then outer struct
        assert_eq!(aux_decls.len(), 2);
        assert_eq!(aux_decls[0].name, "eventArgs_data_amounts");
        assert_eq!(aux_decls[1].name, "eventArgs_data");
    }

    #[test]
    fn test_aux_type_decl_type_string() {
        use crate::type_schema::{RecordField, TypeIdent};

        let decl = super::AuxTypeDecl {
            name: "eventArgs_data".to_string(),
            fields: vec![
                RecordField::new("funder".to_string(), TypeIdent::Address),
                RecordField::new("amount".to_string(), TypeIdent::BigInt),
            ],
        };

        assert_eq!(
            decl.to_type_decl_string(),
            "@genType\ntype eventArgs_data = {funder: Address.t, amount: bigint}"
        );
    }

    #[test]
    fn test_aux_type_decl_schema_string() {
        use crate::type_schema::{RecordField, SchemaMode, TypeIdent};

        let decl = super::AuxTypeDecl {
            name: "eventArgs_data".to_string(),
            fields: vec![
                RecordField::new("funder".to_string(), TypeIdent::Address),
                RecordField::new("amount".to_string(), TypeIdent::BigInt),
            ],
        };

        assert_eq!(
            decl.to_schema_decl_string(&SchemaMode::ForDb),
            "let eventArgs_dataSchema = S.tuple((s): eventArgs_data => \
             {funder: s.item(0, Address.schema), amount: s.item(1, BigInt.schema)})"
        );
    }

    #[test]
    fn test_aux_type_decl_from_array_string() {
        use crate::type_schema::{RecordField, TypeIdent};

        let decl = super::AuxTypeDecl {
            name: "eventArgs_data".to_string(),
            fields: vec![
                RecordField::new("funder".to_string(), TypeIdent::Address),
                RecordField::new("amount".to_string(), TypeIdent::BigInt),
            ],
        };

        assert_eq!(
            decl.to_from_array_decl_string(),
            "let eventArgs_data_fromArray = (arr: array<unknown>): eventArgs_data => \
             {funder: arr->Js.Array2.unsafe_get(0)->Utils.magic, \
             amount: arr->Js.Array2.unsafe_get(1)->Utils.magic}"
        );
    }
}
