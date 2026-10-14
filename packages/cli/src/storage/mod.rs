//! The indexer's storage, whichever databases hold it.
//!
//! A [`Backend`] is one database. Postgres and ClickHouse each implement it,
//! and [`Storage`] composes them: the store of record keeps the indexer's own
//! state — chains, checkpoints, addresses, the config record, effect caches —
//! and every entity lives in the stores its schema names. With both
//! configured Postgres is the store of record; ClickHouse alone is one too.
//!
//! JavaScript reaches all of it through the one class in [`js`], which does
//! only what needs the isolate: laying entity values into staged arenas and
//! reading result arenas back into objects.

pub mod rows;
pub mod types;

#[cfg_attr(test, allow(dead_code))]
mod js;

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use futures_util::future::{join_all, BoxFuture};

use crate::clickhouse;
use crate::columnar::Arena;
use crate::entity_filter::Condition;
use crate::postgres;
use crate::postgres::index_definition::IndexDefinition;
use crate::postgres::param::Param;
use rows::ResultSet;
use types::{
    Addresses, Bounds, CacheTable, ChainConfig, ChainMeta, Checkpoints, DiffCheckpoint, Frontier,
    Progress, ProgressDiff, ReorgCheckpoint, ResumedChain, Sequence, StoredConfig,
};

pub type Op<'a, T> = BoxFuture<'a, Result<T>>;

/// A table as the indexer registered it, and what each store made of it. An
/// entity lives in the stores its schema names; the indexer's own tables only
/// in the store of record.
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

/// What the stores hold before anything is initialized or resumed.
#[napi_derive::napi(string_enum)]
#[derive(Debug, PartialEq, Eq)]
pub enum Holding {
    Nothing,
    Initialized,
    /// ClickHouse holds indexed data its store of record has none of.
    Stranded,
    /// The store of record holds indexed data the ClickHouse following it
    /// doesn't.
    Diverged,
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
}

impl Handoff {
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
    pub contract_names: Vec<String>,
    pub addresses: Addresses,
}

pub struct AddChain {
    pub chain: ChainConfig,
    pub partitions: Vec<Partition>,
    pub addresses: Addresses,
}

pub struct Resume {
    pub sequence: Sequence,
    /// Every entity table, whose rows a store may have to trim back.
    pub tables: Vec<Arc<Table>>,
    /// The chains this run drives. Only their rows are trimmed: a sibling
    /// process driving another chain may be mid-write above its frontier.
    pub chain_ids: Vec<i64>,
    /// What the store of record committed, for a store that follows it: it
    /// trims back to these rather than to what it has itself.
    pub committed: Option<Vec<ResumedChain>>,
}

pub struct Resumed {
    pub chains: Vec<ResumedChain>,
    pub addresses: ResultSet,
    pub reorg_checkpoints: Vec<ReorgCheckpoint>,
}

pub struct StoredConfigRead {
    pub config: StoredConfig,
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

/// One database the indexer's storage lives in.
///
/// A store that follows another — ClickHouse beside Postgres — is only asked
/// what concerns the entities it keeps and the chains' frontier; everything
/// else is the store of record's.
pub trait Backend: Send + Sync {
    fn name(&self) -> &'static str;
    /// Refuses a database the indexer may not take over, before anything is
    /// dropped: initializing starts it from nothing.
    fn check_for_initialize(&self) -> Op<'_, ()>;
    fn initialize<'a>(&'a self, input: &'a Initialize) -> Op<'a, ()>;
    fn add_chain<'a>(&'a self, input: &'a AddChain) -> Op<'a, ()>;
    fn read_stored_config(&self) -> Op<'_, StoredConfigRead>;
    fn resume<'a>(&'a self, input: &'a Resume) -> Op<'a, Resumed>;
    fn load_where<'a>(&'a self, table: &'a Table, conditions: Vec<Condition>) -> Op<'a, ResultSet>;
    fn set_chain_meta<'a>(&'a self, chains: &'a [ChainMeta]) -> Op<'a, ()>;
    /// Builds the indexes the schema promises, then stamps `ready_at` on the
    /// chains that have caught up.
    fn finalize_backfill<'a>(
        &'a self,
        indexes: Vec<IndexDefinition>,
        chain_ids: &'a [i64],
        ready_at: f64,
    ) -> Op<'a, ()>;
    fn prune_checkpoints<'a>(&'a self, bounds: &'a Bounds) -> Op<'a, ()>;
    fn prune_history<'a>(&'a self, table: &'a Table, bounds: &'a Bounds) -> Op<'a, ()>;
    fn rollback_target_checkpoint(&self, chain_id: i64, block_number: i32) -> Op<'_, Option<i64>>;
    fn rollback_progress_diff<'a>(&'a self, bounds: &'a Bounds) -> Op<'a, Vec<ProgressDiff>>;
    /// The keys a rollback removes, and the rows it restores the rest from.
    fn rollback_data<'a>(
        &'a self,
        table: &'a Table,
        bounds: &'a Bounds,
    ) -> Op<'a, (ResultSet, ResultSet)>;
    fn effect_cache_tables(&self) -> Op<'_, Vec<CacheTable>>;
    fn upload_effect_cache<'a>(&'a self, files: &'a [CacheFile]) -> Op<'a, ()>;
    fn dump_effect_cache<'a>(&'a self, files: &'a [CacheDump]) -> Op<'a, ()>;
    fn reset(&self) -> Op<'_, ()>;
    fn write_batch(
        &self,
        batch: Batch,
        handoff: Handoff,
    ) -> BoxFuture<'_, std::result::Result<(), WriteError>>;
    fn close(&self);
}

/// The stores the indexer writes to, and which of them answers what.
pub struct Storage {
    pub postgres: Option<Arc<postgres::storage::Storage>>,
    pub clickhouse: Option<Arc<clickhouse::storage::Storage>>,
}

impl Storage {
    /// The store of record.
    pub fn primary(&self) -> &dyn Backend {
        match (&self.postgres, &self.clickhouse) {
            (Some(postgres), _) => postgres.as_ref(),
            (None, Some(clickhouse)) => clickhouse.as_ref(),
            (None, None) => unreachable!("a storage is built with at least one store"),
        }
    }

    /// The store following the store of record, if one does.
    fn follower(&self) -> Option<&dyn Backend> {
        match (&self.postgres, &self.clickhouse) {
            (Some(_), Some(clickhouse)) => Some(clickhouse.as_ref()),
            _ => None,
        }
    }

    fn all(&self) -> impl Iterator<Item = &dyn Backend> {
        std::iter::once(self.primary()).chain(self.follower())
    }

    /// The store an entity is read from: Postgres where it keeps one,
    /// ClickHouse otherwise.
    pub fn home(&self, table: &Table) -> Result<&dyn Backend> {
        match (
            &self.postgres,
            &table.postgres,
            &self.clickhouse,
            &table.clickhouse,
        ) {
            (Some(postgres), Some(_), _, _) => Ok(postgres.as_ref()),
            (_, _, Some(clickhouse), Some(_)) => Ok(clickhouse.as_ref()),
            _ => Err(anyhow!("\"{}\" is kept in no configured store", table.name)),
        }
    }

    pub async fn holding(&self) -> Result<Holding> {
        let record = match &self.clickhouse {
            Some(clickhouse) => clickhouse.record().await?,
            None => None,
        };
        let Some(postgres) = &self.postgres else {
            return Ok(match record {
                Some(clickhouse::storage::Record {
                    follower: false, ..
                }) => Holding::Initialized,
                Some(_) => Holding::Stranded,
                None => Holding::Nothing,
            });
        };
        if !postgres.is_initialized().await? {
            return Ok(match record {
                Some(_) => Holding::Stranded,
                None => Holding::Nothing,
            });
        }
        if self.clickhouse.is_none() {
            return Ok(Holding::Initialized);
        }
        // A schema an older envio built keeps no record: resuming refuses it
        // on its own.
        let Some(stored) = postgres.read_stored_config().await?.config.envio_info else {
            return Ok(Holding::Initialized);
        };
        Ok(match record {
            Some(clickhouse::storage::Record {
                follower: true,
                envio_info,
            }) if envio_info == stored => Holding::Initialized,
            _ => Holding::Diverged,
        })
    }

    /// Every store starts from nothing. Each one is checked before any is
    /// touched, so a refusal leaves them all as they were.
    ///
    /// The store of record first, here and wherever the stores change apart
    /// from a batch: a follower that fails behind it is brought back to what
    /// it committed by the next resume — or refuses it, missing a table. The
    /// other way round, a store of record that fails keeps its old state, and
    /// a follower emptied under it would resume as if it held that state too.
    pub async fn initialize(&self, input: Initialize) -> Result<()> {
        for backend in self.all() {
            backend.check_for_initialize().await?;
        }
        self.primary().initialize(&input).await?;
        match self.follower() {
            Some(follower) => follower.initialize(&input).await,
            None => Ok(()),
        }
    }

    pub async fn add_chain(&self, input: AddChain) -> Result<()> {
        self.primary().add_chain(&input).await?;
        match self.follower() {
            Some(follower) => follower.add_chain(&input).await,
            None => Ok(()),
        }
    }

    pub async fn read_stored_config(&self) -> Result<StoredConfigRead> {
        self.primary().read_stored_config().await
    }

    /// Resumes the store of record, and then the follower to what it
    /// committed: a batch the follower wrote but the store of record never
    /// did is trimmed away.
    pub async fn resume(
        &self,
        sequence: Sequence,
        tables: Vec<Arc<Table>>,
        chain_ids: Vec<i64>,
    ) -> Result<Resumed> {
        let resumed = self
            .primary()
            .resume(&Resume {
                sequence,
                tables: tables.clone(),
                chain_ids: chain_ids.clone(),
                committed: None,
            })
            .await?;
        if let Some(follower) = self.follower() {
            follower
                .resume(&Resume {
                    sequence,
                    tables,
                    committed: Some(
                        resumed
                            .chains
                            .iter()
                            .filter(|chain| chain_ids.contains(&chain.id))
                            .cloned()
                            .collect(),
                    ),
                    chain_ids,
                })
                .await?;
        }
        Ok(resumed)
    }

    pub async fn load_where(&self, table: &Table, conditions: Vec<Condition>) -> Result<ResultSet> {
        self.home(table)?.load_where(table, conditions).await
    }

    pub async fn set_chain_meta(&self, chains: &[ChainMeta]) -> Result<()> {
        join_all(self.all().map(|backend| backend.set_chain_meta(chains)))
            .await
            .into_iter()
            .collect()
    }

    pub async fn finalize_backfill(
        &self,
        indexes: Vec<IndexDefinition>,
        chain_ids: &[i64],
        ready_at: f64,
    ) -> Result<()> {
        // The follower is only ready once the indexes the store of record
        // promised are built.
        self.primary()
            .finalize_backfill(indexes, chain_ids, ready_at)
            .await?;
        match self.follower() {
            Some(follower) => {
                follower
                    .finalize_backfill(Vec::new(), chain_ids, ready_at)
                    .await
            }
            None => Ok(()),
        }
    }

    pub async fn prune_checkpoints(&self, bounds: &Bounds) -> Result<()> {
        join_all(self.all().map(|backend| backend.prune_checkpoints(bounds)))
            .await
            .into_iter()
            .collect()
    }

    pub async fn prune_history(&self, table: &Table, bounds: &Bounds) -> Result<()> {
        self.home(table)?.prune_history(table, bounds).await
    }

    pub async fn rollback_target_checkpoint(
        &self,
        chain_id: i64,
        block_number: i32,
    ) -> Result<Option<i64>> {
        self.primary()
            .rollback_target_checkpoint(chain_id, block_number)
            .await
    }

    pub async fn rollback_progress_diff(&self, bounds: &Bounds) -> Result<Vec<ProgressDiff>> {
        self.primary().rollback_progress_diff(bounds).await
    }

    pub async fn rollback_data(
        &self,
        table: &Table,
        bounds: &Bounds,
    ) -> Result<(ResultSet, ResultSet)> {
        self.home(table)?.rollback_data(table, bounds).await
    }

    pub async fn effect_cache_tables(&self) -> Result<Vec<CacheTable>> {
        self.primary().effect_cache_tables().await
    }

    pub async fn upload_effect_cache(&self, files: &[CacheFile]) -> Result<()> {
        self.primary().upload_effect_cache(files).await
    }

    pub async fn dump_effect_cache(&self, files: &[CacheDump]) -> Result<()> {
        self.primary().dump_effect_cache(files).await
    }

    pub async fn reset(&self) -> Result<()> {
        join_all(self.all().map(Backend::reset))
            .await
            .into_iter()
            .collect()
    }

    /// Writes a batch to every store, and says how long each took. A follower
    /// writes its half first and the store of record commits only once it
    /// has: a batch either reaches both, or the store of record never commits
    /// it and a restart trims the follower back.
    pub async fn write_batch(
        &self,
        batch: Batch,
    ) -> std::result::Result<Vec<(&'static str, f64)>, Failure> {
        let primary = self.primary();
        let Some(follower) = self.follower() else {
            let started = Instant::now();
            return match primary.write_batch(batch, Handoff::default()).await {
                Ok(()) => Ok(vec![(primary.name(), started.elapsed().as_secs_f64())]),
                Err(WriteError::Failed(failure)) => Err(failure),
                Err(WriteError::Gated) => unreachable!("a write with no gate is never gated"),
            };
        };
        let (primary_batch, follower_batch) = split(batch);
        // The store of record commits once the follower's rows have landed,
        // and the follower makes them readable once the store of record has
        // committed: neither holds a batch the other refused, and nothing
        // reads one before it is the store of record's.
        let (landed, follower_landed) = tokio::sync::oneshot::channel();
        let (committed, primary_committed) = tokio::sync::oneshot::channel();
        let (primary_gate, primary_waited) = waited_on(follower_landed);
        let (follower_gate, follower_waited) = waited_on(primary_committed);
        let started = Instant::now();
        let own_seconds = |waited: &AtomicU64| {
            (started.elapsed() - Duration::from_nanos(waited.load(Ordering::Relaxed))).as_secs_f64()
        };
        let follower_write = async {
            follower
                .write_batch(
                    follower_batch,
                    Handoff {
                        landed: Some(landed),
                        commit: Some(follower_gate),
                    },
                )
                .await
                .map(|()| own_seconds(&follower_waited))
        };
        let primary_write = async {
            let outcome = primary
                .write_batch(
                    primary_batch,
                    Handoff {
                        landed: None,
                        commit: Some(primary_gate),
                    },
                )
                .await;
            let _ = committed.send(outcome.is_ok());
            outcome.map(|()| own_seconds(&primary_waited))
        };
        let (follower_outcome, primary_outcome) = tokio::join!(follower_write, primary_write);
        // A store told not to commit was told so because the other failed,
        // and that failure is the one reported.
        match (follower_outcome, primary_outcome) {
            (Err(WriteError::Failed(follower)), Err(WriteError::Failed(primary))) => {
                Err(Failure::new(
                    "Both stores failed writing the batch",
                    anyhow!(
                        "{}: {}\n{}: {}",
                        follower.context,
                        postgres::error::message_of(&follower.error),
                        primary.context,
                        postgres::error::message_of(&primary.error)
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
            (Ok(follower_seconds), Ok(primary_seconds)) => Ok(vec![
                (follower.name(), follower_seconds),
                (primary.name(), primary_seconds),
            ]),
        }
    }

    pub fn close(&self) {
        for backend in self.all() {
            backend.close();
        }
    }
}

/// Splits a batch between the store of record and its follower. Everything
/// about the chains goes to both; an entity's rows go to the stores it lives
/// in, and the indexer's own tables to the store of record alone.
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
    let mut primary_entities = Vec::with_capacity(entities.len());
    let mut follower_entities = Vec::with_capacity(entities.len());
    for write in entities {
        let EntityWrite {
            table,
            chain_id,
            postgres,
            clickhouse,
        } = write;
        if postgres.is_some() {
            primary_entities.push(EntityWrite {
                table: table.clone(),
                chain_id,
                postgres,
                clickhouse: None,
            });
        }
        if clickhouse.is_some() {
            follower_entities.push(EntityWrite {
                table,
                chain_id,
                postgres: None,
                clickhouse,
            });
        }
    }
    let follower = Batch {
        rollback: rollback.clone(),
        progress: progress.clone(),
        raw_events: None,
        entities: follower_entities,
        chain_meta: chain_meta.clone(),
        addresses: Addresses::default(),
        frontier: frontier.clone(),
        checkpoints: checkpoints.clone(),
        effect_caches: Vec::new(),
    };
    let primary = Batch {
        rollback,
        progress,
        raw_events,
        entities: primary_entities,
        chain_meta,
        addresses,
        frontier,
        checkpoints,
        effect_caches,
    };
    (primary, follower)
}
