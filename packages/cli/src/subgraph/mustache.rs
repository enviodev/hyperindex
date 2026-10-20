//! What mustache.js 4.x renders, for the manifest templates subgraph repos
//! render with its CLI (`mustache config/mainnet.json subgraph.template.yaml >
//! subgraph.yaml`). The output feeds graph-cli as it would on the author's
//! machine, so the parse (standalone-line stripping included), the lookup and
//! the escaping follow mustache.js rather than the mustache spec where they
//! differ.

use anyhow::{anyhow, Result};
use serde_json::Value;

#[derive(Debug)]
enum Token {
    Text(String),
    Escaped(String),
    Unescaped(String),
    Section {
        name: String,
        inverted: bool,
        children: Vec<Token>,
    },
}

#[derive(Debug)]
enum Raw {
    Char(char),
    Tag(char, String),
}

/// The index of the first `\s*<close>` match in `tail`, as a JS regex search
/// finds it, and the length of that match.
fn find_closing(tail: &str, close: &str) -> Option<(usize, usize)> {
    let at = tail.find(close)?;
    let start = tail[..at]
        .char_indices()
        .rev()
        .take_while(|(_, ch)| ch.is_whitespace())
        .last()
        .map(|(index, _)| index)
        .unwrap_or(at);
    Some((start, at + close.len() - start))
}

fn skip_whitespace(src: &str, pos: usize) -> usize {
    pos + src[pos..]
        .char_indices()
        .find(|(_, ch)| !ch.is_whitespace())
        .map(|(index, _)| index)
        .unwrap_or(src.len() - pos)
}

fn parse(template: &str) -> Result<Vec<Token>> {
    let mut open = "{{".to_string();
    let mut close = "}}".to_string();
    let mut tokens: Vec<Option<Raw>> = Vec::new();
    let mut spaces: Vec<usize> = Vec::new();
    let mut has_tag = false;
    let mut non_space = false;
    let mut sections: Vec<String> = Vec::new();
    let mut pos = 0;

    // mustache.js drops a line holding only whitespace and tags that print
    // nothing (sections, comments, partials, delimiter changes) — its newline
    // included — which is what keeps a YAML template's indentation intact.
    let strip_space = |tokens: &mut Vec<Option<Raw>>,
                       spaces: &mut Vec<usize>,
                       has_tag: &mut bool,
                       non_space: &mut bool| {
        if *has_tag && !*non_space {
            for index in spaces.drain(..) {
                tokens[index] = None;
            }
        } else {
            spaces.clear();
        }
        *has_tag = false;
        *non_space = false;
    };

    loop {
        let next = template[pos..].find(&open).map(|at| pos + at);
        let text_end = next.unwrap_or(template.len());
        for ch in template[pos..text_end].chars() {
            if ch.is_whitespace() {
                spaces.push(tokens.len());
            } else {
                non_space = true;
            }
            tokens.push(Some(Raw::Char(ch)));
            if ch == '\n' {
                strip_space(&mut tokens, &mut spaces, &mut has_tag, &mut non_space);
            }
        }
        let Some(tag_start) = next else {
            break;
        };
        pos = skip_whitespace(template, tag_start + open.len());
        has_tag = true;

        let kind = match template[pos..].chars().next() {
            Some(ch @ ('#' | '^' | '/' | '>' | '{' | '&' | '=' | '!')) => {
                pos += 1;
                ch
            }
            _ => 'n',
        };
        pos = skip_whitespace(template, pos);

        let unclosed = || anyhow!("Unclosed tag at {}", template.len());
        let (kind, value) = match kind {
            '=' => {
                let (at, len) = find_closing(&template[pos..], "=").ok_or_else(unclosed)?;
                let value = template[pos..pos + at].to_string();
                pos += at + len;
                let (at, _) = find_closing(&template[pos..], &close).ok_or_else(unclosed)?;
                pos += at;
                ('=', value)
            }
            '{' => {
                let (at, _) =
                    find_closing(&template[pos..], &format!("}}{close}")).ok_or_else(unclosed)?;
                let value = template[pos..pos + at].to_string();
                pos += at;
                let (at, len) = find_closing(&template[pos..], "}").ok_or_else(unclosed)?;
                pos += at + len;
                let (at, _) = find_closing(&template[pos..], &close).ok_or_else(unclosed)?;
                pos += at;
                ('&', value)
            }
            kind => {
                let (at, _) = find_closing(&template[pos..], &close).ok_or_else(unclosed)?;
                let value = template[pos..pos + at].to_string();
                pos += at;
                (kind, value)
            }
        };
        match find_closing(&template[pos..], &close) {
            Some((0, len)) => pos += len,
            _ => return Err(anyhow!("Unclosed tag at {pos}")),
        }

        match kind {
            '#' | '^' => sections.push(value.clone()),
            '/' => match sections.pop() {
                None => return Err(anyhow!("Unopened section \"{value}\" at {tag_start}")),
                Some(open_section) if open_section != value => {
                    return Err(anyhow!(
                        "Unclosed section \"{open_section}\" at {tag_start}"
                    ))
                }
                Some(_) => {}
            },
            'n' | '&' => non_space = true,
            '=' => {
                let mut parts = value.split_whitespace();
                match (parts.next(), parts.next(), parts.next()) {
                    (Some(new_open), Some(new_close), None) => {
                        open = new_open.to_string();
                        close = new_close.to_string();
                    }
                    _ => return Err(anyhow!("Invalid tags: {value}")),
                }
            }
            _ => {}
        }
        tokens.push(Some(Raw::Tag(kind, value)));
    }
    strip_space(&mut tokens, &mut spaces, &mut has_tag, &mut non_space);
    if let Some(open_section) = sections.pop() {
        return Err(anyhow!(
            "Unclosed section \"{open_section}\" at {}",
            template.len()
        ));
    }

    // Each open section's name and whether it is inverted, with what it holds.
    type Frame = (Option<(String, bool)>, Vec<Token>);
    let mut stack: Vec<Frame> = vec![(None, Vec::new())];
    for raw in tokens.into_iter().flatten() {
        let children = &mut stack.last_mut().expect("the root frame").1;
        match raw {
            Raw::Char(ch) => match children.last_mut() {
                Some(Token::Text(text)) => text.push(ch),
                _ => children.push(Token::Text(ch.to_string())),
            },
            Raw::Tag('n', name) => children.push(Token::Escaped(name)),
            Raw::Tag('&', name) => children.push(Token::Unescaped(name)),
            Raw::Tag(kind @ ('#' | '^'), name) => {
                stack.push((Some((name, kind == '^')), Vec::new()));
            }
            Raw::Tag('/', _) => {
                let (Some((name, inverted)), children) = stack.pop().expect("a section frame")
                else {
                    unreachable!("sections are balanced")
                };
                stack
                    .last_mut()
                    .expect("the root frame")
                    .1
                    .push(Token::Section {
                        name,
                        inverted,
                        children,
                    });
            }
            // Comments, delimiter changes, and partials: the CLI is given no
            // partials, and mustache.js renders a missing one as nothing.
            Raw::Tag(_, _) => {}
        }
    }
    Ok(stack.pop().expect("the root frame").1)
}

/// A looked-up value: JSON, or a number only JavaScript has (`length`).
#[derive(Clone, Debug)]
enum Found<'a> {
    Json(&'a Value),
    Number(f64),
}

fn property<'a>(value: &Found<'a>, name: &str) -> Option<Found<'a>> {
    match value {
        Found::Json(Value::Object(map)) => map.get(name).map(Found::Json),
        Found::Json(Value::Array(items)) if name == "length" => {
            Some(Found::Number(items.len() as f64))
        }
        Found::Json(Value::Array(items)) => name
            .parse::<usize>()
            .ok()
            .and_then(|index| items.get(index))
            .map(Found::Json),
        _ => None,
    }
}

fn primitive_property<'a>(value: &Found<'a>, name: &str) -> Option<Found<'a>> {
    match value {
        Found::Json(Value::String(text)) if name == "length" => {
            Some(Found::Number(text.encode_utf16().count() as f64))
        }
        _ => None,
    }
}

/// mustache.js `Context.lookup`: a dotted name resolves in full against each
/// context, innermost first, and counts only if its last part exists.
fn lookup<'a>(stack: &[Found<'a>], name: &str) -> Option<Found<'a>> {
    if name == "." {
        return stack.last().cloned();
    }
    for context in stack.iter().rev() {
        if name.find('.').is_some_and(|at| at > 0) {
            let parts: Vec<&str> = name.split('.').collect();
            let mut current = Some(context.clone());
            for (index, part) in parts.iter().enumerate() {
                let Some(value) = current.as_ref() else { break };
                if matches!(value, Found::Json(Value::Null)) {
                    break;
                }
                let next = property(value, part).or_else(|| primitive_property(value, part));
                if index == parts.len() - 1 {
                    if let Some(found) = next {
                        return Some(found);
                    }
                }
                current = next;
            }
        } else if let Some(found) = property(context, name) {
            return Some(found);
        }
    }
    None
}

fn truthy(value: &Option<Found>) -> bool {
    match value {
        None | Some(Found::Json(Value::Null)) | Some(Found::Json(Value::Bool(false))) => false,
        Some(Found::Json(Value::String(text))) => !text.is_empty(),
        Some(Found::Json(Value::Number(number))) => {
            number.as_f64().is_some_and(|n| n != 0.0 && !n.is_nan())
        }
        Some(Found::Number(n)) => *n != 0.0 && !n.is_nan(),
        Some(_) => true,
    }
}

/// `String(n)` in JavaScript, for the doubles JSON numbers parse to.
pub fn js_number(n: f64) -> String {
    if n.is_nan() {
        return "NaN".to_string();
    }
    if n.is_infinite() {
        return if n > 0.0 { "Infinity" } else { "-Infinity" }.to_string();
    }
    if n == 0.0 {
        return "0".to_string();
    }
    let magnitude = n.abs();
    if (1e-6..1e21).contains(&magnitude) {
        return format!("{n}");
    }
    let exponential = format!("{n:e}");
    match exponential.split_once('e') {
        Some((mantissa, exponent)) if !exponent.starts_with('-') => {
            format!("{mantissa}e+{exponent}")
        }
        _ => exponential,
    }
}

fn js_string(value: &Found) -> String {
    match value {
        Found::Number(n) => js_number(*n),
        Found::Json(Value::Null) => "null".to_string(),
        Found::Json(Value::Bool(flag)) => flag.to_string(),
        Found::Json(Value::Number(number)) => js_number(number.as_f64().unwrap_or(f64::NAN)),
        Found::Json(Value::String(text)) => text.clone(),
        Found::Json(Value::Array(items)) => items
            .iter()
            .map(|item| match item {
                Value::Null => String::new(),
                item => js_string(&Found::Json(item)),
            })
            .collect::<Vec<_>>()
            .join(","),
        Found::Json(Value::Object(_)) => "[object Object]".to_string(),
    }
}

fn escape_html(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&#39;"),
            '/' => escaped.push_str("&#x2F;"),
            '`' => escaped.push_str("&#x60;"),
            '=' => escaped.push_str("&#x3D;"),
            ch => escaped.push(ch),
        }
    }
    escaped
}

fn render_tokens<'a>(tokens: &[Token], stack: &mut Vec<Found<'a>>, out: &mut String) {
    for token in tokens {
        match token {
            Token::Text(text) => out.push_str(text),
            Token::Escaped(name) => match lookup(stack, name) {
                None | Some(Found::Json(Value::Null)) => {}
                Some(Found::Number(n)) => out.push_str(&js_number(n)),
                Some(found @ Found::Json(Value::Number(_))) => out.push_str(&js_string(&found)),
                Some(found) => out.push_str(&escape_html(&js_string(&found))),
            },
            Token::Unescaped(name) => match lookup(stack, name) {
                None | Some(Found::Json(Value::Null)) => {}
                Some(found) => out.push_str(&js_string(&found)),
            },
            Token::Section {
                name,
                inverted: false,
                children,
            } => {
                let value = lookup(stack, name);
                if !truthy(&value) {
                    continue;
                }
                match value.expect("a truthy value exists") {
                    Found::Json(Value::Array(items)) => {
                        for item in items {
                            stack.push(Found::Json(item));
                            render_tokens(children, stack, out);
                            stack.pop();
                        }
                    }
                    Found::Json(Value::Bool(true)) => render_tokens(children, stack, out),
                    found => {
                        stack.push(found);
                        render_tokens(children, stack, out);
                        stack.pop();
                    }
                }
            }
            Token::Section {
                name,
                inverted: true,
                children,
            } => {
                let value = lookup(stack, name);
                let empty_list =
                    matches!(value, Some(Found::Json(Value::Array(ref items))) if items.is_empty());
                if !truthy(&value) || empty_list {
                    render_tokens(children, stack, out);
                }
            }
        }
    }
}

/// `mustache.render(template, view)`, as the mustache CLI calls it.
pub fn render(template: &str, view: &Value) -> Result<String> {
    let tokens = parse(template)?;
    let mut out = String::new();
    render_tokens(&tokens, &mut vec![Found::Json(view)], &mut out);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // Each expected string is what mustache.js 4.2.0 renders for the same
    // template and view (`node -e "require('mustache').render(t, v)"`).
    #[test]
    fn renders_as_mustache_js_does() {
        let cases: Vec<(&str, Value, &str)> = vec![
            (
                "network: {{network}}\n",
                json!({"network": "mainnet"}),
                "network: mainnet\n",
            ),
            ("{{ network }}", json!({"network": "a"}), "a"),
            ("{{missing}}|{{nothing}}", json!({"nothing": null}), "|"),
            (
                "{{n}} {{f}} {{big}}",
                json!({"n": 12345678, "f": 1.5, "big": 1e21}),
                "12345678 1.5 1e+21",
            ),
            (
                "{{flag}} {{list}}",
                json!({"flag": true, "list": [1, null, "a"]}),
                "true 1,,a",
            ),
            ("{{o}}", json!({"o": {}}), "[object Object]"),
            (
                "{{path}}",
                json!({"path": "./abis/A&B's=\"x\"`.json"}),
                ".&#x2F;abis&#x2F;A&amp;B&#39;s&#x3D;&quot;x&quot;&#x60;.json",
            ),
            (
                "{{{path}}} {{&path}}",
                json!({"path": "./abis/A.json"}),
                "./abis/A.json ./abis/A.json",
            ),
            ("{{a.b.c}}", json!({"a": {"b": {"c": "deep"}}}), "deep"),
            (
                "{{#a}}{{b.c}}{{/a}}",
                json!({"a": {"x": 1}, "b": {"c": "outer"}}),
                "outer",
            ),
            (
                "{{#list}}{{.}},{{/list}}",
                json!({"list": ["x", "y"]}),
                "x,y,",
            ),
            (
                "{{list.length}} {{s.length}}",
                json!({"list": [1, 2], "s": "abc"}),
                "2 3",
            ),
            ("{{#v}}[{{.}}]{{/v}}", json!({"v": "str"}), "[str]"),
            ("{{#v}}yes{{/v}}{{^v}}no{{/v}}", json!({"v": 0}), "no"),
            ("{{#v}}yes{{/v}}{{^v}}no{{/v}}", json!({"v": []}), "no"),
            ("{{#v}}yes{{/v}}{{^v}}no{{/v}}", json!({"v": {}}), "yes"),
            ("{{#v}}yes{{/v}}{{^v}}no{{/v}}", json!({"v": ""}), "no"),
            (
                "{{#v}}{{name}}{{/v}}",
                json!({"v": true, "name": "kept"}),
                "kept",
            ),
            ("a{{! comment }}b", json!({}), "ab"),
            ("{{=<% %>=}}<% x %> {{x}}", json!({"x": 1}), "1 {{x}}"),
            ("{{> part}}x", json!({}), "x"),
        ];
        let rendered: Vec<String> = cases
            .iter()
            .map(|(template, view, _)| render(template, view).unwrap())
            .collect();
        let expected: Vec<String> = cases.iter().map(|(_, _, out)| out.to_string()).collect();
        assert_eq!(rendered, expected);
    }

    // Uniswap-style templates put each section tag on a line of its own; the
    // line goes, so the data sources keep their YAML indentation.
    #[test]
    fn drops_lines_that_hold_only_a_section_tag() {
        let template = "dataSources:\n  {{#sources}}\n  - name: {{name}}\n    network: {{network}}\n  {{/sources}}\n  {{^sources}}\n  - none\n  {{/sources}}\ntemplates: []";
        let view = json!({"network": "base", "sources": [{"name": "A"}, {"name": "B"}]});
        assert_eq!(
            render(template, &view).unwrap(),
            "dataSources:\n  - name: A\n    network: base\n  - name: B\n    network: base\ntemplates: []"
        );
    }

    #[test]
    fn keeps_a_line_whose_section_tag_shares_it_with_text() {
        assert_eq!(
            render(
                "x {{#a}}in{{/a}}\n{{#a}}\nline\n{{/a}}",
                &json!({"a": true})
            )
            .unwrap(),
            "x in\nline\n"
        );
    }

    #[test]
    fn refuses_unbalanced_sections() {
        let errors: Vec<String> = ["{{#a}}x", "{{/a}}", "{{#a}}{{/b}}", "{{x"]
            .iter()
            .map(|template| render(template, &json!({})).unwrap_err().to_string())
            .collect();
        assert_eq!(
            errors,
            vec![
                "Unclosed section \"a\" at 7",
                "Unopened section \"a\" at 0",
                "Unclosed section \"a\" at 6",
                "Unclosed tag at 3",
            ]
        );
    }
}
