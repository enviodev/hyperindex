//! Columnar materialisation shared by the per-chain field stores
//! (`TransactionStore`, `BlockStore`). Selected fields are decoded in bulk, off
//! the JS thread, into a struct-of-arrays form; the main thread then zips the
//! columns into plain JS objects, setting only the fields a row selected. The
//! cell type is concrete per column, so decode runs off-thread and only the
//! object zip touches the JS thread.

use alloy_primitives::U256;
use anyhow::{bail, Context, Result};
use napi::bindgen_prelude::{BigInt, ToNapiValue};
use napi::sys;
use napi_derive::napi;

use crate::columnar::{Arena, ColumnSpec};
use crate::event_store::ArenaShape;
use crate::evm_hypersync_source::types::{
    AccessList as AccessListItem, Authorization as AuthorizationItem,
};
use crate::storage::rows::{ColumnRead, ReadKind};

/// Ecosystem selecting `materialize`'s decoder, shared by every per-chain field
/// store (`TransactionStore`, `BlockStore`). A store is per-chain, hence
/// single-ecosystem, and is fixed at construction.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Ecosystem {
    Evm,
    Svm,
    Fuel,
}

/// A byte-slice view of anything that can cheaply produce one (hashes,
/// addresses, raw strings) — shared by every column-fill helper across stores.
pub fn bytes<T: AsRef<[u8]>>(v: &T) -> &[u8] {
    v.as_ref()
}

/// Ordered field names for an ecosystem's field-code enum, the `#[napi]`-exposed
/// contract each store's ReScript field-name array is tested against.
pub fn field_names<F: Copy>(
    variants: &'static [F],
    name: impl Fn(F) -> &'static str,
) -> Vec<String> {
    variants.iter().map(|&f| name(f).to_string()).collect()
}

#[napi(object)]
#[derive(Clone)]
pub struct SvmLamportsOut {
    pub pre: Option<BigInt>,
    pub post: Option<BigInt>,
}

#[napi(object)]
#[derive(Clone)]
pub struct SvmAccountTokenOut {
    pub mint: String,
    pub owner: Option<String>,
    pub decimals: Option<u8>,
    pub pre_amount: Option<BigInt>,
    pub post_amount: Option<BigInt>,
}

#[napi(object)]
#[derive(Clone)]
pub struct SvmAccountActivityOut {
    pub address: String,
    pub transaction_account_index: Option<i64>,
    pub is_signer: Option<bool>,
    pub is_writable: Option<bool>,
    pub lamports: Option<SvmLamportsOut>,
    pub token: Option<SvmAccountTokenOut>,
}

/// One materialised field across all rows: struct-of-arrays, one entry per row,
/// `None` where the row is missing or the value is absent. Every variant's
/// element type is `Send` and `ToNapiValue`. New ecosystems/field kinds extend
/// the type set as needed.
pub enum Column {
    I64(Vec<Option<i64>>),
    F64(Vec<Option<f64>>),
    Bool(Vec<Option<bool>>),
    Big(Vec<Option<BigInt>>),
    Str(Vec<Option<String>>),
    StrVec(Vec<Option<Vec<String>>>),
    AccessList(Vec<Option<Vec<AccessListItem>>>),
    AuthList(Vec<Option<Vec<AuthorizationItem>>>),
    AccountActivities(Vec<Option<Vec<SvmAccountActivityOut>>>),
}

impl Column {
    /// Set this column's value on each object under `key`, skipping `None` cells
    /// so unselected/absent fields stay absent on the JS object.
    unsafe fn set_on(
        self,
        env: sys::napi_env,
        objs: &[sys::napi_value],
        key: sys::napi_value,
    ) -> napi::Result<()> {
        match self {
            Column::I64(v) => set_col(env, objs, key, v),
            Column::F64(v) => set_col(env, objs, key, v),
            Column::Bool(v) => set_col(env, objs, key, v),
            Column::Big(v) => set_col(env, objs, key, v),
            Column::Str(v) => set_col(env, objs, key, v),
            Column::StrVec(v) => set_col(env, objs, key, v),
            Column::AccessList(v) => set_col(env, objs, key, v),
            Column::AuthList(v) => set_col(env, objs, key, v),
            Column::AccountActivities(v) => set_col(env, objs, key, v),
        }
    }
}

unsafe fn set_col<T: ToNapiValue>(
    env: sys::napi_env,
    objs: &[sys::napi_value],
    key: sys::napi_value,
    values: Vec<Option<T>>,
) -> napi::Result<()> {
    for (obj, cell) in objs.iter().zip(values) {
        if let Some(v) = cell {
            let js = T::to_napi_value(env, v)?;
            if sys::napi_set_property(env, *obj, key, js) != sys::Status::napi_ok {
                return Err(napi::Error::from_reason("napi_set_property failed"));
            }
        }
    }
    Ok(())
}

/// A page of materialised rows in columnar form. `ToNapiValue` zips it into a JS
/// array of objects on the main thread; each object carries only the selected
/// fields.
pub struct Columns {
    pub len: usize,
    pub columns: Vec<(&'static str, Column)>,
}

impl ToNapiValue for Columns {
    unsafe fn to_napi_value(env: sys::napi_env, val: Self) -> napi::Result<sys::napi_value> {
        let mut arr = std::ptr::null_mut();
        if sys::napi_create_array_with_length(env, val.len, &mut arr) != sys::Status::napi_ok {
            return Err(napi::Error::from_reason(
                "napi_create_array_with_length failed",
            ));
        }

        let mut objs = Vec::with_capacity(val.len);
        for _ in 0..val.len {
            let mut obj = std::ptr::null_mut();
            if sys::napi_create_object(env, &mut obj) != sys::Status::napi_ok {
                return Err(napi::Error::from_reason("napi_create_object failed"));
            }
            objs.push(obj);
        }

        for (name, col) in val.columns {
            // Create the JS property-key string once per column and reuse it for
            // every row; `napi_set_named_property` would re-create it per cell.
            let mut key = std::ptr::null_mut();
            if sys::napi_create_string_utf8(
                env,
                name.as_ptr() as *const std::os::raw::c_char,
                name.len() as isize,
                &mut key,
            ) != sys::Status::napi_ok
            {
                return Err(napi::Error::from_reason("napi_create_string_utf8 failed"));
            }
            col.set_on(env, &objs, key)?;
        }

        for (i, obj) in objs.iter().enumerate() {
            if sys::napi_set_element(env, arr, i as u32, *obj) != sys::Status::napi_ok {
                return Err(napi::Error::from_reason("napi_set_element failed"));
            }
        }

        Ok(arr)
    }
}

/// A batch's blocks or transactions on their way to JavaScript: an arena with
/// a row per block or transaction and a column per selected field `Reading`
/// reads, null where a row has no value. The nested fields, which have no
/// column shape, come as values beside it, `None` where absent.
#[napi(object, object_from_js = false)]
pub struct FieldRows {
    pub shape: ArenaShape,
    pub access_list: Option<Vec<Option<Vec<AccessListItem>>>>,
    pub authorization_list: Option<Vec<Option<Vec<AuthorizationItem>>>>,
    pub account_activities: Option<Vec<Option<Vec<SvmAccountActivityOut>>>>,
}

/// A JS bigint's decimal text, which `Reading`'s `BigInt` kind parses.
fn bigint_text(value: &BigInt) -> Result<String> {
    if value.words.len() > 4 {
        bail!("a {}-word bigint does not fit 256 bits", value.words.len());
    }
    let mut limbs = [0u64; 4];
    limbs[..value.words.len()].copy_from_slice(&value.words);
    let magnitude = U256::from_limbs(limbs);
    Ok(if value.sign_bit && !magnitude.is_zero() {
        format!("-{magnitude}")
    } else {
        magnitude.to_string()
    })
}

fn write_cells<T>(
    arena: &mut Arena,
    column: usize,
    cells: &[Option<T>],
    mut write: impl FnMut(&mut Arena, usize, &T) -> Result<()>,
) -> Result<()> {
    for (row, cell) in cells.iter().enumerate() {
        match cell {
            Some(value) => write(arena, row, value)?,
            None => arena.mark_null(column, row),
        }
    }
    Ok(())
}

impl Columns {
    /// Lays the flat columns out as a sealed arena; the nested ones travel
    /// beside it.
    pub fn into_arena(self) -> Result<(Arena, FieldRows)> {
        let mut reads = Vec::new();
        let mut flat = Vec::new();
        let mut rows = FieldRows {
            shape: ArenaShape::of(&[], self.len),
            access_list: None,
            authorization_list: None,
            account_activities: None,
        };
        for (name, column) in self.columns {
            let (read, spec) = match &column {
                Column::I64(_) | Column::F64(_) => (ReadKind::Float, None),
                Column::Bool(_) => (ReadKind::Bool, None),
                Column::Big(_) => (ReadKind::BigInt, None),
                Column::Str(_) => (ReadKind::Text, None),
                Column::StrVec(lists) => (
                    ReadKind::List,
                    Some(lists.iter().flatten().map(Vec::len).sum::<usize>()),
                ),
                Column::AccessList(_) => {
                    let Column::AccessList(values) = column else {
                        unreachable!()
                    };
                    rows.access_list = Some(values);
                    continue;
                }
                Column::AuthList(_) => {
                    let Column::AuthList(values) = column else {
                        unreachable!()
                    };
                    rows.authorization_list = Some(values);
                    continue;
                }
                Column::AccountActivities(_) => {
                    let Column::AccountActivities(values) = column else {
                        unreachable!()
                    };
                    rows.account_activities = Some(values);
                    continue;
                }
            };
            reads.push(match spec {
                Some(_) => ColumnRead::list(name, ReadKind::Text),
                None => ColumnRead::scalar(name, read),
            });
            flat.push((column, spec));
        }

        let specs: Vec<ColumnSpec> = reads
            .iter()
            .zip(&flat)
            .map(|(read, (_, elements))| match elements {
                Some(elements) => ColumnSpec::List {
                    element: ReadKind::Text.slot(),
                    elements: *elements,
                },
                None => ColumnSpec::Scalar(read.kind.slot()),
            })
            .collect();
        let mut arena = Arena::new_filled(self.len, &specs);
        for (index, (column, _)) in flat.into_iter().enumerate() {
            match column {
                Column::I64(cells) => {
                    write_cells(&mut arena, index, &cells, |arena, row, value| {
                        arena.set_f64(index, row, *value as f64);
                        Ok(())
                    })?
                }
                Column::F64(cells) => {
                    write_cells(&mut arena, index, &cells, |arena, row, value| {
                        arena.set_f64(index, row, *value);
                        Ok(())
                    })?
                }
                Column::Bool(cells) => {
                    write_cells(&mut arena, index, &cells, |arena, row, value| {
                        arena.set_f64(index, row, if *value { 1.0 } else { 0.0 });
                        Ok(())
                    })?
                }
                Column::Big(cells) => {
                    write_cells(&mut arena, index, &cells, |arena, row, value| {
                        arena.set_bytes(index, row, bigint_text(value)?.as_bytes());
                        Ok(())
                    })?
                }
                Column::Str(cells) => {
                    write_cells(&mut arena, index, &cells, |arena, row, value| {
                        arena.set_bytes(index, row, value.as_bytes());
                        Ok(())
                    })?
                }
                Column::StrVec(cells) => {
                    let mut written = 0;
                    for (row, cell) in cells.iter().enumerate() {
                        match cell {
                            Some(values) => {
                                for value in values {
                                    arena.set_element_bytes(index, written, value.as_bytes());
                                    written += 1;
                                }
                            }
                            None => arena.mark_null(index, row),
                        }
                        arena.end_list_row(index, row, written);
                    }
                }
                Column::AccessList(_) | Column::AuthList(_) | Column::AccountActivities(_) => {
                    unreachable!("nested columns travel beside the arena")
                }
            }
        }
        rows.shape = ArenaShape::of(&reads, self.len);
        arena.seal(&rows.shape.names)?;
        Ok((arena, rows))
    }
}

/// Iterate an ecosystem's field variants and decode each whose bit is set in the
/// union of `masks` (a column is built when any row selects it; the gathered
/// scratch already applies each row's own mask within it). Shared by every
/// store; only the per-field `decode` table differs. A decode error names the
/// field so one bad row aborts the batch's materialisation with an actionable
/// message.
pub fn build_columns<F: Copy>(
    variants: &'static [F],
    masks: &[u64],
    len: usize,
    ordinal: impl Fn(F) -> u32,
    name: impl Fn(F) -> &'static str,
    decode: impl Fn(F) -> Result<Column>,
) -> Result<Columns> {
    let union = masks.iter().fold(0u64, |acc, &m| acc | m);
    let mut columns: Vec<(&'static str, Column)> = Vec::new();
    for &field in variants {
        if union & (1u64 << ordinal(field)) == 0 {
            continue;
        }
        let field_name = name(field);
        let column = decode(field).with_context(|| format!("decoding field '{field_name}'"))?;
        columns.push((field_name, column));
    }
    Ok(Columns { len, columns })
}

/// Reading materialised columns back out, for the store tests across this crate.
#[cfg(test)]
pub(crate) mod test_support {
    use super::{Column, Columns};

    pub(crate) fn column<'a>(cols: &'a Columns, name: &str) -> Option<&'a Column> {
        cols.columns
            .iter()
            .find(|(n, _)| *n == name)
            .map(|(_, c)| c)
    }

    /// The string column `name`, one entry per materialised row (`None` where
    /// the store had no row, or the row no value).
    pub(crate) fn str_column(cols: &Columns, name: &str) -> Vec<Option<String>> {
        match column(cols, name) {
            Some(Column::Str(values)) => values.clone(),
            _ => panic!("expected a {name} string column"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lays_flat_columns_out_with_nulls_and_keeps_nested_ones_beside() {
        let columns = Columns {
            len: 2,
            columns: vec![
                ("number", Column::I64(vec![Some(7), None])),
                (
                    "value",
                    Column::Big(vec![
                        Some(BigInt {
                            sign_bit: true,
                            words: vec![5],
                        }),
                        None,
                    ]),
                ),
                ("hash", Column::Str(vec![None, Some("0xab".into())])),
                (
                    "uncles",
                    Column::StrVec(vec![Some(vec!["a".into(), "b".into()]), None]),
                ),
                (
                    "accessList",
                    Column::AccessList(vec![
                        None,
                        Some(vec![AccessListItem {
                            address: Some("0xcc".into()),
                            storage_keys: None,
                        }]),
                    ]),
                ),
            ],
        };
        let (arena, rows) = columns.into_arena().unwrap();
        let columns = arena.columns();
        let (elements, ends) = columns[3].list().unwrap();
        let nested: Vec<Option<usize>> = rows
            .access_list
            .unwrap()
            .iter()
            .map(|cell| cell.as_ref().map(Vec::len))
            .collect();
        assert_eq!(
            (
                rows.shape.names,
                rows.shape.kinds,
                columns[0].f64_at(0),
                columns[0].is_null(1),
                columns[1].str_at(0).unwrap(),
                columns[2].is_null(0),
                columns[2].str_at(1).unwrap(),
                (
                    elements.str_at(1).unwrap(),
                    ends.to_vec(),
                    columns[3].is_null(1)
                ),
                nested,
            ),
            (
                vec![
                    "number".to_string(),
                    "value".to_string(),
                    "hash".to_string(),
                    "uncles".to_string()
                ],
                vec![
                    ReadKind::Float as u8,
                    ReadKind::BigInt as u8,
                    ReadKind::Text as u8,
                    ReadKind::List as u8
                ],
                7.0,
                true,
                "-5",
                true,
                "0xab",
                ("b", vec![2, 2], true),
                vec![None, Some(1)],
            )
        );
    }
}
