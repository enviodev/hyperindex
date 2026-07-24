use super::coerce::parse_decimal;
use super::{depth_error, invalid_query, GResult, MAX_DEPTH};
use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;

// ---------------------------------------------------------------------------
// Lexical pre-scan
// ---------------------------------------------------------------------------
//
// graphql-parser cannot represent three things Hasura handles at the lexer
// level: duplicate argument names, duplicate keys in input-object literals
// (both "not a valid graphql query" in Hasura, while graphql-parser silently
// collapses them into a BTreeMap), and int literals beyond i64 (Hasura keeps
// arbitrary precision, graphql-parser fails the whole parse). This token
// scan rejects the duplicates and rewrites oversized int literals to unused
// sentinel i64 values, remembering the original digits.

pub(super) struct Prescan {
    pub(super) rewritten: String,
    pub(super) int_originals: HashMap<i64, String>,
    /// All float literals that cannot round-trip through f64, keyed by the
    /// unique finite sentinel substituted into the parser input.
    pub(super) float_originals: HashMap<u64, String>,
    /// f64-overflowing float literals were rewritten to per-occurrence
    /// finite sentinel values before parsing; this maps each sentinel's bit
    /// pattern back to the original digits. Keyed per occurrence (like
    /// `int_originals`) rather than merely by sign, so two distinct
    /// out-of-range float literals in the same query each report their own
    /// text instead of collapsing to whichever one happened to come first.
    pub(super) inf_float_originals: HashMap<u64, String>,
}

#[derive(Clone, Copy, PartialEq)]
enum TokKind {
    Name,
    Int,
    Float,
    Str,
    Punct(char),
}

struct Tok<'a> {
    kind: TokKind,
    text: &'a str,
    start: usize,
    end: usize,
}

fn tokenize(src: &str) -> Result<Vec<Tok<'_>>, ()> {
    let bytes = src.as_bytes();
    let mut toks = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i];
        match c {
            b' ' | b'\t' | b'\r' | b'\n' | b',' => i += 1,
            b'#' => {
                while i < bytes.len() && bytes[i] != b'\n' {
                    i += 1;
                }
            }
            b'"' => {
                let start = i;
                if bytes[i..].starts_with(b"\"\"\"") {
                    i += 3;
                    loop {
                        if i >= bytes.len() {
                            return Err(());
                        }
                        if bytes[i] == b'\\' {
                            i += 2;
                        } else if bytes[i..].starts_with(b"\"\"\"") {
                            i += 3;
                            break;
                        } else {
                            i += 1;
                        }
                    }
                } else {
                    i += 1;
                    loop {
                        if i >= bytes.len() {
                            return Err(());
                        }
                        match bytes[i] {
                            b'\\' => i += 2,
                            b'"' => {
                                i += 1;
                                break;
                            }
                            b'\n' => return Err(()),
                            _ => i += 1,
                        }
                    }
                }
                toks.push(Tok {
                    kind: TokKind::Str,
                    text: &src[start..i],
                    start,
                    end: i,
                });
            }
            b'-' | b'0'..=b'9' => {
                let start = i;
                if c == b'-' {
                    i += 1;
                }
                while i < bytes.len() && bytes[i].is_ascii_digit() {
                    i += 1;
                }
                let mut is_float = false;
                if i < bytes.len() && bytes[i] == b'.' {
                    is_float = true;
                    i += 1;
                    while i < bytes.len() && bytes[i].is_ascii_digit() {
                        i += 1;
                    }
                }
                if i < bytes.len() && (bytes[i] == b'e' || bytes[i] == b'E') {
                    is_float = true;
                    i += 1;
                    if i < bytes.len() && (bytes[i] == b'+' || bytes[i] == b'-') {
                        i += 1;
                    }
                    while i < bytes.len() && bytes[i].is_ascii_digit() {
                        i += 1;
                    }
                }
                toks.push(Tok {
                    kind: if is_float {
                        TokKind::Float
                    } else {
                        TokKind::Int
                    },
                    text: &src[start..i],
                    start,
                    end: i,
                });
            }
            b'_' | b'a'..=b'z' | b'A'..=b'Z' => {
                let start = i;
                while i < bytes.len() && (bytes[i] == b'_' || bytes[i].is_ascii_alphanumeric()) {
                    i += 1;
                }
                toks.push(Tok {
                    kind: TokKind::Name,
                    text: &src[start..i],
                    start,
                    end: i,
                });
            }
            _ => {
                // Multi-byte UTF-8 or punctuation; treat one char at a time.
                let ch_len = src[i..].chars().next().map(|c| c.len_utf8()).unwrap_or(1);
                toks.push(Tok {
                    kind: TokKind::Punct(c as char),
                    text: &src[i..i + ch_len],
                    start: i,
                    end: i + ch_len,
                });
                i += ch_len;
            }
        }
    }
    Ok(toks)
}

pub(super) fn prescan(src: &str) -> GResult<Prescan> {
    let toks = tokenize(src).map_err(|_| invalid_query())?;

    // Nesting depth must be bounded before graphql_parser runs: its
    // recursive-descent parser overflows the stack (aborting the process)
    // on deeply nested documents, so this cannot wait for the AST.
    let mut depth: usize = 0;
    for t in &toks {
        match t.kind {
            TokKind::Punct('(') | TokKind::Punct('[') | TokKind::Punct('{') => {
                depth += 1;
                if depth > MAX_DEPTH {
                    return Err(depth_error());
                }
            }
            TokKind::Punct(')') | TokKind::Punct(']') | TokKind::Punct('}') => {
                depth = depth.saturating_sub(1);
            }
            _ => {}
        }
    }

    // Duplicate argument names / duplicate input-object keys. Inside
    // argument parentheses every `{` opens an object literal (selection
    // sets cannot occur there), so key tracking only runs at paren depth
    // > 0. Names preceded by `$` are variable definitions, not keys.
    enum Scope {
        Args(HashSet<String>),
        Object(HashSet<String>),
        List,
    }
    let mut scopes: Vec<Scope> = Vec::new();
    for (idx, t) in toks.iter().enumerate() {
        match t.kind {
            TokKind::Punct('(') => scopes.push(Scope::Args(HashSet::new())),
            TokKind::Punct(')') => {
                while let Some(s) = scopes.pop() {
                    if matches!(s, Scope::Args(_)) {
                        break;
                    }
                }
            }
            TokKind::Punct('{') if !scopes.is_empty() => scopes.push(Scope::Object(HashSet::new())),
            TokKind::Punct('}') => {
                if matches!(scopes.last(), Some(Scope::Object(_))) {
                    scopes.pop();
                }
            }
            TokKind::Punct('[') if !scopes.is_empty() => scopes.push(Scope::List),
            TokKind::Punct(']') => {
                if matches!(scopes.last(), Some(Scope::List)) {
                    scopes.pop();
                }
            }
            TokKind::Name => {
                let followed_by_colon =
                    matches!(toks.get(idx + 1), Some(n) if n.kind == TokKind::Punct(':'));
                let preceded_by_dollar = idx > 0 && toks[idx - 1].kind == TokKind::Punct('$');
                if followed_by_colon && !preceded_by_dollar {
                    match scopes.last_mut() {
                        Some(Scope::Args(keys)) | Some(Scope::Object(keys)) => {
                            if !keys.insert(t.text.to_string()) {
                                return Err(invalid_query());
                            }
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }

    // Oversized int literals and f64-overflowing float literals both get
    // rewritten to unique sentinel literals so the parsed AST carries a
    // value we can map back to the original text for error display.
    enum Rewrite {
        Int,
        Float { overflow: bool },
    }
    let mut int_originals: HashMap<i64, String> = HashMap::new();
    let mut float_originals: HashMap<u64, String> = HashMap::new();
    let mut inf_float_originals: HashMap<u64, String> = HashMap::new();
    let mut taken_int_values: HashSet<i64> = HashSet::new();
    let mut taken_float_values: HashSet<u64> = HashSet::new();
    let mut rewrites: Vec<(usize, Rewrite)> = Vec::new();
    for (idx, t) in toks.iter().enumerate() {
        match t.kind {
            TokKind::Int => match t.text.parse::<i64>() {
                Ok(n) => {
                    taken_int_values.insert(n);
                }
                Err(_) => rewrites.push((idx, Rewrite::Int)),
            },
            TokKind::Float => {
                if let Ok(f) = t.text.parse::<f64>() {
                    let overflow = !f.is_finite();
                    let roundtrips =
                        !overflow && parse_decimal(t.text) == parse_decimal(&format!("{f}"));
                    if !roundtrips {
                        rewrites.push((idx, Rewrite::Float { overflow }));
                    } else {
                        taken_float_values.insert(f.to_bits());
                    }
                }
            }
            _ => {}
        }
    }

    let rewritten = if rewrites.is_empty() {
        src.to_string()
    } else {
        let mut magic_int = i64::MAX;
        // Each occurrence steps one f64 ULP closer to zero from MAX/MIN, so
        // every rewritten literal gets its own exact, round-trippable
        // sentinel value instead of all collapsing to the same infinity.
        let mut magic_pos_float = f64::MAX;
        let mut magic_neg_float = f64::MIN;
        let mut out = String::with_capacity(src.len());
        let mut pos = 0;
        for (idx, kind) in rewrites {
            let t = &toks[idx];
            out.push_str(&src[pos..t.start]);
            match kind {
                Rewrite::Int => {
                    while taken_int_values.contains(&magic_int)
                        || int_originals.contains_key(&magic_int)
                    {
                        magic_int -= 1;
                    }
                    int_originals.insert(magic_int, t.text.to_string());
                    out.push_str(&magic_int.to_string());
                }
                Rewrite::Float { overflow } => {
                    let magic = if t.text.starts_with('-') {
                        &mut magic_neg_float
                    } else {
                        &mut magic_pos_float
                    };
                    while taken_float_values.contains(&magic.to_bits())
                        || float_originals.contains_key(&magic.to_bits())
                    {
                        *magic = f64::from_bits(magic.to_bits() - 1);
                    }
                    let bits = magic.to_bits();
                    float_originals.insert(bits, t.text.to_string());
                    if overflow {
                        inf_float_originals.insert(bits, t.text.to_string());
                    }
                    let _ = write!(out, "{magic:e}");
                }
            }
            pos = t.end;
        }
        out.push_str(&src[pos..]);
        out
    };

    Ok(Prescan {
        rewritten,
        int_originals,
        float_originals,
        inf_float_originals,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use graphql_parser::query as q;

    #[test]
    fn prescan_duplicates_and_rewrites() {
        assert!(prescan("{ User(limit: 1, limit: 2) { id } }").is_err());
        assert!(prescan("{ User(where: {id: {_eq: \"a\", _eq: \"b\"}}) { id } }").is_err());
        assert!(prescan("query ($l: Int, $l: Int) { User(limit: $l) { id } }").is_ok());
        assert!(prescan("{ a: User { id } a: User { id } }").is_ok());
        assert!(prescan("{ User(where: {a: {_eq: 1}, b: {_eq: 1}}) { id } }").is_ok());
        // String contents must not confuse scope tracking.
        assert!(prescan("{ User(where: {id: {_eq: \"({[\"}}) { id } }").is_ok());

        let scan = prescan("{ User(limit: 9223372036854775808) { id } }").unwrap();
        let (magic, orig) = scan.int_originals.iter().next().unwrap();
        assert_eq!(
            (
                scan.int_originals.len(),
                orig.as_str(),
                scan.rewritten.contains(&magic.to_string()),
                q::parse_query::<String>(&scan.rewritten).is_ok(),
            ),
            (1, "9223372036854775808", true, true)
        );

        let scan = prescan("{ E(where: {f: {_lt: 1e400}}) { id } }").unwrap();
        let (bits, orig) = scan.inf_float_originals.iter().next().unwrap();
        assert_eq!(
            (
                scan.inf_float_originals.len(),
                orig.as_str(),
                scan.rewritten
                    .contains(&format!("{:e}", f64::from_bits(*bits))),
                q::parse_query::<String>(&scan.rewritten).is_ok(),
            ),
            (1, "1e400", true, true)
        );

        // Two distinct literals overflowing to the same-signed infinity must
        // each keep their own original text (not collapse to one entry).
        let scan =
            prescan("{ E(where: {_and: [{f: {_lt: 1e400}}, {g: {_lt: 9e999}}]}) { id } }").unwrap();
        let mut origs: Vec<&String> = scan.inf_float_originals.values().collect();
        origs.sort();
        assert_eq!(
            (scan.inf_float_originals.len(), origs),
            (2, vec![&"1e400".to_string(), &"9e999".to_string()])
        );
    }
}

#[cfg(test)]
mod roundtrip_check {
    use super::*;
    use graphql_parser::query as q;

    #[test]
    fn inf_float_sentinel_roundtrips_bit_exact_through_the_real_parser() {
        let scan = prescan(
            "{ E(where: {_and: [{f: {_lt: 1e400}}, {g: {_lt: 9e999}}, {h: {_lt: -1e500}}]}) { id } }",
        )
        .unwrap();
        assert_eq!(scan.inf_float_originals.len(), 3);

        let doc = q::parse_query::<String>(&scan.rewritten).expect("rewritten text parses");
        // Walk the AST to find every Float literal value actually produced
        // by the real parser, and check each one's bit pattern is a key in
        // inf_float_originals (i.e. round-tripped exactly).
        let mut found_floats = Vec::new();
        fn walk_value(v: &q::Value<String>, out: &mut Vec<f64>) {
            match v {
                q::Value::Float(f) => out.push(*f),
                q::Value::Object(m) => {
                    for v in m.values() {
                        walk_value(v, out);
                    }
                }
                q::Value::List(items) => {
                    for v in items {
                        walk_value(v, out);
                    }
                }
                _ => {}
            }
        }
        fn selection_set<'a>(
            op: &'a q::OperationDefinition<'a, String>,
        ) -> &'a q::SelectionSet<'a, String> {
            match op {
                q::OperationDefinition::SelectionSet(s) => s,
                q::OperationDefinition::Query(q) => &q.selection_set,
                q::OperationDefinition::Mutation(m) => &m.selection_set,
                q::OperationDefinition::Subscription(s) => &s.selection_set,
            }
        }
        for def in &doc.definitions {
            if let q::Definition::Operation(op) = def {
                for field_sel in &selection_set(op).items {
                    if let q::Selection::Field(f) = field_sel {
                        for (_, v) in &f.arguments {
                            walk_value(v, &mut found_floats);
                        }
                    }
                }
            }
        }
        assert_eq!(found_floats.len(), 3);
        for f in found_floats {
            assert!(
                scan.inf_float_originals.contains_key(&f.to_bits()),
                "parsed sentinel {f} (bits {:x}) not found in inf_float_originals -- text/reparse round trip lost precision",
                f.to_bits()
            );
        }
    }
}
