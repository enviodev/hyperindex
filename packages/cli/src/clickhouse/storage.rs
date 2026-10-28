//! ClickHouse beside Postgres, keeping the entities configured for it. Nothing
//! here is updated in place: every write appends rows stamped with the
//! checkpoint they belong to. A batch's rows land first, Postgres commits, and
//! only then do the chains' rows move each chain's frontier, `checkpoint_id`,
//! over them. A read only sees rows at or below its chain's frontier, and a
//! resume trims away whatever a batch Postgres never committed left above it.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, bail, Context, Result};
use futures_util::future::try_join_all;

use super::ch_type::{ChType, FieldSpec};
use super::client::{error_code, insert_tag_prefix, Client, Connection, Tuning, Warn};
use super::ddl::{self, Topology, CHAIN_ID_COLUMN, ID_COLUMN};
use super::row_binary::{self, encode_values, EncodedRows, Value};
use super::select::{self, Frontier};
use super::table::Table;
use super::{literal, quoted, table_ref};
use crate::config_parsing::system_config::ChainIdMode;
use crate::entity_filter::Condition;
use crate::storage::changes::ChangeSet;
use crate::storage::rows::{self, Cell, ColumnRead, ReadKind, ResultSet};
use crate::storage::schema::{Entity, FieldType, Schema};
use crate::storage::types::{
    Bounds, Checkpoints, Sequence, CHAINS_TABLE, CHECKPOINTS_TABLE, CHECKPOINT_ID_COLUMN,
    INFO_TABLE,
};
use crate::storage::{Batch, Failure, Handoff, Initialize, Resume, WriteError};

pub struct Settings {
    pub replicated: bool,
    pub database_engine: Option<String>,
}

/// How far a resume or an initialize moves the chains' version past the
/// highest it read, or past the clock in microseconds when that is higher. A
/// process that died mid-commit can still have its chains insert land after
/// the next one started — with a version a little above what that one read —
/// and the rows with the higher version are the ones that stand. Starting from
/// the clock keeps versions behind it, so an initialize over tables a reset
/// dropped, with nothing to read, still starts past every earlier run.
const VERSION_FENCE: u64 = 1 << 20;

fn unix_micros() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_micros() as u64)
}

#[derive(Default)]
struct Chains {
    /// Each chain's frontier as its row last landed. Everything else about a
    /// chain is Postgres's.
    frontier: Frontier,
    /// The version the last write stamped its rows with.
    version: u64,
}

pub struct Storage {
    client: Client,
    settings: Settings,
    schema: Arc<Schema>,
    /// By entity index: None for an entity ClickHouse doesn't keep.
    tables: Vec<Option<Arc<Table>>>,
    chains: Mutex<Chains>,
}

impl Settings {
    /// A Replicated database engine only replicates data when its tables use
    /// the ReplicatedMergeTree engine, so it implies replicated DDL even when
    /// ENVIO_CLICKHOUSE_REPLICATED is unset.
    fn has_replicated_engine(&self) -> bool {
        self.database_engine
            .as_deref()
            .map(ddl::database_engine_name)
            == Some("Replicated")
    }
}

impl Storage {
    pub fn new(
        connection: Connection,
        tuning: Tuning,
        warn: Warn,
        settings: Settings,
        schema: Arc<Schema>,
    ) -> Result<Self> {
        let client = Client::new(connection, tuning, warn)?;
        let tables = schema
            .entities
            .iter()
            .map(|entity| {
                entity
                    .clickhouse
                    .is_some()
                    .then(|| {
                        Table::new(entity, &client.database, schema.chain_id_mode).map(Arc::new)
                    })
                    .transpose()
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(Self {
            client,
            settings,
            schema,
            tables,
            chains: Mutex::new(Chains::default()),
        })
    }

    pub fn table(&self, entity: &Entity) -> Result<&Arc<Table>> {
        self.tables
            .get(entity.index)
            .and_then(Option::as_ref)
            .ok_or_else(|| anyhow!("\"{}\" is not stored in ClickHouse", entity.name))
    }

    fn all_tables(&self) -> Vec<Arc<Table>> {
        self.tables.iter().flatten().cloned().collect()
    }

    fn chain_id_mode(&self) -> ChainIdMode {
        self.schema.chain_id_mode
    }

    fn database(&self) -> &str {
        &self.client.database
    }

    fn chain_id_type(&self) -> ChType {
        FieldSpec::new("chainId", FieldType::ChainId)
            .ch_type(self.chain_id_mode())
            .expect("a chain id always has a ClickHouse type")
    }

    fn topology(&self) -> Topology {
        let has_replicated_engine = self.settings.has_replicated_engine();
        let replicated = self.settings.replicated || has_replicated_engine;
        Topology {
            replicated,
            ddl_on_cluster: replicated && !has_replicated_engine,
        }
    }

    fn frontier(&self) -> Frontier {
        self.chains.lock().unwrap().frontier.clone()
    }

    async fn insert(&self, table: &str, query: &str, encoded: &EncodedRows) -> Result<()> {
        self.client
            .insert(table, query, encoded)
            .await
            .with_context(|| format!("Failed inserting into ClickHouse table `{table}`"))
    }

    /// The rows of one of the indexer's own tables, and the insert that sends
    /// them.
    fn encode_rows(
        &self,
        table: &str,
        columns: &[(String, ChType)],
        rows: &[Vec<Value>],
    ) -> Result<(String, EncodedRows)> {
        let types = columns
            .iter()
            .map(|(_, ch_type)| ch_type.clone())
            .collect::<Vec<_>>();
        let encoded = encode_values(&types, rows)
            .with_context(|| format!("Failed encoding rows for ClickHouse table `{table}`"))?;
        let query = ddl::insert_query(self.database(), table, columns.iter().map(|(name, _)| name));
        Ok((query, encoded))
    }

    async fn insert_values(
        &self,
        table: &str,
        columns: &[(String, ChType)],
        rows: &[Vec<Value>],
    ) -> Result<()> {
        if rows.is_empty() {
            return Ok(());
        }
        let (query, encoded) = self.encode_rows(table, columns, rows)?;
        self.insert(table, &query, &encoded).await
    }

    /// Sends every change set of one table, in one insert. Encoding runs off
    /// the async workers: it is pure CPU over every cell of the batch.
    async fn insert_changes(&self, table: Arc<Table>, changes: Vec<Arc<ChangeSet>>) -> Result<()> {
        let encoding = table.clone();
        let encoded = tokio::task::spawn_blocking(move || {
            let rows = changes.iter().map(|changes| changes.len()).sum();
            let mut body = Vec::with_capacity(rows * encoding.staged.len() * 12);
            let mut row_offsets = Vec::with_capacity(rows);
            for changes in &changes {
                row_binary::encode_changes(&mut body, &mut row_offsets, &encoding, changes)?;
            }
            Ok::<_, anyhow::Error>(EncodedRows {
                body: body.into(),
                row_offsets,
            })
        })
        .await
        .context("ClickHouse encode task failed")?
        .with_context(|| {
            format!(
                "Failed encoding rows for ClickHouse table `{}`",
                table.entity.history_table
            )
        })?;
        self.insert(&table.entity.history_table, &table.insert_query, &encoded)
            .await
    }

    /// Moves the frontier of every chain `moved` names, the commit point of
    /// whatever was written below it. The rows go in one insert, since half of
    /// them would move some chains' frontiers and not the others', and are only
    /// taken as the frontier once they landed. Writes are never concurrent:
    /// batches are written one at a time, and a resume or an initialize before
    /// any.
    async fn write_chains(&self, moved: Frontier) -> Result<()> {
        // Spent whether the insert lands or not: one that failed here can
        // still land later, and must not tie with the next.
        let version = {
            let mut chains = self.chains.lock().unwrap();
            chains.version += 1;
            chains.version
        };
        if moved.is_empty() {
            return Ok(());
        }
        let rows = moved
            .iter()
            .map(|(chain_id, checkpoint_id)| {
                vec![
                    Value::Int((*chain_id).into()),
                    Value::Int((*checkpoint_id).into()),
                    Value::Int(version.into()),
                ]
            })
            .collect::<Vec<_>>();
        let (query, encoded) = self.encode_rows(
            CHAINS_TABLE,
            &ddl::chain_columns(&self.chain_id_type()),
            &rows,
        )?;
        self.client
            .insert_whole(CHAINS_TABLE, &query, &encoded)
            .await
            .with_context(|| format!("Failed inserting into ClickHouse table `{CHAINS_TABLE}`"))?;
        self.chains.lock().unwrap().frontier.extend(moved);
        Ok(())
    }

    fn checkpoint_values(checkpoints: &Checkpoints) -> Vec<Vec<Value>> {
        (0..checkpoints.len())
            .map(|index| {
                vec![
                    Value::Int(checkpoints.chain_ids[index].into()),
                    Value::Int(checkpoints.ids[index].into()),
                    Value::Int(checkpoints.block_numbers[index].into()),
                    checkpoints.block_hashes[index]
                        .clone()
                        .map_or(Value::Null, Value::Text),
                    Value::Int(checkpoints.events_processed[index].max(0).into()),
                ]
            })
            .collect()
    }

    async fn existing_database_engine(&self) -> Result<Option<String>> {
        let answer = self
            .client
            .statement(format!(
                "SELECT engine FROM system.databases WHERE name = {} FORMAT TabSeparated",
                literal(self.database())
            ))
            .await?;
        Ok(match answer.trim() {
            "" => None,
            engine => Some(engine.to_string()),
        })
    }

    /// What initializing would have to destroy or could not change, refused
    /// before anything is touched.
    pub async fn check_for_initialize(&self) -> Result<()> {
        if let Some(engine_spec) = self.settings.database_engine.as_deref() {
            let expected = ddl::database_engine_name(engine_spec);
            match self.existing_database_engine().await?.as_deref() {
                Some(engine) if engine != expected => bail!(
                    "ClickHouse database \"{}\" exists with engine \"{engine}\" but \
                     ENVIO_CLICKHOUSE_DATABASE_ENGINE specifies \"{expected}\" (from \
                     \"{engine_spec}\"). Drop the database manually to change its engine.",
                    self.database()
                ),
                _ => {}
            }
        }
        let answer = self
            .client
            .statement(format!(
                "SELECT name FROM system.tables WHERE database = {} FORMAT TabSeparated",
                literal(self.database())
            ))
            .await?;
        let names = answer
            .lines()
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .collect::<Vec<_>>();
        // An entity's view is named after the entity, so a database the
        // indexer built is told by its chains' table. One whose setup failed
        // before that table was created holds only tables named the
        // indexer's way.
        let foreign = names.iter().any(|name| !name.starts_with("envio_"));
        if foreign && !names.contains(&CHAINS_TABLE) {
            bail!(
                "ClickHouse database \"{}\" holds tables that aren't the indexer's, and emptying it \
                 for the indexer would delete them.\n\nTo resolve this:\n1. Set \
                 ENVIO_CLICKHOUSE_DATABASE to a database of the indexer's own\n2. Or drop those \
                 tables yourself if you're certain they aren't needed.",
                self.database()
            );
        }
        Ok(())
    }

    async fn initialize_inner(&self, input: &Initialize) -> Result<()> {
        let topology = self.topology();
        if self.settings.has_replicated_engine() && !self.settings.replicated {
            (self.client.warn)(
                "ENVIO_CLICKHOUSE_DATABASE_ENGINE is Replicated; enabling replicated mode so \
                 tables use the ReplicatedMergeTree engine.",
            );
        }
        let database = quoted(self.database());

        let tables = self.all_tables();
        let entities = tables.iter().map(|table| &table.entity).collect::<Vec<_>>();
        let history_tables = entities
            .iter()
            .map(|entity| {
                ddl::create_history_table(entity, self.database(), topology, self.chain_id_mode())
            })
            .collect::<Result<Vec<_>>>()?;

        self.stop_inserts_left_running(Some(
            &input
                .chains
                .iter()
                .map(|chain| chain.id)
                .collect::<Vec<_>>(),
        ))
        .await?;
        // Read before the reset empties it: a previous run's commit still in
        // flight lands in the tables built here, and its rows must lose. A
        // table an older envio built has no version column, and a database or
        // table a reset dropped has nothing to read.
        let previous_version = match self.read_version().await {
            Ok(version) => version,
            Err(error)
                if matches!(
                    error_code(&format!("{error:#}")),
                    Some(
                        16 // NO_SUCH_COLUMN_IN_TABLE
                        | 47 // UNKNOWN_IDENTIFIER
                        | 60 // UNKNOWN_TABLE
                        | 81 // UNKNOWN_DATABASE
                    )
                ) =>
            {
                0
            }
            Err(error) => return Err(error),
        }
        .max(unix_micros());
        self.reset_database().await?;
        self.client
            .statement(format!(
                "CREATE DATABASE IF NOT EXISTS {database}{}{}",
                ddl::on_cluster_clause(topology.replicated),
                match &self.settings.database_engine {
                    Some(engine) => format!(" ENGINE = {engine}"),
                    None => String::new(),
                }
            ))
            .await?;

        let chain_id_type = self.chain_id_type();
        let mut statements = history_tables;
        statements.push(ddl::create_checkpoints_table(
            &chain_id_type,
            self.database(),
            topology,
        ));
        statements.push(ddl::create_chains_table(
            &chain_id_type,
            self.database(),
            topology,
        ));
        statements.push(ddl::create_info_table(self.database(), topology));
        try_join_all(
            statements
                .into_iter()
                .map(|query| self.client.statement(query)),
        )
        .await?;
        try_join_all(entities.iter().map(|entity| {
            self.client
                .statement(ddl::create_view(entity, self.database(), topology))
        }))
        .await?;

        *self.chains.lock().unwrap() = Chains {
            frontier: Frontier::new(),
            version: previous_version + VERSION_FENCE,
        };
        self.write_chains(input.chains.iter().map(|chain| (chain.id, 0)).collect())
            .await
    }

    /// Builds every table, but leaves the database unpaired: see [`Self::seal`].
    pub async fn build(&self, input: &Initialize) -> Result<()> {
        self.initialize_inner(input)
            .await
            .context("Failed to initialize ClickHouse storage")
    }

    /// Pairs a built database with the initialize that built it. The record
    /// is what says the storage exists, so it only does once both stores are
    /// in place: one built for a Postgres that then failed is set up again.
    pub async fn seal(&self, instance: &str) -> Result<()> {
        self.insert_values(
            INFO_TABLE,
            &ddl::info_columns(),
            &[vec![Value::Int(1), Value::Text(instance.to_string())]],
        )
        .await
        .context("Failed to initialize ClickHouse storage")
    }

    #[cfg(test)]
    pub async fn initialize(&self, input: &Initialize) -> Result<()> {
        self.build(input).await?;
        self.seal("instance").await
    }

    async fn has_table(&self, name: &str) -> Result<bool> {
        let count = self
            .client
            .statement(format!(
                "SELECT count() FROM system.tables WHERE `database` = {} AND `name` = {} \
                 FORMAT TabSeparated",
                literal(self.database()),
                literal(name)
            ))
            .await?;
        Ok(count.trim() != "0")
    }

    /// Whether a batch that reached an event landed here: every one writes the
    /// checkpoints it covers, which nothing prunes.
    pub async fn holds_batches(&self) -> Result<bool> {
        if !self.has_table(CHECKPOINTS_TABLE).await? {
            return Ok(false);
        }
        let answer = self
            .client
            .statement(format!(
                "SELECT count() > 0 FROM {} FORMAT TabSeparated",
                table_ref(self.database(), CHECKPOINTS_TABLE)
            ))
            .await?;
        Ok(answer.trim() == "1")
    }

    /// The instance of the initialize that built the database, if one finished
    /// building it.
    pub async fn instance(&self) -> Result<Option<String>> {
        if !self.has_table(INFO_TABLE).await? {
            return Ok(None);
        }
        let body = self
            .client
            .read(format!(
                "SELECT `instance` FROM {} ORDER BY `id` LIMIT 1 FORMAT RowBinary",
                table_ref(self.database(), INFO_TABLE)
            ))
            .await?;
        match row_binary::decode(&body, &[(ChType::String, ReadKind::Text)])?.as_slice() {
            [] => Ok(None),
            [Cell::Str(instance)] => Ok(Some(instance.to_string())),
            other => bail!("Unexpected info record {other:?}"),
        }
    }

    /// Stops the inserts a process before this one left running on any of
    /// `chain_ids` — on any chain, given none — and tags this one's inserts as
    /// writing them. An insert keeps running on the server after the process
    /// that sent it is gone, and one landing after a trim would leave rows the
    /// next batches reuse the checkpoints of.
    async fn stop_inserts_left_running(&self, chain_ids: Option<&[i64]>) -> Result<()> {
        let prefix = insert_tag_prefix(self.database());
        let mut filter = format!("startsWith(query_id, {})", literal(&prefix));
        if let Some(chain_ids) = chain_ids {
            self.client.tag_inserts(chain_ids);
            let needles = chain_ids
                .iter()
                .map(|chain_id| literal(&format!(",{chain_id},")))
                .collect::<Vec<_>>()
                .join(", ");
            // Past the prefix, so a database name holding `,1,` names no chain.
            filter.push_str(&format!(
                " AND multiSearchAny(substring(query_id, {}), [{needles}])",
                prefix.len() + 1
            ));
        }
        self.client
            .statement(format!(
                "KILL QUERY{} WHERE {filter} SYNC FORMAT TabSeparated",
                ddl::on_cluster_clause(self.topology().replicated),
            ))
            .await
            .context(
                "Couldn't stop the ClickHouse inserts a previous run may have left running. Start \
                 again once ClickHouse answers.",
            )?;
        Ok(())
    }

    /// Emptied rather than dropped, so a database the operator provisioned
    /// keeps its engine and grants — except where emptying is not an option.
    async fn reset_database(&self) -> Result<()> {
        let database = quoted(self.database());
        let statement = if self.settings.has_replicated_engine() {
            // TRUNCATE DATABASE is unsupported on Replicated databases, so a
            // reset has to DROP and recreate instead. ON CLUSTER removes the
            // database from every node — the engine's own log can't replicate
            // the drop of the database it lives in — and SYNC waits for the drop
            // to finish before anything is created again.
            format!("DROP DATABASE IF EXISTS {database} ON CLUSTER '{{cluster}}' SYNC")
        } else {
            format!(
                "TRUNCATE DATABASE IF EXISTS {database}{}",
                self.topology().on_cluster()
            )
        };
        self.client.statement(statement).await?;
        Ok(())
    }

    /// The highest version any write stamped the chains' rows with.
    async fn read_version(&self) -> Result<u64> {
        let answer = self
            .client
            .statement(format!(
                // Null over no rows where a profile sets
                // aggregate_functions_null_for_empty.
                "SELECT ifNull(max({}), 0) FROM {} FORMAT TabSeparated",
                quoted(ddl::VERSION_COLUMN),
                table_ref(self.database(), CHAINS_TABLE)
            ))
            .await?;
        answer
            .trim()
            .parse()
            .with_context(|| format!("Unexpected chains version {answer:?}"))
    }

    /// Trims every table holding rows stamped past `frontier`, which only a
    /// batch Postgres never committed leaves behind. A table with nothing
    /// above it is left alone: a mutation rewrites parts, and on a clean
    /// restart there is nothing to rewrite.
    async fn trim_above(
        &self,
        sequence: Sequence,
        frontier: &Frontier,
        tables: &[Arc<Table>],
    ) -> Result<()> {
        let bounds = Bounds {
            sequence,
            chain_ids: frontier.keys().copied().collect(),
            checkpoint_ids: match sequence {
                // Under one shared counter every chain counts from the same
                // run of it, so the highest committed id is where all of them
                // trim — a lower one would remove another chain's rows.
                Sequence::SharedAcrossChains => {
                    let highest = frontier.values().copied().max().unwrap_or(0);
                    vec![highest; frontier.len()]
                }
                Sequence::PerChain => frontier.values().copied().collect(),
            },
        };
        let mut above_by_table = tables
            .iter()
            .map(|table| {
                Ok((
                    table.entity.history_table.clone(),
                    select::history_above(table, &bounds)?,
                ))
            })
            .collect::<Result<Vec<_>>>()?;
        above_by_table.push((
            CHECKPOINTS_TABLE.to_string(),
            select::above(&bounds, Some(CHAIN_ID_COLUMN), ID_COLUMN)?,
        ));

        let holding = self.tables_holding_rows_above(&above_by_table).await?;
        try_join_all(
            above_by_table
                .iter()
                .filter(|(table, _)| holding.contains(table))
                .map(|(table, above)| {
                    self.client
                        .statement(ddl::trim_table(self.database(), table, above))
                }),
        )
        .await?;
        Ok(())
    }

    /// Which of the tables hold a row above the checkpoint. TabSeparated
    /// answers one `name<TAB>0|1` per table, in whatever order the server ran
    /// the branches. The shape is fully known here, so anything else is an
    /// answer to refuse rather than a table to skip: a skipped trim leaves
    /// rolled-back rows visible.
    async fn tables_holding_rows_above(
        &self,
        above_by_table: &[(String, String)],
    ) -> Result<HashSet<String>> {
        let answer = self
            .client
            .statement(ddl::holds_rows_above_checkpoint(
                self.database(),
                above_by_table,
            ))
            .await?;
        let answered: HashMap<&str, bool> = answer
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(|line| {
                let (table, holds) = line
                    .split_once('\t')
                    .with_context(|| format!("Unexpected row count answer {line:?}"))?;
                let holds = match holds.trim() {
                    "0" => false,
                    "1" => true,
                    _ => bail!("Unexpected row count answer {line:?}"),
                };
                Ok((table.trim(), holds))
            })
            .collect::<Result<_>>()?;
        above_by_table
            .iter()
            .filter_map(|(table, _)| match answered.get(table.as_str()) {
                Some(true) => Some(Ok(table.clone())),
                Some(false) => None,
                None => Some(Err(anyhow!("No row count answered for table {table}"))),
            })
            .collect()
    }

    /// Refuses a database missing a batch Postgres committed. Each frontier
    /// Postgres holds was a checkpoint ClickHouse took before Postgres
    /// committed, and none is ever pruned, or trimmed while it stands. One
    /// missing was lost after ClickHouse acknowledged it, and resuming over it
    /// would read the entities as they were before it for good.
    async fn check_holds(&self, frontier: &Frontier) -> Result<()> {
        let committed = frontier
            .iter()
            .filter(|(_, checkpoint_id)| **checkpoint_id > 0)
            .map(|(chain_id, checkpoint_id)| (*chain_id, *checkpoint_id))
            .collect::<Vec<_>>();
        if committed.is_empty() {
            return Ok(());
        }
        let missing = self.missing_checkpoints(&committed).await?;
        if !missing.is_empty() {
            bail!(
                "ClickHouse database \"{}\" doesn't hold batches Postgres committed: {}. \
                 ClickHouse lost them after taking them, or was restored from an older backup: \
                 index from scratch, or point ENVIO_CLICKHOUSE_DATABASE at the database that \
                 holds them.",
                self.database(),
                missing
                    .iter()
                    .map(|(chain_id, checkpoint_id)| {
                        format!("chain {chain_id} through checkpoint {checkpoint_id}")
                    })
                    .collect::<Vec<_>>()
                    .join(", ")
            );
        }
        Ok(())
    }

    /// The last checkpoint below `below`, of the one chain if one is named.
    /// One a rollback reverted is never it while that rollback's own
    /// checkpoint, above it, is below `below` too.
    pub async fn last_checkpoint_below(
        &self,
        chain_id: Option<i64>,
        below: Option<i64>,
    ) -> Result<Option<i64>> {
        let id = quoted(ID_COLUMN);
        let conditions = chain_id
            .map(|chain_id| format!("{} = {chain_id}", quoted(CHAIN_ID_COLUMN)))
            .into_iter()
            .chain(below.map(|below| format!("{id} < {below}")))
            .collect::<Vec<_>>();
        let filter = if conditions.is_empty() {
            String::new()
        } else {
            format!(" WHERE {}", conditions.join(" AND "))
        };
        let answer = self
            .client
            .statement(format!(
                "SELECT {id} FROM {}{filter} ORDER BY {id} DESC LIMIT 1 FORMAT TabSeparated",
                table_ref(self.database(), CHECKPOINTS_TABLE),
            ))
            .await?;
        match answer.trim() {
            "" => Ok(None),
            id => id
                .parse()
                .map(Some)
                .with_context(|| format!("Unexpected checkpoint id {id:?}")),
        }
    }

    /// A replica answering for the first time since a restart can still be
    /// fetching what another took: the last batches it committed, and what a
    /// crash left uncommitted. Checked and trimmed before then, a resume would
    /// read entities without those batches for good, and leave the leftovers it
    /// fetches afterwards above the frontier for the next batch to collide
    /// with.
    async fn sync_replica(&self, tables: &[Arc<Table>]) -> Result<()> {
        let names = tables
            .iter()
            .map(|table| table.entity.history_table.as_str())
            .chain([CHECKPOINTS_TABLE, CHAINS_TABLE]);
        try_join_all(names.map(|name| {
            self.client.statement(format!(
                "SYSTEM SYNC REPLICA {} LIGHTWEIGHT",
                table_ref(self.database(), name)
            ))
        }))
        .await
        .context(
            "Couldn't wait for this ClickHouse replica to fetch what the other replicas took. \
             Start again once they are reachable, or point ENVIO_CLICKHOUSE_HOST at the node that \
             took the writes.",
        )?;
        Ok(())
    }

    async fn missing_checkpoints(&self, committed: &[(i64, i64)]) -> Result<Vec<(i64, i64)>> {
        let answer = self
            .client
            .statement(format!(
                "SELECT DISTINCT {chain}, {id} FROM {} WHERE ({chain}, {id}) IN ({}) FORMAT \
                 TabSeparated",
                table_ref(self.database(), CHECKPOINTS_TABLE),
                committed
                    .iter()
                    .map(|(chain_id, checkpoint_id)| format!("({chain_id}, {checkpoint_id})"))
                    .collect::<Vec<_>>()
                    .join(", "),
                chain = quoted(CHAIN_ID_COLUMN),
                id = quoted(ID_COLUMN),
            ))
            .await?;
        let held = answer
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| {
                line.split_once('\t')
                    .and_then(|(chain_id, checkpoint_id)| {
                        Some((
                            chain_id.trim().parse::<i64>().ok()?,
                            checkpoint_id.trim().parse::<i64>().ok()?,
                        ))
                    })
                    .with_context(|| format!("Unexpected checkpoint row {line:?}"))
            })
            .collect::<Result<HashSet<_>>>()?;
        Ok(committed
            .iter()
            .copied()
            .filter(|chain| !held.contains(chain))
            .collect())
    }

    /// Takes the chains' state from what Postgres committed, frontier first
    /// so nothing above it is readable while the trims run. The rows are
    /// written past a fence, so a previous process's commit still in flight
    /// can't land over them.
    async fn resume_inner(&self, input: &Resume) -> Result<()> {
        self.stop_inserts_left_running(Some(
            &input
                .committed
                .iter()
                .map(|chain| chain.id)
                .collect::<Vec<_>>(),
        ))
        .await?;
        let version = self.read_version().await?.max(unix_micros());
        *self.chains.lock().unwrap() = Chains {
            frontier: Frontier::new(),
            version: version + VERSION_FENCE,
        };
        let frontier: Frontier = input
            .committed
            .iter()
            .map(|chain| (chain.id, chain.checkpoint_id))
            .collect();
        // No chain, no rows to hold to anything: Postgres writes every chain's
        // row in the transaction that creates its schema, so an empty list
        // means a config without chains.
        if frontier.is_empty() {
            return Ok(());
        }
        let tables = self.all_tables();
        if self.topology().replicated {
            self.sync_replica(&tables).await?;
        }
        self.check_holds(&frontier).await?;
        self.write_chains(frontier.clone()).await?;
        self.trim_above(self.schema.sequence, &frontier, &tables)
            .await
    }

    pub async fn resume(&self, input: &Resume) -> Result<()> {
        self.resume_inner(input)
            .await
            .context("Failed to resume ClickHouse storage")
    }

    pub async fn load_where(
        &self,
        entity: &Entity,
        conditions: Vec<Condition>,
    ) -> Result<ResultSet> {
        let table = self.table(entity)?;
        let read = select::load(self.database(), table, &conditions, &self.frontier())?;
        let body = self.client.read_with(read).await?;
        let (types, reads) = table.reads();
        rows::lay_out(&row_binary::decode(&body, &types)?, reads)
    }

    pub async fn history(&self, entity: &Entity) -> Result<ResultSet> {
        let table = self.table(entity)?;
        let body = self
            .client
            .read(select::history(self.database(), table, &self.frontier()))
            .await?;
        let (mut types, mut reads) = table.history_reads();
        types.push((ChType::UInt64, ReadKind::Text));
        reads.push(ColumnRead::scalar(CHECKPOINT_ID_COLUMN, ReadKind::Text));
        rows::lay_out(&row_binary::decode(&body, &types)?, reads)
    }

    /// The keys a rollback removes, and the rows it restores the rest from.
    pub async fn rollback_data(
        &self,
        entity: &Entity,
        bounds: &Bounds,
    ) -> Result<(ResultSet, ResultSet)> {
        let table = self.table(entity)?;
        let key = table.key_columns()?;
        let (removed, restored) = futures_util::try_join!(
            self.client
                .read(select::rollback_removed(self.database(), table, bounds)?),
            self.client
                .read(select::rollback_restored(self.database(), table, bounds)?),
        )?;
        let removed = rows::lay_out(
            &row_binary::decode(
                &removed,
                &key.iter()
                    .map(|column| (column.ch_type.clone(), column.read))
                    .collect::<Vec<_>>(),
            )?,
            key.iter()
                .map(|column| ColumnRead::scalar(&column.row_name, column.read))
                .collect(),
        )?;
        let (types, reads) = table.history_reads();
        let restored = rows::lay_out(&row_binary::decode(&restored, &types)?, reads)?;
        Ok((removed, restored))
    }

    /// Whether the batch was committed: one landed but not told to commit is
    /// left above the frontier, unread and trimmed by the next resume.
    async fn write_inner(&self, batch: &Batch, mut handoff: Handoff) -> Result<bool> {
        // A per-chain entity stages each chain's rows apart, and each insert
        // is a part the server has to merge.
        let mut staged: Vec<(Arc<Table>, Vec<Arc<ChangeSet>>)> = Vec::new();
        for changes in &batch.changes {
            if changes.entity.clickhouse.is_none() || changes.len() == 0 {
                continue;
            }
            let table = self.table(&changes.entity)?;
            match staged
                .iter_mut()
                .find(|(staged, _)| Arc::ptr_eq(staged, table))
            {
                Some((_, sets)) => sets.push(changes.clone()),
                None => staged.push((table.clone(), vec![changes.clone()])),
            }
        }
        // With no rows between the old frontier and the new one, every read
        // bounded by either answers the same, and a resume rewrites the
        // frontier from Postgres anyway.
        let moved = if staged.is_empty() {
            Frontier::new()
        } else {
            batch.frontier.entries().collect()
        };
        let checkpoint_columns = ddl::checkpoint_columns(&self.chain_id_type());
        let checkpoint_rows = Self::checkpoint_values(&batch.checkpoints_with_diff());
        futures_util::try_join!(
            self.insert_values(CHECKPOINTS_TABLE, &checkpoint_columns, &checkpoint_rows),
            try_join_all(
                staged
                    .into_iter()
                    .map(|(table, changes)| self.insert_changes(table, changes))
            ),
        )?;

        // Every row above has landed, so the chains' rows can make them
        // readable once the handoff says to.
        if !handoff.ready_to_commit().await {
            return Ok(false);
        }
        self.write_chains(moved).await.map(|()| true)
    }

    pub async fn write_batch(
        &self,
        batch: &Batch,
        handoff: Handoff,
    ) -> std::result::Result<(), WriteError> {
        match self.write_inner(batch, handoff).await {
            Ok(true) => Ok(()),
            Ok(false) => Err(WriteError::Gated),
            Err(error) => Err(WriteError::Failed(Failure::new(
                "Failed to write a batch to ClickHouse",
                error,
            ))),
        }
    }

    /// Refuses a database it may not empty, as initializing would.
    pub async fn reset(&self) -> Result<()> {
        self.check_for_initialize().await?;
        self.stop_inserts_left_running(None).await?;
        self.reset_database().await?;
        *self.chains.lock().unwrap() = Chains::default();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clickhouse::mock_server::MockClickHouse;
    use crate::clickhouse::table::test_support::{column, entity_input};
    use crate::storage::changes::test_support::{change_set, Change};
    use crate::storage::types::{Addresses, ChainConfig, Frontier, ResumedChain};
    use pretty_assertions::assert_eq;

    /// A cross-chain entity has no chain column, which only a shared sequence
    /// bounds.
    fn schema() -> Arc<Schema> {
        Arc::new(Schema {
            entities: vec![Arc::new(entity_input(
                "Account",
                vec![column("id", "String")],
            ))],
            enums: Vec::new(),
            sequence: Sequence::SharedAcrossChains,
            chain_id_mode: ChainIdMode::Int32,
        })
    }

    fn storage_with(server: &MockClickHouse, replicated: bool) -> Storage {
        Storage::new(
            crate::clickhouse::client::test_support::connection(server.url.clone()),
            Tuning::default(),
            Arc::new(|_: &str| {}),
            Settings {
                replicated,
                database_engine: None,
            },
            schema(),
        )
        .unwrap()
    }

    fn storage_at(server: &MockClickHouse) -> Storage {
        storage_with(server, false)
    }

    /// A set of each id, at checkpoint 1.
    fn sets(storage: &Storage, ids: &[&str]) -> ChangeSet {
        let values = ids.iter().map(|id| [Some(*id)]).collect::<Vec<_>>();
        change_set(
            storage.schema.entities[0].clone(),
            None,
            true,
            &values
                .iter()
                .map(|value| Change::Set(value, 1))
                .collect::<Vec<_>>(),
        )
    }

    /// The table each insert went to, in the order they were sent.
    fn inserted_tables(server: &MockClickHouse) -> Vec<String> {
        server
            .heads()
            .iter()
            .filter_map(|head| {
                let query = head.split_once("query=")?.1;
                let table = query.split("%60").nth(3)?;
                Some(table.to_string())
            })
            .collect()
    }

    async fn initialize(storage: &Storage) {
        storage
            .initialize(&Initialize {
                chains: vec![ChainConfig {
                    id: 1,
                    ecosystem: "evm".to_string(),
                    start_block: 0,
                    end_block: None,
                    max_reorg_depth: 0,
                }],
                envio_info: "{}".to_string(),
                contract_names: Vec::new(),
                addresses: Addresses::default(),
            })
            .await
            .unwrap();
    }

    /// Initializing empties the database, so one that holds tables but none of
    /// the indexer's is refused rather than emptied.
    #[tokio::test(flavor = "multi_thread")]
    async fn initializing_refuses_a_database_with_tables_of_someone_elses() {
        let server = MockClickHouse::answering_statements(Arc::new(|statement: &str| {
            if statement.contains("system.tables") {
                (200, "orders\ncustomers".to_string())
            } else {
                (200, String::new())
            }
        }))
        .await;
        let storage = storage_at(&server);

        let refused = storage.check_for_initialize().await.unwrap_err();

        assert_eq!(
            (
                format!("{refused:#}").contains("holds tables that aren't the indexer's"),
                server.inserts_seen()
            ),
            (true, 0)
        );
    }

    /// A setup that failed partway leaves tables of its own behind, possibly
    /// without the chains' table, and the next one takes them over.
    #[tokio::test(flavor = "multi_thread")]
    async fn initializing_takes_over_what_a_failed_setup_left() {
        let server = MockClickHouse::answering_statements(Arc::new(|statement: &str| {
            if statement.contains("system.tables") {
                (200, "envio_history_Account\nenvio_checkpoints".to_string())
            } else {
                (200, String::new())
            }
        }))
        .await;
        let storage = storage_at(&server);

        assert_eq!(
            storage
                .check_for_initialize()
                .await
                .map_err(|error| format!("{error:#}")),
            Ok(())
        );
    }

    /// A server that answers what initializing and writing ask of it.
    async fn accepting() -> MockClickHouse {
        MockClickHouse::answering_statements(Arc::new(|statement: &str| {
            if statement.contains("count() FROM system.tables")
                || statement.contains("max(`version`)")
            {
                (200, "0".to_string())
            } else {
                (200, String::new())
            }
        }))
        .await
    }

    /// Writes the staged rows at checkpoint 1 of chain 1.
    async fn write_staged(storage: &Storage, writes: Vec<ChangeSet>) {
        storage
            .write_batch(
                &Batch {
                    changes: writes.into_iter().map(Arc::new).collect(),
                    frontier: Frontier {
                        chain_ids: vec![1],
                        checkpoint_ids: vec![1],
                    },
                    checkpoints: Checkpoints {
                        ids: vec![1],
                        chain_ids: vec![1],
                        block_numbers: vec![10],
                        block_hashes: vec![None],
                        events_processed: vec![1],
                        keeps_history: vec![true],
                    },
                    ..Batch::default()
                },
                Handoff::default(),
            )
            .await
            .map_err(|error| match error {
                WriteError::Failed(failure) => format!("{}: {:#}", failure.context, failure.error),
                WriteError::Gated => "gated".to_string(),
            })
            .unwrap();
    }

    /// A per-chain entity stages each chain's rows apart, and every insert is
    /// a part the server has to merge: one table's rows go in one insert. Each
    /// row is its id, its checkpoint and its change — 11 bytes for these.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_write_sends_each_table_one_insert() {
        let server = accepting().await;
        let storage = storage_at(&server);
        initialize(&storage).await;
        let initialized = inserted_tables(&server).len();

        write_staged(
            &storage,
            vec![sets(&storage, &["a"]), sets(&storage, &["b", "c"])],
        )
        .await;

        let history = inserted_tables(&server)
            .into_iter()
            .zip(server.accepted())
            .skip(initialized)
            .filter(|(table, _)| table == "envio_history_Account")
            .map(|(_, body)| body.len())
            .collect::<Vec<_>>();
        assert_eq!(history, vec![33]);
    }

    /// The chains' rows are what make a write readable, so they go only once
    /// every row they cover has landed.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_write_commits_with_its_chains_rows_last() {
        let server = accepting().await;
        let storage = storage_at(&server);
        initialize(&storage).await;
        let initialized = inserted_tables(&server).len();

        let queries_before = server.queries_seen();
        write_staged(&storage, vec![sets(&storage, &["a"])]).await;

        let mut written = inserted_tables(&server).split_off(initialized);
        let last = written.pop();
        written.sort();
        assert_eq!(
            (written, last, server.queries_seen() - queries_before),
            (
                vec![
                    "envio_checkpoints".to_string(),
                    "envio_history_Account".to_string()
                ],
                Some("envio_chains".to_string()),
                0
            )
        );
    }

    /// A batch with no rows for ClickHouse leaves every read as it was, so its
    /// frontier is left for the next batch with rows to raise.
    #[tokio::test(flavor = "multi_thread")]
    async fn only_a_write_with_rows_raises_the_chains_frontier() {
        let server = accepting().await;
        let storage = storage_at(&server);
        initialize(&storage).await;
        let initialized = inserted_tables(&server).len();

        write_staged(&storage, Vec::new()).await;
        let without_rows = inserted_tables(&server).split_off(initialized);
        write_staged(&storage, vec![sets(&storage, &["a"])]).await;
        let mut with_rows = inserted_tables(&server).split_off(initialized + without_rows.len());
        with_rows.sort();

        assert_eq!(
            (without_rows, with_rows),
            (
                vec!["envio_checkpoints".to_string()],
                vec![
                    "envio_chains".to_string(),
                    "envio_checkpoints".to_string(),
                    "envio_history_Account".to_string()
                ]
            )
        );
    }

    /// What a database a run stopped cleanly at checkpoint 7 answers.
    fn after_a_clean_stop(statement: &str) -> (u16, String) {
        if statement.contains("_envio_holds") {
            (
                200,
                "envio_history_Account\t0\nenvio_checkpoints\t0".to_string(),
            )
        } else if statement.contains("max(`version`)") {
            (200, "3".to_string())
        } else if statement.contains("FROM `mock`.`envio_checkpoints`") {
            (200, "1\t7".to_string())
        } else {
            (200, String::new())
        }
    }

    fn resume_at_checkpoint_7() -> Resume {
        Resume {
            committed: vec![ResumedChain {
                id: 1,
                start_block: 0,
                end_block: None,
                max_reorg_depth: 0,
                first_event_block: None,
                ready_at: None,
                events_processed: 0.0,
                progress_block: 10,
                progress_block_time: None,
                source_block: 10,
                checkpoint_id: 7,
            }],
        }
    }

    /// An insert a previous run left running can land after the trim. One
    /// that can't be stopped leaves the resume nothing safe to do but wait
    /// for a later start.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_resume_refuses_when_it_cannot_stop_what_a_previous_run_left_running() {
        let server = MockClickHouse::answering_statements(Arc::new(|statement: &str| {
            if statement.starts_with("KILL QUERY") {
                (
                    500,
                    "Code: 497. DB::Exception: Not enough privileges. (ACCESS_DENIED)".to_string(),
                )
            } else {
                after_a_clean_stop(statement)
            }
        }))
        .await;
        let storage = storage_at(&server);
        let resumed = storage.resume(&resume_at_checkpoint_7()).await;

        assert_eq!(
            resumed.map_err(|error| format!("{error:#}").contains("ACCESS_DENIED")),
            Err(true)
        );
    }

    /// A replica that hasn't fetched the chains' rows yet reads an older
    /// version, and the resume's frontier rows would lose to the ones it
    /// hasn't fetched.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_replicated_resume_waits_for_the_chains_rows_too() {
        let server = MockClickHouse::answering_statements(Arc::new(after_a_clean_stop)).await;
        let storage = storage_with(&server, true);

        storage.resume(&resume_at_checkpoint_7()).await.unwrap();

        let mut synced = server
            .statements_seen()
            .into_iter()
            .filter(|statement| statement.starts_with("SYSTEM SYNC REPLICA"))
            .collect::<Vec<_>>();
        synced.sort();
        assert_eq!(
            synced,
            vec![
                "SYSTEM SYNC REPLICA `mock`.`envio_chains` LIGHTWEIGHT".to_string(),
                "SYSTEM SYNC REPLICA `mock`.`envio_checkpoints` LIGHTWEIGHT".to_string(),
                "SYSTEM SYNC REPLICA `mock`.`envio_history_Account` LIGHTWEIGHT".to_string(),
            ]
        );
    }

    /// A restart after a clean stop finds nothing above the frontier, so it
    /// schedules no mutation: each one rewrites parts.
    #[tokio::test(flavor = "multi_thread")]
    async fn resuming_after_a_clean_stop_rewrites_nothing() {
        let server = MockClickHouse::answering_statements(Arc::new(after_a_clean_stop)).await;
        let storage = storage_at(&server);
        storage.resume(&resume_at_checkpoint_7()).await.unwrap();
        assert_eq!(
            (
                server
                    .statements_seen()
                    .iter()
                    .filter(|statement| statement.starts_with("ALTER"))
                    .count(),
                inserted_tables(&server),
            ),
            (0, vec!["envio_chains".to_string()])
        );
    }
}
