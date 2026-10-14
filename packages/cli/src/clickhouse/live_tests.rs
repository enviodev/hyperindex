//! The ClickHouse store against a real server: every statement it builds is
//! one the server has to accept, and what it reads back has to be what it
//! wrote. Each test works in a database of its own.
//!
//! Run with `cargo test --lib clickhouse::live -- --ignored`, against
//! `ENVIO_CLICKHOUSE_HOST` (default `http://localhost:8123`).

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

use pretty_assertions::assert_eq;

use super::client::{Client, Connection, Tuning};
use super::storage::{Settings, Storage};
use super::table::test_support::{column, entity_input};
use super::table::{ClickHouseTableInput, ClickHouseTableKind};
use crate::columnar::{Arena, ColumnKind};
use crate::config_parsing::system_config::ChainIdMode;
use crate::entity_filter::{Condition, Operator, ValueKind};
use crate::storage::rows::{ReadKind, ResultSet};
use crate::storage::types::{
    Addresses, Bounds, ChainConfig, ChainMeta, Checkpoints, DiffCheckpoint, Frontier, Progress,
    Sequence,
};
use crate::storage::{
    Backend, Batch, CacheDump, CacheFile, EffectCacheWrite, EntityWrite, Initialize, Resume,
    RollbackWrite, Rows, Table,
};

fn env(name: &str, default: &str) -> String {
    std::env::var(name)
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| default.to_string())
}

static COUNTER: AtomicU32 = AtomicU32::new(0);

fn connection(database: &str) -> Connection {
    Connection {
        url: env("ENVIO_CLICKHOUSE_HOST", "http://localhost:8123"),
        username: env("ENVIO_CLICKHOUSE_USERNAME", "default"),
        password: std::env::var("ENVIO_CLICKHOUSE_PASSWORD")
            .unwrap_or_else(|_| "testing".to_string()),
        database: database.to_string(),
    }
}

struct Live {
    storage: Storage,
    database: String,
}

impl Live {
    fn new(primary: bool) -> Self {
        let database = format!(
            "envio_rust_live_{}_{}_{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis()
        );
        let storage = Storage::new(
            connection(&database),
            Tuning::default(),
            Arc::new(|_: &str| {}),
            Settings {
                chain_id_mode: ChainIdMode::Int32,
                replicated: false,
                database_engine: None,
                primary,
            },
        )
        .unwrap();
        Self { storage, database }
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
        self.storage.reset().await.unwrap();
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
}

fn chain(id: i64) -> ChainConfig {
    ChainConfig {
        id,
        ecosystem: "evm".to_string(),
        start_block: 0,
        end_block: None,
        max_reorg_depth: 200,
    }
}

async fn initialize(live: &Live, tables: Vec<Arc<Table>>, chains: Vec<ChainConfig>) {
    live.storage
        .initialize(&Initialize {
            sequence: Sequence::SharedAcrossChains,
            tables,
            partitions: Vec::new(),
            enums: Vec::new(),
            chains,
            envio_info: "{\"config\":1}".to_string(),
            contract_names: vec!["Token".to_string()],
            addresses: Addresses {
                chain_ids: vec![1],
                addresses: vec![vec![0xab; 20]],
                contract_ids: vec![0],
                registration_blocks: vec![-1],
                checkpoint_ids: vec![],
            },
        })
        .await
        .unwrap();
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
        rollback: None,
        progress: vec![Progress {
            chain_id: frontier.0,
            progress_block: checkpoint_entries.last().map_or(0, |(_, _, block)| *block),
            progress_block_time: Some(1_700_000_000.0),
            events_processed: checkpoint_entries.len() as f64,
            source_block: 1000,
        }],
        raw_events: None,
        entities: if changes.is_empty() {
            Vec::new()
        } else {
            vec![EntityWrite {
                table: table.clone(),
                chain_id: None,
                postgres: None,
                clickhouse: Some(history(changes)),
            }]
        },
        chain_meta: Vec::new(),
        addresses: Addresses::default(),
        frontier: Frontier {
            chain_ids: vec![frontier.0],
            checkpoint_ids: vec![frontier.1],
        },
        checkpoints: checkpoints(checkpoint_entries),
        effect_caches: Vec::new(),
    }
}

async fn write(live: &Live, batch: Batch) {
    if let Err(error) = live.storage.write_batch(batch, None).await {
        match error {
            crate::storage::WriteError::Failed(failure) => {
                panic!("{}: {:#}", failure.context, failure.error)
            }
            crate::storage::WriteError::Gated => panic!("gated"),
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

// A TTL reads the columns of every history row, and a delete leaves all but
// its key at their defaults. Were the delete to expire before the set it
// cancels, the entity would come back.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_ttl_never_expires_a_delete_before_the_set_it_cancels() {
    let live = Live::new(true);
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
    initialize(&live, vec![account.clone()], vec![chain(1)]).await;
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

    let loaded = live
        .storage
        .load_where(&account, vec![eq("id", "a")])
        .await
        .unwrap();
    live.drop_database().await;
    assert_eq!(rows(&loaded), Vec::<Vec<String>>::new());
}

// A query that fails once its first rows are on the wire has already answered
// with a success status. Taking what arrived would hand a reader a partial
// result — or none — as if it were the whole of it.
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

#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_primary_reads_back_the_record_it_was_initialized_with() {
    let live = Live::new(true);
    let account = live.account();
    let initialized_before = live.storage.is_initialized().await.unwrap();
    initialize(&live, vec![account], vec![chain(1)]).await;

    let stored = live.storage.read_stored_config().await.unwrap();
    let initialized = live.storage.is_initialized().await.unwrap();
    live.drop_database().await;
    assert_eq!(
        (
            initialized_before,
            initialized,
            stored.config.envio_info,
            stored.config.contract_names,
            stored
                .config
                .chains
                .iter()
                .map(|chain| (chain.id, chain.ecosystem.clone(), chain.max_reorg_depth))
                .collect::<Vec<_>>(),
            names(&stored.config_addresses),
            rows(&stored.config_addresses),
        ),
        (
            false,
            true,
            Some("{\"config\":1}".to_string()),
            Some(vec!["Token".to_string()]),
            vec![(1, "evm".to_string(), 200)],
            vec![
                "chainId".to_string(),
                "address".to_string(),
                "contractId".to_string(),
                "registrationBlock".to_string()
            ],
            vec![row(&["1", &format!("{:?}", vec![0xabu8; 20]), "0", "-1"])],
        )
    );
}

#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_load_reads_each_entitys_latest_row() {
    let live = Live::new(true);
    let account = live.account();
    initialize(&live, vec![account.clone()], vec![chain(1)]).await;
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

/// A write that never got to its chains' row is invisible, and a resume
/// removes it.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_resume_trims_what_an_uncommitted_write_left_behind() {
    let live = Live::new(true);
    let account = live.account();
    initialize(&live, vec![account.clone()], vec![chain(1)]).await;
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
    // The rows of checkpoint 2 land, but its chains row never does: the
    // write is cut off, as a crash would.
    let uncommitted = Live {
        storage: Storage::new(
            Connection {
                url: env("ENVIO_CLICKHOUSE_HOST", "http://localhost:8123"),
                username: env("ENVIO_CLICKHOUSE_USERNAME", "default"),
                password: std::env::var("ENVIO_CLICKHOUSE_PASSWORD")
                    .unwrap_or_else(|_| "testing".to_string()),
                database: live.database.clone(),
            },
            Tuning::default(),
            Arc::new(|_: &str| {}),
            Settings {
                chain_id_mode: ChainIdMode::Int32,
                replicated: false,
                database_engine: None,
                primary: true,
            },
        )
        .unwrap(),
        database: live.database.clone(),
    };
    let mut cut_off = batch(
        &account,
        &[("a", Some(("alice", "2")), 2)],
        &[(2, 1, 20)],
        (1, 2),
    );
    // Nothing the uncommitted writer knows of to commit to: it never loaded
    // the chains, so it writes the rows and no chain row.
    cut_off.progress.clear();
    cut_off.frontier = Frontier::default();
    write(&uncommitted, cut_off).await;

    let before = live
        .storage
        .load_where(&account, vec![eq("id", "a")])
        .await
        .unwrap();
    let resumed = live
        .storage
        .resume(&Resume {
            sequence: Sequence::SharedAcrossChains,
            tables: vec![account.clone()],
            chain_ids: vec![1],
            committed: None,
        })
        .await
        .unwrap();
    let (history, checkpoints) = (
        live.count("envio_history_Account").await,
        live.count("envio_checkpoints").await,
    );
    live.drop_database().await;
    assert_eq!(
        (
            rows(&before),
            resumed
                .chains
                .iter()
                .map(|chain| (chain.checkpoint_id, chain.progress_block))
                .collect::<Vec<_>>(),
            history,
            checkpoints
        ),
        (
            vec![row(&["a", "alice", "1"])],
            vec![(1, 10)],
            "1".to_string(),
            "1".to_string()
        )
    );
}

/// A rollback reads what each entity held at the target, and once its diff
/// is written the orphaned checkpoints no longer count: not as a target, not
/// in the progress the next rollback recomputes.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_rollback_restores_the_target_and_orphans_what_came_after() {
    let live = Live::new(true);
    let account = live.account();
    initialize(&live, vec![account.clone()], vec![chain(1)]).await;
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

    let bounds = Bounds {
        sequence: Sequence::SharedAcrossChains,
        chain_ids: vec![1],
        checkpoint_ids: vec![1],
    };
    let target = live
        .storage
        .rollback_target_checkpoint(1, 15)
        .await
        .unwrap();
    let diff = live.storage.rollback_progress_diff(&bounds).await.unwrap();
    let (removed, restored) = live.storage.rollback_data(&account, &bounds).await.unwrap();

    // The diff: `a` back to what checkpoint 1 wrote, `c` gone, both stamped
    // with checkpoint 4, which marks 2 and 3 as rolled back.
    let mut rollback = batch(
        &account,
        &[("a", Some(("alice", "1")), 4), ("c", None, 4)],
        &[],
        (1, 4),
    );
    rollback.progress.clear();
    rollback.rollback = Some(RollbackWrite {
        bounds: bounds.clone(),
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

    let after = live
        .storage
        .load_where(&account, vec![eq("owner", "carol")])
        .await
        .unwrap();
    let target_after = live
        .storage
        .rollback_target_checkpoint(1, 25)
        .await
        .unwrap();
    let diff_after = live.storage.rollback_progress_diff(&bounds).await.unwrap();
    live.drop_database().await;
    assert_eq!(
        (
            target,
            diff.iter()
                .map(|diff| (diff.chain_id, diff.events_processed, diff.progress_block))
                .collect::<Vec<_>>(),
            rows(&removed),
            rows(&restored),
            rows(&after),
            target_after,
            diff_after.len(),
        ),
        (
            Some(1),
            vec![(1, 2, 19)],
            vec![row(&["c"])],
            vec![row(&["a", "alice", "1", "SET"])],
            Vec::<Vec<String>>::new(),
            // Checkpoint 2 (block 20) was orphaned, so the latest standing one
            // at or below block 25 is still 1.
            Some(1),
            0,
        )
    );
}

#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn addresses_follow_registrations_and_the_rollbacks_that_drop_them() {
    let live = Live::new(true);
    let account = live.account();
    initialize(&live, vec![account.clone()], vec![chain(1)]).await;
    let mut registering = batch(&account, &[], &[(1, 1, 10)], (1, 1));
    registering.entities.clear();
    registering.addresses = Addresses {
        chain_ids: vec![1, 1],
        addresses: vec![vec![1; 20], vec![2; 20]],
        contract_ids: vec![0, 0],
        registration_blocks: vec![10, 10],
        checkpoint_ids: vec![1, 1],
    };
    write(&live, registering).await;
    let mut dropping = batch(&account, &[], &[], (1, 2));
    dropping.entities.clear();
    dropping.rollback = Some(RollbackWrite {
        bounds: Bounds {
            sequence: Sequence::SharedAcrossChains,
            chain_ids: vec![1],
            checkpoint_ids: vec![0],
        },
        tables: vec![account.clone()],
        progress: Vec::new(),
        removed_addresses: Addresses {
            chain_ids: vec![1],
            addresses: vec![vec![2; 20]],
            contract_ids: vec![0],
            registration_blocks: Vec::new(),
            checkpoint_ids: Vec::new(),
        },
        diff_checkpoints: vec![DiffCheckpoint {
            chain_id: 1,
            checkpoint_id: 2,
            block_number: 5,
        }],
    });
    write(&live, dropping).await;

    let resumed = live
        .storage
        .resume(&Resume {
            sequence: Sequence::SharedAcrossChains,
            tables: vec![account],
            chain_ids: vec![1],
            committed: None,
        })
        .await
        .unwrap();
    live.drop_database().await;
    assert_eq!(
        sorted(rows(&resumed.addresses)),
        vec![
            row(&["1", &format!("{:?}", vec![1u8; 20]), "0", "10"]),
            row(&["1", &format!("{:?}", vec![0xabu8; 20]), "0", "-1"]),
        ]
    );
}

#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn chain_state_survives_a_restart() {
    let live = Live::new(true);
    let account = live.account();
    initialize(&live, vec![account.clone()], vec![chain(1), chain(137)]).await;
    let mut progressed = batch(
        &account,
        &[("a", Some(("alice", "1")), 1)],
        &[(1, 1, 10)],
        (1, 1),
    );
    progressed.chain_meta = vec![ChainMeta {
        chain_id: 1,
        first_event_block: Some(10),
        buffer_block: 50,
        ready_at: None,
        is_hyper_sync: true,
    }];
    write(&live, progressed).await;
    live.storage
        .finalize_backfill(Vec::new(), &[1], 1_700_000_000_123.0)
        .await
        .unwrap();

    let resumed = live
        .storage
        .resume(&Resume {
            sequence: Sequence::SharedAcrossChains,
            tables: vec![account],
            chain_ids: vec![1],
            committed: None,
        })
        .await
        .unwrap();
    live.drop_database().await;
    assert_eq!(
        resumed
            .chains
            .iter()
            .map(|chain| (
                chain.id,
                chain.checkpoint_id,
                chain.progress_block,
                chain.progress_block_time,
                chain.first_event_block,
                chain.ready_at,
                chain.events_processed,
            ))
            .collect::<Vec<_>>(),
        vec![
            (
                1,
                1,
                10,
                Some(1_700_000_000.0),
                Some(10),
                Some(1_700_000_000_123.0),
                1.0
            ),
            (137, 0, -1, None, None, None, 0.0),
        ]
    );
}

#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn an_effect_cache_round_trips_through_its_file() {
    let live = Live::new(true);
    let account = live.account();
    initialize(&live, vec![account.clone()], vec![chain(1)]).await;
    let cache = live.table(ClickHouseTableInput {
        kind: ClickHouseTableKind::EffectCache,
        history_table: None,
        ..entity_input(
            "envio_effect_price",
            vec![column("id", "String"), column("output", "Json")],
        )
    });
    let mut arena = Arena::new(2, &[ColumnKind::Text, ColumnKind::Text]).unwrap();
    arena.set_bytes(0, 0, b"k1");
    arena.set_bytes(1, 0, br#"{"price":"1\t2"}"#);
    arena.set_bytes(0, 1, b"k2");
    arena.set_bytes(1, 1, b"null");
    arena
        .seal_unlent(&["id", "output"].map(str::to_string))
        .unwrap();
    let mut cached = batch(&account, &[], &[], (1, 1));
    cached.entities.clear();
    cached.effect_caches = vec![EffectCacheWrite {
        table: cache.clone(),
        create: true,
        rows: Rows::Staged(arena),
    }];
    write(&live, cached).await;

    let directory = std::env::temp_dir().join(&live.database);
    let path = directory.join("price.tsv").to_string_lossy().to_string();
    let tables = live.storage.effect_cache_tables().await.unwrap();
    live.storage
        .dump_effect_cache(&[CacheDump {
            table_name: "envio_effect_price".to_string(),
            path: path.clone(),
        }])
        .await
        .unwrap();
    // Start over and load the cache back from the file.
    initialize(&live, vec![account], vec![chain(1)]).await;
    live.storage
        .upload_effect_cache(&[CacheFile {
            table: cache.clone(),
            path: path.clone(),
        }])
        .await
        .unwrap();
    let loaded = live
        .storage
        .load_where(&cache, vec![eq("id", "k1")])
        .await
        .unwrap();
    live.drop_database().await;
    let _ = std::fs::remove_dir_all(directory);
    assert_eq!(
        (
            tables
                .iter()
                .map(|table| (table.table_name.clone(), table.rows))
                .collect::<Vec<_>>(),
            rows(&loaded),
        ),
        (
            vec![("envio_effect_price".to_string(), 2)],
            vec![row(&["k1", r#"{"price":"1\t2"}"#])],
        )
    );
}

/// Following Postgres, ClickHouse trims back to what Postgres committed,
/// whatever its own chains' rows say.
#[tokio::test]
#[ignore = "needs a ClickHouse server"]
async fn a_follower_resumes_to_what_the_store_of_record_committed() {
    let live = Live::new(false);
    let account = live.account();
    initialize(&live, vec![account.clone()], vec![chain(1)]).await;
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

    live.storage
        .resume(&Resume {
            sequence: Sequence::SharedAcrossChains,
            tables: vec![account.clone()],
            chain_ids: vec![1],
            committed: Some(vec![crate::storage::types::ResumedChain {
                id: 1,
                ecosystem: "evm".to_string(),
                start_block: 0,
                end_block: None,
                max_reorg_depth: 200,
                first_event_block: None,
                ready_at: None,
                events_processed: 1.0,
                progress_block: 10,
                progress_block_time: None,
                source_block: 1000,
                checkpoint_id: 1,
            }]),
        })
        .await
        .unwrap();
    let loaded = live
        .storage
        .load_where(&account, vec![eq("id", "a")])
        .await
        .unwrap();
    let history = live.count("envio_history_Account").await;
    live.drop_database().await;
    assert_eq!(
        (rows(&loaded), history),
        (vec![row(&["a", "alice", "1"])], "1".to_string())
    );
}
