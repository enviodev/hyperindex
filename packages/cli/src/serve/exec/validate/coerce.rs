use super::args::list_items;
use super::variables::VarValue;
use super::{
    aeson_kind, float_bounds_error, found_desc, int_bounds_error, ir, perr, q, verr, AValue, Ctx,
    GResult, Json, Scalar, TypeDef, V,
};

// ---------------------------------------------------------------------------
// Strict (GraphQL-native) scalar coercion
// ---------------------------------------------------------------------------

pub(super) fn coerce_bool_strict(v: V, path: &str) -> GResult<bool> {
    match v {
        V::L(q::Value::Boolean(b)) => Ok(*b),
        V::J(Json::Bool(b)) => Ok(*b),
        other => Err(verr(
            path,
            format!(
                "expected a boolean for type 'Boolean', but found {}",
                found_desc(other)
            ),
        )),
    }
}

pub(super) fn coerce_string_strict(v: V, path: &str) -> GResult<String> {
    match v {
        V::L(q::Value::String(s)) => Ok(s.clone()),
        V::J(Json::String(s)) => Ok(s.clone()),
        other => Err(verr(
            path,
            format!(
                "expected a string for type 'String', but found {}",
                found_desc(other)
            ),
        )),
    }
}

/// Enum value coercion: GraphQL enum literals and JSON strings are valid,
/// string literals are not.
pub(super) fn coerce_enum(ctx: &Ctx, v: V, enum_type: &str, path: &str) -> GResult<String> {
    let name = match v {
        V::L(q::Value::Enum(n)) => n.clone(),
        V::J(Json::String(n)) => n.clone(),
        V::L(q::Value::String(_)) => {
            return Err(verr(
                path,
                format!("expected an enum value for type '{enum_type}', but found a string"),
            ));
        }
        other => {
            return Err(verr(
                path,
                format!(
                    "expected an enum value for type '{enum_type}', but found {}",
                    found_desc(other)
                ),
            ));
        }
    };
    let values = enum_values_for_message(ctx, enum_type);
    if values.iter().any(|value| value == &name) {
        Ok(name)
    } else {
        let list = values
            .iter()
            .map(|value| format!("'{value}'"))
            .collect::<Vec<_>>()
            .join(", ");
        Err(verr(
            path,
            format!(
                "expected one of the values [{list}] for type '{enum_type}', but found '{name}'"
            ),
        ))
    }
}

/// Enum values in Hasura's HashMap-driven order: for select-column enums the
/// primary key comes first (which is all the snapshots pin); everything else
/// keeps registry (alphabetical) order.
fn enum_values_for_message(ctx: &Ctx, enum_type: &str) -> Vec<String> {
    let registry_values: Vec<String> = match ctx.registry.get(enum_type) {
        Some(TypeDef::Enum { values, .. }) => values.iter().map(|v| v.name.clone()).collect(),
        _ => vec![],
    };
    let Some(table) = enum_type
        .strip_suffix("_select_column")
        .and_then(|t| ctx.model.table(t))
    else {
        return registry_values;
    };
    let pk_apis: Vec<&str> = table
        .primary_key
        .iter()
        .filter_map(|db| table.columns.iter().find(|c| &c.db_name == db))
        .map(|c| c.api_name.as_str())
        .collect();
    let mut out: Vec<String> = pk_apis
        .iter()
        .filter(|pk| registry_values.iter().any(|v| v == *pk))
        .map(|pk| pk.to_string())
        .collect();
    for v in registry_values {
        if !pk_apis.contains(&v.as_str()) {
            out.push(v);
        }
    }
    out
}

/// Numeric value under coercion, keeping the original decimal text for
/// literals that overflow i64 so error displays and SQL keep full precision.
enum Num {
    Small(i64),
    Big(String),
    Float(f64),
}

fn numeric_of(ctx: &Ctx, v: V) -> Option<Num> {
    match v {
        V::L(q::Value::Int(n)) => {
            let n = n.as_i64().unwrap_or(0);
            Some(match ctx.int_originals.get(&n) {
                Some(orig) => Num::Big(orig.clone()),
                None => Num::Small(n),
            })
        }
        V::L(q::Value::Float(f)) => Some(Num::Float(*f)),
        V::J(Json::Number(n)) => {
            if let Some(i) = n.as_i64() {
                Some(Num::Small(i))
            } else if let Some(u) = n.as_u64() {
                Some(Num::Big(u.to_string()))
            } else {
                let f = n.as_f64()?;
                Some(match ctx.var_number_originals.get(&f.to_bits()) {
                    Some(orig) => Num::Big(orig.clone()),
                    None => Num::Float(f),
                })
            }
        }
        _ => None,
    }
}

impl Num {
    fn display(&self, ctx: &Ctx) -> String {
        match self {
            Num::Small(n) => hs_scientific_decimal(&n.to_string()),
            Num::Big(s) => hs_scientific_decimal(s),
            Num::Float(f) => {
                // f64-overflowing literals are rewritten to a unique finite
                // sentinel per occurrence before parsing (see prescan.rs),
                // so this is an exact per-occurrence lookup, not a guess by
                // sign -- two distinct out-of-range literals in the same
                // query each keep their own original text.
                match ctx.inf_float_originals.get(&f.to_bits()) {
                    Some(orig) => hs_scientific_decimal(orig),
                    // Defensive: every f64-overflowing literal should have
                    // been rewritten already, so a genuinely infinite value
                    // here would be unexpected -- fall back to a plain
                    // Hasura-style display instead of losing the sign.
                    None if f.is_infinite() => {
                        if *f < 0.0 {
                            "-Infinity".to_string()
                        } else {
                            "Infinity".to_string()
                        }
                    }
                    None => hs_scientific_decimal(&format!("{f}")),
                }
            }
        }
    }

    /// Integral value within [min, max], or Err(display) Hasura-style.
    fn as_int_bounded(&self, ctx: &Ctx, min: i64, max: i64) -> Result<i64, String> {
        match self {
            Num::Small(n) => {
                if *n >= min && *n <= max {
                    Ok(*n)
                } else {
                    Err(self.display(ctx))
                }
            }
            Num::Big(_) => Err(self.display(ctx)),
            Num::Float(f) => {
                if f.is_finite() && f.fract() == 0.0 && *f >= min as f64 && *f <= max as f64 {
                    Ok(*f as i64)
                } else {
                    Err(self.display(ctx))
                }
            }
        }
    }

    /// SQL text form (full precision for oversized literals).
    fn sql_text(&self) -> String {
        match self {
            Num::Small(n) => n.to_string(),
            Num::Big(s) => s.clone(),
            Num::Float(f) => format!("{f}"),
        }
    }
}

/// `limit` (and stream `batch_size`): non-negative 32-bit Int. GraphQL
/// float literals are a kind error; JSON numbers go through scientific
/// bounds checking (so 1.5 reports the bounds message instead).
pub(super) fn coerce_limit(ctx: &Ctx, v: V, path: &str) -> GResult<Option<i64>> {
    if v.is_null() {
        return Ok(None);
    }
    let kind_err = |found: &str| {
        verr(
            path,
            format!("expected a non-negative 32-bit integer for type 'Int', but found {found}"),
        )
    };
    let num = match v {
        V::L(q::Value::Int(_)) | V::J(Json::Number(_)) => numeric_of(ctx, v).unwrap(),
        other => return Err(kind_err(found_desc(other))),
    };
    match num.as_int_bounded(ctx, i32::MIN as i64, i32::MAX as i64) {
        Ok(n) if n >= 0 => Ok(Some(n)),
        Ok(_) => Err(kind_err("an integer")),
        Err(display) => Err(int_bounds_error(path, &display)),
    }
}

/// `offset`: 32-bit ints, 64-bit ints, or 64-bit integers as strings
/// (oversized digit strings saturate, as observed against Hasura).
pub(super) fn coerce_offset(ctx: &Ctx, v: V, path: &str) -> GResult<Option<i64>> {
    if v.is_null() {
        return Ok(None);
    }
    let kind_err = |found: &str| {
        verr(
            path,
            format!(
                "expected a 32-bit integer, or a 64-bit integer represented as a string for type 'Int', but found {found}"
            ),
        )
    };
    match v {
        V::L(q::Value::Int(_)) | V::J(Json::Number(_)) => {
            let num = numeric_of(ctx, v).unwrap();
            match num.as_int_bounded(ctx, i64::MIN, i64::MAX) {
                Ok(n) => Ok(Some(n)),
                Err(display) => Err(int_bounds_error(path, &display)),
            }
        }
        V::L(q::Value::String(s)) | V::J(Json::String(s)) => match s.parse::<i64>() {
            Ok(n) => Ok(Some(n)),
            Err(_) => {
                let digits = s.strip_prefix('-').unwrap_or(s);
                if !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) {
                    Ok(Some(if s.starts_with('-') {
                        i64::MIN
                    } else {
                        i64::MAX
                    }))
                } else {
                    Err(kind_err("a string"))
                }
            }
        },
        other => Err(kind_err(found_desc(other))),
    }
}

// ---------------------------------------------------------------------------
// Column-typed value coercion (comparison values, by_pk, stream cursors)
// ---------------------------------------------------------------------------

fn pg_cast(scalar: Scalar, pg_type: &str) -> String {
    match scalar {
        Scalar::String => "text".to_string(),
        Scalar::Int => "int4".to_string(),
        Scalar::Smallint => "int2".to_string(),
        Scalar::Bigint => "int8".to_string(),
        Scalar::Float => "float4".to_string(),
        Scalar::Float8 => "float8".to_string(),
        Scalar::Numeric => "numeric".to_string(),
        Scalar::Boolean => "bool".to_string(),
        Scalar::Timestamptz => "timestamptz".to_string(),
        Scalar::Timestamp => "timestamp".to_string(),
        Scalar::Date => "date".to_string(),
        Scalar::Jsonb => "jsonb".to_string(),
        Scalar::Json => "json".to_string(),
        Scalar::PgEnum | Scalar::Other => pg_type.to_string(),
    }
}

pub(super) fn coerce_column_value<'a>(
    ctx: &Ctx<'a>,
    scalar: Scalar,
    pg_type: &str,
    is_array: bool,
    v: V<'a>,
    path: &str,
) -> GResult<ir::SqlValue> {
    if v.is_null() {
        let base = scalar.gql_name(pg_type);
        let display = if is_array { format!("[{base}!]") } else { base };
        return Err(verr(
            path,
            format!("unexpected null value for type '{display}'"),
        ));
    }
    if is_array {
        let cast = format!("{}[]", pg_cast(scalar, pg_type));
        let mut elems: Vec<String> = Vec::new();
        for (i, item) in list_items(v).into_iter().enumerate() {
            let elem =
                coerce_column_value(ctx, scalar, pg_type, false, item, &format!("{path}[{i}]"))?;
            elems.push(elem.text.unwrap_or_default());
        }
        return Ok(ir::SqlValue::new(pg_array_literal(&elems), cast));
    }

    let cast = pg_cast(scalar, pg_type);
    // Strings (and enum literals) always pass through: Hasura's typed parse
    // falls back to an opaque value, so bad text errors in Postgres, not here.
    let passthrough = match v {
        V::L(q::Value::String(s)) | V::J(Json::String(s)) => Some(s.clone()),
        V::L(q::Value::Enum(e)) => Some(e.clone()),
        _ => None,
    };

    match scalar {
        Scalar::Jsonb | Scalar::Json => {
            let json = value_to_json(ctx, v)?;
            Ok(ir::SqlValue::new(json.to_string(), cast))
        }
        Scalar::String => match passthrough {
            Some(s) => Ok(ir::SqlValue::new(s, cast)),
            None => Err(perr(
                path,
                format!(
                    "parsing Text failed, expected String, but encountered {}",
                    aeson_kind(v)
                ),
            )),
        },
        Scalar::Timestamptz | Scalar::Timestamp | Scalar::Date => match passthrough {
            Some(s) => Ok(ir::SqlValue::new(s, cast)),
            None => {
                let hs_type = match scalar {
                    Scalar::Timestamptz => "UTCTime",
                    Scalar::Timestamp => "LocalTime",
                    _ => "Day",
                };
                Err(perr(
                    path,
                    format!(
                        "parsing {hs_type} failed, expected String, but encountered {}",
                        aeson_kind(v)
                    ),
                ))
            }
        },
        Scalar::PgEnum | Scalar::Other => match passthrough {
            Some(s) => Ok(ir::SqlValue::new(s, cast)),
            None => Err(perr(
                path,
                format!("A string is expected for type: {pg_type}"),
            )),
        },
        Scalar::Boolean => match v {
            V::L(q::Value::Boolean(b)) => Ok(ir::SqlValue::new(b.to_string(), cast)),
            V::J(Json::Bool(b)) => Ok(ir::SqlValue::new(b.to_string(), cast)),
            _ => match passthrough {
                Some(s) => Ok(ir::SqlValue::new(s, cast)),
                None => Err(perr(
                    path,
                    format!("expected Bool, but encountered {}", aeson_kind(v)),
                )),
            },
        },
        Scalar::Int | Scalar::Smallint | Scalar::Bigint => {
            if let Some(s) = passthrough {
                return Ok(ir::SqlValue::new(s, cast));
            }
            let pg_name = match scalar {
                Scalar::Int => "PGInteger",
                Scalar::Smallint => "PGSmallInt",
                _ => "PGBigInt",
            };
            let (min, max) = match scalar {
                Scalar::Int => (i32::MIN as i64, i32::MAX as i64),
                Scalar::Smallint => (i16::MIN as i64, i16::MAX as i64),
                _ => (i64::MIN, i64::MAX),
            };
            let Some(num) = numeric_of(ctx, v) else {
                return Err(perr(
                    path,
                    format!(
                        "parsing Integer expected for input type: {pg_name} failed, expected Number, but encountered {}",
                        aeson_kind(v)
                    ),
                ));
            };
            match num.as_int_bounded(ctx, min, max) {
                Ok(n) => Ok(ir::SqlValue::new(n.to_string(), cast)),
                Err(display) => Err(int_bounds_error(path, &display)),
            }
        }
        Scalar::Numeric => {
            if let Some(s) = passthrough {
                return Ok(ir::SqlValue::new(s, cast));
            }
            let Some(num) = numeric_of(ctx, v) else {
                return Err(perr(
                    path,
                    format!(
                        "parsing Scientific failed, expected Number, but encountered {}",
                        aeson_kind(v)
                    ),
                ));
            };
            Ok(ir::SqlValue::new(num.sql_text(), cast))
        }
        Scalar::Float | Scalar::Float8 => {
            if let Some(s) = passthrough {
                return Ok(ir::SqlValue::new(s, cast));
            }
            let pg_name = if scalar == Scalar::Float {
                "PGFloat"
            } else {
                "PGDouble"
            };
            let Some(num) = numeric_of(ctx, v) else {
                return Err(perr(
                    path,
                    format!(
                        "parsing Float expected for input type: {pg_name} failed, expected Number, but encountered {}",
                        aeson_kind(v)
                    ),
                ));
            };
            if let Num::Float(f) = &num {
                // A literal that overflowed f64 is rewritten to a finite
                // sentinel before parsing (see prescan.rs), so it no longer
                // satisfies `is_infinite()` here -- check the sentinel map
                // too, or an out-of-range literal like `1e400` would wrongly
                // coerce instead of erroring like Hasura does.
                if f.is_infinite() || ctx.inf_float_originals.contains_key(&f.to_bits()) {
                    return Err(float_bounds_error(path, &num.display(ctx)));
                }
            }
            Ok(ir::SqlValue::new(num.sql_text(), cast))
        }
    }
}

/// GraphQL literal (with variables substituted) to a JSON value, for
/// jsonb/json column positions.
fn value_to_json<'a>(ctx: &Ctx<'a>, v: V<'a>) -> GResult<Json> {
    match v {
        V::J(j) => Ok(desentinel(ctx, j)),
        V::L(l) => literal_to_json(ctx, l),
    }
}

/// Sentinel numbers (see json_numbers.rs) must not leak into jsonb values;
/// substitute the closest f64 to the original text, which is what
/// serde_json would have parsed without the rewrite.
fn desentinel(ctx: &Ctx, j: &Json) -> Json {
    if ctx.var_number_originals.is_empty() {
        return j.clone();
    }
    match j {
        Json::Number(n) if n.as_i64().is_none() && n.as_u64().is_none() => {
            let orig = n
                .as_f64()
                .and_then(|f| ctx.var_number_originals.get(&f.to_bits()));
            match orig {
                Some(orig) => orig
                    .parse::<f64>()
                    .ok()
                    .and_then(serde_json::Number::from_f64)
                    .map(Json::Number)
                    .unwrap_or(Json::Null),
                None => j.clone(),
            }
        }
        Json::Array(items) => Json::Array(items.iter().map(|i| desentinel(ctx, i)).collect()),
        Json::Object(map) => Json::Object(
            map.iter()
                .map(|(k, v)| (k.clone(), desentinel(ctx, v)))
                .collect(),
        ),
        other => other.clone(),
    }
}

fn literal_to_json<'a>(ctx: &Ctx<'a>, l: &'a AValue) -> GResult<Json> {
    Ok(match l {
        q::Value::Null => Json::Null,
        q::Value::Boolean(b) => Json::Bool(*b),
        q::Value::Int(n) => {
            let n = n.as_i64().unwrap_or(0);
            match ctx.int_originals.get(&n) {
                Some(orig) => orig
                    .parse::<f64>()
                    .ok()
                    .and_then(serde_json::Number::from_f64)
                    .map(Json::Number)
                    .unwrap_or(Json::Null),
                None => Json::Number(n.into()),
            }
        }
        q::Value::Float(f) => serde_json::Number::from_f64(*f)
            .map(Json::Number)
            .unwrap_or(Json::Null),
        q::Value::String(s) => Json::String(s.clone()),
        q::Value::Enum(e) => Json::String(e.clone()),
        q::Value::List(items) => Json::Array(
            items
                .iter()
                .map(|i| literal_to_json(ctx, i))
                .collect::<GResult<Vec<_>>>()?,
        ),
        q::Value::Object(map) => {
            let mut out = serde_json::Map::new();
            for (k, val) in map {
                out.insert(k.clone(), literal_to_json(ctx, val)?);
            }
            Json::Object(out)
        }
        q::Value::Variable(name) => {
            ctx.mark_used(name);
            match ctx.vars.get(name.as_str()) {
                Some(var) => match &var.value {
                    VarValue::Json(j) => (*j).clone(),
                    VarValue::Lit(l) => literal_to_json(ctx, l)?,
                },
                None => return Err(verr("$", format!("unbound variable \"{name}\""))),
            }
        }
    })
}

/// Postgres array literal text form, e.g. `{a,"b c"}`.
fn pg_array_literal(elems: &[String]) -> String {
    let mut out = String::from("{");
    for (i, e) in elems.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        let needs_quoting = e.is_empty()
            || e.eq_ignore_ascii_case("null")
            || e.chars()
                .any(|c| matches!(c, '{' | '}' | ',' | '"' | '\\') || c.is_whitespace());
        if needs_quoting {
            out.push('"');
            for c in e.chars() {
                if c == '"' || c == '\\' {
                    out.push('\\');
                }
                out.push(c);
            }
            out.push('"');
        } else {
            out.push_str(e);
        }
    }
    out.push('}');
    out
}

// ---------------------------------------------------------------------------
// Hasura JSONPath parsing (json/jsonb `path` argument)
// ---------------------------------------------------------------------------

/// Parses Hasura's JSONPath dialect into `#>` path segments. Accepted:
/// `$`, dotted names (unicode letters/digits/_/-, leading `$`/`.` optional),
/// `[123]` indexes, and `["..."]`/`['...']` quoted keys.
pub(super) fn parse_json_path(input: &str) -> Result<Vec<String>, ()> {
    if input == "$" {
        return Ok(vec![]);
    }
    let mut chars = input.chars().peekable();
    if let Some('$') = chars.peek() {
        chars.next();
    }
    let mut segments: Vec<String> = Vec::new();
    while chars.peek().is_some() {
        if let Some('.') = chars.peek() {
            chars.next();
        }
        match chars.peek() {
            Some('[') => {
                chars.next();
                match chars.peek() {
                    Some(q @ '"') | Some(q @ '\'') => {
                        let quote = *q;
                        chars.next();
                        let mut key = String::new();
                        loop {
                            match chars.next() {
                                Some('\\') => match chars.next() {
                                    Some(c) => key.push(c),
                                    None => return Err(()),
                                },
                                Some(c) if c == quote => break,
                                Some(c) => key.push(c),
                                None => return Err(()),
                            }
                        }
                        if chars.next() != Some(']') {
                            return Err(());
                        }
                        segments.push(key);
                    }
                    Some(c) if c.is_ascii_digit() => {
                        let mut index = String::new();
                        while let Some(c) = chars.peek() {
                            if c.is_ascii_digit() {
                                index.push(*c);
                                chars.next();
                            } else {
                                break;
                            }
                        }
                        if chars.next() != Some(']') {
                            return Err(());
                        }
                        segments.push(index);
                    }
                    _ => return Err(()),
                }
            }
            Some(c) if *c == '_' || *c == '-' || c.is_alphanumeric() => {
                let mut name = String::new();
                while let Some(c) = chars.peek() {
                    if *c == '_' || *c == '-' || c.is_alphanumeric() {
                        name.push(*c);
                        chars.next();
                    } else {
                        break;
                    }
                }
                segments.push(name);
            }
            _ => return Err(()),
        }
    }
    if segments.is_empty() {
        return Err(());
    }
    Ok(segments)
}

// ---------------------------------------------------------------------------
// Haskell Scientific display (Data.Scientific Show)
// ---------------------------------------------------------------------------

/// Formats a decimal literal the way Haskell shows a Scientific:
/// normalized digits, fixed notation for exponents 0..=7, otherwise
/// `d.ddde<exp>` (e.g. "5000000000" -> "5.0e9", "0.001" -> "1.0e-3").
fn hs_scientific_decimal(s: &str) -> String {
    let Some((neg, digits, e)) = parse_decimal(s) else {
        return s.to_string();
    };
    hs_scientific_parts(neg, &digits, e)
}

/// Splits a decimal/scientific literal into (negative, normalized mantissa
/// digits, e) with value = 0.digits * 10^e.
pub(super) fn parse_decimal(s: &str) -> Option<(bool, String, i64)> {
    let s = s.trim();
    let (neg, s) = match s.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, s),
    };
    let (mantissa, exp) = match s.find(['e', 'E']) {
        Some(i) => (&s[..i], s[i + 1..].parse::<i64>().ok()?),
        None => (s, 0),
    };
    let (int_part, frac_part) = match mantissa.find('.') {
        Some(i) => (&mantissa[..i], &mantissa[i + 1..]),
        None => (mantissa, ""),
    };
    if int_part.is_empty() && frac_part.is_empty() {
        return None;
    }
    if !int_part.bytes().all(|b| b.is_ascii_digit())
        || !frac_part.bytes().all(|b| b.is_ascii_digit())
    {
        return None;
    }
    let mut digits: String = format!("{int_part}{frac_part}");
    // A literal like `1e9223372036854775807` puts exp at i64::MAX; checked
    // arithmetic falls back to echoing the raw text instead of overflowing
    // (which would panic under debug assertions — a user-triggerable crash).
    let mut e = (int_part.len() as i64).checked_add(exp)?;
    let leading_zeros = digits.len() - digits.trim_start_matches('0').len();
    digits = digits[leading_zeros..].to_string();
    e = e.checked_sub(leading_zeros as i64)?;
    digits = digits.trim_end_matches('0').to_string();
    if digits.is_empty() {
        return Some((false, "0".to_string(), 0));
    }
    Some((neg, digits, e))
}

fn hs_scientific_parts(neg: bool, digits: &str, e: i64) -> String {
    let sign = if neg { "-" } else { "" };
    if !(0..=7).contains(&e) {
        // Exponent format: first digit, '.', remaining digits (or 0), e<e-1>.
        // i128: e can legitimately sit at i64::MIN (e.g. `0.1e-9223372036854775808`).
        let first = &digits[..1];
        let rest = if digits.len() > 1 { &digits[1..] } else { "0" };
        format!("{sign}{first}.{rest}e{}", (e as i128) - 1)
    } else if e <= 0 {
        format!("{sign}0.{}{digits}", "0".repeat((-e) as usize))
    } else {
        let e = e as usize;
        if digits.len() <= e {
            format!("{sign}{digits}{}.0", "0".repeat(e - digits.len()))
        } else {
            format!("{sign}{}.{}", &digits[..e], &digits[e..])
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scientific_display_matches_hasura() {
        let cases = [
            ("1.5", "1.5"),
            ("2147483648", "2.147483648e9"),
            ("-2147483649", "-2.147483649e9"),
            ("5000000000", "5.0e9"),
            ("99999999999999", "9.9999999999999e13"),
            ("9223372036854775808", "9.223372036854775808e18"),
            ("99999999999999999999999", "9.9999999999999999999999e22"),
            ("0.001", "1.0e-3"),
            ("0.0025", "2.5e-3"),
            ("2.5e-3", "2.5e-3"),
            ("1e400", "1.0e400"),
            ("100000000000000000000000000", "1.0e26"),
            ("1.5e3", "1500.0"),
            ("42", "42.0"),
            ("5", "5.0"),
            ("0.5", "0.5"),
            ("0", "0.0"),
            ("123.45", "123.45"),
            // Exponents at the i64 boundary must not overflow the internal
            // arithmetic (echoed raw when normalization can't represent them).
            ("1e9223372036854775807", "1e9223372036854775807"),
            ("1e-9223372036854775808", "1.0e-9223372036854775808"),
            ("0.1e-9223372036854775807", "1.0e-9223372036854775808"),
        ];
        for (input, expected) in cases {
            assert_eq!(
                (input, hs_scientific_decimal(input).as_str()),
                (input, expected)
            );
        }
    }

    #[test]
    fn json_path_parsing() {
        let ok = [
            ("$", vec![]),
            ("$.a.b", vec!["a", "b"]),
            ("$.nested.a[0]", vec!["nested", "a", "0"]),
            ("kind", vec!["kind"]),
            (".kind", vec!["kind"]),
            ("a.b", vec!["a", "b"]),
            ("[0]", vec!["0"]),
            ("$[2]", vec!["2"]),
            ("['x']", vec!["x"]),
            ("$[\"x y\"]", vec!["x y"]),
            ("[\"a\\\"b\"]", vec!["a\"b"]),
            ("$.héllo", vec!["héllo"]),
            ("$[4].k", vec!["4", "k"]),
            ("a-b_c1", vec!["a-b_c1"]),
        ];
        for (input, expected) in ok {
            assert_eq!(
                parse_json_path(input),
                Ok(expected.into_iter().map(String::from).collect::<Vec<_>>()),
                "{input}"
            );
        }
        for bad in [
            "",
            "$.",
            "a..b",
            "$[",
            "[x]",
            "[12ab]",
            "a b",
            "$$",
            "totally broken [",
        ] {
            assert_eq!(parse_json_path(bad), Err(()), "{bad}");
        }
    }

    #[test]
    fn pg_array_literal_quoting() {
        assert_eq!(
            pg_array_literal(&[
                "one".to_string(),
                "two words".to_string(),
                "a\"b\\c".to_string(),
                "".to_string(),
                "NULL".to_string(),
            ]),
            r#"{one,"two words","a\"b\\c","","NULL"}"#
        );
    }
}
