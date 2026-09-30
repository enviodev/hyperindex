use napi::bindgen_prelude::{ToNapiValue, Uint8Array};
use napi::{check_status, sys};

/// A decoded value that crosses to JS by emitting itself into a `Sink`, so
/// the JS values are built straight from the decoder's own representation
/// with no intermediate tree allocated and freed per item.
pub trait Emit {
    fn emit<S: Sink>(&self, sink: &mut S) -> Option<S::Value>;

    /// Whether `emit` succeeds, checked without building anything: the
    /// routing-time accept/reject for decoders whose output is only fully
    /// validated by walking it.
    fn is_valid(&self) -> bool {
        self.emit(&mut Validate).is_some()
    }
}

/// Where an `Emit` walk writes. Every method returns `None` to stop the walk:
/// `Validate` never does, so a `None` from it is always the data's fault.
pub trait Sink {
    type Value;
    type Arr;
    type Obj;
    fn undefined(&mut self) -> Option<Self::Value>;
    fn null(&mut self) -> Option<Self::Value>;
    fn bool(&mut self, value: bool) -> Option<Self::Value>;
    fn num(&mut self, value: f64) -> Option<Self::Value>;
    /// `words` is the magnitude as little-endian 64-bit words.
    fn bigint(&mut self, negative: bool, words: &[u64]) -> Option<Self::Value>;
    fn str(&mut self, value: &str) -> Option<Self::Value>;
    /// `bytes` as a `0x`-prefixed lowercase hex string.
    fn hex(&mut self, bytes: &[u8]) -> Option<Self::Value>;
    /// `bytes` as a `Uint8Array`.
    fn bytes(&mut self, bytes: &[u8]) -> Option<Self::Value>;
    fn arr(&mut self, len: usize) -> Option<Self::Arr>;
    fn push(&mut self, arr: &mut Self::Arr, value: Self::Value) -> Option<()>;
    fn end_arr(&mut self, arr: Self::Arr) -> Self::Value;
    fn obj(&mut self) -> Option<Self::Obj>;
    fn set(&mut self, obj: &mut Self::Obj, key: &str, value: Self::Value) -> Option<()>;
    fn end_obj(&mut self, obj: Self::Obj) -> Self::Value;
}

/// Crosses the napi boundary as the JS value `T` emits.
pub struct ToJs<T>(pub T);

impl<T: Emit> ToNapiValue for ToJs<T> {
    unsafe fn to_napi_value(env: sys::napi_env, val: Self) -> napi::Result<sys::napi_value> {
        let mut js = JsSink { env, error: None };
        val.0.emit(&mut js).ok_or_else(|| {
            js.error.take().unwrap_or_else(|| {
                napi::Error::from_reason("a decoded value stopped emitting after it validated")
            })
        })
    }
}

/// Walks a value without building anything.
struct Validate;

impl Sink for Validate {
    type Value = ();
    type Arr = ();
    type Obj = ();
    fn undefined(&mut self) -> Option<()> {
        Some(())
    }
    fn null(&mut self) -> Option<()> {
        Some(())
    }
    fn bool(&mut self, _: bool) -> Option<()> {
        Some(())
    }
    fn num(&mut self, _: f64) -> Option<()> {
        Some(())
    }
    fn bigint(&mut self, _: bool, _: &[u64]) -> Option<()> {
        Some(())
    }
    fn str(&mut self, _: &str) -> Option<()> {
        Some(())
    }
    fn hex(&mut self, _: &[u8]) -> Option<()> {
        Some(())
    }
    fn bytes(&mut self, _: &[u8]) -> Option<()> {
        Some(())
    }
    fn arr(&mut self, _: usize) -> Option<()> {
        Some(())
    }
    fn push(&mut self, _: &mut (), _: ()) -> Option<()> {
        Some(())
    }
    fn end_arr(&mut self, _: ()) {}
    fn obj(&mut self) -> Option<()> {
        Some(())
    }
    fn set(&mut self, _: &mut (), _: &str, _: ()) -> Option<()> {
        Some(())
    }
    fn end_obj(&mut self, _: ()) {}
}

/// Builds JS values in place. A `None` means a napi call failed, with its
/// error in `error`.
struct JsSink {
    env: sys::napi_env,
    error: Option<napi::Error>,
}

/// Hex strings up to this many bytes (a B512's included) are built on the
/// stack.
const HEX_BUF: usize = 160;

/// Keys shorter than this are NUL-terminated on the stack. Kept small: the
/// buffer is zeroed once per property set.
const KEY_BUF: usize = 64;

impl JsSink {
    fn ok<T>(&mut self, result: napi::Result<T>) -> Option<T> {
        result.map_err(|e| self.error = Some(e)).ok()
    }

    fn new_value(
        &mut self,
        create: impl FnOnce(sys::napi_env, *mut sys::napi_value) -> sys::napi_status,
    ) -> Option<sys::napi_value> {
        let mut value = std::ptr::null_mut();
        let status = create(self.env, &mut value);
        self.ok(check_status!(status)).map(|()| value)
    }
}

// SAFETY (all `unsafe` below): `env` is the live env `ToJs::to_napi_value`
// was called with, and every pointer passed to napi outlives the call.
impl Sink for JsSink {
    type Value = sys::napi_value;
    type Arr = (sys::napi_value, u32);
    type Obj = sys::napi_value;

    fn undefined(&mut self) -> Option<sys::napi_value> {
        self.new_value(|env, out| unsafe { sys::napi_get_undefined(env, out) })
    }
    fn null(&mut self) -> Option<sys::napi_value> {
        self.new_value(|env, out| unsafe { sys::napi_get_null(env, out) })
    }
    fn bool(&mut self, value: bool) -> Option<sys::napi_value> {
        self.new_value(|env, out| unsafe { sys::napi_get_boolean(env, value, out) })
    }
    fn num(&mut self, value: f64) -> Option<sys::napi_value> {
        self.new_value(|env, out| unsafe { sys::napi_create_double(env, value, out) })
    }
    fn bigint(&mut self, negative: bool, words: &[u64]) -> Option<sys::napi_value> {
        let len = words.iter().rposition(|w| *w != 0).map_or(0, |i| i + 1);
        let words = &words[..len];
        match (negative, words) {
            (false, []) => {
                self.new_value(|env, out| unsafe { sys::napi_create_bigint_uint64(env, 0, out) })
            }
            (false, [word]) => self
                .new_value(|env, out| unsafe { sys::napi_create_bigint_uint64(env, *word, out) }),
            _ => self.new_value(|env, out| unsafe {
                sys::napi_create_bigint_words(
                    env,
                    i32::from(negative),
                    words.len(),
                    words.as_ptr(),
                    out,
                )
            }),
        }
    }
    fn str(&mut self, value: &str) -> Option<sys::napi_value> {
        self.new_value(|env, out| unsafe {
            sys::napi_create_string_utf8(env, value.as_ptr().cast(), value.len() as isize, out)
        })
    }
    // Inlined, the stack buffer lands in the frame of every recursive decode
    // step that could reach it, which measurably slows the whole walk.
    #[inline(never)]
    fn hex(&mut self, bytes: &[u8]) -> Option<sys::napi_value> {
        let len = 2 + bytes.len() * 2;
        let mut stack = [0u8; HEX_BUF];
        let mut heap = Vec::new();
        let buf = if len <= HEX_BUF {
            &mut stack[..len]
        } else {
            heap.resize(len, 0);
            &mut heap[..]
        };
        buf[..2].copy_from_slice(b"0x");
        faster_hex::hex_encode(bytes, &mut buf[2..]).ok()?;
        self.str(std::str::from_utf8(buf).ok()?)
    }
    fn bytes(&mut self, bytes: &[u8]) -> Option<sys::napi_value> {
        let array = Uint8Array::from(bytes.to_vec());
        let result = unsafe { Uint8Array::to_napi_value(self.env, array) };
        self.ok(result)
    }
    fn arr(&mut self, len: usize) -> Option<(sys::napi_value, u32)> {
        let arr = self
            .new_value(|env, out| unsafe { sys::napi_create_array_with_length(env, len, out) })?;
        Some((arr, 0))
    }
    fn push(&mut self, arr: &mut (sys::napi_value, u32), value: sys::napi_value) -> Option<()> {
        let status = unsafe { sys::napi_set_element(self.env, arr.0, arr.1, value) };
        arr.1 += 1;
        self.ok(check_status!(status))
    }
    fn end_arr(&mut self, arr: (sys::napi_value, u32)) -> sys::napi_value {
        arr.0
    }
    fn obj(&mut self) -> Option<sys::napi_value> {
        self.new_value(|env, out| unsafe { sys::napi_create_object(env, out) })
    }
    /// V8 interns the keys `napi_set_named_property` takes, which makes it
    /// the fastest way to set a property; it wants a NUL-terminated key, so
    /// a key that doesn't fit the stack buffer or holds a NUL goes through a
    /// JS string instead.
    fn set(&mut self, obj: &mut sys::napi_value, key: &str, value: sys::napi_value) -> Option<()> {
        let obj = *obj;
        let mut buf = [0u8; KEY_BUF];
        let status = if key.len() < KEY_BUF && !key.as_bytes().contains(&0) {
            buf[..key.len()].copy_from_slice(key.as_bytes());
            unsafe { sys::napi_set_named_property(self.env, obj, buf.as_ptr().cast(), value) }
        } else {
            let key = self.str(key)?;
            unsafe { sys::napi_set_property(self.env, obj, key, value) }
        };
        self.ok(check_status!(status))
    }
    fn end_obj(&mut self, obj: sys::napi_value) -> sys::napi_value {
        obj
    }
}

#[cfg(test)]
pub(crate) mod test_value {
    use super::{Emit, Sink};
    use ruint::aliases::U256;
    use ruint::UintTryFrom;

    /// The JS value an `Emit` produces, for Rust tests to assert on.
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
        pub(crate) fn of(value: &impl Emit) -> Self {
            value.emit(&mut Tree).expect("emit a test value")
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

    struct Tree;

    impl Sink for Tree {
        type Value = JsValue;
        type Arr = Vec<JsValue>;
        type Obj = Vec<(String, JsValue)>;
        fn undefined(&mut self) -> Option<JsValue> {
            Some(JsValue::Undefined)
        }
        fn null(&mut self) -> Option<JsValue> {
            Some(JsValue::Null)
        }
        fn bool(&mut self, value: bool) -> Option<JsValue> {
            Some(JsValue::Bool(value))
        }
        fn num(&mut self, value: f64) -> Option<JsValue> {
            Some(JsValue::Num(value))
        }
        fn bigint(&mut self, negative: bool, words: &[u64]) -> Option<JsValue> {
            Some(JsValue::BigInt {
                negative,
                magnitude: U256::checked_from_limbs_slice(words)?,
            })
        }
        fn str(&mut self, value: &str) -> Option<JsValue> {
            Some(JsValue::str(value))
        }
        fn hex(&mut self, bytes: &[u8]) -> Option<JsValue> {
            Some(JsValue::Str(format!("0x{}", faster_hex::hex_string(bytes))))
        }
        fn bytes(&mut self, bytes: &[u8]) -> Option<JsValue> {
            Some(JsValue::Bytes(bytes.to_vec()))
        }
        fn arr(&mut self, len: usize) -> Option<Vec<JsValue>> {
            Some(Vec::with_capacity(len))
        }
        fn push(&mut self, arr: &mut Vec<JsValue>, value: JsValue) -> Option<()> {
            arr.push(value);
            Some(())
        }
        fn end_arr(&mut self, arr: Vec<JsValue>) -> JsValue {
            JsValue::Arr(arr)
        }
        fn obj(&mut self) -> Option<Vec<(String, JsValue)>> {
            Some(Vec::new())
        }
        fn set(
            &mut self,
            obj: &mut Vec<(String, JsValue)>,
            key: &str,
            value: JsValue,
        ) -> Option<()> {
            obj.push((key.to_string(), value));
            Some(())
        }
        fn end_obj(&mut self, obj: Vec<(String, JsValue)>) -> JsValue {
            JsValue::Obj(obj)
        }
    }
}
