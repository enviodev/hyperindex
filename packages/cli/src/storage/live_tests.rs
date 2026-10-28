//! Postgres with ClickHouse following it, against real servers.
//!
//! Run with `cargo test --lib storage::live -- --ignored`, which starts its own
//! servers.

use std::sync::Arc;

use pretty_assertions::assert_eq;

use super::batch::EffectCacheWrite;
use super::schema::{ClickHouseOptions, Entity, Schema};
use super::types::{Frontier, Progress};
use super::{Batch, Holding, Storage};
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
            frontier: Frontier {
                chain_ids: vec![1],
                checkpoint_ids: vec![1],
            },
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
