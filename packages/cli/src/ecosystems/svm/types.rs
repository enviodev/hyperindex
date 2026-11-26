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

pub(crate) fn hex_to_bytes(input: &str) -> Result<Vec<u8>> {
    crate::hex::decode_optionally_prefixed(input, "hex string")
}

/// Parse base58 filter values into the wire byte newtypes. A typo'd pubkey is
/// rejected here rather than silently matching nothing on the server.
pub(crate) fn parse_values<T>(values: Option<Vec<String>>, field: &str) -> Result<Vec<T>>
where
    T: std::str::FromStr,
    T::Err: std::fmt::Display,
{
    values
        .unwrap_or_default()
        .into_iter()
        .map(|value| {
            value
                .parse::<T>()
                .map_err(|e| anyhow::anyhow!("{e}"))
                .with_context(|| format!("parse {field} filter value {value:?}"))
        })
        .collect()
}
