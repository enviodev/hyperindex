//! The indexer's storage.
//!
//! Postgres keeps the indexer's own state — chains, checkpoints, addresses,
//! the config record, effect caches, raw events — and the entities configured
//! for it. ClickHouse, when configured, keeps the entities configured for it,
//! and makes a batch readable only once Postgres has committed it. Handlers
//! read an entity from the store that keeps it: Postgres, where both do.
//!
//! JavaScript reaches all of it through the one class in [`js`], which does
//! only what needs the isolate: laying entity values into staged arenas and
//! reading result arenas back into objects.

pub mod rows;
pub mod types;

#[cfg_attr(test, allow(dead_code))]
mod js;
#[cfg(test)]
mod live_tests;

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context, Result};
use futures_util::future::BoxFuture;
use tokio::io::AsyncWriteExt;

use crate::clickhouse;
use crate::columnar::Arena;
use crate::entity_filter::Condition;
use crate::postgres;
use crate::postgres::param::Param;
use rows::ResultSet;
use types::{
    Addresses, Bounds, ChainConfig, ChainMeta, Checkpoints, DiffCheckpoint, Frontier, Progress,
    ResumedChain, Sequence,
};

pub type Op<'a, T> = BoxFuture<'a, Result<T>>;

/// A table as the indexer registered it, and what each store made of it. An
/// entity lives in the stores its schema names; the indexer's own tables only
/// in Postgres.
pub struct Table {
    pub name: String,
    pub postgres: Option<Arc<postgres::storage::Table>>,
    pub clickhouse: Option<Arc<clickhouse::table::Table>>,
}

impl Table {
    pub fn postgres(&self) -> Result<&Arc<postgres::storage::Table>> {
        self.postgres
            .as_ref()
            .ok_or_else(|| anyhow!("\"{}\" is not stored in Postgres", self.name))
    }

    pub fn clickhouse(&self) -> Result<&Arc<clickhouse::table::Table>> {
        self.clickhouse
            .as_ref()
            .ok_or_else(|| anyhow!("\"{}\" is not stored in ClickHouse", self.name))
    }
}

/// Rows of a batch, as JavaScript handed them over: laid out in an arena, or
/// — for a Postgres table with a column of arrays, which an unnest would
/// spread across the rows — one rendered parameter per cell, column by column.
pub enum Rows {
    Staged(Arena),
    Cells { cells: Vec<Param>, rows: usize },
}

impl Rows {
    pub fn len(&self) -> usize {
        match self {
            Rows::Staged(arena) => arena.rows(),
            Rows::Cells { rows, .. } => *rows,
        }
    }
}

/// What a Postgres entity table takes from one write group: the current rows
/// it ends up with and the history leading to them.
pub struct PgEntityWrite {
    /// The latest value of each id the batch set.
    pub sets: Option<Rows>,
    /// The ids whose latest change is a delete.
    pub deletes: Vec<String>,
    pub history: Option<HistoryWrite>,
}

pub struct HistoryWrite {
    /// Ids whose history has to start from their current row first.
    pub backfill: Vec<String>,
    /// Every set the batch made, with the checkpoint of each.
    pub sets: Option<(Rows, Vec<String>)>,
    pub delete_ids: Vec<String>,
    pub delete_checkpoint_ids: Vec<String>,
}

/// One entity's changes within one chain scope, as each of its stores takes
/// them. ClickHouse keeps every change as a history row.
pub struct EntityWrite {
    pub table: Arc<Table>,
    /// The scope's chain, for a per-chain entity.
    pub chain_id: Option<i64>,
    pub postgres: Option<PgEntityWrite>,
    pub clickhouse: Option<Arena>,
}

pub struct TableWrite {
    pub table: Arc<Table>,
    pub rows: Rows,
}

pub struct EffectCacheWrite {
    pub table: Arc<Table>,
    /// The first write to a cache creates its table.
    pub create: bool,
    pub rows: Rows,
}

#[derive(Clone)]
pub struct RollbackWrite {
    pub bounds: Bounds,
    /// Every entity table a rollback reaches.
    pub tables: Vec<Arc<Table>>,
    /// Where the rollback left each chain it moved.
    pub progress: Vec<Progress>,
    /// Registrations the rollback dropped.
    pub removed_addresses: Addresses,
    /// The checkpoint each chain the rollback moved stamps its diff with.
    pub diff_checkpoints: Vec<DiffCheckpoint>,
}

/// What a batch writes. An empty list is nothing to write.
#[derive(Default)]
pub struct Batch {
    pub rollback: Option<RollbackWrite>,
    pub progress: Vec<Progress>,
    pub raw_events: Option<TableWrite>,
    pub entities: Vec<EntityWrite>,
    pub chain_meta: Vec<ChainMeta>,
    /// Addresses the batch registered, with the checkpoint covering each.
    pub addresses: Addresses,
    pub frontier: Frontier,
    pub checkpoints: Checkpoints,
    pub effect_caches: Vec<EffectCacheWrite>,
}

#[napi_derive::napi(string_enum)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Store {
    Postgres,
    ClickHouse,
}

/// What the stores hold before anything is initialized or resumed.
#[napi_derive::napi(string_enum)]
#[derive(Debug, PartialEq, Eq)]
pub enum Holding {
    Nothing,
    Initialized,
    /// ClickHouse holds indexed data Postgres has none of.
    Stranded,
    /// Postgres holds indexed data the ClickHouse beside it doesn't.
    Diverged,
    /// Postgres was built by an older envio, which kept no instance to pair
    /// it with the ClickHouse beside it.
    Outdated,
}

/// A failed write, and what it was doing.
#[derive(Debug)]
pub struct Failure {
    pub context: String,
    pub error: anyhow::Error,
}

impl Failure {
    pub fn new(context: impl Into<String>, error: anyhow::Error) -> Self {
        Self {
            context: context.into(),
            error,
        }
    }
}

/// Settles with whether a store may commit what it wrote.
pub type Gate = Pin<Box<dyn Future<Output = bool> + Send>>;

/// How a store's half of a batch meets the other store's: it says once its
/// rows have landed, and commits only when the other side says so.
#[derive(Default)]
pub struct Handoff {
    pub landed: Option<tokio::sync::oneshot::Sender<bool>>,
    pub commit: Option<Gate>,
    /// Told whether the store committed as soon as it knows, rather than once
    /// the rest of its write is done. Postgres reports it right at its COMMIT,
    /// which is what lets ClickHouse make the batch readable.
    pub committed: Option<tokio::sync::oneshot::Sender<bool>>,
}

impl Handoff {
    pub fn report_commit(&mut self, committed: bool) {
        if let Some(sender) = self.committed.take() {
            let _ = sender.send(committed);
        }
    }

    /// A store that fails before calling this drops `landed` unsent, which
    /// the other side reads as a no.
    pub async fn ready_to_commit(&mut self) -> bool {
        if let Some(landed) = self.landed.take() {
            let _ = landed.send(true);
        }
        match self.commit.take() {
            Some(commit) => commit.await,
            None => true,
        }
    }
}

pub enum WriteError {
    Failed(Failure),
    /// Told not to commit, so nothing here was.
    Gated,
}

impl From<Failure> for WriteError {
    fn from(failure: Failure) -> Self {
        WriteError::Failed(failure)
    }
}

pub struct Partition {
    pub table: Arc<Table>,
    pub chain_id: i64,
    pub name: String,
}

pub struct Enum {
    pub name: String,
    pub variants: Vec<String>,
}

pub struct Initialize {
    pub sequence: Sequence,
    /// Every table the indexer created up front: the entities' and the raw
    /// events'.
    pub tables: Vec<Arc<Table>>,
    pub partitions: Vec<Partition>,
    pub enums: Vec<Enum>,
    pub chains: Vec<ChainConfig>,
    pub envio_info: String,
    /// Written to both stores, so a ClickHouse database is told apart from one
    /// built beside another initialize of the same config.
    pub instance: String,
    pub contract_names: Vec<String>,
    pub addresses: Addresses,
}

/// One initialize's instance: unique to it with overwhelming odds, which is
/// all telling deployments apart needs.
pub fn new_instance() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
    hasher.write_u128(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos()),
    );
    hasher.write_u32(std::process::id());
    format!("{:016x}", hasher.finish())
}

pub struct AddChain {
    pub chain: ChainConfig,
    pub partitions: Vec<Partition>,
    pub addresses: Addresses,
}

/// What ClickHouse resumes to.
pub struct Resume {
    pub sequence: Sequence,
    /// Every entity table, whose rows ClickHouse may have to trim back.
    pub tables: Vec<Arc<Table>>,
    /// What Postgres committed for the chains this run drives. Only their rows
    /// are trimmed: a sibling process driving another chain may be mid-write
    /// above its frontier.
    pub committed: Vec<ResumedChain>,
}

pub struct Resumed {
    pub chains: Vec<ResumedChain>,
    pub addresses: ResultSet,
    pub reorg_checkpoints: Vec<types::ReorgCheckpoint>,
}

pub struct StoredConfigRead {
    pub config: types::StoredConfig,
    /// The addresses the config declared, as the stored rows hold them.
    pub config_addresses: ResultSet,
}

pub struct CacheFile {
    pub table: Arc<Table>,
    pub path: String,
}

pub struct CacheDump {
    pub table_name: String,
    pub path: String,
}

impl CacheDump {
    /// Writes the dump through a file of its own beside its path, which
    /// replaces it only once `write` has finished: a dump the server gives up on
    /// part way would otherwise leave a file holding its first rows, and the
    /// next start would load that as the cache. The name is unique per call, so
    /// two dumps of the same table cannot write into each other's.
    pub async fn replace_with(
        &self,
        write: impl AsyncFnOnce(&mut tokio::fs::File) -> Result<()>,
    ) -> Result<()> {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = &self.path;
        if let Some(directory) = std::path::Path::new(path).parent() {
            tokio::fs::create_dir_all(directory)
                .await
                .with_context(|| format!("Failed creating {}", directory.display()))?;
        }
        let partial = format!(
            "{path}.{}.{}.partial",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        let outcome = async {
            let mut file = tokio::fs::File::create(&partial)
                .await
                .with_context(|| format!("Failed creating {partial}"))?;
            write(&mut file).await?;
            file.flush().await?;
            // On disk before the rename makes it the dump: a crash right after
            // would otherwise leave the name pointing at a file still empty.
            file.sync_all().await?;
            tokio::fs::rename(&partial, path)
                .await
                .with_context(|| format!("Failed replacing {path}"))
        }
        .await;
        if outcome.is_err() {
            let _ = tokio::fs::remove_file(&partial).await;
        }
        outcome
    }
}

/// What each store does for the entities it keeps.
pub trait EntityStore: Send + Sync {
    fn store(&self) -> Store;
    fn load_where<'a>(&'a self, table: &'a Table, conditions: Vec<Condition>) -> Op<'a, ResultSet>;
    /// The keys a rollback removes, and the rows it restores the rest from.
    fn rollback_data<'a>(
        &'a self,
        table: &'a Table,
        bounds: &'a Bounds,
    ) -> Op<'a, (ResultSet, ResultSet)>;
}

/// Postgres, and the ClickHouse beside it if one is configured.
pub struct Storage {
    pub postgres: Arc<postgres::storage::Storage>,
    pub clickhouse: Option<Arc<clickhouse::storage::Storage>>,
}

impl Storage {
    /// The store an entity is read from: Postgres where it keeps one,
    /// ClickHouse otherwise.
    pub fn home(&self, table: &Table) -> Result<&dyn EntityStore> {
        match (&table.postgres, &self.clickhouse, &table.clickhouse) {
            (Some(_), _, _) => Ok(self.postgres.as_ref()),
            (None, Some(clickhouse), Some(_)) => Ok(clickhouse.as_ref()),
            _ => Err(anyhow!("\"{}\" is kept in no configured store", table.name)),
        }
    }

    pub async fn holding(&self) -> Result<Holding> {
        let built = match &self.clickhouse {
            Some(clickhouse) => clickhouse.instance().await?,
            None => None,
        };
        if !self.postgres.is_initialized().await? {
            // Paired, it is another Postgres's — perhaps still running. An
            // initialize that failed leaves one built but unpaired, and so does
            // an older envio, which paired nothing: only the batches tell its
            // data apart from none.
            let stranded = match (&self.clickhouse, &built) {
                (Some(_), Some(_)) => true,
                (Some(clickhouse), None) => clickhouse.holds_batches().await?,
                (None, _) => false,
            };
            return Ok(if stranded {
                Holding::Stranded
            } else {
                Holding::Nothing
            });
        }
        if self.clickhouse.is_none() {
            return Ok(Holding::Initialized);
        }
        Ok(match (self.postgres.instance().await?, built) {
            (Some(instance), Some(built)) if instance == built => Holding::Initialized,
            (None, _) => Holding::Outdated,
            _ => Holding::Diverged,
        })
    }

    /// Both stores start from nothing. Each is checked before either is
    /// touched, so a refusal leaves both as they were.
    ///
    /// ClickHouse's tables first: what a user writes into them — a `ttl`, an
    /// `orderBy` — only its server checks, and a table it refuses then leaves
    /// Postgres untouched. Its pairing record last, once Postgres committed:
    /// a ClickHouse built for a Postgres that then failed is left unpaired,
    /// which the next start sets up again.
    pub async fn initialize(&self, input: Initialize) -> Result<()> {
        self.postgres.check_schema_for_initialize().await?;
        if let Some(clickhouse) = &self.clickhouse {
            clickhouse.check_for_initialize().await?;
            clickhouse.build(&input).await?;
        }
        self.postgres.initialize(&input).await?;
        match &self.clickhouse {
            Some(clickhouse) => clickhouse.seal(&input).await,
            None => Ok(()),
        }
    }

    /// Postgres keeps only the checkpoints anchoring its history, and a
    /// rollback below all of them lands on 0, where its backfill holds what
    /// came before. ClickHouse rows carry every batch's checkpoint, so there it
    /// lands on the last batch below the fork instead: 0 would revert what was
    /// written before the reorg threshold, which is never indexed again.
    pub async fn rollback_target_checkpoint(
        &self,
        chain_id: i64,
        block_number: i32,
    ) -> Result<Option<i64>> {
        let target = self
            .postgres
            .rollback_target_checkpoint(chain_id, block_number)
            .await?;
        match (target, &self.clickhouse) {
            (None, Some(clickhouse)) => {
                clickhouse
                    .rollback_target_checkpoint(chain_id, block_number)
                    .await
            }
            (target, _) => Ok(target),
        }
    }

    /// Resumes Postgres, and then ClickHouse to what Postgres committed: a
    /// batch ClickHouse landed but Postgres never committed is trimmed away.
    pub async fn resume(
        &self,
        sequence: Sequence,
        tables: Vec<Arc<Table>>,
        chain_ids: Vec<i64>,
    ) -> Result<Resumed> {
        let resumed = self.postgres.resume().await?;
        if let Some(clickhouse) = &self.clickhouse {
            clickhouse
                .resume(&Resume {
                    sequence,
                    tables,
                    committed: resumed
                        .chains
                        .iter()
                        .filter(|chain| chain_ids.contains(&chain.id))
                        .cloned()
                        .collect(),
                })
                .await?;
        }
        Ok(resumed)
    }

    pub async fn load_where(&self, table: &Table, conditions: Vec<Condition>) -> Result<ResultSet> {
        self.home(table)?.load_where(table, conditions).await
    }

    pub async fn rollback_data(
        &self,
        table: &Table,
        bounds: &Bounds,
    ) -> Result<(ResultSet, ResultSet)> {
        self.home(table)?.rollback_data(table, bounds).await
    }

    /// ClickHouse first, and it refuses a database it may not empty before
    /// Postgres is touched. Failing after it, Postgres keeps data ClickHouse
    /// no longer holds, which the next start refuses until a reset finishes.
    pub async fn reset(&self) -> Result<()> {
        if let Some(clickhouse) = &self.clickhouse {
            clickhouse.reset().await?;
        }
        self.postgres.reset().await
    }

    /// Writes a batch to every store, and says how long each took. ClickHouse
    /// lands its half first and Postgres commits only once it has: a batch
    /// either reaches both, or Postgres never commits it and a restart trims
    /// ClickHouse back. Past Postgres's COMMIT, ClickHouse can still fail to
    /// move its frontier: the batch is reported failed though Postgres holds
    /// it, and only a restart, raising the frontier to what Postgres
    /// committed, makes its rows readable. So a failed write is never retried
    /// by the process that made it.
    pub async fn write_batch(
        &self,
        batch: Batch,
    ) -> std::result::Result<Vec<(Store, f64)>, Failure> {
        let Some(clickhouse) = &self.clickhouse else {
            let started = Instant::now();
            return match self.postgres.write_batch(batch, Handoff::default()).await {
                Ok(()) => Ok(vec![(Store::Postgres, started.elapsed().as_secs_f64())]),
                Err(WriteError::Failed(failure)) => Err(failure),
                Err(WriteError::Gated) => unreachable!("a write with no gate is never gated"),
            };
        };
        let (postgres_batch, clickhouse_batch) = split(batch);
        // Postgres commits once ClickHouse's rows have landed, and ClickHouse
        // makes them readable once Postgres has committed: neither holds a
        // batch the other refused, and nothing reads one before Postgres has
        // it.
        let (landed, clickhouse_landed) = tokio::sync::oneshot::channel();
        let (committed, postgres_committed) = tokio::sync::oneshot::channel();
        let (postgres_gate, postgres_waited) = waited_on(clickhouse_landed);
        let (clickhouse_gate, clickhouse_waited) = waited_on(postgres_committed);
        let started = Instant::now();
        let own_seconds = |waited: &AtomicU64| {
            (started.elapsed() - Duration::from_nanos(waited.load(Ordering::Relaxed))).as_secs_f64()
        };
        let clickhouse_write = async {
            clickhouse
                .write_batch(
                    clickhouse_batch,
                    Handoff {
                        landed: Some(landed),
                        commit: Some(clickhouse_gate),
                        committed: None,
                    },
                )
                .await
                .map(|()| own_seconds(&clickhouse_waited))
        };
        let postgres_write = async {
            self.postgres
                .write_batch(
                    postgres_batch,
                    Handoff {
                        landed: None,
                        commit: Some(postgres_gate),
                        committed: Some(committed),
                    },
                )
                .await
                .map(|()| own_seconds(&postgres_waited))
        };
        let (clickhouse_outcome, postgres_outcome) = tokio::join!(clickhouse_write, postgres_write);
        // A store told not to commit was told so because the other failed,
        // and that failure is the one reported.
        match (clickhouse_outcome, postgres_outcome) {
            (Err(WriteError::Failed(on_clickhouse)), Err(WriteError::Failed(on_postgres))) => {
                Err(Failure::new(
                    "Both stores failed writing the batch",
                    anyhow!(
                        "{}: {}\n{}: {}",
                        on_clickhouse.context,
                        postgres::error::message_of(&on_clickhouse.error),
                        on_postgres.context,
                        postgres::error::message_of(&on_postgres.error)
                    ),
                ))
            }
            (Err(WriteError::Failed(failure)), _) | (_, Err(WriteError::Failed(failure))) => {
                Err(failure)
            }
            (Err(WriteError::Gated), _) | (_, Err(WriteError::Gated)) => Err(Failure::new(
                "Failed writing the batch",
                anyhow!("a store refused its half of the batch"),
            )),
            (Ok(clickhouse_seconds), Ok(postgres_seconds)) => Ok(vec![
                (Store::ClickHouse, clickhouse_seconds),
                (Store::Postgres, postgres_seconds),
            ]),
        }
    }

    pub fn close(&self) {
        self.postgres.client.close();
    }
}

/// A gate on the other store's word, and how long a store spent waiting on
/// it: that time is the other store's, not the waiting one's. No word, its
/// sender dropped, is a no.
fn waited_on(word: tokio::sync::oneshot::Receiver<bool>) -> (Gate, Arc<AtomicU64>) {
    let waited = Arc::new(AtomicU64::new(0));
    let gate: Gate = Box::pin({
        let waited = waited.clone();
        async move {
            let started = Instant::now();
            let go = word.await.unwrap_or(false);
            waited.store(started.elapsed().as_nanos() as u64, Ordering::Relaxed);
            go
        }
    });
    (gate, waited)
}

/// Splits a batch between Postgres and ClickHouse. ClickHouse takes the rows
/// of the entities it keeps, the checkpoints mapping them to blocks — a
/// rollback's included — and the frontier making them readable. Everything
/// else is Postgres's alone.
fn split(batch: Batch) -> (Batch, Batch) {
    let Batch {
        rollback,
        progress,
        raw_events,
        entities,
        chain_meta,
        addresses,
        frontier,
        checkpoints,
        effect_caches,
    } = batch;
    let mut postgres_entities = Vec::with_capacity(entities.len());
    let mut clickhouse_entities = Vec::with_capacity(entities.len());
    for write in entities {
        let EntityWrite {
            table,
            chain_id,
            postgres,
            clickhouse,
        } = write;
        if postgres.is_some() {
            postgres_entities.push(EntityWrite {
                table: table.clone(),
                chain_id,
                postgres,
                clickhouse: None,
            });
        }
        if clickhouse.is_some() {
            clickhouse_entities.push(EntityWrite {
                table,
                chain_id,
                postgres: None,
                clickhouse,
            });
        }
    }
    let clickhouse = Batch {
        rollback: rollback.clone(),
        entities: clickhouse_entities,
        frontier: frontier.clone(),
        checkpoints: checkpoints.clone(),
        ..Batch::default()
    };
    let postgres = Batch {
        rollback,
        progress,
        raw_events,
        entities: postgres_entities,
        chain_meta,
        addresses,
        frontier,
        checkpoints,
        effect_caches,
    };
    (postgres, clickhouse)
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[tokio::test]
    async fn a_dump_that_fails_part_way_leaves_the_file_it_would_replace() {
        let directory = tempdir::TempDir::new("envio-dump").unwrap();
        let path = directory.path().join("price.tsv");
        std::fs::write(&path, "id\toutput\nk1\t1\n").unwrap();
        let dump = CacheDump {
            table_name: "envio_effect_price".to_string(),
            path: path.to_string_lossy().into_owned(),
        };

        let outcome = dump
            .replace_with(async |file| {
                file.write_all(b"id\toutput\n").await?;
                Err(anyhow!("the answer broke off"))
            })
            .await;

        assert_eq!(
            (
                outcome.map_err(|error| error.to_string()),
                std::fs::read_to_string(&path).unwrap(),
                std::fs::read_dir(directory.path()).unwrap().count(),
            ),
            (
                Err("the answer broke off".to_string()),
                "id\toutput\nk1\t1\n".to_string(),
                1
            )
        );
    }
}
