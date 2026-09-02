//! Borsh instruction decoder bridge.
//!
//! `build_program_schema` assembles an upstream `ProgramSchema` from the
//! per-instruction schema pieces carried on the event registrations. The
//! Solana client builds these once at creation time and keeps them keyed by
//! program id; `get_event_items` then decodes each routed instruction inline
//! via `decode_with_schema`, so the `DecodedInstruction` shape rides back on
//! the query response instead of crossing the napi boundary one call at a
//! time.

use std::collections::BTreeMap;

use anyhow::{Context, Result};

use hypersync_client_solana::decode::{
    decode_instruction as upstream_decode, EnumVariant as UpstreamEnumVariant,
    FieldType as SvmFieldType, InstructionSchema as UpstreamIxSchema,
    NamedAccount as UpstreamAccount, NamedField as UpstreamNamedField,
    ProgramSchema as UpstreamSchema,
};
use hypersync_client_solana::simple_types::InstructionCall as UpstreamInstructionCall;

use crate::config_parsing::human_config::svm::{ArgComposite, ArgDef, ArgPrimitive, ArgType};
use crate::param_value::ParamValue;

use super::mod_helpers::hex_to_bytes;

/// One instruction's schema piece, assembled from a registration's
/// `accounts`/`args` at client creation.
#[derive(Debug)]
pub(crate) struct InstructionSchemaInput {
    pub name: String,
    /// Hex (`0x`-prefixed or bare) — the bytes the dispatcher matches against
    /// the head of `instruction.data`.
    pub discriminator: String,
    pub accounts: Vec<String>,
    pub args: Vec<ArgDef>,
}

/// What decoding one instruction against its program's schema produced.
#[derive(Debug, PartialEq)]
pub(crate) enum Decoded {
    Args(ParamValue),
    /// The program's schema carries no entry for this discriminator, so the
    /// registration declared neither args nor accounts. Nothing was asked to be
    /// decoded and nothing failed.
    Uncovered,
    /// The schema covers the discriminator but rejected the data.
    Failed,
}

/// Decode a raw instruction against a resolved schema into its args as a
/// `ParamValue` tree. Called inline by the Solana client's `get_event_items`,
/// so decoded args ride back on the query response instead of crossing the
/// napi boundary one instruction at a time.
///
/// The upstream decoder renders wide integers as decimal JSON strings and
/// leaves the bigint conversion to the consumer; `args_to_param` re-walks its
/// output against the instruction's field types to make that conversion.
///
/// A decode failure (account-count mismatch, trailing bytes, unresolved type)
/// yields `Failed` rather than an error: real on-chain calls drift from schemas
/// in small ways (Metaplex `rent` slot was optional in some versions, etc.), and
/// a single bad row should not kill the worker. The caller drops such an
/// instruction instead of running handlers on args it could not decode.
pub(crate) fn decode_with_schema(
    schema: &UpstreamSchema,
    instruction: &UpstreamInstructionCall,
) -> Decoded {
    // Dispatch as upstream does (longest discriminator prefix wins) to recover
    // the instruction schema, and to tell an undeclared instruction apart from
    // one whose data the schema rejects.
    let data = instruction.data.as_deref().unwrap_or_default();
    let ix = schema.disc_lens.iter().find_map(|&len| {
        data.get(..len)
            .and_then(|prefix| schema.instructions.get(prefix))
    });
    let Some(ix) = ix else {
        return Decoded::Uncovered;
    };
    let Ok(decoded) = upstream_decode(schema, instruction) else {
        return Decoded::Failed;
    };
    match args_to_param(decoded.args, &ix.args, &schema.defined_types) {
        Some(args) => Decoded::Args(args),
        None => Decoded::Failed,
    }
}

/// Convert a decoded args object into a `ParamValue` tree, guided by the
/// schema's field types — the only way to tell a wide-integer decimal string
/// from a Pubkey or a genuine `string` field. `None` on any shape mismatch,
/// which the caller treats like a decode failure.
fn args_to_param(
    args: serde_json::Value,
    fields: &[UpstreamNamedField],
    defined_types: &BTreeMap<String, SvmFieldType>,
) -> Option<ParamValue> {
    let serde_json::Value::Object(mut obj) = args else {
        return None;
    };
    let mut out = Vec::with_capacity(fields.len());
    for field in fields {
        let value = obj.remove(&field.name)?;
        out.push((
            field.name.clone(),
            value_to_param(value, &field.ty, defined_types)?,
        ));
    }
    Some(ParamValue::Obj(out))
}

fn value_to_param(
    value: serde_json::Value,
    ty: &SvmFieldType,
    defined_types: &BTreeMap<String, SvmFieldType>,
) -> Option<ParamValue> {
    use serde_json::Value;
    Some(match ty {
        SvmFieldType::Bool => ParamValue::Bool(value.as_bool()?),
        SvmFieldType::U8
        | SvmFieldType::U16
        | SvmFieldType::U32
        | SvmFieldType::I8
        | SvmFieldType::I16
        | SvmFieldType::I32 => ParamValue::Num(value.as_f64()?),
        // The upstream decoder renders a non-finite float as `Null`.
        SvmFieldType::F32 | SvmFieldType::F64 => match value {
            Value::Null => ParamValue::Null,
            value => ParamValue::Num(value.as_f64()?),
        },
        SvmFieldType::U64 | SvmFieldType::U128 => {
            ParamValue::from_u128(value.as_str()?.parse().ok()?)
        }
        SvmFieldType::I64 | SvmFieldType::I128 => {
            ParamValue::from_i128(value.as_str()?.parse().ok()?)
        }
        SvmFieldType::String | SvmFieldType::Pubkey => ParamValue::Str(value.as_str()?.to_string()),
        SvmFieldType::Option(inner) => match value {
            Value::Null => ParamValue::Null,
            value => value_to_param(value, inner, defined_types)?,
        },
        // Every u8 sequence reaches handlers as raw bytes. The upstream decoder
        // renders them three ways: `bytes` as `0x` hex, `[u8; 32]` as base58
        // on the assumption it is a pubkey (a schema declares a real pubkey as
        // `pubkey`, so a 32-byte array is a hash, root or seed), and any other
        // `vec<u8>` / `[u8; N]` as a number array.
        SvmFieldType::Bytes => {
            ParamValue::Bytes(crate::hex::decode_prefixed(value.as_str()?, "bytes").ok()?)
        }
        SvmFieldType::Array { ty, len } if matches!(**ty, SvmFieldType::U8) && *len == 32 => {
            let bytes = bs58::decode(value.as_str()?).into_vec().ok()?;
            if bytes.len() != 32 {
                return None;
            }
            ParamValue::Bytes(bytes)
        }
        SvmFieldType::Vec(ty) | SvmFieldType::Array { ty, .. }
            if matches!(**ty, SvmFieldType::U8) =>
        {
            let Value::Array(items) = value else {
                return None;
            };
            ParamValue::Bytes(
                items
                    .into_iter()
                    .map(|item| u8::try_from(item.as_u64()?).ok())
                    .collect::<Option<_>>()?,
            )
        }
        SvmFieldType::Vec(inner) | SvmFieldType::Array { ty: inner, .. } => {
            let Value::Array(items) = value else {
                return None;
            };
            ParamValue::Arr(
                items
                    .into_iter()
                    .map(|item| value_to_param(item, inner, defined_types))
                    .collect::<Option<_>>()?,
            )
        }
        SvmFieldType::Struct(fields) => args_to_param(value, fields, defined_types)?,
        SvmFieldType::Enum(variants) => {
            // Upstream renders every variant externally tagged, `{ Name: <body> }`.
            // A variant without fields (unit, or a struct variant with an empty
            // field list - the wire format is identical) collapses to its bare
            // name so handlers compare it as a string.
            let Value::Object(obj) = value else {
                return None;
            };
            let (name, body) = obj.into_iter().next()?;
            let variant = variants.iter().find(|v| v.name == name)?;
            match variant.fields.as_deref() {
                None | Some([]) => ParamValue::Str(name),
                Some(fields) => {
                    let body = args_to_param(body, fields, defined_types)?;
                    ParamValue::Obj(vec![(name, body)])
                }
            }
        }
        SvmFieldType::Defined(name) => {
            value_to_param(value, defined_types.get(name)?, defined_types)?
        }
    })
}

pub(crate) fn build_program_schema(
    program_id: String,
    defined_types: &BTreeMap<String, ArgType>,
    instruction_inputs: Vec<InstructionSchemaInput>,
) -> Result<UpstreamSchema> {
    let defined_types: BTreeMap<String, SvmFieldType> = defined_types
        .iter()
        .map(|(name, ty)| {
            arg_type_to_field_type(ty)
                .map(|ft| (name.clone(), ft))
                .with_context(|| format!("translating defined type '{name}'"))
        })
        .collect::<Result<_>>()?;

    let mut instructions: BTreeMap<Vec<u8>, UpstreamIxSchema> = BTreeMap::new();
    for ix in instruction_inputs {
        let discriminator = hex_to_bytes(&ix.discriminator)
            .with_context(|| format!("instruction '{}' discriminator", ix.name))?;
        let accounts = ix
            .accounts
            .into_iter()
            .map(|name| UpstreamAccount {
                name,
                writable: false,
                signer: false,
                // The wire format drops per-account writable/signer/optional
                // flags. Marking every account as `optional` lets the upstream
                // `required_account_count` rule accept *any* trailing tail,
                // matching real-world callers that omit sysvar slots.
                // Real-world surplus accounts still go to `extra_accounts`.
                optional: true,
            })
            .collect();
        let args = ix
            .args
            .into_iter()
            .map(|a| {
                Ok(UpstreamNamedField {
                    name: a.name.clone(),
                    ty: arg_type_to_field_type(&a.ty)
                        .with_context(|| format!("translating arg '{}'", a.name))?,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        instructions.insert(
            discriminator.clone(),
            UpstreamIxSchema {
                name: ix.name,
                discriminator,
                accounts,
                args,
            },
        );
    }

    Ok(UpstreamSchema::build(
        program_id,
        instructions,
        defined_types,
    ))
}

fn arg_type_to_field_type(ty: &ArgType) -> Result<SvmFieldType> {
    Ok(match ty {
        ArgType::Primitive(p) => match p {
            ArgPrimitive::Bool => SvmFieldType::Bool,
            ArgPrimitive::U8 => SvmFieldType::U8,
            ArgPrimitive::U16 => SvmFieldType::U16,
            ArgPrimitive::U32 => SvmFieldType::U32,
            ArgPrimitive::U64 => SvmFieldType::U64,
            ArgPrimitive::U128 => SvmFieldType::U128,
            ArgPrimitive::I8 => SvmFieldType::I8,
            ArgPrimitive::I16 => SvmFieldType::I16,
            ArgPrimitive::I32 => SvmFieldType::I32,
            ArgPrimitive::I64 => SvmFieldType::I64,
            ArgPrimitive::I128 => SvmFieldType::I128,
            ArgPrimitive::F32 => SvmFieldType::F32,
            ArgPrimitive::F64 => SvmFieldType::F64,
            ArgPrimitive::String => SvmFieldType::String,
            ArgPrimitive::Bytes => SvmFieldType::Bytes,
            ArgPrimitive::Pubkey | ArgPrimitive::PublicKey => SvmFieldType::Pubkey,
        },
        ArgType::Composite(c) => match c {
            ArgComposite::Option(inner) => {
                SvmFieldType::Option(Box::new(arg_type_to_field_type(inner)?))
            }
            ArgComposite::Vec(inner) => SvmFieldType::Vec(Box::new(arg_type_to_field_type(inner)?)),
            ArgComposite::Array(inner, len) => SvmFieldType::Array {
                ty: Box::new(arg_type_to_field_type(inner)?),
                len: *len,
            },
            ArgComposite::Defined(name) => SvmFieldType::Defined(name.clone()),
            ArgComposite::Struct(fields) => SvmFieldType::Struct(
                fields
                    .iter()
                    .map(|f| {
                        Ok(UpstreamNamedField {
                            name: f.name.clone(),
                            ty: arg_type_to_field_type(&f.ty)
                                .with_context(|| format!("struct field '{}'", f.name))?,
                        })
                    })
                    .collect::<Result<_>>()?,
            ),
            ArgComposite::Enum(variants) => SvmFieldType::Enum(
                variants
                    .iter()
                    .map(|v| {
                        let fields = v
                            .fields
                            .as_ref()
                            .map(|fs| {
                                fs.iter()
                                    .map(|f| {
                                        Ok(UpstreamNamedField {
                                            name: f.name.clone(),
                                            ty: arg_type_to_field_type(&f.ty).with_context(
                                                || format!("enum field '{}'", f.name),
                                            )?,
                                        })
                                    })
                                    .collect::<Result<_>>()
                            })
                            .transpose()?;
                        Ok(UpstreamEnumVariant {
                            name: v.name.clone(),
                            fields,
                        })
                    })
                    .collect::<Result<_>>()?,
            ),
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const PROGRAM: &str = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s";

    fn schema_of(args_json: &str, defined_types_json: &str) -> UpstreamSchema {
        let args: Vec<ArgDef> = serde_json::from_str(args_json).unwrap();
        let defined_types: BTreeMap<String, ArgType> =
            serde_json::from_str(defined_types_json).unwrap();
        build_program_schema(
            PROGRAM.to_string(),
            &defined_types,
            vec![InstructionSchemaInput {
                name: "Ix".to_string(),
                discriminator: "0x01".to_string(),
                accounts: vec![],
                args,
            }],
        )
        .unwrap()
    }

    fn instruction_with_data(data: Vec<u8>) -> UpstreamInstructionCall {
        UpstreamInstructionCall {
            data: Some(data),
            account_arguments: Some(vec![]),
            ..Default::default()
        }
    }

    fn obj(entries: Vec<(&str, ParamValue)>) -> ParamValue {
        ParamValue::Obj(
            entries
                .into_iter()
                .map(|(name, value)| (name.to_string(), value))
                .collect(),
        )
    }

    // https://github.com/enviodev/hyperindex/issues/1606 follow-up: wide
    // integers must reach handlers as bigint, not decimal strings.
    #[test]
    fn wide_integers_decode_as_bigints() {
        let schema = schema_of(
            r#"[
                {"name":"maxU64","type":"u64"},
                {"name":"maxU128","type":"u128"},
                {"name":"negI64","type":"i64"},
                {"name":"negI128","type":"i128"}
            ]"#,
            "{}",
        );
        let mut data = vec![0x01];
        data.extend_from_slice(&u64::MAX.to_le_bytes());
        data.extend_from_slice(&u128::MAX.to_le_bytes());
        data.extend_from_slice(&(-2i64).to_le_bytes());
        data.extend_from_slice(&(-(1i128 << 100)).to_le_bytes());
        assert_eq!(
            decode_with_schema(&schema, &instruction_with_data(data)),
            Decoded::Args(obj(vec![
                ("maxU64", ParamValue::from_u128(u128::from(u64::MAX))),
                ("maxU128", ParamValue::from_u128(u128::MAX)),
                ("negI64", ParamValue::from_i128(-2)),
                ("negI128", ParamValue::from_i128(-(1i128 << 100))),
            ]))
        );
    }

    // Borsh `bytes` reaches handlers as a Uint8Array, not a hex string:
    // Solana tooling takes raw bytes and nothing on that side speaks hex.
    #[test]
    fn bytes_decode_as_raw_bytes() {
        let schema = schema_of(
            r#"[
                {"name":"payload","type":"bytes"},
                {"name":"empty","type":"bytes"}
            ]"#,
            "{}",
        );
        let mut data = vec![0x01];
        data.extend_from_slice(&3u32.to_le_bytes());
        data.extend_from_slice(&[0xde, 0xad, 0x00]);
        data.extend_from_slice(&0u32.to_le_bytes());
        assert_eq!(
            decode_with_schema(&schema, &instruction_with_data(data)),
            Decoded::Args(obj(vec![
                ("payload", ParamValue::Bytes(vec![0xde, 0xad, 0x00])),
                ("empty", ParamValue::Bytes(vec![])),
            ]))
        );
    }

    // `vec<u8>` is byte-for-byte the same wire format as `bytes`, and a
    // fixed `[u8; N]` is a blob too, so neither may come back as `number[]`,
    // nor as base58 when N happens to be 32.
    #[test]
    fn u8_sequences_decode_as_raw_bytes() {
        let schema = schema_of(
            r#"[
                {"name":"vec","type":{"vec":"u8"}},
                {"name":"fixed","type":{"array":["u8",4]}},
                {"name":"nested","type":{"vec":{"array":["u8",2]}}},
                {"name":"hash","type":{"array":["u8",32]}},
                {"name":"notBytes","type":{"array":["u16",2]}}
            ]"#,
            "{}",
        );
        let mut data = vec![0x01];
        data.extend_from_slice(&2u32.to_le_bytes());
        data.extend_from_slice(&[0xff, 0x00]);
        data.extend_from_slice(&[1, 2, 3, 4]);
        data.extend_from_slice(&1u32.to_le_bytes());
        data.extend_from_slice(&[9, 8]);
        data.extend_from_slice(&[0xab; 32]);
        data.extend_from_slice(&7u16.to_le_bytes());
        data.extend_from_slice(&8u16.to_le_bytes());
        assert_eq!(
            decode_with_schema(&schema, &instruction_with_data(data)),
            Decoded::Args(obj(vec![
                ("vec", ParamValue::Bytes(vec![0xff, 0x00])),
                ("fixed", ParamValue::Bytes(vec![1, 2, 3, 4])),
                (
                    "nested",
                    ParamValue::Arr(vec![ParamValue::Bytes(vec![9, 8])])
                ),
                ("hash", ParamValue::Bytes(vec![0xab; 32])),
                (
                    "notBytes",
                    ParamValue::Arr(vec![ParamValue::Num(7.0), ParamValue::Num(8.0)])
                ),
            ]))
        );
    }

    #[test]
    fn composites_walk_by_schema() {
        let schema = schema_of(
            r#"[
                {"name":"absent","type":{"option":"u64"}},
                {"name":"present","type":{"option":"u64"}},
                {"name":"amounts","type":{"vec":"u64"}},
                {"name":"pair","type":{"struct":[
                    {"name":"label","type":"string"},
                    {"name":"amount","type":"u64"}
                ]}},
                {"name":"mode","type":{"defined":"SwapMode"}},
                {"name":"tag","type":{"defined":"SwapMode"}},
                {"name":"empty","type":{"defined":"SwapMode"}}
            ]"#,
            r#"{"SwapMode":{"enum":[
                {"name":"In"},
                {"name":"Out","fields":[{"name":"limit","type":"u64"}]},
                {"name":"Empty","fields":[]}
            ]}}"#,
        );
        let mut data = vec![0x01];
        data.push(0); // absent: None
        data.push(1); // present: Some
        data.extend_from_slice(&7u64.to_le_bytes());
        data.extend_from_slice(&2u32.to_le_bytes()); // amounts: len 2
        data.extend_from_slice(&1u64.to_le_bytes());
        data.extend_from_slice(&u64::MAX.to_le_bytes());
        data.extend_from_slice(&2u32.to_le_bytes()); // pair.label: "hi"
        data.extend_from_slice(b"hi");
        data.extend_from_slice(&3u64.to_le_bytes()); // pair.amount
        data.push(1); // mode: Out
        data.extend_from_slice(&(1u64 << 63).to_le_bytes()); // mode.limit
        data.push(0); // tag: In (unit variant)
        data.push(2); // empty: struct variant with no fields
        assert_eq!(
            decode_with_schema(&schema, &instruction_with_data(data)),
            Decoded::Args(obj(vec![
                ("absent", ParamValue::Null),
                ("present", ParamValue::from_u128(7)),
                (
                    "amounts",
                    ParamValue::Arr(vec![
                        ParamValue::from_u128(1),
                        ParamValue::from_u128(u128::from(u64::MAX)),
                    ])
                ),
                (
                    "pair",
                    obj(vec![
                        ("label", ParamValue::Str("hi".to_string())),
                        ("amount", ParamValue::from_u128(3)),
                    ])
                ),
                (
                    "mode",
                    obj(vec![(
                        "Out",
                        obj(vec![("limit", ParamValue::from_u128(1u128 << 63))])
                    )])
                ),
                ("tag", ParamValue::Str("In".to_string())),
                ("empty", ParamValue::Str("Empty".to_string())),
            ]))
        );
    }
}
