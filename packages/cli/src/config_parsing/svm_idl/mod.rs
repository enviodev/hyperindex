//! Program IDL parsing. Owns the Anchor and Codama dialects; the Borsh
//! runtime (`FieldType`, `decode_instruction`) stays upstream.

mod anchor;
mod codama;
#[cfg(test)]
mod tests;

use std::collections::BTreeMap;

use anyhow::{anyhow, bail, Context, Result};
use hypersync_client_solana::decode::{FieldType, NamedField};
use serde_json::Value;

/// One account slot of an instruction, in declared order.
#[derive(Debug, Clone, PartialEq)]
pub struct IdlAccount {
    pub name: String,
    pub optional: bool,
    pub writable: bool,
    pub signer: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct IxIdl {
    pub discriminator: Vec<u8>,
    pub accounts: Vec<IdlAccount>,
    pub args: Vec<NamedField>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct EventIdl {
    pub discriminator: Vec<u8>,
    pub fields: Vec<NamedField>,
}

/// A parsed program IDL, keyed by name rather than by discriminator: the
/// config addresses instructions by name, and the discriminator is a field.
#[derive(Debug, Clone, PartialEq)]
pub struct ProgramIdl {
    /// The IDL's own program address, when it declares one.
    pub address: Option<String>,
    pub instructions: BTreeMap<String, IxIdl>,
    pub events: BTreeMap<String, EventIdl>,
    pub defined_types: BTreeMap<String, FieldType>,
}

pub fn parse_idl(json: &str, program_name: &str) -> Result<ProgramIdl> {
    parse_either_dialect(json).with_context(|| format!("parsing IDL for program '{program_name}'"))
}

fn parse_either_dialect(json: &str) -> Result<ProgramIdl> {
    let root: Value = serde_json::from_str(json).context("invalid JSON")?;
    let root = root
        .as_object()
        .ok_or_else(|| anyhow!("expected a JSON object at the IDL root"))?;

    if root.contains_key("rootNode") || root.get("kind").and_then(Value::as_str) == Some("rootNode")
    {
        codama::parse(root)
    } else if root.contains_key("instructions") {
        anchor::parse(root)
    } else {
        bail!(
            "unrecognized IDL: expected an Anchor IDL (top-level 'instructions') or a Codama IDL \
             (a 'rootNode')"
        )
    }
}

/// PascalCase on `_`/`-`/`.` boundaries: `pump_fun` → `PumpFun`,
/// `pumpfun` → `Pumpfun`.
pub fn program_name_from_filename(file_stem: &str) -> String {
    file_stem
        .split(['_', '-', '.'])
        .filter(|segment| !segment.is_empty())
        .map(|segment| {
            let mut chars = segment.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().chain(chars).collect::<String>(),
                None => String::new(),
            }
        })
        .collect()
}
