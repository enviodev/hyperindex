use std::sync::Arc;

use anyhow::Context;
use napi_derive::napi;

mod config;
mod query;
mod types;

use config::SolanaClientConfig;
use hypersync_client_solana::config::StreamConfig;
use query::SolanaQuery;
use types::QueryResponse;

#[napi]
pub struct HypersyncSolanaClient {
    inner: Arc<hypersync_client_solana::Client>,
}

#[napi]
impl HypersyncSolanaClient {
    #[napi(constructor)]
    pub fn new(cfg: SolanaClientConfig) -> napi::Result<HypersyncSolanaClient> {
        Self::from_config(cfg)
    }

    /// Factory mirroring EVM's `new_with_agent`. Exposed so callers that grab
    /// the class dynamically (e.g. ReScript reaching through the addon dict)
    /// can use `@send` rather than `%raw` to invoke `new`.
    #[napi(factory)]
    pub fn from_config(cfg: SolanaClientConfig) -> napi::Result<HypersyncSolanaClient> {
        let inner = hypersync_client_solana::Client::new(cfg.into())
            .context("build solana client")
            .map_err(map_err)?;
        Ok(HypersyncSolanaClient {
            inner: Arc::new(inner),
        })
    }

    #[napi]
    pub async fn get_height(&self) -> napi::Result<i64> {
        let h = self.inner.get_height().await.map_err(map_err)?;
        i64::try_from(h)
            .with_context(|| format!("height {} does not fit in i64", h))
            .map_err(map_err)
    }

    #[napi]
    pub async fn get(&self, query: SolanaQuery) -> napi::Result<QueryResponse> {
        let q: hypersync_solana_net_types::query::SolanaQuery = query
            .try_into()
            .context("parse solana query")
            .map_err(map_err)?;
        let resp = self
            .inner
            .collect(q, StreamConfig::default())
            .await
            .context("solana collect")
            .map_err(map_err)?;
        QueryResponse::try_from(resp)
            .context("convert solana response")
            .map_err(map_err)
    }
}

pub(crate) fn map_err(e: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{:?}", e))
}

#[cfg(test)]
mod tests {
    use super::*;
    use query::{InstructionSelection, SolanaQuery};

    const TOKEN_METADATA_PROGRAM: &str = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s";

    /// Live test against `solana.hypersync.xyz`. Run with:
    ///     cargo test -p envio --lib hypersync_source_svm::tests -- --ignored --nocapture
    #[tokio::test]
    #[ignore]
    async fn live_query_token_metadata() {
        let client = HypersyncSolanaClient::new(SolanaClientConfig {
            url: "https://solana.hypersync.xyz".into(),
            ..Default::default()
        })
        .expect("build client");

        let height = client.get_height().await.expect("get_height");
        eprintln!("current slot: {}", height);
        let from = height.saturating_sub(10_000).max(0);

        let q = SolanaQuery {
            from_slot: from,
            to_slot: Some(height),
            instructions: Some(vec![InstructionSelection {
                program_id: Some(vec![TOKEN_METADATA_PROGRAM.into()]),
                include_transaction: Some(true),
                ..Default::default()
            }]),
            max_num_instructions: Some(200),
            ..Default::default()
        };

        let resp = client.get(q).await.expect("collect");
        eprintln!(
            "got {} instructions / {} txs / next_slot={}",
            resp.data.instructions.len(),
            resp.data.transactions.len(),
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
