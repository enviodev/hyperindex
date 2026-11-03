//! Turning staged rows into the parameters their insert binds: one array
//! literal per column, for an insert that unnests them.

use anyhow::{bail, Context, Result};
use serde_json::Value;
use std::fmt::Write;

use super::param::Param;
use crate::columnar::{Column, ColumnKind};
use crate::storage::schema::{iso_millis, Encoding};

/// How a staged column's cells become text, beyond what their slot says.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Render {
    Plain,
    /// Milliseconds, which a timestamp column reads as an ISO instant.
    Date,
    /// A list's JSON, which becomes the row's own array literal; its elements
    /// are encoded as the list's element type says.
    List(Encoding),
}

impl Render {
    pub fn of(encoding: Encoding, element: Encoding) -> Self {
        match encoding {
            Encoding::Date => Render::Date,
            Encoding::List => Render::List(element),
            _ => Render::Plain,
        }
    }
}

/// Where one bound column's values come from.
pub enum Source<'a> {
    Staged {
        column: &'a Column,
        render: Render,
    },
    /// The same value on every row.
    Repeated(&'a str),
}

fn push_escaped(into: &mut String, text: &str) {
    for character in text.chars() {
        if character == '"' || character == '\\' {
            into.push('\\');
        }
        into.push(character);
    }
}

fn push_hex(into: &mut String, bytes: impl IntoIterator<Item = u8>) {
    for byte in bytes {
        let _ = write!(into, "{byte:02x}");
    }
}

/// A list as Postgres spells an array, each element quoted: inside quotes only
/// the quote and the backslash mean anything, so nothing here has to know what
/// the element type treats as special. A sub-list is written unquoted, which is
/// how Postgres spells a further dimension.
fn list_literal(into: &mut String, list: &[Value], element: Encoding) -> Result<()> {
    into.push('{');
    for (index, item) in list.iter().enumerate() {
        if index > 0 {
            into.push(',');
        }
        match item {
            Value::Null => into.push_str("NULL"),
            Value::Array(bytes)
                if element == Encoding::Bytes && bytes.iter().all(Value::is_number) =>
            {
                into.push_str("\"\\\\x");
                push_hex(
                    into,
                    bytes
                        .iter()
                        .map(|byte| {
                            byte.as_u64()
                                .and_then(|byte| u8::try_from(byte).ok())
                                .with_context(|| format!("`{byte}` is not a byte"))
                        })
                        .collect::<Result<Vec<u8>>>()?,
                );
                into.push('"');
            }
            Value::Array(items) => list_literal(into, items, element)?,
            Value::Bool(flag) => into.push_str(if *flag { "\"t\"" } else { "\"f\"" }),
            Value::Number(number) if element == Encoding::Date => {
                let ms = number
                    .as_i64()
                    .with_context(|| format!("`{number}` is not a timestamp"))?;
                let _ = write!(into, "\"{}\"", iso_millis(ms));
            }
            Value::Number(number) => {
                let _ = write!(into, "\"{number}\"");
            }
            Value::String(text) => {
                into.push('"');
                push_escaped(into, text);
                into.push('"');
            }
            Value::Object(_) => bail!("a list element can't be an object"),
        }
    }
    into.push('}');
    Ok(())
}

/// Writes one cell into the literal being built, escaped as an element of it.
///
/// The element is already inside its quotes, where only the quote and the
/// backslash still mean anything. A number goes through Rust's `Display`,
/// which never switches to exponent notation: Postgres refuses that for an
/// integer column.
fn write_cell(into: &mut String, column: &Column, render: Render, row: usize) -> Result<()> {
    match (render, column.kind()) {
        (Render::Date, ColumnKind::F64) => into.push_str(&iso_millis(column.f64_at(row) as i64)),
        (Render::List(element), ColumnKind::Text) => {
            let list: Vec<Value> = serde_json::from_slice(column.bytes_at(row))
                .context("a list's value is not a JSON array")?;
            let mut literal = String::new();
            list_literal(&mut literal, &list, element)?;
            push_escaped(into, &literal);
        }
        (_, ColumnKind::F64) => {
            let _ = write!(into, "{}", column.f64_at(row));
        }
        (_, ColumnKind::U64) => {
            let _ = write!(into, "{}", column.u64_at(row));
        }
        (_, ColumnKind::I64) => {
            let _ = write!(into, "{}", column.i64_at(row));
        }
        (_, ColumnKind::Text) => push_escaped(into, column.str_at(row)?),
        // `\x` then the bytes in hex, with the backslash escaped because the
        // element is inside quotes.
        (_, ColumnKind::Bytes) => {
            into.push_str("\\\\x");
            push_hex(into, column.bytes_at(row).iter().copied());
        }
        (_, ColumnKind::List) => bail!("a list column has no single value to render"),
    }
    Ok(())
}

/// The parameters for an insert that unnests one array per column, taking the
/// `rows` of the staged columns in that order.
///
/// Each column becomes one array literal, built in a single pass: a cell is
/// written where it will be read from rather than rendered to a string of its
/// own first, which for a batch is one allocation instead of one per cell.
pub fn unnest_params(sources: &[Source], rows: &[usize]) -> Result<Vec<Param>> {
    sources
        .iter()
        .map(|source| {
            let mut literal = String::with_capacity(rows.len() * 24 + 2);
            literal.push('{');
            for (index, &row) in rows.iter().enumerate() {
                if index > 0 {
                    literal.push(',');
                }
                match source {
                    Source::Repeated(value) => {
                        literal.push('"');
                        push_escaped(&mut literal, value);
                        literal.push('"');
                    }
                    // Quoted, it would be the four-character string instead
                    // of the absence of a value.
                    Source::Staged { column, .. } if column.is_null(row) => {
                        literal.push_str("NULL")
                    }
                    Source::Staged { column, render } => {
                        literal.push('"');
                        write_cell(&mut literal, column, *render, row)?;
                        literal.push('"');
                    }
                }
            }
            literal.push('}');
            Ok(Param::Text(literal))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::columnar::{Arena, ColumnSpec};

    fn arena_of(kind: ColumnKind, fill: impl Fn(&mut Arena), rows: usize) -> Arena {
        let mut arena = Arena::new_filled(rows, &[ColumnSpec::Scalar(kind)]);
        fill(&mut arena);
        arena.seal(&["c".to_string()]).unwrap();
        arena
    }

    fn text_column(values: &[Option<&str>]) -> Arena {
        arena_of(
            ColumnKind::Text,
            |arena| {
                for (row, value) in values.iter().enumerate() {
                    match value {
                        None => arena.mark_null(0, row),
                        Some(value) => arena.set_bytes(0, row, value.as_bytes()),
                    }
                }
            },
            values.len(),
        )
    }

    fn params(arena: &Arena, render: Render) -> Vec<Param> {
        let rows = (0..arena.rows()).collect::<Vec<_>>();
        unnest_params(
            &[Source::Staged {
                column: &arena.columns()[0],
                render,
            }],
            &rows,
        )
        .unwrap()
    }

    fn text(literal: &str) -> Vec<Param> {
        vec![Param::Text(literal.to_string())]
    }

    #[test]
    fn a_column_becomes_one_array_literal() {
        assert_eq!(
            params(&text_column(&[Some("a"), None, Some("b")]), Render::Plain),
            text("{\"a\",NULL,\"b\"}")
        );
    }

    #[test]
    fn only_the_rows_asked_for_are_bound_in_their_order_beside_a_repeated_value() {
        let arena = text_column(&[Some("a"), Some("b"), Some("c")]);
        assert_eq!(
            unnest_params(
                &[
                    Source::Staged {
                        column: &arena.columns()[0],
                        render: Render::Plain,
                    },
                    Source::Repeated("SET"),
                ],
                &[2, 0],
            )
            .unwrap(),
            vec![
                Param::Text("{\"c\",\"a\"}".to_string()),
                Param::Text("{\"SET\",\"SET\"}".to_string()),
            ]
        );
    }

    #[test]
    fn bytes_render_as_a_hex_literal() {
        let arena = arena_of(
            ColumnKind::Bytes,
            |arena| {
                arena.set_bytes(0, 0, &[0xde, 0xad]);
                arena.mark_null(0, 1);
            },
            2,
        );
        assert_eq!(params(&arena, Render::Plain), text("{\"\\\\xdead\",NULL}"));
    }

    /// A whole number is written without a point: the column it goes into is an
    /// integer one, and `1.0` is not something it takes.
    #[test]
    fn a_whole_number_keeps_no_decimal_point() {
        let arena = arena_of(
            ColumnKind::F64,
            |arena| {
                for (row, value) in [1.0, -7.0, 1.5, 9007199254740991.0].iter().enumerate() {
                    arena.set_f64(0, row, *value);
                }
            },
            4,
        );
        assert_eq!(
            params(&arena, Render::Plain),
            text("{\"1\",\"-7\",\"1.5\",\"9007199254740991\"}")
        );
    }

    #[test]
    fn a_date_is_written_as_the_instant_its_milliseconds_name() {
        let arena = arena_of(
            ColumnKind::F64,
            |arena| arena.set_f64(0, 0, 1_700_000_000_123.0),
            1,
        );
        assert_eq!(
            params(&arena, Render::Date),
            text("{\"2023-11-14T22:13:20.123Z\"}")
        );
    }

    /// Unquoted, each of these would end the element early or be read as
    /// something other than itself.
    #[test]
    fn an_element_survives_the_characters_an_array_reads() {
        let arena = text_column(&[
            Some("a,b"),
            Some("{nested}"),
            Some("has \"quotes\""),
            Some("back\\slash"),
            Some(""),
            Some("NULL"),
        ]);
        assert_eq!(
            params(&arena, Render::Plain),
            text("{\"a,b\",\"{nested}\",\"has \\\"quotes\\\"\",\"back\\\\slash\",\"\",\"NULL\"}")
        );
    }

    #[test]
    fn the_word_null_is_not_the_absence_of_a_value() {
        assert_eq!(
            (
                params(&text_column(&[Some("NULL")]), Render::Plain),
                params(&text_column(&[None]), Render::Plain),
                params(&text_column(&[]), Render::Plain),
            ),
            (text("{\"NULL\"}"), text("{NULL}"), text("{}"))
        );
    }

    /// The row's array literal is itself an element of the column's, so its
    /// own quoting is escaped once more.
    #[test]
    fn a_list_becomes_its_rows_own_array_literal() {
        let lists = [
            r#"["a\"b",null,"c"]"#,
            "[[1,2],[3]]",
            "[[222,173],[]]",
            "[true,false]",
            "[1700000000123]",
        ];
        let rendered = [
            Encoding::Text,
            Encoding::Number,
            Encoding::Bytes,
            Encoding::Bool,
            Encoding::Date,
        ]
        .iter()
        .zip(lists)
        .map(|(element, list)| params(&text_column(&[Some(list)]), Render::List(*element)))
        .collect::<Vec<_>>();
        assert_eq!(
            rendered,
            vec![
                text(r#"{"{\"a\\\"b\",NULL,\"c\"}"}"#),
                text(r#"{"{{\"1\",\"2\"},{\"3\"}}"}"#),
                text(r#"{"{\"\\\\xdead\",\"\\\\x\"}"}"#),
                text(r#"{"{\"t\",\"f\"}"}"#),
                text(r#"{"{\"2023-11-14T22:13:20.123Z\"}"}"#),
            ]
        );
    }
}
