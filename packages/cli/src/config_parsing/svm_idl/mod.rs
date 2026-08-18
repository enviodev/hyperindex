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
    /// Discriminators of the instructions in `unusable`, where one was read
    /// before the layout failed. Setting an instruction aside does not remove
    /// it from the chain: it still occurs and still answers to its
    /// discriminator, so it still has to be weighed against everything that
    /// survived.
    pub unusable_discriminators: BTreeMap<String, Vec<u8>>,
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
        }
    }

    // Judged over every discriminator the program declares, not just the ones
    // that survive. Setting an instruction aside does not remove it from the
    // chain: it still occurs, and its data still arrives carrying its own
    // discriminator. What matters is whether that data can reach a survivor —
    // which is a question about the bytes, not about whether we can decode the
    // instruction they belong to. A width we cannot dispatch is no exception:
    // nothing routes *to* a 3-byte discriminator, but a 2-byte survivor
    // holding its first two bytes still collects its calls. Only an empty
    // discriminator drops out, being a prefix of everything and evidence of
    // nothing.
    let declared: Vec<(&[u8], &str)> = idl
        .instructions
        .iter()
        .map(|(name, ix)| (ix.discriminator.as_slice(), name.as_str()))
        .chain(
            idl.unusable_discriminators
                .iter()
                .map(|(name, bytes)| (bytes.as_slice(), name.as_str())),
        )
        .filter(|(bytes, _)| !bytes.is_empty())
        .collect();
    for (name, reason) in prefix_collisions(declared) {
        // A name already set aside keeps the reason it was set aside for.
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

    // Nothing reads events yet, so nothing has caught one left holding a
    // reference to a type about to be pruned. Drop those with the type.
    let dangling: Vec<String> = idl
        .events
        .iter()
        .filter(|(_, event)| {
            event
                .fields
                .iter()
                .any(|f| references_resolve(&f.ty, idl, &bad_types).is_err())
        })
        .map(|(name, _)| name.clone())
        .collect();
    for name in dangling {
        idl.events.remove(&name);
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
            idl.unusable_discriminators
                .insert(name.clone(), ix.discriminator);
        }
        idl.unusable.insert(name, reason);
    }
}

/// Dispatch probes discriminator widths longest-first and compares a prefix of
/// the data, so a discriminator that is a prefix of another leaves neither
/// instruction routable. The shorter never fires: the longer wins every probe
/// that reaches it. The longer over-fires: a call to the shorter whose payload
/// happens to continue with the extra bytes matches it instead, and decodes
/// against the wrong layout. Equal discriminators are the degenerate case of
/// the same thing.
fn prefix_collisions(mut by_bytes: Vec<(&[u8], &str)>) -> Unusable {
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
            let (short_hex, long_hex) = (crate::hex::encode(shorter), crate::hex::encode(longer));
            out.insert(
                first.to_string(),
                format!(
                    "its discriminator 0x{short_hex} is a prefix of '{second}'\'s 0x{long_hex}, so \
                     '{second}' takes every call that would have matched it"
                ),
            );
            out.insert(
                second.to_string(),
                format!(
                    "its discriminator 0x{long_hex} extends '{first}'\'s 0x{short_hex}, so a \
                     '{first}' call whose data continues those bytes arrives here instead"
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

/// One entry per declared type that cannot be resolved, with the reason.
/// Settled to a fixed point, so a type is condemned by anything it reaches
/// however deeply, while each type is still inspected a bounded number of
/// times. Following nominal references per occurrence instead is exponential
/// on a type graph that shares subtrees, which real IDLs do.
fn unresolvable_types(idl: &ProgramIdl) -> Unusable {
    let mut bad = idl.unusable_types.clone();
    loop {
        let mut changed = false;
        for (name, ty) in &idl.defined_types {
            if bad.contains_key(name) {
                continue;
            }
            if let Err(reason) = references_resolve(ty, idl, &bad) {
                bad.insert(name.clone(), reason);
                changed = true;
            }
        }
        if !changed {
            return bad;
        }
    }
}

/// Whether every nominal reference reachable through `ty`'s own structure
/// resolves. Deliberately does not follow those references: `unresolvable_types`
/// has already settled what each name is worth, so this walks one type's shape
/// and stops. A mistyped primitive (`u46`) arrives here as a nominal type, and
/// this is what catches it rather than leaving it for the runtime.
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

/// Parse instructions, reading the discriminator before the layout so it
/// survives a layout failure. Returns the usable instructions, the reasons the
/// rest were set aside, and the discriminators of those that got far enough to
/// have one.
fn collect_instructions<T>(
    entries: &[Value],
    mut discriminator_of: impl FnMut(&str, &Value) -> Result<(Vec<u8>, T)>,
    mut layout_of: impl FnMut(&Value, Vec<u8>, T) -> Result<IxIdl>,
) -> Result<(BTreeMap<String, IxIdl>, Unusable, BTreeMap<String, Vec<u8>>)> {
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
        match layout_of(entry, discriminator.clone(), carried) {
            Ok(ix) => {
                out.insert(name, ix);
            }
            Err(e) => {
                unusable.insert(name.clone(), format!("{e:#}"));
                discriminators.insert(name, discriminator);
            }
        }
    }
    Ok((out, unusable, discriminators))
}

/// Parse each entry of a named collection, setting the failures aside instead
/// of failing the whole IDL. Shared by both dialects so the duplicate-name
/// rule and the demotion policy cannot drift between them.
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
        // A repeated name makes that name ambiguous for whatever reaches it,
        // and nothing else. Instructions are stricter — see
        // `collect_instructions`, where a repeat leaves dispatch with no way
        // to say which was meant.
        if out.contains_key(&name) || unusable.contains_key(&name) {
            out.remove(&name);
            let reason = format!("the IDL declares {noun} '{name}' more than once");
            unusable.insert(name, reason);
            continue;
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
