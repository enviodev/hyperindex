use crate::config_parsing::entity_parsing::RescriptType;
use ethers::abi::{EventParam as EthAbiEventParam, ParamType as EthAbiParamType};

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

pub fn abi_to_rescript_type(param: &EthereumEventParam) -> RescriptType {
    match &param.abi_type {
        EthAbiParamType::Uint(_size) => RescriptType::BigInt,
        EthAbiParamType::Int(_size) => RescriptType::BigInt,
        EthAbiParamType::Bool => RescriptType::Bool,
        EthAbiParamType::Address => RescriptType::Address,
        EthAbiParamType::Bytes => RescriptType::String,
        EthAbiParamType::String => RescriptType::String,
        EthAbiParamType::FixedBytes(_) => RescriptType::String,
        EthAbiParamType::Array(abi_type) => {
            let sub_param = EthereumEventParam {
                abi_type,
                name: param.name,
            };
            RescriptType::Array(Box::new(abi_to_rescript_type(&sub_param)))
        }
        EthAbiParamType::FixedArray(abi_type, _) => {
            let sub_param = EthereumEventParam {
                abi_type,
                name: param.name,
            };

            RescriptType::Array(Box::new(abi_to_rescript_type(&sub_param)))
        }
        EthAbiParamType::Tuple(abi_types) => {
            let rescript_types: Vec<RescriptType> = abi_types
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

            RescriptType::Tuple(rescript_types)
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
            String::from("(string, BigInt.t)")
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

        assert_eq!(
            user_address_res_type.to_string(),
            "Ethers.ethAddress".to_string()
        );
        assert_eq!(amount_uint256_res_type.to_string(), "BigInt.t".to_string());
        assert_eq!(
            tuple_bool_string_res_type.to_string(),
            "(bool, Ethers.ethAddress)".to_string()
        );
        assert_eq!(bytes_arr_res_type.to_string(), "array<string>".to_string());

        assert_eq!(
            user_address_res_type.get_default_value_rescript(),
            "TestHelpers_MockAddresses.defaultAddress".to_string()
        );
        assert_eq!(
            amount_uint256_res_type.get_default_value_rescript(),
            "BigInt.zero".to_string()
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
