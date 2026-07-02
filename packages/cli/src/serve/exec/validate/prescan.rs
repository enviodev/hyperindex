use super::{invalid_query, GResult};
use std::collections::{HashMap, HashSet};

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
    pub(super) inf_floats: Vec<String>,
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

    // Oversized int literals and f64-overflowing float literals.
    let mut int_originals: HashMap<i64, String> = HashMap::new();
    let mut inf_floats: Vec<String> = Vec::new();
    let mut oversized: Vec<usize> = Vec::new();
    let mut taken_values: HashSet<i64> = HashSet::new();
    for (idx, t) in toks.iter().enumerate() {
        match t.kind {
            TokKind::Int => match t.text.parse::<i64>() {
                Ok(n) => {
                    taken_values.insert(n);
                }
                Err(_) => oversized.push(idx),
            },
            TokKind::Float => {
                if let Ok(f) = t.text.parse::<f64>() {
                    if f.is_infinite() {
                        inf_floats.push(t.text.to_string());
                    }
                }
            }
            _ => {}
        }
    }

    let rewritten = if oversized.is_empty() {
        src.to_string()
    } else {
        let mut magic = i64::MAX;
        let mut out = String::with_capacity(src.len());
        let mut pos = 0;
        for idx in oversized {
            let t = &toks[idx];
            while taken_values.contains(&magic) || int_originals.contains_key(&magic) {
                magic -= 1;
            }
            int_originals.insert(magic, t.text.to_string());
            out.push_str(&src[pos..t.start]);
            out.push_str(&magic.to_string());
            pos = t.end;
        }
        out.push_str(&src[pos..]);
        out
    };

    Ok(Prescan {
        rewritten,
        int_originals,
        inf_floats,
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
        assert_eq!(scan.int_originals.len(), 1);
        let (magic, orig) = scan.int_originals.iter().next().unwrap();
        assert_eq!(orig, "9223372036854775808");
        assert!(scan.rewritten.contains(&magic.to_string()));
        assert!(q::parse_query::<String>(&scan.rewritten).is_ok());

        let scan = prescan("{ E(where: {f: {_lt: 1e400}}) { id } }").unwrap();
        assert_eq!(scan.inf_floats, vec!["1e400".to_string()]);
    }
}
