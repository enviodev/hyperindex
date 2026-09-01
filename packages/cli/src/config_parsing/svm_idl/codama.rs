//! Codama describes the non-Anchor programs, which is why it is worth a second
//! parser: an instruction's discriminator can be a plain constant, or a regular
//! argument singled out by name, or several such fields packed together — none
//! of which Anchor's fixed 8-byte prefix can express.
//!
//! It also describes the data differently — see `parse_arguments`.

use std::collections::HashSet;

use anyhow::{anyhow, bail, Context, Result};
use hypersync_client_solana::decode::{EnumVariant, FieldType, NamedField};
use serde_json::{Map, Value};

use super::{
    account_slot, collect_instructions, declared_array, le_bytes, parse_defined_types,
    required_str, Dispatch, IdlAccount, ProgramIdl,
};

pub(super) fn parse(root: &Map<String, Value>) -> Result<ProgramIdl> {
    let program = codama_program(root)?;
    let (defined_types, unusable_types) =
        parse_defined_types(program.get("definedTypes"), "definedTypes", |name, node| {
            parse_type(node, &format!("definedTypes.{name}"))
        })?;
    Ok(ProgramIdl {
        address: program
            .get("publicKey")
            .and_then(Value::as_str)
            .map(str::to_string),
        defined_types,
        unusable_types,
        ..parse_instructions(program)?
    })
}

fn codama_program(root: &Map<String, Value>) -> Result<&Map<String, Value>> {
    if root.get("kind").and_then(Value::as_str) == Some("programNode") {
        return Ok(root);
    }
    let root = match root.get("rootNode").and_then(Value::as_object) {
        Some(nested) => nested,
        None => root,
    };
    root.get("program")
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow!("Codama root node has no 'program'"))
}

fn parse_instructions(program: &Map<String, Value>) -> Result<ProgramIdl> {
    let arr = program
        .get("instructions")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("Codama program has no 'instructions' array"))?;
    collect_instructions(
        arr,
        |_name, ix| {
            let (bytes, _) = parse_discriminators(ix).context("discriminators")?;
            Ok(Dispatch {
                bytes,
                derived: false,
            })
        },
        |ix, dispatch| {
            let accounts = parse_accounts(ix.get("accounts")).context("accounts")?;
            reject_ambiguous_optional_accounts(ix, &accounts)?;
            // Re-read rather than carried through: two nodes at most, and the
            // alternative is a value threaded across both closures for the one
            // dialect that has anything to thread.
            let (_, named) = parse_discriminators(ix).context("discriminators")?;
            let args = parse_arguments(ix.get("arguments"), dispatch.bytes.len(), &named)?;
            Ok((accounts, args))
        },
    )
}

/// One discriminator part that names an argument, and the byte offset it
/// claims — checked against where that argument actually starts.
type NamedPart = (u64, String);

/// The instruction's discriminator bytes, plus the parts that named an
/// argument rather than spelling a constant.
fn parse_discriminators(ix: &Value) -> Result<(Vec<u8>, Vec<NamedPart>)> {
    let arr = declared_array(ix.get("discriminators"))?;
    // Packed discriminators are declared in any order but encode at their
    // offsets, so byte order follows `offset`, not declaration order.
    let mut parts: Vec<(u64, Vec<u8>, Option<String>)> = Vec::with_capacity(arr.len());
    for d in arr.iter() {
        let kind = required_str(d, "kind")?;
        // Absent means Codama's default of 0. Present but unreadable is not:
        // coerced to 0 it would tile from the head of the data and pass the
        // contiguity check below carrying a prefix encoded somewhere else.
        let offset = match d.get("offset") {
            None => 0,
            Some(offset) => offset
                .as_u64()
                .ok_or_else(|| anyhow!("expected a non-negative integer 'offset', got {offset}"))?,
        };
        match kind {
            "constantDiscriminatorNode" | "byteDiscriminatorNode" => {
                let constant = d
                    .get("constant")
                    .ok_or_else(|| anyhow!("{kind} has no 'constant'"))?;
                parts.push((offset, constant_bytes(constant)?, None));
            }
            "fieldDiscriminatorNode" => {
                let field = required_str(d, "name")?.to_string();
                let argument = ix
                    .get("arguments")
                    .and_then(Value::as_array)
                    .and_then(|args| {
                        args.iter()
                            .find(|a| a.get("name").and_then(Value::as_str) == Some(&field))
                    })
                    .ok_or_else(|| {
                        anyhow!("field discriminator names unknown argument '{field}'")
                    })?;
                let default = argument.get("defaultValue").ok_or_else(|| {
                    anyhow!("argument '{field}' is a discriminator but has no 'defaultValue'")
                })?;
                let ty = argument
                    .get("type")
                    .ok_or_else(|| anyhow!("argument '{field}' has no 'type'"))?;
                parts.push((offset, number_bytes(default, ty)?, Some(field)));
            }
            // Dropping it quietly would leave two instructions the IDL does
            // tell apart looking like a plain collision, and the reason the
            // user reads would name a prefix they never wrote.
            "sizeDiscriminatorNode" => bail!(
                "dispatch matches a fixed-width prefix of the data, not its length, so a \
                 sizeDiscriminatorNode cannot be honoured"
            ),
            other => bail!("unsupported discriminator kind '{other}'"),
        }
    }
    // Dispatch matches one contiguous prefix off the head of the data, so the
    // parts have to tile from offset 0 with no gap and no overlap. Anything
    // else would concatenate into a prefix that is not what the program
    // actually encodes.
    parts.sort_by_key(|(offset, _, _)| *offset);
    let mut bytes: Vec<u8> = Vec::new();
    let mut named = Vec::new();
    for (offset, part, field) in parts {
        if offset != bytes.len() as u64 {
            bail!(
                "discriminator part at offset {offset} does not follow the previous part, which \
                 ends at {}; dispatch needs one contiguous prefix from offset 0",
                bytes.len()
            );
        }
        // A part contributing nothing has no offset to be at, and sorting it
        // against a real one would decide the outcome by declaration order.
        if part.is_empty() {
            bail!("discriminator part at offset {offset} contributes no bytes");
        }
        if let Some(field) = field {
            named.push((offset, field));
        }
        bytes.extend(part);
    }
    Ok((bytes, named))
}

fn constant_bytes(constant: &Value) -> Result<Vec<u8>> {
    let value = constant
        .get("value")
        .ok_or_else(|| anyhow!("constant value node has no 'value'"))?;
    match required_str(value, "kind")? {
        "bytesValueNode" => {
            let data = required_str(value, "data")?;
            match value.get("encoding").and_then(Value::as_str) {
                Some("base16") | None => {
                    crate::hex::decode_optionally_prefixed(data, "discriminator constant")
                }
                Some("base58") => bs58::decode(data)
                    .into_vec()
                    .with_context(|| format!("decoding base58 constant '{data}'")),
                Some(other) => bail!("unsupported constant encoding '{other}'"),
            }
        }
        "numberValueNode" => {
            let ty = constant
                .get("type")
                .ok_or_else(|| anyhow!("constant value node has no 'type'"))?;
            number_bytes(value, ty)
        }
        other => bail!("unsupported constant value kind '{other}'"),
    }
}

/// Little-endian encoding of a `numberValueNode` at the width its type node
/// declares. The type goes through `parse_type`, so a node dressed as a number
/// but carrying a layout key the runtime cannot honour is refused here rather
/// than silently encoding at the width its `format` advertises.
fn number_bytes(value: &Value, ty: &Value) -> Result<Vec<u8>> {
    // Widened to i128 so the top half of the u64 range stays representable
    // alongside negative signed values.
    let number = value
        .get("number")
        .and_then(|n| {
            n.as_i64()
                .map(i128::from)
                .or_else(|| n.as_u64().map(i128::from))
        })
        .ok_or_else(|| anyhow!("expected an integer 'number', got {value}"))?;
    le_bytes(&parse_type(ty, "discriminator")?, number)
}

fn parse_accounts(node: Option<&Value>) -> Result<Vec<IdlAccount>> {
    declared_array(node)?.iter().map(account_slot).collect()
}

/// `optionalAccountStrategy` decides what an absent optional account leaves
/// behind. Codama's default fills the slot with the program id, so every later
/// account keeps its declared position. Under `omitted` there is no slot, and a
/// non-trailing optional shifts everything after it — this parser pairs names
/// to accounts by position, as the runtime does, so it has no way to say which
/// name such a slot carries.
fn reject_ambiguous_optional_accounts(ix: &Value, accounts: &[IdlAccount]) -> Result<()> {
    match ix.get("optionalAccountStrategy") {
        None => return Ok(()),
        Some(strategy) => match strategy.as_str() {
            Some("programId") => return Ok(()),
            Some("omitted") => {}
            _ => bail!("unsupported optionalAccountStrategy {strategy}"),
        },
    }
    if let Some(account) = super::optional_before_a_required_slot(accounts) {
        bail!(
            "account '{}' is optional and left out entirely when absent, so every account after \
             it shifts and this parser cannot tell which name a slot carries",
            account.name
        );
    }
    Ok(())
}

/// The instruction's body: the arguments left once the discriminator prefix has
/// been accounted for.
///
/// Codama builds an instruction's data out of its arguments alone and treats
/// every discriminator — a literal constant no differently from a named field —
/// as a match against those same bytes at an offset. Dispatch here works the
/// other way round: it reads a prefix and the runtime decodes the body after it.
/// So the arguments the prefix covers are already spent, and decoding them again
/// would read every later field one argument too early.
fn parse_arguments(
    node: Option<&Value>,
    prefix_len: usize,
    named_parts: &[NamedPart],
) -> Result<Vec<NamedField>> {
    let arr = declared_array(node).context("arguments")?;
    reject_duplicate_argument_names(arr)?;
    let covered = arguments_under_prefix(arr, prefix_len)?;
    reject_misplaced_named_parts(&covered, named_parts)?;

    arr.iter()
        .skip(covered.len())
        .map(|a| {
            let (name, ty) = argument_field(a)?;
            Ok(NamedField {
                name: name.to_string(),
                ty,
            })
        })
        .collect()
}

/// An argument's name and the type it encodes. Every key on the node is
/// modelled or the argument is refused, since one that is not could be
/// deciding the layout.
fn argument_field(a: &Value) -> Result<(&str, FieldType)> {
    let name = required_str(a, "name").context("arguments")?;
    let path = format!("args.{name}");
    reject_unmodelled_keys(a, &path, &FIELD_KEYS)?;
    let ty = a
        .get("type")
        .ok_or_else(|| anyhow!("{path}: argument has no 'type'"))?;
    Ok((name, parse_type(ty, &path)?))
}

/// Names are matched by position from here on, so two arguments sharing one
/// would leave which of them the discriminator covered undecidable.
fn reject_duplicate_argument_names(arr: &[Value]) -> Result<()> {
    let mut seen = HashSet::new();
    for a in arr {
        let name = required_str(a, "name").context("arguments")?;
        if !seen.insert(name) {
            bail!("IDL declares argument '{name}' more than once");
        }
    }
    Ok(())
}

/// The leading arguments whose bytes the discriminator covers, each with the
/// offset it starts at. They are spent: the runtime starts the body after the
/// prefix, so decoding them again reads every later field one argument early.
fn arguments_under_prefix(arr: &[Value], prefix_len: usize) -> Result<Vec<(usize, &str)>> {
    let mut covered = Vec::new();
    let mut offset = 0usize;
    for a in arr {
        if offset >= prefix_len {
            break;
        }
        let (name, ty) = argument_field(a)?;
        let width = super::encoded_width(&ty).ok_or_else(|| {
            anyhow!(
                "argument '{name}' is under the {prefix_len}-byte discriminator, and its width is \
                 not fixed, so where the body starts cannot be told"
            )
        })?;
        // A count comes off the file, so the running total is checked rather
        // than trusted: it reaches the end of the prefix or it stops here.
        let end = offset
            .checked_add(width)
            .filter(|end| *end <= prefix_len)
            .ok_or_else(|| {
                anyhow!(
                    "the {prefix_len}-byte discriminator stops inside argument '{name}', which \
                     starts at byte {offset} and is {width} bytes wide"
                )
            })?;
        covered.push((offset, name));
        offset = end;
    }
    // The discriminator matches bytes the arguments encode, so where there are
    // arguments it has to land on exactly those: short of that the file
    // describes a layout this reading does not fit, and the rest of the
    // arguments would decode from the wrong offset. An instruction declaring
    // none is the one case with nothing to get wrong — no argument can be
    // mistaken for the prefix, and the body is empty either way.
    if offset != prefix_len && !arr.is_empty() {
        bail!(
            "the discriminator is {prefix_len} bytes, and the arguments account for {offset} of \
             them; its bytes are part of the instruction's data, not a prefix in front of it"
        );
    }
    Ok(covered)
}

/// An argument a field discriminator names has to be the one the offsets put
/// there. Otherwise the offsets and the declaration order disagree, and where
/// the body starts is a guess.
fn reject_misplaced_named_parts(
    covered: &[(usize, &str)],
    named_parts: &[NamedPart],
) -> Result<()> {
    for (offset, field) in named_parts {
        let offset = *offset as usize;
        if !covered.contains(&(offset, field.as_str())) {
            let found = covered
                .iter()
                .find(|(at, _)| *at == offset)
                .map(|(_, name)| *name);
            bail!(
                "the discriminator reads argument '{field}' at byte {offset}, where the arguments \
                 put {}",
                found.map_or("nothing".to_string(), |name| format!("'{name}'"))
            );
        }
    }
    Ok(())
}

/// Keys any node may carry without changing a single decoded byte. `display`
/// is Codama's presentation layer (a `u64` annotated as a SOL amount, say):
/// it describes how to show a value, never how to read it.
const DESCRIPTIVE_KEYS: [&str; 3] = ["kind", "docs", "display"];

/// Within a type node nothing is ignored. Codama attaches layout modifiers
/// (`endian`, `fixed`, `size`, `encoding`) to shapes that are otherwise
/// recognisable, and one the runtime cannot express shifts every byte decoded
/// after it, so each arm lists the keys it models and refuses the rest.
///
/// Account and discriminator nodes are deliberately not held to this. They
/// carry keys deciding which pubkey fills which slot — `remainingAccounts`,
/// per-account `defaultValue` — which this parser does not model: it pairs
/// names to accounts by position, as the runtime does. SPL Token declares
/// those keys on nearly every instruction, so refusing them would cost the
/// whole program to describe something no name lookup here depends on. The one
/// that can move a slot, `optionalAccountStrategy`, is read separately by
/// `reject_ambiguous_optional_accounts`.
fn reject_unmodelled_keys(node: &Value, path: &str, modelled: &[&str]) -> Result<()> {
    let Some(obj) = node.as_object() else {
        return Ok(());
    };
    let kind = node.get("kind").and_then(Value::as_str).unwrap_or("node");
    for key in obj.keys() {
        if DESCRIPTIVE_KEYS.contains(&key.as_str()) || modelled.contains(&key.as_str()) {
            continue;
        }
        bail!(
            "{path}: {kind} carries '{key}', which this parser does not model; decoding it would \
             be a guess at the byte layout. Removing the key from a local copy of the IDL is the \
             way through if it does not affect the layout"
        );
    }
    Ok(())
}

/// Keys a named field or instruction argument may carry. The two default
/// keys shape the client-side API, not the encoded bytes.
const FIELD_KEYS: [&str; 4] = ["name", "type", "defaultValue", "defaultValueStrategy"];

/// Borsh is little-endian throughout, and `le` is Codama's default — but a
/// node may say otherwise, and the runtime has no way to honour it.
fn require_little_endian(node: &Value, path: &str) -> Result<()> {
    match node.get("endian").and_then(Value::as_str) {
        None | Some("le") => Ok(()),
        Some(other) => bail!("{path}: Borsh decodes numbers little-endian, got '{other}'"),
    }
}

/// A node's integer-width sub-node (an enum's tag, a boolean's storage), which
/// Borsh fixes at one byte regardless of what the IDL asks for. Absent means
/// Codama's default, which is the width Borsh wants.
fn require_number_width(node: &Value, key: &str, expected: &str, path: &str) -> Result<()> {
    let Some(inner) = node.get(key) else {
        return Ok(());
    };
    let path = format!("{path}.{key}");
    check_number_node(inner, expected, &path)
}

/// A `numberTypeNode` used as framing rather than as a value: an enum tag, a
/// boolean's storage, a length prefix. Held to the same rules as any other
/// number, since a wrong width or endianness here shifts everything after it.
fn check_number_node(node: &Value, expected: &str, path: &str) -> Result<()> {
    let kind = required_str(node, "kind").with_context(|| path.to_string())?;
    if kind != "numberTypeNode" {
        bail!("{path}: expected a numberTypeNode, got {kind}");
    }
    reject_unmodelled_keys(node, path, &["format", "endian"])?;
    let format = required_str(node, "format").with_context(|| path.to_string())?;
    if format != expected {
        bail!("{path}: Borsh needs {expected} here, got {format}");
    }
    require_little_endian(node, path)
}

fn parse_type(node: &Value, path: &str) -> Result<FieldType> {
    let kind = required_str(node, "kind").with_context(|| path.to_string())?;
    match kind {
        "numberTypeNode" => {
            reject_unmodelled_keys(node, path, &["format", "endian"])?;
            require_little_endian(node, path)?;
            let format = required_str(node, "format").with_context(|| path.to_string())?;
            super::numeric_field_type(format)
                .ok_or_else(|| anyhow!("{path}: unsupported number format '{format}'"))
        }
        "booleanTypeNode" => {
            reject_unmodelled_keys(node, path, &["size"])?;
            require_number_width(node, "size", "u8", path)?;
            Ok(FieldType::Bool)
        }
        // Borsh has no unframed string or byte run: both carry a u32 length,
        // which Codama spells as a `sizePrefixTypeNode` wrapper. A bare node
        // is remainder-encoded, so decoding it as framed would consume four
        // bytes of content as a length.
        "stringTypeNode" | "bytesTypeNode" => bail!(
            "{path}: a bare {kind} carries no length; Borsh needs it wrapped in a \
             sizePrefixTypeNode with a u32 prefix"
        ),
        "publicKeyTypeNode" => {
            reject_unmodelled_keys(node, path, &[])?;
            Ok(FieldType::Pubkey)
        }
        // A link carrying a `program` names a type another program declares.
        // Resolution here is against the registry of the program being parsed,
        // where the same name is a different type — and decoding against it
        // would be right only by coincidence.
        "definedTypeLinkNode" => {
            reject_unmodelled_keys(node, path, &["name", "program"])?;
            let name = required_str(node, "name").with_context(|| path.to_string())?;
            if let Some(program) = node.get("program") {
                let program = program
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("another program");
                bail!(
                    "{path}: '{name}' is defined by program '{program}', and this parser resolves \
                     type links against the program it is parsing, where the name means something \
                     else"
                );
            }
            Ok(FieldType::Defined(name.to_string()))
        }
        // Borsh tags an option with one byte, which is Codama's default
        // prefix. A wider prefix decodes at the wrong offset.
        "optionTypeNode" => {
            reject_unmodelled_keys(node, path, &["item", "prefix", "fixed"])?;
            require_prefix(node, "u8", path)?;
            // A fixed option always occupies prefix + item bytes, zero-padding
            // the body when absent; Borsh writes the tag on its own.
            if node.get("fixed").and_then(Value::as_bool) == Some(true) {
                bail!(
                    "{path}: a fixed option pads its body when absent, which Borsh does not encode"
                );
            }
            Ok(FieldType::Option(Box::new(parse_type(
                item(node, path)?,
                &format!("{path}.item"),
            )?)))
        }
        // A zeroable option carries no tag at all — presence is encoded by the
        // value being non-zero. There is no Borsh shape for that, and reading
        // it as a tagged option would consume a byte that isn't there.
        "zeroableOptionTypeNode" => {
            bail!("{path}: zeroable options are not Borsh-compatible and cannot be decoded")
        }
        "arrayTypeNode" => {
            reject_unmodelled_keys(node, path, &["item", "count"])?;
            let item = parse_type(item(node, path)?, &format!("{path}.item"))?;
            let count = node
                .get("count")
                .ok_or_else(|| anyhow!("{path}: array has no 'count'"))?;
            match required_str(count, "kind")? {
                "fixedCountNode" => {
                    reject_unmodelled_keys(count, path, &["value"])?;
                    let len = count
                        .get("value")
                        .and_then(Value::as_u64)
                        .ok_or_else(|| anyhow!("{path}: fixed count has no 'value'"))?;
                    Ok(FieldType::Array {
                        ty: Box::new(item),
                        len: len as usize,
                    })
                }
                // Borsh frames a vector with a u32 length prefix.
                "prefixedCountNode" => {
                    reject_unmodelled_keys(count, path, &["prefix"])?;
                    require_prefix(count, "u32", path)?;
                    Ok(FieldType::Vec(Box::new(item)))
                }
                other => bail!("{path}: unsupported array count kind '{other}'"),
            }
        }
        "structTypeNode" => {
            reject_unmodelled_keys(node, path, &["fields"])?;
            let fields = optional_array(node, "fields", path)?;
            Ok(FieldType::Struct(
                fields
                    .iter()
                    .map(|f| {
                        let name = required_str(f, "name").with_context(|| path.to_string())?;
                        reject_unmodelled_keys(f, path, &FIELD_KEYS)?;
                        Ok(NamedField {
                            name: name.to_string(),
                            ty: parse_type(
                                f.get("type")
                                    .ok_or_else(|| anyhow!("{path}.{name}: field has no 'type'"))?,
                                &format!("{path}.{name}"),
                            )?,
                        })
                    })
                    .collect::<Result<Vec<_>>>()?,
            ))
        }
        "tupleTypeNode" => {
            reject_unmodelled_keys(node, path, &["items"])?;
            Ok(FieldType::Struct(positional_fields(node, path)?))
        }
        "enumTypeNode" => {
            reject_unmodelled_keys(node, path, &["variants", "size"])?;
            require_number_width(node, "size", "u8", path)?;
            let variants = optional_array(node, "variants", path)?;
            Ok(FieldType::Enum(
                variants
                    .iter()
                    .map(|v| parse_enum_variant(v, path))
                    .collect::<Result<Vec<_>>>()?,
            ))
        }
        // A u32 size prefix is exactly how Borsh frames a string or a byte
        // vector. Every other prefix width, and every other framed shape,
        // shifts the byte layout in a way the runtime cannot express.
        "sizePrefixTypeNode" => {
            reject_unmodelled_keys(node, path, &["type", "prefix"])?;
            require_prefix(node, "u32", path)?;
            let inner = node
                .get("type")
                .ok_or_else(|| anyhow!("{path}: {kind} has no 'type'"))?;
            match required_str(inner, "kind").with_context(|| path.to_string())? {
                "stringTypeNode" => {
                    reject_unmodelled_keys(inner, path, &["encoding"])?;
                    match inner.get("encoding").and_then(Value::as_str) {
                        None | Some("utf8") => Ok(FieldType::String),
                        Some(other) => {
                            bail!("{path}: Borsh strings are utf8, got '{other}'")
                        }
                    }
                }
                "bytesTypeNode" => {
                    reject_unmodelled_keys(inner, path, &[])?;
                    Ok(FieldType::Bytes)
                }
                other => bail!(
                    "{path}: a u32 size prefix frames a string or bytes in Borsh, got {other}"
                ),
            }
        }
        other => bail!("{path}: unsupported type node '{other}'"),
    }
}

fn parse_enum_variant(v: &Value, enum_path: &str) -> Result<EnumVariant> {
    let name = required_str(v, "name").with_context(|| enum_path.to_string())?;
    let path = format!("{enum_path}.{name}");
    // Borsh numbers variants by position. A variant carrying its own
    // `discriminator` renumbers the set, so the runtime's positional index
    // would select the wrong body.
    reject_unmodelled_keys(v, &path, &["name", "struct", "tuple"])?;
    let fields = match required_str(v, "kind").with_context(|| path.clone())? {
        "enumEmptyVariantTypeNode" => None,
        "enumStructVariantTypeNode" => {
            let inner = v
                .get("struct")
                .ok_or_else(|| anyhow!("{path}: struct variant has no 'struct'"))?;
            match parse_type(inner, &path)? {
                FieldType::Struct(fields) => Some(fields),
                other => bail!("{path}: struct variant resolved to {other:?}"),
            }
        }
        "enumTupleVariantTypeNode" => {
            let inner = v
                .get("tuple")
                .ok_or_else(|| anyhow!("{path}: tuple variant has no 'tuple'"))?;
            // Through `parse_type` rather than straight to `positional_fields`:
            // Codama types this as a nested node, so the wrapper needs the same
            // key checks as any other type.
            match parse_type(inner, &path)? {
                FieldType::Struct(fields) => Some(fields),
                other => bail!("{path}: tuple variant resolved to {other:?}"),
            }
        }
        other => bail!("{path}: unsupported enum variant kind '{other}'"),
    };
    Ok(EnumVariant {
        name: name.to_string(),
        fields,
    })
}

/// Codama lets a node choose the integer width framing it; the Borsh runtime
/// has exactly one width per shape. An absent prefix means Codama's default,
/// which is what these shapes are checked against.
fn require_prefix(node: &Value, expected: &str, path: &str) -> Result<()> {
    match node.get("prefix") {
        None => Ok(()),
        Some(prefix) => check_number_node(prefix, expected, &format!("{path}.prefix")),
    }
}

fn item<'a>(node: &'a Value, path: &str) -> Result<&'a Value> {
    node.get("item")
        .ok_or_else(|| anyhow!("{path}: node has no 'item'"))
}

/// Codama drops `fields`/`items`/`variants` rather than writing an empty
/// array, so an absent key is a legitimate empty collection, not a defect.
fn optional_array<'a>(node: &'a Value, key: &str, path: &str) -> Result<&'a [Value]> {
    declared_array(node.get(key)).with_context(|| format!("{path}: '{key}'"))
}

/// Tuple items become `_0`, `_1`, … so every decoded body is keyed by name.
fn positional_fields(node: &Value, path: &str) -> Result<Vec<NamedField>> {
    let items = optional_array(node, "items", path)?;
    items
        .iter()
        .enumerate()
        .map(|(i, item)| {
            Ok(NamedField {
                name: format!("_{i}"),
                ty: parse_type(item, &format!("{path}[{i}]"))?,
            })
        })
        .collect()
}
