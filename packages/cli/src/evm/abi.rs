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

const FIX_THE_ENTRY: &str = "Fix that entry in the ABI file, or re-export the ABI from the \
                             contract build - for example \"forge inspect <Contract> abi\", or \
                             the \"abi\" field of a Hardhat artifact under \"artifacts/\".";
const FIX_THE_FILE: &str = "Point the config at a contract ABI file, or re-export one from the \
                            contract build - for example \"forge inspect <Contract> abi\", or the \
                            \"abi\" field of a Hardhat artifact under \"artifacts/\".";

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

/// serde quotes with backticks and names its own machinery; an ABI file is
/// written by hand as often as it is generated, so its reader says what is
/// wrong in the file's own terms.
fn readable(err: &serde_json::Error) -> String {
    err.to_string().replace('`', "\"")
}

fn describe(index: usize, item: &Map<String, Value>, err: &serde_json::Error) -> anyhow::Error {
    let kind = item
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let named = match item.get("name").and_then(Value::as_str) {
        Some(name) => format!("entry {index} \"{name}\" ({kind})"),
        None => format!("entry {index} ({kind})"),
    };
    anyhow!(
        "{named} is not a valid ABI entry: {}. {FIX_THE_ENTRY}",
        readable(err)
    )
}

/// `AbiOrNestedAbi` is untagged, so serde reports only that the file matched no
/// variant, and reading the array as a whole names no entry. Reading one entry
/// at a time says which entry the file has to fix.
fn explain(text: &str, err: &serde_json::Error) -> anyhow::Error {
    let Ok(mut parsed) = serde_json::from_str::<Value>(text) else {
        return anyhow!(
            "The file is not valid JSON: {}. {FIX_THE_FILE}",
            readable(err)
        );
    };
    let Some(items) = entries(&mut parsed) else {
        return anyhow!(
            "An ABI file holds a JSON array of ABI entries, or an object with an \"abi\" field \
             holding that array. {FIX_THE_FILE}"
        );
    };
    for (index, item) in items.iter().enumerate() {
        let Some(object) = item.as_object() else {
            return anyhow!("entry {index} is not a JSON object. {FIX_THE_ENTRY}");
        };
        if let Err(entry_err) = serde_json::from_value::<AbiItem>(item.clone()) {
            return describe(index, object, &entry_err);
        }
    }
    anyhow!("{}. {FIX_THE_FILE}", readable(err))
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
                r#"[{"anonymous": false, "inputs": [], "name": "Failure", "type": "event"}, {"type": "wormhole", "name": "Warp"}]"#
            ),
            "entry 1 \"Warp\" (wormhole) is not a valid ABI entry: unknown variant \"wormhole\", \
             expected one of \"constructor\", \"fallback\", \"receive\", \"function\", \"event\", \
             \"error\". Fix that entry in the ABI file, or re-export the ABI from the contract \
             build - for example \"forge inspect <Contract> abi\", or the \"abi\" field of a \
             Hardhat artifact under \"artifacts/\"."
        );
    }

    #[test]
    fn names_the_entry_whose_parameter_is_malformed() {
        assert_eq!(
            error(
                r#"[{"name": "Transfer", "type": "event", "inputs": [{"name": "a", "type": "uint256["}]}]"#
            ),
            "entry 0 \"Transfer\" (event) is not a valid ABI entry: invalid value: string \
             \"uint256[\", expected a valid Solidity type specifier. Fix that entry in the ABI \
             file, or re-export the ABI from the contract build - for example \"forge inspect \
             <Contract> abi\", or the \"abi\" field of a Hardhat artifact under \"artifacts/\"."
        );
    }

    #[test]
    fn says_when_the_file_is_not_json() {
        assert_eq!(
            error("not json"),
            "The file is not valid JSON: expected ident at line 1 column 2. Point the config at a \
             contract ABI file, or re-export one from the contract build - for example \"forge \
             inspect <Contract> abi\", or the \"abi\" field of a Hardhat artifact under \
             \"artifacts/\"."
        );
    }

    #[test]
    fn says_when_the_file_holds_no_abi() {
        assert_eq!(
            error(r#"{"contractName": "Comptroller", "bytecode": "0x60806040"}"#),
            "An ABI file holds a JSON array of ABI entries, or an object with an \"abi\" field \
             holding that array. Point the config at a contract ABI file, or re-export one from \
             the contract build - for example \"forge inspect <Contract> abi\", or the \"abi\" \
             field of a Hardhat artifact under \"artifacts/\"."
        );
    }
}
