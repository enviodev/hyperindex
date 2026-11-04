//! An experiment: the same page of event items crossing to JS two ways.
//!
//! - `napi`: `ItemsResponse` as `get_items` returns it today, built field by
//!   field with `#[napi(object)]`, each item's params replayed from a `JsTape`.
//! - `rkyv`: one rkyv archive in a `Buffer`, read on the JS side by Sury's
//!   `S.rkyv` against a schema of the same shape.
//! - `arena`: the storage arena's layout (`columnar`), one buffer per column -
//!   numbers in 8-byte slots, text as bytes end to end beside where each row's
//!   stop - read on the JS side the way `Reading.res` reads a result.
//!
//! `prepare_*` does the work that runs on a worker thread in production
//! (decoding into the tape, or serializing the archive) and parks the result;
//! `take_*` is the main-thread part, which is what the benchmark compares.

use std::sync::Mutex;

use napi::bindgen_prelude::Buffer;
use napi_derive::napi;

use crate::evm_hypersync_source::{EventItem, ItemsResponse};
use crate::js_value::JsTape;

#[derive(rkyv::Archive, rkyv::Serialize)]
pub struct Page {
    archive_height: Option<i64>,
    next_block: i64,
    event_items: Vec<PageEventItem>,
    block_items: Vec<PageBlockItem>,
    response_blocks: i64,
}

#[derive(rkyv::Archive, rkyv::Serialize)]
pub struct PageEventItem {
    log_index: i64,
    src_address: String,
    block_number: i64,
    transaction_index: i64,
    on_event_registration_index: i64,
    params: Transfer,
}

#[derive(rkyv::Archive, rkyv::Serialize)]
pub struct PageBlockItem {
    block_number: i64,
    on_block_registration_index: i64,
    skipped: bool,
}

/// ERC20 `Transfer(address indexed from, address indexed to, uint256 value)`.
#[derive(rkyv::Archive, rkyv::Serialize)]
pub struct Transfer {
    from: String,
    to: String,
    value: ruint::aliases::U256,
}

fn address(seed: u64) -> String {
    format!("0x{:040x}", seed.wrapping_mul(0x9e37_79b9_7f4a_7c15))
}

fn value(index: u64) -> u128 {
    u128::from(index) * 1_000_000_000_000_000_000
}

const BLOCK: i64 = 18_000_000;

fn napi_page(count: u32) -> ItemsResponse {
    let event_items = (0..u64::from(count))
        .map(|i| {
            let mut params = JsTape::new();
            params.obj(3);
            params.key("from");
            params.str(&address(i * 7));
            params.key("to");
            params.str(&address(i * 13));
            params.key("value");
            let value = value(i);
            params.bigint(false, &[value as u64, (value >> 64) as u64]);
            EventItem {
                log_index: i as i64,
                src_address: address(i % 16),
                block_number: BLOCK + (i / 10) as i64,
                transaction_index: (i % 200) as i64,
                on_event_registration_index: 0,
                params,
            }
        })
        .collect();
    ItemsResponse {
        archive_height: Some(BLOCK + 100_000),
        next_block: BLOCK + i64::from(count) / 10 + 1,
        event_items,
        block_items: Vec::new(),
        response_blocks: i64::from(count) / 10,
    }
}

fn rkyv_page(count: u32) -> Vec<u8> {
    let page = Page {
        archive_height: Some(BLOCK + 100_000),
        next_block: BLOCK + i64::from(count) / 10 + 1,
        event_items: (0..u64::from(count))
            .map(|i| PageEventItem {
                log_index: i as i64,
                src_address: address(i % 16),
                block_number: BLOCK + (i / 10) as i64,
                transaction_index: (i % 200) as i64,
                on_event_registration_index: 0,
                params: Transfer {
                    from: address(i * 7),
                    to: address(i * 13),
                    value: ruint::aliases::U256::from(value(i)),
                },
            })
            .collect(),
        block_items: Vec::new(),
        response_blocks: i64::from(count) / 10,
    };
    rkyv::to_bytes::<rkyv::rancor::Error>(&page)
        .expect("the page serializes")
        .to_vec()
}

/// The columns in order: `logIndex`, `srcAddress` (data, ends), `blockNumber`,
/// `transactionIndex`, `onEventRegistrationIndex`, `from` (data, ends), `to`
/// (data, ends), `value` (data, ends) as decimal digits: a slot holds 64 bits.
fn arena_page(count: u32) -> Vec<Vec<u8>> {
    let rows = u64::from(count);
    let numbers = |value: &dyn Fn(u64) -> f64| -> Vec<u8> {
        (0..rows).flat_map(|i| value(i).to_le_bytes()).collect()
    };
    let text = |value: &dyn Fn(u64) -> String| -> [Vec<u8>; 2] {
        let mut data = Vec::with_capacity(count as usize * 42);
        let mut ends = Vec::with_capacity(count as usize * 4);
        for i in 0..rows {
            data.extend_from_slice(value(i).as_bytes());
            ends.extend_from_slice(&(data.len() as u32).to_le_bytes());
        }
        [data, ends]
    };
    let [src_data, src_ends] = text(&|i| address(i % 16));
    let [from_data, from_ends] = text(&|i| address(i * 7));
    let [to_data, to_ends] = text(&|i| address(i * 13));
    let [value_data, value_ends] = text(&|i| value(i).to_string());
    vec![
        numbers(&|i| i as f64),
        src_data,
        src_ends,
        numbers(&|i| (BLOCK + (i / 10) as i64) as f64),
        numbers(&|i| (i % 200) as f64),
        numbers(&|_| 0.0),
        from_data,
        from_ends,
        to_data,
        to_ends,
        value_data,
        value_ends,
    ]
}

/// The same page as one `Vec` per field, laid out like a tuple of them, for a
/// reader that builds rows from columns (`S.compactColumns`).
#[derive(rkyv::Archive, rkyv::Serialize)]
pub struct ColumnsPage {
    log_index: Vec<i64>,
    src_address: Vec<String>,
    block_number: Vec<i64>,
    transaction_index: Vec<i64>,
    on_event_registration_index: Vec<i64>,
    from: Vec<String>,
    to: Vec<String>,
    value: Vec<ruint::aliases::U256>,
}

fn columns_page(count: u32) -> Vec<u8> {
    let rows = 0..u64::from(count);
    let page = ColumnsPage {
        log_index: rows.clone().map(|i| i as i64).collect(),
        src_address: rows.clone().map(|i| address(i % 16)).collect(),
        block_number: rows.clone().map(|i| BLOCK + (i / 10) as i64).collect(),
        transaction_index: rows.clone().map(|i| (i % 200) as i64).collect(),
        on_event_registration_index: rows.clone().map(|_| 0).collect(),
        from: rows.clone().map(|i| address(i * 7)).collect(),
        to: rows.clone().map(|i| address(i * 13)).collect(),
        value: rows.map(|i| ruint::aliases::U256::from(value(i))).collect(),
    };
    rkyv::to_bytes::<rkyv::rancor::Error>(&page)
        .expect("the page serializes")
        .to_vec()
}

static COLUMNS_PAGE: Mutex<Option<Vec<u8>>> = Mutex::new(None);

#[napi]
pub fn rkyv_interop_prepare_columns(count: u32) {
    *COLUMNS_PAGE.lock().unwrap() = Some(columns_page(count));
}

#[napi]
pub fn rkyv_interop_take_columns() -> Buffer {
    Buffer::from(COLUMNS_PAGE.lock().unwrap().take().expect("prepared"))
}

static ARENA_PAGE: Mutex<Option<Vec<Vec<u8>>>> = Mutex::new(None);

#[napi]
pub fn rkyv_interop_prepare_arena(count: u32) {
    *ARENA_PAGE.lock().unwrap() = Some(arena_page(count));
}

#[napi]
pub fn rkyv_interop_take_arena() -> Vec<Buffer> {
    ARENA_PAGE
        .lock()
        .unwrap()
        .take()
        .expect("prepared")
        .into_iter()
        .map(Buffer::from)
        .collect()
}

static NAPI_PAGE: Mutex<Option<ItemsResponse>> = Mutex::new(None);
static RKYV_PAGE: Mutex<Option<Vec<u8>>> = Mutex::new(None);

#[napi]
pub fn rkyv_interop_prepare_napi(count: u32) {
    *NAPI_PAGE.lock().unwrap() = Some(napi_page(count));
}

#[napi]
pub fn rkyv_interop_take_napi() -> ItemsResponse {
    NAPI_PAGE.lock().unwrap().take().expect("prepared")
}

#[napi]
pub fn rkyv_interop_prepare_rkyv(count: u32) {
    *RKYV_PAGE.lock().unwrap() = Some(rkyv_page(count));
}

#[napi]
pub fn rkyv_interop_take_rkyv() -> Buffer {
    Buffer::from(RKYV_PAGE.lock().unwrap().take().expect("prepared"))
}

// Entities both ways, for the storage path: `Change.t` values JavaScript stages
// for a write, and rows read back. `BigInt` travels as its digits, as the arena
// stages it, since a Postgres numeric has no fixed width.

#[derive(rkyv::Archive, rkyv::Serialize)]
pub struct Account {
    id: String,
    owner: String,
    balance: String,
    transfers: i32,
    active: bool,
    ratio: Option<f64>,
}

/// `Change.t`: `Set` or `Delete`, fields in the order the variant declares them.
#[derive(rkyv::Archive, rkyv::Serialize)]
#[expect(
    dead_code,
    reason = "JavaScript writes the archive; Rust only reads it"
)]
pub enum AccountChange {
    Set {
        entity_id: String,
        entity: Account,
        checkpoint_id: i64,
    },
    Delete {
        entity_id: String,
        checkpoint_id: i64,
    },
}

/// What a write hands Rust: the archive validated where it lies, ready for an
/// encoder to read without copying. Returns how many rows set an entity.
#[napi]
pub fn rkyv_interop_receive_changes(bytes: Buffer) -> napi::Result<u32> {
    let validate = |bytes: &[u8]| {
        rkyv::access::<rkyv::vec::ArchivedVec<ArchivedAccountChange>, rkyv::rancor::Error>(bytes)
            .map(|changes| {
                changes
                    .iter()
                    .filter(|change| matches!(change, ArchivedAccountChange::Set { .. }))
                    .count() as u32
            })
    };
    // rkyv reads in place only from memory aligned for the archive.
    let result = if (bytes.as_ptr() as usize).is_multiple_of(16) {
        validate(&bytes)
    } else {
        let mut aligned = rkyv::util::AlignedVec::<16>::with_capacity(bytes.len());
        aligned.extend_from_slice(&bytes);
        validate(&aligned)
    };
    result.map_err(|err| napi::Error::from_reason(err.to_string()))
}

fn accounts(count: u32) -> Vec<u8> {
    let rows: Vec<Account> = (0..u64::from(count))
        .map(|i| Account {
            id: format!("account-{i}"),
            // As the Postgres query in RkyvInteropBench.res renders it.
            owner: format!("0x{:040x}", i * 7),
            balance: value(i).to_string(),
            transfers: (i % 1000) as i32,
            active: i % 3 != 0,
            ratio: (i % 2 == 0).then_some(i as f64 / 7.0),
        })
        .collect();
    rkyv::to_bytes::<rkyv::rancor::Error>(&rows)
        .expect("the rows serialize")
        .to_vec()
}

static ACCOUNTS: Mutex<Option<Vec<u8>>> = Mutex::new(None);

#[napi]
pub fn rkyv_interop_prepare_accounts(count: u32) {
    *ACCOUNTS.lock().unwrap() = Some(accounts(count));
}

#[napi]
pub fn rkyv_interop_take_accounts() -> Buffer {
    Buffer::from(ACCOUNTS.lock().unwrap().take().expect("prepared"))
}
