use napi::bindgen_prelude::{FromNapiValue, ToNapiValue};
use napi::{check_status, sys};

/// A JS value recorded as a flat byte tape. Decoders write it on the worker
/// thread, where every conversion (hex, checksums, base58, bigint limbs)
/// happens; crossing to JS replays it on the main thread as one sequential
/// read, so that thread does nothing but create the JS values.
///
/// Arrays and objects are written as their length followed by their
/// elements; an object's elements are key-value pairs, key first.
#[derive(Clone, Default)]
pub struct JsTape(Vec<u8>);

const UNDEFINED: u8 = 0;
const NULL: u8 = 1;
const FALSE: u8 = 2;
const TRUE: u8 = 3;
const NUM: u8 = 4;
const BIGINT: u8 = 5;
const STR: u8 = 6;
const BYTES: u8 = 7;
const ARR: u8 = 8;
const OBJ: u8 = 9;

/// A key NUL-terminated in the tape, so the replay can hand napi a pointer
/// straight into it; a key holding a NUL itself is length-prefixed instead.
const NAMED_KEY: u8 = 0;
const STR_KEY: u8 = 1;

/// Magnitudes wider than 256 bits don't occur in any ecosystem's ABI.
const MAX_BIGINT_WORDS: usize = 4;

impl JsTape {
    pub fn new() -> Self {
        Self::default()
    }

    fn tag(&mut self, tag: u8) {
        self.0.push(tag);
    }

    fn u64(&mut self, value: u64) {
        self.0.extend_from_slice(&value.to_le_bytes());
    }

    fn len_prefixed(&mut self, tag: u8, bytes: &[u8]) {
        self.tag(tag);
        self.u64(bytes.len() as u64);
        self.0.extend_from_slice(bytes);
    }

    pub fn undefined(&mut self) {
        self.tag(UNDEFINED);
    }

    pub fn null(&mut self) {
        self.tag(NULL);
    }

    pub fn bool(&mut self, value: bool) {
        self.tag(if value { TRUE } else { FALSE });
    }

    pub fn num(&mut self, value: f64) {
        self.tag(NUM);
        self.0.extend_from_slice(&value.to_le_bytes());
    }

    /// `words` is the magnitude as little-endian 64-bit words, at most four.
    pub fn bigint(&mut self, negative: bool, words: &[u64]) {
        let len = words.iter().rposition(|w| *w != 0).map_or(0, |i| i + 1);
        assert!(len <= MAX_BIGINT_WORDS, "bigint wider than 256 bits");
        self.tag(BIGINT);
        self.0.push(u8::from(negative));
        self.0.push(len as u8);
        for word in &words[..len] {
            self.u64(*word);
        }
    }

    pub fn str(&mut self, value: &str) {
        self.len_prefixed(STR, value.as_bytes());
    }

    /// `bytes` as a `0x`-prefixed lowercase hex string.
    pub fn hex(&mut self, bytes: &[u8]) {
        self.tag(STR);
        self.u64(2 + 2 * bytes.len() as u64);
        let start = self.0.len();
        self.0.resize(start + 2 + 2 * bytes.len(), 0);
        self.0[start..start + 2].copy_from_slice(b"0x");
        faster_hex::hex_encode(bytes, &mut self.0[start + 2..])
            .expect("the buffer is sized for the hex");
    }

    /// `bytes` as a `Uint8Array`.
    pub fn bytes(&mut self, bytes: &[u8]) {
        self.len_prefixed(BYTES, bytes);
    }

    /// An array of the `len` values written next.
    pub fn arr(&mut self, len: usize) {
        self.tag(ARR);
        self.u64(len as u64);
    }

    /// An object of the `len` key-value pairs written next.
    pub fn obj(&mut self, len: usize) {
        self.tag(OBJ);
        self.u64(len as u64);
    }

    /// `value` as the next value; a tape holds exactly one value, so its bytes
    /// splice in as one.
    pub fn embed(&mut self, value: &JsTape) {
        self.0.extend_from_slice(&value.0);
    }

    /// The key of the object entry whose value is written next.
    pub fn key(&mut self, key: &str) {
        if key.as_bytes().contains(&0) {
            self.len_prefixed(STR_KEY, key.as_bytes());
        } else {
            self.len_prefixed(NAMED_KEY, key.as_bytes());
            self.0.push(0);
        }
    }

    fn read(&self) -> Reader<'_> {
        Reader(&self.0)
    }
}

/// One value's or key's worth of tape.
enum Token<'a> {
    Undefined,
    Null,
    Bool(bool),
    Num(f64),
    BigInt {
        negative: bool,
        words: [u64; MAX_BIGINT_WORDS],
        len: usize,
    },
    Str(&'a [u8]),
    Bytes(&'a [u8]),
    Arr(usize),
    Obj(usize),
}

enum Key<'a> {
    /// The key's bytes followed by their NUL terminator.
    Named(&'a [u8]),
    Str(&'a [u8]),
}

struct Reader<'a>(&'a [u8]);

fn corrupt() -> napi::Error {
    napi::Error::from_reason("a JS value tape ended early or holds an unknown tag")
}

impl<'a> Reader<'a> {
    fn take(&mut self, len: usize) -> napi::Result<&'a [u8]> {
        let (head, tail) = self.0.split_at_checked(len).ok_or_else(corrupt)?;
        self.0 = tail;
        Ok(head)
    }

    fn byte(&mut self) -> napi::Result<u8> {
        Ok(self.take(1)?[0])
    }

    fn u64(&mut self) -> napi::Result<u64> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }

    fn len(&mut self) -> napi::Result<usize> {
        usize::try_from(self.u64()?).map_err(|_| corrupt())
    }

    fn token(&mut self) -> napi::Result<Token<'a>> {
        Ok(match self.byte()? {
            UNDEFINED => Token::Undefined,
            NULL => Token::Null,
            FALSE => Token::Bool(false),
            TRUE => Token::Bool(true),
            NUM => Token::Num(f64::from_bits(self.u64()?)),
            BIGINT => {
                let negative = self.byte()? != 0;
                let len = usize::from(self.byte()?);
                let mut words = [0; MAX_BIGINT_WORDS];
                for word in words.get_mut(..len).ok_or_else(corrupt)? {
                    *word = self.u64()?;
                }
                Token::BigInt {
                    negative,
                    words,
                    len,
                }
            }
            STR => {
                let len = self.len()?;
                Token::Str(self.take(len)?)
            }
            BYTES => {
                let len = self.len()?;
                Token::Bytes(self.take(len)?)
            }
            ARR => Token::Arr(self.len()?),
            OBJ => Token::Obj(self.len()?),
            _ => return Err(corrupt()),
        })
    }

    fn key(&mut self) -> napi::Result<Key<'a>> {
        let tag = self.byte()?;
        let len = self.len()?;
        Ok(match tag {
            NAMED_KEY => Key::Named(self.take(len + 1)?),
            STR_KEY => Key::Str(self.take(len)?),
            _ => return Err(corrupt()),
        })
    }
}

impl ToNapiValue for JsTape {
    unsafe fn to_napi_value(env: sys::napi_env, val: Self) -> napi::Result<sys::napi_value> {
        let mut reader = val.read();
        let value = Replay { env }.value(&mut reader)?;
        match reader.0 {
            [] => Ok(value),
            _ => Err(corrupt()),
        }
    }
}

/// Records a JS value made of plain data: primitives, bigints, strings,
/// Uint8Arrays (Buffers included), arrays and objects' own enumerable string
/// keys. Anything else (functions, symbols, class instances' prototypes) has
/// no tape form and is refused, so a value can't silently lose a part.
impl FromNapiValue for JsTape {
    unsafe fn from_napi_value(env: sys::napi_env, value: sys::napi_value) -> napi::Result<Self> {
        let mut tape = JsTape::new();
        Record { env }.value(&mut tape, value, 0)?;
        Ok(tape)
    }
}

/// Deep enough for any payload; a cycle runs into it instead of overflowing
/// the stack.
const MAX_RECORD_DEPTH: usize = 64;

struct Record {
    env: sys::napi_env,
}

fn unrecordable(what: &str) -> napi::Error {
    napi::Error::from_reason(format!("a {what} can't be stored as a JS value tape"))
}

// SAFETY (all `unsafe` below): `env` is the live env `from_napi_value` was
// called with, `value` a handle valid for that call, and every out pointer
// points at a local that outlives the napi call writing it.
impl Record {
    fn value(&self, tape: &mut JsTape, value: sys::napi_value, depth: usize) -> napi::Result<()> {
        if depth > MAX_RECORD_DEPTH {
            return Err(unrecordable("value nested this deep (or cyclic)"));
        }
        let mut kind = 0;
        check_status!(unsafe { sys::napi_typeof(self.env, value, &mut kind) })?;
        match kind {
            sys::ValueType::napi_undefined => tape.undefined(),
            sys::ValueType::napi_null => tape.null(),
            sys::ValueType::napi_boolean => {
                let mut out = false;
                check_status!(unsafe { sys::napi_get_value_bool(self.env, value, &mut out) })?;
                tape.bool(out);
            }
            sys::ValueType::napi_number => {
                let mut out = 0.0;
                check_status!(unsafe { sys::napi_get_value_double(self.env, value, &mut out) })?;
                tape.num(out);
            }
            sys::ValueType::napi_string => tape.str(&self.string(value)?),
            sys::ValueType::napi_bigint => self.bigint(tape, value)?,
            sys::ValueType::napi_object => self.object(tape, value, depth)?,
            sys::ValueType::napi_symbol => return Err(unrecordable("symbol")),
            sys::ValueType::napi_function => return Err(unrecordable("function")),
            _ => return Err(unrecordable("external value")),
        }
        Ok(())
    }

    fn string(&self, value: sys::napi_value) -> napi::Result<String> {
        let mut len = 0;
        check_status!(unsafe {
            sys::napi_get_value_string_utf8(self.env, value, std::ptr::null_mut(), 0, &mut len)
        })?;
        let mut bytes = vec![0u8; len + 1];
        check_status!(unsafe {
            sys::napi_get_value_string_utf8(
                self.env,
                value,
                bytes.as_mut_ptr().cast(),
                bytes.len(),
                &mut len,
            )
        })?;
        bytes.truncate(len);
        String::from_utf8(bytes).map_err(|_| unrecordable("string that isn't UTF-8"))
    }

    fn bigint(&self, tape: &mut JsTape, value: sys::napi_value) -> napi::Result<()> {
        // Only a call with neither a sign nor a words pointer reports the
        // word count alone.
        let mut count = 0;
        check_status!(unsafe {
            sys::napi_get_value_bigint_words(
                self.env,
                value,
                std::ptr::null_mut(),
                &mut count,
                std::ptr::null_mut(),
            )
        })?;
        let mut sign = 0;
        if count > MAX_BIGINT_WORDS {
            return Err(unrecordable("bigint wider than 256 bits"));
        }
        let mut words = [0u64; MAX_BIGINT_WORDS];
        check_status!(unsafe {
            sys::napi_get_value_bigint_words(
                self.env,
                value,
                &mut sign,
                &mut count,
                words.as_mut_ptr(),
            )
        })?;
        tape.bigint(sign != 0, &words[..count]);
        Ok(())
    }

    fn object(&self, tape: &mut JsTape, value: sys::napi_value, depth: usize) -> napi::Result<()> {
        let mut is_typed_array = false;
        check_status!(unsafe { sys::napi_is_typedarray(self.env, value, &mut is_typed_array) })?;
        if is_typed_array {
            let mut kind = 0;
            let mut len = 0;
            let mut data = std::ptr::null_mut();
            check_status!(unsafe {
                sys::napi_get_typedarray_info(
                    self.env,
                    value,
                    &mut kind,
                    &mut len,
                    &mut data,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                )
            })?;
            if kind != sys::TypedarrayType::uint8_array {
                return Err(unrecordable("typed array other than Uint8Array"));
            }
            let bytes: &[u8] = if len == 0 {
                &[]
            } else {
                unsafe { std::slice::from_raw_parts(data.cast(), len) }
            };
            tape.bytes(bytes);
            return Ok(());
        }

        let mut is_array = false;
        check_status!(unsafe { sys::napi_is_array(self.env, value, &mut is_array) })?;
        if is_array {
            let mut len = 0;
            check_status!(unsafe { sys::napi_get_array_length(self.env, value, &mut len) })?;
            tape.arr(len as usize);
            for index in 0..len {
                let mut element = std::ptr::null_mut();
                check_status!(unsafe {
                    sys::napi_get_element(self.env, value, index, &mut element)
                })?;
                self.value(tape, element, depth + 1)?;
            }
            return Ok(());
        }

        let mut keys = std::ptr::null_mut();
        check_status!(unsafe {
            sys::napi_get_all_property_names(
                self.env,
                value,
                sys::KeyCollectionMode::own_only,
                sys::KeyFilter::enumerable | sys::KeyFilter::skip_symbols,
                sys::KeyConversion::numbers_to_strings,
                &mut keys,
            )
        })?;
        let mut len = 0;
        check_status!(unsafe { sys::napi_get_array_length(self.env, keys, &mut len) })?;
        tape.obj(len as usize);
        for index in 0..len {
            let mut key = std::ptr::null_mut();
            check_status!(unsafe { sys::napi_get_element(self.env, keys, index, &mut key) })?;
            let mut property = std::ptr::null_mut();
            check_status!(unsafe { sys::napi_get_property(self.env, value, key, &mut property) })?;
            tape.key(&self.string(key)?);
            self.value(tape, property, depth + 1)?;
        }
        Ok(())
    }
}

struct Replay {
    env: sys::napi_env,
}

// SAFETY (all `unsafe` below): `env` is the live env `to_napi_value` was
// called with, and every pointer passed to napi outlives the call.
impl Replay {
    fn new_value(
        &self,
        create: impl FnOnce(sys::napi_env, *mut sys::napi_value) -> sys::napi_status,
    ) -> napi::Result<sys::napi_value> {
        let mut value = std::ptr::null_mut();
        check_status!(create(self.env, &mut value))?;
        Ok(value)
    }

    fn str(&self, bytes: &[u8]) -> napi::Result<sys::napi_value> {
        self.new_value(|env, out| unsafe {
            sys::napi_create_string_utf8(env, bytes.as_ptr().cast(), bytes.len() as isize, out)
        })
    }

    fn value(&self, reader: &mut Reader) -> napi::Result<sys::napi_value> {
        match reader.token()? {
            Token::Undefined => {
                self.new_value(|env, out| unsafe { sys::napi_get_undefined(env, out) })
            }
            Token::Null => self.new_value(|env, out| unsafe { sys::napi_get_null(env, out) }),
            Token::Bool(value) => {
                self.new_value(|env, out| unsafe { sys::napi_get_boolean(env, value, out) })
            }
            Token::Num(value) => {
                self.new_value(|env, out| unsafe { sys::napi_create_double(env, value, out) })
            }
            Token::BigInt {
                negative: false,
                words,
                len: 0 | 1,
            } => self.new_value(|env, out| unsafe {
                sys::napi_create_bigint_uint64(env, words[0], out)
            }),
            Token::BigInt {
                negative,
                words,
                len,
            } => self.new_value(|env, out| unsafe {
                sys::napi_create_bigint_words(env, i32::from(negative), len, words.as_ptr(), out)
            }),
            Token::Str(bytes) => self.str(bytes),
            Token::Bytes(bytes) => {
                let mut data = std::ptr::null_mut();
                let buffer = self.new_value(|env, out| unsafe {
                    sys::napi_create_arraybuffer(env, bytes.len(), &mut data, out)
                })?;
                if !bytes.is_empty() {
                    unsafe {
                        std::ptr::copy_nonoverlapping(bytes.as_ptr(), data.cast(), bytes.len())
                    };
                }
                self.new_value(|env, out| unsafe {
                    sys::napi_create_typedarray(
                        env,
                        sys::TypedarrayType::uint8_array,
                        bytes.len(),
                        buffer,
                        0,
                        out,
                    )
                })
            }
            Token::Arr(len) => {
                let arr = self.new_value(|env, out| unsafe {
                    sys::napi_create_array_with_length(env, len, out)
                })?;
                for index in 0..len {
                    let item = self.value(reader)?;
                    let index = u32::try_from(index).map_err(|_| corrupt())?;
                    check_status!(unsafe { sys::napi_set_element(self.env, arr, index, item) })?;
                }
                Ok(arr)
            }
            Token::Obj(len) => {
                let obj =
                    self.new_value(|env, out| unsafe { sys::napi_create_object(env, out) })?;
                for _ in 0..len {
                    let key = reader.key()?;
                    let value = self.value(reader)?;
                    // `napi_set_named_property` is the fastest way to set a
                    // property: V8 interns the NUL-terminated key.
                    check_status!(match key {
                        Key::Named(key) => unsafe {
                            sys::napi_set_named_property(self.env, obj, key.as_ptr().cast(), value)
                        },
                        Key::Str(key) => {
                            let key = self.str(key)?;
                            unsafe { sys::napi_set_property(self.env, obj, key, value) }
                        }
                    })?;
                }
                Ok(obj)
            }
        }
    }
}

#[cfg(test)]
pub(crate) mod test_value {
    use super::{JsTape, Key, Reader, Token};
    use ruint::aliases::U256;
    use ruint::UintTryFrom;

    /// The JS value a tape replays to, for Rust tests to assert on.
    #[derive(Debug, Clone, PartialEq)]
    pub(crate) enum JsValue {
        Undefined,
        Null,
        Bool(bool),
        Num(f64),
        BigInt { negative: bool, magnitude: U256 },
        Str(String),
        Bytes(Vec<u8>),
        Arr(Vec<JsValue>),
        Obj(Vec<(String, JsValue)>),
    }

    impl JsValue {
        pub(crate) fn of(tape: &JsTape) -> Self {
            let mut reader = tape.read();
            let value = Self::read(&mut reader);
            assert!(reader.0.is_empty(), "the tape holds more than one value");
            value
        }

        fn read(reader: &mut Reader) -> Self {
            let text = |bytes: &[u8]| String::from_utf8(bytes.to_vec()).unwrap();
            match reader.token().unwrap() {
                Token::Undefined => JsValue::Undefined,
                Token::Null => JsValue::Null,
                Token::Bool(value) => JsValue::Bool(value),
                Token::Num(value) => JsValue::Num(value),
                Token::BigInt {
                    negative,
                    words,
                    len,
                } => JsValue::BigInt {
                    negative,
                    magnitude: U256::from_limbs_slice(&words[..len]),
                },
                Token::Str(bytes) => JsValue::Str(text(bytes)),
                Token::Bytes(bytes) => JsValue::Bytes(bytes.to_vec()),
                Token::Arr(len) => JsValue::Arr((0..len).map(|_| Self::read(reader)).collect()),
                Token::Obj(len) => JsValue::Obj(
                    (0..len)
                        .map(|_| {
                            let key = match reader.key().unwrap() {
                                Key::Named(key) => text(&key[..key.len() - 1]),
                                Key::Str(key) => text(key),
                            };
                            (key, Self::read(reader))
                        })
                        .collect(),
                ),
            }
        }

        pub(crate) fn uint<T>(value: T) -> Self
        where
            U256: UintTryFrom<T>,
        {
            JsValue::BigInt {
                negative: false,
                magnitude: U256::from(value),
            }
        }

        pub(crate) fn int(value: i128) -> Self {
            JsValue::BigInt {
                negative: value < 0,
                magnitude: U256::from(value.unsigned_abs()),
            }
        }

        pub(crate) fn str(value: &str) -> Self {
            JsValue::Str(value.to_string())
        }

        pub(crate) fn obj<'a>(entries: impl IntoIterator<Item = (&'a str, JsValue)>) -> Self {
            JsValue::Obj(
                entries
                    .into_iter()
                    .map(|(key, value)| (key.to_string(), value))
                    .collect(),
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_value::JsValue;
    use super::JsTape;
    use ruint::aliases::U256;

    #[test]
    fn reads_back_every_kind_of_value_it_records() {
        let mut tape = JsTape::new();
        tape.obj(3);
        tape.key("scalars");
        tape.arr(6);
        tape.undefined();
        tape.null();
        tape.bool(true);
        tape.num(-1.5);
        tape.bigint(false, &[7, 0, 0, 0]);
        tape.bigint(true, &[1, 2]);
        tape.key("a\0b");
        tape.arr(3);
        tape.str("é");
        tape.hex(&[0xab, 0x01]);
        tape.bytes(&[]);
        tape.key("");
        tape.obj(0);
        assert_eq!(
            JsValue::of(&tape),
            JsValue::obj([
                (
                    "scalars",
                    JsValue::Arr(vec![
                        JsValue::Undefined,
                        JsValue::Null,
                        JsValue::Bool(true),
                        JsValue::Num(-1.5),
                        JsValue::uint(7u64),
                        JsValue::BigInt {
                            negative: true,
                            magnitude: U256::from_limbs([1, 2, 0, 0]),
                        },
                    ])
                ),
                (
                    "a\0b",
                    JsValue::Arr(vec![
                        JsValue::str("é"),
                        JsValue::str("0xab01"),
                        JsValue::Bytes(vec![]),
                    ])
                ),
                ("", JsValue::Obj(vec![])),
            ])
        );
    }
}
