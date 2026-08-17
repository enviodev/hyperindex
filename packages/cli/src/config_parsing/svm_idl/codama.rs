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

use super::{IdlAccount, IxIdl, ProgramIdl};

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
    parts.sort_by_key(|(offset, _, _)| *offset);
    let bytes = parts.iter().flat_map(|(_, b, _)| b.clone()).collect();
    let field_names = parts.into_iter().filter_map(|(_, _, name)| name).collect();
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
    let number = value
        .get("number")
        .and_then(Value::as_u64)
        .ok_or_else(|| anyhow!("expected a 'number', got {value}"))?;
    let format = ty
        .get("format")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("expected a number type, got {ty}"))?;
    let width = match format {
        "u8" | "i8" => 1,
        "u16" | "i16" => 2,
        "u32" | "i32" => 4,
        "u64" | "i64" => 8,
        other => bail!("unsupported discriminator number format '{other}'"),
    };
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

fn parse_type(node: &Value, path: &str) -> Result<FieldType> {
    let kind = required_str(node, "kind").with_context(|| path.to_string())?;
    match kind {
        "numberTypeNode" => {
            let format = required_str(node, "format").with_context(|| path.to_string())?;
            match format {
                "u8" => Ok(FieldType::U8),
                "u16" => Ok(FieldType::U16),
                "u32" => Ok(FieldType::U32),
                "u64" => Ok(FieldType::U64),
                "u128" => Ok(FieldType::U128),
                "i8" => Ok(FieldType::I8),
                "i16" => Ok(FieldType::I16),
                "i32" => Ok(FieldType::I32),
                "i64" => Ok(FieldType::I64),
                "i128" => Ok(FieldType::I128),
                "f32" => Ok(FieldType::F32),
                "f64" => Ok(FieldType::F64),
                other => bail!("{path}: unsupported number format '{other}'"),
            }
        }
        "booleanTypeNode" => Ok(FieldType::Bool),
        "stringTypeNode" => Ok(FieldType::String),
        "bytesTypeNode" => Ok(FieldType::Bytes),
        "publicKeyTypeNode" => Ok(FieldType::Pubkey),
        "definedTypeLinkNode" => Ok(FieldType::Defined(
            required_str(node, "name")
                .with_context(|| path.to_string())?
                .to_string(),
        )),
        // `zeroableOptionTypeNode` differs only in how `None` is encoded, and
        // the Borsh runtime has no zeroable form to decode it with.
        "optionTypeNode" | "zeroableOptionTypeNode" => Ok(FieldType::Option(Box::new(parse_type(
            item(node, path)?,
            &format!("{path}.item"),
        )?))),
        "arrayTypeNode" => {
            let item = parse_type(item(node, path)?, &format!("{path}.item"))?;
            let count = node
                .get("count")
                .ok_or_else(|| anyhow!("{path}: array has no 'count'"))?;
            match required_str(count, "kind")? {
                "fixedCountNode" => {
                    let len = count
                        .get("value")
                        .and_then(Value::as_u64)
                        .ok_or_else(|| anyhow!("{path}: fixed count has no 'value'"))?;
                    Ok(FieldType::Array {
                        ty: Box::new(item),
                        len: len as usize,
                    })
                }
                "prefixedCountNode" => Ok(FieldType::Vec(Box::new(item))),
                other => bail!("{path}: unsupported array count kind '{other}'"),
            }
        }
        "structTypeNode" => {
            let fields = node
                .get("fields")
                .and_then(Value::as_array)
                .ok_or_else(|| anyhow!("{path}: struct has no 'fields'"))?;
            Ok(FieldType::Struct(
                fields
                    .iter()
                    .map(|f| {
                        let name = required_str(f, "name").with_context(|| path.to_string())?;
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
        "tupleTypeNode" => Ok(FieldType::Struct(positional_fields(node, path)?)),
        "enumTypeNode" => {
            let variants = node
                .get("variants")
                .and_then(Value::as_array)
                .ok_or_else(|| anyhow!("{path}: enum has no 'variants'"))?;
            Ok(FieldType::Enum(
                variants
                    .iter()
                    .map(|v| parse_enum_variant(v, path))
                    .collect::<Result<Vec<_>>>()?,
            ))
        }
        // A u32 size prefix is exactly how Borsh frames a string or a byte
        // vector, so this wrapper adds nothing the runtime doesn't already do.
        // Any other prefix width — and every other wrapper node — shifts the
        // byte layout in a way the runtime cannot express, and unwrapping one
        // regardless would misalign every field decoded after it.
        "sizePrefixTypeNode" => {
            let prefix = node
                .get("prefix")
                .and_then(|p| p.get("format"))
                .and_then(Value::as_str);
            if prefix != Some("u32") {
                bail!("{path}: size prefix must be u32, got {prefix:?}");
            }
            parse_type(
                node.get("type")
                    .ok_or_else(|| anyhow!("{path}: {kind} has no 'type'"))?,
                path,
            )
        }
        other => bail!("{path}: unsupported type node '{other}'"),
    }
}

fn parse_enum_variant(v: &Value, enum_path: &str) -> Result<EnumVariant> {
    let name = required_str(v, "name").with_context(|| enum_path.to_string())?;
    let path = format!("{enum_path}.{name}");
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
            Some(positional_fields(inner, &path)?)
        }
        other => bail!("{path}: unsupported enum variant kind '{other}'"),
    };
    Ok(EnumVariant {
        name: name.to_string(),
        fields,
    })
}

/// Tuple items become `_0`, `_1`, … so every decoded body is keyed by name.
fn positional_fields(node: &Value, path: &str) -> Result<Vec<NamedField>> {
    let items = node
        .get("items")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("{path}: tuple has no 'items'"))?;
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

fn item<'a>(node: &'a Value, path: &str) -> Result<&'a Value> {
    node.get("item")
        .ok_or_else(|| anyhow!("{path}: node has no 'item'"))
}

fn required_str<'a>(node: &'a Value, key: &str) -> Result<&'a str> {
    node.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("missing '{key}' in {node}"))
}
