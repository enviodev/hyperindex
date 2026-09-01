//! Anchor IDL parsing, both dialects behind one code path.
//!
//! - **0.30+**: instructions carry an inline 8-byte `discriminator`; type refs
//!   are `{"defined": {"name": T}}`; optional accounts use `optional`; the
//!   pubkey primitive is `"pubkey"`.
//! - **Legacy (<=0.29)**: no inline discriminator; type refs are
//!   `{"defined": T}`; optional accounts use `isOptional`; the pubkey
//!   primitive is `"publicKey"`.
//!
//! Both shapes are accepted for every divergent field, so no format toggle is
//! needed. An IDL is legacy precisely when its instructions lack an inline
//! `discriminator`, and only then is one derived from the name.
//!
//! Shank (Metaplex's generator) emits the same top-level shape and is read
//! here too, but it dispatches on `discriminant`, never on a hashed name.

use std::collections::BTreeMap;

use anyhow::{anyhow, bail, Context, Result};
use hypersync_client_solana::decode::{EnumVariant, FieldType, NamedField};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

use crate::config_parsing::field_types::to_snake_case;

use super::{
    account_slot, collect_instructions, collect_named, declared_array, declared_optional, le_bytes,
    required_str, IdlAccount, Instructions, IxIdl, ProgramIdl, Unusable,
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
    let (instructions, unusable, declared_discriminators) = parse_instructions(root)?;

    Ok(ProgramIdl {
        address,
        instructions,
        defined_types,
        unusable,
        unusable_types,
        declared_discriminators,
    })
}

fn parse_defined_types(
    root: &Map<String, Value>,
) -> Result<(BTreeMap<String, FieldType>, Unusable)> {
    let arr = declared_array(root.get("types")).context("types")?;
    collect_named(arr, "type", "types[].name", |name, t| {
        let node = t
            .get("type")
            .ok_or_else(|| anyhow!("type '{name}' has no 'type'"))?;
        parse_type_def(name, node)
    })
}

fn parse_instructions(root: &Map<String, Value>) -> Result<Instructions> {
    let arr = root
        .get("instructions")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("IDL has no 'instructions' array"))?;
    let shank = root
        .get("metadata")
        .and_then(|m| m.get("origin"))
        .and_then(Value::as_str)
        == Some("shank");
    collect_instructions(
        arr,
        |name, ix| {
            let bytes = match (ix.get("discriminator"), ix.get("discriminant")) {
                (Some(node), _) => parse_byte_array(node).context("discriminator")?,
                (None, Some(node)) => discriminant_bytes(node).context("discriminant")?,
                (None, None) if shank => bail!(
                    "discriminant: this Shank IDL declares none, and a hashed Anchor \
                     discriminator is not what a Shank program dispatches on"
                ),
                (None, None) => hashed_discriminator("global:", &to_snake_case(name)),
            };
            Ok((bytes, ()))
        },
        |ix, discriminator, ()| {
            Ok(IxIdl {
                discriminator,
                accounts: parse_accounts(ix.get("accounts")).context("accounts")?,
                args: parse_named_fields(ix.get("args"), "args")?,
            })
        },
    )
}

fn hashed_discriminator(prefix: &str, name: &str) -> Vec<u8> {
    let mut hasher = Sha256::new();
    hasher.update(prefix.as_bytes());
    hasher.update(name.as_bytes());
    hasher.finalize()[..8].to_vec()
}

/// Shank's `{"type": "u8", "value": 12}`: the tag the program reads off the
/// head of the data, little-endian at the width its type declares.
fn discriminant_bytes(node: &Value) -> Result<Vec<u8>> {
    let format = required_str(node, "type")?;
    let ty = super::numeric_field_type(format)
        .ok_or_else(|| anyhow!("unsupported discriminant type '{format}'"))?;
    let value = node
        .get("value")
        .and_then(Value::as_u64)
        .ok_or_else(|| anyhow!("expected a non-negative integer 'value', got {node}"))?;
    le_bytes(&ty, value.into())
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
/// parent's list — Anchor inlines them at the call site. A group is a namespace
/// in the program's source, and two of them nesting the same inner name is
/// ordinary: Kamino's `depositAccounts` and `withdrawAccounts` each carry an
/// `owner`. So a member is named for the group that declares it, the way
/// Anchor's own clients address it, rather than by a bare name that would
/// collide and cost the instruction.
///
/// A group may itself be optional, and then every slot it holds is: reading its
/// members as required makes the account after the group inherit a pubkey that
/// belongs to it.
fn parse_accounts(node: Option<&Value>) -> Result<Vec<IdlAccount>> {
    fn flatten(
        node: Option<&Value>,
        prefix: &str,
        optional: bool,
        out: &mut Vec<IdlAccount>,
    ) -> Result<()> {
        for a in declared_array(node)? {
            let optional = optional || declared_optional(a)?;
            match a.get("accounts") {
                Some(group) => {
                    let name = required_str(a, "name")?;
                    flatten(Some(group), &qualify(prefix, name), optional, out)?;
                }
                None => {
                    let slot = account_slot(a)?;
                    out.push(IdlAccount {
                        name: qualify(prefix, &slot.name),
                        optional: optional || slot.optional,
                    });
                }
            }
        }
        Ok(())
    }

    let mut out = Vec::new();
    flatten(node, "", false, &mut out)?;
    Ok(out)
}

/// `depositAccounts` + `owner` reads back as `depositAccountsOwner`, keeping
/// the flattened list in the lowerCamelCase the rest of an IDL's names use.
fn qualify(prefix: &str, name: &str) -> String {
    if prefix.is_empty() {
        return name.to_string();
    }
    let mut out = String::with_capacity(prefix.len() + name.len());
    out.push_str(prefix);
    let mut chars = name.chars();
    if let Some(first) = chars.next() {
        out.extend(first.to_uppercase());
        out.push_str(chars.as_str());
    }
    out
}

/// Present but not an array is a defect, not an empty list: read as empty, an
/// instruction would decode as taking no data and report an empty payload for
/// every call.
fn parse_named_fields(node: Option<&Value>, path: &str) -> Result<Vec<NamedField>> {
    declared_array(node)
        .with_context(|| path.to_string())?
        .iter()
        .map(|f| parse_named_field(f, path))
        .collect()
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
        return parse_primitive(s).with_context(|| path.to_string());
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

fn parse_primitive(s: &str) -> Result<FieldType> {
    if let Some(numeric) = super::numeric_field_type(s) {
        return Ok(numeric);
    }
    Ok(match s {
        "bool" => FieldType::Bool,
        "string" => FieldType::String,
        "bytes" => FieldType::Bytes,
        "pubkey" | "publicKey" => FieldType::Pubkey,
        other => bail!("unknown type '{other}'"),
    })
}

fn parse_type_def(name: &str, node: &Value) -> Result<FieldType> {
    let kind = node
        .get("kind")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("type '{name}' has no 'kind'"))?;
    match kind {
        // A unit struct spells its absent body as a null `fields`, the same way
        // an enum's unit variant does.
        "struct" => Ok(FieldType::Struct(parse_named_fields(
            node.get("fields").filter(|fields| !fields.is_null()),
            &format!("type '{name}'"),
        )?)),
        // An absent `variants` is a legitimate empty enum; one that is present
        // and not an array is a defect, since reading it as empty leaves the
        // enum's tag resolving to no variant at all.
        "enum" => Ok(FieldType::Enum(
            declared_array(node.get("variants"))
                .with_context(|| format!("type '{name}' variants"))?
                .iter()
                .map(|v| parse_enum_variant(v, name))
                .collect::<Result<Vec<_>>>()?,
        )),
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
