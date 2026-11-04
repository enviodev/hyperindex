//! An experiment: the same page of event items crossing to JS two ways.
//!
//! - `napi`: `ItemsResponse` as `get_items` returns it today, built field by
//!   field with `#[napi(object)]`, each item's params replayed from a `JsTape`.
//! - `rkyv`: one rkyv archive in a `Buffer`, read on the JS side by Sury's
//!   `S.rkyv` against a schema of the same shape.
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
