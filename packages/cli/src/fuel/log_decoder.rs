use std::collections::HashMap;

use anyhow::{bail, ensure, Context, Result};
use fuel_abi_types::abi::program::ProgramABI;
use fuel_abi_types::abi::unified_program::{
    UnifiedProgramABI, UnifiedTypeApplication, UnifiedTypeDeclaration,
};

use crate::param_value::ParamValue;

/// A logged type resolved against its ABI, with every generic parameter
/// substituted, so decoding is a plain walk over the tree.
#[derive(Debug, Clone)]
enum Coder {
    Unit,
    Bool,
    /// Big-endian unsigned integer of this many bytes, decoded to a JS number.
    Num(usize),
    /// Big-endian unsigned integer of this many bytes (a multiple of 8),
    /// decoded to a JS bigint.
    BigInt(usize),
    /// Fixed-size bytes, decoded to a `0x`-prefixed hex string.
    Hex(usize),
    /// `str[N]`: exactly N bytes of UTF-8.
    StrArray(usize),
    /// `str` and `String`: u64 length prefix, then UTF-8.
    Str,
    /// `Bytes`: u64 length prefix, decoded to a `Uint8Array`.
    Bytes,
    /// `raw untyped slice`: u64 length prefix, decoded to an array of numbers.
    RawSlice,
    Array(Box<Coder>, usize),
    Vec(Box<Coder>),
    Tuple(Vec<Coder>),
    Struct(Vec<(String, Coder)>),
    /// Decoded to `{case, payload}`, with an `undefined` payload for unit
    /// variants — the shape the generated ReScript variants are tagged on.
    Enum(Vec<(String, Coder)>),
}

pub struct LogDecoder(Coder);

impl LogDecoder {
    pub fn new(abi: serde_json::Value, log_id: &str) -> Result<Self> {
        let program: ProgramABI = serde_json::from_value(abi).context("parse Fuel ABI")?;
        let program = UnifiedProgramABI::from_counterpart(&program)?;
        let logged = program
            .logged_types
            .iter()
            .flatten()
            .find(|logged| logged.log_id == log_id)
            .with_context(|| format!("Log type with logId '{log_id}' doesn't exist in the ABI"))?;
        let types = program.types.iter().map(|t| (t.type_id, t)).collect();
        let coder = resolve(&logged.application, &types, &HashMap::new())
            .with_context(|| format!("resolve the type logged with logId '{log_id}'"))?;
        Ok(Self(coder))
    }

    /// Trailing bytes are ignored.
    pub fn decode(&self, data: &[u8]) -> Result<ParamValue> {
        self.0.decode(&mut &data[..])
    }
}

/// `generics` binds the generic parameters in scope where `app` appears.
fn resolve(
    app: &UnifiedTypeApplication,
    types: &HashMap<usize, &UnifiedTypeDeclaration>,
    generics: &HashMap<usize, Coder>,
) -> Result<Coder> {
    if let Some(bound) = generics.get(&app.type_id) {
        return Ok(bound.clone());
    }
    let decl = types
        .get(&app.type_id)
        .with_context(|| format!("type id {} is missing from the ABI", app.type_id))?;
    let args = app
        .type_arguments
        .iter()
        .flatten()
        .map(|arg| resolve(arg, types, generics))
        .collect::<Result<Vec<_>>>()?;
    let own_generics: HashMap<usize, Coder> = decl
        .type_parameters
        .iter()
        .flatten()
        .copied()
        .zip(args.iter().cloned())
        .collect();
    let components = || {
        decl.components
            .iter()
            .flatten()
            .map(|c| Ok((c.name.clone(), resolve(c, types, &own_generics)?)))
            .collect::<Result<Vec<_>>>()
    };
    let field = decl.type_field.as_str();
    Ok(match field {
        "()" => Coder::Unit,
        "bool" => Coder::Bool,
        "u8" => Coder::Num(1),
        "u16" => Coder::Num(2),
        "u32" => Coder::Num(4),
        "u64" | "raw untyped ptr" => Coder::BigInt(8),
        "u128" => Coder::BigInt(16),
        "u256" => Coder::BigInt(32),
        "b256" => Coder::Hex(32),
        "struct std::b512::B512" => Coder::Hex(64),
        "str" | "struct std::string::String" => Coder::Str,
        "struct std::bytes::Bytes" => Coder::Bytes,
        "raw untyped slice" => Coder::RawSlice,
        "struct std::vec::Vec" => Coder::Vec(Box::new(
            args.into_iter()
                .next()
                .context("Vec is missing its element type")?,
        )),
        _ if field.starts_with("str[") => Coder::StrArray(parse_len(field, '[')?),
        _ if field.starts_with('[') => {
            let (_, element) = components()?
                .into_iter()
                .next()
                .with_context(|| format!("{field} is missing its element type"))?;
            Coder::Array(Box::new(element), parse_len(field, ';')?)
        }
        _ if field.starts_with("struct ") => Coder::Struct(components()?),
        _ if field.starts_with("enum ") => Coder::Enum(components()?),
        _ if field.starts_with('(') => {
            Coder::Tuple(components()?.into_iter().map(|(_, c)| c).collect())
        }
        _ => bail!("unsupported Fuel ABI type '{field}'"),
    })
}

/// The number between `after` and the closing `]`, as in `str[5]` or `[_; 5]`.
fn parse_len(field: &str, after: char) -> Result<usize> {
    field
        .split_once(after)
        .and_then(|(_, rest)| rest.strip_suffix(']'))
        .and_then(|len| len.trim().parse().ok())
        .with_context(|| format!("parse the length of '{field}'"))
}

fn take<'a>(buf: &mut &'a [u8], len: usize) -> Result<&'a [u8]> {
    ensure!(
        buf.len() >= len,
        "unexpected end of data: needed {len} bytes, {} left",
        buf.len()
    );
    let (head, tail) = buf.split_at(len);
    *buf = tail;
    Ok(head)
}

fn take_u64(buf: &mut &[u8]) -> Result<u64> {
    Ok(u64::from_be_bytes(take(buf, 8)?.try_into().unwrap()))
}

fn take_len(buf: &mut &[u8]) -> Result<usize> {
    let len = take_u64(buf)?;
    usize::try_from(len).with_context(|| format!("length {len} overflows"))
}

fn utf8(bytes: &[u8]) -> ParamValue {
    ParamValue::Str(String::from_utf8_lossy(bytes).into_owned())
}

impl Coder {
    /// The fewest bytes a value can encode to, which bounds how many elements
    /// a length prefix can honestly claim.
    fn min_size(&self) -> usize {
        match self {
            Coder::Unit => 0,
            Coder::Bool => 1,
            Coder::Num(n) | Coder::BigInt(n) | Coder::Hex(n) | Coder::StrArray(n) => *n,
            Coder::Str | Coder::Bytes | Coder::RawSlice | Coder::Vec(_) | Coder::Enum(_) => 8,
            Coder::Array(element, n) => element.min_size() * n,
            Coder::Tuple(items) => items.iter().map(Coder::min_size).sum(),
            Coder::Struct(fields) => fields.iter().map(|(_, c)| c.min_size()).sum(),
        }
    }

    fn decode_all<'a>(
        coders: impl Iterator<Item = &'a Coder>,
        buf: &mut &[u8],
    ) -> Result<Vec<ParamValue>> {
        coders.map(|c| c.decode(buf)).collect()
    }

    fn decode(&self, buf: &mut &[u8]) -> Result<ParamValue> {
        Ok(match self {
            Coder::Unit => ParamValue::Undefined,
            Coder::Bool => match take(buf, 1)?[0] {
                0 => ParamValue::Bool(false),
                1 => ParamValue::Bool(true),
                b => bail!("invalid bool value {b}"),
            },
            Coder::Num(n) => ParamValue::Num(
                take(buf, *n)?
                    .iter()
                    .fold(0u32, |acc, b| (acc << 8) | u32::from(*b))
                    .into(),
            ),
            Coder::BigInt(n) => ParamValue::BigInt {
                sign_bit: false,
                words: take(buf, *n)?
                    .rchunks(8)
                    .map(|limb| u64::from_be_bytes(limb.try_into().unwrap()))
                    .collect(),
            },
            Coder::Hex(n) => {
                ParamValue::Str(format!("0x{}", faster_hex::hex_string(take(buf, *n)?)))
            }
            Coder::StrArray(n) => utf8(take(buf, *n)?),
            Coder::Str => {
                let len = take_len(buf)?;
                utf8(take(buf, len)?)
            }
            Coder::Bytes => {
                let len = take_len(buf)?;
                ParamValue::Bytes(take(buf, len)?.to_vec())
            }
            Coder::RawSlice => {
                let len = take_len(buf)?;
                ParamValue::Arr(
                    take(buf, len)?
                        .iter()
                        .map(|b| ParamValue::Num(f64::from(*b)))
                        .collect(),
                )
            }
            Coder::Array(element, n) => {
                ParamValue::Arr(Self::decode_all(std::iter::repeat_n(&**element, *n), buf)?)
            }
            Coder::Vec(element) => {
                let len = take_len(buf)?;
                ensure!(
                    len.saturating_mul(element.min_size()) <= buf.len(),
                    "Vec length {len} exceeds the remaining {} bytes",
                    buf.len()
                );
                ParamValue::Arr(Self::decode_all(std::iter::repeat_n(&**element, len), buf)?)
            }
            Coder::Tuple(items) => ParamValue::Arr(Self::decode_all(items.iter(), buf)?),
            Coder::Struct(fields) => ParamValue::Obj(
                fields
                    .iter()
                    .map(|(name, c)| Ok((name.clone(), c.decode(buf)?)))
                    .collect::<Result<_>>()?,
            ),
            Coder::Enum(variants) => {
                let case = take_u64(buf)?;
                let (name, payload) = usize::try_from(case)
                    .ok()
                    .and_then(|i| variants.get(i))
                    .with_context(|| {
                        format!(
                            "invalid enum case {case}, expected one of {} variants",
                            variants.len()
                        )
                    })?;
                ParamValue::Obj(vec![
                    ("case".to_string(), ParamValue::Str(name.clone())),
                    ("payload".to_string(), payload.decode(buf)?),
                ])
            }
        })
    }
}

/// An ABI logging a `u8` under `log_id`.
#[cfg(test)]
pub(crate) fn test_abi(log_id: &str) -> serde_json::Value {
    serde_json::json!({
        "programType": "contract",
        "specVersion": "1",
        "encodingVersion": "1",
        "concreteTypes": [{ "type": "u8", "concreteTypeId": "u8" }],
        "metadataTypes": [],
        "functions": [],
        "loggedTypes": [{ "logId": log_id, "concreteTypeId": "u8" }],
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use ruint::aliases::U256;
    use serde_json::json;

    #[derive(Debug, Clone)]
    enum Shape {
        Unit,
        Bool,
        U8,
        U16,
        U32,
        U64,
        U128,
        U256,
        RawPtr,
        B256,
        B512,
        StrArray(usize),
        Str,
        String,
        Bytes,
        RawSlice,
        Array(Box<Shape>, usize),
        Vec(Box<Shape>),
        Option(Box<Shape>),
        Tuple(Vec<Shape>),
        Struct(Vec<Shape>),
        Enum(Vec<Shape>),
        /// `struct Wrapper<T> { value: T, list: Vec<T> }`: a generic threaded
        /// through a nested generic application.
        Wrapper(Box<Shape>),
        /// `enum Result<T, E> { Ok: T, Err: E }`: two generic parameters.
        Result(Box<Shape>, Box<Shape>),
    }

    fn shape() -> impl Strategy<Value = Shape> {
        let leaf = prop_oneof![
            Just(Shape::Unit),
            Just(Shape::Bool),
            Just(Shape::U8),
            Just(Shape::U16),
            Just(Shape::U32),
            Just(Shape::U64),
            Just(Shape::U128),
            Just(Shape::U256),
            Just(Shape::RawPtr),
            Just(Shape::B256),
            Just(Shape::B512),
            (0usize..6).prop_map(Shape::StrArray),
            Just(Shape::Str),
            Just(Shape::String),
            Just(Shape::Bytes),
            Just(Shape::RawSlice),
        ];
        leaf.prop_recursive(4, 32, 4, |inner| {
            let boxed = inner.clone().prop_map(Box::new);
            prop_oneof![
                (boxed.clone(), 0usize..4).prop_map(|(s, n)| Shape::Array(s, n)),
                boxed.clone().prop_map(Shape::Vec),
                boxed.clone().prop_map(Shape::Option),
                prop::collection::vec(inner.clone(), 2..4).prop_map(Shape::Tuple),
                prop::collection::vec(inner.clone(), 0..4).prop_map(Shape::Struct),
                prop::collection::vec(inner.clone(), 1..4).prop_map(Shape::Enum),
                boxed.clone().prop_map(Shape::Wrapper),
                (boxed.clone(), boxed).prop_map(|(t, e)| Shape::Result(t, e)),
            ]
        })
    }

    /// Emits a spec-v1 ABI (`concreteTypes` + `metadataTypes`) the way forc
    /// does: each generic declared once, metadata components pointing at
    /// non-generic types by concrete id and at generic instantiations by
    /// metadata id plus `typeArguments`.
    #[derive(Default)]
    struct AbiBuilder {
        concrete: Vec<serde_json::Value>,
        metadata: Vec<serde_json::Value>,
        generics: HashMap<&'static str, usize>,
    }

    /// A type as the logged type refers to it (`concrete`) and as a metadata
    /// component does (`application`).
    struct Applied {
        concrete: String,
        application: serde_json::Value,
    }

    fn component(name: &str, applied: &Applied) -> serde_json::Value {
        let mut component = applied.application.clone();
        component["name"] = json!(name);
        component
    }

    impl AbiBuilder {
        fn concrete_type(&mut self, value: serde_json::Value) -> String {
            let id = format!("c{}", self.concrete.len());
            let mut value = value;
            value["concreteTypeId"] = json!(id);
            self.concrete.push(value);
            id
        }

        fn metadata_type(&mut self, value: serde_json::Value) -> usize {
            let id = self.metadata.len();
            let mut value = value;
            value["metadataTypeId"] = json!(id);
            self.metadata.push(value);
            id
        }

        fn by_concrete_id(concrete: String) -> Applied {
            let application = json!({ "typeId": concrete });
            Applied {
                concrete,
                application,
            }
        }

        fn primitive(&mut self, type_field: &str) -> Applied {
            Self::by_concrete_id(self.concrete_type(json!({ "type": type_field })))
        }

        fn named(&mut self, type_field: &str, components: Vec<(String, Applied)>) -> Applied {
            let components: Vec<_> = components
                .iter()
                .map(|(name, applied)| component(name, applied))
                .collect();
            let metadata =
                self.metadata_type(json!({ "type": type_field, "components": components }));
            Self::by_concrete_id(
                self.concrete_type(json!({ "type": type_field, "metadataTypeId": metadata })),
            )
        }

        /// Declares a generic type once; `build` gets the ids of its generic
        /// parameters and returns its type field and components.
        fn generic(
            &mut self,
            key: &'static str,
            params: usize,
            build: impl FnOnce(&mut Self, &[usize]) -> (&'static str, serde_json::Value),
        ) -> usize {
            if let Some(id) = self.generics.get(key) {
                return *id;
            }
            let param_ids: Vec<usize> = (0..params)
                .map(|i| self.metadata_type(json!({ "type": format!("generic T{i}") })))
                .collect();
            let (type_field, components) = build(self, &param_ids);
            let id = self.metadata_type(json!({
                "type": type_field,
                "components": components,
                "typeParameters": param_ids,
            }));
            self.generics.insert(key, id);
            id
        }

        fn vec_metadata(&mut self) -> usize {
            self.generic("Vec", 1, |b, t| {
                let raw_vec = b.generic("RawVec", 1, |b, _| {
                    let ptr = b.primitive("raw untyped ptr");
                    let cap = b.primitive("u64");
                    (
                        "struct std::vec::RawVec",
                        json!([component("ptr", &ptr), component("cap", &cap)]),
                    )
                });
                let len = b.primitive("u64");
                (
                    "struct std::vec::Vec",
                    json!([
                        { "name": "buf", "typeId": raw_vec, "typeArguments": [{ "name": "", "typeId": t[0] }] },
                        component("len", &len),
                    ]),
                )
            })
        }

        fn apply(&mut self, type_field: &str, metadata: usize, args: Vec<Applied>) -> Applied {
            let concrete = self.concrete_type(json!({
                "type": type_field,
                "metadataTypeId": metadata,
                "typeArguments": args.iter().map(|a| a.concrete.clone()).collect::<Vec<_>>(),
            }));
            Applied {
                concrete,
                application: json!({
                    "typeId": metadata,
                    "typeArguments": args.iter().map(|a| component("", a)).collect::<Vec<_>>(),
                }),
            }
        }

        fn add(&mut self, shape: &Shape) -> Applied {
            match shape {
                Shape::Unit => self.primitive("()"),
                Shape::Bool => self.primitive("bool"),
                Shape::U8 => self.primitive("u8"),
                Shape::U16 => self.primitive("u16"),
                Shape::U32 => self.primitive("u32"),
                Shape::U64 => self.primitive("u64"),
                Shape::U128 => self.primitive("u128"),
                Shape::U256 => self.primitive("u256"),
                Shape::RawPtr => self.primitive("raw untyped ptr"),
                Shape::B256 => self.primitive("b256"),
                Shape::B512 => {
                    let b256 = self.primitive("b256");
                    let bits = self.named("[_; 2]", vec![("__array_element".into(), b256)]);
                    self.named("struct std::b512::B512", vec![("bits".into(), bits)])
                }
                Shape::StrArray(n) => self.primitive(&format!("str[{n}]")),
                Shape::Str => self.primitive("str"),
                Shape::String => self.primitive("struct std::string::String"),
                Shape::Bytes => self.primitive("struct std::bytes::Bytes"),
                Shape::RawSlice => self.primitive("raw untyped slice"),
                Shape::Array(element, n) => {
                    let element = self.add(element);
                    self.named(
                        &format!("[_; {n}]"),
                        vec![("__array_element".into(), element)],
                    )
                }
                Shape::Vec(element) => {
                    let element = self.add(element);
                    let vec = self.vec_metadata();
                    self.apply("struct std::vec::Vec", vec, vec![element])
                }
                Shape::Option(some) => {
                    let some = self.add(some);
                    let option = self.generic("Option", 1, |b, t| {
                        let unit = b.primitive("()");
                        (
                            "enum std::option::Option",
                            json!([component("None", &unit), { "name": "Some", "typeId": t[0] }]),
                        )
                    });
                    self.apply("enum std::option::Option", option, vec![some])
                }
                Shape::Tuple(items) => {
                    let items = items
                        .iter()
                        .map(|s| ("__tuple_element".into(), self.add(s)))
                        .collect();
                    self.named("(_, _)", items)
                }
                Shape::Struct(fields) => {
                    let name = format!("struct lib::S{}", self.metadata.len());
                    let fields = fields
                        .iter()
                        .enumerate()
                        .map(|(i, s)| (format!("f{i}"), self.add(s)))
                        .collect();
                    self.named(&name, fields)
                }
                Shape::Enum(variants) => {
                    let name = format!("enum lib::E{}", self.metadata.len());
                    let variants = variants
                        .iter()
                        .enumerate()
                        .map(|(i, s)| (format!("V{i}"), self.add(s)))
                        .collect();
                    self.named(&name, variants)
                }
                Shape::Wrapper(value) => {
                    let value = self.add(value);
                    let wrapper = self.generic("Wrapper", 1, |b, t| {
                        let vec = b.vec_metadata();
                        (
                            "struct lib::Wrapper",
                            json!([
                                { "name": "value", "typeId": t[0] },
                                { "name": "list", "typeId": vec, "typeArguments": [{ "name": "", "typeId": t[0] }] },
                            ]),
                        )
                    });
                    self.apply("struct lib::Wrapper", wrapper, vec![value])
                }
                Shape::Result(ok, err) => {
                    let ok = self.add(ok);
                    let err = self.add(err);
                    let result = self.generic("Result", 2, |_, t| {
                        (
                            "enum std::result::Result",
                            json!([{ "name": "Ok", "typeId": t[0] }, { "name": "Err", "typeId": t[1] }]),
                        )
                    });
                    self.apply("enum std::result::Result", result, vec![ok, err])
                }
            }
        }
    }

    const LOG_ID: &str = "4242";

    fn abi_logging(shape: &Shape) -> serde_json::Value {
        let mut builder = AbiBuilder::default();
        let logged = builder.add(shape).concrete;
        json!({
            "programType": "contract",
            "specVersion": "1",
            "encodingVersion": "1",
            "concreteTypes": builder.concrete,
            "metadataTypes": builder.metadata,
            "functions": [],
            "loggedTypes": [{ "logId": LOG_ID, "concreteTypeId": logged }],
        })
    }

    /// An encoded value alongside the JS value it must decode to.
    type Sample = (Vec<u8>, ParamValue);

    fn obj(entries: Vec<(String, ParamValue)>) -> ParamValue {
        ParamValue::Obj(entries)
    }

    fn enum_value(case: usize, name: String, (bytes, payload): Sample) -> Sample {
        let mut encoded = (case as u64).to_be_bytes().to_vec();
        encoded.extend(bytes);
        (
            encoded,
            obj(vec![
                ("case".into(), ParamValue::Str(name)),
                ("payload".into(), payload),
            ]),
        )
    }

    fn concat(samples: Vec<Sample>) -> (Vec<u8>, Vec<ParamValue>) {
        samples
            .into_iter()
            .fold((vec![], vec![]), |(mut bytes, mut values), (b, v)| {
                bytes.extend(b);
                values.push(v);
                (bytes, values)
            })
    }

    fn length_prefixed(len: usize, bytes: impl IntoIterator<Item = u8>) -> Vec<u8> {
        (len as u64)
            .to_be_bytes()
            .into_iter()
            .chain(bytes)
            .collect()
    }

    fn uint(bytes: Vec<u8>) -> Sample {
        let value = U256::from_be_slice(&bytes);
        let expected = ParamValue::BigInt {
            sign_bit: false,
            words: value.as_limbs()[..bytes.len() / 8].to_vec(),
        };
        (bytes, expected)
    }

    fn hex(bytes: Vec<u8>) -> Sample {
        let expected = bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
        (bytes, ParamValue::Str(format!("0x{expected}")))
    }

    fn fields(
        shapes: &[Shape],
        name: impl Fn(usize) -> String + 'static,
    ) -> BoxedStrategy<Vec<(String, Sample)>> {
        let strategies: Vec<_> = shapes.iter().map(sample).collect();
        strategies
            .prop_map(move |samples| {
                samples
                    .into_iter()
                    .enumerate()
                    .map(|(i, s)| (name(i), s))
                    .collect()
            })
            .boxed()
    }

    fn sample(shape: &Shape) -> BoxedStrategy<Sample> {
        let num = |bytes: Vec<u8>| {
            let value = bytes
                .iter()
                .fold(0f64, |acc, b| acc * 256.0 + f64::from(*b));
            (bytes, ParamValue::Num(value))
        };
        match shape.clone() {
            Shape::Unit => Just((vec![], ParamValue::Undefined)).boxed(),
            Shape::Bool => any::<bool>()
                .prop_map(|b| (vec![b as u8], ParamValue::Bool(b)))
                .boxed(),
            Shape::U8 => any::<[u8; 1]>().prop_map(move |b| num(b.to_vec())).boxed(),
            Shape::U16 => any::<[u8; 2]>().prop_map(move |b| num(b.to_vec())).boxed(),
            Shape::U32 => any::<[u8; 4]>().prop_map(move |b| num(b.to_vec())).boxed(),
            Shape::U64 | Shape::RawPtr => any::<[u8; 8]>().prop_map(|b| uint(b.to_vec())).boxed(),
            Shape::U128 => any::<[u8; 16]>().prop_map(|b| uint(b.to_vec())).boxed(),
            Shape::U256 => any::<[u8; 32]>().prop_map(|b| uint(b.to_vec())).boxed(),
            Shape::B256 => any::<[u8; 32]>().prop_map(|b| hex(b.to_vec())).boxed(),
            Shape::B512 => prop::collection::vec(any::<u8>(), 64).prop_map(hex).boxed(),
            Shape::StrArray(n) => prop::collection::vec(0x20u8..0x7f, n)
                .prop_map(|b| {
                    let s = String::from_utf8(b.clone()).unwrap();
                    (b, ParamValue::Str(s))
                })
                .boxed(),
            Shape::Str | Shape::String => any::<String>()
                .prop_map(|s| (length_prefixed(s.len(), s.bytes()), ParamValue::Str(s)))
                .boxed(),
            Shape::Bytes => prop::collection::vec(any::<u8>(), 0..8)
                .prop_map(|b| (length_prefixed(b.len(), b.clone()), ParamValue::Bytes(b)))
                .boxed(),
            Shape::RawSlice => prop::collection::vec(any::<u8>(), 0..8)
                .prop_map(|b| {
                    let values = b.iter().map(|x| ParamValue::Num(f64::from(*x))).collect();
                    (length_prefixed(b.len(), b), ParamValue::Arr(values))
                })
                .boxed(),
            Shape::Array(element, n) => prop::collection::vec(sample(&element), n)
                .prop_map(|samples| {
                    let (bytes, values) = concat(samples);
                    (bytes, ParamValue::Arr(values))
                })
                .boxed(),
            Shape::Vec(element) => prop::collection::vec(sample(&element), 0..4)
                .prop_map(|samples| {
                    let len = samples.len();
                    let (bytes, values) = concat(samples);
                    (length_prefixed(len, bytes), ParamValue::Arr(values))
                })
                .boxed(),
            Shape::Option(some) => prop_oneof![
                Just(enum_value(
                    0,
                    "None".into(),
                    (vec![], ParamValue::Undefined)
                )),
                sample(&some).prop_map(|s| enum_value(1, "Some".into(), s)),
            ]
            .boxed(),
            Shape::Tuple(items) => fields(&items, |_| String::new())
                .prop_map(|samples| {
                    let (bytes, values) = concat(samples.into_iter().map(|(_, s)| s).collect());
                    (bytes, ParamValue::Arr(values))
                })
                .boxed(),
            Shape::Struct(shapes) => fields(&shapes, |i| format!("f{i}"))
                .prop_map(|samples| {
                    let names: Vec<_> = samples.iter().map(|(n, _)| n.clone()).collect();
                    let (bytes, values) = concat(samples.into_iter().map(|(_, s)| s).collect());
                    (bytes, obj(names.into_iter().zip(values).collect()))
                })
                .boxed(),
            Shape::Enum(variants) => {
                let cases: Vec<_> = variants
                    .iter()
                    .enumerate()
                    .map(|(i, v)| {
                        sample(v)
                            .prop_map(move |s| enum_value(i, format!("V{i}"), s))
                            .boxed()
                    })
                    .collect();
                prop::strategy::Union::new(cases).boxed()
            }
            Shape::Wrapper(value) => (sample(&value), prop::collection::vec(sample(&value), 0..3))
                .prop_map(|((value_bytes, value), list)| {
                    let len = list.len();
                    let (list_bytes, list) = concat(list);
                    let mut bytes = value_bytes;
                    bytes.extend(length_prefixed(len, list_bytes));
                    (
                        bytes,
                        obj(vec![
                            ("value".into(), value),
                            ("list".into(), ParamValue::Arr(list)),
                        ]),
                    )
                })
                .boxed(),
            Shape::Result(ok, err) => prop_oneof![
                sample(&ok).prop_map(|s| enum_value(0, "Ok".into(), s)),
                sample(&err).prop_map(|s| enum_value(1, "Err".into(), s)),
            ]
            .boxed(),
        }
    }

    fn shape_with_sample() -> impl Strategy<Value = (Shape, Sample)> {
        shape().prop_flat_map(|shape| (Just(shape.clone()), sample(&shape)))
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(2000))]

        #[test]
        fn decodes_every_shape((shape, (bytes, expected)) in shape_with_sample()) {
            let decoder = LogDecoder::new(abi_logging(&shape), LOG_ID).unwrap();
            prop_assert_eq!(decoder.decode(&bytes).unwrap(), expected);
            for len in 0..bytes.len() {
                prop_assert!(decoder.decode(&bytes[..len]).is_err(), "prefix of {} bytes decoded", len);
            }
        }
    }

    #[test]
    fn resolves_every_logged_type_of_a_forc_abi() {
        let raw = include_str!("../../../../scenarios/fuel_test/abis/all-events-abi.json");
        let abi: serde_json::Value = serde_json::from_str(raw).unwrap();
        let log_ids: Vec<String> = abi["loggedTypes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|l| l["logId"].as_str().unwrap().to_string())
            .collect();
        let failed: Vec<_> = log_ids
            .iter()
            .filter_map(|id| {
                LogDecoder::new(abi.clone(), id)
                    .err()
                    .map(|e| format!("{id}: {e:#}"))
            })
            .collect();
        assert_eq!(failed, Vec::<String>::new());
    }

    #[test]
    fn rejects_an_unknown_log_id() {
        let err = LogDecoder::new(abi_logging(&Shape::U8), "1").err().unwrap();
        assert_eq!(
            err.to_string(),
            "Log type with logId '1' doesn't exist in the ABI"
        );
    }

    #[test]
    fn rejects_invalid_bool_and_enum_case() {
        let bool_decoder = LogDecoder::new(abi_logging(&Shape::Bool), LOG_ID).unwrap();
        let option_decoder =
            LogDecoder::new(abi_logging(&Shape::Option(Box::new(Shape::U8))), LOG_ID).unwrap();
        assert_eq!(
            (
                bool_decoder.decode(&[2]).unwrap_err().to_string(),
                option_decoder
                    .decode(&2u64.to_be_bytes())
                    .unwrap_err()
                    .to_string(),
            ),
            (
                "invalid bool value 2".to_string(),
                "invalid enum case 2, expected one of 2 variants".to_string(),
            )
        );
    }
}
