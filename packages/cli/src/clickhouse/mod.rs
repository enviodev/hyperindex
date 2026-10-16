pub mod ch_type;
pub mod client;
pub mod ddl;
#[cfg(test)]
pub(crate) mod live_tests;
#[cfg(test)]
mod mock_server;
pub mod row_binary;
pub mod select;
pub mod storage;
pub mod table;

/// Backtick-quotes an identifier. ClickHouse reads C-style escapes inside one
/// just as it does inside a string, so a backslash is doubled alongside the
/// backtick — left alone, a name holding `a\tb` would be created with a tab in
/// it.
pub(crate) fn quoted(name: &str) -> String {
    format!("`{}`", name.replace('\\', "\\\\").replace('`', "``"))
}

pub(crate) fn quoted_list(names: impl IntoIterator<Item = impl AsRef<str>>) -> String {
    names
        .into_iter()
        .map(|name| quoted(name.as_ref()))
        .collect::<Vec<_>>()
        .join(", ")
}

pub(crate) fn table_ref(database: &str, table: &str) -> String {
    format!("{}.{}", quoted(database), quoted(table))
}

/// Single-quotes a string literal. ClickHouse reads C-style escapes inside one,
/// so a backslash has to be doubled as well as a quote — left alone, `a\tb`
/// would be stored as `a`, a tab, `b`. NUL bytes are dropped because
/// `row_binary::put_string` drops them on write, so a filter value matches
/// the stored text.
pub(crate) fn literal(value: &str) -> String {
    format!(
        "'{}'",
        value
            .replace('\0', "")
            .replace('\\', "\\\\")
            .replace('\'', "''")
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn a_literal_survives_whatever_it_is_given() {
        let escaped = [
            r"abc\",
            r"a\'b",
            "it's",
            "''",
            r"a\tb",
            "x'; DROP TABLE y; --",
            "plain",
        ]
        .map(literal);
        assert_eq!(
            escaped,
            [
                r"'abc\\'",
                r"'a\\''b'",
                "'it''s'",
                "''''''",
                r"'a\\tb'",
                "'x''; DROP TABLE y; --'",
                "'plain'",
            ]
        );
    }

    #[test]
    fn an_identifier_survives_whatever_it_is_given() {
        assert_eq!(
            ["plain", "a`b", r"a\tb"].map(quoted),
            ["`plain`", "`a``b`", r"`a\\tb`"]
        );
    }
}
