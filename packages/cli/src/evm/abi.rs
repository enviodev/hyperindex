use alloy_json_abi::JsonAbi;
use anyhow::{anyhow, Result};
use serde::Deserialize;
use serde_json::Value;

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

/// A contract has one constructor, one fallback and one receive. An ABI
/// concatenated from a proxy and its implementation lists them twice, and the
/// parser has nowhere to put the second.
fn drop_repeated_singletons(text: &str) -> Option<String> {
    let mut parsed: Value = serde_json::from_str(text).ok()?;
    let mut seen = [false; 3];
    items_mut(&mut parsed)?.retain(|item| {
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

/// `AbiOrNestedAbi` is untagged, so serde only reports that the file matched no
/// variant. Reading it again as the shape it actually is recovers the real
/// complaint: the unknown entry type, the malformed parameter.
fn diagnose(text: &str) -> Option<serde_json::Error> {
    let mut parsed: Value = serde_json::from_str(text).ok()?;
    let items = std::mem::take(items_mut(&mut parsed)?);
    serde_json::from_value::<JsonAbi>(Value::Array(items)).err()
}

/// Reads an ABI file, repairing what old toolchains wrote.
pub fn parse(text: &str) -> Result<AbiOrNestedAbi> {
    let err = match serde_json::from_str::<AbiOrNestedAbi>(text) {
        Ok(abi) => return Ok(abi),
        Err(err) => err,
    };
    let repaired = drop_repeated_singletons(text)
        .and_then(|text| serde_json::from_str::<AbiOrNestedAbi>(&text).ok());
    match repaired {
        Some(abi) => Ok(abi),
        None => Err(anyhow!("{}", diagnose(text).unwrap_or(err))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn events(abi: AbiOrNestedAbi) -> Vec<String> {
        let (AbiOrNestedAbi::Abi(abi) | AbiOrNestedAbi::NestedAbi { abi }) = abi;
        abi.events().map(|event| event.name.clone()).collect()
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
    fn reports_what_an_unreadable_abi_got_wrong() {
        let Err(err) = parse(r#"[{"type": "wormhole"}]"#) else {
            panic!("expected an unreadable ABI to fail");
        };

        assert_eq!(
            err.to_string(),
            "unknown variant `wormhole`, expected one of `constructor`, `fallback`, `receive`, \
             `function`, `event`, `error`"
        );
    }

    #[test]
    fn reports_what_a_malformed_parameter_got_wrong() {
        let Err(err) = parse(
            r#"[{"anonymous": false, "name": "E", "type": "event", "inputs": [{"name": "a", "type": "uint256[", "indexed": false}]}]"#,
        ) else {
            panic!("expected an unreadable ABI to fail");
        };

        assert_eq!(
            err.to_string(),
            "invalid value: string \"uint256[\", expected a valid Solidity type specifier"
        );
    }

    #[test]
    fn reports_that_a_file_which_is_not_json_is_not_json() {
        let Err(err) = parse("not json") else {
            panic!("expected an unreadable ABI to fail");
        };

        assert_eq!(err.to_string(), "expected ident at line 1 column 2");
    }
}
