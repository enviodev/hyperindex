use alloy_json_abi::JsonAbi;
use anyhow::{anyhow, Result};
use serde::Deserialize;
use serde_json::{Map, Value};
use std::collections::HashSet;

#[derive(Deserialize)]
#[serde(untagged)]
pub enum AbiOrNestedAbi {
    Abi(JsonAbi),
    // This is a case for Hardhat or Foundry generated ABI files
    NestedAbi { abi: JsonAbi },
}

/// What an ABI entry may carry. The parser rejects anything else, and older
/// toolchains wrote more: truffle stamped every entry with its `signature`, and
/// files that have been in a repo since 2020 still carry it.
const ITEM_KEYS: &[&str] = &[
    "type",
    "name",
    "inputs",
    "outputs",
    "stateMutability",
    "anonymous",
    "constant",
    "payable",
];
const PARAM_KEYS: &[&str] = &["name", "type", "components", "internalType", "indexed"];

fn keep(object: &mut Map<String, Value>, allowed: &[&str]) {
    object.retain(|key, _| allowed.contains(&key.as_str()));
}

fn strip_params(value: &mut Value) {
    let Some(params) = value.as_array_mut() else {
        return;
    };
    for param in params {
        let Some(object) = param.as_object_mut() else {
            continue;
        };
        keep(object, PARAM_KEYS);
        if let Some(components) = object.get_mut("components") {
            strip_params(components);
        }
    }
}

/// Drops the entries' unrecognised keys, leaving the ABI itself untouched.
fn strip_unknown_keys(text: &str) -> Option<String> {
    let mut parsed: Value = serde_json::from_str(text).ok()?;
    let items = match &mut parsed {
        Value::Array(items) => items,
        Value::Object(object) => object.get_mut("abi")?.as_array_mut()?,
        _ => return None,
    };
    // A contract has one constructor, one fallback and one receive; an ABI
    // concatenated from a proxy and its implementation lists them twice, and the
    // parser has nowhere to put the second.
    let mut seen = HashSet::new();
    let mut kept = Vec::with_capacity(items.len());
    for mut item in std::mem::take(items) {
        let object = item.as_object_mut()?;
        keep(object, ITEM_KEYS);
        for key in ["inputs", "outputs"] {
            if let Some(params) = object.get_mut(key) {
                strip_params(params);
            }
        }
        let kind = object.get("type").and_then(Value::as_str).unwrap_or("");
        if matches!(kind, "constructor" | "fallback" | "receive") && !seen.insert(kind.to_string())
        {
            continue;
        }
        kept.push(item);
    }
    *items = kept;
    serde_json::to_string(&parsed).ok()
}

/// Reads an ABI file, tolerating the extra keys old toolchains wrote.
pub fn parse(text: &str) -> Result<AbiOrNestedAbi> {
    match serde_json::from_str::<AbiOrNestedAbi>(text) {
        Ok(abi) => Ok(abi),
        Err(err) => strip_unknown_keys(text)
            .and_then(|text| serde_json::from_str::<AbiOrNestedAbi>(&text).ok())
            .ok_or_else(|| anyhow!("{err}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_an_abi_a_truffle_era_toolchain_wrote() {
        let abi = parse(
            r#"[
              {
                "constant": true,
                "inputs": [],
                "name": "admin",
                "outputs": [{"name": "", "type": "address"}],
                "payable": false,
                "stateMutability": "view",
                "type": "function",
                "signature": "0xf851a440"
              },
              {
                "anonymous": false,
                "inputs": [{"indexed": false, "name": "action", "type": "string"}],
                "name": "Failure",
                "type": "event",
                "signature": "0x45b96fe4"
              }
            ]"#,
        )
        .unwrap();

        let AbiOrNestedAbi::Abi(abi) = abi else {
            panic!("expected a flat ABI");
        };
        assert_eq!(
            (
                abi.functions().map(|f| f.name.as_str()).collect::<Vec<_>>(),
                abi.events().map(|e| e.name.as_str()).collect::<Vec<_>>(),
            ),
            (vec!["admin"], vec!["Failure"])
        );
    }

    // Compound V2's ABIs, generated when the proxy and the implementation were
    // concatenated, list the constructor twice.
    #[test]
    fn reads_an_abi_that_names_its_constructor_twice() {
        let abi = parse(
            r#"[
              {"inputs": [], "payable": false, "stateMutability": "nonpayable", "type": "constructor", "signature": "constructor"},
              {"inputs": [], "payable": false, "stateMutability": "nonpayable", "type": "constructor", "signature": "constructor"},
              {"anonymous": false, "inputs": [], "name": "Failure", "type": "event"}
            ]"#,
        )
        .unwrap();

        let AbiOrNestedAbi::Abi(abi) = abi else {
            panic!("expected a flat ABI");
        };
        assert_eq!(
            abi.events().map(|e| e.name.as_str()).collect::<Vec<_>>(),
            vec!["Failure"]
        );
    }

    #[test]
    fn reads_a_nested_abi_with_extra_keys() {
        let abi = parse(
            r#"{
              "contractName": "Comptroller",
              "abi": [
                {"anonymous": false, "inputs": [], "name": "Failure", "type": "event", "signature": "0x45b96fe4"}
              ],
              "bytecode": "0x60806040"
            }"#,
        )
        .unwrap();

        let AbiOrNestedAbi::NestedAbi { abi } = abi else {
            panic!("expected a nested ABI");
        };
        assert_eq!(
            abi.events().map(|e| e.name.as_str()).collect::<Vec<_>>(),
            vec!["Failure"]
        );
    }

    #[test]
    fn reports_the_original_error_when_stripping_does_not_help() {
        let Err(err) = parse(r#"[{"type": "wormhole"}]"#) else {
            panic!("expected an unreadable ABI to fail");
        };
        assert!(
            !err.to_string().is_empty(),
            "expected the parser's own error"
        );
    }
}
