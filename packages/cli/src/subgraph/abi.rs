//! Resolving a manifest's event reference against the contract's ABI.
//!
//! A manifest names an event by a signature with no parameter names —
//! `Transfer(indexed address,indexed address,uint256)`. Envio takes the bare
//! event name and reads the parameters out of the ABI itself, which is all a
//! unique name needs. An overloaded name isn't unique, so that one has to be
//! spelled out in the human-readable form envio parses.

use std::collections::BTreeMap;

use serde_json::Value;

use super::errors::Report;

/// The parameter types a manifest signature declares, in order, each paired
/// with whether it is indexed. Indexing is part of what identifies an overload:
/// Safe declares `ExecutionSuccess` both ways, and the two differ only there.
fn manifest_arg_types(signature: &str) -> Vec<(String, bool)> {
    let Some(open) = signature.find('(') else {
        return vec![];
    };
    let Some(close) = signature.rfind(')') else {
        return vec![];
    };
    let inner = &signature[open + 1..close];

    let mut args = Vec::new();
    let mut depth = 0;
    let mut current = String::new();
    for char in inner.chars() {
        match char {
            '(' | '[' => {
                depth += 1;
                current.push(char);
            }
            ')' | ']' => {
                depth -= 1;
                current.push(char);
            }
            ',' if depth == 0 => {
                args.push(current.trim().to_string());
                current = String::new();
            }
            _ => current.push(char),
        }
    }
    if !current.trim().is_empty() {
        args.push(current.trim().to_string());
    }

    args.into_iter()
        .map(|arg| {
            let indexed = arg
                .split_whitespace()
                .any(|word| word == "indexed");
            let ty = arg
                .trim_start_matches("indexed")
                .trim_end_matches("indexed")
                .trim()
                .to_string();
            (ty, indexed)
        })
        .filter(|(ty, _)| !ty.is_empty())
        .collect()
}

/// A tuple's canonical Solidity type is its components, so an ABI input has to
/// be flattened before it can be compared or printed.
fn solidity_type(input: &Value) -> String {
    let raw = input.get("type").and_then(Value::as_str).unwrap_or_default();
    if !raw.starts_with("tuple") {
        return raw.to_string();
    }
    let components = input
        .get("components")
        .and_then(Value::as_array)
        .map(|components| {
            components
                .iter()
                .map(solidity_type)
                .collect::<Vec<_>>()
                .join(",")
        })
        .unwrap_or_default();
    // `tuple[]` keeps its suffix: "(uint256,address)[]".
    format!("({components}){}", &raw["tuple".len()..])
}

fn human_readable(name: &str, inputs: &[Value]) -> String {
    let params: Vec<String> = inputs
        .iter()
        .enumerate()
        .map(|(index, input)| {
            let ty = solidity_type(input);
            let indexed = input
                .get("indexed")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let param_name = input
                .get("name")
                .and_then(Value::as_str)
                .filter(|name| !name.is_empty())
                .map(|name| name.to_string())
                .unwrap_or_else(|| format!("arg{index}"));
            if indexed {
                format!("{ty} indexed {param_name}")
            } else {
                format!("{ty} {param_name}")
            }
        })
        .collect();
    format!("{name}({})", params.join(", "))
}

fn event_name(manifest_signature: &str) -> String {
    manifest_signature
        .split('(')
        .next()
        .unwrap_or_default()
        .trim()
        .to_string()
}

/// The ABI entries declaring an event of this name, in ABI order.
fn candidates(name: &str, abi_json: Option<&str>) -> Vec<Value> {
    let Some(abi_json) = abi_json else {
        return vec![];
    };
    let Ok(abi) = serde_json::from_str::<Value>(abi_json) else {
        return vec![];
    };
    let Some(entries) = abi.as_array() else {
        return vec![];
    };
    entries
        .iter()
        .filter(|entry| {
            entry.get("type").and_then(Value::as_str) == Some("event")
                && entry.get("name").and_then(Value::as_str) == Some(name)
        })
        .cloned()
        .collect()
}

fn inputs_of(entry: &Value) -> Vec<Value> {
    entry
        .get("inputs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

/// The ABI entry a manifest signature names, matching on argument types when
/// the name is overloaded.
fn matching_entry(manifest_signature: &str, abi_json: Option<&str>) -> Option<Value> {
    let found = candidates(&event_name(manifest_signature), abi_json);
    if found.len() <= 1 {
        return found.into_iter().next();
    }
    let wanted = manifest_arg_types(manifest_signature);
    found.into_iter().find(|candidate| {
        let inputs = inputs_of(candidate);
        inputs.len() == wanted.len()
            && inputs.iter().zip(wanted.iter()).all(|(input, (ty, indexed))| {
                &solidity_type(input) == ty
                    && input.get("indexed").and_then(Value::as_bool).unwrap_or(false) == *indexed
            })
    })
}

/// Each parameter's ABI type, keyed by the name envio decodes it under.
pub fn param_types(manifest_signature: &str, abi_json: Option<&str>) -> BTreeMap<String, String> {
    let Some(entry) = matching_entry(manifest_signature, abi_json) else {
        return BTreeMap::new();
    };
    inputs_of(&entry)
        .iter()
        .enumerate()
        .map(|(index, input)| {
            let name = input
                .get("name")
                .and_then(Value::as_str)
                .filter(|name| !name.is_empty())
                .map(|name| name.to_string())
                .unwrap_or_else(|| format!("arg{index}"));
            (name, solidity_type(input))
        })
        .collect()
}

/// What to put in the generated config's `event:` field.
pub fn resolve_event(
    manifest_signature: &str,
    abi_json: Option<&str>,
    location: &str,
    report: &mut Report,
) -> String {
    let name = event_name(manifest_signature);
    if candidates(&name, abi_json).len() <= 1 {
        return name;
    }
    match matching_entry(manifest_signature, abi_json) {
        Some(entry) => human_readable(&name, &inputs_of(&entry)),
        None => {
            report.unknown(
                format!("which overload of \"{name}\" \"{manifest_signature}\" refers to"),
                location.to_string(),
            );
            name
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ABI: &str = r#"[
      {"type":"event","name":"Transfer","inputs":[
        {"name":"from","type":"address","indexed":true},
        {"name":"to","type":"address","indexed":true},
        {"name":"value","type":"uint256","indexed":false}]},
      {"type":"event","name":"Transfer","inputs":[
        {"name":"from","type":"address","indexed":true},
        {"name":"to","type":"address","indexed":true},
        {"name":"id","type":"uint256","indexed":false},
        {"name":"data","type":"bytes","indexed":false}]},
      {"type":"event","name":"Approval","inputs":[
        {"name":"owner","type":"address","indexed":true}]},
      {"type":"event","name":"Executed","inputs":[
        {"name":"txHash","type":"bytes32","indexed":false},
        {"name":"payment","type":"uint256","indexed":false}]},
      {"type":"event","name":"Executed","inputs":[
        {"name":"txHash","type":"bytes32","indexed":true},
        {"name":"payment","type":"uint256","indexed":false}]}
    ]"#;

    fn resolve(signature: &str) -> (String, Report) {
        let mut report = Report::new();
        let resolved = resolve_event(signature, Some(ABI), "data source \"Token\"", &mut report);
        (resolved, report)
    }

    // Safe declares ExecutionSuccess both ways, so indexing is the only thing
    // telling the two overloads apart. Resolving both to one signature leaves
    // two events envio cannot route a log to.
    #[test]
    fn tells_two_overloads_apart_by_indexing_alone() {
        assert_eq!(
            (
                resolve("Executed(bytes32,uint256)").0,
                resolve("Executed(indexed bytes32,uint256)").0,
            ),
            (
                "Executed(bytes32 txHash, uint256 payment)".to_string(),
                "Executed(bytes32 indexed txHash, uint256 payment)".to_string(),
            )
        );
    }

    #[test]
    fn reads_param_types_for_a_unique_name() {
        assert_eq!(
            param_types("Approval(indexed address)", Some(ABI)),
            BTreeMap::from([("owner".to_string(), "address".to_string())])
        );
    }

    #[test]
    fn reads_param_types_of_the_matching_overload() {
        assert_eq!(
            param_types(
                "Transfer(indexed address,indexed address,uint256,bytes)",
                Some(ABI)
            ),
            BTreeMap::from([
                ("from".to_string(), "address".to_string()),
                ("to".to_string(), "address".to_string()),
                ("id".to_string(), "uint256".to_string()),
                ("data".to_string(), "bytes".to_string()),
            ])
        );
    }

    #[test]
    fn keeps_the_bare_name_when_it_is_unique() {
        let (resolved, report) = resolve("Approval(indexed address)");
        assert_eq!((resolved.as_str(), report.is_empty()), ("Approval", true));
    }

    #[test]
    fn spells_out_an_overloaded_event() {
        let (three, report) = resolve("Transfer(indexed address,indexed address,uint256)");
        let (four, _) = resolve("Transfer(indexed address,indexed address,uint256,bytes)");
        assert_eq!(
            (three.as_str(), four.as_str(), report.is_empty()),
            (
                "Transfer(address indexed from, address indexed to, uint256 value)",
                "Transfer(address indexed from, address indexed to, uint256 id, bytes data)",
                true
            )
        );
    }

    #[test]
    fn refuses_an_overload_the_abi_does_not_hold() {
        let (_, report) = resolve("Transfer(indexed address,uint128)");
        assert!(
            report
                .to_string()
                .contains("doesn't know which overload of \"Transfer\""),
            "{report}"
        );
    }

    #[test]
    fn flattens_tuple_parameters() {
        let abi = r#"[
          {"type":"event","name":"Trade","inputs":[
            {"name":"order","type":"tuple","indexed":false,"components":[
              {"name":"maker","type":"address"},{"name":"amount","type":"uint256"}]}]},
          {"type":"event","name":"Trade","inputs":[
            {"name":"amount","type":"uint256","indexed":false}]}
        ]"#;
        let mut report = Report::new();
        let resolved = resolve_event(
            "Trade((address,uint256))",
            Some(abi),
            "data source \"Book\"",
            &mut report,
        );
        assert_eq!(
            (resolved.as_str(), report.is_empty()),
            ("Trade((address,uint256) order)", true)
        );
    }
}
