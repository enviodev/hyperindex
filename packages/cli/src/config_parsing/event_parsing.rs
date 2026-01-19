use alloy_dyn_abi::DynSolType;

use crate::config_parsing::abi_compat::EventParam;
use crate::type_schema::TypeIdent;

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

#[cfg(test)]
mod tests {
    use super::{abi_to_rescript_type, EthereumEventParam};
    use crate::config_parsing::abi_compat;
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
}
