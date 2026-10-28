//! Every configured store, kept in step. Postgres is the store of record: it
//! holds the indexer's own state and every entity the schema puts there.
//! ClickHouse, when configured, keeps the entities the schema puts there and
//! follows what Postgres commits.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};

use super::batch::Batch;
use super::handoff::{Failure, Gate, Handoff, WriteError};
use super::rows::ResultSet;
use super::schema::{Entity, Schema};
use super::types::{Bounds, CacheTable, ChainMeta, ProgressDiff, Sequence};
use super::{
    AddChain, CacheDump, CacheFile, Holding, Initialize, Resume, Resumed, Store, StoredConfigRead,
};
use crate::clickhouse;
use crate::entity_filter::Condition;
use crate::postgres;
use crate::postgres::indexes::{Coverage, Purpose};

pub struct Storage {
    pub schema: Arc<Schema>,
    pub postgres: Arc<postgres::storage::Storage>,
    pub clickhouse: Option<Arc<clickhouse::storage::Storage>>,
}

/// The rows a rollback reads for one entity: the keys it removes, and the
/// rows it restores the rest from.
pub struct RollbackData {
    pub removed: ResultSet,
    pub restored: ResultSet,
}

/// One initialize's instance, written to both stores so a ClickHouse database
/// is told apart from one built beside another initialize of the same config.
/// Unique to it with overwhelming odds, which is all telling deployments apart
/// needs.
fn new_instance() -> String {
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

impl Storage {
    /// The store an entity is read from: Postgres where it keeps one,
    /// ClickHouse otherwise.
    pub fn home(&self, entity: &Entity) -> Result<Store> {
        match (entity.postgres, &entity.clickhouse, &self.clickhouse) {
            (true, _, _) => Ok(Store::Postgres),
            (false, Some(_), Some(_)) => Ok(Store::ClickHouse),
            _ => Err(anyhow!(
                "\"{}\" is kept in no configured store",
                entity.name
            )),
        }
    }

    fn clickhouse(&self) -> Result<&Arc<clickhouse::storage::Storage>> {
        self.clickhouse
            .as_ref()
            .ok_or_else(|| anyhow!("No ClickHouse is configured"))
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
        let is_empty_schema = self.postgres.check_schema_for_initialize().await?;
        if let Some(clickhouse) = &self.clickhouse {
            clickhouse.check_for_initialize().await?;
            clickhouse.build(&input).await?;
        }
        let instance = new_instance();
        self.postgres
            .initialize(&input, &instance, is_empty_schema)
            .await?;
        match &self.clickhouse {
            Some(clickhouse) => clickhouse.seal(&instance).await,
            None => Ok(()),
        }
    }

    pub async fn add_chain(&self, input: AddChain) -> Result<()> {
        self.postgres.add_chain(&input).await
    }

    pub async fn read_stored_config(&self) -> Result<StoredConfigRead> {
        self.postgres.read_stored_config().await
    }

    /// Postgres keeps only the checkpoints anchoring its history, and a
    /// rollback below all of them lands on 0, where its backfill holds what
    /// came before. ClickHouse rows carry every batch's checkpoint, and 0
    /// would revert the batches before the reorg threshold, which no chain's
    /// progress is rewound to redo: the rollback only replays what Postgres
    /// keeps. So with ClickHouse it lands on the last checkpoint below those
    /// Postgres keeps — every chain's under a shared counter, where one
    /// chain's rollback reverts them all.
    pub async fn rollback_target_checkpoint(
        &self,
        chain_id: i64,
        block_number: i32,
    ) -> Result<Option<i64>> {
        let target = self
            .postgres
            .rollback_target_checkpoint(chain_id, block_number)
            .await?;
        let (None, Some(clickhouse)) = (target, &self.clickhouse) else {
            return Ok(target);
        };
        let chain_id = match self.schema.sequence {
            Sequence::PerChain => Some(chain_id),
            Sequence::SharedAcrossChains => None,
        };
        let kept_from = self.postgres.lowest_checkpoint(chain_id).await?;
        clickhouse.last_checkpoint_below(chain_id, kept_from).await
    }

    pub async fn rollback_progress_diff(&self, bounds: &Bounds) -> Result<Vec<ProgressDiff>> {
        self.postgres.rollback_progress_diff(bounds).await
    }

    /// Resumes Postgres, and then ClickHouse to what Postgres committed for
    /// the chains this run drives: a batch ClickHouse landed but Postgres
    /// never committed is trimmed away.
    pub async fn resume(&self, chain_ids: &[i64]) -> Result<Resumed> {
        let resumed = self.postgres.resume().await?;
        if let Some(clickhouse) = &self.clickhouse {
            clickhouse
                .resume(&Resume {
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

    pub async fn set_chain_meta(&self, chains: &[ChainMeta]) -> Result<()> {
        self.postgres.set_chain_meta(chains).await
    }

    pub async fn finalize_backfill(&self, chain_ids: &[i64], ready_at: f64) -> Result<()> {
        self.postgres.finalize_backfill(chain_ids, ready_at).await
    }

    /// Restores whatever the schema promises and Postgres no longer has. A
    /// failed build is reported, and its queries run unindexed until the next
    /// restart.
    pub async fn ensure_schema_indexes(&self, chain_ids: &[i64]) {
        self.postgres
            .indexes
            .ensure(self.postgres.schema_indexes(chain_ids), Purpose::Schema)
            .await;
    }

    /// The build a getWhere on `columns` still needs, if any. None when the
    /// catalog already covers them, which is every call but the first — and
    /// every call for an entity Postgres doesn't keep, which builds none.
    pub fn ensure_query_indexes(
        &self,
        entity: &Entity,
        chain_id: Option<i64>,
        columns: Vec<String>,
    ) -> Option<impl std::future::Future<Output = ()> + Send + 'static> {
        if !entity.postgres {
            return None;
        }
        let definitions = self.postgres.query_indexes(entity, chain_id, columns);
        let indexes = &self.postgres.indexes;
        if indexes.covers_all(&definitions, Coverage::LeadingColumns) {
            return None;
        }
        let indexes = indexes.clone();
        Some(async move { indexes.ensure(definitions, Purpose::Query).await })
    }

    pub async fn prune_checkpoints(&self, bounds: &Bounds) -> Result<()> {
        self.postgres.prune_checkpoints(bounds).await
    }

    /// ClickHouse keeps every history row: its reads resolve the entities from
    /// them.
    pub async fn prune_history(&self, entity: &Entity, bounds: &Bounds) -> Result<()> {
        self.postgres.prune_history(entity, bounds).await
    }

    pub async fn load_where(
        &self,
        entity: &Entity,
        conditions: Vec<Condition>,
    ) -> Result<ResultSet> {
        match self.home(entity)? {
            Store::Postgres => self.postgres.load_where(&entity.name, conditions).await,
            Store::ClickHouse => self.clickhouse()?.load_where(entity, conditions).await,
        }
    }

    pub async fn load_effect_cache(
        &self,
        table: &str,
        conditions: Vec<Condition>,
    ) -> Result<ResultSet> {
        self.postgres.load_where(table, conditions).await
    }

    pub async fn rollback_data(&self, entity: &Entity, bounds: &Bounds) -> Result<RollbackData> {
        let (removed, restored) = match self.home(entity)? {
            Store::Postgres => self.postgres.rollback_data(entity, bounds).await?,
            Store::ClickHouse => self.clickhouse()?.rollback_data(entity, bounds).await?,
        };
        Ok(RollbackData { removed, restored })
    }

    /// Every current row of an entity ClickHouse keeps.
    pub async fn clickhouse_rows(&self, entity: &Entity) -> Result<ResultSet> {
        self.clickhouse()?.load_where(entity, Vec::new()).await
    }

    /// Every committed history row of an entity ClickHouse keeps.
    pub async fn clickhouse_history(&self, entity: &Entity) -> Result<ResultSet> {
        self.clickhouse()?.history(entity).await
    }

    pub async fn effect_cache_tables(&self) -> Result<Vec<CacheTable>> {
        self.postgres.effect_cache_tables().await
    }

    pub async fn upload_effect_cache(&self, files: &[CacheFile]) -> Result<()> {
        self.postgres.upload_effect_cache(files).await
    }

    pub async fn dump_effect_cache(&self, files: &[CacheDump]) -> Result<()> {
        self.postgres.dump_effect_cache(files).await
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
            return match self.postgres.write_batch(&batch, Handoff::default()).await {
                Ok(()) => Ok(vec![(Store::Postgres, started.elapsed().as_secs_f64())]),
                Err(WriteError::Failed(failure)) => Err(failure),
                Err(WriteError::Gated) => unreachable!("a write with no gate is never gated"),
            };
        };
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
                    &batch,
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
                    &batch,
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
