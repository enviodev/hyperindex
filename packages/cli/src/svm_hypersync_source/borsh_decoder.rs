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
    FieldType as SvmFieldType, NamedField as UpstreamNamedField,
};

use crate::config_parsing::human_config::svm::{ArgDef, ArgType};
use crate::config_parsing::system_config::arg_type_to_field_type;
use crate::js_value::JsTape;

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
    /// rejects the data: too few bytes, trailing bytes, an invalid bool,
    /// option or enum tag, invalid UTF-8, a non-finite float, or more
    /// zero-sized values than the data can account for. Real on-chain calls
    /// drift from layouts in small ways (a program upgrade that kept its
    /// discriminator, a hand-rolled wrapper), and one bad row must not kill
    /// the worker, so the caller drops the instruction for this layout only.
    pub(crate) fn decode(&self, data: &[u8]) -> Option<JsTape> {
        let buf = data.get(self.prefix_len..)?;
        let mut input = Input {
            buf,
            zero_sized_budget: buf.len() + ZERO_SIZED_BUDGET_SLACK,
        };
        let mut tape = JsTape::new();
        write_struct(&self.fields, &self.defined_types, &mut input, &mut tape)?;
        input.buf.is_empty().then_some(tape)
    }
}

/// The data left to decode, and how many more values may be decoded without
/// consuming any of it.
struct Input<'a> {
    buf: &'a [u8],
    zero_sized_budget: usize,
}

impl<'a> Input<'a> {
    fn take(&mut self, len: usize) -> Option<&'a [u8]> {
        let (head, tail) = self.buf.split_at_checked(len)?;
        self.buf = tail;
        Some(head)
    }

    fn array<const N: usize>(&mut self) -> Option<[u8; N]> {
        self.take(N)?.try_into().ok()
    }

    fn byte(&mut self) -> Option<u8> {
        Some(self.take(1)?[0])
    }

    fn len(&mut self) -> Option<usize> {
        usize::try_from(u32::from_le_bytes(self.array()?)).ok()
    }
}

/// Only values of zero-sized types (an empty struct, a zero-length array)
/// can outnumber the data. Instruction data is attacker-controlled (any
/// caller can hit a matching discriminator), so a `vec` of them must not
/// expand a few bytes into unbounded memory: they may number at most the
/// data length plus this.
const ZERO_SIZED_BUDGET_SLACK: usize = 1024;

fn write_struct(
    fields: &[UpstreamNamedField],
    defined_types: &DefinedTypes,
    input: &mut Input,
    tape: &mut JsTape,
) -> Option<()> {
    tape.obj(fields.len());
    for field in fields {
        tape.key(&field.name);
        write_value(&field.ty, defined_types, input, tape)?;
    }
    Some(())
}

fn write_value(
    ty: &SvmFieldType,
    defined_types: &DefinedTypes,
    input: &mut Input,
    tape: &mut JsTape,
) -> Option<()> {
    let remaining = input.buf.len();
    match ty {
        SvmFieldType::Bool => match input.byte()? {
            0 => tape.bool(false),
            1 => tape.bool(true),
            _ => return None,
        },
        SvmFieldType::U8 => tape.num(f64::from(input.byte()?)),
        SvmFieldType::U16 => tape.num(f64::from(u16::from_le_bytes(input.array()?))),
        SvmFieldType::U32 => tape.num(f64::from(u32::from_le_bytes(input.array()?))),
        SvmFieldType::I8 => tape.num(f64::from(i8::from_le_bytes(input.array()?))),
        SvmFieldType::I16 => tape.num(f64::from(i16::from_le_bytes(input.array()?))),
        SvmFieldType::I32 => tape.num(f64::from(i32::from_le_bytes(input.array()?))),
        // Borsh refuses to serialize a NaN, so one on the wire says the bytes
        // are not the float this layout claims. No Solana program is known to
        // send an infinity, so non-finite floats are rejected together.
        SvmFieldType::F32 => tape.num(finite(f64::from(f32::from_le_bytes(input.array()?)))?),
        SvmFieldType::F64 => tape.num(finite(f64::from_le_bytes(input.array()?))?),
        SvmFieldType::U64 => tape.bigint(false, &[u64::from_le_bytes(input.array()?)]),
        SvmFieldType::U128 => tape.bigint(false, &words(u128::from_le_bytes(input.array()?))),
        SvmFieldType::I64 => {
            let value = i64::from_le_bytes(input.array()?);
            tape.bigint(value < 0, &[value.unsigned_abs()]);
        }
        SvmFieldType::I128 => {
            let value = i128::from_le_bytes(input.array()?);
            tape.bigint(value < 0, &words(value.unsigned_abs()));
        }
        SvmFieldType::String => {
            let len = input.len()?;
            tape.str(std::str::from_utf8(input.take(len)?).ok()?);
        }
        SvmFieldType::Pubkey => {
            let mut base58 = [0u8; 44];
            let len = bs58::encode(input.take(32)?).onto(&mut base58[..]).ok()?;
            tape.str(std::str::from_utf8(&base58[..len]).ok()?);
        }
        SvmFieldType::Option(inner) => match input.byte()? {
            0 => tape.null(),
            1 => write_value(inner, defined_types, input, tape)?,
            _ => return None,
        },
        // Every u8 sequence reaches handlers as raw bytes: a schema declares a
        // real pubkey as `pubkey`, so a `[u8; 32]` is a hash, root or seed.
        SvmFieldType::Bytes => {
            let len = input.len()?;
            tape.bytes(input.take(len)?);
        }
        SvmFieldType::Vec(ty) if matches!(**ty, SvmFieldType::U8) => {
            let len = input.len()?;
            tape.bytes(input.take(len)?);
        }
        SvmFieldType::Array { ty, len } if matches!(**ty, SvmFieldType::U8) => {
            tape.bytes(input.take(*len)?);
        }
        SvmFieldType::Vec(inner) => {
            let len = input.len()?;
            tape.arr(len);
            for _ in 0..len {
                write_value(inner, defined_types, input, tape)?;
            }
        }
        SvmFieldType::Array { ty: inner, len } => {
            tape.arr(*len);
            for _ in 0..*len {
                write_value(inner, defined_types, input, tape)?;
            }
        }
        SvmFieldType::Struct(fields) => write_struct(fields, defined_types, input, tape)?,
        // A variant without fields (unit, or a struct variant with an empty
        // field list - the wire format is identical) is its bare name, so
        // handlers compare it as a string; one with fields is `{ Name: body }`.
        SvmFieldType::Enum(variants) => {
            let variant = variants.get(usize::from(input.byte()?))?;
            match variant.fields.as_deref() {
                None | Some([]) => tape.str(&variant.name),
                Some(fields) => {
                    tape.obj(1);
                    tape.key(&variant.name);
                    write_struct(fields, defined_types, input, tape)?;
                }
            }
        }
        SvmFieldType::Defined(name) => {
            write_value(defined_types.get(name)?, defined_types, input, tape)?
        }
    }
    if input.buf.len() == remaining {
        input.zero_sized_budget = input.zero_sized_budget.checked_sub(1)?;
    }
    Some(())
}

fn finite(value: f64) -> Option<f64> {
    value.is_finite().then_some(value)
}

/// `value` as little-endian 64-bit words.
fn words(value: u128) -> [u64; 2] {
    [value as u64, (value >> 64) as u64]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::js_value::test_value::JsValue;

    struct Schema(ArgsSchema);

    impl Schema {
        fn decode(&self, data: &[u8]) -> Option<JsValue> {
            self.0.decode(data).map(|tape| JsValue::of(&tape))
        }
    }

    fn schema_of(args_json: &str, defined_types_json: &str) -> Schema {
        let args: Vec<ArgDef> = serde_json::from_str(args_json).unwrap();
        let defined_types = parse_defined_types(Some(defined_types_json)).unwrap();
        Schema(ArgsSchema::new(1, &args, Arc::new(defined_types)).unwrap())
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
        let schema = Schema(ArgsSchema::new(0, &args, Arc::new(DefinedTypes::new())).unwrap());
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

    // A few bytes claiming u32::MAX empty structs used to spin the upstream
    // decoder until the process ran out of memory.
    #[test]
    fn bounds_values_decoded_without_consuming_data() {
        let schema = schema_of(r#"[{"name":"xs","type":{"vec":{"struct":[]}}}]"#, "{}");
        let claiming = |len: u32| {
            let mut data = vec![0x01];
            data.extend_from_slice(&len.to_le_bytes());
            data
        };
        assert_eq!(
            (
                schema.decode(&claiming(u32::MAX)),
                schema.decode(&claiming(2)),
            ),
            (
                None,
                Some(obj(vec![(
                    "xs",
                    JsValue::Arr(vec![JsValue::Obj(vec![]), JsValue::Obj(vec![])])
                )]))
            )
        );
    }

    #[test]
    fn a_non_finite_float_behind_an_option_is_rejected() {
        let schema = schema_of(r#"[{"name":"ratio","type":{"option":"f64"}}]"#, "{}");
        let some = |value: f64| {
            let mut data = vec![0x01, 0x01];
            data.extend_from_slice(&value.to_le_bytes());
            data
        };
        assert_eq!(
            (schema.decode(&some(f64::NAN)), schema.decode(&[0x01, 0x00]),),
            (None, Some(obj(vec![("ratio", JsValue::Null)])))
        );
    }
}
