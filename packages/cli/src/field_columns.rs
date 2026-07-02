//! Columnar materialisation shared by the per-chain field stores
//! (`TransactionStore`, `BlockStore`). Selected fields are decoded in bulk, off
//! the JS thread, into a struct-of-arrays form; the main thread then zips the
//! columns into plain JS objects, setting only the fields a row selected. The
//! cell type is concrete per column, so decode runs off-thread and only the
//! object zip touches the JS thread.

use anyhow::{Context, Result};
use napi::bindgen_prelude::{BigInt, ToNapiValue};
use napi::sys;
use napi_derive::napi;

use crate::evm_hypersync_source::types::{
    AccessList as AccessListItem, Authorization as AuthorizationItem,
};

/// The materialised SVM token balance, matching the public `svmTokenBalance`
/// shape (napi camel-cases the field names).
#[napi(object)]
#[derive(Clone)]
pub struct SvmTokenBalanceOut {
    pub account: Option<String>,
    pub mint: Option<String>,
    pub owner: Option<String>,
    pub pre_amount: Option<String>,
    pub post_amount: Option<String>,
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
    TokenBalances(Vec<Option<Vec<SvmTokenBalanceOut>>>),
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
            Column::TokenBalances(v) => set_col(env, objs, key, v),
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

/// Build one column by extracting a field from each record, but only for rows
/// whose per-row `mask` has `bit` set; every other row (or a key missing from
/// the store) yields a `None` cell. This is what lets a field be materialised on
/// exactly the rows that selected it, rather than on every row in the batch —
/// and it skips `extract` (e.g. hex-encoding a large field) on unselected rows.
pub fn fill_masked<R, T>(
    records: &[Option<std::sync::Arc<R>>],
    masks: &[u64],
    bit: u64,
    extract: impl Fn(&R) -> Result<Option<T>>,
) -> Result<Vec<Option<T>>> {
    records
        .iter()
        .zip(masks)
        .map(|(rec, &m)| {
            if m & bit == 0 {
                return Ok(None);
            }
            match rec {
                Some(r) => extract(r.as_ref()),
                None => Ok(None),
            }
        })
        .collect()
}

/// Iterate an ecosystem's field variants and decode each whose bit is set in the
/// union of `masks` (a column is built when any row selects it; `decode`, via
/// `fill_masked`, still applies each row's own mask within it). Shared by every
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
