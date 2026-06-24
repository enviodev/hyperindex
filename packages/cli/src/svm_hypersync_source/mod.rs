use std::collections::HashMap;
use std::sync::Arc;

use anyhow::Context;
use napi_derive::napi;

mod borsh_decoder;
mod config;
mod query;
mod types;

/// Local hex helpers. Lives here so `decoder.rs` can pull them via
/// `super::mod_helpers::hex_to_bytes` without crossing the crate boundary
/// and without exposing a public hex parser at the napi surface.
pub(crate) mod mod_helpers {
    use anyhow::{anyhow, Result};
    pub fn hex_to_bytes(input: &str) -> Result<Vec<u8>> {
        let s = input.strip_prefix("0x").unwrap_or(input);
        if !s.len().is_multiple_of(2) {
            return Err(anyhow!("hex string has odd length: '{input}'"));
        }
        (0..s.len())
            .step_by(2)
            .map(|i| {
                u8::from_str_radix(&s[i..i + 2], 16)
                    .map_err(|_| anyhow!("invalid hex byte at offset {i} in '{input}'"))
            })
            .collect()
    }
}

use hypersync_client_solana::decode::ProgramSchema as UpstreamSchema;
use hypersync_client_solana::simple_types as simple;

use crate::transaction_store::TransactionStore;
use config::SvmClientConfig;
use query::SvmQuery;
use types::QueryResponse;

/// Move the raw transactions and token balances of a response into a
/// `TransactionStore`, keyed by `(slot, transactionIndex)`. Kept raw in Rust so
/// only the config-selected fields are materialised at batch prep; many
/// instructions in one transaction collapse to a single stored record.
fn build_svm_store(
    transactions: Vec<simple::Transaction>,
    token_balances: Vec<simple::TokenBalance>,
) -> TransactionStore {
    let store = TransactionStore::new_svm();

    let mut tx_by_key: HashMap<(u64, u32), simple::Transaction> = HashMap::new();
    for tx in transactions {
        tx_by_key.insert((tx.slot, tx.transaction_index), tx);
    }
    let mut tb_by_key: HashMap<(u64, u32), Vec<simple::TokenBalance>> = HashMap::new();
    for tb in token_balances {
        if let Some(ti) = tb.transaction_index {
            tb_by_key.entry((tb.slot, ti)).or_default().push(tb);
        }
    }

    // Union of keys: a transaction may have token balances but no selected
    // transaction fields, or vice versa.
    let mut keys: Vec<(u64, u32)> = tx_by_key.keys().copied().collect();
    for key in tb_by_key.keys() {
        if !tx_by_key.contains_key(key) {
            keys.push(*key);
        }
    }
    for key in keys {
        // A token-balance-only key has no transaction row; the defaulted struct
        // is fine because `transactionIndex` materialises from the store key, not
        // this record (no other field is read for such keys).
        let tx = tx_by_key.remove(&key).unwrap_or_default();
        let token_balances = tb_by_key.remove(&key).unwrap_or_default();
        store.insert_svm_raw(
            key.0,
            key.1,
            Arc::new(TransactionStore::make_svm_stored(tx, token_balances)),
        );
    }

    store
}

#[napi]
pub struct SvmHypersyncClient {
    inner: Arc<hypersync_client_solana::Client>,
    /// Per-program Borsh schemas, keyed by base58 program id, built once from
    /// the config at client creation. `get` decodes matching instructions
    /// against these.
    schemas: HashMap<String, UpstreamSchema>,
}

#[napi]
impl SvmHypersyncClient {
    #[napi(constructor)]
    pub fn new(cfg: SvmClientConfig, user_agent: String) -> napi::Result<SvmHypersyncClient> {
        Self::from_config(cfg, user_agent)
    }

    /// Factory taking a custom user agent, mirroring EVM's `new_with_agent`.
    /// Exposed so callers that grab the class dynamically (e.g. ReScript
    /// reaching through the addon dict) can use `@send` rather than `%raw`.
    #[napi(factory)]
    pub fn from_config(
        cfg: SvmClientConfig,
        user_agent: String,
    ) -> napi::Result<SvmHypersyncClient> {
        let mut schemas = HashMap::new();
        for descriptor_json in cfg.program_schemas.clone().unwrap_or_default() {
            let schema = borsh_decoder::parse_program_schema(&descriptor_json).map_err(map_err)?;
            schemas.insert(schema.program_id.clone(), schema);
        }
        let inner = hypersync_client_solana::Client::new_with_agent(cfg.into(), user_agent)
            .context("build solana client")
            .map_err(map_err)?;
        Ok(SvmHypersyncClient {
            inner: Arc::new(inner),
            schemas,
        })
    }

    #[napi]
    pub async fn get_height(&self) -> napi::Result<i64> {
        let h = self.inner.get_height().await.map_err(map_err)?;
        i64::try_from(h)
            .with_context(|| format!("height {} does not fit in i64", h))
            .map_err(map_err)
    }

    /// Single-window query (no client-side pagination). The hyperindex source
    /// layer paginates by chunking the slot range itself, so the napi binding
    /// must NOT call `collect` (which spins up parallel batched requests under
    /// `StreamConfig::default()` and can DoS the server on multi-day windows).
    #[napi]
    pub async fn get(&self, query: SvmQuery) -> napi::Result<(QueryResponse, TransactionStore)> {
        let q: hypersync_solana_net_types::query::SolanaQuery = query
            .try_into()
            .context("parse solana query")
            .map_err(map_err)?;
        let mut resp = self
            .inner
            .get(&q)
            .await
            .context("solana get")
            .map_err(map_err)?;

        // Decode each matching instruction inline against the client's
        // configured schemas — Borsh decoding happens here, in Rust, rather
        // than per-instruction over the napi boundary, mirroring how the EVM
        // client returns pre-decoded params. Skipped when no schemas exist.
        let decoded: Vec<Option<borsh_decoder::DecodedInstructionJson>> = if self.schemas.is_empty()
        {
            Vec::new()
        } else {
            resp.instructions
                .iter()
                .map(|ix| {
                    self.schemas.get(&ix.program_id).and_then(|schema| {
                        borsh_decoder::decode_with_schema(
                            schema,
                            ix.accounts.clone(),
                            ix.data.clone(),
                        )
                    })
                })
                .collect()
        };

        // Retain raw transactions + token balances in Rust; ReScript builds
        // items from instructions and the store materialises the parent
        // transaction (selected fields only) at batch prep.
        let store = build_svm_store(
            std::mem::take(&mut resp.transactions),
            std::mem::take(&mut resp.token_balances),
        );

        let mut out = QueryResponse::try_from(resp)
            .context("convert solana response")
            .map_err(map_err)?;
        for (instr, d) in out.data.instructions.iter_mut().zip(decoded) {
            instr.decoded = d;
        }
        Ok((out, store))
    }
}

pub(crate) fn map_err(e: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{:?}", e))
}

#[cfg(test)]
mod tests {
    use super::*;
    use query::{InstructionSelection, SvmQuery};

    const TOKEN_METADATA_PROGRAM: &str = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s";

    /// Live test against `solana.hypersync.xyz`. Run with:
    ///     cargo test -p envio --lib svm_hypersync_source::tests -- --ignored --nocapture
    #[tokio::test]
    #[ignore]
    async fn live_query_token_metadata() {
        let client = SvmHypersyncClient::new(
            SvmClientConfig {
                url: "https://solana.hypersync.xyz".into(),
                ..Default::default()
            },
            "hyperindex-test".into(),
        )
        .expect("build client");

        let height = client.get_height().await.expect("get_height");
        eprintln!("current slot: {}", height);
        let from = height.saturating_sub(10_000).max(0);

        let q = SvmQuery {
            from_slot: from,
            to_slot: Some(height),
            instructions: Some(vec![InstructionSelection {
                program_id: Some(vec![TOKEN_METADATA_PROGRAM.into()]),
                ..Default::default()
            }]),
            max_num_instructions: Some(200),
            ..Default::default()
        };

        // Transactions are moved into the store, so `resp.data.transactions` is
        // empty here by design.
        let (resp, _store) = client.get(q).await.expect("collect");
        eprintln!(
            "got {} instructions / next_slot={}",
            resp.data.instructions.len(),
            resp.next_slot
        );
        assert!(
            !resp.data.instructions.is_empty(),
            "expected at least one Token Metadata instruction"
        );
        for ix in resp.data.instructions.iter().take(3) {
            assert_eq!(ix.program_id, TOKEN_METADATA_PROGRAM);
            assert!(ix.data.starts_with("0x"));
            assert!(ix.data.len() > 2, "data should not be empty hex");
        }
    }
}
