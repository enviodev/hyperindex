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

/// Discriminator widths the router can probe for. Dispatch reads a fixed-width
/// prefix off `instruction.data`, so a width outside this set parses fine here
/// and then fails at indexer start, far from the IDL that caused it.
const DISPATCHABLE_DISCRIMINATOR_LENS: [usize; 4] = [1, 2, 4, 8];

pub fn parse_idl(json: &str, program_name: &str) -> Result<ProgramIdl> {
    parse_validated(json).with_context(|| format!("parsing IDL for program '{program_name}'"))
}

fn parse_validated(json: &str) -> Result<ProgramIdl> {
    let root: Value = serde_json::from_str(json).context("invalid JSON")?;
    let root = root
        .as_object()
        .ok_or_else(|| anyhow!("expected a JSON object at the IDL root"))?;

    let idl = if root.contains_key("rootNode")
        || root.get("kind").and_then(Value::as_str) == Some("rootNode")
    {
        codama::parse(root)
    } else if root.contains_key("instructions") {
        anchor::parse(root)
    } else {
        bail!(
            "unrecognized IDL: expected an Anchor IDL (top-level 'instructions') or a Codama IDL \
             (a 'rootNode')"
        )
    }?;

    validate(&idl)?;
    Ok(idl)
}

/// Everything both dialects have to hold true once parsed. Kept here rather
/// than in each parser so a shape only one dialect can produce still can't
/// reach codegen through the other.
fn validate(idl: &ProgramIdl) -> Result<()> {
    for (name, ix) in &idl.instructions {
        let len = ix.discriminator.len();
        if !DISPATCHABLE_DISCRIMINATOR_LENS.contains(&len) {
            bail!(
                "instruction '{name}' has a {len}-byte discriminator; dispatch only probes widths \
                 {DISPATCHABLE_DISCRIMINATOR_LENS:?}"
            );
        }
        for arg in &ix.args {
            check_resolvable(
                &arg.ty,
                &idl.defined_types,
                &format!("instruction '{name}'"),
            )?;
        }
    }
    for (name, event) in &idl.events {
        for field in &event.fields {
            check_resolvable(&field.ty, &idl.defined_types, &format!("event '{name}'"))?;
        }
    }
    for (name, ty) in &idl.defined_types {
        check_resolvable(ty, &idl.defined_types, &format!("type '{name}'"))?;
    }
    check_no_prefix_collisions(&idl.instructions)?;
    Ok(())
}

/// Dispatch probes discriminator widths longest-first, so if one
/// instruction's discriminator is a prefix of another's, the longer one wins
/// every match and the shorter one never fires. Equal discriminators are the
/// degenerate case of the same problem.
fn check_no_prefix_collisions(instructions: &BTreeMap<String, IxIdl>) -> Result<()> {
    let mut by_bytes: Vec<(&[u8], &str)> = instructions
        .iter()
        .map(|(name, ix)| (ix.discriminator.as_slice(), name.as_str()))
        .collect();
    by_bytes.sort_unstable();
    // A prefix sorts immediately before everything it prefixes, so the
    // adjacent pairs cover every collision.
    for window in by_bytes.windows(2) {
        let [(shorter, first), (longer, second)] = window else {
            continue;
        };
        if shorter == longer {
            bail!(
                "instructions '{first}' and '{second}' share discriminator 0x{}",
                crate::hex::encode(shorter)
            );
        }
        if longer.starts_with(shorter) {
            bail!(
                "instruction '{first}' has discriminator 0x{}, a prefix of '{second}'\'s 0x{}, so \
                 '{second}' would shadow it",
                crate::hex::encode(shorter),
                crate::hex::encode(longer),
            );
        }
    }
    Ok(())
}

/// The numeric formats both dialects spell the same way. Shared so a width the
/// runtime learns to decode cannot reach one dialect and not the other.
fn numeric_field_type(format: &str) -> Option<FieldType> {
    Some(match format {
        "u8" => FieldType::U8,
        "u16" => FieldType::U16,
        "u32" => FieldType::U32,
        "u64" => FieldType::U64,
        "u128" => FieldType::U128,
        "i8" => FieldType::I8,
        "i16" => FieldType::I16,
        "i32" => FieldType::I32,
        "i64" => FieldType::I64,
        "i128" => FieldType::I128,
        "f32" => FieldType::F32,
        "f64" => FieldType::F64,
        _ => return None,
    })
}

/// Every `Defined` name must be in the registry. An unresolved one is not a
/// decode-time surprise to leave for the runtime: a mistyped primitive
/// (`u46`) lands here as a nominal type, and this is what catches it.
fn check_resolvable(
    ty: &FieldType,
    defined_types: &BTreeMap<String, FieldType>,
    path: &str,
) -> Result<()> {
    match ty {
        FieldType::Defined(name) => {
            if !defined_types.contains_key(name) {
                bail!("{path} references undefined type '{name}'");
            }
            Ok(())
        }
        FieldType::Option(inner) | FieldType::Vec(inner) | FieldType::Array { ty: inner, .. } => {
            check_resolvable(inner, defined_types, path)
        }
        FieldType::Struct(fields) => fields
            .iter()
            .try_for_each(|f| check_resolvable(&f.ty, defined_types, path)),
        FieldType::Enum(variants) => variants
            .iter()
            .flat_map(|v| v.fields.iter().flatten())
            .try_for_each(|f| check_resolvable(&f.ty, defined_types, path)),
        _ => Ok(()),
    }
}

/// Shared by both parsers: a required string field, with the offending node in
/// the message so a deep IDL doesn't need a path to be diagnosable.
fn required_str<'a>(node: &'a Value, key: &str) -> Result<&'a str> {
    node.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("missing '{key}' in {node}"))
}
