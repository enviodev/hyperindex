//! serde_json (without `arbitrary_precision`) rounds every non-64-bit-int
//! JSON number through f64, so variable values like
//! `99999999999999999999999` lose digits that Hasura's aeson `Scientific`
//! keeps. After validating the raw JSON grammar without materializing its
//! numbers, tokens whose text cannot round-trip through serde_json's
//! representation are rewritten to unique finite f64 sentinels. The decoder carries the resulting
//! sentinel-bits -> original-text map alongside (never inside) the
//! client-owned variables object, and the coercion layer substitutes the
//! original text back when producing SQL parameters.

use super::coerce::parse_decimal;
use serde_json::value::RawValue;
use serde_json::Value as Json;
use std::collections::{HashMap, HashSet};

struct NumTok {
    start: usize,
    end: usize,
}

/// Finds JSON number tokens in `src`, skipping string contents. Assumes
/// `src` has already been validated as JSON by `RawValue`.
fn number_tokens(src: &str) -> Vec<NumTok> {
    let bytes = src.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'"' => {
                i += 1;
                while i < bytes.len() {
                    match bytes[i] {
                        b'\\' => i += 2,
                        b'"' => {
                            i += 1;
                            break;
                        }
                        _ => i += 1,
                    }
                }
            }
            b'-' | b'0'..=b'9' => {
                let start = i;
                if bytes[i] == b'-' {
                    i += 1;
                }
                while i < bytes.len()
                    && matches!(bytes[i], b'0'..=b'9' | b'.' | b'e' | b'E' | b'+' | b'-')
                {
                    i += 1;
                }
                out.push(NumTok { start, end: i });
            }
            _ => i += 1,
        }
    }
    out
}

/// True when serde_json's parsed representation of `text` reaches SQL with
/// the same numeric value: i64/u64 integers are exact, and an f64 is exact
/// when the shortest decimal form it prints back equals the source text.
fn roundtrips(text: &str) -> bool {
    let is_plain_int = !text.contains(['.', 'e', 'E']);
    if is_plain_int && (text.parse::<i64>().is_ok() || text.parse::<u64>().is_ok()) {
        return true;
    }
    let Ok(f) = text.parse::<f64>() else {
        return false;
    };
    if !f.is_finite() {
        return false;
    }
    match (parse_decimal(text), parse_decimal(&format!("{f}"))) {
        (Some(a), Some(b)) => a == b,
        _ => false,
    }
}

/// Rewrites lossy number tokens in a JSON document to sentinel f64 values.
/// Returns None when every number round-trips as-is.
pub fn rewrite_lossy_numbers(src: &str) -> Option<(String, HashMap<u64, String>)> {
    let toks = number_tokens(src);
    let mut lossy: Vec<&NumTok> = Vec::new();
    let mut taken: HashSet<u64> = HashSet::new();
    for t in &toks {
        let text = &src[t.start..t.end];
        if roundtrips(text) {
            if let Ok(f) = text.parse::<f64>() {
                taken.insert(f.to_bits());
            }
        } else {
            lossy.push(t);
        }
    }
    if lossy.is_empty() {
        return None;
    }

    let mut originals: HashMap<u64, String> = HashMap::new();
    let mut sentinel = f64::MAX;
    let mut out = String::with_capacity(src.len());
    let mut pos = 0;
    for t in lossy {
        // serde_json's default float parsing is not correctly rounded
        // (that's its `float_roundtrip` feature), so the map must be keyed
        // by the value serde_json will actually parse from the sentinel
        // text — adjacent ULPs can collapse to the same f64.
        let (text, bits) = loop {
            let text = format!("{sentinel:e}");
            sentinel = f64::from_bits(sentinel.to_bits() - 1);
            let Ok(parsed) = serde_json::from_str::<f64>(&text) else {
                continue;
            };
            let bits = parsed.to_bits();
            if !taken.contains(&bits) && !originals.contains_key(&bits) {
                break (text, bits);
            }
        };
        originals.insert(bits, src[t.start..t.end].to_string());
        out.push_str(&src[pos..t.start]);
        out.push_str(&text);
        pos = t.end;
    }
    out.push_str(&src[pos..]);
    Some((out, originals))
}

/// Validates JSON without first forcing its numbers through f64, then
/// materializes a `Value` after substituting finite sentinels for numbers
/// serde_json cannot otherwise represent. RawValue validation is important:
/// the lightweight number scanner deliberately assumes valid JSON and must
/// never turn a malformed token such as `1e` into an accepted request.
pub fn parse_value_preserving_numbers(
    src: &str,
) -> Result<(Json, HashMap<u64, String>), serde_json::Error> {
    let _: &RawValue = serde_json::from_str(src)?;
    match rewrite_lossy_numbers(src) {
        Some((rewritten, originals)) => Ok((serde_json::from_str::<Json>(&rewritten)?, originals)),
        None => Ok((serde_json::from_str::<Json>(src)?, HashMap::new())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ordinary_numbers_are_untouched() {
        for src in [
            r#"{"v": 1.5}"#,
            r#"{"v": -0}"#,
            r#"{"v": 1e2, "w": [42, -7, 0.25]}"#,
            r#"{"v": 9223372036854775807}"#,
            r#"{"v": 18446744073709551615}"#,
            r#"{"s": "99999999999999999999999"}"#,
        ] {
            assert!(rewrite_lossy_numbers(src).is_none(), "{src}");
        }
    }

    #[test]
    fn lossy_numbers_are_rewritten_and_recoverable() {
        let src = r#"{"a": 99999999999999999999999, "b": 1.00000000000000000001, "c": 1.5}"#;
        let (rewritten, originals) = rewrite_lossy_numbers(src).unwrap();
        let parsed: Json = serde_json::from_str(&rewritten).unwrap();
        let mut found: Vec<&String> = Vec::new();
        for key in ["a", "b"] {
            let f = parsed[key].as_f64().unwrap();
            found.push(originals.get(&f.to_bits()).unwrap());
        }
        assert_eq!(
            (
                originals.len(),
                found,
                parsed["c"].as_f64(),
                parsed["a"].as_i64(),
            ),
            (
                2,
                vec![
                    &"99999999999999999999999".to_string(),
                    &"1.00000000000000000001".to_string()
                ],
                Some(1.5),
                None,
            )
        );
    }

    #[test]
    fn raw_validation_accepts_overflow_but_rejects_malformed_numbers() {
        let (parsed, originals) =
            parse_value_preserving_numbers(r#"{"v":1e400,"nested":{"n":-9e999}}"#).unwrap();
        for (path, expected) in [(["v", ""], "1e400"), (["nested", "n"], "-9e999")] {
            let value = if path[1].is_empty() {
                &parsed[path[0]]
            } else {
                &parsed[path[0]][path[1]]
            };
            let bits = value.as_f64().unwrap().to_bits();
            assert_eq!(originals.get(&bits).map(String::as_str), Some(expected));
        }
        assert!(parse_value_preserving_numbers(r#"{"v":1e}"#).is_err());
    }
}
