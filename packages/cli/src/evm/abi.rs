use alloy_json_abi::{AbiItem, JsonAbi};
use anyhow::{anyhow, Result};
use serde::Deserialize;
use serde_json::value::RawValue;
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

/// The entries as the file wrote them. `RawValue` keeps each one's original
/// text, which is what lets a message point into the file.
fn raw_entries(text: &str) -> Option<Vec<&RawValue>> {
    #[derive(Deserialize)]
    struct Nested<'a> {
        #[serde(borrow)]
        abi: Vec<&'a RawValue>,
    }

    serde_json::from_str::<Vec<&RawValue>>(text)
        .ok()
        .or_else(|| {
            serde_json::from_str::<Nested>(text)
                .ok()
                .map(|nested| nested.abi)
        })
}

fn line_and_column(text: &str, offset: usize) -> (usize, usize) {
    let before = &text[..offset];
    let line = before.matches('\n').count() + 1;
    let start_of_line = before.rfind('\n').map_or(0, |newline| newline + 1);
    // Columns count characters, the way an editor does, not bytes.
    let column = before[start_of_line..].chars().count() + 1;
    (line, column)
}

/// Where each entry begins. The entries are searched for in order, so two
/// written identically resolve to their own positions instead of both to the
/// first. Positions line up with `entries`, which adds and removes nothing.
fn positions(text: &str) -> Vec<(usize, usize)> {
    let Some(entries) = raw_entries(text) else {
        return Vec::new();
    };
    let mut cursor = 0;
    let mut found = Vec::with_capacity(entries.len());
    for entry in entries {
        let offset = text[cursor..]
            .find(entry.get())
            .map_or(cursor, |index| cursor + index);
        cursor = offset + entry.get().len();
        found.push(line_and_column(text, offset));
    }
    found
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
        let reads_as_its_own_shape = if is_event { as_event } else { as_param };
        if reads_as_its_own_shape {
            continue;
        }
        let name = param.get("name").and_then(Value::as_str).unwrap_or("");
        if as_param || as_event {
            return Some(format!(
                "parameter \"{name}\" has \"indexed\", which only an event's parameter can have"
            ));
        }
        return Some(match param.get("type").and_then(Value::as_str) {
            Some(kind) => format!("parameter \"{name}\" has an invalid type \"{kind}\""),
            None => format!("parameter \"{name}\" has no \"type\""),
        });
    }
    None
}

fn describe(at: &str, item: &Map<String, Value>, err: &serde_json::Error) -> anyhow::Error {
    let named = match item.get("name").and_then(Value::as_str) {
        Some(name) => format!("\"{name}\": "),
        None => String::new(),
    };
    let kind = item.get("type").and_then(Value::as_str).unwrap_or_default();
    if !ENTRY_TYPES.contains(&kind) {
        return anyhow!(
            "{at}{named}unknown entry type \"{kind}\". Expected one of {}.",
            quoted(&ENTRY_TYPES)
        );
    }
    match bad_parameter(item, kind == "event") {
        Some(problem) => anyhow!("{at}{named}{problem}."),
        // serde quotes with backticks and names its own machinery, so the rare
        // error this does not recognise is at least quoted like the file is.
        None => anyhow!(
            "{at}{named}entry is invalid: {}.",
            err.to_string().replace('`', "\"")
        ),
    }
}

/// `AbiOrNestedAbi` is untagged, so serde reports only that the file matched no
/// variant, and reading the array as a whole names no entry. Reading one entry
/// at a time says which entry to fix, and where in the file it is.
fn explain(source: Option<&str>, text: &str, err: &serde_json::Error) -> anyhow::Error {
    let subject = source.unwrap_or("The ABI");
    let Ok(mut parsed) = serde_json::from_str::<Value>(text) else {
        return anyhow!("{subject} is not valid JSON: {err}.");
    };
    let Some(items) = entries(&mut parsed) else {
        let hint = match source {
            Some(_) => " Check the \"abi_file_path\" in your config.",
            None => "",
        };
        return anyhow!(
            "{subject} must hold a JSON array of ABI entries, or an object with an \"abi\" field \
             holding one.{hint}"
        );
    };
    let positions = positions(text);
    let at = |index: usize| match (source, positions.get(index)) {
        (Some(source), Some((line, column))) => format!("{source}:{line}:{column}: "),
        (Some(source), None) => format!("{source}: "),
        (None, _) => String::new(),
    };
    for (index, item) in items.iter().enumerate() {
        let Some(object) = item.as_object() else {
            return anyhow!("{}an ABI entry must be a JSON object.", at(index));
        };
        if let Err(entry_err) = serde_json::from_value::<AbiItem>(item.clone()) {
            return describe(&at(index), object, &entry_err);
        }
    }
    anyhow!(
        "{subject} is invalid: {}.",
        err.to_string().replace('`', "\"")
    )
}

/// Reads an ABI, filling in what its writer left out. `source` names the file
/// it came from, and is what an unreadable entry is reported against; an ABI
/// with no file behind it passes `None`.
pub fn parse(source: Option<&str>, text: &str) -> Result<AbiOrNestedAbi> {
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
        _ => Err(explain(source, text, &err)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(text: &str) -> AbiOrNestedAbi {
        parse(Some("abis/Token.json"), text).expect("a readable ABI")
    }

    fn events(abi: AbiOrNestedAbi) -> Vec<String> {
        let (AbiOrNestedAbi::Abi(abi) | AbiOrNestedAbi::NestedAbi { abi }) = abi;
        abi.events().map(|event| event.name.clone()).collect()
    }

    fn error(text: &str) -> String {
        let Err(err) = parse(Some("abis/Token.json"), text) else {
            panic!("expected an unreadable ABI to fail");
        };
        err.to_string()
    }

    fn error_without_a_file(text: &str) -> String {
        let Err(err) = parse(None, text) else {
            panic!("expected an unreadable ABI to fail");
        };
        err.to_string()
    }

    #[test]
    fn reads_an_abi_a_truffle_era_toolchain_wrote() {
        let abi = read(
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
        );

        assert_eq!(events(abi), vec!["Failure"]);
    }

    // The ABI spec makes these optional: an event that is not anonymous, an
    // entry with no parameters, a function that returns nothing, and an entry
    // with no type at all, which the spec reads as a function.
    #[test]
    fn reads_an_abi_that_leaves_out_what_the_spec_lets_it() {
        let abi = read(
            r#"[
              {"name": "admin", "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
              {"type": "function", "name": "renounce"},
              {"type": "event", "name": "Failure"},
              {"type": "event", "name": "Transfer", "inputs": [{"name": "to", "type": "address", "indexed": true}]}
            ]"#,
        );

        assert_eq!(events(abi), vec!["Failure", "Transfer"]);
    }

    // Compound V2's ABIs, generated when the proxy and the implementation were
    // concatenated, list the constructor twice.
    #[test]
    fn reads_an_abi_that_repeats_its_constructor_fallback_and_receive() {
        let abi = read(
            r#"[
              {"inputs": [], "payable": false, "stateMutability": "nonpayable", "type": "constructor"},
              {"payable": true, "stateMutability": "payable", "type": "fallback"},
              {"stateMutability": "payable", "type": "receive"},
              {"inputs": [], "payable": false, "stateMutability": "nonpayable", "type": "constructor"},
              {"payable": true, "stateMutability": "payable", "type": "fallback"},
              {"stateMutability": "payable", "type": "receive"},
              {"anonymous": false, "inputs": [], "name": "Failure", "type": "event"}
            ]"#,
        );

        assert_eq!(events(abi), vec!["Failure"]);
    }

    #[test]
    fn reads_a_nested_abi_that_repeats_its_constructor() {
        let abi = read(
            r#"{
              "contractName": "Comptroller",
              "abi": [
                {"inputs": [], "stateMutability": "nonpayable", "type": "constructor"},
                {"inputs": [], "stateMutability": "nonpayable", "type": "constructor"},
                {"anonymous": false, "inputs": [], "name": "Failure", "type": "event", "signature": "0x45b96fe4"}
              ],
              "bytecode": "0x60806040"
            }"#,
        );

        assert_eq!(events(abi), vec!["Failure"]);
    }

    #[test]
    fn points_at_the_line_the_unreadable_entry_begins_on() {
        assert_eq!(
            error(
                "[\n  {\"type\": \"event\", \"name\": \"Failure\", \"inputs\": []},\n  \
                 {\"type\": \"wormhole\", \"name\": \"Warp\"}\n]"
            ),
            "abis/Token.json:3:3: \"Warp\": unknown entry type \"wormhole\". Expected one of \
             \"constructor\", \"fallback\", \"receive\", \"function\", \"event\", \"error\"."
        );
    }

    // Entries are found in order, so entries written identically do not all
    // resolve to the position of the first.
    #[test]
    fn points_past_entries_written_identically() {
        assert_eq!(
            error(
                "[\n  {\"type\": \"event\", \"name\": \"Ping\", \"inputs\": []},\n  \
                 {\"type\": \"event\", \"name\": \"Ping\", \"inputs\": []},\n  \
                 {\"type\": \"wormhole\", \"name\": \"Warp\"}\n]"
            ),
            "abis/Token.json:4:3: \"Warp\": unknown entry type \"wormhole\". Expected one of \
             \"constructor\", \"fallback\", \"receive\", \"function\", \"event\", \"error\"."
        );
    }

    #[test]
    fn points_into_a_nested_abi() {
        assert_eq!(
            error(
                "{\n  \"contractName\": \"Comptroller\",\n  \"abi\": [\n    \
                 {\"type\": \"wormhole\", \"name\": \"Warp\"}\n  ]\n}"
            ),
            "abis/Token.json:4:5: \"Warp\": unknown entry type \"wormhole\". Expected one of \
             \"constructor\", \"fallback\", \"receive\", \"function\", \"event\", \"error\"."
        );
    }

    #[test]
    fn names_the_parameter_whose_type_is_malformed() {
        assert_eq!(
            error(
                "[\n  {\"name\": \"Transfer\", \"type\": \"event\", \"inputs\": \
                 [{\"name\": \"to\", \"type\": \"address\"}, {\"name\": \"value\", \"type\": \"uint256[\"}]}\n]"
            ),
            "abis/Token.json:2:3: \"Transfer\": parameter \"value\" has an invalid type \"uint256[\"."
        );
    }

    #[test]
    fn names_the_parameter_that_has_no_type() {
        assert_eq!(
            error(
                "[\n  {\"name\": \"transfer\", \"type\": \"function\", \"inputs\": [{\"name\": \"to\"}]}\n]"
            ),
            "abis/Token.json:2:3: \"transfer\": parameter \"to\" has no \"type\"."
        );
    }

    #[test]
    fn says_when_a_parameter_carries_indexed_and_may_not() {
        assert_eq!(
            error(
                "[\n  {\"name\": \"transfer\", \"type\": \"function\", \"inputs\": \
                 [{\"name\": \"to\", \"type\": \"address\", \"indexed\": true}]}\n]"
            ),
            "abis/Token.json:2:3: \"transfer\": parameter \"to\" has \"indexed\", which only an \
             event's parameter can have."
        );
    }

    // alloy refuses the property, not the value, so "indexed": false is
    // rejected as surely as true and must not be described as being indexed.
    #[test]
    fn says_when_a_parameter_carries_indexed_set_to_false() {
        assert_eq!(
            error(
                "[\n  {\"name\": \"transfer\", \"type\": \"function\", \"inputs\": \
                 [{\"name\": \"to\", \"type\": \"address\", \"indexed\": false}]}\n]"
            ),
            "abis/Token.json:2:3: \"transfer\": parameter \"to\" has \"indexed\", which only an \
             event's parameter can have."
        );
    }

    #[test]
    fn says_when_the_file_is_not_json() {
        assert_eq!(
            error("not json"),
            "abis/Token.json is not valid JSON: expected ident at line 1 column 2."
        );
    }

    #[test]
    fn says_when_the_file_holds_no_abi() {
        assert_eq!(
            error(r#"{"contractName": "Comptroller", "bytecode": "0x60806040"}"#),
            "abis/Token.json must hold a JSON array of ABI entries, or an object with an \"abi\" \
             field holding one. Check the \"abi_file_path\" in your config."
        );
    }

    // An ABI a block explorer served has no file to open, so it is reported
    // without a position.
    #[test]
    fn reports_an_entry_of_an_abi_that_has_no_file_behind_it() {
        assert_eq!(
            error_without_a_file(r#"[{"type": "wormhole", "name": "Warp"}]"#),
            "\"Warp\": unknown entry type \"wormhole\". Expected one of \"constructor\", \
             \"fallback\", \"receive\", \"function\", \"event\", \"error\"."
        );
    }

    // ... and nothing to fix in the config either.
    #[test]
    fn reports_an_abi_that_has_no_file_behind_it_and_holds_no_entries() {
        assert_eq!(
            error_without_a_file(r#"{"contractName": "Comptroller"}"#),
            "The ABI must hold a JSON array of ABI entries, or an object with an \"abi\" field \
             holding one."
        );
    }
}
