//! The ABI codec of the subgraph runtime: what graph-ts decodes and the
//! contract calls it encodes. graph-node does both with alloy, so the runtime
//! does too, and a value decodes here exactly as a mapping sees it there.

use alloy_dyn_abi::DynSolType;
use alloy_primitives::keccak256;
use anyhow::{Context, Result};
use serde_json::Value;

use crate::evm::topic_filter::coerce_json_value;
use crate::evm_hypersync_source::types::write_sol_value;
use crate::js_value::JsTape;

/// `ty` decoded from `data`: as one value, as `ethereum.decode` reads it, or
/// with `params` as a sequence of parameters (a tuple's fields), as calldata,
/// return data and `ethereum.decodeParams` hold them. A tuple is an array of
/// its fields, an address lowercase hex.
fn decode(ty: &str, data: &[u8], params: bool) -> Result<JsTape> {
    let ty =
        DynSolType::parse(ty).with_context(|| format!("Failed to parse the ABI type `{ty}`"))?;
    let value = if params {
        ty.abi_decode_params(data)
    } else {
        ty.abi_decode(data)
    }
    .with_context(|| format!("The data doesn't decode as `{ty}`"))?;
    let mut tape = JsTape::new();
    write_sol_value(&mut tape, &value, None, false);
    Ok(tape)
}

/// The type as a function signature spells it. alloy spells a one-element
/// tuple `(address,)`; a signature spells it `(address)`.
fn canonical(ty: &DynSolType) -> String {
    match ty {
        DynSolType::Tuple(types) => format!(
            "({})",
            types.iter().map(canonical).collect::<Vec<_>>().join(",")
        ),
        DynSolType::Array(inner) => format!("{}[]", canonical(inner)),
        DynSolType::FixedArray(inner, len) => format!("{}[{len}]", canonical(inner)),
        other => other.sol_type_name().into_owned(),
    }
}

/// The calldata of `name` over the parameter tuple `inputs`: its selector, the
/// hash of its canonical signature, then `args` encoded as parameters. An
/// integer travels as its decimal string.
fn encode_call(name: &str, inputs: &str, args: Value) -> Result<String> {
    let ty = DynSolType::parse(inputs)
        .with_context(|| format!("Failed to parse the parameters `{inputs}` of {name}"))?;
    let value = coerce_json_value(&ty, args)
        .with_context(|| format!("Invalid arguments for {name}{inputs}"))?;
    if !matches!(ty, DynSolType::Tuple(_)) {
        anyhow::bail!("The parameters of {name} aren't a tuple: `{inputs}`");
    }
    let selector = keccak256(format!("{name}{}", canonical(&ty)));
    let mut calldata = selector[..4].to_vec();
    calldata.extend(value.abi_encode_params());
    Ok(format!("0x{}", faster_hex::hex_string(&calldata)))
}

// Reached only through the addon's C ABI, which the test target does not build.
#[allow(dead_code)]
#[napi_derive::napi]
pub fn subgraph_abi_decode(
    ty: String,
    data: napi::bindgen_prelude::Uint8ArraySlice,
    params: bool,
) -> napi::Result<JsTape> {
    decode(&ty, &data, params).map_err(|error| napi::Error::from_reason(format!("{error:#}")))
}

#[allow(dead_code)]
#[napi_derive::napi]
pub fn subgraph_abi_encode_call(name: String, inputs: String, args: Value) -> napi::Result<String> {
    encode_call(&name, &inputs, args)
        .map_err(|error| napi::Error::from_reason(format!("{error:#}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::js_value::test_value::JsValue;
    use alloy_dyn_abi::DynSolValue;
    use alloy_primitives::{Address, U256};
    use serde_json::json;

    fn hex(bytes: &[u8]) -> String {
        format!("0x{}", faster_hex::hex_string(bytes))
    }

    // `balanceOf(address)`'s selector is 0x70a08231, and `uint` is spelled
    // `uint256` in the signature it hashes.
    #[test]
    fn encodes_a_call_as_its_selector_and_parameters() {
        let owner = format!("0x{}", "ab".repeat(20));
        assert_eq!(
            (
                encode_call("balanceOf", "(address)", json!([owner])).unwrap(),
                encode_call("transfer", "(address,uint)", json!([owner, "5"])).unwrap()[..10]
                    .to_string(),
                canonical(&DynSolType::parse("((address)[],uint8[2])").unwrap()),
            ),
            (
                format!("0x70a08231{}{}", "00".repeat(12), "ab".repeat(20)),
                "0xa9059cbb".to_string(),
                "((address)[],uint8[2])".to_string(),
            )
        );
    }

    // Uniswap v2's `getReserves()` returns `(uint112,uint112,uint32)`; return
    // data is the parameters themselves. A tuple is an array of its fields.
    #[test]
    fn decodes_parameters_and_single_values() {
        let reserves = DynSolValue::Tuple(vec![
            DynSolValue::Uint(U256::from(7u64), 112),
            DynSolValue::Uint(U256::from(8u64), 112),
            DynSolValue::Uint(U256::from(9u64), 32),
        ])
        .abi_encode_params();
        let pair = DynSolValue::Tuple(vec![
            DynSolValue::Address(Address::from([0xAB; 20])),
            DynSolValue::String("x".to_string()),
        ])
        .abi_encode();
        assert_eq!(
            (
                JsValue::of(&decode("(uint112,uint112,uint32)", &reserves, true).unwrap()),
                JsValue::of(&decode("(address,string)", &pair, false).unwrap()),
            ),
            (
                JsValue::Arr(vec![
                    JsValue::uint(7u64),
                    JsValue::uint(8u64),
                    JsValue::uint(9u64)
                ]),
                JsValue::Arr(vec![JsValue::str(&hex(&[0xab; 20])), JsValue::str("x")]),
            )
        );
    }

    // A function that returns something answers no bytes when the account
    // has no code: there is nothing to decode, which the runtime counts as a
    // revert.
    #[test]
    fn refuses_data_too_short_for_the_type() {
        assert!(decode("(uint256)", &[], true).is_err());
    }
}
