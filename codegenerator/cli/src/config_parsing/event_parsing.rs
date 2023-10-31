use anyhow::{Context, Result};

use std::path::PathBuf;

use ethers::abi::{
    Contract as AbiContract, EventParam as EthAbiEventParam, ParamType as EthAbiParamType,
};

pub fn parse_abi(abi: &str) -> Result<AbiContract> {
    Ok(serde_json::from_str(abi)?)
}

pub fn get_abi_from_file_path(file_path: &PathBuf) -> Result<AbiContract> {
    let abi_file = std::fs::read_to_string(file_path).context("Failed reading abi file")?;
    parse_abi(&abi_file)
}

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

impl<'a> EthereumEventParam<'a> {
    pub fn from_ethereum_abi_param(abi_type: &'a EthAbiEventParam) -> EthereumEventParam<'a> {
        EthereumEventParam {
            name: &abi_type.name,
            abi_type: &abi_type.kind,
        }
    }
}

pub fn abi_type_to_rescript_string(param: &EthereumEventParam) -> String {
    match &param.abi_type {
        EthAbiParamType::Uint(_size) => String::from("Ethers.BigInt.t"),
        EthAbiParamType::Int(_size) => String::from("Ethers.BigInt.t"),
        EthAbiParamType::Bool => String::from("bool"),
        EthAbiParamType::Address => String::from("Ethers.ethAddress"),
        EthAbiParamType::Bytes => String::from("string"),
        EthAbiParamType::String => String::from("string"),
        EthAbiParamType::FixedBytes(_) => String::from("string"),
        EthAbiParamType::Array(abi_type) => {
            let sub_param = EthereumEventParam {
                abi_type,
                name: param.name,
            };
            format!("array<{}>", abi_type_to_rescript_string(&sub_param))
        }
        EthAbiParamType::FixedArray(abi_type, _) => {
            let sub_param = EthereumEventParam {
                abi_type,
                name: param.name,
            };

            format!("array<{}>", abi_type_to_rescript_string(&sub_param))
        }
        EthAbiParamType::Tuple(abi_types) => {
            let rescript_types: Vec<String> = abi_types
                .iter()
                .map(|abi_type| {
                    let ethereum_param = EthereumEventParam {
                        // Note the name doesn't matter since it's creating tuple without keys
                        //   it is only included so that the type is the same for recursion.
                        name: "",
                        abi_type,
                    };

                    abi_type_to_rescript_string(&ethereum_param)
                })
                .collect();

            let tuple_inner = rescript_types.join(", ");

            let tuple = format!("({})", tuple_inner);
            tuple
        }
    }
}

#[cfg(test)]
mod tests {
    //TODO: Recreate these tests where the converters are used

    use ethers::abi::ParamType;

    use super::abi_type_to_rescript_string;

    #[test]
    fn test_record_type_array() {
        let array_string_type = ParamType::Array(Box::new(ParamType::String));
        let param = super::EthereumEventParam {
            abi_type: &array_string_type,
            name: "myArray",
        };

        let parsed_rescript_string = abi_type_to_rescript_string(&param);

        assert_eq!(parsed_rescript_string, String::from("array<string>"))
    }

    #[test]
    fn test_record_type_fixed_array() {
        let array_fixed_arr_type = ParamType::FixedArray(Box::new(ParamType::String), 1);
        let param = super::EthereumEventParam {
            abi_type: &array_fixed_arr_type,
            name: "myArrayFixed",
        };
        let parsed_rescript_string = abi_type_to_rescript_string(&param);

        assert_eq!(parsed_rescript_string, String::from("array<string>"))
    }

    #[test]
    fn test_record_type_tuple() {
        let tuple_type = ParamType::Tuple(vec![ParamType::String, ParamType::Uint(256)]);
        let param = super::EthereumEventParam {
            abi_type: &tuple_type,
            name: "myArrayFixed",
        };

        let parsed_rescript_string = abi_type_to_rescript_string(&param);

        assert_eq!(
            parsed_rescript_string,
            String::from("(string, Ethers.BigInt.t)")
        )
    }
}
