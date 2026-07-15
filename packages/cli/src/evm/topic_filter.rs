use alloy_dyn_abi::{DynSolType, DynSolValue};
use alloy_primitives::keccak256;
use anyhow::{bail, Context, Result};
use napi_derive::napi;
use serde_json::Value;

/// Encodes a user-facing handler filter value into the topic representation
/// used by Solidity for an indexed event parameter.
#[napi]
pub fn encode_indexed_topic(abi_type: String, value: Value) -> napi::Result<String> {
    encode_indexed_topic_inner(&abi_type, value)
        .map_err(|error| napi::Error::from_reason(format!("{error:#}")))
}

fn encode_indexed_topic_inner(abi_type: &str, value: Value) -> Result<String> {
    let ty = DynSolType::parse(abi_type)
        .with_context(|| format!("Failed to parse indexed event ABI type `{abi_type}`"))?;
    let value = coerce_json_value(&ty, value)
        .with_context(|| format!("Invalid filter value for indexed ABI type `{abi_type}`"))?;

    let topic = match ty {
        DynSolType::String => match value {
            DynSolValue::String(value) => keccak256(value.as_bytes()).to_vec(),
            _ => unreachable!("value was coerced from the matching type"),
        },
        DynSolType::Bytes => match value {
            DynSolValue::Bytes(value) => keccak256(value).to_vec(),
            _ => unreachable!("value was coerced from the matching type"),
        },
        DynSolType::Array(_) | DynSolType::FixedArray(_, _) | DynSolType::Tuple(_) => {
            let mut preimage = Vec::new();
            encode_topic_preimage(&value, &mut preimage)?;
            keccak256(preimage).to_vec()
        }
        _ => {
            let encoded = value.abi_encode();
            if encoded.len() != 32 {
                bail!(
                    "Expected indexed scalar ABI type `{abi_type}` to encode to one word, got {} bytes",
                    encoded.len()
                );
            }
            encoded
        }
    };

    Ok(format!("0x{}", faster_hex::hex_string(&topic)))
}

fn coerce_json_value(ty: &DynSolType, value: Value) -> Result<DynSolValue> {
    match (ty, value) {
        (DynSolType::Bool, Value::Bool(value)) => Ok(DynSolValue::Bool(value)),
        (DynSolType::String, Value::String(value)) => Ok(DynSolValue::String(value)),
        (DynSolType::Bytes, Value::String(value)) if value == "0x" || value.is_empty() => {
            Ok(DynSolValue::Bytes(Vec::new()))
        }
        (DynSolType::Address, Value::String(value)) => {
            // Preserve the handler API's existing `viem.pad` behavior for
            // short hex values while still using Alloy for validation and
            // word encoding. Generated types intentionally allow `0x${string}`.
            let digits = value
                .strip_prefix("0x")
                .or_else(|| value.strip_prefix("0X"))
                .unwrap_or(&value);
            let normalized =
                if digits.len() <= 40 && digits.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                    format!("{digits:0>40}")
                } else {
                    value
                };
            DynSolType::Address
                .coerce_str(&normalized)
                .with_context(|| format!("Could not parse `{normalized}` as address"))
        }
        (DynSolType::Array(element_ty), Value::Array(values)) => values
            .into_iter()
            .enumerate()
            .map(|(index, value)| {
                coerce_json_value(element_ty, value)
                    .with_context(|| format!("Invalid array element at index {index}"))
            })
            .collect::<Result<Vec<_>>>()
            .map(DynSolValue::Array),
        (DynSolType::FixedArray(element_ty, expected_len), Value::Array(values)) => {
            if values.len() != *expected_len {
                bail!(
                    "Expected fixed array of length {expected_len}, received {} values",
                    values.len()
                );
            }
            values
                .into_iter()
                .enumerate()
                .map(|(index, value)| {
                    coerce_json_value(element_ty, value)
                        .with_context(|| format!("Invalid fixed-array element at index {index}"))
                })
                .collect::<Result<Vec<_>>>()
                .map(DynSolValue::FixedArray)
        }
        (DynSolType::Tuple(component_types), Value::Array(values)) => {
            if values.len() != component_types.len() {
                bail!(
                    "Expected tuple with {} components, received {} values",
                    component_types.len(),
                    values.len()
                );
            }
            component_types
                .iter()
                .zip(values)
                .enumerate()
                .map(|(index, (component_ty, value))| {
                    coerce_json_value(component_ty, value)
                        .with_context(|| format!("Invalid tuple component at index {index}"))
                })
                .collect::<Result<Vec<_>>>()
                .map(DynSolValue::Tuple)
        }
        (scalar_ty, Value::String(value)) => scalar_ty
            .coerce_str(&value)
            .with_context(|| format!("Could not parse `{value}` as {scalar_ty}")),
        (scalar_ty @ (DynSolType::Int(_) | DynSolType::Uint(_)), Value::Number(value)) => scalar_ty
            .coerce_str(&value.to_string())
            .with_context(|| format!("Could not parse `{value}` as {scalar_ty}")),
        (expected, actual) => bail!(
            "Expected a value compatible with {expected}, received {}",
            json_kind(&actual)
        ),
    }
}

/// Solidity's indexed-event preimage encoding recursively concatenates
/// container members without offsets or length prefixes. Dynamic bytes and
/// strings are right-padded to a multiple of 32 bytes.
fn encode_topic_preimage(value: &DynSolValue, out: &mut Vec<u8>) -> Result<()> {
    match value {
        DynSolValue::String(value) => append_padded_bytes(value.as_bytes(), out),
        DynSolValue::Bytes(value) => append_padded_bytes(value, out),
        DynSolValue::Array(values)
        | DynSolValue::FixedArray(values)
        | DynSolValue::Tuple(values) => {
            for value in values {
                encode_topic_preimage(value, out)?;
            }
        }
        scalar => {
            let encoded = scalar.abi_encode();
            if encoded.len() != 32 {
                bail!(
                    "Expected an indexed scalar container member to encode to one word, got {} bytes",
                    encoded.len()
                );
            }
            out.extend_from_slice(&encoded);
        }
    }
    Ok(())
}

fn append_padded_bytes(value: &[u8], out: &mut Vec<u8>) {
    out.extend_from_slice(value);
    let padding = (32 - value.len() % 32) % 32;
    out.resize(out.len() + padding, 0);
}

fn json_kind(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "a boolean",
        Value::Number(_) => "a number",
        Value::String(_) => "a string",
        Value::Array(_) => "an array",
        Value::Object(_) => "an object",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn encodes_dynamic_array_like_solidity() {
        assert_eq!(
            encode_indexed_topic_inner("uint256[]", json!([50, 51])).unwrap(),
            "0xde4717968916aced526cf22f9a203477a82ac23edb99e677f506e50d182b3c4d"
        );
    }

    #[test]
    fn encodes_tuple_like_solidity() {
        assert_eq!(
            encode_indexed_topic_inner("(uint256,string)", json!(["50", "test"])).unwrap(),
            "0xd0b8769ea9cd15d60ef1800406aa875a74f05fc702bedb0572ea99e06d18257d"
        );
    }

    #[test]
    fn encodes_nested_containers_like_solidity() {
        assert_eq!(
            encode_indexed_topic_inner(
                "(uint256[],string[2])",
                json!([["50", "51"], ["test", "test"]]),
            )
            .unwrap(),
            "0x9d1a9024ca624fc8bfc4071fa581a206162ee435dfc42b756e1a70f1b5e4121c"
        );
    }

    #[test]
    fn keeps_empty_dynamic_values_empty_inside_containers() {
        let expected_hash = keccak256([]);
        let expected = format!("0x{}", faster_hex::hex_string(expected_hash.as_slice()));
        assert_eq!(
            encode_indexed_topic_inner("(string)", json!([""])).unwrap(),
            expected
        );
        assert_eq!(
            encode_indexed_topic_inner("(bytes)", json!(["0x"])).unwrap(),
            expected
        );
        assert_eq!(
            encode_indexed_topic_inner("bytes", json!("0x")).unwrap(),
            "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
        );
    }

    #[test]
    fn keeps_scalar_topic_encoding_unhashed() {
        assert_eq!(
            encode_indexed_topic_inner("int8", json!(-1)).unwrap(),
            "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        );
        assert_eq!(
            encode_indexed_topic_inner("bytes4", json!("0x01020304")).unwrap(),
            "0x0102030400000000000000000000000000000000000000000000000000000000"
        );
        assert_eq!(
            encode_indexed_topic_inner("address", json!("0x000")).unwrap(),
            "0x0000000000000000000000000000000000000000000000000000000000000000"
        );
    }

    #[test]
    fn rejects_invalid_fixed_array_length() {
        let error = encode_indexed_topic_inner("uint256[2]", json!([50])).unwrap_err();
        assert!(format!("{error:#}").contains("Expected fixed array of length 2"));
    }
}
