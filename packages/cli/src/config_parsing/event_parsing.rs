use alloy_dyn_abi::DynSolType;

use crate::config_parsing::abi_compat::{AbiType, EventParam};
use crate::type_schema::{RecordField, TypeIdent};

pub struct EvmEventParam<'a> {
    pub name: &'a str,
    abi_type: &'a AbiType,
}

impl<'a> From<&'a EventParam> for EvmEventParam<'a> {
    fn from(abi_param: &'a EventParam) -> EvmEventParam<'a> {
        EvmEventParam {
            name: &abi_param.name,
            abi_type: &abi_param.kind,
        }
    }
}

impl EvmEventParam<'_> {
    /// Returns the depth of the nested type
    /// A value type would return 0
    /// An array or tuple type would have a nested type
    /// Tuple depth is only calculated on the first element of the tuple
    /// as this corrisponds with the check on SingleOrMultiple in the rescript code
    pub fn get_nested_type_depth(&self) -> usize {
        fn rec(param: &AbiType, accum: usize) -> usize {
            match param {
                AbiType::Tuple(fields) => match fields.first() {
                    Some(f) => rec(&f.kind, accum + 1),
                    None => accum,
                },
                AbiType::Array(p) | AbiType::FixedArray(p, _) => rec(p, accum + 1),
                _ => accum,
            }
        }
        rec(self.abi_type, 0)
    }

    pub fn get_topic_encoder(&self) -> String {
        // Topic encoding is purely structural (no named fields needed), so we reuse
        // the DynSolType-based implementation by lowering the AbiType.
        Self::topic_encoder_for_dyn(&self.abi_type.to_dyn_sol_type())
    }

    fn topic_encoder_for_dyn(abi_type: &DynSolType) -> String {
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
        match rec(abi_type, IsNestedType(false)) {
            (encoder, IsValueEncoder(false)) => {
                format!("(value) => TopicFilter.keccak256(value->{encoder})")
            }
            (encoder, IsValueEncoder(true)) => encoder,
        }
    }
}

pub fn abi_to_rescript_type(param: &EvmEventParam) -> TypeIdent {
    abi_type_to_rescript(param.abi_type)
}

/// Same as [`abi_to_rescript_type`] but always renders tuples as positional
/// tuples, discarding component names. Used for contexts like the ReScript
/// `eventFilter` type where inline records inside generic type arguments
/// (e.g. `SingleOrMultiple.t<{...}>`) are syntactically disallowed.
pub fn abi_to_rescript_type_positional(param: &EvmEventParam) -> TypeIdent {
    abi_type_to_rescript_positional(param.abi_type)
}

fn abi_type_to_rescript_positional(ty: &AbiType) -> TypeIdent {
    match ty {
        AbiType::Uint(_) => TypeIdent::BigInt,
        AbiType::Int(_) => TypeIdent::BigInt,
        AbiType::Bool => TypeIdent::Bool,
        AbiType::Address => TypeIdent::Address,
        AbiType::Bytes => TypeIdent::String,
        AbiType::String => TypeIdent::String,
        AbiType::FixedBytes(_) => TypeIdent::String,
        AbiType::Function => {
            unreachable!("Function type should be filtered out before reaching here")
        }
        AbiType::Array(inner) => TypeIdent::Array(Box::new(abi_type_to_rescript_positional(inner))),
        AbiType::FixedArray(inner, _) => {
            TypeIdent::Array(Box::new(abi_type_to_rescript_positional(inner)))
        }
        AbiType::Tuple(fields) => TypeIdent::Tuple(
            fields
                .iter()
                .map(|f| abi_type_to_rescript_positional(&f.kind))
                .collect(),
        ),
    }
}

fn abi_type_to_rescript(ty: &AbiType) -> TypeIdent {
    match ty {
        AbiType::Uint(_) => TypeIdent::BigInt,
        AbiType::Int(_) => TypeIdent::BigInt,
        AbiType::Bool => TypeIdent::Bool,
        AbiType::Address => TypeIdent::Address,
        AbiType::Bytes => TypeIdent::String,
        AbiType::String => TypeIdent::String,
        AbiType::FixedBytes(_) => TypeIdent::String,
        AbiType::Function => {
            unreachable!("Function type should be filtered out before reaching here")
        }
        AbiType::Array(inner) => TypeIdent::Array(Box::new(abi_type_to_rescript(inner))),
        AbiType::FixedArray(inner, _) => TypeIdent::Array(Box::new(abi_type_to_rescript(inner))),
        AbiType::Tuple(fields) => {
            // Solidity structs (named components) render as inline records;
            // anonymous tuples (e.g. from bare signature strings or unnamed
            // tuple types) stay as positional tuples.
            if fields
                .iter()
                .all(|f| f.name.as_ref().is_some_and(|n| !n.is_empty()))
            {
                let record_fields = fields
                    .iter()
                    .map(|f| {
                        RecordField::new(f.name.clone().unwrap(), abi_type_to_rescript(&f.kind))
                    })
                    .collect();
                TypeIdent::Record(record_fields)
            } else {
                TypeIdent::Tuple(
                    fields
                        .iter()
                        .map(|f| abi_type_to_rescript(&f.kind))
                        .collect(),
                )
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{abi_to_rescript_type, AbiType, EvmEventParam};
    use crate::config_parsing::abi_compat::{self, AbiTupleField};
    use crate::type_schema::{RecordField, TypeIdent};

    #[test]
    fn test_record_type_array() {
        let array_string_type = AbiType::Array(Box::new(AbiType::String));
        let param = EvmEventParam {
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
        let array_fixed_arr_type = AbiType::FixedArray(Box::new(AbiType::String), 1);
        let param = EvmEventParam {
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
    fn test_record_type_unnamed_tuple_stays_positional() {
        let tuple_type = AbiType::Tuple(vec![
            AbiTupleField {
                name: None,
                kind: AbiType::String,
            },
            AbiTupleField {
                name: None,
                kind: AbiType::Uint(256),
            },
        ]);
        let param = EvmEventParam {
            abi_type: &tuple_type,
            name: "myTuple",
        };

        let parsed = abi_to_rescript_type(&param);

        assert_eq!(parsed.to_string(), "(string, bigint)".to_string());
        assert_eq!(parsed.to_ts_type_string(), "[string, bigint]");
    }

    #[test]
    fn test_record_type_named_tuple_uses_field_names() {
        let tuple_type = AbiType::Tuple(vec![
            AbiTupleField {
                name: Some("funder".to_string()),
                kind: AbiType::Address,
            },
            AbiTupleField {
                name: Some("amount".to_string()),
                kind: AbiType::Uint(256),
            },
        ]);
        let param = EvmEventParam {
            abi_type: &tuple_type,
            name: "commonParams",
        };

        let parsed = abi_to_rescript_type(&param);

        match &parsed {
            TypeIdent::Record(fields) => {
                assert_eq!(
                    fields,
                    &vec![
                        RecordField::new("funder".to_string(), TypeIdent::Address),
                        RecordField::new("amount".to_string(), TypeIdent::BigInt),
                    ]
                );
            }
            _ => panic!("expected Record"),
        }
        // Inline records render as ReScript JS object types so they can be nested
        // inside other records without requiring lifted type aliases.
        assert_eq!(
            parsed.to_string(),
            "{\"funder\": Address.t, \"amount\": bigint}"
        );
        assert_eq!(
            parsed.to_ts_type_string(),
            "{ readonly funder: Address; readonly amount: bigint }"
        );
    }

    #[test]
    fn test_abi_default_rescript_int() {
        let event = abi_compat::parse_event(
            "event MyEvent(address user, uint256 amount, (bool, address) myTuple, bytes[] myArr)",
        )
        .expect("parsing event");

        let params: Vec<EvmEventParam> = event.inputs.iter().map(|p| p.into()).collect();
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
        // Bare signature strings have no component names, so the tuple stays positional.
        assert_eq!(
            tuple_bool_string_res_type.to_string(),
            "(bool, Address.t)".to_string()
        );
        assert_eq!(bytes_arr_res_type.to_string(), "array<string>".to_string());

        assert_eq!(
            user_address_res_type.get_default_value_rescript(),
            "Envio.TestHelpers.Addresses.defaultAddress".to_string()
        );
        assert_eq!(
            amount_uint256_res_type.get_default_value_rescript(),
            "0n".to_string()
        );
        assert_eq!(
            tuple_bool_string_res_type.get_default_value_rescript(),
            "(false, Envio.TestHelpers.Addresses.defaultAddress)".to_string()
        );
        assert_eq!(
            bytes_arr_res_type.get_default_value_rescript(),
            "[]".to_string()
        );
    }
}
