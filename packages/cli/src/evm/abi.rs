use alloy_json_abi::{AbiItem, JsonAbi};
use anyhow::{anyhow, Result};
use serde::Deserialize;
use serde_json::{Map, Value};

#[derive(Deserialize)]
#[serde(untagged)]
pub enum AbiOrNestedAbi {
    Abi(JsonAbi),
    // This is a case for Hardhat or Foundry generated ABI files
    NestedAbi { abi: JsonAbi },
}

fn items_mut(abi: &mut Value) -> Option<&mut Vec<Value>> {
    match abi {
        Value::Array(items) => Some(items),
        Value::Object(object) => object.get_mut("abi")?.as_array_mut(),
        _ => None,
    }
}

/// The ABI spec lets an entry leave out what is empty or implied, and both
/// hand-written ABIs and older toolchains do. The parser requires all of it.
fn fill_in_defaults(item: &mut Value) {
    let Some(object) = item.as_object_mut() else {
        return;
    };
    let kind = object
        .entry("type")
        .or_insert_with(|| Value::from("function"))
        .as_str()
        .unwrap_or_default()
        .to_owned();
    let mut default = |key: &str, value: Value| {
        object.entry(key.to_owned()).or_insert(value);
    };
    match kind.as_str() {
        "function" => {
            default("inputs", Value::Array(Vec::new()));
            default("outputs", Value::Array(Vec::new()));
        }
        "event" => {
            default("inputs", Value::Array(Vec::new()));
            default("anonymous", Value::Bool(false));
        }
        "constructor" | "error" => default("inputs", Value::Array(Vec::new())),
        _ => {}
    }
}

fn entries(parsed: &mut Value) -> Option<&mut Vec<Value>> {
    let items = items_mut(parsed)?;
    items.iter_mut().for_each(fill_in_defaults);
    Some(items)
}

/// A contract has one constructor, one fallback and one receive. An ABI
/// concatenated from a proxy and its implementation lists them twice, and the
/// parser has nowhere to put the second.
fn repair(text: &str) -> Option<String> {
    let mut parsed: Value = serde_json::from_str(text).ok()?;
    let mut seen = [false; 3];
    entries(&mut parsed)?.retain(|item| {
        let singleton = match item.get("type").and_then(Value::as_str) {
            Some("constructor") => 0,
            Some("fallback") => 1,
            Some("receive") => 2,
            _ => return true,
        };
        !std::mem::replace(&mut seen[singleton], true)
    });
    serde_json::to_string(&parsed).ok()
}

const ENTRY_TYPES: [&str; 6] = [
    "constructor",
    "fallback",
    "receive",
    "function",
    "event",
    "error",
];

fn quoted(types: &[&str]) -> String {
    types
        .iter()
        .map(|kind| format!("\"{kind}\""))
        .collect::<Vec<_>>()
        .join(", ")
}

/// Where in the file to look: the entry's position in the ABI array, which is
/// the one locator every entry has, and its name when it has one.
fn locate(index: usize, item: &Map<String, Value>) -> String {
    let named = match item.get("name").and_then(Value::as_str) {
        Some(name) => format!(" \"{name}\""),
        None => match item.get("type").and_then(Value::as_str) {
            Some(kind) => format!(" ({kind})"),
            None => String::new(),
        },
    };
    format!("abi[{index}]{named}")
}

/// The parameter alloy could not read. Checking one at a time is what lets the
/// message name it, rather than repeating serde's account of the whole entry.
/// A parameter reads as one of two shapes, and only an event's may be indexed,
/// so the shape that did not apply tells the two failures apart: a type the
/// file got wrong, and an "indexed" the entry is not allowed to carry.
fn bad_parameter(item: &Map<String, Value>, is_event: bool) -> Option<String> {
    let params = ["inputs", "outputs"]
        .iter()
        .filter_map(|key| item.get(*key))
        .filter_map(Value::as_array)
        .flatten();
    for param in params {
        let as_param = serde_json::from_value::<alloy_json_abi::Param>(param.clone()).is_ok();
        let as_event = serde_json::from_value::<alloy_json_abi::EventParam>(param.clone()).is_ok();
        if if is_event { as_event } else { as_param } {
            continue;
        }
        let name = param.get("name").and_then(Value::as_str).unwrap_or("");
        if as_param || as_event {
            return Some(format!(
                "parameter \"{name}\" is indexed, which only an event's parameter can be"
            ));
        }
        return Some(match param.get("type").and_then(Value::as_str) {
            Some(kind) => format!("parameter \"{name}\" has an invalid type \"{kind}\""),
            None => format!("parameter \"{name}\" has no \"type\""),
        });
    }
    None
}

fn describe(index: usize, item: &Map<String, Value>, err: &serde_json::Error) -> anyhow::Error {
    let at = locate(index, item);
    let kind = item.get("type").and_then(Value::as_str).unwrap_or_default();
    if !ENTRY_TYPES.contains(&kind) {
        return anyhow!(
            "{at} has an unknown type \"{kind}\". Expected one of {}.",
            quoted(&ENTRY_TYPES)
        );
    }
    match bad_parameter(item, kind == "event") {
        Some(problem) => anyhow!("{at}: {problem}."),
        // serde quotes with backticks and names its own machinery, so the rare
        // error this does not recognise is at least quoted like the file is.
        None => anyhow!("{at} is invalid: {}.", err.to_string().replace('`', "\"")),
    }
}

/// `AbiOrNestedAbi` is untagged, so serde reports only that the file matched no
/// variant, and reading the array as a whole names no entry. Reading one entry
/// at a time says which entry the file has to fix.
fn explain(text: &str, err: &serde_json::Error) -> anyhow::Error {
    let Ok(mut parsed) = serde_json::from_str::<Value>(text) else {
        return anyhow!("The file is not valid JSON: {err}.");
    };
    let Some(items) = entries(&mut parsed) else {
        return anyhow!(
            "The file must hold a JSON array of ABI entries, or an object with an \"abi\" field \
             holding one. Check the \"abi_file_path\" in your config."
        );
    };
    for (index, item) in items.iter().enumerate() {
        let Some(object) = item.as_object() else {
            return anyhow!("abi[{index}] is not a JSON object.");
        };
        if let Err(entry_err) = serde_json::from_value::<AbiItem>(item.clone()) {
            return describe(index, object, &entry_err);
        }
    }
    anyhow!("{}.", err.to_string().replace('`', "\""))
}

/// Reads an ABI file, filling in what its writer left out.
pub fn parse(text: &str) -> Result<AbiOrNestedAbi> {
    let err = match serde_json::from_str::<AbiOrNestedAbi>(text) {
        Ok(abi) => return Ok(abi),
        Err(err) => err,
    };
    let repaired = repair(text);
    match repaired
        .as_deref()
        .map(serde_json::from_str::<AbiOrNestedAbi>)
    {
        Some(Ok(abi)) => Ok(abi),
        _ => Err(explain(text, &err)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn events(abi: AbiOrNestedAbi) -> Vec<String> {
        let (AbiOrNestedAbi::Abi(abi) | AbiOrNestedAbi::NestedAbi { abi }) = abi;
        abi.events().map(|event| event.name.clone()).collect()
    }

    fn error(text: &str) -> String {
        let Err(err) = parse(text) else {
            panic!("expected an unreadable ABI to fail");
        };
        err.to_string()
    }

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

        assert_eq!(events(abi), vec!["Failure"]);
    }

    // The ABI spec makes these optional: an event that is not anonymous, an
    // entry with no parameters, a function that returns nothing, and an entry
    // with no type at all, which the spec reads as a function.
    #[test]
    fn reads_an_abi_that_leaves_out_what_the_spec_lets_it() {
        let abi = parse(
            r#"[
              {"name": "admin", "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
              {"type": "function", "name": "renounce"},
              {"type": "event", "name": "Failure"},
              {"type": "event", "name": "Transfer", "inputs": [{"name": "to", "type": "address", "indexed": true}]}
            ]"#,
        )
        .unwrap();

        assert_eq!(events(abi), vec!["Failure", "Transfer"]);
    }

    // Compound V2's ABIs, generated when the proxy and the implementation were
    // concatenated, list the constructor twice.
    #[test]
    fn reads_an_abi_that_repeats_its_constructor_fallback_and_receive() {
        let abi = parse(
            r#"[
              {"inputs": [], "payable": false, "stateMutability": "nonpayable", "type": "constructor"},
              {"payable": true, "stateMutability": "payable", "type": "fallback"},
              {"stateMutability": "payable", "type": "receive"},
              {"inputs": [], "payable": false, "stateMutability": "nonpayable", "type": "constructor"},
              {"payable": true, "stateMutability": "payable", "type": "fallback"},
              {"stateMutability": "payable", "type": "receive"},
              {"anonymous": false, "inputs": [], "name": "Failure", "type": "event"}
            ]"#,
        )
        .unwrap();

        assert_eq!(events(abi), vec!["Failure"]);
    }

    #[test]
    fn reads_a_nested_abi_that_repeats_its_constructor() {
        let abi = parse(
            r#"{
              "contractName": "Comptroller",
              "abi": [
                {"inputs": [], "stateMutability": "nonpayable", "type": "constructor"},
                {"inputs": [], "stateMutability": "nonpayable", "type": "constructor"},
                {"anonymous": false, "inputs": [], "name": "Failure", "type": "event", "signature": "0x45b96fe4"}
              ],
              "bytecode": "0x60806040"
            }"#,
        )
        .unwrap();

        assert_eq!(events(abi), vec!["Failure"]);
    }

    #[test]
    fn names_the_entry_whose_type_is_not_an_abi_entry_type() {
        assert_eq!(
            error(
                r#"[{"name": "Failure", "type": "event"}, {"type": "wormhole", "name": "Warp"}]"#
            ),
            "abi[1] \"Warp\" has an unknown type \"wormhole\". Expected one of \"constructor\", \
             \"fallback\", \"receive\", \"function\", \"event\", \"error\"."
        );
    }

    #[test]
    fn names_the_parameter_whose_type_is_malformed() {
        assert_eq!(
            error(
                r#"[{"name": "Transfer", "type": "event", "inputs": [{"name": "to", "type": "address"}, {"name": "value", "type": "uint256["}]}]"#
            ),
            "abi[0] \"Transfer\": parameter \"value\" has an invalid type \"uint256[\"."
        );
    }

    // Only an event's parameter can be indexed, so alloy refuses a function's
    // that is; the type it names is not the problem.
    #[test]
    fn says_when_a_parameter_is_indexed_and_may_not_be() {
        assert_eq!(
            error(
                r#"[{"name": "transfer", "type": "function", "inputs": [{"name": "to", "type": "address", "indexed": true}]}]"#
            ),
            "abi[0] \"transfer\": parameter \"to\" is indexed, which only an event's parameter can be."
        );
    }

    #[test]
    fn names_the_parameter_that_has_no_type() {
        assert_eq!(
            error(r#"[{"name": "transfer", "type": "function", "inputs": [{"name": "to"}]}]"#),
            "abi[0] \"transfer\": parameter \"to\" has no \"type\"."
        );
    }

    #[test]
    fn says_when_the_file_is_not_json() {
        assert_eq!(
            error("not json"),
            "The file is not valid JSON: expected ident at line 1 column 2."
        );
    }

    #[test]
    fn says_when_the_file_holds_no_abi() {
        assert_eq!(
            error(r#"{"contractName": "Comptroller", "bytecode": "0x60806040"}"#),
            "The file must hold a JSON array of ABI entries, or an object with an \"abi\" field \
             holding one. Check the \"abi_file_path\" in your config."
        );
    }
}
