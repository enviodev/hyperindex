//! Lending an [`Arena`]'s memory to JavaScript and taking it back.
//!
//! The ownership and phase rules this code has to keep are written down at the
//! top of [`super`]. Read them before changing anything here.

use std::collections::HashMap;
use std::sync::Mutex;

use napi::bindgen_prelude::{ArrayBuffer, FromNapiValue, Object};
use napi::{Env, JsValue};

use super::{Arena, ColumnKind};

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
/// to move, which the arena checks — detaching some other buffer would leave a
/// live view over memory this is about to free.
///
/// The growth runs before the detach, so a column too wide to grow leaves
/// `stale` attached and still the column's payload — an abort can then detach
/// it, and the error the caller sees is the one that says why. Nothing runs
/// between the two: JavaScript is blocked in this call, so the moment where the
/// old buffer describes a freed allocation is not one it can write in.
pub fn grow<'env>(
    env: &'env Env,
    arena: &mut Arena,
    column: u32,
    needed: u32,
    stale: ArrayBuffer,
) -> napi::Result<ArrayBuffer<'env>> {
    let (data, len) = arena
        .grow(column as usize, needed as usize, stale.as_ptr())
        .map_err(to_napi)?;
    stale.detach()?;
    lend(env, data, len)
}

/// Ends the lending phase, in whichever direction it ran: detaches every buffer
/// JavaScript hands back, then
/// checks that this covered all of the arena's. A buffer the caller forgot
/// would be a live view over memory Rust is about to read and then free, so it
/// fails instead — and the caller has to keep the arena rather than free it.
///
/// Does nothing for an arena that is already detached, which is the abort after
/// a commit that detached everything and then failed to seal. Counting those
/// buffers as missing would report the cleanup instead of the failure.
pub fn detach_all(arena: &mut Arena, buffers: Vec<ArrayBuffer>) -> napi::Result<()> {
    if !arena.is_lent() {
        return Ok(());
    }
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
    arena.finish_lending();
    Ok(())
}

fn to_napi(err: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{err:#}"))
}

/// Hands a filled arena's buffers to JavaScript to read from. The mirror of
/// [`expose`]: the same memory, lent the other way round, and taken back by the
/// same [`detach_all`].
pub fn lend_for_reading<'env>(
    env: &'env Env,
    arena: &mut Arena,
) -> napi::Result<Vec<ArrayBuffer<'env>>> {
    arena.start_reading().map_err(to_napi)?;
    expose(env, arena)
}

/// A batch lent to JavaScript to fill, and what its sink needs to write it.
pub struct Staged<M> {
    pub meta: M,
    pub arena: Arena,
}

/// The batches a sink has lent out, by handle, from `begin` until the sink
/// takes them to write.
pub struct Stages<M> {
    batches: Mutex<HashMap<u32, Staged<M>>>,
}

impl<M> Default for Stages<M> {
    fn default() -> Self {
        Self {
            batches: Mutex::new(HashMap::new()),
        }
    }
}

impl<M> Stages<M> {
    /// Lays out a batch and lends JavaScript its buffers, as
    /// `{ handle, buffers }`. Nothing may await between here and `commit`.
    pub fn begin<'env>(
        &self,
        env: &'env Env,
        handle: u32,
        rows: u32,
        kinds: &[ColumnKind],
        meta: M,
    ) -> napi::Result<Object<'env>> {
        let mut arena = Arena::new(rows as usize, kinds).map_err(to_napi)?;
        let buffers = expose(env, &mut arena)?;
        // Storing the arena moves its `Vec` headers, not the allocations the
        // buffers above point into, so the lending survives the move.
        self.insert(handle, Staged { meta, arena });
        let mut result = Object::new(env)?;
        result.set("handle", handle)?;
        result.set("buffers", buffers)?;
        Ok(result)
    }

    pub fn insert(&self, handle: u32, staged: Staged<M>) {
        self.batches.lock().unwrap().insert(handle, staged);
    }

    pub fn grow<'env>(
        &self,
        env: &'env Env,
        handle: u32,
        column: u32,
        needed: u32,
        stale: ArrayBuffer,
    ) -> napi::Result<ArrayBuffer<'env>> {
        let mut batches = self.batches.lock().unwrap();
        let staged = batches.get_mut(&handle).ok_or_else(|| unknown(handle))?;
        grow(env, &mut staged.arena, column, needed, stale)
    }

    /// Ends the filling phase: every buffer is detached, so a view JavaScript
    /// kept throws rather than writing into memory Rust is about to read.
    pub fn commit(
        &self,
        handle: u32,
        buffers: Vec<ArrayBuffer>,
        names: impl FnOnce(&M) -> Vec<String>,
    ) -> napi::Result<()> {
        let mut batches = self.batches.lock().unwrap();
        detach_or_abandon(&mut batches, handle, buffers)?;
        let staged = batches.get_mut(&handle).ok_or_else(|| unknown(handle))?;
        let names = names(&staged.meta);
        staged.arena.seal(&names).map_err(to_napi)
    }

    /// Drops a batch that threw while it was being filled, detaching its
    /// buffers first. A batch that cannot hand them back is abandoned, which is
    /// safe, and the failure is returned for the caller to mention: the error
    /// that sent it here is the one worth throwing.
    pub fn abort(&self, handle: u32, buffers: Vec<ArrayBuffer>) -> Option<napi::Error> {
        let mut batches = self.batches.lock().unwrap();
        if !batches.contains_key(&handle) {
            return None;
        }
        let failed = detach_or_abandon(&mut batches, handle, buffers).err();
        batches.remove(&handle);
        failed
    }

    pub fn take(&self, handle: u32) -> Option<Staged<M>> {
        self.batches.lock().unwrap().remove(&handle)
    }

    /// How many batches are lent out or waiting to be written.
    #[cfg(test)]
    pub fn count(&self) -> usize {
        self.batches.lock().unwrap().len()
    }
}

fn unknown(handle: u32) -> napi::Error {
    napi::Error::from_reason(format!("Unknown staged batch {handle}"))
}

/// Detaches a staged batch's buffers. A batch that cannot hand them all back
/// still has a JavaScript view into its arena, and that allocation has to
/// outlive the view — so it leaves the registry without being freed. The handle
/// stops working, which is what makes the leak one batch rather than a write
/// into memory that has been handed to something else.
fn detach_or_abandon<M>(
    batches: &mut HashMap<u32, Staged<M>>,
    handle: u32,
    buffers: Vec<ArrayBuffer>,
) -> napi::Result<()> {
    let entry = batches.get_mut(&handle).ok_or_else(|| unknown(handle))?;
    let detached = detach_all(&mut entry.arena, buffers);
    if detached.is_err() {
        std::mem::forget(batches.remove(&handle));
    }
    detached
}
