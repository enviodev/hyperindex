//! The Anchor and Codama dialects read into one shape, with the reasons for
//! whatever this runtime cannot dispatch or decode. A defect costs the
//! instruction or type that carries it, not the file: a program stays
//! indexable when one of its instructions is not.

mod anchor;
mod codama;
#[cfg(test)]
mod tests;

use std::collections::{BTreeMap, BTreeSet, HashSet};

use anyhow::{anyhow, bail, Context, Result};
use hypersync_client_solana::decode::{FieldType, NamedField};
use serde_json::{Map, Value};

/// One account slot of an instruction, in declared order.
#[derive(Debug, Clone, PartialEq)]
pub struct IdlAccount {
    pub name: String,
    pub optional: bool,
}

/// The first optional slot with a required one after it, if any. Names are
/// paired to accounts by position, so a slot like that shifts every name after
/// it when the transaction leaves it out.
fn optional_before_a_required_slot(accounts: &[IdlAccount]) -> Option<&IdlAccount> {
    let last_required = accounts.iter().rposition(|a| !a.optional)?;
    accounts[..last_required].iter().find(|a| a.optional)
}

#[derive(Debug, Clone, PartialEq)]
pub struct IxIdl {
    pub discriminator: Vec<u8>,
    /// The bytes were derived from the instruction's name rather than read off
    /// the file. Only legacy Anchor does this, and only because such a file
    /// leaves them implicit — but an IDL is Anchor-shaped whether or not the
    /// program dispatches on an Anchor hash, so a config that disagrees with a
    /// derived value may well be the one that is right.
    pub derived: bool,
    pub accounts: Vec<IdlAccount>,
    pub args: Vec<NamedField>,
}

pub type Unusable = BTreeMap<String, String>;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct ProgramIdl {
    pub address: Option<String>,
    pub instructions: BTreeMap<String, IxIdl>,
    pub defined_types: BTreeMap<String, FieldType>,
    /// Declared instructions this runtime cannot decode or dispatch, and why.
    /// They are out of the catalog, so a config naming one is answered with the
    /// reason rather than a silent miss.
    pub unusable: Unusable,
    pub unusable_types: Unusable,
    /// Known non-empty prefixes of set-aside instructions. Prefix collision
    /// is about the bytes on chain, not about whether we can decode the ix.
    declared_discriminators: BTreeMap<String, Vec<u8>>,
}

/// Discriminator widths the router can probe for. Dispatch reads a fixed-width
/// prefix off `instruction.data`, so a width outside this set parses fine here
/// and then fails at indexer start, far from the IDL that caused it. The
/// config validator and the router read the same list, since a width one of
/// the three admits and another does not is a registration nothing can match.
pub(crate) const DISPATCHABLE_DISCRIMINATOR_LENS: [usize; 4] = [1, 2, 4, 8];

/// "1, 2, 4, or 8", for a message that would otherwise spell out by hand the
/// list it is reporting against.
pub(crate) fn describe_dispatchable_lens() -> String {
    let (last, rest) = DISPATCHABLE_DISCRIMINATOR_LENS
        .split_last()
        .expect("non-empty");
    let rest = rest
        .iter()
        .map(usize::to_string)
        .collect::<Vec<_>>()
        .join(", ");
    format!("{rest}, or {last}")
}

pub fn parse_idl(json: &str, program_name: &str) -> Result<ProgramIdl> {
    parse_and_validate(json).with_context(|| format!("parsing IDL for program '{program_name}'"))
}

impl ProgramIdl {
    /// A program whose schema is compiled in rather than read from a file. It
    /// goes through the same checks, so a bundled schema cannot carry a
    /// collision or a discriminator width the router never probes for.
    pub fn compiled_in(
        address: String,
        instructions: BTreeMap<String, IxIdl>,
        defined_types: BTreeMap<String, FieldType>,
    ) -> Self {
        let mut idl = ProgramIdl {
            address: Some(address),
            instructions,
            defined_types,
            ..Default::default()
        };
        validate(&mut idl);
        idl
    }

    /// The instruction dispatched by these bytes, for a config that names an
    /// instruction differently from the IDL.
    pub fn dispatched_by(&self, discriminator: &[u8]) -> Option<&IxIdl> {
        self.instructions
            .values()
            .find(|ix| ix.discriminator == discriminator)
    }
}

fn parse_and_validate(json: &str) -> Result<ProgramIdl> {
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

fn validate(idl: &mut ProgramIdl) {
    let mut demoted = Unusable::new();
    for (name, ix) in &idl.instructions {
        let len = ix.discriminator.len();
        if !DISPATCHABLE_DISCRIMINATOR_LENS.contains(&len) {
            demoted.insert(
                name.clone(),
                format!(
                    "its discriminator is {len} bytes, and dispatch matches only {}",
                    describe_dispatchable_lens()
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

    // `unresolvable_types` has already settled every name, so an instruction
    // only has to be checked against its own arguments' references.
    let bad_types = unresolvable_types(idl);
    for (name, ix) in &idl.instructions {
        if demoted.contains_key(name) {
            continue;
        }
        let mut references = BTreeSet::new();
        for arg in &ix.args {
            collect_defined_names(&arg.ty, &mut references);
        }
        if let Some(reason) = references
            .iter()
            .find_map(|r| unresolved_reason(idl, &bad_types, r))
        {
            demoted.insert(name.clone(), reason);
        }
    }

    // Codegen hands `defined_types` to the runtime's type registry whole, so a
    // type that cannot be resolved must not be in it — even when no
    // instruction reaches it.
    for name in bad_types.keys() {
        idl.defined_types.remove(name);
    }
    idl.unusable_types = bad_types;
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
fn prefix_collisions(mut by_bytes: Vec<(&[u8], &str)>) -> Unusable {
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

/// Little-endian bytes of a discriminant at the width its type declares.
/// Solana encodes multi-byte discriminators little-endian, same as Borsh, and
/// a signed format is two's-complement at its own width — so the range check
/// belongs to the format rather than being "does it fit in u64".
fn le_bytes(ty: &FieldType, value: i128) -> Result<Vec<u8>> {
    let (width, min, max): (usize, i128, i128) = match ty {
        FieldType::U8 => (1, 0, u8::MAX as i128),
        FieldType::U16 => (2, 0, u16::MAX as i128),
        FieldType::U32 => (4, 0, u32::MAX as i128),
        FieldType::U64 => (8, 0, u64::MAX as i128),
        FieldType::I8 => (1, i8::MIN as i128, i8::MAX as i128),
        FieldType::I16 => (2, i16::MIN as i128, i16::MAX as i128),
        FieldType::I32 => (4, i32::MIN as i128, i32::MAX as i128),
        FieldType::I64 => (8, i64::MIN as i128, i64::MAX as i128),
        other => bail!("a discriminator is a whole number, and this one is typed {other:?}"),
    };
    if value < min || value > max {
        bail!(
            "discriminator value {value} does not fit in {}",
            render_integer(ty)
        );
    }
    Ok(value.to_le_bytes()[..width].to_vec())
}

/// The IDL spelling of an integer type, for a message naming what the file
/// declared rather than the runtime's own type.
fn render_integer(ty: &FieldType) -> String {
    format!("{ty:?}").to_lowercase()
}

/// The encoded width of a type, when it has one. `None` for anything whose
/// width the bytes themselves decide — a vec's length, an option's tag, an
/// enum's variant — none of which can sit under a fixed-width prefix.
fn encoded_width(ty: &FieldType) -> Option<usize> {
    Some(match ty {
        FieldType::Bool | FieldType::U8 | FieldType::I8 => 1,
        FieldType::U16 | FieldType::I16 => 2,
        FieldType::U32 | FieldType::I32 | FieldType::F32 => 4,
        FieldType::U64 | FieldType::I64 | FieldType::F64 => 8,
        FieldType::U128 | FieldType::I128 => 16,
        FieldType::Pubkey => 32,
        FieldType::Array { ty, len } => encoded_width(ty)?.checked_mul(*len)?,
        FieldType::Struct(fields) => fields
            .iter()
            .try_fold(0usize, |sum, f| sum.checked_add(encoded_width(&f.ty)?))?,
        _ => return None,
    })
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

/// Every type the runtime cannot decode, the ones the parsers already set aside
/// included, each with the reason it is out.
fn unresolvable_types(idl: &ProgramIdl) -> Unusable {
    let mut bad = idl.unusable_types.clone();
    // `unbounded_recursion` reads the type graph alone, so one memo serves
    // every type: a subtree proven to terminate stays proven.
    let mut terminates = HashSet::new();
    let mut referenced_by: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    for (name, ty) in &idl.defined_types {
        if bad.contains_key(name) {
            continue;
        }
        let mut references = BTreeSet::new();
        collect_defined_names(ty, &mut references);
        let reason = unbounded_recursion(ty, idl, &mut vec![name], false, &mut terminates, 0)
            .err()
            .map(|stop| stop.reason(name))
            .or_else(|| {
                references
                    .iter()
                    .find_map(|r| unresolved_reason(idl, &bad, r))
            });
        match reason {
            Some(reason) => {
                bad.insert(name.clone(), reason);
            }
            None => {
                for reference in references {
                    referenced_by.entry(reference).or_default().push(name);
                }
            }
        }
    }

    // Badness only travels from a type to the ones naming it, so each type is
    // revisited exactly when one of its references turns bad.
    let mut queue: Vec<String> = bad.keys().cloned().collect();
    while let Some(broken) = queue.pop() {
        let Some(referrers) = referenced_by.get(broken.as_str()) else {
            continue;
        };
        for referrer in referrers {
            if bad.contains_key(*referrer) {
                continue;
            }
            let reason = format!(
                "it reaches type '{broken}', which cannot be decoded: {}",
                bad[broken.as_str()]
            );
            bad.insert(referrer.to_string(), reason);
            queue.push(referrer.to_string());
        }
    }
    bad
}

fn unresolved_reason(idl: &ProgramIdl, bad: &Unusable, name: &str) -> Option<String> {
    if let Some(reason) = bad.get(name) {
        Some(format!(
            "it reaches type '{name}', which cannot be decoded: {reason}"
        ))
    } else if !idl.defined_types.contains_key(name) {
        Some(format!("it references undefined type '{name}'"))
    } else {
        None
    }
}

fn collect_defined_names<'a>(ty: &'a FieldType, out: &mut BTreeSet<&'a str>) {
    match ty {
        FieldType::Defined(name) => {
            out.insert(name);
        }
        FieldType::Option(inner) | FieldType::Vec(inner) | FieldType::Array { ty: inner, .. } => {
            collect_defined_names(inner, out)
        }
        FieldType::Struct(fields) => fields
            .iter()
            .for_each(|f| collect_defined_names(&f.ty, out)),
        FieldType::Enum(variants) => variants
            .iter()
            .flat_map(|v| v.fields.iter().flatten())
            .for_each(|f| collect_defined_names(&f.ty, out)),
        _ => {}
    }
}

/// Levels the reference walk will descend. Every level is a live stack frame
/// here and another in the runtime's `decode_field`, and a file decides the
/// depth: a chain of defined types is as long as the file's `types` array,
/// while each node in it stays shallow enough that serde's own nesting limit
/// never sees it. Far below what either stack can afford, far above the
/// handful of levels a real program's types nest.
///
/// A type this far down is refused rather than walked, and near the limit that
/// verdict depends on what else the file declares: another type reaching the
/// same chain lower down leaves its tail proven in `terminates`, and the walk
/// then reaches the end within the budget. Both answers are safe — one
/// decodes, the other declines to — and no real IDL comes close to the limit.
const MAX_REFERENCE_DEPTH: usize = 256;

/// Why the walk stopped. Reported against the type the walk started from,
/// which is not always the one at fault: a type that merely names a cyclic one
/// is not itself recursive, and blaming it would send the reader to the wrong
/// declaration.
enum WalkStop {
    /// The type that closes the cycle.
    Cycle(String),
    TooDeep,
}

impl WalkStop {
    fn reason(self, walked_from: &str) -> String {
        let cycles = "recursively contains itself without an option or vec to terminate decoding";
        match self {
            WalkStop::Cycle(name) if name == walked_from => format!("it {cycles}"),
            WalkStop::Cycle(name) => {
                format!("it reaches type '{name}', which cannot be decoded: it {cycles}")
            }
            WalkStop::TooDeep => format!(
                "its references are nested too deeply to decode: the walk stops after \
                 {MAX_REFERENCE_DEPTH} levels"
            ),
        }
    }
}

/// `Option`/`Vec` carry a tag or length, so a type may name itself behind
/// them. A `Defined` cycle with no such terminator would recurse in
/// `decode_field` until the stack overflows.
/// `depth` counts every level, not just the named ones: nesting inside a type
/// costs a frame as surely as a link to the next type does.
fn unbounded_recursion<'a>(
    ty: &'a FieldType,
    idl: &'a ProgramIdl,
    stack: &mut Vec<&'a str>,
    through_var_len: bool,
    terminates: &mut HashSet<&'a str>,
    depth: usize,
) -> Result<(), WalkStop> {
    if depth > MAX_REFERENCE_DEPTH {
        return Err(WalkStop::TooDeep);
    }
    let deeper = depth + 1;
    match ty {
        FieldType::Defined(name) => {
            let name = name.as_str();
            if stack.contains(&name) {
                if through_var_len {
                    Ok(())
                } else {
                    Err(WalkStop::Cycle(name.to_string()))
                }
            // Only a strict proof is memoized, and it answers both modes: a
            // subtree that terminates with nothing helping it terminates behind
            // a var-len edge too.
            } else if terminates.contains(&name) {
                Ok(())
            } else if let Some(inner) = idl.defined_types.get(name) {
                stack.push(name);
                let result =
                    unbounded_recursion(inner, idl, stack, through_var_len, terminates, deeper);
                stack.pop();
                if result.is_ok() && !through_var_len {
                    terminates.insert(name);
                }
                result
            } else {
                Ok(())
            }
        }
        FieldType::Option(inner) | FieldType::Vec(inner) => {
            unbounded_recursion(inner, idl, stack, true, terminates, deeper)
        }
        FieldType::Array { ty: inner, .. } => {
            unbounded_recursion(inner, idl, stack, through_var_len, terminates, deeper)
        }
        FieldType::Struct(fields) => fields.iter().try_for_each(|f| {
            unbounded_recursion(&f.ty, idl, stack, through_var_len, terminates, deeper)
        }),
        FieldType::Enum(variants) => variants
            .iter()
            .flat_map(|v| v.fields.iter().flatten())
            .try_for_each(|f| {
                unbounded_recursion(&f.ty, idl, stack, through_var_len, terminates, deeper)
            }),
        _ => Ok(()),
    }
}

/// What an instruction dispatches on, before its body has been read.
struct Dispatch {
    bytes: Vec<u8>,
    derived: bool,
}

/// The instructions of one program: the ones that can be indexed, the reasons
/// for the ones that cannot, and the bytes of those whose layout failed after
/// their discriminator was read — kept so a collision can still name them.
fn collect_instructions(
    entries: &[Value],
    mut dispatch_of: impl FnMut(&str, &Value) -> Result<Dispatch>,
    mut layout_of: impl FnMut(&Value, &Dispatch) -> Result<(Vec<IdlAccount>, Vec<NamedField>)>,
) -> Result<ProgramIdl> {
    let mut idl = ProgramIdl::default();
    for entry in entries {
        let name = required_str(entry, "name")
            .context("instructions[].name")?
            .to_string();
        if idl.instructions.contains_key(&name) || idl.unusable.contains_key(&name) {
            bail!("IDL declares instruction '{name}' more than once");
        }
        let dispatch = match dispatch_of(&name, entry) {
            Ok(dispatch) => dispatch,
            Err(e) => {
                idl.unusable.insert(name, format!("{e:#}"));
                continue;
            }
        };
        // Colliding flattened names are this instruction's defect, like any
        // other layout defect: the rest of the program stays indexable.
        let parsed = layout_of(entry, &dispatch).and_then(|(accounts, args)| {
            reject_duplicate_account_names(&accounts).map(|()| (accounts, args))
        });
        match parsed {
            Ok((accounts, args)) => {
                idl.instructions.insert(
                    name,
                    IxIdl {
                        discriminator: dispatch.bytes,
                        derived: dispatch.derived,
                        accounts,
                        args,
                    },
                );
            }
            Err(e) => {
                idl.unusable.insert(name.clone(), format!("{e:#}"));
                if !dispatch.bytes.is_empty() {
                    idl.declared_discriminators.insert(name, dispatch.bytes);
                }
            }
        }
    }
    Ok(idl)
}

/// The `types` / `definedTypes` block: every declared type by name, plus the
/// reasons for the ones that could not be read. Which key holds them and how a
/// type node is read is the dialect's business; that a type without a `type` is
/// that type's defect rather than the file's is not.
fn parse_defined_types(
    node: Option<&Value>,
    key: &str,
    mut parse_one: impl FnMut(&str, &Value) -> Result<FieldType>,
) -> Result<(BTreeMap<String, FieldType>, Unusable)> {
    let mut out = BTreeMap::new();
    let mut unusable = Unusable::new();
    for entry in declared_array(node).with_context(|| key.to_string())? {
        let name = required_str(entry, "name")
            .with_context(|| format!("{key}[].name"))?
            .to_string();
        if out.contains_key(&name) || unusable.contains_key(&name) {
            bail!("IDL declares type '{name}' more than once");
        }
        let parsed = entry
            .get("type")
            .ok_or_else(|| anyhow!("type '{name}' has no 'type'"))
            .and_then(|node| parse_one(&name, node));
        match parsed {
            Ok(ty) => {
                out.insert(name, ty);
            }
            Err(e) => {
                unusable.insert(name, format!("{e:#}"));
            }
        }
    }
    Ok((out, unusable))
}

/// A declared list of nodes. Absent means the file declares none; present but
/// not an array is a defect, not an empty list — read as empty, whatever it
/// held disappears silently, and what disappears is a slot whose name every
/// later account inherits, or a field the decoder then reads past.
fn declared_array(node: Option<&Value>) -> Result<&[Value]> {
    match node {
        None => Ok(&[]),
        Some(node) => node
            .as_array()
            .map(Vec::as_slice)
            .ok_or_else(|| anyhow!("expected an array, got {node}")),
    }
}

/// One account slot. The dialects spell the optional flag differently — Anchor
/// 0.30 `optional`, legacy Anchor and Codama `isOptional` — so both are read,
/// and every spelling the node declares has to agree and be readable. Settling
/// this quietly, by defaulting a non-boolean to `false` or by letting one
/// spelling outrank the other, makes the slot required on a guess, and a
/// transaction that omits it pairs every later pubkey with the wrong name.
fn account_slot(node: &Value) -> Result<IdlAccount> {
    Ok(IdlAccount {
        name: required_str(node, "name")?.to_string(),
        optional: declared_optional(node)?,
    })
}

/// Reads both spellings of the optional flag off an account node or a group of
/// them. See `account_slot` for why neither is allowed to be settled quietly.
fn declared_optional(node: &Value) -> Result<bool> {
    let mut optional = None;
    for key in ["optional", "isOptional"] {
        let declared = match node.get(key) {
            None => continue,
            Some(Value::Bool(declared)) => *declared,
            Some(other) => bail!("'{key}' must be a boolean, got {other}"),
        };
        if optional.is_some_and(|earlier| earlier != declared) {
            bail!(
                "'optional' and 'isOptional' disagree on account '{}'",
                required_str(node, "name")?
            );
        }
        optional = Some(declared);
    }
    Ok(optional.unwrap_or(false))
}

fn reject_duplicate_account_names(accounts: &[IdlAccount]) -> Result<()> {
    let mut seen = HashSet::new();
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
