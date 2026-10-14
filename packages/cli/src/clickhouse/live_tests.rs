//! The ClickHouse store against a real server: every statement it builds is
//! one the server has to accept, and what it reads back has to be what it
//! wrote. Each test works in a database of its own, and resumes to chains it
//! makes up as Postgres would hand them over.
//!
//! Run with `cargo test --lib clickhouse::live -- --ignored`, against
//! `ENVIO_CLICKHOUSE_HOST` (default `http://localhost:8123`).

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

use pretty_assertions::assert_eq;

use super::client::{Client, Connection, Tuning};
use super::storage::{Settings, Storage};
use super::table::test_support::{column, entity_input};
use super::table::ClickHouseTableInput;
use crate::columnar::{Arena, ColumnKind};
use crate::config_parsing::system_config::ChainIdMode;
use crate::entity_filter::{Condition, Operator, ValueKind};
use crate::storage::rows::{ReadKind, ResultSet};
use crate::storage::types::{
    Addresses, Bounds, ChainConfig, Checkpoints, DiffCheckpoint, Frontier, Progress, ResumedChain,
    Sequence,
};
use crate::storage::{
    Batch, EntityStore, EntityWrite, Handoff, Initialize, Resume, RollbackWrite, Table, WriteError,
};

fn env(name: &str, default: &str) -> String {
    std::env::var(name)
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| default.to_string())
}

static COUNTER: AtomicU32 = AtomicU32::new(0);

pub(crate) fn connection(database: &str) -> Connection {
    Connection {
        url: env("ENVIO_CLICKHOUSE_HOST", "http://localhost:8123"),
        username: env("ENVIO_CLICKHOUSE_USERNAME", "default"),
        password: std::env::var("ENVIO_CLICKHOUSE_PASSWORD")
            .unwrap_or_else(|_| "testing".to_string()),
        database: database.to_string(),
    }
}

fn store(database: &str) -> Storage {
    Storage::new(
        connection(database),
        Tuning::default(),
        Arc::new(|_: &str| {}),
        Settings {
            chain_id_mode: ChainIdMode::Int32,
            replicated: false,
            database_engine: None,
        },
    )
    .unwrap()
}

struct Live {
    storage: Storage,
    database: String,
}

impl Live {
    fn new() -> Self {
        let database = format!(
            "envio_rust_live_{}_{}_{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis()
        );
        Self {
            storage: store(&database),
            database,
        }
    }

    /// Another process's store on the same database.
    fn another_process(&self) -> Storage {
        store(&self.database)
    }

    fn table(&self, input: ClickHouseTableInput) -> Arc<Table> {
        Arc::new(Table {
            name: input.name.clone(),
            postgres: None,
            clickhouse: Some(Arc::new(self.storage.register(input).unwrap())),
        })
    }

    fn account(&self) -> Arc<Table> {
        self.table(entity_input(
            "Account",
            vec![
                column("id", "String"),
                column("owner", "String"),
                column("balance", "BigInt"),
            ],
        ))
    }

    async fn drop_database(&self) {
        self.execute(format!("DROP DATABASE IF EXISTS `{}` SYNC", self.database))
            .await;
    }

    async fn execute(&self, statement: String) -> String {
        let response = reqwest::Client::new()
            .post(env("ENVIO_CLICKHOUSE_HOST", "http://localhost:8123"))
            .basic_auth(
                env("ENVIO_CLICKHOUSE_USERNAME", "default"),
                Some(
                    std::env::var("ENVIO_CLICKHOUSE_PASSWORD")
                        .unwrap_or_else(|_| "testing".to_string()),
                ),
            )
            .body(statement)
            .send()
            .await
            .unwrap();
        assert!(
            response.status().is_success(),
            "{}",
            response.text().await.unwrap()
        );
        response.text().await.unwrap().trim().to_string()
    }

    async fn count(&self, table: &str) -> String {
        self.execute(format!("SELECT count() FROM `{}`.`{table}`", self.database))
            .await
    }

    async fn load(&self, table: &Table, condition: Condition) -> Vec<Vec<String>> {
        rows(
            &self
                .storage
                .load_where(table, vec![condition])
                .await
                .unwrap(),
        )
    }

    /// Chain 1's frontier, as the entities' views read it.
    async fn frontier(&self) -> String {
        self.execute(format!(
            "SELECT checkpoint_id FROM `{}`.envio_chains FINAL WHERE chain_id = 1",
            self.database
        ))
        .await
    }
}

async fn initialize(live: &Live, tables: Vec<Arc<Table>>) {
    live.storage
        .initialize(&Initialize {
            sequence: Sequence::SharedAcrossChains,
            tables,
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
            instance: "instance".to_string(),
            contract_names: Vec::new(),
            addresses: Addresses::default(),
        })
        .await
        .unwrap();
}

/// Resumes `storage` to chain 1 as Postgres hands it over having committed
/// up to `checkpoint_id`, at `progress_block`.
async fn resume(
    storage: &Storage,
    tables: Vec<Arc<Table>>,
    checkpoint_id: i64,
    progress_block: i32,
) {
    storage
        .resume(&Resume {
            sequence: Sequence::SharedAcrossChains,
            tables,
            committed: vec![committed(checkpoint_id, progress_block)],
        })
        .await
        .unwrap();
}

/// Chain 1 as Postgres hands it over having committed up to `checkpoint_id`.
fn committed(checkpoint_id: i64, progress_block: i32) -> ResumedChain {
    ResumedChain {
        id: 1,
        start_block: 0,
        end_block: None,
        max_reorg_depth: 200,
        first_event_block: None,
        ready_at: None,
        events_processed: 0.0,
        progress_block,
        progress_block_time: None,
        source_block: 1000,
        checkpoint_id,
    }
}

/// An account history row: set to `(owner, balance)`, or a delete.
type Change<'a> = (&'a str, Option<(&'a str, &'a str)>, u64);

fn history(changes: &[Change<'_>]) -> Arena {
    let mut arena = Arena::new(
        changes.len(),
        &[
            ColumnKind::Text,
            ColumnKind::Text,
            ColumnKind::Text,
            ColumnKind::U64,
            ColumnKind::Text,
        ],
    )
    .unwrap();
    for (row, (id, value, checkpoint)) in changes.iter().enumerate() {
        arena.set_bytes(0, row, id.as_bytes());
        match value {
            Some((owner, balance)) => {
                arena.set_bytes(1, row, owner.as_bytes());
                arena.set_bytes(2, row, balance.as_bytes());
                arena.set_bytes(4, row, b"SET");
            }
            None => {
                arena.mark_null(1, row);
                arena.mark_null(2, row);
                arena.set_bytes(4, row, b"DELETE");
            }
        }
        arena.set_u64(3, row, *checkpoint);
    }
    arena
        .seal_unlent(
            &[
                "id",
                "owner",
                "balance",
                "envio_checkpoint_id",
                "envio_change",
            ]
            .map(str::to_string),
        )
        .unwrap();
    arena
}

fn checkpoints(entries: &[(i64, i64, i32)]) -> Checkpoints {
    Checkpoints {
        ids: entries.iter().map(|(id, _, _)| *id).collect(),
        chain_ids: entries.iter().map(|(_, chain, _)| *chain).collect(),
        block_numbers: entries.iter().map(|(_, _, block)| *block).collect(),
        block_hashes: entries
            .iter()
            .map(|(_, _, block)| Some(format!("0x{block}")))
            .collect(),
        events_processed: entries.iter().map(|_| 1).collect(),
        keeps_history: entries.iter().map(|_| true).collect(),
    }
}

fn batch(
    table: &Arc<Table>,
    changes: &[Change<'_>],
    checkpoint_entries: &[(i64, i64, i32)],
    frontier: (i64, i64),
) -> Batch {
    Batch {
        progress: vec![Progress {
            chain_id: frontier.0,
            progress_block: checkpoint_entries.last().map_or(0, |(_, _, block)| *block),
            progress_block_time: Some(1_700_000_000.0),
            events_processed: checkpoint_entries.len() as f64,
            source_block: 1000,
        }],
        entities: vec![EntityWrite {
            table: table.clone(),
            chain_id: None,
            postgres: None,
            clickhouse: Some(history(changes)),
        }],
        frontier: Frontier {
            chain_ids: vec![frontier.0],
            checkpoint_ids: vec![frontier.1],
        },
        checkpoints: checkpoints(checkpoint_entries),
        ..Batch::default()
    }
}

async fn write(live: &Live, batch: Batch) {
    if let Err(error) = live.storage.write_batch(batch, Handoff::default()).await {
        match error {
            WriteError::Failed(failure) => panic!("{}: {:#}", failure.context, failure.error),
            WriteError::Gated => panic!("gated"),
        }
    }
}

/// A result's rows, every cell as the value JavaScript would see.
fn rows(result: &ResultSet) -> Vec<Vec<String>> {
    let columns = result.arena.columns();
    (0..result.arena.rows())
        .map(|row| {
            columns
                .iter()
                .zip(&result.columns)
                .map(|(column, read)| {
                    if column.is_null(row) {
                        return "null".to_string();
                    }
                    match read.kind {
                        ReadKind::Text | ReadKind::Json => column.str_at(row).unwrap().to_string(),
                        ReadKind::Bytes => format!("{:?}", column.bytes_at(row)),
                        _ => column.f64_at(row).to_string(),
                    }
                })
                .collect()
        })
        .collect()
}

fn names(result: &ResultSet) -> Vec<String> {
    result
        .columns
        .iter()
        .map(|column| column.name.clone())
        .collect()
}

fn eq(column: &str, value: &str) -> Condition {
    Condition {
        column: column.to_string(),
        operator: Operator::Eq,
        values: vec![vec![Some(value.to_string())]],
        kind: ValueKind::Text,
        is_list: false,
        enum_name: None,
        is_chain_id: false,
    }
}

fn sorted(mut rows: Vec<Vec<String>>) -> Vec<Vec<String>> {
    rows.sort();
    rows
}

fn row(cells: &[&str]) -> Vec<String> {
    cells.iter().map(|cell| cell.to_string()).collect()
}

/// A TTL reads the columns of every history row, and a delete leaves all but
/// its key at their defaults. Were the delete to expire before the set it
/// cancels, the entity would come back.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_ttl_never_expires_a_delete_before_the_set_it_cancels() {
    let live = Live::new();
    let mut input = entity_input(
        "Account",
        vec![
            column("id", "String"),
            column("owner", "String"),
            column("balance", "BigInt"),
        ],
    );
    input.ttl =
        Some("if(owner = '', toDateTime('2000-01-01'), toDateTime('2100-01-01'))".to_string());
    let account = live.table(input);
    initialize(&live, vec![account.clone()]).await;
    write(
        &live,
        batch(
            &account,
            &[("a", Some(("alice", "1")), 1), ("a", None, 2)],
            &[(1, 1, 10), (2, 1, 11)],
            (1, 2),
        ),
    )
    .await;
    live.execute(format!(
        "OPTIMIZE TABLE `{}`.`envio_history_Account` FINAL",
        live.database
    ))
    .await;

    let loaded = live.load(&account, eq("id", "a")).await;
    live.drop_database().await;
    assert_eq!(loaded, Vec::<Vec<String>>::new());
}

/// A query that fails once its first rows are on the wire has already answered
/// with a success status. Taking what arrived would hand a reader a partial
/// result — or none — as if it were the whole of it.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_read_that_fails_partway_is_an_error() {
    let client = Client::new(
        connection("default"),
        Tuning::default(),
        Arc::new(|_: &str| {}),
    )
    .unwrap();
    let read = client
        .read(
            "SELECT number, throwIf(number = 500000) FROM numbers(1000000) FORMAT RowBinary"
                .to_string(),
        )
        .await;
    assert!(
        read.is_err(),
        "read {:?} bytes",
        read.map(|body| body.len())
    );
}

/// The instance is what tells the database apart from one built beside
/// another initialize of the same config, so there is none until an
/// initialize has finished building it.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn the_instance_reads_back_as_it_was_initialized() {
    let live = Live::new();
    let before = live.storage.instance().await.unwrap();
    initialize(&live, vec![live.account()]).await;

    let after = live.storage.instance().await.unwrap();
    live.drop_database().await;
    assert_eq!((before, after), (None, Some("instance".to_string())));
}

#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_load_reads_each_entitys_latest_row() {
    let live = Live::new();
    let account = live.account();
    initialize(&live, vec![account.clone()]).await;
    write(
        &live,
        batch(
            &account,
            &[
                ("a", Some(("alice", "10")), 1),
                ("b", Some(("bob", "5")), 1),
                ("c", Some(("carol", "7")), 1),
            ],
            &[(1, 1, 10)],
            (1, 1),
        ),
    )
    .await;
    write(
        &live,
        batch(
            &account,
            &[
                ("a", Some(("alice", "11")), 2),
                ("b", Some(("alice", "6")), 2),
                ("c", None, 2),
            ],
            &[(2, 1, 20)],
            (1, 2),
        ),
    )
    .await;

    let by_id = |id: &str| eq("id", id);
    let load = |conditions: Vec<Condition>| live.storage.load_where(&account, conditions);
    let (a, c, alices, bobs) = (
        load(vec![by_id("a")]).await.unwrap(),
        load(vec![by_id("c")]).await.unwrap(),
        load(vec![eq("owner", "alice")]).await.unwrap(),
        load(vec![eq("owner", "bob")]).await.unwrap(),
    );
    live.drop_database().await;
    assert_eq!(
        (
            rows(&a),
            rows(&c),
            sorted(rows(&alices)),
            rows(&bobs),
            names(&a)
        ),
        (
            vec![row(&["a", "alice", "11"])],
            Vec::<Vec<String>>::new(),
            vec![row(&["a", "alice", "11"]), row(&["b", "alice", "6"])],
            // b belonged to bob once, but no longer does.
            Vec::<Vec<String>>::new(),
            vec!["id".to_string(), "owner".to_string(), "balance".to_string()]
        )
    );
}

/// A batch loads every id its handlers touch in one read, thousands at a time,
/// and with a value condition beside them the ids appear in the read twice. The
/// server caps how long a statement may be, which a read has to fit under
/// whatever the ids add up to.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_load_of_more_ids_than_a_statement_holds_reads_them_all() {
    let live = Live::new();
    let account = live.account();
    initialize(&live, vec![account.clone()]).await;
    let ids = (0..6000)
        .map(|index| format!("0x{index:040x}"))
        .collect::<Vec<_>>();
    let changes = ids
        .iter()
        .map(|id| (id.as_str(), Some(("alice", "1")), 1))
        .collect::<Vec<_>>();
    write(&live, batch(&account, &changes, &[(1, 1, 10)], (1, 1))).await;

    let by_ids = Condition {
        operator: Operator::In,
        values: ids.iter().map(|id| vec![Some(id.clone())]).collect(),
        ..eq("id", "")
    };
    let loaded = |conditions: Vec<Condition>| async {
        live.storage
            .load_where(&account, conditions)
            .await
            .map(|result| result.arena.rows())
            .map_err(|error| format!("{error:#}"))
    };
    let (by_id, by_id_and_owner) = (
        loaded(vec![by_ids.clone()]).await,
        loaded(vec![by_ids, eq("owner", "alice")]).await,
    );
    live.drop_database().await;
    assert_eq!((by_id, by_id_and_owner), (Ok(6000), Ok(6000)));
}

/// A long list of numbers is spelled in the statement: alone it runs past the
/// server's default cap on a statement's length, and beside a list of ids,
/// which go as a form, past the longest form field the server reads.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_load_spelling_a_long_list_of_numbers_reads_what_it_names() {
    let live = Live::new();
    let account = live.account();
    initialize(&live, vec![account.clone()]).await;
    write(
        &live,
        batch(
            &account,
            &[
                ("a", Some(("alice", "1")), 1),
                ("b", Some(("bob", "2")), 1),
                ("c", Some(("carol", "300000")), 1),
            ],
            &[(1, 1, 10)],
            (1, 1),
        ),
    )
    .await;

    let balances = Condition {
        operator: Operator::In,
        kind: ValueKind::Number,
        values: (0..30_000)
            .map(|balance| vec![Some(balance.to_string())])
            .collect(),
        ..eq("balance", "")
    };
    let by_ids = Condition {
        operator: Operator::In,
        values: ["a", "c"].map(|id| vec![Some(id.to_string())]).to_vec(),
        ..eq("id", "")
    };
    let loaded = |conditions: Vec<Condition>| async {
        live.storage
            .load_where(&account, conditions)
            .await
            .map(|result| sorted(rows(&result)))
            .map_err(|error| format!("{error:#}"))
    };
    let (alone, beside_ids) = (
        loaded(vec![balances.clone()]).await,
        loaded(vec![by_ids, balances]).await,
    );
    live.drop_database().await;
    assert_eq!(
        (alone, beside_ids),
        (
            Ok(vec![row(&["a", "alice", "1"]), row(&["b", "bob", "2"])]),
            Ok(vec![row(&["a", "alice", "1"])])
        )
    );
}

/// A value the statement spells as a call — a timestamp, bytes, a decimal —
/// counts as several of the elements the server caps a statement at, which a
/// long list of them outgrows long before the statement's own length does.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_load_spelling_a_long_list_of_timestamps_reads_what_it_names() {
    let live = Live::new();
    let event = live.table(entity_input(
        "Event",
        vec![column("id", "String"), column("at", "Date")],
    ));
    initialize(&live, vec![event.clone()]).await;

    let at = Condition {
        operator: Operator::In,
        kind: ValueKind::Timestamp,
        values: (0..20_000)
            .map(|second| vec![Some(format!("2024-01-01T00:00:{:02}.000Z", second % 60))])
            .collect(),
        ..eq("at", "")
    };
    let loaded = live
        .storage
        .load_where(&event, vec![at])
        .await
        .map(|result| result.arena.rows())
        .map_err(|error| format!("{error:#}"));
    live.drop_database().await;
    assert_eq!(loaded, Ok(0));
}

/// A process that died mid-write can leave an insert running on the server,
/// one that finishes after the next process resumed and trimmed what never
/// committed. Its rows would read as that run's once its frontier passed them.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn an_insert_a_dead_process_left_running_lands_nothing_after_the_resume() {
    let live = Live::new();
    let account = live.account();
    initialize(&live, vec![account.clone()]).await;
    write(
        &live,
        batch(
            &account,
            &[("a", Some(("alice", "1")), 1)],
            &[(1, 1, 10)],
            (1, 1),
        ),
    )
    .await;
    let late = tokio::spawn(send_as(
        format!("{}late", super::client::insert_tag(&live.database, &[1])),
        format!(
            "INSERT INTO `{}`.envio_history_Account (id, owner, balance, envio_checkpoint_id, \
             envio_change) SELECT toString(number), 'mallory', '9', 2, 'SET' FROM numbers(3) \
             WHERE sleepEachRow(1) = 0 SETTINGS max_block_size = 1",
            live.database
        ),
    ));
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;

    resume(&live.another_process(), vec![account], 1, 10).await;
    let _ = late.await;
    let landed = live
        .execute(format!(
            "SELECT count() FROM `{}`.envio_history_Account WHERE envio_checkpoint_id = 2",
            live.database
        ))
        .await;

    live.drop_database().await;
    assert_eq!(landed, "0");
}

/// Sends `statement` under `query_id`, answering whether it succeeded.
async fn send_as(query_id: String, statement: String) -> bool {
    reqwest::Client::new()
        .post(env("ENVIO_CLICKHOUSE_HOST", "http://localhost:8123"))
        .query(&[("query_id", query_id)])
        .basic_auth(
            env("ENVIO_CLICKHOUSE_USERNAME", "default"),
            Some(
                std::env::var("ENVIO_CLICKHOUSE_PASSWORD")
                    .unwrap_or_else(|_| "testing".to_string()),
            ),
        )
        .body(statement)
        .send()
        .await
        .is_ok_and(|response| response.status().is_success())
}

/// A process that died mid-commit can still have its chains insert land after
/// the next process resumed and trimmed that batch's rows away. Landing then,
/// it must not move the frontier back over the checkpoint the next process
/// writes its own rows at before Postgres has committed them.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_commit_landing_after_the_next_resume_claims_nothing() {
    let live = Live::new();
    let account = live.account();
    initialize(&live, vec![account.clone()]).await;
    write(
        &live,
        batch(
            &account,
            &[("a", Some(("alice", "1")), 1)],
            &[(1, 1, 10)],
            (1, 1),
        ),
    )
    .await;

    let (landed, rows_landed) = tokio::sync::oneshot::channel();
    let (commit, may_commit) = tokio::sync::oneshot::channel();
    let dying = live.storage.write_batch(
        batch(
            &account,
            &[("a", Some(("alice", "2")), 2)],
            &[(2, 1, 20)],
            (1, 2),
        ),
        Handoff {
            landed: Some(landed),
            commit: Some(Box::pin(async move { may_commit.await.unwrap_or(false) })),
            committed: None,
        },
    );
    let next = async {
        rows_landed.await.unwrap();
        resume(&live.another_process(), vec![account.clone()], 1, 10).await;
        let resumed = live.frontier().await;
        commit.send(true).unwrap();
        resumed
    };
    let (dying, resumed) = tokio::join!(dying, next);
    let after = live.frontier().await;

    live.drop_database().await;
    assert_eq!(
        (dying.is_ok(), resumed, after),
        (true, "1".to_string(), "1".to_string())
    );
}

/// A reset empties the indexer's database, so it refuses one that also holds
/// someone else's tables, as initializing does.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_reset_leaves_a_database_with_someone_elses_tables_alone() {
    let live = Live::new();
    live.execute(format!("CREATE DATABASE `{}`", live.database))
        .await;
    live.execute(format!(
        "CREATE TABLE `{}`.`orders` (id UInt64) ENGINE = MergeTree ORDER BY id",
        live.database
    ))
    .await;

    let refused = live.storage.reset().await.is_err();
    let orders = live
        .execute(format!(
            "SELECT count() FROM system.tables WHERE database = '{}' AND name = 'orders'",
            live.database
        ))
        .await;
    live.drop_database().await;
    assert_eq!((refused, orders), (true, "1".to_string()));
}

/// A batch replayed after a resume trimmed it lands byte for byte as before,
/// which an engine that deduplicates inserts (ClickHouse Cloud's does) would
/// drop while reporting success.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_replayed_insert_lands_where_the_engine_deduplicates() {
    let live = Live::new();
    let account = live.account();
    initialize(&live, vec![account.clone()]).await;
    live.execute(format!(
        "ALTER TABLE `{}`.`envio_history_Account` MODIFY SETTING \
         non_replicated_deduplication_window = 100",
        live.database
    ))
    .await;
    let replayed = || {
        batch(
            &account,
            &[("a", Some(("alice", "10")), 1)],
            &[(1, 1, 10)],
            (1, 1),
        )
    };
    write(&live, replayed()).await;
    write(&live, replayed()).await;

    let history = live.count("envio_history_Account").await;
    live.drop_database().await;
    assert_eq!(history, "2");
}

/// A write Postgres never committed lands its rows but is never told to make
/// them readable, and the resume after it removes them.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_resume_trims_what_an_uncommitted_write_left_behind() {
    let live = Live::new();
    let account = live.account();
    initialize(&live, vec![account.clone()]).await;
    write(
        &live,
        batch(
            &account,
            &[("a", Some(("alice", "1")), 1)],
            &[(1, 1, 10)],
            (1, 1),
        ),
    )
    .await;
    let uncommitted = live
        .storage
        .write_batch(
            batch(
                &account,
                &[("a", Some(("alice", "2")), 2)],
                &[(2, 1, 20)],
                (1, 2),
            ),
            Handoff {
                landed: None,
                commit: Some(Box::pin(async { false })),
                committed: None,
            },
        )
        .await;
    let (landed_history, landed_checkpoints) = (
        live.count("envio_history_Account").await,
        live.count("envio_checkpoints").await,
    );

    let before = live.load(&account, eq("id", "a")).await;
    resume(&live.storage, vec![account.clone()], 1, 10).await;
    let (history, checkpoints) = (
        live.count("envio_history_Account").await,
        live.count("envio_checkpoints").await,
    );
    live.drop_database().await;
    assert_eq!(
        (
            matches!(uncommitted, Err(WriteError::Gated)),
            (landed_history, landed_checkpoints),
            before,
            (history, checkpoints)
        ),
        (
            true,
            ("2".to_string(), "2".to_string()),
            vec![row(&["a", "alice", "1"])],
            ("1".to_string(), "1".to_string())
        )
    );
}

/// A database an older envio built holds a chains table without the version
/// column, and initializing over it is how a deployment upgrades.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn initializing_takes_over_a_database_an_older_envio_built() {
    let live = Live::new();
    live.execute(format!("CREATE DATABASE `{}`", live.database))
        .await;
    live.execute(format!(
        "CREATE TABLE `{}`.envio_chains (chain_id Int32, checkpoint_id UInt64) ENGINE = \
         MergeTree ORDER BY chain_id",
        live.database
    ))
    .await;

    let account = live.account();
    let initialized = live
        .storage
        .initialize(&Initialize {
            sequence: Sequence::SharedAcrossChains,
            tables: vec![account],
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
            instance: "instance".to_string(),
            contract_names: Vec::new(),
            addresses: Addresses::default(),
        })
        .await
        .map_err(|error| format!("{error:#}"));
    let frontier = live.frontier().await;
    live.drop_database().await;
    assert_eq!((initialized, frontier), (Ok(()), "0".to_string()));
}

/// The same commit landing after the next process initialized afresh lands in
/// the tables that process built, and must not claim the checkpoint over the
/// rows it hasn't written yet either.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_commit_landing_after_the_next_initialize_claims_nothing() {
    let live = Live::new();
    let account = live.account();
    initialize(&live, vec![account.clone()]).await;

    let (landed, rows_landed) = tokio::sync::oneshot::channel();
    let (commit, may_commit) = tokio::sync::oneshot::channel();
    let dying = live.storage.write_batch(
        batch(
            &account,
            &[("a", Some(("alice", "1")), 1)],
            &[(1, 1, 10)],
            (1, 1),
        ),
        Handoff {
            landed: Some(landed),
            commit: Some(Box::pin(async move { may_commit.await.unwrap_or(false) })),
            committed: None,
        },
    );
    let next = async {
        rows_landed.await.unwrap();
        let next = Live {
            storage: live.another_process(),
            database: live.database.clone(),
        };
        initialize(&next, vec![next.account()]).await;
        commit.send(true).unwrap();
    };
    let (dying, ()) = tokio::join!(dying, next);
    let after = live.frontier().await;

    live.drop_database().await;
    assert_eq!((dying.is_ok(), after), (true, "0".to_string()));
}

/// ClickHouse trims back to what Postgres committed, whatever its own chains'
/// rows say.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_resume_trims_back_to_what_postgres_committed() {
    let live = Live::new();
    let account = live.account();
    initialize(&live, vec![account.clone()]).await;
    write(
        &live,
        batch(
            &account,
            &[("a", Some(("alice", "1")), 1)],
            &[(1, 1, 10)],
            (1, 1),
        ),
    )
    .await;
    write(
        &live,
        batch(
            &account,
            &[("a", Some(("alice", "2")), 2)],
            &[(2, 1, 20)],
            (1, 2),
        ),
    )
    .await;

    resume(&live.storage, vec![account.clone()], 1, 10).await;
    let loaded = live.load(&account, eq("id", "a")).await;
    let (history, frontier) = (
        live.count("envio_history_Account").await,
        live.frontier().await,
    );
    live.drop_database().await;
    assert_eq!(
        (loaded, history, frontier),
        (
            vec![row(&["a", "alice", "1"])],
            "1".to_string(),
            "1".to_string()
        )
    );
}

/// Every batch Postgres committed landed in ClickHouse first, as the
/// checkpoint its frontier names. A database without that checkpoint lost the
/// batch after taking it — a server that dropped an acknowledged insert, a
/// restore from an older backup — and a resume over it would serve the
/// entities as they were before it, for good.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_resume_refuses_a_database_missing_a_batch_postgres_committed() {
    let live = Live::new();
    let account = live.account();
    initialize(&live, vec![account.clone()]).await;
    write(
        &live,
        batch(
            &account,
            &[("a", Some(("alice", "1")), 1)],
            &[(1, 1, 10)],
            (1, 1),
        ),
    )
    .await;

    let resumed = live
        .storage
        .resume(&Resume {
            sequence: Sequence::SharedAcrossChains,
            tables: vec![account],
            committed: vec![committed(2, 20)],
        })
        .await
        .map_err(|error| format!("{error:#}"));
    live.drop_database().await;
    assert_eq!(
        resumed,
        Err(format!(
            "Failed to resume ClickHouse storage: ClickHouse database \"{}\" doesn't hold \
             batches Postgres committed: chain 1 through checkpoint 2. ClickHouse lost them \
             after taking them, or was restored from an older backup: index from scratch, or \
             point ENVIO_CLICKHOUSE_DATABASE at the database that holds them.",
            live.database
        ))
    );
}

/// A rollback writes, at its diff checkpoint, the row each entity it touched
/// held at the target: restored, or deleted. The rows it orphaned stay in the
/// history, so every read resolves an entity by its latest row at or below a
/// standing checkpoint, and a later rollback to the diff checkpoint restores
/// what the first one did rather than what it orphaned.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_rollback_restores_the_target_at_its_diff_checkpoint() {
    let live = Live::new();
    let account = live.account();
    initialize(&live, vec![account.clone()]).await;
    write(
        &live,
        batch(
            &account,
            &[("a", Some(("alice", "1")), 1)],
            &[(1, 1, 10)],
            (1, 1),
        ),
    )
    .await;
    write(
        &live,
        batch(
            &account,
            &[
                ("a", Some(("alice", "2")), 2),
                ("c", Some(("carol", "3")), 2),
            ],
            &[(2, 1, 20), (3, 1, 30)],
            (1, 3),
        ),
    )
    .await;
    let bounds = |checkpoint_id: i64| Bounds {
        sequence: Sequence::SharedAcrossChains,
        chain_ids: vec![1],
        checkpoint_ids: vec![checkpoint_id],
    };

    let (removed, restored) = live
        .storage
        .rollback_data(&account, &bounds(1))
        .await
        .unwrap();
    let before = (
        rows(&removed),
        rows(&restored),
        live.load(&account, eq("id", "a")).await,
        live.load(&account, eq("owner", "carol")).await,
    );

    let mut rollback = batch(
        &account,
        &[("a", Some(("alice", "1")), 4), ("c", None, 4)],
        &[],
        (1, 4),
    );
    rollback.progress.clear();
    rollback.rollback = Some(RollbackWrite {
        bounds: bounds(1),
        tables: vec![account.clone()],
        progress: vec![Progress {
            chain_id: 1,
            progress_block: 15,
            progress_block_time: None,
            events_processed: 1.0,
            source_block: 1000,
        }],
        removed_addresses: Addresses::default(),
        diff_checkpoints: vec![DiffCheckpoint {
            chain_id: 1,
            checkpoint_id: 4,
            block_number: 15,
        }],
    });
    write(&live, rollback).await;
    let rolled_back = (
        live.load(&account, eq("id", "a")).await,
        live.load(&account, eq("owner", "carol")).await,
    );

    write(
        &live,
        batch(
            &account,
            &[
                ("a", Some(("alice", "5")), 5),
                ("d", Some(("dave", "6")), 5),
            ],
            &[(5, 1, 16)],
            (1, 5),
        ),
    )
    .await;
    let (removed, restored) = live
        .storage
        .rollback_data(&account, &bounds(4))
        .await
        .unwrap();
    let to_the_diff = (rows(&removed), rows(&restored));

    live.drop_database().await;
    assert_eq!(
        (before, rolled_back, to_the_diff),
        (
            (
                vec![row(&["c"])],
                vec![row(&["a", "alice", "1", "SET"])],
                vec![row(&["a", "alice", "2"])],
                vec![row(&["c", "carol", "3"])],
            ),
            (vec![row(&["a", "alice", "1"])], Vec::<Vec<String>>::new()),
            (vec![row(&["d"])], vec![row(&["a", "alice", "1", "SET"])]),
        )
    );
}
