//! Program IDL parsing. Owns the Anchor and Codama dialects; the Borsh
//! runtime (`FieldType`, `decode_instruction`) stays upstream.
//!
//! Nothing in the config pipeline calls this yet, so the whole module reads as
//! dead code until the wiring lands. Drop the attribute then.
#![allow(dead_code)]

mod anchor;
mod codama;
#[cfg(test)]
mod tests;

use std::collections::BTreeMap;

use anyhow::{anyhow, bail, Context, Result};
use hypersync_client_solana::decode::{FieldType, NamedField};
use serde_json::{Map, Value};

/// One account slot of an instruction, in declared order.
#[derive(Debug, Clone, PartialEq)]
pub struct IdlAccount {
    pub name: String,
    pub optional: bool,
}

/// Only a trailing run of optional slots can be omitted from a transaction.
/// A middle optional would shift later names, so generated types keep it required.
pub fn trailing_optional_mask(accounts: &[IdlAccount]) -> Vec<bool> {
    let mut mask = vec![false; accounts.len()];
    for (i, account) in accounts.iter().enumerate().rev() {
        if !account.optional {
            break;
        }
        mask[i] = true;
    }
    mask
}

#[derive(Debug, Clone, PartialEq)]
pub struct IxIdl {
    pub discriminator: Vec<u8>,
    pub accounts: Vec<IdlAccount>,
    pub args: Vec<NamedField>,
}

pub type Unusable = BTreeMap<String, String>;

/// Parsed program IDL, keyed by instruction name.
#[derive(Debug, Clone, PartialEq)]
pub struct ProgramIdl {
    pub address: Option<String>,
    pub instructions: BTreeMap<String, IxIdl>,
    pub defined_types: BTreeMap<String, FieldType>,
    /// Declared instructions this runtime cannot decode or dispatch. They are
    /// omitted from the catalog; if none remain, the program fails with these
    /// reasons.
    pub unusable: Unusable,
    pub unusable_types: Unusable,
    /// Known non-empty prefixes of set-aside instructions. Prefix collision
    /// is about the bytes on chain, not about whether we can decode the ix.
    declared_discriminators: BTreeMap<String, Vec<u8>>,
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

    let mut idl = if is_codama_root(root) {
        codama::parse(root)
    } else if root.contains_key("instructions") {
        anchor::parse(root)
    } else {
        bail!(
            "unrecognized IDL: expected an Anchor IDL (top-level 'instructions') or a Codama IDL \
             (a 'rootNode' or 'programNode')"
        )
    }?;

    validate(&mut idl);
    Ok(idl)
}

fn is_codama_root(root: &Map<String, Value>) -> bool {
    root.contains_key("rootNode")
        || matches!(
            root.get("kind").and_then(Value::as_str),
            Some("rootNode" | "programNode")
        )
}

/// Shared post-parse checks. Failures demote an instruction from the catalog.
fn validate(idl: &mut ProgramIdl) {
    let mut demoted = Unusable::new();
    for (name, ix) in &idl.instructions {
        let len = ix.discriminator.len();
        if !DISPATCHABLE_DISCRIMINATOR_LENS.contains(&len) {
            demoted.insert(
                name.clone(),
                format!(
                    "its discriminator is {len} bytes, and dispatch matches only 1, 2, 4, or 8"
                ),
            );
        }
    }

    // Empty / unreadable prefixes are not evidence of a collision. An
    // instruction the file never declared is the same unknown. An empty
    // prefix is still unroutable (the width check above).
    let declared: Vec<(&[u8], &str)> = idl
        .instructions
        .iter()
        .map(|(name, ix)| (ix.discriminator.as_slice(), name.as_str()))
        .chain(
            idl.declared_discriminators
                .iter()
                .map(|(name, bytes)| (bytes.as_slice(), name.as_str())),
        )
        .filter(|(bytes, _)| !bytes.is_empty())
        .collect();
    for (name, reason) in prefix_collisions(declared) {
        if idl.instructions.contains_key(&name) {
            demoted.entry(name).or_insert(reason);
        }
    }

    let bad_types = unresolvable_types(idl);
    for (name, ix) in &idl.instructions {
        if demoted.contains_key(name) {
            continue;
        }
        for arg in &ix.args {
            if let Err(reason) = references_resolve(&arg.ty, idl, &bad_types) {
                demoted.insert(name.clone(), reason);
                break;
            }
        }
    }

    // Codegen hands `defined_types` to the runtime's type registry whole, so a
    // type that cannot be resolved must not be in it — even when no
    // instruction reaches it.
    for name in bad_types.keys() {
        idl.defined_types.remove(name);
    }
    idl.unusable_types.extend(bad_types);
    demote(idl, demoted);
}

fn demote(idl: &mut ProgramIdl, demoted: Unusable) {
    for (name, reason) in demoted {
        if let Some(ix) = idl.instructions.remove(&name) {
            if !ix.discriminator.is_empty() {
                idl.declared_discriminators
                    .insert(name.clone(), ix.discriminator);
            }
        }
        idl.unusable.insert(name, reason);
    }
}

/// Dispatch probes widths longest-first, so `0x0c` and `0x0c02` are one key:
/// the longer wins every probe that reaches it, and the shorter never fires.
pub(crate) fn prefix_collisions(mut by_bytes: Vec<(&[u8], &str)>) -> Unusable {
    by_bytes.sort_unstable();
    let mut out = Unusable::new();
    for (i, (shorter, first)) in by_bytes.iter().enumerate() {
        for (longer, second) in by_bytes[i + 1..].iter() {
            if !longer.starts_with(shorter) {
                break;
            }
            if shorter == longer {
                let hex = crate::hex::encode(shorter);
                out.insert(
                    first.to_string(),
                    format!("it shares discriminator 0x{hex} with '{second}'"),
                );
                out.insert(
                    second.to_string(),
                    format!("it shares discriminator 0x{hex} with '{first}'"),
                );
                continue;
            }
            out.entry(first.to_string()).or_insert_with(|| {
                format!(
                    "its discriminator 0x{} is a prefix of '{second}'\'s 0x{}, so '{second}' \
                     takes every call that would have matched it",
                    crate::hex::encode(shorter),
                    crate::hex::encode(longer),
                )
            });
            out.entry(second.to_string()).or_insert_with(|| {
                format!(
                    "its discriminator 0x{} extends '{first}'\'s 0x{}, so a '{first}' call whose \
                     data continues those bytes arrives here instead",
                    crate::hex::encode(longer),
                    crate::hex::encode(shorter),
                )
            });
        }
    }
    out
}

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

fn unresolvable_types(idl: &ProgramIdl) -> Unusable {
    let mut bad = idl.unusable_types.clone();
    loop {
        let mut changed = false;
        for (name, ty) in &idl.defined_types {
            if bad.contains_key(name) {
                continue;
            }
            let reason = unbounded_recursion(
                ty,
                idl,
                &mut vec![name.clone()],
                false,
                &mut std::collections::HashSet::new(),
            )
            .err()
            .or_else(|| references_resolve(ty, idl, &bad).err());
            if let Some(reason) = reason {
                bad.insert(name.clone(), reason);
                changed = true;
            }
        }
        if !changed {
            return bad;
        }
    }
}

/// `Option`/`Vec` carry a tag or length, so a type may name itself behind
/// them. A `Defined` cycle with no such terminator would recurse in
/// `decode_field` until the stack overflows.
fn unbounded_recursion(
    ty: &FieldType,
    idl: &ProgramIdl,
    stack: &mut Vec<String>,
    through_var_len: bool,
    seen: &mut std::collections::HashSet<(String, bool)>,
) -> Result<(), String> {
    match ty {
        FieldType::Defined(name) => {
            if stack.iter().any(|n| n == name) {
                if through_var_len {
                    Ok(())
                } else {
                    Err(
                        "it recursively contains itself without an option or vec to terminate \
                         decoding"
                            .to_string(),
                    )
                }
            } else if seen.contains(&(name.clone(), through_var_len))
                || seen.contains(&(name.clone(), false))
            {
                Ok(())
            } else if let Some(inner) = idl.defined_types.get(name) {
                stack.push(name.clone());
                let result = unbounded_recursion(inner, idl, stack, through_var_len, seen);
                stack.pop();
                if result.is_ok() {
                    seen.insert((name.clone(), through_var_len));
                }
                result
            } else {
                Ok(())
            }
        }
        FieldType::Option(inner) | FieldType::Vec(inner) => {
            unbounded_recursion(inner, idl, stack, true, seen)
        }
        FieldType::Array { ty: inner, .. } => {
            unbounded_recursion(inner, idl, stack, through_var_len, seen)
        }
        FieldType::Struct(fields) => fields
            .iter()
            .try_for_each(|f| unbounded_recursion(&f.ty, idl, stack, through_var_len, seen)),
        FieldType::Enum(variants) => variants
            .iter()
            .flat_map(|v| v.fields.iter().flatten())
            .try_for_each(|f| unbounded_recursion(&f.ty, idl, stack, through_var_len, seen)),
        _ => Ok(()),
    }
}

/// Walks `ty`'s own shape only. `unresolvable_types` already settled each name.
fn references_resolve(ty: &FieldType, idl: &ProgramIdl, bad: &Unusable) -> Result<(), String> {
    match ty {
        FieldType::Defined(name) => {
            if let Some(reason) = bad.get(name) {
                Err(format!(
                    "it reaches type '{name}', which cannot be decoded: {reason}"
                ))
            } else if !idl.defined_types.contains_key(name) {
                Err(format!("it references undefined type '{name}'"))
            } else {
                Ok(())
            }
        }
        FieldType::Option(inner) | FieldType::Vec(inner) | FieldType::Array { ty: inner, .. } => {
            references_resolve(inner, idl, bad)
        }
        FieldType::Struct(fields) => fields
            .iter()
            .try_for_each(|f| references_resolve(&f.ty, idl, bad)),
        FieldType::Enum(variants) => variants
            .iter()
            .flat_map(|v| v.fields.iter().flatten())
            .try_for_each(|f| references_resolve(&f.ty, idl, bad)),
        _ => Ok(()),
    }
}

pub(super) type Instructions = (BTreeMap<String, IxIdl>, Unusable, BTreeMap<String, Vec<u8>>);

fn collect_instructions<T>(
    entries: &[Value],
    mut discriminator_of: impl FnMut(&str, &Value) -> Result<(Vec<u8>, T)>,
    mut layout_of: impl FnMut(&Value, Vec<u8>, T) -> Result<IxIdl>,
) -> Result<Instructions> {
    let mut out = BTreeMap::new();
    let mut unusable = Unusable::new();
    let mut discriminators = BTreeMap::new();
    for entry in entries {
        let name = required_str(entry, "name")
            .context("instructions[].name")?
            .to_string();
        if out.contains_key(&name) || unusable.contains_key(&name) {
            bail!("IDL declares instruction '{name}' more than once");
        }
        let (discriminator, carried) = match discriminator_of(&name, entry) {
            Ok(parsed) => parsed,
            Err(e) => {
                unusable.insert(name, format!("{e:#}"));
                continue;
            }
        };
        // Colliding flattened names are this instruction's defect, like any
        // other layout defect: the rest of the program stays indexable.
        let parsed = layout_of(entry, discriminator.clone(), carried)
            .and_then(|ix| reject_duplicate_account_names(&ix.accounts).map(|()| ix));
        match parsed {
            Ok(ix) => {
                out.insert(name, ix);
            }
            Err(e) => {
                unusable.insert(name.clone(), format!("{e:#}"));
                if !discriminator.is_empty() {
                    discriminators.insert(name, discriminator);
                }
            }
        }
    }
    Ok((out, unusable, discriminators))
}

fn collect_named<T>(
    entries: &[Value],
    noun: &str,
    name_context: &str,
    mut parse_one: impl FnMut(&str, &Value) -> Result<T>,
) -> Result<(BTreeMap<String, T>, Unusable)> {
    let mut out = BTreeMap::new();
    let mut unusable = Unusable::new();
    for entry in entries {
        let name = required_str(entry, "name")
            .with_context(|| name_context.to_string())?
            .to_string();
        if out.contains_key(&name) || unusable.contains_key(&name) {
            bail!("IDL declares {noun} '{name}' more than once");
        }
        match parse_one(&name, entry) {
            Ok(parsed) => {
                out.insert(name, parsed);
            }
            Err(e) => {
                unusable.insert(name, format!("{e:#}"));
            }
        }
    }
    Ok((out, unusable))
}

/// An `accounts` list. Absent means an instruction that takes none; present but
/// not an array is a defect, since reading it as empty would drop its slots and
/// shift every later account's name.
fn account_array<'a>(node: Option<&'a Value>) -> Result<&'a [Value]> {
    match node {
        None => Ok(&[]),
        Some(node) => node
            .as_array()
            .map(Vec::as_slice)
            .ok_or_else(|| anyhow!("expected an array of accounts, got {node}")),
    }
}

/// One account slot. The dialects spell the optional flag differently — Anchor
/// 0.30 `optional`, legacy Anchor and Codama `isOptional` — but neither may
/// leave it unreadable: defaulting a non-boolean to `false` makes the slot
/// required, and a transaction that omits it pairs every later pubkey with the
/// wrong name.
pub(super) fn account_slot(node: &Value) -> Result<IdlAccount> {
    let mut optional = false;
    for key in ["optional", "isOptional"] {
        match node.get(key) {
            None => continue,
            Some(Value::Bool(value)) => optional = *value,
            Some(other) => bail!("'{key}' must be a boolean, got {other}"),
        }
        break;
    }
    Ok(IdlAccount {
        name: required_str(node, "name")?.to_string(),
        optional,
    })
}

fn reject_duplicate_account_names(accounts: &[IdlAccount]) -> Result<()> {
    let mut seen = std::collections::HashSet::new();
    for account in accounts {
        if !seen.insert(account.name.as_str()) {
            bail!("IDL declares account '{}' more than once", account.name);
        }
    }
    Ok(())
}

fn required_str<'a>(node: &'a Value, key: &str) -> Result<&'a str> {
    node.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("missing '{key}' in {node}"))
}
