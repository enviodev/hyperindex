//! Postgres with ClickHouse following it, against real servers.
//!
//! Run with `cargo test --lib storage::live -- --ignored`.

use std::sync::Arc;

use pretty_assertions::assert_eq;

use super::types::{Addresses, ChainConfig, Frontier, Progress, Sequence};
use super::{Batch, EffectCacheWrite, Holding, Initialize, Rows, Storage, Table};
use crate::clickhouse;
use crate::postgres;
use crate::postgres::param::Param;

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
            },
        )
        .unwrap();
        Self {
            storage: Storage {
                postgres: Arc::new(postgres),
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
                instance: super::new_instance(),
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

    /// Where Postgres and ClickHouse each hold chain 1's frontier.
    async fn frontiers(&self) -> (String, String) {
        let (rows, _) = postgres::live_tests::client()
            .query(
                &format!(
                    "SELECT \"checkpoint_id\"::text FROM \"{}\".\"envio_chains\" WHERE \"id\" = 1",
                    self.name
                ),
                &[],
            )
            .await
            .unwrap();
        let clickhouse = self
            .clickhouse_statement(format!(
                "SELECT checkpoint_id FROM `{}`.envio_chains FINAL WHERE chain_id = 1 FORMAT \
                 TabSeparated",
                self.name
            ))
            .await;
        (rows.first().unwrap().get::<_, String>(0), clickhouse)
    }

    async fn clickhouse_statement(&self, statement: String) -> String {
        clickhouse::client::Client::new(
            clickhouse::live_tests::connection("default"),
            clickhouse::client::Tuning::default(),
            Arc::new(|_: &str| ()),
        )
        .unwrap()
        .statement(statement)
        .await
        .unwrap()
        .trim()
        .to_string()
    }

    async fn drop_clickhouse(&self) {
        self.clickhouse_statement(format!("DROP DATABASE IF EXISTS `{}` SYNC", self.name))
            .await;
    }

    async fn drop_all(&self) {
        self.drop_clickhouse().await;
        postgres::live_tests::client()
            .batch(&format!("DROP SCHEMA IF EXISTS \"{}\" CASCADE", self.name))
            .await
            .unwrap();
    }
}

/// Two deployments of one config each pair a Postgres schema with the
/// ClickHouse database built alongside it. Crossing them resumes neither.
#[tokio::test]
#[ignore = "needs a Postgres and a ClickHouse server"]
async fn a_clickhouse_built_alongside_another_postgres_schema_has_diverged() {
    let (a, b) = (Live::new("pair_a"), Live::new("pair_b"));
    a.initialize().await;
    b.initialize().await;
    let crossed = Storage {
        postgres: a.storage.postgres.clone(),
        clickhouse: b.storage.clickhouse.clone(),
    };

    let holding = crossed.holding().await;

    a.drop_all().await;
    b.drop_all().await;
    assert_eq!(
        holding.map_err(|error| format!("{error:#}")),
        Ok(Holding::Diverged)
    );
}

/// ClickHouse only ever holds what Postgres committed, so one whose Postgres
/// schema is gone holds data nothing says how far it got.
#[tokio::test]
#[ignore = "needs a Postgres and a ClickHouse server"]
async fn a_clickhouse_without_its_postgres_is_stranded() {
    let live = Live::new("stranded");
    live.initialize().await;
    live.storage.postgres.reset().await.unwrap();

    let holding = live.storage.holding().await;

    live.drop_all().await;
    assert_eq!(
        holding.map_err(|error| format!("{error:#}")),
        Ok(Holding::Stranded)
    );
}

/// ClickHouse commits once Postgres has: an effect cache write failing after
/// the transaction committed fails the batch, not ClickHouse's half of it.
#[tokio::test]
#[ignore = "needs a Postgres and a ClickHouse server"]
async fn clickhouse_commits_what_postgres_committed_whatever_its_caches_do() {
    let live = Live::new("cache_after_commit");
    live.initialize().await;
    let cache = Arc::new(Table {
        name: "envio_effect_price".to_string(),
        postgres: Some(Arc::new(
            live.storage
                .postgres
                .register(postgres::storage::TableRegistration {
                    spec: postgres::ddl::TableSpec {
                        table_name: "envio_effect_price".to_string(),
                        columns: vec![
                            postgres::ddl::ColumnSpec {
                                name: "id".to_string(),
                                field_type: postgres::pg_type::FieldType::String,
                                is_array: false,
                                is_nullable: false,
                                is_primary_key: true,
                                default_value: None,
                            },
                            postgres::ddl::ColumnSpec {
                                name: "output".to_string(),
                                field_type: postgres::pg_type::FieldType::Json,
                                is_array: false,
                                is_nullable: false,
                                is_primary_key: false,
                                default_value: None,
                            },
                        ],
                        partition_by_column: None,
                    },
                    write_columns: vec!["id".to_string(), "output".to_string()],
                    append_only: false,
                    history: None,
                })
                .unwrap(),
        )),
        clickhouse: None,
    });

    let written = live
        .storage
        .write_batch(Batch {
            progress: vec![Progress {
                chain_id: 1,
                progress_block: 10,
                progress_block_time: None,
                events_processed: 1.0,
                source_block: 10,
            }],
            frontier: Frontier {
                chain_ids: vec![1],
                checkpoint_ids: vec![1],
            },
            // Never created, so the insert into it fails.
            effect_caches: vec![EffectCacheWrite {
                table: cache,
                create: false,
                rows: Rows::Cells {
                    cells: vec![Param::Text("k".to_string()), Param::Text("{}".to_string())],
                    rows: 1,
                },
            }],
            ..Batch::default()
        })
        .await;
    let frontiers = live.frontiers().await;

    live.drop_all().await;
    assert_eq!(
        (written.is_err(), frontiers),
        (true, ("1".to_string(), "1".to_string()))
    );
}

/// Every store is checked before any is reset, as before an initialize: a
/// refusal leaves them all as they were.
#[tokio::test]
#[ignore = "needs a Postgres and a ClickHouse server"]
async fn a_reset_one_store_refuses_touches_neither() {
    let live = Live::new("reset_refused");
    live.initialize().await;
    live.drop_clickhouse().await;
    live.clickhouse_statement(format!("CREATE DATABASE `{}`", live.name))
        .await;
    live.clickhouse_statement(format!(
        "CREATE TABLE `{}`.someone_elses (x UInt8) ENGINE = MergeTree ORDER BY x",
        live.name
    ))
    .await;

    let refused = live.storage.reset().await.is_err();
    let kept = (
        live.storage.postgres.is_initialized().await.unwrap(),
        live.clickhouse_statement(format!(
            "SELECT count() FROM system.tables WHERE database = '{}' AND name = 'someone_elses'",
            live.name
        ))
        .await,
    );

    live.drop_all().await;
    assert_eq!((refused, kept), (true, (true, "1".to_string())));
}
