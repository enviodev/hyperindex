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
/// same bytes. `stale` has to be the buffer that describes the allocation about
/// to move — it is checked rather than trusted, because detaching some other
/// buffer would leave a live view over memory `grow` is about to free.
pub fn grow<'env>(
    env: &'env Env,
    arena: &mut Arena,
    column: u32,
    needed: u32,
    stale: ArrayBuffer,
) -> napi::Result<ArrayBuffer<'env>> {
    let payload = arena.payload_ptr(column as usize).map_err(to_napi)?;
    if !std::ptr::eq(stale.as_ptr(), payload) {
        return Err(napi::Error::from_reason(format!(
            "The buffer handed to grow is not column {column}'s payload."
        )));
    }
    stale.detach()?;
    let (data, len) = arena
        .grow(column as usize, needed as usize)
        .map_err(to_napi)?;
    lend(env, data, len)
}

/// Ends the filling phase: detaches every buffer JavaScript hands back, then
/// checks that this covered all of the arena's. A buffer the caller forgot
/// would be a live view over memory Rust is about to read and then free, so it
/// fails the batch instead — the arena stays lent out, and the handle is
/// unusable, rather than being read or freed under a writer.
pub fn detach_all(arena: &Arena, buffers: Vec<ArrayBuffer>) -> napi::Result<()> {
    let mut detached = Vec::with_capacity(buffers.len());
    for buffer in buffers {
        // A payload superseded by `grow` is already detached, and has no
        // pointer left to match against the arena's.
        if buffer.is_detached()? {
            continue;
        }
        detached.push(buffer.as_ptr());
        buffer.detach()?;
    }
    if let Some(missed) = arena
        .buffer_ptrs()
        .into_iter()
        .position(|buffer| !detached.contains(&buffer))
    {
        return Err(napi::Error::from_reason(format!(
            "Buffer {missed} of the staged batch was not handed back to be detached."
        )));
    }
    Ok(())
}

fn to_napi(err: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{err:#}"))
}
