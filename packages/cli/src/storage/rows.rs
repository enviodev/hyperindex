//! A result set laid out for JavaScript to read, whichever database produced
//! it. Each store decodes its own wire format into [`Cell`]s of the shape the
//! entity schemas on the other side parse, so a row reads the same from
//! Postgres and from ClickHouse.

use std::borrow::Cow;

use anyhow::{bail, Result};

use crate::columnar::{Arena, ColumnKind, ColumnSpec};

/// A decoded column value, in the shape it will take in JavaScript.
#[derive(Debug, Clone, PartialEq)]
pub enum Cell<'a> {
    Null,
    Bool(bool),
    Num(f64),
    Str(Cow<'a, str>),
    Bytes(Cow<'a, [u8]>),
    /// Milliseconds since the Unix epoch, becoming a `Date`.
    Timestamp(f64),
    Arr(Vec<Cell<'a>>),
}

impl Cell<'_> {
    #[cfg(test)]
    pub fn into_owned(self) -> Cell<'static> {
        match self {
            Cell::Null => Cell::Null,
            Cell::Bool(value) => Cell::Bool(value),
            Cell::Num(value) => Cell::Num(value),
            Cell::Str(value) => Cell::Str(Cow::Owned(value.into_owned())),
            Cell::Bytes(value) => Cell::Bytes(Cow::Owned(value.into_owned())),
            Cell::Timestamp(value) => Cell::Timestamp(value),
            Cell::Arr(items) => Cell::Arr(items.into_iter().map(Cell::into_owned).collect()),
        }
    }
}

/// What JavaScript makes of a column, which is more than the slot it travels
/// in: a boolean, a timestamp and a float all ride in the same eight bytes and
/// come out as three different things.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
pub enum ReadKind {
    Float = 0,
    Bool = 1,
    /// Milliseconds, which is what a `Date` is built from.
    Timestamp = 2,
    Text = 3,
    Bytes = 4,
    List = 5,
    /// The document's own text, parsed on the other side.
    Json = 6,
}

impl ReadKind {
    /// The slot it travels in. Three of them share one.
    pub fn slot(self) -> ColumnKind {
        match self {
            ReadKind::Float | ReadKind::Bool | ReadKind::Timestamp => ColumnKind::F64,
            ReadKind::Text | ReadKind::Json => ColumnKind::Text,
            ReadKind::Bytes => ColumnKind::Bytes,
            ReadKind::List => ColumnKind::List,
        }
    }
}

/// One column of a result: its name, what it becomes, and for a list what its
/// elements become.
#[derive(Clone, Debug, PartialEq)]
pub struct ColumnRead {
    pub name: String,
    pub kind: ReadKind,
    pub element: Option<ReadKind>,
}

impl ColumnRead {
    pub fn scalar(name: impl Into<String>, kind: ReadKind) -> Self {
        Self {
            name: name.into(),
            kind,
            element: None,
        }
    }

    pub fn list(name: impl Into<String>, element: ReadKind) -> Self {
        Self {
            name: name.into(),
            kind: ReadKind::List,
            element: Some(element),
        }
    }
}

/// A result laid out column by column, ready to be lent to JavaScript.
pub struct ResultSet {
    pub columns: Vec<ColumnRead>,
    pub arena: Arena,
}

fn write_cell(arena: &mut Arena, column: usize, row: usize, cell: &Cell<'_>) -> Result<()> {
    match cell {
        Cell::Null => arena.mark_null(column, row),
        Cell::Bool(value) => arena.set_f64(column, row, if *value { 1.0 } else { 0.0 }),
        Cell::Num(value) | Cell::Timestamp(value) => arena.set_f64(column, row, *value),
        Cell::Str(value) => arena.set_bytes(column, row, value.as_bytes()),
        Cell::Bytes(value) => arena.set_bytes(column, row, value),
        Cell::Arr(_) => bail!("column {column} holds an array inside an array"),
    }
    Ok(())
}

fn write_element(arena: &mut Arena, column: usize, element: usize, cell: &Cell<'_>) -> Result<()> {
    match cell {
        Cell::Null => arena.mark_element_null(column, element),
        Cell::Bool(value) => arena.set_element_f64(column, element, if *value { 1.0 } else { 0.0 }),
        Cell::Num(value) | Cell::Timestamp(value) => arena.set_element_f64(column, element, *value),
        Cell::Str(value) => arena.set_element_bytes(column, element, value.as_bytes()),
        Cell::Bytes(value) => arena.set_element_bytes(column, element, value),
        Cell::Arr(_) => bail!("column {column} holds an array inside an array"),
    }
    Ok(())
}

/// Lays decoded cells out column by column. `cells` holds every row's cells in
/// turn, one per column.
///
/// The columns are described rather than inferred from the values, so an empty
/// result still says what it would have held and the other side builds the
/// same views over it as for a full one. A list column cannot be sized until
/// its elements have been counted, which is why the values are decoded first.
pub fn lay_out(cells: &[Cell<'_>], columns: Vec<ColumnRead>) -> Result<ResultSet> {
    let width = columns.len();
    let rows = if width == 0 {
        0
    } else {
        if !cells.len().is_multiple_of(width) {
            bail!("{} cells do not fill rows of {width} columns", cells.len());
        }
        cells.len() / width
    };

    let specs = columns
        .iter()
        .enumerate()
        .map(|(column, read)| match (read.kind, read.element) {
            (ReadKind::List, Some(element)) => Ok(ColumnSpec::List {
                element: element.slot(),
                elements: cells
                    .iter()
                    .skip(column)
                    .step_by(width)
                    .map(|cell| match cell {
                        Cell::Arr(items) => items.len(),
                        _ => 0,
                    })
                    .sum(),
            }),
            (ReadKind::List, None) => bail!("list column `{}` names no element kind", read.name),
            (kind, _) => Ok(ColumnSpec::Scalar(kind.slot())),
        })
        .collect::<Result<Vec<_>>>()?;

    let mut arena = Arena::new_filled(rows, &specs);
    let mut written = vec![0usize; width];

    // Indexed rather than chunked: a result with no columns at all has nothing
    // to chunk by.
    for row in 0..rows {
        let row_cells = &cells[row * width..(row + 1) * width];
        for (column, cell) in row_cells.iter().enumerate() {
            match (&specs[column], cell) {
                (ColumnSpec::List { .. }, Cell::Arr(items)) => {
                    for item in items {
                        write_element(&mut arena, column, written[column], item)?;
                        written[column] += 1;
                    }
                    arena.end_list_row(column, row, written[column]);
                }
                // A null array is a row with no elements of its own and the
                // null flag set, not an empty one.
                (ColumnSpec::List { .. }, Cell::Null) => {
                    arena.mark_null(column, row);
                    arena.end_list_row(column, row, written[column]);
                }
                (ColumnSpec::List { .. }, other) => {
                    bail!(
                        "column `{}` is an array but holds {other:?}",
                        columns[column].name
                    )
                }
                (ColumnSpec::Scalar(_), cell) => write_cell(&mut arena, column, row, cell)?,
            }
        }
    }

    let names = columns
        .iter()
        .map(|column| column.name.clone())
        .collect::<Vec<_>>();
    arena.seal(&names)?;
    Ok(ResultSet { columns, arena })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_result_matching_nothing_still_describes_its_columns() {
        let result = lay_out(
            &[],
            vec![
                ColumnRead::scalar("id", ReadKind::Text),
                ColumnRead::list("tags", ReadKind::Text),
            ],
        )
        .unwrap();
        assert_eq!(
            (
                result.arena.rows(),
                result
                    .arena
                    .columns()
                    .iter()
                    .map(|column| column.kind())
                    .collect::<Vec<_>>()
            ),
            (0, vec![ColumnKind::Text, ColumnKind::List])
        );
    }

    #[test]
    fn a_null_list_and_an_empty_one_stay_apart() {
        let result = lay_out(
            &[
                Cell::Arr(vec![Cell::Str("a".into()), Cell::Str("b".into())]),
                Cell::Null,
                Cell::Arr(vec![]),
            ],
            vec![ColumnRead::list("tags", ReadKind::Text)],
        )
        .unwrap();
        let column = &result.arena.columns()[0];
        let (elements, row_ends) = column.list().unwrap();
        assert_eq!(
            (
                (0..3).map(|row| column.is_null(row)).collect::<Vec<_>>(),
                row_ends.to_vec(),
                (0..elements.len())
                    .map(|element| elements.str_at(element).unwrap().to_string())
                    .collect::<Vec<_>>(),
            ),
            (
                vec![false, true, false],
                vec![2, 2, 2],
                vec!["a".to_string(), "b".to_string()]
            )
        );
    }

    #[test]
    fn cells_that_do_not_fill_their_rows_are_refused() {
        assert_eq!(
            lay_out(
                &[Cell::Null, Cell::Null, Cell::Null],
                vec![
                    ColumnRead::scalar("a", ReadKind::Text),
                    ColumnRead::scalar("b", ReadKind::Text),
                ],
            )
            .err()
            .map(|error| error.to_string()),
            Some("3 cells do not fill rows of 2 columns".to_string())
        );
    }
}
