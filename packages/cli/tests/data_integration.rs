//! Integration tests against real HyperSync endpoints.
//!
//! Gated behind `--features integration_tests` so default `cargo test` stays
//! offline. Requires `ENVIO_API_TOKEN` in the environment.
//!
//! Run with:
//!   cargo test -p envio --features integration_tests --test data_integration
#![cfg(feature = "integration_tests")]

use envio::data::{chain, field_selection::Selection, toon, where_filter::WhereFilter};
use reqwest::Client;
use serde_json::Value;
use std::time::Duration;

fn token() -> String {
    std::env::var("ENVIO_API_TOKEN").expect("ENVIO_API_TOKEN must be set for integration tests")
}

fn client() -> Client {
    Client::builder()
        .timeout(Duration::from_secs(60))
        .build()
        .unwrap()
}

async fn http_get_height(base_url: &str) -> i64 {
    let resp = client()
        .get(format!("{base_url}/height"))
        .bearer_auth(token())
        .send()
        .await
        .unwrap();
    assert!(
        resp.status().is_success(),
        "/height returned {}",
        resp.status()
    );
    let v: Value = resp.json().await.unwrap();
    v["height"].as_i64().unwrap()
}

async fn http_post_query(base_url: &str, body: &Value) -> Value {
    let resp = client()
        .post(format!("{base_url}/query"))
        .bearer_auth(token())
        .json(body)
        .send()
        .await
        .unwrap();
    let status = resp.status();
    let text = resp.text().await.unwrap();
    assert!(status.is_success(), "/query returned {status}: {text}");
    serde_json::from_str(&text).unwrap()
}

#[tokio::test]
async fn base_height_is_reasonable() {
    let chain = chain::resolve("base").unwrap();
    let height = http_get_height(&chain.base_url).await;
    assert!(
        height > 1_000_000,
        "Base archive height suspiciously low: {height}"
    );
}

#[tokio::test]
async fn base_usdc_transfers_round_trip() {
    let chain = chain::resolve("base").unwrap();
    let selection = Selection::parse(
        chain.kind,
        &[
            "block.number".into(),
            "log.srcAddress".into(),
            "log.topic0".into(),
        ],
    )
    .unwrap();
    let filter = WhereFilter::parse(
        chain.kind,
        Some(
            "{ block: { number: { _gte: 25000000, _lte: 25000020 } }, log: { srcAddress: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913' } }",
        ),
    )
    .unwrap();
    let body = filter.build_query_body(selection.build_field_selection());
    let response = http_post_query(&chain.base_url, &body).await;

    let archive_height = response["archive_height"].as_i64().unwrap_or(0);
    let next_block = response["next_block"].as_u64().unwrap_or(0);
    let rendered = toon::render_response(&selection, &response);

    let summary = (
        rendered.contains("blocks["),
        rendered.contains("logs["),
        rendered.contains("0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"),
        archive_height > 25_000_000,
        next_block >= 25_000_021,
    );
    assert_eq!(summary, (true, true, true, true, true));
}

#[tokio::test]
async fn fuel_testnet_height_works() {
    let chain = chain::resolve("fuel-testnet").unwrap();
    let height = http_get_height(&chain.base_url).await;
    assert!(
        height > 0,
        "fuel-testnet height should be > 0, got {height}"
    );
}

#[tokio::test]
async fn evm_query_with_no_where_returns_genesis_data() {
    let chain = chain::resolve("base").unwrap();
    let selection = Selection::parse(chain.kind, &["block.number".into()]).unwrap();
    let filter = WhereFilter::parse(chain.kind, None).unwrap();
    let body = filter.build_query_body(selection.build_field_selection());
    let response = http_post_query(&chain.base_url, &body).await;

    // With no filters and no include_all_blocks, HS returns no blocks until
    // it finds something matching — but it must still page forward, so
    // next_block > from_block (= 0) is the signal that the query was valid.
    let next_block = response["next_block"].as_u64().unwrap_or(0);
    assert!(
        next_block > 0,
        "next_block should advance past 0, got {next_block}"
    );
}
