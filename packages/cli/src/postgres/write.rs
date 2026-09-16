//! Turning a staged batch into the parameters its insert binds.
//!
//! The rows arrive in the arena, written there by JavaScript through lent
//! buffers, and leave as the text the statement takes. Rendering them here is
//! the point of the exercise: the path this replaces built a Postgres array
//! literal in JavaScript, hex-encoding every `bytea` a character at a time,
//! which is the most expensive thing a batch write did.
//!
//! Two statements bind their rows differently and both are reproduced as they
//! were. An insert that unnests takes one array per column; one that lists its
//! values takes every cell of every row, column by column.

use anyhow::{bail, Result};

use crate::columnar::{Arena, Column, ColumnKind};

use super::param::{array_literal, bytea_literal, Param};

/// One cell, rendered as Postgres reads it in text.
///
/// A number goes through Rust's own formatting rather than JavaScript's, which
/// is the safer of the two here: past 1e21 JavaScript switches to exponent
/// notation, which Postgres will not take for an integer column. No column
/// reaches that — an `int8` stops well short — but nothing relies on it either.
fn render(column: &Column, row: usize) -> Result<Option<String>> {
    if column.is_null(row) {
        return Ok(None);
    }
    Ok(Some(match column.kind() {
        ColumnKind::F64 => format_number(column.f64_at(row)),
        ColumnKind::U64 => column.u64_at(row).to_string(),
        ColumnKind::I64 => column.i64_at(row).to_string(),
        ColumnKind::Text => column.str_at(row)?.to_string(),
        ColumnKind::Bytes => bytea_literal(column.bytes_at(row)),
        ColumnKind::List => bail!("a list column has no single value to render"),
    }))
}

fn format_number(value: f64) -> String {
    if value.is_finite() {
        format!("{value}")
    } else {
        // Postgres spells these out for the float types and refuses them
        // everywhere else, which is the error the column should give.
        format!("{value}").replace("inf", "Infinity")
    }
}

/// The parameters for an insert that unnests one array per column.
///
/// A column of arrays cannot go through here: unnesting one would flatten it
/// into the rows rather than keep it as a value, which is why a table holding
/// one takes the other statement instead.
pub fn unnest_params(arena: &Arena) -> Result<Vec<Param>> {
    arena
        .columns()
        .iter()
        .map(|column| {
            if column.kind() == ColumnKind::List {
                bail!("a table with an array column is written one row at a time, not unnested");
            }
            let rendered = (0..arena.rows())
                .map(|row| render(column, row))
                .collect::<Result<Vec<_>>>()?;
            Ok(Param::Text(array_literal(
                rendered.iter().map(Option::as_deref),
            )))
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

    /// The whole point of rendering here: the path this replaces built this
    /// literal in JavaScript, a character at a time.
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
            "a table with an array column is written one row at a time, not unnested"
        );
    }
}
