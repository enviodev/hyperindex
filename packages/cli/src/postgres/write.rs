//! Turning a staged batch into the parameters its insert binds.
//!
//! The rows arrive in the arena, written there by JavaScript through lent
//! buffers, and leave as one array literal per column, for an insert that
//! unnests them.

use anyhow::{bail, Result};
use std::fmt::Write;

use crate::columnar::{Arena, Column, ColumnKind};

use super::param::Param;

/// Writes one cell into the literal being built, escaped as an element of it.
///
/// The element is already inside its quotes, where only the quote and the
/// backslash still mean anything — so text is the only kind with anything to
/// escape. A number goes through Rust's `Display`, which never switches to
/// exponent notation: Postgres refuses that for an integer column.
fn write_cell(into: &mut String, column: &Column, row: usize) -> Result<()> {
    match column.kind() {
        ColumnKind::F64 => write_number(into, column.f64_at(row)),
        ColumnKind::U64 => {
            let _ = write!(into, "{}", column.u64_at(row));
        }
        ColumnKind::I64 => {
            let _ = write!(into, "{}", column.i64_at(row));
        }
        ColumnKind::Text => {
            for character in column.str_at(row)?.chars() {
                if character == '"' || character == '\\' {
                    into.push('\\');
                }
                into.push(character);
            }
        }
        // `\x` then the bytes in hex, with the backslash escaped because the
        // element is inside quotes.
        ColumnKind::Bytes => {
            into.push_str("\\\\x");
            for byte in column.bytes_at(row) {
                let _ = write!(into, "{byte:02x}");
            }
        }
        ColumnKind::List => bail!("a list column has no single value to render"),
    }
    Ok(())
}

fn write_number(into: &mut String, value: f64) {
    if value.is_finite() {
        let _ = write!(into, "{value}");
    } else {
        // Postgres spells these out for the float types and refuses them
        // everywhere else, which is the error the column should give.
        into.push_str(&format!("{value}").replace("inf", "Infinity"));
    }
}

/// The parameters for an insert that unnests one array per column.
///
/// Each column becomes one array literal, built in a single pass: a cell is
/// written where it will be read from rather than rendered to a string of its
/// own first, which for a batch is one allocation instead of one per cell.
pub fn unnest_params(arena: &Arena) -> Result<Vec<Param>> {
    arena
        .columns()
        .iter()
        .map(|column| {
            let rows = arena.rows();
            let mut literal = String::with_capacity(rows * 24 + 2);
            literal.push('{');
            for row in 0..rows {
                if row > 0 {
                    literal.push(',');
                }
                if column.is_null(row) {
                    // Quoted, it would be the four-character string instead of
                    // the absence of a value.
                    literal.push_str("NULL");
                    continue;
                }
                literal.push('"');
                write_cell(&mut literal, column, row)?;
                literal.push('"');
            }
            literal.push('}');
            Ok(Param::Text(literal))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::columnar::ColumnSpec;

    fn text_column(values: &[Option<&str>]) -> Arena {
        let mut arena = Arena::new_filled(values.len(), &[ColumnSpec::Scalar(ColumnKind::Text)]);
        for (row, value) in values.iter().enumerate() {
            match value {
                None => arena.mark_null(0, row),
                Some(value) => arena.set_bytes(0, row, value.as_bytes()),
            }
        }
        arena.seal(&["c".to_string()]).unwrap();
        arena
    }

    #[test]
    fn a_column_becomes_one_array_literal() {
        let arena = text_column(&[Some("a"), None, Some("b")]);
        assert_eq!(
            unnest_params(&arena).unwrap(),
            vec![Param::Text("{\"a\",NULL,\"b\"}".to_string())]
        );
    }

    #[test]
    fn bytes_render_as_a_hex_literal() {
        let mut arena = Arena::new_filled(2, &[ColumnSpec::Scalar(ColumnKind::Bytes)]);
        arena.set_bytes(0, 0, &[0xde, 0xad]);
        arena.mark_null(0, 1);
        arena.seal(&["b".to_string()]).unwrap();
        assert_eq!(
            unnest_params(&arena).unwrap(),
            vec![Param::Text("{\"\\\\xdead\",NULL}".to_string())]
        );
    }

    /// A whole number is written without a point: the column it goes into is an
    /// integer one, and `1.0` is not something it takes.
    #[test]
    fn a_whole_number_keeps_no_decimal_point() {
        let mut arena = Arena::new_filled(4, &[ColumnSpec::Scalar(ColumnKind::F64)]);
        arena.set_f64(0, 0, 1.0);
        arena.set_f64(0, 1, -7.0);
        arena.set_f64(0, 2, 1.5);
        arena.set_f64(0, 3, 9007199254740991.0);
        arena.seal(&["n".to_string()]).unwrap();
        assert_eq!(
            unnest_params(&arena).unwrap(),
            vec![Param::Text(
                "{\"1\",\"-7\",\"1.5\",\"9007199254740991\"}".to_string()
            )]
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
            unnest_params(&arena).unwrap(),
            vec![Param::Text(
                "{\"a,b\",\"{nested}\",\"has \\\"quotes\\\"\",\"back\\\\slash\",\"\",\"NULL\"}"
                    .to_string()
            )]
        );
    }

    /// The string `NULL` is a value; the absence of one is not. Quoting keeps
    /// them apart.
    #[test]
    fn the_word_null_is_not_the_absence_of_a_value() {
        assert_eq!(
            unnest_params(&text_column(&[Some("NULL")])).unwrap(),
            vec![Param::Text("{\"NULL\"}".to_string())]
        );
        assert_eq!(
            unnest_params(&text_column(&[None])).unwrap(),
            vec![Param::Text("{NULL}".to_string())]
        );
    }

    #[test]
    fn a_column_with_no_rows_is_a_pair_of_braces() {
        assert_eq!(
            unnest_params(&text_column(&[])).unwrap(),
            vec![Param::Text("{}".to_string())]
        );
    }

    #[test]
    fn unnesting_refuses_a_column_of_arrays() {
        let mut arena = Arena::new_filled(
            1,
            &[ColumnSpec::List {
                element: ColumnKind::Text,
                elements: 0,
            }],
        );
        arena.end_list_row(0, 0, 0);
        arena.seal(&["xs".to_string()]).unwrap();
        assert_eq!(
            unnest_params(&arena).unwrap_err().to_string(),
            "a list column has no single value to render"
        );
    }
}
