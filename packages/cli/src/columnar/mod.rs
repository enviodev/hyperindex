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
//! * *Filling*, from [`js::expose`] until [`js::detach_all`]. JavaScript writes
//!   through the lent views. Rust must not read the bytes, and must not
//!   reallocate anything except through [`js::grow`], which detaches the buffer
//!   it supersedes before the `Vec` moves.
//! * *Detached*, once [`js::detach_all`] has taken every buffer back. Nothing
//!   outside the arena points into it, so it is safe both to read and to free —
//!   and the step is what [`Arena::seal`] needs to have happened.
//! * *Sealed*, from [`Arena::seal`] on. The values have been checked against the
//!   row count, so the encoder may slice them.
//!
//! An arena that cannot reach *Detached* — a buffer was never handed back, so a
//! view into it may still be live — must never be freed. Its owner drops it from
//! the registry and leaks the allocation instead; one leaked batch is the cheap
//! side of that trade.
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
    /// A column of arrays. The elements are a column of their own, and
    /// `row_ends` says where each row's run of them stops.
    List = 5,
}

impl ColumnKind {
    pub fn is_variable(self) -> bool {
        matches!(self, ColumnKind::Text | ColumnKind::Bytes)
    }
}

/// What a column holds. A list has to say what its elements are and how many of
/// them there are in total, since the element column is sized once.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ColumnSpec {
    Scalar(ColumnKind),
    List {
        element: ColumnKind,
        elements: usize,
    },
}

/// A zeroed vector of `len`, always holding at least one slot's worth of
/// allocation. An empty `Vec` has no pointer to lend, and a result matching
/// nothing — or an array with no elements — would otherwise have nothing to
/// hand JavaScript.
fn sized<T: Clone + Default>(len: usize) -> Vec<T> {
    let mut values = Vec::with_capacity(len.max(1));
    values.resize(len, T::default());
    values
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
    /// The elements laid out as a column in their own right — so an array of
    /// text and an array of bytes are the same shape twice over, rather than
    /// two — and `row_ends[row]` saying which of them belong to that row.
    ///
    /// Sized from a count taken up front, which is what the reading direction
    /// has. Filling one from JavaScript would need the element column to grow
    /// the way a variable one does.
    List {
        elements: Box<Column>,
        row_ends: Vec<u32>,
    },
}

pub struct Column {
    kind: ColumnKind,
    storage: Storage,
    /// One byte per row, non-zero where the row carries no value. A column that
    /// cannot hold NULL still uses it: a delete row names no value for a field,
    /// and what that encodes to is the writer's business, not the arena's.
    nulls: Vec<u8>,
    /// Whether any of `nulls` is set, as sealing found it. Most batches mark
    /// none, and the encoder asks once per cell — without this it would read a
    /// second array, on its own cache lines, for every value it encodes.
    any_null: bool,
}

impl Column {
    fn new(kind: ColumnKind, rows: usize) -> Self {
        let storage = if kind.is_variable() {
            Storage::Variable {
                data: sized((rows * VARIABLE_GUESS_PER_ROW).max(MIN_VARIABLE_CAPACITY)),
                ends: sized(rows),
            }
        } else {
            Storage::Fixed(sized(rows))
        };
        Self {
            kind,
            storage,
            nulls: sized(rows),
            any_null: false,
        }
    }

    /// A column of arrays, with room for `elements` of them in total across the
    /// `rows`. The count has to be known here: the element column is sized once
    /// and never grows.
    fn new_list(element: ColumnKind, rows: usize, elements: usize) -> Self {
        Self {
            kind: ColumnKind::List,
            storage: Storage::List {
                elements: Box::new(Column::new(element, elements)),
                row_ends: sized(rows),
            },
            nulls: sized(rows),
            any_null: false,
        }
    }

    /// The elements of a list column, and where each row's run of them stops.
    /// Nothing in the indexer reaches for these — the Postgres reader walks the
    /// lent buffers from the other side of the boundary and ClickHouse only
    /// writes — but a check on how a list grows does.
    #[cfg(test)]
    pub fn list(&self) -> Result<(&Column, &[u32])> {
        match &self.storage {
            Storage::List { elements, row_ends } => Ok((elements, row_ends)),
            _ => bail!("this column is not a list"),
        }
    }

    // The encoder calls these once per cell, and the `envio` profile builds with
    // neither LTO nor a single codegen unit, so what would otherwise be a field
    // read becomes a cross-module call in the innermost loop there is.
    #[inline]
    pub fn kind(&self) -> ColumnKind {
        self.kind
    }

    /// How many rows the column holds, which sealing has already checked
    /// against the arena's row count.
    pub fn len(&self) -> usize {
        match &self.storage {
            Storage::Fixed(words) => words.len(),
            Storage::Variable { ends, .. } => ends.len(),
            Storage::List { row_ends, .. } => row_ends.len(),
        }
    }

    /// Only meaningful once the arena is sealed: `any_null` is what sealing
    /// found, and before that it is still false.
    #[inline]
    pub fn is_null(&self, row: usize) -> bool {
        self.any_null && self.nulls[row] != 0
    }

    #[inline]
    fn words(&self) -> &[u64] {
        match &self.storage {
            Storage::Fixed(words) => words,
            Storage::Variable { .. } | Storage::List { .. } => &[],
        }
    }

    #[inline]
    pub fn f64_at(&self, row: usize) -> f64 {
        f64::from_bits(self.words()[row])
    }

    #[inline]
    pub fn u64_at(&self, row: usize) -> u64 {
        self.words()[row]
    }

    #[inline]
    pub fn i64_at(&self, row: usize) -> i64 {
        self.words()[row] as i64
    }

    #[inline]
    pub fn bytes_at(&self, row: usize) -> &[u8] {
        match &self.storage {
            Storage::Variable { data, ends } => {
                let end = ends[row] as usize;
                let start = if row == 0 { 0 } else { ends[row - 1] as usize };
                &data[start..end]
            }
            Storage::Fixed(_) | Storage::List { .. } => &[],
        }
    }

    #[inline]
    pub fn str_at(&self, row: usize) -> Result<&str> {
        std::str::from_utf8(self.bytes_at(row)).context("staged text is not UTF-8")
    }

    /// Checks what the arena lent out against what it promised, so a writer bug
    /// surfaces as an error on the batch rather than a panic deep in an
    /// encoder — the slicing in [`Column::bytes_at`] trusts these invariants.
    fn seal(&mut self, name: &str, rows: usize) -> Result<()> {
        if self.nulls.len() != rows {
            bail!(
                "column `{name}` has {} null flags, not {rows}",
                self.nulls.len()
            );
        }
        match &mut self.storage {
            Storage::Fixed(words) => {
                if words.len() != rows {
                    bail!("column `{name}` has {} values, not {rows}", words.len());
                }
            }
            Storage::List { elements, row_ends } => {
                if row_ends.len() != rows {
                    bail!("column `{name}` has {} rows, not {rows}", row_ends.len());
                }
                let mut previous = 0u32;
                for (row, &end) in row_ends.iter().enumerate() {
                    if end < previous {
                        bail!(
                            "column `{name}` row {row} ends at element {end}, before row {} at \
                             {previous}",
                            row - 1
                        );
                    }
                    previous = end;
                }
                let elements_len = elements.len();
                if previous as usize > elements_len {
                    bail!(
                        "column `{name}` runs to element {previous}, past the {elements_len} it \
                         was given"
                    );
                }
                let mut elements =
                    std::mem::replace(elements, Box::new(Column::new(ColumnKind::F64, 0)));
                elements.seal(&format!("{name}'s elements"), elements_len)?;
                if let Storage::List { elements: slot, .. } = &mut self.storage {
                    *slot = elements;
                }
            }
            Storage::Variable { data, ends } => {
                if ends.len() != rows {
                    bail!("column `{name}` has {} offsets, not {rows}", ends.len());
                }
                let mut previous = 0u32;
                for (row, &end) in ends.iter().enumerate() {
                    if end < previous {
                        bail!(
                            "column `{name}` row {row} ends at {end}, before row {} at {previous}",
                            row - 1
                        );
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
        self.any_null = self.nulls.iter().any(|&null| null != 0);
        Ok(())
    }

    fn buffers(&mut self) -> Vec<(*mut u8, usize)> {
        let nulls = (self.nulls.as_mut_ptr(), self.nulls.len().max(1));
        match &mut self.storage {
            Storage::Fixed(words) => {
                vec![(words.as_mut_ptr().cast(), (words.len() * 8).max(8)), nulls]
            }
            Storage::Variable { data, ends } => vec![
                (data.as_mut_ptr(), data.len()),
                (ends.as_mut_ptr().cast(), (ends.len() * 4).max(4)),
                nulls,
            ],
            // The elements' own buffers first, so a reader builds the element
            // column exactly as it would a top-level one, then what cuts them
            // into rows.
            Storage::List { elements, row_ends } => {
                let mut buffers = elements.buffers();
                buffers.push((row_ends.as_mut_ptr().cast(), (row_ends.len() * 4).max(4)));
                buffers.push(nulls);
                buffers
            }
        }
    }
}

/// Which of the phases described at the top of this module an arena is in.
/// Each step happens once, and only in this order.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Phase {
    /// JavaScript holds the buffers and writes through them.
    Filling,
    /// Every buffer is detached, so nothing outside points into the arena.
    Detached,
    /// The values have been checked against the row count and Rust may read them.
    Sealed,
    /// JavaScript holds the buffers and reads through them. The mirror of
    /// `Filling`, and it ends the same way: every buffer detached before the
    /// memory behind it is freed.
    Reading,
}

/// One batch's columns, allocated together and filled by JavaScript.
pub struct Arena {
    rows: usize,
    columns: Vec<Column>,
    phase: Phase,
}

impl Arena {
    pub fn new(rows: usize, kinds: &[ColumnKind]) -> Result<Self> {
        if rows == 0 {
            bail!("a staged batch needs at least one row");
        }
        Ok(Self::with_rows(rows, kinds))
    }

    fn with_rows(rows: usize, kinds: &[ColumnKind]) -> Self {
        Self {
            rows,
            columns: kinds.iter().map(|&kind| Column::new(kind, rows)).collect(),
            phase: Phase::Filling,
        }
    }

    /// An arena Rust fills and JavaScript reads — a result set on its way out,
    /// rather than a batch on its way in. Nothing is lent yet, so it starts
    /// where a filled one that has handed its buffers back would be.
    /// Unlike a staged batch, this one may hold no rows: a query matching
    /// nothing is an ordinary answer, and the columns still have to be
    /// described so the other side builds the same views over them.
    pub fn new_filled(rows: usize, specs: &[ColumnSpec]) -> Self {
        Self {
            rows,
            columns: specs
                .iter()
                .map(|spec| match *spec {
                    ColumnSpec::Scalar(kind) => Column::new(kind, rows),
                    ColumnSpec::List { element, elements } => {
                        Column::new_list(element, rows, elements)
                    }
                })
                .collect(),
            phase: Phase::Detached,
        }
    }

    /// Hands a laid-out arena back to JavaScript to fill. The reading direction
    /// lays one out and reads it here; the writing direction lays one out and
    /// lets JavaScript write it, which is the same memory before anything is in
    /// it.
    pub fn reopen_for_filling(&mut self) {
        self.phase = Phase::Filling;
    }

    pub fn rows(&self) -> usize {
        self.rows
    }

    pub fn columns(&self) -> &[Column] {
        &self.columns
    }

    pub fn is_sealed(&self) -> bool {
        self.phase == Phase::Sealed
    }

    /// Whether JavaScript currently holds the arena's buffers, in either
    /// direction. Both end by detaching every one of them.
    fn is_lent(&self) -> bool {
        self.phase == Phase::Filling || self.phase == Phase::Reading
    }

    /// Hands sealed values to JavaScript to read. Only from `Sealed`: the
    /// values have been checked against the row count by then, so the views
    /// built over them describe what is actually there.
    fn start_reading(&mut self) -> Result<()> {
        if self.phase != Phase::Sealed {
            bail!("only a sealed batch can be read, and only once");
        }
        self.phase = Phase::Reading;
        Ok(())
    }

    /// Records that nothing outside the arena points into it any more. Only
    /// [`js::detach_all`] may say so, having detached the buffers itself.
    fn finish_lending(&mut self) {
        self.phase = Phase::Detached;
    }

    /// Every buffer the arena currently has lent out. A commit that does not
    /// detach all of these has left JavaScript able to write into memory Rust
    /// is about to read.
    fn buffer_ptrs(&mut self) -> Vec<*const u8> {
        self.columns
            .iter_mut()
            .flat_map(Column::buffers)
            .map(|(data, _)| data.cast_const())
            .collect()
    }

    /// Doubles a variable-width column's payload until it holds `needed` bytes,
    /// and reports where it moved to.
    ///
    /// `current` is what the caller believes the payload to be. It is checked
    /// rather than trusted: growing a column whose buffer the caller does not
    /// actually hold would leave that buffer describing a freed allocation.
    fn grow(
        &mut self,
        column: usize,
        needed: usize,
        current: *const u8,
    ) -> Result<(*mut u8, usize)> {
        let index = column;
        let column = self
            .columns
            .get_mut(index)
            .with_context(|| format!("no column {index} to grow"))?;
        // A list's payload is its elements', so growing the column grows that:
        // the elements are sized from a count taken up front, but how many bytes
        // they come to is only known as they are written.
        let storage = match &mut column.storage {
            Storage::List { elements, .. } => &mut elements.storage,
            storage => storage,
        };
        let Storage::Variable { data, .. } = storage else {
            bail!("a fixed-width column is sized from the row count and never grows");
        };
        if !std::ptr::eq(data.as_ptr(), current) {
            bail!("the buffer handed to grow is not column {index}'s payload");
        }
        if needed > u32::MAX as usize {
            bail!("a staged column cannot hold more than {} bytes", u32::MAX);
        }
        let mut capacity = data.len().max(1);
        while capacity < needed {
            capacity = capacity.saturating_mul(2).min(u32::MAX as usize);
        }
        data.resize(capacity, 0);
        Ok((data.as_mut_ptr(), data.len()))
    }

    /// Checks the values against the row count, which is what lets the encoder
    /// slice them. Only reachable once every buffer is detached, so nothing can
    /// change them between the check and the read.
    pub fn seal(&mut self, names: &[String]) -> Result<()> {
        if self.phase != Phase::Detached {
            bail!("a staged batch can only be sealed once, and not while it is still lent out");
        }
        for (index, column) in self.columns.iter_mut().enumerate() {
            let name = names.get(index).map(String::as_str).unwrap_or("?");
            column.seal(name, self.rows)?;
        }
        self.phase = Phase::Sealed;
        Ok(())
    }
}

/// Filling an arena from Rust: how a result set is laid out on its way to
/// JavaScript, and how the encoder's own tests build a batch without an isolate.
/// On the way in it is JavaScript that writes these same bytes, through the
/// lent views.
impl Column {
    fn write_word(&mut self, row: usize, bits: u64) {
        match &mut self.storage {
            Storage::Fixed(words) => words[row] = bits,
            Storage::Variable { .. } | Storage::List { .. } => {
                panic!("this column holds no fixed-width slot")
            }
        }
    }

    /// Rows have to be written in order: a row's start is where the row before
    /// it ended, which is what JavaScript's cursor does too.
    fn write_bytes(&mut self, row: usize, value: &[u8]) {
        let Storage::Variable { data, ends } = &mut self.storage else {
            panic!("this column holds no bytes");
        };
        let start = if row == 0 { 0 } else { ends[row - 1] as usize };
        let end = start + value.len();
        if end > data.len() {
            data.resize(end.next_power_of_two(), 0);
        }
        data[start..end].copy_from_slice(value);
        ends[row] = end as u32;
    }

    fn write_null(&mut self, row: usize) {
        self.nulls[row] = 1;
        self.any_null = true;
        // A variable-width row still has to say where it ends, or the row after
        // it would start from the wrong place.
        if let Storage::Variable { ends, .. } = &mut self.storage {
            ends[row] = if row == 0 { 0 } else { ends[row - 1] };
        }
    }

    fn elements_mut(&mut self) -> &mut Column {
        match &mut self.storage {
            Storage::List { elements, .. } => elements,
            _ => panic!("this column holds no elements"),
        }
    }
}

impl Arena {
    pub fn set_f64(&mut self, column: usize, row: usize, value: f64) {
        self.columns[column].write_word(row, value.to_bits());
    }

    pub fn set_bytes(&mut self, column: usize, row: usize, value: &[u8]) {
        self.columns[column].write_bytes(row, value);
    }

    pub fn mark_null(&mut self, column: usize, row: usize) {
        self.columns[column].write_null(row);
    }

    /// The element column of a list, written by the same calls as a top-level
    /// one — `element` counts across the whole column, not within a row.
    pub fn set_element_f64(&mut self, column: usize, element: usize, value: f64) {
        self.columns[column]
            .elements_mut()
            .write_word(element, value.to_bits());
    }

    pub fn set_element_bytes(&mut self, column: usize, element: usize, value: &[u8]) {
        self.columns[column]
            .elements_mut()
            .write_bytes(element, value);
    }

    pub fn mark_element_null(&mut self, column: usize, element: usize) {
        self.columns[column].elements_mut().write_null(element);
    }

    /// Closes a list row at `elements` written so far, which is where the next
    /// row's own elements begin.
    pub fn end_list_row(&mut self, column: usize, row: usize, elements: usize) {
        match &mut self.columns[column].storage {
            Storage::List { row_ends, .. } => row_ends[row] = elements as u32,
            _ => panic!("column {column} is not a list"),
        }
    }

    #[cfg(test)]
    pub fn set_u64(&mut self, column: usize, row: usize, value: u64) {
        self.columns[column].write_word(row, value);
    }

    #[cfg(test)]
    pub fn set_i64(&mut self, column: usize, row: usize, value: i64) {
        self.columns[column].write_word(row, value as u64);
    }

    /// Nothing was lent out — the values came from Rust, not from an isolate —
    /// so there is no buffer to detach before sealing.
    #[cfg(test)]
    pub fn seal_unlent(&mut self, names: &[String]) -> Result<()> {
        self.finish_lending();
        self.seal(names)
    }

    #[cfg(test)]
    pub fn seal_for_test(&mut self) -> Result<()> {
        let names: Vec<String> = (0..self.columns.len()).map(|i| i.to_string()).collect();
        self.seal_unlent(&names)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixed_columns_round_trip_their_bits() {
        let mut arena =
            Arena::new(2, &[ColumnKind::F64, ColumnKind::U64, ColumnKind::I64]).unwrap();
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
            (
                "first",
                true,
                "",
                "ünïcode",
                &[][..],
                &[0xde, 0xad][..],
                &[0xbe][..]
            )
        );
    }

    #[test]
    fn a_list_grows_the_payload_its_elements_share() {
        let long = "x".repeat(MIN_VARIABLE_CAPACITY * 2);
        let mut arena = Arena::new_filled(
            1,
            &[ColumnSpec::List {
                element: ColumnKind::Text,
                elements: 1,
            }],
        );
        arena.set_element_bytes(0, 0, long.as_bytes());
        arena.end_list_row(0, 0, 1);
        arena.seal(&["xs".to_string()]).unwrap();
        let (elements, _) = arena.columns()[0].list().unwrap();
        assert_eq!(elements.str_at(0).unwrap(), long.as_str());
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
    fn a_list_column_cuts_its_elements_into_rows() {
        let mut arena = Arena::new_filled(
            3,
            &[ColumnSpec::List {
                element: ColumnKind::Text,
                elements: 4,
            }],
        );
        // ["a", "bb"], [], ["c", "d"]
        arena.set_element_bytes(0, 0, b"a");
        arena.set_element_bytes(0, 1, b"bb");
        arena.end_list_row(0, 0, 2);
        arena.end_list_row(0, 1, 2);
        arena.set_element_bytes(0, 2, b"c");
        arena.set_element_bytes(0, 3, b"d");
        arena.end_list_row(0, 2, 4);
        arena.seal(&["tags".to_string()]).unwrap();
        assert_eq!(arena.columns()[0].len(), 3);
    }

    /// A row with no elements and a row that has none because it is null end at
    /// the same element; only the null flag tells them apart.
    #[test]
    fn a_null_list_row_is_not_an_empty_one() {
        let mut arena = Arena::new_filled(
            2,
            &[ColumnSpec::List {
                element: ColumnKind::F64,
                elements: 0,
            }],
        );
        arena.end_list_row(0, 0, 0);
        arena.mark_null(0, 1);
        arena.end_list_row(0, 1, 0);
        arena.seal(&["xs".to_string()]).unwrap();
        assert_eq!(
            (arena.columns()[0].is_null(0), arena.columns()[0].is_null(1)),
            (false, true)
        );
    }

    #[test]
    fn a_list_row_ending_past_its_elements_is_refused() {
        let mut arena = Arena::new_filled(
            1,
            &[ColumnSpec::List {
                element: ColumnKind::F64,
                elements: 1,
            }],
        );
        arena.end_list_row(0, 0, 2);
        assert_eq!(
            arena.seal(&["xs".to_string()]).unwrap_err().to_string(),
            "column `xs` runs to element 2, past the 1 it was given"
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
