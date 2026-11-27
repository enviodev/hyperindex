//! The test binary's global allocator: the system allocator, counting what the
//! threads that opted in allocate and free.
//!
//! Counting is per thread because tests run in parallel in one process: a
//! measurement marks only the threads doing the work it measures, so another
//! test's allocations never land in its totals.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};

pub(crate) struct CountingAllocator;

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

static ALLOCATIONS: AtomicU64 = AtomicU64::new(0);
static ALLOCATED_BYTES: AtomicU64 = AtomicU64::new(0);
static LIVE_BYTES: AtomicI64 = AtomicI64::new(0);
static PEAK_LIVE_BYTES: AtomicI64 = AtomicI64::new(0);

thread_local! {
    static COUNTED: Cell<bool> = const { Cell::new(false) };
}

fn is_counted() -> bool {
    // Read during thread teardown too, after the slot is gone.
    COUNTED.try_with(Cell::get).unwrap_or(false)
}

fn record_allocation(size: usize) {
    ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
    ALLOCATED_BYTES.fetch_add(size as u64, Ordering::Relaxed);
    let live = LIVE_BYTES.fetch_add(size as i64, Ordering::Relaxed) + size as i64;
    PEAK_LIVE_BYTES.fetch_max(live, Ordering::Relaxed);
}

fn record_free(size: usize) {
    LIVE_BYTES.fetch_sub(size as i64, Ordering::Relaxed);
}

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let pointer = unsafe { System.alloc(layout) };
        if !pointer.is_null() && is_counted() {
            record_allocation(layout.size());
        }
        pointer
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let pointer = unsafe { System.alloc_zeroed(layout) };
        if !pointer.is_null() && is_counted() {
            record_allocation(layout.size());
        }
        pointer
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        unsafe { System.dealloc(pointer, layout) };
        if is_counted() {
            record_free(layout.size());
        }
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let moved = unsafe { System.realloc(pointer, layout, new_size) };
        if !moved.is_null() && is_counted() {
            record_free(layout.size());
            record_allocation(new_size);
        }
        moved
    }
}

/// Count what the calling thread allocates and frees from now on.
pub(crate) fn count_this_thread() {
    COUNTED.with(|counted| counted.set(true));
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct AllocationTotals {
    pub(crate) allocations: u64,
    pub(crate) allocated_bytes: u64,
    /// The most bytes the counted threads held at once, above what they held
    /// when the totals were reset.
    pub(crate) peak_live_bytes: u64,
}

static MEASUREMENT: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Held for the whole of a measurement: the totals are shared by every counted
/// thread, so two measurements at once would each count the other's work.
pub(crate) fn measure_exclusively() -> std::sync::MutexGuard<'static, ()> {
    MEASUREMENT
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// Start a fresh measurement.
pub(crate) fn reset() {
    ALLOCATIONS.store(0, Ordering::Relaxed);
    ALLOCATED_BYTES.store(0, Ordering::Relaxed);
    LIVE_BYTES.store(0, Ordering::Relaxed);
    PEAK_LIVE_BYTES.store(0, Ordering::Relaxed);
}

/// What one run of `work` allocates, on a runtime of its own whose threads
/// are all counted, after a first run warms up connections and caches.
pub(crate) fn allocations_of<Work, Run>(work: Work) -> AllocationTotals
where
    Work: Fn() -> Run,
    Run: std::future::Future + Send + 'static,
    Run::Output: Send + 'static,
{
    let _exclusive = measure_exclusively();
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .on_thread_start(count_this_thread)
        .build()
        .unwrap();
    runtime.block_on(runtime.spawn(work())).unwrap();
    reset();
    runtime.block_on(runtime.spawn(work())).unwrap();
    totals()
}

pub(crate) fn totals() -> AllocationTotals {
    AllocationTotals {
        allocations: ALLOCATIONS.load(Ordering::Relaxed),
        allocated_bytes: ALLOCATED_BYTES.load(Ordering::Relaxed),
        peak_live_bytes: PEAK_LIVE_BYTES.load(Ordering::Relaxed).max(0) as u64,
    }
}
