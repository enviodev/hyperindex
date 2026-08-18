//! Anchor IDL parsing, both dialects behind one code path.
//!
//! - **0.30+**: instructions carry an inline 8-byte `discriminator`; type refs
//!   are `{"defined": {"name": T}}`; account flags are
//!   `writable`/`signer`/`optional`; the pubkey primitive is `"pubkey"`.
//! - **Legacy (<=0.29)**: no inline discriminator; type refs are
//!   `{"defined": T}`; account flags are `isMut`/`isSigner`/`isOptional`; the
//!   pubkey primitive is `"publicKey"`.
//!
//! Both shapes are accepted for every divergent field, so no format toggle is
//! needed. An IDL is legacy precisely when its instructions lack an inline
//! `discriminator`, and only then is one derived from the name.

use std::collections::BTreeMap;

use anyhow::{anyhow, bail, Context, Result};
use heck::ToSnakeCase;
use hypersync_client_solana::decode::{EnumVariant, FieldType, NamedField};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

use super::{
    collect_instructions, collect_named, required_str, EventIdl, IdlAccount, IxIdl, ProgramIdl,
    Unusable,
};

pub(super) fn parse(root: &Map<String, Value>) -> Result<ProgramIdl> {
    let address = root
        .get("address")
        .and_then(Value::as_str)
        .or_else(|| {
            root.get("metadata")
                .and_then(|m| m.get("address"))
                .and_then(Value::as_str)
        })
        .map(str::to_string);

    let (defined_types, unusable_types) = parse_defined_types(root)?;
    let (instructions, unusable, unusable_discriminators) = parse_instructions(root)?;
    let events = parse_events(root, &defined_types, &unusable_types)?;

    Ok(ProgramIdl {
        address,
        instructions,
        events,
        defined_types,
        unusable,
        unusable_types,
        unusable_discriminators,
    })
}

fn parse_defined_types(
    root: &Map<String, Value>,
) -> Result<(BTreeMap<String, FieldType>, Unusable)> {
    let Some(arr) = root.get("types").and_then(Value::as_array) else {
        return Ok(Default::default());
    };
    collect_named(arr, "type", "types[].name", |name, t| {
        let node = t
            .get("type")
            .ok_or_else(|| anyhow!("type '{name}' has no 'type'"))?;
        parse_type_def(name, node)
    })
}

type Instructions = (BTreeMap<String, IxIdl>, Unusable, BTreeMap<String, Vec<u8>>);

fn parse_instructions(root: &Map<String, Value>) -> Result<Instructions> {
    let arr = root
        .get("instructions")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("IDL has no 'instructions' array"))?;
    collect_instructions(
        arr,
        |name, ix| match ix.get("discriminator") {
            Some(node) => parse_byte_array(node).context("discriminator"),
            None => Ok(hashed_discriminator("global:", &name.to_snake_case())),
        },
        |ix, discriminator| {
            Ok(IxIdl {
                discriminator,
                accounts: parse_accounts(ix.get("accounts")).context("accounts")?,
                args: parse_named_fields(ix.get("args"), "args")?,
            })
        },
    )
}

/// Legacy events carry their fields inline; 0.30+ moves the payload into
/// `types` under the event's own name and leaves only the discriminator.
fn parse_events(
    root: &Map<String, Value>,
    defined_types: &BTreeMap<String, FieldType>,
    unusable_types: &Unusable,
) -> Result<BTreeMap<String, EventIdl>> {
    let Some(arr) = root.get("events").and_then(Value::as_array) else {
        return Ok(BTreeMap::new());
    };
    // Nothing consumes events yet, so one the runtime could not decode is
    // dropped rather than held against the instructions, which it has no
    // bearing on.
    let (events, _undecodable) = collect_named(arr, "event", "events[].name", |name, ev| {
        let discriminator = match ev.get("discriminator") {
            Some(node) => {
                parse_byte_array(node).with_context(|| format!("event '{name}' discriminator"))?
            }
            None => hashed_discriminator("event:", name),
        };
        // 0.30+ leaves only the discriminator here and puts the payload in
        // `types` under the event's own name.
        let fields = match ev.get("fields") {
            Some(node) => parse_named_fields(Some(node), "fields")?,
            None => match defined_types.get(name) {
                Some(FieldType::Struct(fields)) => fields.clone(),
                Some(other) => bail!("its payload type is {other:?}, expected a struct"),
                None => match unusable_types.get(name) {
                    Some(reason) => bail!("its payload type cannot be decoded: {reason}"),
                    None => bail!("it declares no fields and no type named '{name}'"),
                },
            },
        };
        Ok(EventIdl {
            discriminator,
            fields,
        })
    })?;
    Ok(events)
}

/// `sha256(prefix + name)[..8]`, Anchor's derivation for both the pre-0.30
/// instruction discriminator (`global:` + snake_case) and the event
/// discriminator (`event:` + the declared name).
fn hashed_discriminator(prefix: &str, name: &str) -> Vec<u8> {
    let mut hasher = Sha256::new();
    hasher.update(prefix.as_bytes());
    hasher.update(name.as_bytes());
    hasher.finalize()[..8].to_vec()
}

fn parse_byte_array(node: &Value) -> Result<Vec<u8>> {
    let arr = node
        .as_array()
        .ok_or_else(|| anyhow!("expected an array of bytes, got {node}"))?;
    arr.iter()
        .map(|b| {
            b.as_u64()
                .filter(|n| *n <= u8::MAX as u64)
                .map(|n| n as u8)
                .ok_or_else(|| anyhow!("expected a byte (0-255), got {b}"))
        })
        .collect()
}

/// Composite account groups (`{ name, accounts: [...] }`) flatten into the
/// parent's list — Anchor inlines them at the call site.
fn parse_accounts(node: Option<&Value>) -> Result<Vec<IdlAccount>> {
    let Some(arr) = node.and_then(Value::as_array) else {
        return Ok(Vec::new());
    };
    let mut out = Vec::with_capacity(arr.len());
    for a in arr {
        if a.get("accounts").is_some() {
            out.extend(parse_accounts(a.get("accounts"))?);
            continue;
        }
        out.push(IdlAccount {
            name: required_str(a, "name")?.to_string(),
            optional: flag(a, "optional", "isOptional"),
            writable: flag(a, "writable", "isMut"),
            signer: flag(a, "signer", "isSigner"),
        });
    }
    Ok(out)
}

fn flag(node: &Value, modern: &str, legacy: &str) -> bool {
    node.get(modern)
        .or_else(|| node.get(legacy))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn parse_named_fields(node: Option<&Value>, path: &str) -> Result<Vec<NamedField>> {
    let Some(arr) = node.and_then(Value::as_array) else {
        return Ok(Vec::new());
    };
    arr.iter().map(|f| parse_named_field(f, path)).collect()
}

fn parse_named_field(f: &Value, path: &str) -> Result<NamedField> {
    let name = required_str(f, "name").with_context(|| path.to_string())?;
    let node = f
        .get("type")
        .ok_or_else(|| anyhow!("{path}: field '{name}' has no 'type'"))?;
    Ok(NamedField {
        name: name.to_string(),
        ty: parse_type(node, &format!("{path}.{name}"))?,
    })
}

fn parse_type(node: &Value, path: &str) -> Result<FieldType> {
    if let Some(s) = node.as_str() {
        return Ok(parse_primitive(s));
    }
    let obj = node
        .as_object()
        .ok_or_else(|| anyhow!("{path}: unsupported type {node}"))?;

    if let Some(inner) = obj.get("option") {
        return Ok(FieldType::Option(Box::new(parse_type(
            inner,
            &format!("{path}.option"),
        )?)));
    }
    // An SPL `COption` tags presence with four bytes where Borsh uses one, and
    // the runtime has no four-byte option to decode it with. Reading it as a
    // Borsh option would misalign this field and every field after it.
    if obj.contains_key("coption") {
        bail!("{path}: `coption` is not Borsh-compatible and cannot be decoded");
    }
    if let Some(inner) = obj.get("vec") {
        return Ok(FieldType::Vec(Box::new(parse_type(
            inner,
            &format!("{path}.vec"),
        )?)));
    }
    if let Some(arr) = obj.get("array").and_then(Value::as_array) {
        let [item, len] = arr.as_slice() else {
            bail!("{path}.array: expected [type, length], got {node}");
        };
        let len = len
            .as_u64()
            .ok_or_else(|| anyhow!("{path}.array: expected a length, got {len}"))?;
        return Ok(FieldType::Array {
            ty: Box::new(parse_type(item, &format!("{path}.array"))?),
            len: len as usize,
        });
    }
    if let Some(d) = obj.get("defined") {
        let name = d
            .as_str()
            .or_else(|| d.get("name").and_then(Value::as_str))
            .ok_or_else(|| anyhow!("{path}.defined: expected a type name, got {d}"))?;
        return Ok(FieldType::Defined(name.to_string()));
    }
    // A generic parameter is bound at the use site. `defined_types` is keyed
    // by declared type names, so a parameter could only ever resolve by
    // coincidence — and would then decode with another type's layout.
    if let Some(name) = obj.get("generic").and_then(Value::as_str) {
        bail!("{path}: generic parameter '{name}' has no concrete layout to decode against");
    }
    bail!("{path}: unsupported type {node}")
}

fn parse_primitive(s: &str) -> FieldType {
    if let Some(numeric) = super::numeric_field_type(s) {
        return numeric;
    }
    match s {
        "bool" => FieldType::Bool,
        "string" => FieldType::String,
        "bytes" => FieldType::Bytes,
        "pubkey" | "publicKey" => FieldType::Pubkey,
        // Tools sometimes emit a nominal name where a primitive is expected.
        // Falling through to `Defined` lets `types` supply the layout instead
        // of failing the whole IDL.
        other => FieldType::Defined(other.to_string()),
    }
}

fn parse_type_def(name: &str, node: &Value) -> Result<FieldType> {
    let kind = node
        .get("kind")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("type '{name}' has no 'kind'"))?;
    match kind {
        "struct" => Ok(FieldType::Struct(parse_named_fields(
            node.get("fields"),
            &format!("type '{name}'"),
        )?)),
        "enum" => {
            let variants = node
                .get("variants")
                .and_then(Value::as_array)
                .map(|arr| {
                    arr.iter()
                        .map(|v| parse_enum_variant(v, name))
                        .collect::<Result<Vec<_>>>()
                })
                .transpose()?
                .unwrap_or_default();
            Ok(FieldType::Enum(variants))
        }
        // Aliases (`pub type Foo = Pubkey`) resolve inline rather than adding
        // an indirection the Borsh runtime would have to chase.
        "type" => {
            let alias = node
                .get("alias")
                .or_else(|| node.get("type"))
                .ok_or_else(|| anyhow!("type alias '{name}' has no 'alias'"))?;
            parse_type(alias, &format!("type '{name}'"))
        }
        other => bail!("type '{name}' has unsupported kind '{other}'"),
    }
}

fn parse_enum_variant(v: &Value, enum_name: &str) -> Result<EnumVariant> {
    let name = required_str(v, "name")
        .with_context(|| format!("type '{enum_name}' variants[].name"))?
        .to_string();
    let path = format!("type '{enum_name}'.{name}");
    let fields = match v.get("fields") {
        None | Some(Value::Null) => None,
        Some(Value::Array(arr)) => Some(
            arr.iter()
                .enumerate()
                .map(|(i, f)| {
                    if f.get("name").and_then(Value::as_str).is_some() {
                        parse_named_field(f, &path)
                    } else {
                        // Tuple variant: positional names, as the runtime
                        // keys every decoded body by field name.
                        Ok(NamedField {
                            name: format!("_{i}"),
                            ty: parse_type(f, &format!("{path}[{i}]"))?,
                        })
                    }
                })
                .collect::<Result<Vec<_>>>()?,
        ),
        Some(other) => bail!("{path}.fields: expected an array, got {other}"),
    };
    Ok(EnumVariant { name, fields })
}
