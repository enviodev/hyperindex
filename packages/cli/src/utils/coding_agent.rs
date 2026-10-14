/// An AI coding agent running envio, known from the variable it sets on the
/// commands it runs. Agents that set no such variable go unrecognized rather
/// than guessed at from generic names like `AGENT`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodingAgent {
    Claude,
    Codex,
    Cursor,
}

/// Claude Code's `CLAUDECODE` counts when present at all; the others need a
/// value. When several are set, the first in this order wins.
pub fn detect(var: impl Fn(&str) -> Option<String>) -> Option<CodingAgent> {
    let has_value = |name| var(name).is_some_and(|value| !value.is_empty());
    if var("CLAUDECODE").is_some() {
        Some(CodingAgent::Claude)
    } else if has_value("CODEX_THREAD_ID") {
        Some(CodingAgent::Codex)
    } else if has_value("CURSOR_AGENT") {
        Some(CodingAgent::Cursor)
    } else {
        None
    }
}

pub fn from_process() -> Option<CodingAgent> {
    detect(|name| std::env::var(name).ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn detect_with(vars: &[(&str, &str)]) -> Option<CodingAgent> {
        detect(|name| {
            vars.iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| value.to_string())
        })
    }

    #[test]
    fn detects_each_agent_in_order_and_nothing_from_generic_names() {
        assert_eq!(
            [
                detect_with(&[("CLAUDECODE", "")]),
                detect_with(&[("CODEX_THREAD_ID", "thread-1")]),
                detect_with(&[("CURSOR_AGENT", "1")]),
                detect_with(&[
                    ("CURSOR_AGENT", "1"),
                    ("CODEX_THREAD_ID", "thread-1"),
                    ("CLAUDECODE", "1"),
                ]),
                detect_with(&[("CURSOR_AGENT", "1"), ("CODEX_THREAD_ID", "thread-1")]),
                detect_with(&[("CODEX_THREAD_ID", ""), ("CURSOR_AGENT", "")]),
                detect_with(&[("AGENT", "1"), ("AI_AGENT", "1")]),
            ],
            [
                Some(CodingAgent::Claude),
                Some(CodingAgent::Codex),
                Some(CodingAgent::Cursor),
                Some(CodingAgent::Claude),
                Some(CodingAgent::Codex),
                None,
                None,
            ]
        );
    }
}
