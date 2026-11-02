use anyhow::{Context, Result};
use napi::bindgen_prelude::BigInt;

pub(crate) fn bigint_u64(v: u64) -> BigInt {
    BigInt {
        sign_bit: false,
        words: vec![v],
    }
}

pub(crate) fn required<T>(value: Option<T>, field: &str) -> Result<T> {
    value.with_context(|| format!("{field} missing from the response"))
}
