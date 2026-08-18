//! Program IDL parsing. Owns the Anchor and Codama dialects; the Borsh
//! runtime (`FieldType`, `decode_instruction`) stays upstream.

mod anchor;
mod codama;
#[cfg(test)]
mod tests;

use std::collections::{BTreeMap, BTreeSet};

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

/// Names the runtime cannot decode or dispatch, each with the reason, so the
/// reason survives to whoever asks for that name.
pub type Unusable = BTreeMap<String, String>;

/// A parsed program IDL, keyed by name rather than by discriminator: the
/// config addresses instructions by name, and the discriminator is a field.
#[derive(Debug, Clone, PartialEq)]
pub struct ProgramIdl {
    /// The IDL's own program address, when it declares one.
    pub address: Option<String>,
    pub instructions: BTreeMap<String, IxIdl>,
    pub events: BTreeMap<String, EventIdl>,
    pub defined_types: BTreeMap<String, FieldType>,
    /// Instructions the program declares that this runtime cannot decode or
    /// dispatch. Held aside rather than rejected: an IDL describes a whole
    /// program while a config indexes a few of its instructions, and the two
    /// are routinely far apart. SPL Token declares a remainder-encoded string
    /// that Borsh has no shape for, and every other instruction it declares
    /// decodes fine — failing the file would put `transfer` out of reach over
    /// a shape nobody asked to decode.
    pub unusable: Unusable,
    /// Declared types whose layout the runtime cannot express. Kept for the
    /// reason text: an instruction reaching one is unusable for that reason,
    /// not for the "undefined type" a bare lookup would report.
    pub unusable_types: Unusable,
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

    let mut idl = if root.contains_key("rootNode")
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

    validate(&mut idl);
    Ok(idl)
}

/// Everything both dialects have to hold true once parsed. Kept here rather
/// than in each parser so a shape only one dialect can produce still can't
/// reach codegen through the other.
///
/// Failures demote an instruction instead of rejecting the IDL. Whether one
/// matters is a question about the config, not about the file, so the answer
/// belongs where the config names an instruction.
fn validate(idl: &mut ProgramIdl) {
    let mut demoted = Unusable::new();
    for (name, ix) in &idl.instructions {
        let len = ix.discriminator.len();
        if !DISPATCHABLE_DISCRIMINATOR_LENS.contains(&len) {
            demoted.insert(
                name.clone(),
                format!(
                    "its {len}-byte discriminator is not one of the widths dispatch probes \
                     ({DISPATCHABLE_DISCRIMINATOR_LENS:?})"
                ),
            );
            continue;
        }
        for arg in &ix.args {
            if let Err(e) = check_resolvable(&arg.ty, idl, &mut BTreeSet::new()) {
                demoted.insert(name.clone(), format!("{e:#}"));
                break;
            }
        }
    }
    // Events are parsed but nothing consumes them, so an event payload the
    // runtime cannot decode is not a reason to withhold an instruction.
    demote(idl, demoted);

    let collisions = prefix_collisions(&idl.instructions);
    demote(idl, collisions);
}

fn demote(idl: &mut ProgramIdl, demoted: Unusable) {
    for (name, reason) in demoted {
        idl.instructions.remove(&name);
        idl.unusable.insert(name, reason);
    }
}

/// Dispatch probes discriminator widths longest-first, so if one
/// instruction's discriminator is a prefix of another's, the longer one wins
/// every match and the shorter one never fires. Equal discriminators are the
/// degenerate case: neither can be routed to at all.
fn prefix_collisions(instructions: &BTreeMap<String, IxIdl>) -> Unusable {
    let mut by_bytes: Vec<(&[u8], &str)> = instructions
        .iter()
        .map(|(name, ix)| (ix.discriminator.as_slice(), name.as_str()))
        .collect();
    by_bytes.sort_unstable();
    let mut out = Unusable::new();
    // A prefix sorts immediately before everything it prefixes, so the
    // adjacent pairs cover every collision.
    for window in by_bytes.windows(2) {
        let [(shorter, first), (longer, second)] = window else {
            continue;
        };
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
        } else if longer.starts_with(shorter) {
            out.insert(
                first.to_string(),
                format!(
                    "its discriminator 0x{} is a prefix of '{second}'\'s 0x{}, which would shadow \
                     it",
                    crate::hex::encode(shorter),
                    crate::hex::encode(longer),
                ),
            );
        }
    }
    out
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

/// Every `Defined` name must resolve to a layout, and so must everything that
/// layout reaches. An unresolved one is not a decode-time surprise to leave
/// for the runtime: a mistyped primitive (`u46`) lands here as a nominal type,
/// and this is what catches it. `visiting` both breaks the cycles a
/// self-referential type would otherwise spin on and keeps a diamond from
/// being walked twice.
fn check_resolvable(
    ty: &FieldType,
    idl: &ProgramIdl,
    visiting: &mut BTreeSet<String>,
) -> Result<()> {
    match ty {
        FieldType::Defined(name) => {
            if let Some(reason) = idl.unusable_types.get(name) {
                bail!("it reaches type '{name}', which cannot be decoded: {reason}");
            }
            let Some(target) = idl.defined_types.get(name) else {
                bail!("it references undefined type '{name}'");
            };
            if !visiting.insert(name.clone()) {
                return Ok(());
            }
            let resolved = check_resolvable(target, idl, visiting);
            visiting.remove(name);
            resolved
        }
        FieldType::Option(inner) | FieldType::Vec(inner) | FieldType::Array { ty: inner, .. } => {
            check_resolvable(inner, idl, visiting)
        }
        FieldType::Struct(fields) => fields
            .iter()
            .try_for_each(|f| check_resolvable(&f.ty, idl, visiting)),
        FieldType::Enum(variants) => variants
            .iter()
            .flat_map(|v| v.fields.iter().flatten())
            .try_for_each(|f| check_resolvable(&f.ty, idl, visiting)),
        _ => Ok(()),
    }
}

/// Parse each entry of a named collection, setting the failures aside instead
/// of failing the whole IDL. Shared by both dialects so the duplicate-name
/// rule and the demotion policy cannot drift between them.
fn collect_named<T>(
    entries: &[Value],
    what: &str,
    mut parse_one: impl FnMut(&str, &Value) -> Result<T>,
) -> Result<(BTreeMap<String, T>, Unusable)> {
    let mut out = BTreeMap::new();
    let mut unusable = Unusable::new();
    for entry in entries {
        let name = required_str(entry, "name")
            .with_context(|| format!("{what}s[].name"))?
            .to_string();
        if out.contains_key(&name) || unusable.contains_key(&name) {
            bail!("IDL declares {what} '{name}' more than once");
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

/// Shared by both parsers: a required string field, with the offending node in
/// the message so a deep IDL doesn't need a path to be diagnosable.
fn required_str<'a>(node: &'a Value, key: &str) -> Result<&'a str> {
    node.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("missing '{key}' in {node}"))
}
