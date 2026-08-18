//! Codama IDL parsing.
//!
//! Codama describes non-Anchor programs, which is why it is worth a second
//! parser: an instruction's discriminator can be a plain constant, or a
//! regular argument singled out by name, or several such fields packed
//! together — none of which Anchor's fixed 8-byte prefix can express.

use std::collections::BTreeMap;

use anyhow::{anyhow, bail, Context, Result};
use hypersync_client_solana::decode::{EnumVariant, FieldType, NamedField};
use serde_json::{Map, Value};

use super::{required_str, IdlAccount, IxIdl, ProgramIdl};

pub(super) fn parse(root: &Map<String, Value>) -> Result<ProgramIdl> {
    // A `.codama` file wraps the root node; a serialized `RootNode` is the
    // root node itself.
    let root = match root.get("rootNode").and_then(Value::as_object) {
        Some(nested) => nested,
        None => root,
    };
    let program = root
        .get("program")
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow!("Codama root node has no 'program'"))?;

    Ok(ProgramIdl {
        address: program
            .get("publicKey")
            .and_then(Value::as_str)
            .map(str::to_string),
        instructions: parse_instructions(program)?,
        // Codama has no event concept; program logs are not modelled.
        events: BTreeMap::new(),
        defined_types: parse_defined_types(program)?,
    })
}

fn parse_defined_types(program: &Map<String, Value>) -> Result<BTreeMap<String, FieldType>> {
    let mut out = BTreeMap::new();
    let Some(arr) = program.get("definedTypes").and_then(Value::as_array) else {
        return Ok(out);
    };
    for t in arr {
        let name = required_str(t, "name")
            .context("definedTypes[].name")?
            .to_string();
        let node = t
            .get("type")
            .ok_or_else(|| anyhow!("defined type '{name}' has no 'type'"))?;
        let ty = parse_type(node, &format!("definedTypes.{name}"))?;
        out.insert(name, ty);
    }
    Ok(out)
}

fn parse_instructions(program: &Map<String, Value>) -> Result<BTreeMap<String, IxIdl>> {
    let arr = program
        .get("instructions")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("Codama program has no 'instructions' array"))?;
    let mut out: BTreeMap<String, IxIdl> = BTreeMap::new();
    for ix in arr {
        let name = required_str(ix, "name")
            .context("instructions[].name")?
            .to_string();
        let (discriminator, encoded_arg_names) = parse_discriminators(ix)
            .with_context(|| format!("instruction '{name}' discriminators"))?;
        let ix_idl = IxIdl {
            discriminator,
            accounts: parse_accounts(ix.get("accounts"))
                .with_context(|| format!("instruction '{name}' accounts"))?,
            args: parse_arguments(ix.get("arguments"), &encoded_arg_names, &name)?,
        };
        if out.insert(name.clone(), ix_idl).is_some() {
            bail!("IDL declares instruction '{name}' more than once");
        }
    }
    Ok(out)
}

/// Returns the instruction's discriminator bytes plus the names of the
/// arguments consumed by field discriminators, which the Borsh runtime must
/// not decode again — it starts reading after the discriminator prefix.
fn parse_discriminators(ix: &Value) -> Result<(Vec<u8>, Vec<String>)> {
    let Some(arr) = ix.get("discriminators").and_then(Value::as_array) else {
        return Ok((Vec::new(), Vec::new()));
    };
    // Packed discriminators are declared in any order but encode at their
    // offsets, so byte order follows `offset`, not declaration order.
    let mut parts: Vec<(u64, Vec<u8>, Option<String>)> = Vec::with_capacity(arr.len());
    for d in arr {
        let kind = required_str(d, "kind")?;
        let offset = d.get("offset").and_then(Value::as_u64).unwrap_or(0);
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
            // A size discriminator matches on data length, not on a prefix,
            // so it contributes no bytes.
            "sizeDiscriminatorNode" => {}
            other => bail!("unsupported discriminator kind '{other}'"),
        }
    }
    // Dispatch matches one contiguous prefix off the head of the data, so the
    // parts have to tile from offset 0 with no gap and no overlap. Anything
    // else would concatenate into a prefix that is not what the program
    // actually encodes.
    parts.sort_by_key(|(offset, _, _)| *offset);
    let mut bytes: Vec<u8> = Vec::new();
    let mut field_names = Vec::new();
    for (offset, part, field) in parts {
        if offset != bytes.len() as u64 {
            bail!(
                "discriminator part at offset {offset} does not follow the previous part, which \
                 ends at {}; dispatch needs one contiguous prefix from offset 0",
                bytes.len()
            );
        }
        bytes.extend(part);
        field_names.extend(field);
    }
    Ok((bytes, field_names))
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

/// Little-endian encoding of a `numberValueNode` at the width its
/// `numberTypeNode` declares. Solana encodes multi-byte discriminators
/// little-endian, same as Borsh.
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
    let format = ty
        .get("format")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("expected a number type, got {ty}"))?;
    require_little_endian(ty, "discriminator")?;
    // Signed formats are encoded two's-complement at their own width, so the
    // range check has to be per-format rather than "does it fit in u64".
    let (width, min, max): (usize, i128, i128) = match format {
        "u8" => (1, 0, u8::MAX as i128),
        "u16" => (2, 0, u16::MAX as i128),
        "u32" => (4, 0, u32::MAX as i128),
        "u64" => (8, 0, u64::MAX as i128),
        "i8" => (1, i8::MIN as i128, i8::MAX as i128),
        "i16" => (2, i16::MIN as i128, i16::MAX as i128),
        "i32" => (4, i32::MIN as i128, i32::MAX as i128),
        "i64" => (8, i64::MIN as i128, i64::MAX as i128),
        other => bail!("unsupported discriminator number format '{other}'"),
    };
    if number < min || number > max {
        bail!("discriminator value {number} does not fit in {format}");
    }
    Ok(number.to_le_bytes()[..width].to_vec())
}

fn parse_accounts(node: Option<&Value>) -> Result<Vec<IdlAccount>> {
    let Some(arr) = node.and_then(Value::as_array) else {
        return Ok(Vec::new());
    };
    arr.iter()
        .map(|a| {
            Ok(IdlAccount {
                name: required_str(a, "name")?.to_string(),
                optional: a
                    .get("isOptional")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                writable: a
                    .get("isWritable")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                // `isSigner` is a tri-state: `true`, `false`, or `"either"`
                // for a slot that may or may not sign.
                signer: match a.get("isSigner") {
                    Some(Value::Bool(signer)) => *signer,
                    Some(Value::String(s)) => s == "either",
                    _ => false,
                },
            })
        })
        .collect()
}

fn parse_arguments(
    node: Option<&Value>,
    encoded_arg_names: &[String],
    ix_name: &str,
) -> Result<Vec<NamedField>> {
    let Some(arr) = node.and_then(Value::as_array) else {
        return Ok(Vec::new());
    };
    let mut out = Vec::with_capacity(arr.len());
    for a in arr {
        let name = required_str(a, "name")
            .with_context(|| format!("instruction '{ix_name}' arguments"))?
            .to_string();
        if encoded_arg_names.contains(&name) {
            continue;
        }
        let path = format!("instruction '{ix_name}'.{name}");
        reject_unmodelled_keys(a, &path, &FIELD_KEYS)?;
        let ty = a
            .get("type")
            .ok_or_else(|| anyhow!("{path}: argument has no 'type'"))?;
        out.push(NamedField {
            ty: parse_type(ty, &path)?,
            name,
        });
    }
    Ok(out)
}

/// Keys any node may carry without changing a single decoded byte. `display`
/// is Codama's presentation layer (a `u64` annotated as a SOL amount, say):
/// it describes how to show a value, never how to read it.
const DESCRIPTIVE_KEYS: [&str; 3] = ["kind", "docs", "display"];

/// Codama attaches layout modifiers (`endian`, `fixed`, `size`, `encoding`) to
/// nodes whose shape is otherwise recognisable, and a modifier the runtime
/// cannot express shifts every byte decoded after it. Ignoring an unknown key
/// is therefore never safe: each arm below lists the keys it actually models,
/// and a node carrying anything else is refused here rather than silently
/// mis-decoded at indexing time.
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
             be a guess at the byte layout"
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
        "definedTypeLinkNode" => {
            reject_unmodelled_keys(node, path, &["name", "program"])?;
            Ok(FieldType::Defined(
                required_str(node, "name")
                    .with_context(|| path.to_string())?
                    .to_string(),
            ))
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
    match node.get(key) {
        None => Ok(&[]),
        Some(value) => value
            .as_array()
            .map(Vec::as_slice)
            .ok_or_else(|| anyhow!("{path}: '{key}' must be an array")),
    }
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
