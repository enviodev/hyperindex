use ethers::abi::{EventParam as EthAbiEventParam, ParamType as EthAbiParamType};

use crate::rescript_types::RescriptTypeIdent;

pub struct EthereumEventParam<'a> {
    name: &'a str,
    abi_type: &'a EthAbiParamType,
}

impl<'a> From<&'a EthAbiEventParam> for EthereumEventParam<'a> {
    fn from(abi_type: &'a EthAbiEventParam) -> EthereumEventParam<'a> {
        EthereumEventParam {
            name: &abi_type.name,
            abi_type: &abi_type.kind,
        }
    }
}

pub fn eth_type_to_topic_filter(param: &EthereumEventParam) -> String {
    struct IsValueEncoder(bool);
    struct IsNestedType(bool);
    fn rec(param: &EthAbiParamType, is_nested_type: IsNestedType) -> (String, IsValueEncoder) {
        fn value_encoder(encoder: &str) -> (String, IsValueEncoder) {
            (encoder.to_string(), IsValueEncoder(true))
        }
        fn non_value_encoder(encoder: &str) -> (String, IsValueEncoder) {
            (encoder.to_string(), IsValueEncoder(false))
        }
        match &param {
            EthAbiParamType::Bytes | EthAbiParamType::String if !is_nested_type.0 => {
                //In the case of a string or bytes param we simply create a keccak256 hash of the value
                //unless it is a nested type inside a tuple or array
                non_value_encoder("TopicFilter.castToHexUnsafe")
            }
            EthAbiParamType::Address => value_encoder("TopicFilter.fromAddress"),
            EthAbiParamType::Uint(_size) | EthAbiParamType::Int(_size) => {
                value_encoder("TopicFilter.fromBigInt")
            }
            EthAbiParamType::Bytes | EthAbiParamType::FixedBytes(_) => {
                value_encoder("TopicFilter.fromBytes")
            }
            EthAbiParamType::Bool => value_encoder("TopicFilter.fromBool"),
            EthAbiParamType::String => value_encoder("TopicFilter.fromString"),
            EthAbiParamType::Tuple(params) => {
                //TODO: test for nested tuples
                let tuple_arg = "tuple";
                let params_applied = params
                    .iter()
                    .enumerate()
                    .map(|(i, p)| {
                        let (param_encoder, _) = rec(p, IsNestedType(true));
                        format!(
                            "{tuple_arg}->Utils.Tuple.get({i})->Belt.Option.getUnsafe->{param_encoder}"
                        )
                    })
                    .collect::<Vec<_>>()
                    .join(", ");

                non_value_encoder(
                    format!("({tuple_arg}) => TopicFilter.concat([{params_applied}])").as_str(),
                )
            }
            EthAbiParamType::Array(p) | EthAbiParamType::FixedArray(p, _) => {
                let (param_encoder, _) = rec(p, IsNestedType(true));
                non_value_encoder(
                    format!("(arr) => TopicFilter.concat(arr->Belt.Array.map({param_encoder}))")
                        .as_str(),
                )
            }
        }
    }
    match rec(param.abi_type, IsNestedType(false)) {
        (encoder, IsValueEncoder(false)) => {
            format!("(value) => TopicFilter.keccak256(value->{encoder})")
        }
        (encoder, IsValueEncoder(true)) => encoder,
    }
}

pub fn abi_to_rescript_type(param: &EthereumEventParam) -> RescriptTypeIdent {
    match &param.abi_type {
        EthAbiParamType::Uint(_size) => RescriptTypeIdent::BigInt,
        EthAbiParamType::Int(_size) => RescriptTypeIdent::BigInt,
        EthAbiParamType::Bool => RescriptTypeIdent::Bool,
        EthAbiParamType::Address => RescriptTypeIdent::Address,
        EthAbiParamType::Bytes => RescriptTypeIdent::String,
        EthAbiParamType::String => RescriptTypeIdent::String,
        EthAbiParamType::FixedBytes(_) => RescriptTypeIdent::String,
        EthAbiParamType::Array(abi_type) => {
            let sub_param = EthereumEventParam {
                abi_type,
                name: param.name,
            };
            RescriptTypeIdent::Array(Box::new(abi_to_rescript_type(&sub_param)))
        }
        EthAbiParamType::FixedArray(abi_type, _) => {
            let sub_param = EthereumEventParam {
                abi_type,
                name: param.name,
            };

            RescriptTypeIdent::Array(Box::new(abi_to_rescript_type(&sub_param)))
        }
        EthAbiParamType::Tuple(abi_types) => {
            let rescript_types: Vec<RescriptTypeIdent> = abi_types
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

            RescriptTypeIdent::Tuple(rescript_types)
        }
    }
}

#[cfg(test)]
mod tests {
    //TODO: Recreate these tests where the converters are used

    use ethers::abi::{HumanReadableParser, ParamType};

    use super::{abi_to_rescript_type, EthereumEventParam};

    #[test]
    fn test_record_type_array() {
        let array_string_type = ParamType::Array(Box::new(ParamType::String));
        let param = super::EthereumEventParam {
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
        let array_fixed_arr_type = ParamType::FixedArray(Box::new(ParamType::String), 1);
        let param = super::EthereumEventParam {
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
        let tuple_type = ParamType::Tuple(vec![ParamType::String, ParamType::Uint(256)]);
        let param = super::EthereumEventParam {
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
        let event = HumanReadableParser::parse_event(
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
