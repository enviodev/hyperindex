//! Lending an [`Arena`]'s memory to JavaScript and taking it back.
//!
//! The ownership and phase rules this code has to keep are written down at the
//! top of [`super`]. Read them before changing anything here.

use napi::bindgen_prelude::{ArrayBuffer, FromNapiValue};
use napi::{Env, JsValue};

use super::Arena;

/// Wraps arena memory in an `ArrayBuffer` JavaScript can write through.
///
/// The finalize callback deliberately does nothing: the arena owns these bytes
/// and frees them when it is dropped, so a collected `ArrayBuffer` must not.
fn lend<'env>(env: &'env Env, data: *mut u8, len: usize) -> napi::Result<ArrayBuffer<'env>> {
    let buffer = unsafe { ArrayBuffer::from_external(env, data, len, (), |_, _| ())? };
    // A runtime that refuses external backing stores — Electron, or Node run
    // with `--no-external-buffers` — hands back a copy instead, and napi says so
    // only by pointing the `ArrayBuffer` somewhere else. JavaScript would then
    // fill bytes Rust never reads, which no test downstream could tell from an
    // empty batch, so refuse the stage while it is still an error.
    let actual = unsafe { ArrayBuffer::from_napi_value(env.raw(), buffer.raw())? };
    if !std::ptr::eq(actual.as_ptr(), data) {
        return Err(napi::Error::from_reason(
            "This runtime copies external ArrayBuffers instead of sharing them, so a staged \
             batch cannot be written in place.",
        ));
    }
    Ok(buffer)
}

/// Every buffer of `arena`, column by column, in the order the column's kind
/// lays them out. The arena is in its filling phase from here on.
pub fn expose<'env>(env: &'env Env, arena: &mut Arena) -> napi::Result<Vec<ArrayBuffer<'env>>> {
    let mut buffers = Vec::new();
    for column in arena.columns.iter_mut() {
        for (data, len) in column.buffers() {
            buffers.push(lend(env, data, len)?);
        }
    }
    Ok(buffers)
}

/// Replaces one variable-width column's payload with a larger one holding the
/// same bytes. `stale` describes the allocation that is about to move, and is
/// detached before it does.
pub fn grow<'env>(
    env: &'env Env,
    arena: &mut Arena,
    column: u32,
    needed: u32,
    stale: ArrayBuffer,
) -> napi::Result<ArrayBuffer<'env>> {
    stale.detach()?;
    let (data, len) = arena
        .grow(column as usize, needed as usize)
        .map_err(|err| napi::Error::from_reason(format!("{err:#}")))?;
    lend(env, data, len)
}

/// Ends the filling phase. Once this returns, no JavaScript view describes
/// arena memory and Rust may read it.
pub fn detach_all(buffers: Vec<ArrayBuffer>) -> napi::Result<()> {
    for buffer in buffers {
        // A buffer superseded by `grow` is already detached, and detaching it
        // again is not an error worth failing a batch over.
        if !buffer.is_detached()? {
            buffer.detach()?;
        }
    }
    Ok(())
}
