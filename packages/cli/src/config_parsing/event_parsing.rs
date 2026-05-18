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

pub fn abi_to_rescript_type(param: &EvmEventParam) -> TypeIdent {
    abi_type_to_rescript(param.abi_type)
}

/// Same as [`abi_to_rescript_type`] but discards component names, using the
/// positional index (`"0"`, `"1"`, …) as the JS object key instead. Used for
/// contexts like the ReScript `eventFilter` type where component names from
/// the ABI may clash with other identifiers or where callers want a stable
/// shape regardless of ABI naming. The rendered type is still a JS object
/// (`{"0": ..., "1": ...}`) so it remains inlinable inside generics and
/// optional fields without needing a lifted alias.
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
        AbiType::Tuple(fields) => TypeIdent::Record(
            fields
                .iter()
                .enumerate()
                .map(|(i, f)| {
                    RecordField::new(i.to_string(), abi_type_to_rescript_positional(&f.kind))
                })
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
            // All tuples render as inline records so handlers can access fields
            // by key (`event.params.commonParams["funder"]`) regardless of whether
            // the ABI names them. Unnamed components fall back to their positional
            // index as the JS object key (e.g. `commonParams["0"]`). At runtime the
            // raw positional decoder output is remapped into an object via
            // `componentsToRemapper` in `EventConfigBuilder.res`.
            // `AbiTupleField` constructors normalise empty source names to `None`,
            // so `Some(_)` always carries a non-empty identifier.
            TypeIdent::Record(
                fields
                    .iter()
                    .enumerate()
                    .map(|(i, f)| {
                        let name = f.name.clone().unwrap_or_else(|| i.to_string());
                        RecordField::new(name, abi_type_to_rescript(&f.kind))
                    })
                    .collect(),
            )
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
    fn test_record_type_unnamed_tuple_uses_positional_keys() {
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

        // Fully anonymous tuples also render as inline records — every component
        // falls back to its positional index as the JS object key so handlers
        // access fields uniformly via `["0"]` / `["1"]`.
        assert_eq!(
            parsed.to_string(),
            "{\"0\": string, \"1\": bigint}".to_string()
        );
        assert_eq!(
            parsed.to_ts_type_string(),
            "{ readonly 0: string; readonly 1: bigint }"
        );
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
    fn test_record_type_mixed_named_tuple_uses_index_for_unnamed() {
        // Mixed-name tuples (some components named, others not) still render as
        // an inline record. Unnamed fields fall back to their positional index
        // as the JS object key, with no leading underscore. `AbiTupleField`
        // constructors normalise empty source names to `None`, which is what
        // the codegen relies on here.
        let tuple_type = AbiType::Tuple(vec![
            AbiTupleField {
                name: Some("funder".to_string()),
                kind: AbiType::Address,
            },
            AbiTupleField {
                name: None,
                kind: AbiType::Uint(256),
            },
            AbiTupleField {
                name: None,
                kind: AbiType::Bool,
            },
            AbiTupleField {
                name: Some("recipient".to_string()),
                kind: AbiType::Address,
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
                        RecordField::new("1".to_string(), TypeIdent::BigInt),
                        RecordField::new("2".to_string(), TypeIdent::Bool),
                        RecordField::new("recipient".to_string(), TypeIdent::Address),
                    ]
                );
            }
            _ => panic!("expected Record"),
        }
        assert_eq!(
            parsed.to_string(),
            "{\"funder\": Address.t, \"1\": bigint, \"2\": bool, \"recipient\": Address.t}"
        );
        assert_eq!(
            parsed.to_ts_type_string(),
            "{ readonly funder: Address; readonly 1: bigint; readonly 2: boolean; readonly recipient: Address }"
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
        // Bare signature strings have no component names, so tuple components
        // fall back to their positional index as the JS object key.
        assert_eq!(
            tuple_bool_string_res_type.to_string(),
            "{\"0\": bool, \"1\": Address.t}".to_string()
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
            "{\"0\": false, \"1\": Envio.TestHelpers.Addresses.defaultAddress}".to_string()
        );
        assert_eq!(
            bytes_arr_res_type.get_default_value_rescript(),
            "[]".to_string()
        );
    }
}
