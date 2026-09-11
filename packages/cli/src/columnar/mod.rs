//! A staging arena that JavaScript fills in place.
//!
//! A batch used to reach Rust as napi typed arrays, JS strings and per-row
//! `Uint8Array`s, every one of which napi copied on the way in. Here Rust owns
//! the memory up front and lends it to JavaScript as `ArrayBuffer`s, so the
//! values are written where they will be read from.
//!
//! # Ownership
//!
//! Read this before touching anything in here: it is the one place a mistake is
//! silent memory corruption rather than a failing test.
//!
//! Every byte an arena lends out is Rust memory. The `ArrayBuffer`s from
//! [`js::expose`] are *external* and their finalize callback does nothing, so
//! garbage-collecting one frees nothing. The `Vec`s inside [`Column`] are the
//! single owner and dropping the [`Arena`] is the single free — there is no
//! path on which both sides release the same allocation.
//!
//! The hazard that remains is the mirror image: a JavaScript view that outlives
//! the bytes it points at. Every buffer is therefore detached before Rust reads
//! or frees what it describes, which turns a stale view into a throw rather
//! than a read of freed memory.
//!
//! # Phases
//!
//! An arena is in exactly one phase at a time, and nothing may straddle them:
//!
//! * *Filling*, from [`js::expose`] until [`js::commit`]. JavaScript writes
//!   through the lent views. Rust must not read the bytes, and must not
//!   reallocate anything except through [`Arena::grow`], which detaches the
//!   buffer it supersedes before the `Vec` moves.
//! * *Sealed*, from [`js::commit`] on. Every buffer is detached and the values
//!   have been checked against the row count, so Rust may read them.
//!
//! Filling must not span an `await`: a stage that yielded to the event loop
//! would let another stage's commit interleave with this one's writes.

pub mod js;

use anyhow::{bail, Context, Result};

/// How a column's values are laid out. The ordinals are part of the interface:
/// JavaScript reads them back from a registered table to pick which view to
/// build over each buffer.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
pub enum ColumnKind {
    F64 = 0,
    U64 = 1,
    I64 = 2,
    Text = 3,
    Bytes = 4,
}

impl ColumnKind {
    pub fn is_variable(self) -> bool {
        matches!(self, ColumnKind::Text | ColumnKind::Bytes)
    }
}

/// What a variable-width column reserves per row before anything grows. A hex
/// address renders to 42 bytes and an id to a little more, so most batches are
/// filled without a single reallocation.
const VARIABLE_GUESS_PER_ROW: usize = 64;
/// Small batches would otherwise start with a capacity that every row grows.
const MIN_VARIABLE_CAPACITY: usize = 1024;

enum Storage {
    /// One 8-byte slot per row. `f64`, `u64` and `i64` all live here as raw
    /// bits, which is exactly what the matching JS typed array writes.
    Fixed(Vec<u64>),
    /// `ends[row]` is where the row's bytes stop; the row before it says where
    /// they start. `data` is a capacity, not a length: past `ends[rows - 1]` it
    /// holds whatever the last growth zeroed.
    Variable { data: Vec<u8>, ends: Vec<u32> },
}

pub struct Column {
    kind: ColumnKind,
    storage: Storage,
    /// One byte per row, non-zero where the row carries no value. A column that
    /// cannot hold NULL still uses it: a delete row names no value for a field,
    /// and what that encodes to is the writer's business, not the arena's.
    nulls: Vec<u8>,
}

impl Column {
    fn new(kind: ColumnKind, rows: usize) -> Self {
        let storage = if kind.is_variable() {
            Storage::Variable {
                data: vec![0; (rows * VARIABLE_GUESS_PER_ROW).max(MIN_VARIABLE_CAPACITY)],
                ends: vec![0; rows],
            }
        } else {
            Storage::Fixed(vec![0; rows])
        };
        Self {
            kind,
            storage,
            nulls: vec![0; rows],
        }
    }

    pub fn kind(&self) -> ColumnKind {
        self.kind
    }

    /// How many rows the column holds, which sealing has already checked
    /// against the arena's row count.
    pub fn len(&self) -> usize {
        match &self.storage {
            Storage::Fixed(words) => words.len(),
            Storage::Variable { ends, .. } => ends.len(),
        }
    }

    pub fn is_null(&self, row: usize) -> bool {
        self.nulls.get(row).copied().unwrap_or(0) != 0
    }

    fn words(&self) -> &[u64] {
        match &self.storage {
            Storage::Fixed(words) => words,
            Storage::Variable { .. } => &[],
        }
    }

    pub fn f64_at(&self, row: usize) -> f64 {
        f64::from_bits(self.words()[row])
    }

    pub fn u64_at(&self, row: usize) -> u64 {
        self.words()[row]
    }

    pub fn i64_at(&self, row: usize) -> i64 {
        self.words()[row] as i64
    }

    pub fn bytes_at(&self, row: usize) -> &[u8] {
        match &self.storage {
            Storage::Variable { data, ends } => {
                let end = ends[row] as usize;
                let start = if row == 0 { 0 } else { ends[row - 1] as usize };
                &data[start..end]
            }
            Storage::Fixed(_) => &[],
        }
    }

    pub fn str_at(&self, row: usize) -> Result<&str> {
        std::str::from_utf8(self.bytes_at(row)).context("staged text is not UTF-8")
    }

    /// Checks what the arena lent out against what it promised, so a writer bug
    /// surfaces as an error on the batch rather than a panic deep in an
    /// encoder — the slicing in [`Column::bytes_at`] trusts these invariants.
    fn seal(&self, name: &str, rows: usize) -> Result<()> {
        if self.nulls.len() != rows {
            bail!("column `{name}` has {} null flags, not {rows}", self.nulls.len());
        }
        match &self.storage {
            Storage::Fixed(words) => {
                if words.len() != rows {
                    bail!("column `{name}` has {} values, not {rows}", words.len());
                }
            }
            Storage::Variable { data, ends } => {
                if ends.len() != rows {
                    bail!("column `{name}` has {} offsets, not {rows}", ends.len());
                }
                let mut previous = 0u32;
                for (row, &end) in ends.iter().enumerate() {
                    if end < previous {
                        bail!("column `{name}` row {row} ends at {end}, before row {} at {previous}", row - 1);
                    }
                    previous = end;
                }
                if previous as usize > data.len() {
                    bail!(
                        "column `{name}` runs to {previous} bytes, past the {} it was given",
                        data.len()
                    );
                }
            }
        }
        Ok(())
    }

    fn buffers(&mut self) -> Vec<(*mut u8, usize)> {
        let nulls = (self.nulls.as_mut_ptr(), self.nulls.len());
        match &mut self.storage {
            Storage::Fixed(words) => {
                vec![(words.as_mut_ptr().cast(), words.len() * 8), nulls]
            }
            Storage::Variable { data, ends } => vec![
                (data.as_mut_ptr(), data.len()),
                (ends.as_mut_ptr().cast(), ends.len() * 4),
                nulls,
            ],
        }
    }
}

/// One batch's columns, allocated together and filled by JavaScript.
pub struct Arena {
    rows: usize,
    columns: Vec<Column>,
    sealed: bool,
}

impl Arena {
    pub fn new(rows: usize, kinds: &[ColumnKind]) -> Result<Self> {
        if rows == 0 {
            bail!("a staged batch needs at least one row");
        }
        Ok(Self {
            rows,
            columns: kinds.iter().map(|&kind| Column::new(kind, rows)).collect(),
            sealed: false,
        })
    }

    pub fn rows(&self) -> usize {
        self.rows
    }

    pub fn columns(&self) -> &[Column] {
        &self.columns
    }

    pub fn is_sealed(&self) -> bool {
        self.sealed
    }

    /// Doubles a variable-width column's payload until it holds `needed` bytes.
    /// The `Vec` moves, so the caller has to have detached the buffer that
    /// described the old allocation before calling this.
    fn grow(&mut self, column: usize, needed: usize) -> Result<(*mut u8, usize)> {
        let column = self
            .columns
            .get_mut(column)
            .with_context(|| format!("no column {column} to grow"))?;
        let Storage::Variable { data, .. } = &mut column.storage else {
            bail!("a fixed-width column is sized from the row count and never grows");
        };
        if needed > u32::MAX as usize {
            bail!("a staged column cannot hold more than {} bytes", u32::MAX);
        }
        let mut capacity = data.len();
        while capacity < needed {
            capacity = capacity.saturating_mul(2).min(u32::MAX as usize);
        }
        data.resize(capacity, 0);
        Ok((data.as_mut_ptr(), data.len()))
    }

    /// Ends the filling phase. Every buffer must already be detached.
    pub fn seal(&mut self, names: &[String]) -> Result<()> {
        if self.sealed {
            bail!("a staged batch cannot be committed twice");
        }
        for (index, column) in self.columns.iter().enumerate() {
            let name = names.get(index).map(String::as_str).unwrap_or("?");
            column.seal(name, self.rows)?;
        }
        self.sealed = true;
        Ok(())
    }
}

/// Filling an arena from Rust, which is how the encoder's own tests build a
/// batch without an isolate. JavaScript writes the same bytes through the lent
/// views instead.
#[cfg(test)]
impl Arena {
    pub fn set_f64(&mut self, column: usize, row: usize, value: f64) {
        self.set_word(column, row, value.to_bits());
    }

    pub fn set_u64(&mut self, column: usize, row: usize, value: u64) {
        self.set_word(column, row, value);
    }

    pub fn set_i64(&mut self, column: usize, row: usize, value: i64) {
        self.set_word(column, row, value as u64);
    }

    fn set_word(&mut self, column: usize, row: usize, bits: u64) {
        match &mut self.columns[column].storage {
            Storage::Fixed(words) => words[row] = bits,
            Storage::Variable { .. } => panic!("column {column} is variable-width"),
        }
    }

    /// Rows have to be written in order: a row's start is where the row before
    /// it ended, which is what JavaScript's cursor does too.
    pub fn set_bytes(&mut self, column: usize, row: usize, value: &[u8]) {
        let Storage::Variable { data, ends } = &mut self.columns[column].storage else {
            panic!("column {column} is fixed-width");
        };
        let start = if row == 0 { 0 } else { ends[row - 1] as usize };
        let end = start + value.len();
        if end > data.len() {
            data.resize(end.next_power_of_two(), 0);
        }
        data[start..end].copy_from_slice(value);
        ends[row] = end as u32;
    }

    pub fn mark_null(&mut self, column: usize, row: usize) {
        self.columns[column].nulls[row] = 1;
    }

    pub fn seal_for_test(&mut self) -> Result<()> {
        let names: Vec<String> = (0..self.columns.len()).map(|i| i.to_string()).collect();
        self.seal(&names)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixed_columns_round_trip_their_bits() {
        let mut arena = Arena::new(2, &[ColumnKind::F64, ColumnKind::U64, ColumnKind::I64]).unwrap();
        arena.set_f64(0, 0, 1.5);
        arena.set_f64(0, 1, -0.25);
        arena.set_u64(1, 0, u64::MAX);
        arena.set_i64(2, 1, i64::MIN);
        arena.seal_for_test().unwrap();
        let columns = arena.columns();
        assert_eq!(
            (
                columns[0].f64_at(0),
                columns[0].f64_at(1),
                columns[1].u64_at(0),
                columns[2].i64_at(1),
            ),
            (1.5, -0.25, u64::MAX, i64::MIN)
        );
    }

    #[test]
    fn variable_columns_slice_by_their_ends() {
        let mut arena = Arena::new(3, &[ColumnKind::Text, ColumnKind::Bytes]).unwrap();
        arena.set_bytes(0, 0, b"first");
        arena.set_bytes(0, 1, &[]);
        arena.mark_null(0, 1);
        arena.set_bytes(0, 2, "ünïcode".as_bytes());
        arena.set_bytes(1, 0, &[]);
        arena.set_bytes(1, 1, &[0xde, 0xad]);
        arena.set_bytes(1, 2, &[0xbe]);
        arena.seal_for_test().unwrap();
        let columns = arena.columns();
        assert_eq!(
            (
                columns[0].str_at(0).unwrap(),
                columns[0].is_null(1),
                columns[0].str_at(1).unwrap(),
                columns[0].str_at(2).unwrap(),
                columns[1].bytes_at(0),
                columns[1].bytes_at(1),
                columns[1].bytes_at(2),
            ),
            ("first", true, "", "ünïcode", &[][..], &[0xde, 0xad][..], &[0xbe][..])
        );
    }

    #[test]
    fn a_value_past_the_initial_guess_grows_the_payload() {
        let long = "x".repeat(MIN_VARIABLE_CAPACITY * 3);
        let mut arena = Arena::new(1, &[ColumnKind::Text]).unwrap();
        arena.set_bytes(0, 0, long.as_bytes());
        arena.seal_for_test().unwrap();
        assert_eq!(arena.columns()[0].str_at(0).unwrap(), long.as_str());
    }

    #[test]
    fn sealing_refuses_offsets_that_run_past_the_payload() {
        let mut arena = Arena::new(1, &[ColumnKind::Text]).unwrap();
        let Storage::Variable { data, ends } = &mut arena.columns[0].storage else {
            unreachable!()
        };
        ends[0] = data.len() as u32 + 1;
        assert_eq!(
            arena.seal_for_test().unwrap_err().to_string(),
            format!(
                "column `0` runs to {} bytes, past the {} it was given",
                MIN_VARIABLE_CAPACITY + 1,
                MIN_VARIABLE_CAPACITY
            )
        );
    }

    #[test]
    fn an_empty_batch_is_not_a_batch() {
        assert_eq!(
            Arena::new(0, &[ColumnKind::F64]).err().unwrap().to_string(),
            "a staged batch needs at least one row"
        );
    }
}
