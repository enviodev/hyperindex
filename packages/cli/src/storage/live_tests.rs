//! Postgres with ClickHouse following it, against real servers.
//!
//! Run with `cargo test --lib storage::live -- --ignored`, which starts its own
//! servers.

use std::sync::Arc;

use pretty_assertions::assert_eq;

use super::batch::EffectCacheWrite;
use super::schema::{ClickHouseOptions, Entity, Schema};
use super::types::{Addresses, ChainConfig, Frontier, Progress, ResumedChain};
use super::{Batch, Holding, Initialize, Storage};
use crate::clickhouse;
use crate::columnar::{Arena, ColumnKind};
use crate::postgres;

struct Live {
    storage: Storage,
    name: String,
}

/// An account ClickHouse alone keeps.
fn account() -> Entity {
    Entity {
        postgres: false,
        ..clickhouse::live_tests::account_input()
    }
}

impl Live {
    fn new(name: &str) -> Self {
        Self::with(name, Vec::new())
    }

    fn with(name: &str, entities: Vec<Entity>) -> Self {
        let name = format!("envio_composite_{name}_{}", std::process::id());
        let schema: std::sync::Arc<Schema> = clickhouse::live_tests::schema_of(entities);
        let postgres = postgres::storage::Storage::new(
            postgres::live_tests::client(),
            postgres::storage::Settings {
                pg_schema: name.clone(),
                pg_user: "postgres".to_string(),
                numeric_array_as_text: false,
                isolated: false,
            },
            schema.clone(),
            Arc::new(|_| ()),
        )
        .unwrap();
        let clickhouse = clickhouse::live_tests::store_on(
            clickhouse::live_tests::connection(&name),
            false,
            schema.clone(),
        );
        Self {
            storage: Storage {
                schema,
                postgres: Arc::new(postgres),
                clickhouse: Some(Arc::new(clickhouse)),
            },
            name,
        }
    }

    async fn initialize(&self) {
        self.storage
            .initialize(clickhouse::live_tests::initialize_input())
            .await
            .unwrap();
        self.storage.resume(&[1]).await.unwrap();
        self.storage.take_over_clickhouse(&[1]).await.unwrap();
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
        clickhouse::live_tests::execute_on(&clickhouse::live_tests::connection("").url, statement)
            .await
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
        schema: a.storage.schema.clone(),
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
/// schema is gone holds data nothing says how far it got — or is another
/// deployment's, still backfilling towards its first event and holding no
/// batch yet.
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
    let live = Live::with("cache_after_commit", vec![account()]);
    live.initialize().await;
    let account = live.storage.schema.entities[0].clone();
    let mut cached = Arena::new(1, &[ColumnKind::Text, ColumnKind::Text]).unwrap();
    cached.set_bytes(0, 0, b"k");
    cached.set_bytes(1, 0, b"{}");
    cached
        .seal_unlent(&["id".to_string(), "output".to_string()])
        .unwrap();

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
            frontier: Frontier::from([(1, 1)]),
            changes: vec![Arc::new(clickhouse::live_tests::history(
                &account,
                &[("a", Some(("alice", "1")), 1)],
            ))],
            // Never created, so the insert into it fails.
            effect_caches: vec![EffectCacheWrite {
                table: "envio_effect_price".to_string(),
                create: false,
                rows: cached,
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

/// What a user writes into a ClickHouse table's definition — a `ttl`, an
/// `orderBy` — only the server checks. ClickHouse is built first, so a table it
/// refuses leaves Postgres as it was, and the next start sets both up again
/// rather than refusing them as diverged.
#[tokio::test]
#[ignore = "needs a Postgres and a ClickHouse server"]
async fn a_table_clickhouse_refuses_leaves_postgres_unset() {
    let live = Live::with(
        "refused_table",
        vec![Entity {
            clickhouse: Some(ClickHouseOptions {
                ttl: Some("no_such_column + INTERVAL 1 DAY".to_string()),
                ..ClickHouseOptions::default()
            }),
            ..account()
        }],
    );

    let initialized = live
        .storage
        .initialize(clickhouse::live_tests::initialize_input())
        .await
        .is_ok();
    let holding = live
        .storage
        .holding()
        .await
        .map_err(|error| format!("{error:#}"));

    live.drop_all().await;
    assert_eq!((initialized, holding), (false, Ok(Holding::Nothing)));
}

// https://github.com/enviodev/hyperindex/issues/1862
/// A process of a split run resumes only the chains it indexes: their rows,
/// addresses and effect caches, and every cross-chain cache. Its supervisor,
/// which indexes none, reads only where every chain stands.
#[tokio::test]
#[ignore = "needs a Postgres and a ClickHouse server"]
async fn a_resume_reads_only_the_chains_it_indexes() {
    let live = Live::new("resume_scoped");
    let chain = |id| ChainConfig {
        id,
        ..clickhouse::live_tests::initialize_input().chains[0].clone()
    };
    live.storage
        .initialize(Initialize {
            chains: vec![chain(1), chain(137)],
            contract_names: vec!["Token".to_string()],
            addresses: Addresses {
                chain_ids: vec![1, 137, 137],
                addresses: vec![vec![1; 20], vec![2; 20], vec![3; 20]],
                contract_ids: vec![0, 0, 0],
                registration_blocks: vec![5, 5, 6],
            },
            ..clickhouse::live_tests::initialize_input()
        })
        .await
        .unwrap();
    for (table, rows) in [
        ("envio_1_effect_price", 1),
        ("envio_137_effect_price", 2),
        ("envio_effect_price", 3),
    ] {
        postgres::live_tests::client()
            .batch(&format!(
                "CREATE TABLE \"{schema}\".\"{table}\" (\"id\" TEXT PRIMARY KEY, \"output\" JSONB); \
                 INSERT INTO \"{schema}\".\"{table}\" SELECT g::text, '1' FROM generate_series(1, {rows}) g",
                schema = live.name
            ))
            .await
            .unwrap();
    }
    let chain_ids =
        |chains: &[ResumedChain]| chains.iter().map(|chain| chain.id).collect::<Vec<_>>();
    let read = |resumed: super::Resumed| {
        let columns = resumed.addresses.arena.columns();
        (
            chain_ids(&resumed.chains),
            (0..resumed.addresses.arena.rows())
                .map(|row| (columns[0].f64_at(row), columns[1].bytes_at(row).to_vec()))
                .collect::<Vec<_>>(),
            resumed
                .caches
                .iter()
                .map(|stored| (stored.cache.table_name(), stored.rows))
                .collect::<Vec<_>>(),
        )
    };

    let worker = live.storage.resume(&[1]).await.map(read);
    let supervisor = live
        .storage
        .read_chain_progress(&[1, 137])
        .await
        .map(|chains| chain_ids(&chains));

    live.drop_all().await;
    assert_eq!(
        (
            worker.map_err(|error| format!("{error:#}")),
            supervisor.map_err(|error| format!("{error:#}")),
        ),
        (
            Ok((
                vec![1],
                vec![(1.0, vec![1; 20])],
                vec![
                    ("envio_1_effect_price".to_string(), 1),
                    ("envio_effect_price".to_string(), 3),
                ],
            )),
            Ok(vec![1, 137]),
        )
    );
}

// https://github.com/enviodev/hyperindex/issues/1862
/// The address table can hold tens of millions of rows, and its config rows
/// have no index of their own. A worker reads it once, for its own chains, and
/// finds the config's addresses among them. Its supervisor never reads it.
#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn startup_reads_the_address_table_only_to_resume_a_chain() {
    let name = format!("envio_address_scans_{}", std::process::id());
    let client = postgres::live_tests::pinned_client();
    let schema: Arc<Schema> = clickhouse::live_tests::schema_of(Vec::new());
    let storage = Storage {
        schema: schema.clone(),
        postgres: Arc::new(
            postgres::storage::Storage::new(
                client.clone(),
                postgres::storage::Settings {
                    pg_schema: name.clone(),
                    pg_user: "postgres".to_string(),
                    numeric_array_as_text: false,
                    isolated: false,
                },
                schema,
                Arc::new(|_| ()),
            )
            .unwrap(),
        ),
        clickhouse: None,
    };
    let chain = |id| ChainConfig {
        id,
        ..clickhouse::live_tests::initialize_input().chains[0].clone()
    };
    storage
        .initialize(Initialize {
            chains: vec![chain(1), chain(137)],
            contract_names: vec!["Token".to_string()],
            addresses: Addresses {
                chain_ids: vec![1, 137],
                addresses: vec![vec![1; 20], vec![2; 20]],
                contract_ids: vec![0, 0],
                registration_blocks: vec![-1, -1],
            },
            ..clickhouse::live_tests::initialize_input()
        })
        .await
        .unwrap();
    // The one connection is the backend that ran the reads: its counts reach
    // the shared statistics at the next transaction boundary once forced.
    let scans = || async {
        client
            .query("SELECT pg_stat_force_next_flush()", &[])
            .await
            .unwrap();
        client.query("SELECT 1", &[]).await.unwrap();
        let (rows, _) = client
            .query(
                &format!(
                    "SELECT (seq_scan + coalesce(idx_scan, 0))::int8 FROM pg_stat_user_tables \
                     WHERE schemaname = '{name}' AND relname = 'envio_addresses'"
                ),
                &[],
            )
            .await
            .unwrap();
        rows[0].get::<_, i64>(0)
    };

    let before = scans().await;
    storage.read_stored_config().await.unwrap();
    storage.resume(&[1]).await.unwrap();
    let after_worker = scans().await;
    storage.read_stored_config().await.unwrap();
    storage.read_chain_progress(&[1, 137]).await.unwrap();
    let after_supervisor = scans().await;

    client
        .batch(&format!("DROP SCHEMA IF EXISTS \"{name}\" CASCADE"))
        .await
        .unwrap();
    assert_eq!(
        (after_worker - before, after_supervisor - after_worker),
        (1, 0)
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
