use std::ffi::CString;

use napi::bindgen_prelude::{BigInt, FromNapiValue, Null, ToNapiValue, Uint8Array};

/// A decoded parameter tree crossing the napi boundary as real JS values, so
/// wide integers arrive as `bigint` instead of decimal strings.
#[derive(Debug, Clone, PartialEq)]
pub enum ParamValue {
    Bool(bool),
    /// Magnitude as little-endian 64-bit limbs; `sign_bit` set means negative.
    BigInt {
        sign_bit: bool,
        words: Vec<u64>,
    },
    Num(f64),
    Str(String),
    Bytes(Vec<u8>),
    Arr(Vec<ParamValue>),
    Obj(Vec<(String, ParamValue)>),
    Null,
}

impl ParamValue {
    pub fn from_u128(v: u128) -> Self {
        ParamValue::BigInt {
            sign_bit: false,
            words: vec![v as u64, (v >> 64) as u64],
        }
    }

    pub fn from_i128(v: i128) -> Self {
        let magnitude = v.unsigned_abs();
        ParamValue::BigInt {
            sign_bit: v < 0,
            words: vec![magnitude as u64, (magnitude >> 64) as u64],
        }
    }
}

impl FromNapiValue for ParamValue {
    unsafe fn from_napi_value(
        _env: napi::sys::napi_env,
        _val: napi::sys::napi_value,
    ) -> napi::Result<Self> {
        Err(napi::Error::from_reason(
            "ParamValue is decode-only; it cannot be constructed from JS",
        ))
    }
}

impl ToNapiValue for ParamValue {
    unsafe fn to_napi_value(
        raw_env: napi::sys::napi_env,
        val: Self,
    ) -> napi::Result<napi::sys::napi_value> {
        match val {
            ParamValue::Bool(v) => bool::to_napi_value(raw_env, v),
            ParamValue::BigInt { sign_bit, words } => {
                BigInt::to_napi_value(raw_env, BigInt { sign_bit, words })
            }
            ParamValue::Num(v) => f64::to_napi_value(raw_env, v),
            ParamValue::Str(v) => String::to_napi_value(raw_env, v),
            ParamValue::Bytes(v) => Uint8Array::to_napi_value(raw_env, Uint8Array::from(v)),
            ParamValue::Arr(items) => Vec::<ParamValue>::to_napi_value(raw_env, items),
            ParamValue::Obj(entries) => {
                let mut obj = std::ptr::null_mut();
                assert_eq!(
                    napi::sys::napi_create_object(raw_env, &mut obj),
                    napi::sys::Status::napi_ok
                );
                for (key, val) in entries {
                    let js_val = ParamValue::to_napi_value(raw_env, val)?;
                    let c_key = CString::new(key)
                        .map_err(|_| napi::Error::from_reason("invalid param name"))?;
                    assert_eq!(
                        napi::sys::napi_set_named_property(raw_env, obj, c_key.as_ptr(), js_val),
                        napi::sys::Status::napi_ok,
                    );
                }
                Ok(obj)
            }
            ParamValue::Null => Null::to_napi_value(raw_env, Null),
        }
    }
}
