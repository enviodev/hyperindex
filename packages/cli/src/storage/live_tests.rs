//! Postgres with ClickHouse following it, against real servers.
//!
//! Run with `cargo test --lib storage::live -- --ignored`.

use std::sync::Arc;

use pretty_assertions::assert_eq;

use super::types::{Addresses, ChainConfig, ChainMeta, Sequence};
use super::{Initialize, Storage};
use crate::clickhouse;
use crate::postgres;

struct Live {
    storage: Storage,
    name: String,
}

impl Live {
    fn new(name: &str) -> Self {
        let name = format!("envio_composite_{name}_{}", std::process::id());
        let postgres = postgres::storage::Storage::new(
            postgres::live_tests::client(),
            postgres::storage::Settings {
                pg_schema: name.clone(),
                pg_user: "postgres".to_string(),
                chain_id_mode: postgres::pg_type::ChainIdMode::Int32,
                numeric_array_as_text: false,
            },
            Arc::new(|_| ()),
        );
        let clickhouse = clickhouse::storage::Storage::new(
            clickhouse::live_tests::connection(&name),
            clickhouse::client::Tuning {
                retries: 0,
                ..clickhouse::client::Tuning::default()
            },
            Arc::new(|_: &str| ()),
            clickhouse::storage::Settings {
                chain_id_mode: crate::config_parsing::system_config::ChainIdMode::Int32,
                replicated: false,
                database_engine: None,
                primary: false,
            },
        )
        .unwrap();
        Self {
            storage: Storage {
                postgres: Some(Arc::new(postgres)),
                clickhouse: Some(Arc::new(clickhouse)),
            },
            name,
        }
    }

    async fn initialize(&self) {
        self.storage
            .initialize(Initialize {
                sequence: Sequence::SharedAcrossChains,
                tables: Vec::new(),
                partitions: Vec::new(),
                enums: Vec::new(),
                chains: vec![ChainConfig {
                    id: 1,
                    ecosystem: "evm".to_string(),
                    start_block: 0,
                    end_block: None,
                    max_reorg_depth: 200,
                }],
                envio_info: "{\"config\":1}".to_string(),
                contract_names: Vec::new(),
                addresses: Addresses::default(),
            })
            .await
            .unwrap();
        self.storage
            .resume(Sequence::SharedAcrossChains, Vec::new(), vec![1])
            .await
            .unwrap();
    }

    async fn drop_clickhouse(&self) {
        clickhouse::client::Client::new(
            clickhouse::live_tests::connection("default"),
            clickhouse::client::Tuning::default(),
            Arc::new(|_: &str| ()),
        )
        .unwrap()
        .statement(format!("DROP DATABASE IF EXISTS `{}` SYNC", self.name))
        .await
        .unwrap();
    }

    async fn drop_all(&self) {
        self.drop_clickhouse().await;
        postgres::live_tests::client()
            .batch(&format!("DROP SCHEMA IF EXISTS \"{}\" CASCADE", self.name))
            .await
            .unwrap();
    }
}

/// Nothing reads a follower's chain metadata, so a follower that cannot take
/// it is no reason to fail the write the store of record took.
#[tokio::test]
#[ignore = "needs a Postgres and a ClickHouse server"]
async fn chain_metadata_is_the_store_of_records_alone() {
    let live = Live::new("meta");
    live.initialize().await;
    live.drop_clickhouse().await;

    let outcome = live
        .storage
        .set_chain_meta(&[ChainMeta {
            chain_id: 1,
            first_event_block: Some(5),
            buffer_block: 10,
            ready_at: None,
            is_hyper_sync: true,
        }])
        .await;

    live.drop_all().await;
    assert_eq!(outcome.map_err(|error| format!("{error:#}")), Ok(()));
}
