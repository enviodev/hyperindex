//! Borsh instruction args decoder.
//!
//! Every config instruction carries its own `ArgsSchema`; the Solana client
//! builds them once at creation and `get_event_items` decodes each routed
//! instruction inline, so decoded args ride back on the query response instead
//! of crossing the napi boundary one instruction at a time.

use std::collections::BTreeMap;
use std::sync::Arc;

use anyhow::{Context, Result};

use hypersync_client_solana::decode::{
    decode_field, FieldType as SvmFieldType, NamedField as UpstreamNamedField,
};

use crate::config_parsing::human_config::svm::{ArgDef, ArgType};
use crate::config_parsing::system_config::arg_type_to_field_type;
use crate::js_value::{Emit, Sink};

/// A program's nominal types, shared by every instruction of the program.
pub(crate) type DefinedTypes = BTreeMap<String, SvmFieldType>;

pub(crate) fn parse_defined_types(json: Option<&str>) -> Result<DefinedTypes> {
    let types: BTreeMap<String, ArgType> = match json {
        Some(json) => serde_json::from_str(json).context("parse defined types")?,
        None => BTreeMap::new(),
    };
    types
        .iter()
        .map(|(name, ty)| {
            arg_type_to_field_type(ty)
                .map(|ft| (name.clone(), ft))
                .with_context(|| format!("translating defined type '{name}'"))
        })
        .collect()
}

/// The Borsh layout of one config instruction's args: the bytes after the
/// instruction's data prefix, walked in declared order.
#[derive(Debug)]
pub(crate) struct ArgsSchema {
    prefix_len: usize,
    fields: Vec<UpstreamNamedField>,
    defined_types: Arc<DefinedTypes>,
}

impl ArgsSchema {
    pub(crate) fn new(
        prefix_len: usize,
        args: &[ArgDef],
        defined_types: Arc<DefinedTypes>,
    ) -> Result<Self> {
        let fields = args
            .iter()
            .map(|a| {
                Ok(UpstreamNamedField {
                    name: a.name.clone(),
                    ty: arg_type_to_field_type(&a.ty)
                        .with_context(|| format!("translating arg '{}'", a.name))?,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(Self {
            prefix_len,
            fields,
            defined_types,
        })
    }

    /// Decode an instruction's data into its args. `None` when the layout
    /// rejects the data: too few bytes, trailing bytes, an unknown enum tag.
    /// Real on-chain calls drift from layouts in small ways (a program upgrade
    /// that kept its discriminator, a hand-rolled wrapper), and one bad row
    /// must not kill the worker, so the caller drops the instruction for this
    /// layout only.
    pub(crate) fn decode(self: &Arc<Self>, data: &[u8]) -> Option<InstructionArgs> {
        let mut buf = data.get(self.prefix_len..)?;
        let values = self
            .fields
            .iter()
            .map(|field| decode_field(&field.ty, &self.defined_types, &mut buf).ok())
            .collect::<Option<_>>()?;
        if !buf.is_empty() {
            return None;
        }
        let args = InstructionArgs {
            schema: self.clone(),
            values,
        };
        args.is_valid().then_some(args)
    }
}

/// Instruction args their layout accepted, as the upstream decoder's JSON,
/// one value per field.
///
/// The upstream decoder renders wide integers as decimal strings and u8
/// sequences three different ways, so the JS values are emitted by walking
/// the JSON against the field types — the only way to tell a wide-integer
/// decimal string from a Pubkey or a genuine `string` field.
#[derive(Clone)]
pub struct InstructionArgs {
    schema: Arc<ArgsSchema>,
    values: Arc<[serde_json::Value]>,
}

impl Emit for InstructionArgs {
    fn emit<S: Sink>(&self, sink: &mut S) -> Option<S::Value> {
        let mut obj = sink.obj()?;
        for (field, value) in self.schema.fields.iter().zip(self.values.iter()) {
            let value = emit_value(value, &field.ty, &self.schema.defined_types, sink)?;
            sink.set(&mut obj, &field.name, value)?;
        }
        Some(sink.end_obj(obj))
    }
}

/// `None` on any shape mismatch, which `decode` treats like a decode failure.
fn emit_struct<S: Sink>(
    value: &serde_json::Value,
    fields: &[UpstreamNamedField],
    defined_types: &DefinedTypes,
    sink: &mut S,
) -> Option<S::Value> {
    let values = value.as_object()?;
    let mut obj = sink.obj()?;
    for field in fields {
        let value = emit_value(values.get(&field.name)?, &field.ty, defined_types, sink)?;
        sink.set(&mut obj, &field.name, value)?;
    }
    Some(sink.end_obj(obj))
}

fn emit_value<S: Sink>(
    value: &serde_json::Value,
    ty: &SvmFieldType,
    defined_types: &DefinedTypes,
    sink: &mut S,
) -> Option<S::Value> {
    use serde_json::Value;
    match ty {
        SvmFieldType::Bool => sink.bool(value.as_bool()?),
        SvmFieldType::U8
        | SvmFieldType::U16
        | SvmFieldType::U32
        | SvmFieldType::I8
        | SvmFieldType::I16
        | SvmFieldType::I32
        // Borsh refuses to serialize a NaN, so one on the wire says the bytes
        // are not the float this layout claims and the instruction is dropped
        // like any other layout mismatch. The upstream decoder renders every
        // non-finite float as `Null`, which `as_f64` rejects; that takes a
        // legitimate infinity with it, which no Solana program is known to
        // send. Behind an `option` the ambiguity is unreachable: `None` is
        // `Null` too, and there a non-finite float reads as absent.
        | SvmFieldType::F32
        | SvmFieldType::F64 => sink.num(value.as_f64()?),
        SvmFieldType::U64 | SvmFieldType::U128 => {
            let value: u128 = value.as_str()?.parse().ok()?;
            sink.bigint(false, &words(value))
        }
        SvmFieldType::I64 | SvmFieldType::I128 => {
            let value: i128 = value.as_str()?.parse().ok()?;
            sink.bigint(value < 0, &words(value.unsigned_abs()))
        }
        SvmFieldType::String | SvmFieldType::Pubkey => sink.str(value.as_str()?),
        SvmFieldType::Option(inner) => match value {
            Value::Null => sink.null(),
            value => emit_value(value, inner, defined_types, sink),
        },
        // Every u8 sequence reaches handlers as raw bytes. The upstream decoder
        // renders them three ways: `bytes` as `0x` hex, `[u8; 32]` as base58
        // on the assumption it is a pubkey (a schema declares a real pubkey as
        // `pubkey`, so a 32-byte array is a hash, root or seed), and any other
        // `vec<u8>` / `[u8; N]` as a number array.
        SvmFieldType::Bytes => {
            sink.bytes(&crate::hex::decode_prefixed(value.as_str()?, "bytes").ok()?)
        }
        SvmFieldType::Array { ty, len } if matches!(**ty, SvmFieldType::U8) && *len == 32 => {
            let mut bytes = [0u8; 32];
            let len = bs58::decode(value.as_str()?).onto(&mut bytes).ok()?;
            if len != 32 {
                return None;
            }
            sink.bytes(&bytes)
        }
        SvmFieldType::Vec(ty) | SvmFieldType::Array { ty, .. }
            if matches!(**ty, SvmFieldType::U8) =>
        {
            let bytes: Vec<u8> = value
                .as_array()?
                .iter()
                .map(|item| u8::try_from(item.as_u64()?).ok())
                .collect::<Option<_>>()?;
            sink.bytes(&bytes)
        }
        SvmFieldType::Vec(inner) | SvmFieldType::Array { ty: inner, .. } => {
            let items = value.as_array()?;
            let mut arr = sink.arr(items.len())?;
            for item in items {
                let item = emit_value(item, inner, defined_types, sink)?;
                sink.push(&mut arr, item)?;
            }
            Some(sink.end_arr(arr))
        }
        SvmFieldType::Struct(fields) => emit_struct(value, fields, defined_types, sink),
        SvmFieldType::Enum(variants) => {
            // Upstream renders every variant externally tagged, `{ Name: <body> }`.
            // A variant without fields (unit, or a struct variant with an empty
            // field list - the wire format is identical) collapses to its bare
            // name so handlers compare it as a string.
            let (name, body) = value.as_object()?.iter().next()?;
            let variant = variants.iter().find(|v| &v.name == name)?;
            match variant.fields.as_deref() {
                None | Some([]) => sink.str(name),
                Some(fields) => {
                    let body = emit_struct(body, fields, defined_types, sink)?;
                    let mut obj = sink.obj()?;
                    sink.set(&mut obj, name, body)?;
                    Some(sink.end_obj(obj))
                }
            }
        }
        SvmFieldType::Defined(name) => {
            emit_value(value, defined_types.get(name)?, defined_types, sink)
        }
    }
}

/// `value` as little-endian 64-bit words.
fn words(value: u128) -> [u64; 2] {
    [value as u64, (value >> 64) as u64]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::js_value::test_value::JsValue;

    struct Schema(Arc<ArgsSchema>);

    impl Schema {
        fn decode(&self, data: &[u8]) -> Option<JsValue> {
            self.0.decode(data).map(|args| JsValue::of(&args))
        }
    }

    fn schema_of(args_json: &str, defined_types_json: &str) -> Schema {
        let args: Vec<ArgDef> = serde_json::from_str(args_json).unwrap();
        let defined_types = parse_defined_types(Some(defined_types_json)).unwrap();
        Schema(Arc::new(
            ArgsSchema::new(1, &args, Arc::new(defined_types)).unwrap(),
        ))
    }

    fn obj(entries: Vec<(&str, JsValue)>) -> JsValue {
        JsValue::obj(entries)
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
            schema.decode(&data),
            Some(obj(vec![
                ("maxU64", JsValue::uint(u128::from(u64::MAX))),
                ("maxU128", JsValue::uint(u128::MAX)),
                ("negI64", JsValue::int(-2)),
                ("negI128", JsValue::int(-(1i128 << 100))),
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
            schema.decode(&data),
            Some(obj(vec![
                ("payload", JsValue::Bytes(vec![0xde, 0xad, 0x00])),
                ("empty", JsValue::Bytes(vec![])),
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
            schema.decode(&data),
            Some(obj(vec![
                ("vec", JsValue::Bytes(vec![0xff, 0x00])),
                ("fixed", JsValue::Bytes(vec![1, 2, 3, 4])),
                ("nested", JsValue::Arr(vec![JsValue::Bytes(vec![9, 8])])),
                ("hash", JsValue::Bytes(vec![0xab; 32])),
                (
                    "notBytes",
                    JsValue::Arr(vec![JsValue::Num(7.0), JsValue::Num(8.0)])
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
            schema.decode(&data),
            Some(obj(vec![
                ("absent", JsValue::Null),
                ("present", JsValue::uint(7)),
                (
                    "amounts",
                    JsValue::Arr(vec![JsValue::uint(1), JsValue::uint(u128::from(u64::MAX)),])
                ),
                (
                    "pair",
                    obj(vec![
                        ("label", JsValue::Str("hi".to_string())),
                        ("amount", JsValue::uint(3)),
                    ])
                ),
                (
                    "mode",
                    obj(vec![(
                        "Out",
                        obj(vec![("limit", JsValue::uint(1u128 << 63))])
                    )])
                ),
                ("tag", JsValue::Str("In".to_string())),
                ("empty", JsValue::Str("Empty".to_string())),
            ]))
        );
    }

    // SPL Memo: no discriminator, the whole data is the args.
    #[test]
    fn a_zero_length_prefix_decodes_the_whole_data() {
        let args: Vec<ArgDef> =
            serde_json::from_str(r#"[{"name":"text","type":"string"}]"#).unwrap();
        let schema = Schema(Arc::new(
            ArgsSchema::new(0, &args, Arc::new(DefinedTypes::new())).unwrap(),
        ));
        let mut data = 5u32.to_le_bytes().to_vec();
        data.extend_from_slice(b"hello");
        assert_eq!(
            schema.decode(&data),
            Some(obj(vec![("text", JsValue::Str("hello".to_string()))]))
        );
    }

    #[test]
    fn a_non_finite_float_is_rejected() {
        let schema = schema_of(r#"[{"name":"ratio","type":"f64"}]"#, "{}");
        let payload = |bits: f64| {
            let mut data = vec![0x01];
            data.extend_from_slice(&bits.to_le_bytes());
            data
        };
        assert_eq!(
            (
                schema.decode(&payload(f64::NAN)),
                schema.decode(&payload(f64::INFINITY)),
                schema.decode(&payload(1.5)),
            ),
            (None, None, Some(obj(vec![("ratio", JsValue::Num(1.5))])))
        );
    }

    /// A declared-but-empty layout is the assertion that the instruction takes
    /// no arguments, so it accepts exactly the calls that carry nothing past
    /// the discriminator. Attaching no layout at all is what takes every call.
    #[test]
    fn an_empty_layout_accepts_only_a_bare_discriminator() {
        let schema = schema_of("[]", "{}");
        assert_eq!(
            (
                schema.decode(&[0x01]),
                schema.decode(&[0x01, 0x00]),
                schema.decode(&[0x01, 0xde, 0xad])
            ),
            (Some(obj(vec![])), None, None)
        );
    }

    #[test]
    fn short_and_trailing_data_are_rejected() {
        let schema = schema_of(r#"[{"name":"amount","type":"u64"}]"#, "{}");
        let mut exact = vec![0x01];
        exact.extend_from_slice(&1u64.to_le_bytes());
        let mut trailing = exact.clone();
        trailing.push(0);
        assert_eq!(
            (
                schema.decode(&[0x01, 1]),
                schema.decode(&trailing),
                schema.decode(&exact)
            ),
            (None, None, Some(obj(vec![("amount", JsValue::uint(1))])))
        );
    }
}
