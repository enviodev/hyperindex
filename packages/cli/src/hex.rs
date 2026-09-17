use anyhow::{Context, Result};

/// Either spelling of the prefix, so the same notation is read the same way
/// wherever it arrives.
pub(crate) fn strip_prefix(s: &str) -> Option<&str> {
    s.strip_prefix("0x").or_else(|| s.strip_prefix("0X"))
}

fn decode_digits(digits: &str, source: &str, name: &str) -> Result<Vec<u8>> {
    if !digits.len().is_multiple_of(2) {
        anyhow::bail!("{name} '{source}' must have an even number of hex digits");
    }
    let mut out = vec![0u8; digits.len() / 2];
    faster_hex::hex_decode(digits.as_bytes(), &mut out)
        .with_context(|| format!("{name} '{source}' is not valid hex"))?;
    Ok(out)
}

/// Strictly decode a prefixed even-length hex string; anything else (e.g. an
/// arbitrary marker string) is a validation error.
pub(crate) fn decode_prefixed(s: &str, name: &str) -> Result<Vec<u8>> {
    let digits = strip_prefix(s)
        .with_context(|| format!("{name} '{s}' must be a 0x-prefixed hex string"))?;
    decode_digits(digits, s, name)
}

/// Decode hex that may or may not carry the `0x` prefix — SVM discriminators
/// are written both ways in user config.
pub(crate) fn decode_optionally_prefixed(s: &str, name: &str) -> Result<Vec<u8>> {
    decode_digits(strip_prefix(s).unwrap_or(s), s, name)
}

/// Encode bytes as a `0x`-prefixed lowercase hex string. The SVM wire's `dN`
/// filters take this form.
pub(crate) fn to_hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(2 + bytes.len() * 2);
    s.push_str("0x");
    s.push_str(&faster_hex::hex_string(bytes));
    s
}

/// Decode exactly `len` bytes of `0x`-prefixed hex, or `None` when the string
/// isn't that. Callers treat it as "not a well-formed value" rather than an
/// error to surface.
pub(crate) fn decode_fixed(s: &str, len: usize) -> Option<Vec<u8>> {
    let hex = strip_prefix(s)?;
    if hex.len() != len * 2 {
        return None;
    }
    let mut out = vec![0u8; len];
    faster_hex::hex_decode(hex.as_bytes(), &mut out).ok()?;
    Some(out)
}

/// Lowercase hex digits, no `0x` prefix.
pub(crate) fn encode(bytes: &[u8]) -> String {
    faster_hex::hex_string(bytes)
}
