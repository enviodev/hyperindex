//! One canonical JSON form per stored type, so a value read from envio's
//! Postgres and the same value served by graph-node compare equal.

use serde_json::Value;

use super::model::{FieldKind, Scalar};

/// The canonical form of a field value: `null`, a string, a boolean, or a list
/// of those.
pub fn canonical(kind: &FieldKind, list: bool, value: &Value) -> Value {
    match (value, list) {
        // graph-node resolves a list of entities by loading its children
        // (graphql/src/store/prefetch.rs), so one the store holds as null is
        // served as no children at all.
        (Value::Null, true) if matches!(kind, FieldKind::Entity { .. }) => Value::Array(vec![]),
        (Value::Null, _) => Value::Null,
        (Value::Array(items), true) => {
            let mut items: Vec<Value> = items.iter().map(|item| element(kind, item)).collect();
            // graph-node resolves a stored list of ids by loading the entities,
            // so it answers them ordered by id and once each, whatever order
            // the mapping saved them in.
            if matches!(kind, FieldKind::Entity { .. }) {
                items.sort_by(|a, b| a.as_str().cmp(&b.as_str()));
                items.dedup();
            }
            Value::Array(items)
        }
        _ => element(kind, value),
    }
}

fn element(kind: &FieldKind, value: &Value) -> Value {
    match kind {
        FieldKind::Scalar(scalar) => scalar_value(*scalar, value),
        FieldKind::Entity { target_id } => {
            let id = match value {
                Value::Object(object) => object.get("id").unwrap_or(&Value::Null),
                other => other,
            };
            scalar_value(*target_id, id)
        }
    }
}

pub fn scalar_value(scalar: Scalar, value: &Value) -> Value {
    if value.is_null() {
        return Value::Null;
    }
    match scalar {
        Scalar::Text => Value::String(text(value)),
        Scalar::Bytes => Value::String(text(value).to_lowercase()),
        Scalar::Integer => Value::String(integer(&text(value))),
        Scalar::BigDecimal => Value::String(decimal(&text(value))),
        Scalar::Boolean => match value {
            Value::Bool(b) => Value::Bool(*b),
            other => match text(other).as_str() {
                "true" | "t" => Value::Bool(true),
                "false" | "f" => Value::Bool(false),
                raw => Value::String(raw.to_string()),
            },
        },
    }
}

/// An entity id in canonical form, for set comparison and sampling.
pub fn id(scalar: Scalar, value: &Value) -> Option<String> {
    match scalar_value(scalar, value) {
        Value::String(id) => Some(id),
        _ => None,
    }
}

fn text(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// Canonical decimal integer. Postgres renders `numeric` plainly, graph-node
/// sends `Int` as a number and `BigInt`/`Int8` as strings; anything that isn't
/// an integer in any spelling is kept verbatim so the mismatch shows it.
pub fn integer(raw: &str) -> String {
    let trimmed = raw.trim();
    let (negative, digits) = split_sign(trimmed);
    if !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) {
        let digits = digits.trim_start_matches('0');
        return match (negative, digits.is_empty()) {
            (_, true) => "0".to_string(),
            (true, false) => format!("-{digits}"),
            (false, false) => digits.to_string(),
        };
    }
    // `1e3` or `100.0` is still an integer, just not spelled as one.
    let canonical = decimal(trimmed);
    if canonical.contains(['.', 'e', 'E']) || canonical.is_empty() {
        raw.to_string()
    } else {
        canonical
    }
}

/// Canonical decimal: plain notation, no leading zeros, no trailing fraction
/// zeros, `0` for any zero. graph-node normalizes BigDecimal the same way
/// before rendering it; Postgres keeps whatever scale was written.
pub fn decimal(raw: &str) -> String {
    let trimmed = raw.trim();
    let (negative, unsigned) = split_sign(trimmed);
    let (mantissa, exponent) = match unsigned.find(['e', 'E']) {
        Some(at) => match unsigned[at + 1..].parse::<i64>() {
            Ok(exponent) => (&unsigned[..at], exponent),
            Err(_) => return raw.to_string(),
        },
        None => (unsigned, 0),
    };
    let (int_part, frac_part) = mantissa.split_once('.').unwrap_or((mantissa, ""));
    if (int_part.is_empty() && frac_part.is_empty())
        || !int_part.bytes().all(|b| b.is_ascii_digit())
        || !frac_part.bytes().all(|b| b.is_ascii_digit())
    {
        return raw.to_string();
    }

    let mut digits = format!("{int_part}{frac_part}");
    let mut exponent = exponent - frac_part.len() as i64;
    let leading = digits.len() - digits.trim_start_matches('0').len();
    digits.drain(..leading);
    if digits.is_empty() {
        return "0".to_string();
    }
    if digits.len() > BIG_DECIMAL_DIGITS {
        exponent += (digits.len() - BIG_DECIMAL_DIGITS) as i64;
        let round_up = digits.as_bytes()[BIG_DECIMAL_DIGITS] >= b'5';
        digits.truncate(BIG_DECIMAL_DIGITS);
        if round_up {
            digits = increment(&digits);
        }
    }
    let trailing = digits.len() - digits.trim_end_matches('0').len();
    digits.truncate(digits.len() - trailing);
    exponent += trailing as i64;
    // A value this far from 1 isn't worth materialising digit by digit; both
    // sides of a real match spell it the same anyway.
    if exponent.abs() > 10_000 {
        return format!("{}{digits}e{exponent}", if negative { "-" } else { "" });
    }

    let plain = if exponent >= 0 {
        format!("{digits}{}", "0".repeat(exponent as usize))
    } else {
        let point = digits.len() as i64 + exponent;
        if point > 0 {
            let (whole, fraction) = digits.split_at(point as usize);
            format!("{whole}.{fraction}")
        } else {
            format!("0.{}{digits}", "0".repeat((-point) as usize))
        }
    };
    if negative {
        format!("-{plain}")
    } else {
        plain
    }
}

/// graph-node keeps a BigDecimal to this many significant digits, rounding
/// half up, so a longer value stored by envio is served as its rounding.
const BIG_DECIMAL_DIGITS: usize = 34;

fn increment(digits: &str) -> String {
    let mut bytes = digits.as_bytes().to_vec();
    for byte in bytes.iter_mut().rev() {
        if *byte == b'9' {
            *byte = b'0';
        } else {
            *byte += 1;
            return String::from_utf8(bytes).expect("ascii digits");
        }
    }
    format!("1{}", String::from_utf8(bytes).expect("ascii digits"))
}

fn split_sign(raw: &str) -> (bool, &str) {
    match raw.as_bytes().first() {
        Some(b'-') => (true, &raw[1..]),
        Some(b'+') => (false, &raw[1..]),
        _ => (false, raw),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;
    use serde_json::json;

    #[test]
    fn spells_integers_one_way() {
        assert_eq!(
            ["0", "-0", "007", "-12", "+5", "1e3", "100.0", "12.5", "abc", " 42 "]
                .map(integer)
                .to_vec(),
            ["0", "0", "7", "-12", "5", "1000", "100", "12.5", "abc", "42"]
        );
    }

    #[test]
    fn spells_decimals_one_way() {
        assert_eq!(
            [
                "1.500",
                "0.000",
                "-0.0",
                "1e-18",
                "1E+3",
                "123.456e2",
                "0.0001234",
                ".5",
                "5.",
                "-00012.3400",
                "12345678901234567890.123456789012345678",
                "1.2.3",
                "9999999999999999999999999999999999.5",
            ]
            .map(decimal)
            .to_vec(),
            [
                "1.5",
                "0",
                "0",
                "0.000000000000000001",
                "1000",
                "12345.6",
                "0.0001234",
                "0.5",
                "5",
                "-12.34",
                "12345678901234567890.12345678901235",
                "1.2.3",
                "10000000000000000000000000000000000",
            ]
        );
    }

    #[test]
    fn makes_postgres_and_graph_node_encodings_agree() {
        let bigint = FieldKind::Scalar(Scalar::Integer);
        let bytes = FieldKind::Scalar(Scalar::Bytes);
        let boolean = FieldKind::Scalar(Scalar::Boolean);
        let decimal = FieldKind::Scalar(Scalar::BigDecimal);
        let relation = FieldKind::Entity {
            target_id: Scalar::Bytes,
        };
        // (kind, list, as envio's Postgres renders it, as graph-node sends it)
        let pairs = [
            (&bigint, false, json!("1000"), json!("1000")),
            (&bigint, false, json!("42"), json!(42)),
            (&bytes, false, json!("0xabcdef"), json!("0xABCDEF")),
            (&boolean, false, json!("true"), json!(true)),
            (&decimal, false, json!("1.2300"), json!("1.23")),
            (&relation, false, json!("0xab"), json!({"id": "0xAB"})),
            (
                &relation,
                true,
                json!(["0x02", "0x01", "0x02"]),
                json!([{"id": "0x01"}, {"id": "0x02"}]),
            ),
            (&bigint, true, json!(["1", "2"]), json!(["1", "2"])),
            (&bigint, false, Value::Null, Value::Null),
            // A nullable `[Token!]` no mapping set (TakoTako-xyz/takotako-subgraph's
            // LendingProtocol.mintedTokens): stored null, served as `[]`.
            (&relation, true, Value::Null, json!([])),
        ];
        assert_eq!(
            pairs
                .iter()
                .map(|(kind, list, ours, theirs)| canonical(kind, *list, ours)
                    == canonical(kind, *list, theirs))
                .collect::<Vec<_>>(),
            vec![true; pairs.len()]
        );
    }

    #[test]
    fn keeps_scalar_lists_in_stored_order() {
        let kind = FieldKind::Scalar(Scalar::Integer);
        assert_eq!(
            canonical(&kind, true, &json!(["2", "1"]))
                == canonical(&kind, true, &json!(["1", "2"])),
            false
        );
    }
}
