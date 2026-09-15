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

/// The parameters for an insert that lists its values.
///
/// The statement names them column by column — every row's first column, then
/// every row's second — which is the order the placeholders were built in.
pub fn values_params(arena: &Arena) -> Result<Vec<Param>> {
    let mut params = Vec::with_capacity(arena.columns().len() * arena.rows());
    for column in arena.columns() {
        for row in 0..arena.rows() {
            // A null array is not an empty one, and the arena keeps them apart;
            // binding `{}` for a null would quietly store the wrong value.
            params.push(if column.is_null(row) {
                Param::Null
            } else {
                match column.kind() {
                    ColumnKind::List => Param::Text(list_literal(column, row)?),
                    _ => match render(column, row)? {
                        None => Param::Null,
                        Some(text) => Param::Text(text),
                    },
                }
            });
        }
    }
    Ok(params)
}

/// One row of a list column, as the array literal its column takes.
fn list_literal(column: &Column, row: usize) -> Result<String> {
    let (elements, row_ends) = column.list()?;
    let end = row_ends[row] as usize;
    let start = if row == 0 {
        0
    } else {
        row_ends[row - 1] as usize
    };
    let rendered = (start..end)
        .map(|element| render(elements, element))
        .collect::<Result<Vec<_>>>()?;
    Ok(array_literal(rendered.iter().map(Option::as_deref)))
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
    fn values_are_bound_column_by_column() {
        let mut arena = Arena::new_filled(
            2,
            &[
                ColumnSpec::Scalar(ColumnKind::Text),
                ColumnSpec::Scalar(ColumnKind::F64),
            ],
        );
        arena.set_bytes(0, 0, b"a");
        arena.set_bytes(0, 1, b"b");
        arena.set_f64(1, 0, 1.0);
        arena.mark_null(1, 1);
        arena.seal(&["t".to_string(), "n".to_string()]).unwrap();
        assert_eq!(
            values_params(&arena).unwrap(),
            vec![
                Param::Text("a".to_string()),
                Param::Text("b".to_string()),
                Param::Text("1".to_string()),
                Param::Null,
            ]
        );
    }

    /// An array that is absent binds as nothing, not as an array with nothing
    /// in it — two values a column tells apart.
    #[test]
    fn a_null_array_is_not_an_empty_one() {
        let mut arena = Arena::new_filled(
            2,
            &[ColumnSpec::List {
                element: ColumnKind::Text,
                elements: 0,
            }],
        );
        arena.end_list_row(0, 0, 0);
        arena.mark_null(0, 1);
        arena.end_list_row(0, 1, 0);
        arena.seal(&["xs".to_string()]).unwrap();
        assert_eq!(
            values_params(&arena).unwrap(),
            vec![Param::Text("{}".to_string()), Param::Null]
        );
    }

    /// A row's own array, rather than its elements spread across the rows.
    #[test]
    fn a_list_row_binds_as_one_array() {
        let mut arena = Arena::new_filled(
            2,
            &[ColumnSpec::List {
                element: ColumnKind::Text,
                elements: 3,
            }],
        );
        arena.set_element_bytes(0, 0, b"a");
        arena.set_element_bytes(0, 1, b"b");
        arena.end_list_row(0, 0, 2);
        arena.set_element_bytes(0, 2, b"c");
        arena.end_list_row(0, 1, 3);
        arena.seal(&["xs".to_string()]).unwrap();
        assert_eq!(
            values_params(&arena).unwrap(),
            vec![
                Param::Text("{\"a\",\"b\"}".to_string()),
                Param::Text("{\"c\"}".to_string())
            ]
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
