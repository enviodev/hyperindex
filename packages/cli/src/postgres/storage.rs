//! The indexer's Postgres storage: every statement it runs, and the
//! transactions they run in.
//!
//! JavaScript keeps what only it can do — reading entity values out of its own
//! objects into staged arenas, and decoding rows back into them — and hands
//! each storage operation over in one call. Everything between, from the SQL to
//! which failure in a batch is the one worth reporting, happens here.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use anyhow::{anyhow, bail, Context, Result};
use futures_util::future::{join_all, BoxFuture};
use tokio_postgres::Row;

use crate::columnar::ColumnKind;

use super::client::{PgClient, Transaction};
use super::ddl::{create_partition_query, create_table_query, ColumnSpec, TableSpec};
use super::error::sql_state;
use super::history::{
    History, Sequence, CHANGE_COLUMN, CHANGE_TYPE, CHECKPOINT_COLUMN, DELETE, SET,
};
use super::index_definition::IndexDefinition;
use super::indexes::{IndexEvent, Indexes, Report};
use super::insert::{self, Constant};
use super::internal;
use super::param::Param;
use super::pg_type::{pg_field_type, ChainIdMode, FieldType};
use super::rows::into_result;
use super::select;
use super::write;
use crate::entity_filter::Condition;
use crate::storage::rows::ResultSet;
use crate::storage::types::{
    Addresses, Bounds, CacheTable, ChainMeta, Checkpoints, Frontier, Progress, ProgressDiff,
    ReorgCheckpoint, ResumedChain, StoredChain, StoredConfig,
};
use crate::storage::{
    self as composite, AddChain, Backend, Batch, CacheDump, CacheFile, EntityWrite, Failure, Gate,
    Initialize, Op, PgEntityWrite, Resume, Resumed, RollbackWrite, Rows, StoredConfigRead,
    WriteError,
};

pub struct Settings {
    pub pg_schema: String,
    /// Only for the GRANT the schema is created with.
    pub pg_user: String,
    pub chain_id_mode: ChainIdMode,
    /// Hasura cannot read a `numeric[]`, so a schema it tracks stores those as
    /// `text[]` (issue #788).
    pub numeric_array_as_text: bool,
}

/// What a registered table is to the storage.
pub struct TableRegistration {
    pub spec: TableSpec,
    /// The columns a batch's rows carry, by name, in the order JavaScript lays
    /// them out — which is the order its schema emits them, not the table's.
    pub write_columns: Vec<String>,
    /// Raw events are only ever appended, so a row already there is one the
    /// batch has seen before rather than one to overwrite.
    pub append_only: bool,
    /// An entity's: where its history goes, and which column names its chain.
    pub history: Option<HistoryRegistration>,
}

pub struct HistoryRegistration {
    pub table_name: String,
    pub chain_id_column: Option<String>,
}

pub struct Table {
    pub spec: TableSpec,
    write: TableSpec,
    append_only: bool,
    /// The slot each write column travels in, when the table can be staged. A
    /// column of arrays has none: unnesting it would spread it across the rows,
    /// so such a table binds a parameter per cell instead.
    pub kinds: Option<Vec<ColumnKind>>,
    entity: Option<Entity>,
}

struct Entity {
    history: History,
    history_spec: TableSpec,
    /// The write columns as history declares them, plus the checkpoint.
    history_write: TableSpec,
}

const SET_CHANGE: [Constant<'static>; 1] = [Constant {
    column: CHANGE_COLUMN,
    literal: "'SET'",
}];

impl Table {
    fn new(registration: TableRegistration, settings: &Settings) -> Result<Self> {
        let TableRegistration {
            spec,
            write_columns,
            append_only,
            history,
        } = registration;
        let write = TableSpec {
            table_name: spec.table_name.clone(),
            columns: write_columns
                .iter()
                .map(|name| {
                    spec.columns
                        .iter()
                        .find(|column| &column.name == name)
                        .cloned()
                        .ok_or_else(|| {
                            anyhow!("`{name}` is not a column of \"{}\"", spec.table_name)
                        })
                })
                .collect::<Result<_>>()?,
            partition_by_column: None,
        };
        let kinds = write
            .columns
            .iter()
            .all(|column| !column.is_array)
            .then(|| {
                write
                    .columns
                    .iter()
                    .map(|column| insert::staged_kind(&column.field_type))
                    .collect()
            });
        let entity = history
            .map(|history| Entity::new(&spec, &write, history, settings))
            .transpose()?;
        Ok(Self {
            spec,
            write,
            append_only,
            kinds,
            entity,
        })
    }

    pub fn name(&self) -> &str {
        &self.spec.table_name
    }

    pub fn write_column_names(&self) -> Vec<String> {
        self.write.columns.iter().map(|c| c.name.clone()).collect()
    }

    fn entity(&self) -> Result<&Entity> {
        self.entity
            .as_ref()
            .ok_or_else(|| anyhow!("\"{}\" is not an entity table", self.spec.table_name))
    }
}

impl Entity {
    fn new(
        spec: &TableSpec,
        write: &TableSpec,
        registration: HistoryRegistration,
        settings: &Settings,
    ) -> Result<Self> {
        let is_key = |column: &ColumnSpec| {
            column.name == "id" || registration.chain_id_column.as_deref() == Some(&column.name)
        };
        // Every data column takes NULL, which is what a delete row holds;
        // the key is what identifies the row, so it never does.
        let as_history = |column: &ColumnSpec| ColumnSpec {
            is_nullable: !is_key(column),
            is_primary_key: is_key(column),
            ..column.clone()
        };
        let checkpoint = ColumnSpec {
            name: CHECKPOINT_COLUMN.to_string(),
            field_type: FieldType::UInt64,
            is_array: false,
            is_nullable: false,
            is_primary_key: true,
            default_value: None,
        };
        let change = ColumnSpec {
            name: CHANGE_COLUMN.to_string(),
            field_type: FieldType::Enum {
                name: CHANGE_TYPE.to_string(),
            },
            is_primary_key: false,
            ..checkpoint.clone()
        };
        let id = spec
            .columns
            .iter()
            .find(|column| column.name == "id")
            .ok_or_else(|| anyhow!("\"{}\" has no id column", spec.table_name))?;
        let id_pg_type = pg_field_type(
            &id.field_type,
            &settings.pg_schema,
            false,
            false,
            false,
            settings.chain_id_mode,
        );
        let history_spec = TableSpec {
            table_name: registration.table_name.clone(),
            columns: spec
                .columns
                .iter()
                .map(as_history)
                .chain([checkpoint.clone(), change])
                .collect(),
            partition_by_column: None,
        };
        let history_write = TableSpec {
            table_name: registration.table_name.clone(),
            columns: write
                .columns
                .iter()
                .map(as_history)
                .chain([checkpoint])
                .collect(),
            partition_by_column: None,
        };
        Ok(Self {
            history: History {
                entity_table: spec.table_name.clone(),
                history_table: registration.table_name,
                data_columns: spec.columns.iter().map(|c| c.name.clone()).collect(),
                chain_id_column: registration.chain_id_column,
                id_pg_type,
            },
            history_spec,
            history_write,
        })
    }
}

/// Under one shared sequence every chain is held to the lowest of the ids,
/// bound as `$1`; per chain, the chains and their ids are the two arrays the
/// joined relation unnests.
fn bound_params(bounds: &Bounds) -> Vec<Param> {
    match bounds.sequence {
        Sequence::SharedAcrossChains => vec![Param::Text(bounds.shared_id().to_string())],
        Sequence::PerChain => vec![
            array_literal(bounds.chain_ids.iter().map(|id| Some(id.to_string()))),
            array_literal(bounds.checkpoint_ids.iter().map(|id| Some(id.to_string()))),
        ],
    }
}

fn address_params(addresses: &Addresses, with_registration_blocks: bool) -> Vec<Param> {
    let mut params = vec![
        array_literal(addresses.chain_ids.iter().map(|id| Some(id.to_string()))),
        array_literal(addresses.addresses.iter().map(|bytes| Some(bytea(bytes)))),
        array_literal(addresses.contract_ids.iter().map(|id| Some(id.to_string()))),
    ];
    if with_registration_blocks {
        params.push(array_literal(
            addresses
                .registration_blocks
                .iter()
                .map(|block| Some(block.to_string())),
        ));
    }
    params
}

/// One statement of a batch, pending, and what it reports if it fails.
type Statement<'a> = Pin<Box<dyn Future<Output = std::result::Result<(), Failure>> + Send + 'a>>;

fn pg_table(table: &composite::Table) -> Result<Arc<Table>> {
    table.postgres().cloned()
}

pub struct Storage {
    pub client: PgClient,
    settings: Settings,
    pub indexes: Arc<Indexes<PgClient>>,
}

/// The failure worth reporting out of a transaction's: the first one that is
/// not the aborted-transaction cascade another one set off in every statement
/// after it.
fn first_cause<T>(
    failures: impl IntoIterator<Item = T>,
    error: impl Fn(&T) -> &anyhow::Error,
) -> Option<T> {
    let is_cascade = |failure: &T| sql_state(error(failure)) == Some("25P02");
    let mut failures = failures.into_iter();
    let first = failures.next()?;
    if !is_cascade(&first) {
        return Some(first);
    }
    Some(
        failures
            .find(|failure| !is_cascade(failure))
            .unwrap_or(first),
    )
}

/// The cause among a set of statements' outcomes, if any of them failed.
fn settle<T>(outcomes: Vec<std::result::Result<T, Failure>>) -> std::result::Result<(), Failure> {
    match first_cause(
        outcomes.into_iter().filter_map(|outcome| outcome.err()),
        |failure| &failure.error,
    ) {
        Some(failure) => Err(failure),
        None => Ok(()),
    }
}

impl Storage {
    pub fn new(client: PgClient, settings: Settings, report: Report) -> Self {
        Self {
            indexes: Arc::new(Indexes::new(
                client.clone(),
                settings.pg_schema.clone(),
                report,
            )),
            client,
            settings,
        }
    }

    fn schema(&self) -> &str {
        &self.settings.pg_schema
    }

    pub fn register(&self, registration: TableRegistration) -> Result<Table> {
        Table::new(registration, &self.settings)
    }

    fn create_table(&self, spec: &TableSpec) -> Result<String> {
        create_table_query(
            spec,
            self.schema(),
            self.settings.numeric_array_as_text,
            self.settings.chain_id_mode,
        )
    }

    fn create_partition(&self, partition: &composite::Partition) -> Result<String> {
        Ok(create_partition_query(
            self.schema(),
            partition.table.postgres()?.name(),
            &partition.name,
            partition.chain_id,
        ))
    }

    pub async fn is_initialized(&self) -> Result<bool> {
        // `event_sync_state` is what an envio before 2.28 created.
        let (rows, _) = self
            .client
            .query(
                "SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND \
                 (table_name = 'event_sync_state' OR table_name = $2);",
                &[
                    Param::Text(self.schema().to_string()),
                    Param::Text(internal::CHAINS.to_string()),
                ],
            )
            .await?;
        Ok(!rows.is_empty())
    }

    /// Whether the schema is empty, refusing one that holds anything but an
    /// indexer's tables: initializing drops it.
    pub async fn check_schema_for_initialize(&self) -> Result<bool> {
        let (rows, _) = self
            .client
            .query(
                "SELECT table_name::TEXT FROM information_schema.tables WHERE table_schema = $1;",
                &[Param::Text(self.schema().to_string())],
            )
            .await?;
        let names = rows
            .iter()
            .map(|row| cell::<String>(row, 0))
            .collect::<Result<Vec<_>>>()?;
        if !names.is_empty()
            && !names
                .iter()
                .any(|name| name == internal::CHAINS || name == "event_sync_state")
        {
            bail!(
                "Cannot run Envio migrations on PostgreSQL schema \"{schema}\" because it contains \
                 non-Envio tables. Running migrations would delete all data in this schema.\n\nTo \
                 resolve this:\n1. If you want to use this schema, first backup any important \
                 data, then drop it with: \"pnpm envio local db-migrate down\"\n2. Or specify a \
                 different schema name by setting the \"ENVIO_PG_SCHEMA\" environment variable\n3. \
                 Or manually drop the schema in your database if you're certain the data is not \
                 needed.",
                schema = self.schema()
            );
        }
        Ok(names.is_empty())
    }

    /// Creates the schema from scratch in one transaction, the config record,
    /// contract mapping and config addresses included: a schema never comes up
    /// without the record a resume checks it against.
    ///
    /// Only tables, keys, views and chain rows. The schema's read indexes make
    /// backfill writes far dearer, so they come later, from
    /// `finalizeBackfill`.
    pub async fn initialize(&self, input: &Initialize) -> Result<()> {
        let is_empty_schema = self.check_schema_for_initialize().await?;
        let schema = self.schema();
        let tables = input
            .tables
            .iter()
            .filter_map(|table| table.postgres.clone())
            .collect::<Vec<_>>();
        let mut ddl = Vec::new();
        // A hosted database already has a `public` schema it won't let us
        // drop, so an empty one is reused. `IF NOT EXISTS` covers one that was
        // dropped before.
        if is_empty_schema && schema == "public" {
            ddl.push(format!("CREATE SCHEMA IF NOT EXISTS \"{schema}\";"));
        } else {
            ddl.push(format!(
                "DROP SCHEMA IF EXISTS \"{schema}\" CASCADE;\nCREATE SCHEMA \"{schema}\";"
            ));
        }
        ddl.push(format!(
            "GRANT ALL ON SCHEMA \"{schema}\" TO \"{}\";\nGRANT ALL ON SCHEMA \"{schema}\" TO \
             public;",
            self.settings.pg_user
        ));
        for enum_type in &input.enums {
            ddl.push(format!(
                "CREATE TYPE \"{schema}\".{} AS ENUM({});",
                enum_type.name,
                enum_type
                    .variants
                    .iter()
                    .map(|variant| format!("'{variant}'"))
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
        ddl.push(format!(
            "CREATE TYPE \"{schema}\".{CHANGE_TYPE} AS ENUM('{SET}', '{DELETE}');"
        ));
        for spec in internal::tables(input.sequence) {
            ddl.push(self.create_table(&spec)?);
        }
        for table in &tables {
            ddl.push(self.create_table(&table.spec)?);
        }
        for partition in &input.partitions {
            if partition.table.postgres.is_some() {
                ddl.push(self.create_partition(partition)?);
            }
        }
        // History stays unpartitioned: it is only ever read by checkpoint,
        // never by chain, so partitioning it would route every write and prune
        // nothing.
        for table in &tables {
            if let Some(entity) = &table.entity {
                ddl.push(self.create_table(&entity.history_spec)?);
            }
        }
        ddl.push(internal::views(schema));
        ddl.extend(internal::insert_chains(schema, &input.chains));

        let transaction = self.client.begin().await?;
        let outcome = async {
            transaction.batch(&ddl.join("\n")).await?;
            transaction
                .execute(
                    &internal::write_info(schema),
                    &[Param::Text(input.envio_info.clone())],
                )
                .await?;
            transaction
                .execute(
                    &internal::insert_contracts(schema),
                    &[
                        array_literal(
                            (0..input.contract_names.len()).map(|id| Some(id.to_string())),
                        ),
                        array_literal(input.contract_names.iter().map(|name| Some(name.as_str()))),
                    ],
                )
                .await?;
            self.insert_addresses(&transaction, &input.addresses)
                .await?;
            anyhow::Ok(())
        }
        .await;
        finish(transaction, outcome).await?;
        self.indexes.reload().await
    }

    async fn insert_addresses(
        &self,
        transaction: &Transaction,
        addresses: &Addresses,
    ) -> Result<()> {
        if addresses.chain_ids.is_empty() {
            return Ok(());
        }
        transaction
            .execute(
                &internal::insert_addresses(self.schema(), self.settings.chain_id_mode),
                &address_params(addresses, true),
            )
            .await?;
        Ok(())
    }

    /// Brings a chain the schema doesn't have yet: its partitions, its config
    /// addresses and its row. Only one process ever adds a given chain.
    pub async fn add_chain(&self, input: &AddChain) -> Result<()> {
        let partitions = input
            .partitions
            .iter()
            .filter(|partition| partition.table.postgres.is_some())
            .map(|partition| self.create_partition(partition))
            .collect::<Result<Vec<_>>>()?;
        let transaction = self.client.begin().await?;
        let outcome = async {
            for partition in &partitions {
                transaction.batch(partition).await?;
            }
            self.insert_addresses(&transaction, &input.addresses)
                .await?;
            if let Some(insert) =
                internal::insert_chains(self.schema(), std::slice::from_ref(&input.chain))
            {
                transaction.batch(&insert).await?;
            }
            anyhow::Ok(())
        }
        .await;
        finish(transaction, outcome).await
    }

    /// The record a resume is checked against, and the config addresses it was
    /// written with.
    pub async fn read_stored_config(&self) -> Result<StoredConfigRead> {
        let schema = self.schema();
        let (read_info, read_contracts) = (
            internal::read_info(schema),
            internal::read_contracts(schema),
        );
        let (info, contracts) = futures_util::try_join!(
            missing_as_none(self.client.query(&read_info, &[])),
            missing_as_none(self.client.query(&read_contracts, &[])),
        )?;
        let envio_info = info
            .and_then(|(rows, _)| rows.first().map(|row| cell(row, 0)))
            .transpose()?;
        let contract_names = contracts
            .map(|(rows, _)| rows.iter().map(|row| cell(row, 0)).collect::<Result<_>>())
            .transpose()?;
        // Both join the schema in one transaction. Without either, an older
        // envio wrote it, and the address rows are shaped differently.
        if envio_info.is_none() || contract_names.is_none() {
            return Ok(StoredConfigRead {
                config: StoredConfig {
                    envio_info: None,
                    contract_names: None,
                    chains: vec![],
                },
                config_addresses: into_result(&[], &[])?,
            });
        }
        let (read_chains, read_addresses) = (
            internal::read_stored_chains(schema),
            internal::read_addresses(schema, true),
        );
        let ((chains, _), (addresses, address_columns)) = futures_util::try_join!(
            self.client.query(&read_chains, &[]),
            self.client.query(&read_addresses, &[]),
        )?;
        Ok(StoredConfigRead {
            config: StoredConfig {
                envio_info,
                contract_names,
                chains: chains
                    .iter()
                    .map(|row| {
                        Ok(StoredChain {
                            id: cell(row, 0)?,
                            ecosystem: cell(row, 1)?,
                            start_block: cell(row, 2)?,
                            end_block: cell(row, 3)?,
                            max_reorg_depth: cell(row, 4)?,
                        })
                    })
                    .collect::<Result<_>>()?,
            },
            config_addresses: into_result(&addresses, &address_columns)?,
        })
    }

    pub async fn resume(&self) -> Result<Resumed> {
        let schema = self.schema();
        let (read_chains, read_addresses, read_checkpoints) = (
            internal::read_resumed_chains(schema),
            internal::read_addresses(schema, false),
            internal::read_reorg_checkpoints(schema),
        );
        let ((chains, _), (addresses, address_columns), (checkpoints, _), ()) = futures_util::try_join!(
            self.client.query(&read_chains, &[]),
            self.client.query(&read_addresses, &[]),
            self.client.query(&read_checkpoints, &[]),
            self.indexes.reload(),
        )?;
        Ok(Resumed {
            chains: chains
                .iter()
                .map(|row| {
                    Ok(ResumedChain {
                        id: cell(row, 0)?,
                        start_block: cell(row, 1)?,
                        end_block: cell(row, 2)?,
                        max_reorg_depth: cell(row, 3)?,
                        first_event_block: cell(row, 4)?,
                        ready_at: cell(row, 5)?,
                        events_processed: cell(row, 6)?,
                        progress_block: cell(row, 7)?,
                        progress_block_time: cell(row, 8)?,
                        source_block: cell(row, 9)?,
                        checkpoint_id: cell(row, 10)?,
                        ecosystem: cell(row, 11)?,
                    })
                })
                .collect::<Result<_>>()?,
            addresses: into_result(&addresses, &address_columns)?,
            reorg_checkpoints: checkpoints
                .iter()
                .map(|row| {
                    Ok(ReorgCheckpoint {
                        id: cell(row, 0)?,
                        chain_id: cell(row, 1)?,
                        block_number: cell(row, 2)?,
                        block_hash: cell(row, 3)?,
                    })
                })
                .collect::<Result<_>>()?,
        })
    }

    pub async fn set_chain_meta(&self, chains: &[ChainMeta]) -> Result<()> {
        let sql = internal::set_meta(self.schema());
        let params = chains.iter().map(meta_params).collect::<Vec<_>>();
        let updates = params
            .iter()
            .map(|params| self.client.execute(&sql, params));
        for outcome in join_all(updates).await {
            outcome?;
        }
        Ok(())
    }

    /// One transaction for every chain: they caught up together, and a crash
    /// part way through would leave some stamped and some not.
    pub async fn set_ready_at(&self, chain_ids: &[i64], ready_at: f64) -> Result<()> {
        let sql = internal::set_ready_at(self.schema());
        let transaction = self.client.begin().await?;
        let outcome = async {
            for chain_id in chain_ids {
                transaction
                    .execute(
                        &sql,
                        &[
                            Param::Text(ready_at.to_string()),
                            Param::Text(chain_id.to_string()),
                        ],
                    )
                    .await?;
            }
            anyhow::Ok(())
        }
        .await;
        finish(transaction, outcome).await
    }

    /// Each index commits on its own rather than in one transaction with `ready_at`: a
    /// build that dies half way through a large schema would otherwise roll
    /// back every index before it and make the retry start over. Readiness is
    /// stamped only once every one is verified, so a crash either leaves it
    /// unset and the retry finds the indexes built, or commits readiness the
    /// schema backs.
    pub async fn finalize_backfill(
        &self,
        definitions: Vec<IndexDefinition>,
        chain_ids: &[i64],
        ready_at: f64,
    ) -> Result<()> {
        let start = std::time::Instant::now();
        let built = self.indexes.finalize(definitions).await?;
        self.set_ready_at(chain_ids, ready_at).await?;
        // Only when something was built: the wait this closes is the build,
        // and the stamp on its own is not one anybody waited through.
        if built > 0 {
            self.indexes.report(IndexEvent::Committed {
                count: built as u32,
                seconds: start.elapsed().as_secs_f64(),
            });
        }
        Ok(())
    }

    pub async fn prune_checkpoints(&self, bounds: &Bounds) -> Result<()> {
        self.client
            .execute(
                &internal::prune_checkpoints(self.schema(), bounds.sequence)?,
                &bound_params(bounds),
            )
            .await?;
        Ok(())
    }

    pub async fn prune_history(&self, table: &Table, bounds: &Bounds) -> Result<()> {
        let entity = table.entity()?;
        self.client
            .execute(
                &entity.history.prune(self.schema(), bounds.sequence)?,
                &bound_params(bounds),
            )
            .await?;
        Ok(())
    }

    pub async fn rollback_target_checkpoint(
        &self,
        chain_id: i64,
        block_number: i32,
    ) -> Result<Option<i64>> {
        let (rows, _) = self
            .client
            .query(
                &internal::rollback_target_checkpoint(self.schema()),
                &[
                    Param::Text(chain_id.to_string()),
                    Param::Text(block_number.to_string()),
                ],
            )
            .await?;
        rows.first()
            .map(|row| {
                let id: String = cell(row, 0)?;
                id.parse()
                    .with_context(|| format!("`{id}` is not a checkpoint id"))
            })
            .transpose()
    }

    pub async fn rollback_progress_diff(&self, bounds: &Bounds) -> Result<Vec<ProgressDiff>> {
        let (rows, _) = self
            .client
            .query(
                &internal::rollback_progress_diff(self.schema(), bounds.sequence)?,
                &bound_params(bounds),
            )
            .await?;
        rows.iter()
            .map(|row| {
                Ok(ProgressDiff {
                    chain_id: cell(row, 0)?,
                    events_processed: cell(row, 1)?,
                    progress_block: cell(row, 2)?,
                })
            })
            .collect()
    }

    /// The ids a rollback removes, and the history rows it restores from.
    pub async fn rollback_data(
        &self,
        table: &Table,
        bounds: &Bounds,
    ) -> Result<(ResultSet, ResultSet)> {
        let history = &table.entity()?.history;
        let params = bound_params(bounds);
        let removed = history.removed_ids(self.schema(), bounds.sequence)?;
        let restored = history.pre_target_rows(self.schema(), bounds.sequence)?;
        let ((removed, removed_columns), (restored, restored_columns)) = futures_util::try_join!(
            self.client.query(&removed, &params),
            self.client.query(&restored, &params),
        )?;
        Ok((
            into_result(&removed, &removed_columns)?,
            into_result(&restored, &restored_columns)?,
        ))
    }

    pub async fn effect_cache_tables(&self) -> Result<Vec<CacheTable>> {
        let schema = self.schema();
        let (rows, _) = self
            .client
            .query(&internal::effect_cache_tables(schema), &[])
            .await?;
        let names = rows
            .iter()
            .map(|row| cell::<String>(row, 0))
            .collect::<Result<Vec<_>>>()?;
        let counts_sql = names
            .iter()
            .map(|name| internal::count_rows(schema, name))
            .collect::<Vec<_>>();
        let counts = join_all(counts_sql.iter().map(|sql| self.client.query(sql, &[]))).await;
        names
            .into_iter()
            .zip(counts)
            .map(|(table_name, counted)| {
                let (rows, _) = counted?;
                Ok(CacheTable {
                    table_name,
                    rows: rows.first().map_or(Ok(0), |row| cell(row, 0))?,
                })
            })
            .collect()
    }

    pub async fn upload_effect_cache(&self, files: &[CacheFile]) -> Result<()> {
        let schema = self.schema();
        let uploads = files.iter().map(|file| async move {
            let table = file.table.postgres()?;
            self.client.batch(&self.create_table(&table.spec)?).await?;
            self.client
                .copy_in(
                    &format!(
                        "COPY \"{schema}\".\"{}\" FROM STDIN WITH (FORMAT text, HEADER)",
                        table.name()
                    ),
                    &file.path,
                )
                .await
                .with_context(|| format!("Failed uploading {}", file.path))
        });
        for outcome in join_all(uploads).await {
            outcome?;
        }
        Ok(())
    }

    /// Each table to its file, the directories a chain's caches go in created
    /// as needed.
    pub async fn dump_effect_cache(&self, files: &[CacheDump]) -> Result<()> {
        let schema = self.schema();
        let dumps = files
            .iter()
            .map(|CacheDump { table_name, path }| async move {
                if let Some(directory) = std::path::Path::new(path).parent() {
                    tokio::fs::create_dir_all(directory)
                        .await
                        .with_context(|| format!("Failed creating {}", directory.display()))?;
                }
                self.client
                    .copy_out(
                        &format!(
                            "COPY {}.{} TO STDOUT WITH (FORMAT text, HEADER)",
                            internal::quote_ident(schema),
                            internal::quote_ident(table_name)
                        ),
                        path,
                    )
                    .await
            });
        for outcome in join_all(dumps).await {
            outcome?;
        }
        Ok(())
    }

    pub async fn load_where(
        &self,
        table_name: &str,
        conditions: Vec<Condition>,
    ) -> Result<ResultSet> {
        let (sql, params) = select::load_query(self.schema(), table_name, conditions)?;
        let (rows, columns) = self.client.query(&sql, &params).await?;
        into_result(&rows, &columns)
    }

    pub async fn reset(&self) -> Result<()> {
        self.client
            .batch(&format!(
                "DROP SCHEMA IF EXISTS \"{}\" CASCADE;",
                self.schema()
            ))
            .await?;
        // The schema's types are gone with it, and a statement prepared against
        // them cannot be executed again.
        self.client.forget_prepared();
        Ok(())
    }

    /// Writes a batch in one transaction, and the effect caches beside it.
    ///
    /// The caches stay outside: they are never rolled back, and keeping them
    /// out keeps their writes off the connection the batch holds.
    ///
    /// Nothing commits unless every statement succeeded and the gate, if there
    /// is one, says the other store wrote its half.
    pub async fn write_batch(
        &self,
        batch: Batch,
        gate: Option<Gate>,
    ) -> std::result::Result<(), WriteError> {
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
        let transactional = async {
            let transaction =
                self.client.begin().await.map_err(|error| {
                    Failure::new("Failed opening the batch's transaction", error)
                })?;
            let outcome = async {
                if let Some(rollback) = &rollback {
                    self.write_rollback(&transaction, rollback).await?;
                }
                self.write_changes(
                    &transaction,
                    &progress,
                    raw_events.as_ref(),
                    &entities,
                    &chain_meta,
                    &addresses,
                    &frontier,
                    &checkpoints,
                )
                .await?;
                if let Some(gate) = gate {
                    if !gate.await {
                        return Err(WriteError::Gated);
                    }
                }
                Ok(())
            }
            .await;
            match outcome {
                Ok(()) => transaction
                    .commit()
                    .await
                    .map_err(|error| Failure::new("Failed committing the batch", error).into()),
                Err(error) => {
                    // The statement that failed is what to report; a rollback
                    // failing after it would only say the connection is gone.
                    let _ = transaction.rollback().await;
                    Err(error)
                }
            }
        };
        let caches = async {
            let writes = effect_caches.iter().map(|write| async move {
                let table = pg_table(&write.table)
                    .map_err(|error| Failure::new(insert_context(&write.table.name), error))?;
                if write.create {
                    let create = self
                        .create_table(&table.spec)
                        .map_err(|error| Failure::new(insert_context(table.name()), error))?;
                    self.client
                        .batch(&create)
                        .await
                        .map_err(|error| Failure::new(insert_context(table.name()), error))?;
                }
                self.insert(None, &table, &write.rows).await
            });
            settle(join_all(writes).await)
        };
        let (written, cached) = tokio::join!(transactional, caches);
        written?;
        Ok(cached?)
    }

    async fn write_rollback(
        &self,
        transaction: &Transaction,
        rollback: &RollbackWrite,
    ) -> std::result::Result<(), Failure> {
        let schema = self.schema();
        let params = bound_params(&rollback.bounds);
        let mut statements = Vec::new();
        for table in rollback
            .tables
            .iter()
            .filter_map(|table| table.postgres.as_ref())
        {
            let sql = table
                .entity()
                .and_then(|entity| entity.history.rollback(schema, rollback.bounds.sequence))
                .map_err(|error| Failure::new("Failed rolling back the history", error))?;
            statements.push((
                format!("Failed rolling back the history of \"{}\"", table.name()),
                sql,
                params.clone(),
            ));
        }
        statements.push((
            "Failed rolling back the checkpoints".to_string(),
            internal::rollback_checkpoints(schema, rollback.bounds.sequence)
                .map_err(|error| Failure::new("Failed rolling back the checkpoints", error))?,
            params.clone(),
        ));
        // Before the batch's own progress write, so a chain the batch also
        // progressed keeps the batch's later value.
        let progress_sql = internal::set_progress(schema);
        for progress in &rollback.progress {
            statements.push((
                "Failed rolling back the chains' progress".to_string(),
                progress_sql.clone(),
                progress_params(progress),
            ));
        }
        // Before the batch's own inserts, so an address registered again lands
        // after its old row is gone.
        if !rollback.removed_addresses.chain_ids.is_empty() {
            statements.push((
                "Failed rolling back the registered addresses".to_string(),
                internal::delete_addresses(schema, self.settings.chain_id_mode),
                address_params(&rollback.removed_addresses, false),
            ));
        }
        settle(
            join_all(statements.iter().map(|(context, sql, params)| async move {
                transaction
                    .execute(sql, params)
                    .await
                    .map_err(|error| Failure::new(context.clone(), error))
            }))
            .await,
        )
    }

    #[allow(clippy::too_many_arguments)]
    async fn write_changes(
        &self,
        transaction: &Transaction,
        progress: &[Progress],
        raw_events: Option<&composite::TableWrite>,
        entities: &[EntityWrite],
        chain_meta: &[ChainMeta],
        addresses: &Addresses,
        frontier: &Frontier,
        checkpoints: &Checkpoints,
    ) -> std::result::Result<(), Failure> {
        let schema = self.schema();
        let chain_id_mode = self.settings.chain_id_mode;
        let mut statements: Vec<Statement<'_>> = Vec::new();
        let run = |context: String, sql: String, params: Vec<Param>| {
            Box::pin(async move {
                transaction
                    .execute(&sql, &params)
                    .await
                    .map(|_| ())
                    .map_err(|error| Failure::new(context, error))
            }) as Statement<'_>
        };

        let progress_sql = internal::set_progress(schema);
        for progress in progress {
            statements.push(run(
                "Failed writing the chains' progress".to_string(),
                progress_sql.clone(),
                progress_params(progress),
            ));
        }
        if let Some(write) = raw_events {
            let table = pg_table(&write.table)
                .map_err(|error| Failure::new(insert_context(&write.table.name), error))?;
            statements.push(Box::pin(async move {
                self.insert(Some(transaction), &table, &write.rows).await
            }));
        }
        for write in entities {
            if let Some(rows) = &write.postgres {
                let table = pg_table(&write.table)
                    .map_err(|error| Failure::new(insert_context(&write.table.name), error))?;
                statements.push(Box::pin(async move {
                    self.write_entity(transaction, &table, write.chain_id, rows)
                        .await
                }));
            }
        }
        let meta_sql = internal::set_meta(schema);
        for meta in chain_meta {
            statements.push(run(
                "Failed writing the chains' metadata".to_string(),
                meta_sql.clone(),
                meta_params(meta),
            ));
        }
        if !addresses.chain_ids.is_empty() {
            statements.push(run(
                "Failed writing the registered addresses".to_string(),
                internal::insert_addresses(schema, chain_id_mode),
                address_params(addresses, true),
            ));
        }
        if !frontier.chain_ids.is_empty() {
            statements.push(run(
                "Failed writing the chains' checkpoint".to_string(),
                internal::set_frontier(schema, chain_id_mode),
                vec![
                    array_literal(frontier.chain_ids.iter().map(|id| Some(id.to_string()))),
                    array_literal(
                        frontier
                            .checkpoint_ids
                            .iter()
                            .map(|id| Some(id.to_string())),
                    ),
                ],
            ));
        }
        // Only the checkpoints a rollback can reach back to: those anchoring
        // history a chain keeps.
        let checkpoints = checkpoints.keeping_history();
        if !checkpoints.ids.is_empty() {
            statements.push(run(
                "Failed writing the checkpoints".to_string(),
                internal::insert_checkpoints(schema, chain_id_mode),
                vec![
                    array_literal(checkpoints.ids.iter().map(|id| Some(id.to_string()))),
                    array_literal(checkpoints.chain_ids.iter().map(|id| Some(id.to_string()))),
                    array_literal(
                        checkpoints
                            .block_numbers
                            .iter()
                            .map(|block| Some(block.to_string())),
                    ),
                    array_literal(checkpoints.block_hashes.iter().map(Option::as_ref)),
                    array_literal(
                        checkpoints
                            .events_processed
                            .iter()
                            .map(|count| Some(count.to_string())),
                    ),
                ],
            ));
        }

        settle(join_all(statements).await)
    }

    /// One entity's share of the batch. The backfill runs first: it copies the
    /// rows the other statements are about to change.
    async fn write_entity(
        &self,
        transaction: &Transaction,
        table: &Table,
        chain_id: Option<i64>,
        write: &PgEntityWrite,
    ) -> std::result::Result<(), Failure> {
        let schema = self.schema();
        let entity = table
            .entity()
            .map_err(|error| Failure::new(insert_context(table.name()), error))?;
        let history_context = || format!("Failed writing the history of \"{}\"", table.name());

        let mut statements: Vec<Statement<'_>> = Vec::new();
        if let Some(history) = &write.history {
            if !history.backfill.is_empty() {
                transaction
                    .execute(
                        &entity.history.backfill(schema, chain_id),
                        &[array_literal(history.backfill.iter().map(Some))],
                    )
                    .await
                    .map_err(|error| Failure::new(history_context(), error))?;
            }
            if !history.delete_ids.is_empty() {
                let mut params = vec![
                    array_literal(history.delete_ids.iter().map(Some)),
                    array_literal(history.delete_checkpoint_ids.iter().map(Some)),
                ];
                let chain_id = chain_id.filter(|_| entity.history.chain_id_column.is_some());
                if let Some(chain_id) = chain_id {
                    params.push(Param::Text(chain_id.to_string()));
                }
                let sql = entity
                    .history
                    .insert_delete_rows(schema, chain_id.is_some());
                statements.push(Box::pin(async move {
                    transaction
                        .execute(&sql, &params)
                        .await
                        .map(|_| ())
                        .map_err(|error| Failure::new(history_context(), error))
                }));
            }
            if let Some((rows, checkpoint_ids)) = &history.sets {
                statements.push(Box::pin(self.insert_history(
                    transaction,
                    table,
                    entity,
                    rows,
                    checkpoint_ids,
                )));
            }
        }
        if let Some(rows) = &write.sets {
            statements.push(Box::pin(self.insert(Some(transaction), table, rows)));
        }
        if !write.deletes.is_empty() {
            let sql = entity.history.delete_entities(schema, chain_id);
            let params = vec![array_literal(write.deletes.iter().map(Some))];
            statements.push(Box::pin(async move {
                transaction
                    .execute(&sql, &params)
                    .await
                    .map(|_| ())
                    .map_err(|error| {
                        Failure::new(
                            format!("Failed deleting \"{}\" from storage by ids", table.name()),
                            error,
                        )
                    })
            }));
        }
        settle(join_all(statements).await)
    }

    /// Inserts rows into a table, in the transaction when there is one.
    async fn insert(
        &self,
        transaction: Option<&Transaction>,
        table: &Table,
        rows: &Rows,
    ) -> std::result::Result<(), Failure> {
        let fail = |error| Failure::new(insert_context(table.name()), error);
        let statements = match rows {
            Rows::Staged(arena) => vec![(
                insert::unnest_query(
                    &table.write,
                    self.schema(),
                    &[],
                    table.append_only,
                    self.settings.chain_id_mode,
                ),
                write::unnest_params(arena).map_err(fail)?,
                Shape::Recurring,
            )],
            Rows::Cells { cells, rows } => {
                chunked_cells(cells, *rows, table.write.columns.len(), &[], |count| {
                    insert::values_query(&table.write, self.schema(), &[], count)
                })
                .map_err(fail)?
            }
        };
        self.run_all(transaction, statements).await.map_err(fail)
    }

    /// A set's history row: the same values the entity's insert takes, plus
    /// the checkpoint the change happened at.
    async fn insert_history(
        &self,
        transaction: &Transaction,
        table: &Table,
        entity: &Entity,
        rows: &Rows,
        checkpoint_ids: &[String],
    ) -> std::result::Result<(), Failure> {
        let fail = |error| Failure::new(insert_context(&entity.history.history_table), error);
        if checkpoint_ids.len() != rows.len() {
            return Err(fail(anyhow!(
                "{} history rows came with {} checkpoints",
                rows.len(),
                checkpoint_ids.len()
            )));
        }
        let statements = match rows {
            Rows::Staged(arena) => {
                let mut params = write::unnest_params(arena).map_err(fail)?;
                params.push(array_literal(checkpoint_ids.iter().map(Some)));
                vec![(
                    insert::unnest_query(
                        &entity.history_write,
                        self.schema(),
                        &SET_CHANGE,
                        false,
                        self.settings.chain_id_mode,
                    ),
                    params,
                    Shape::Recurring,
                )]
            }
            Rows::Cells { cells, rows } => {
                let checkpoints = checkpoint_ids
                    .iter()
                    .map(|id| Param::Text(id.clone()))
                    .collect::<Vec<_>>();
                chunked_cells(
                    cells,
                    *rows,
                    table.write.columns.len(),
                    &checkpoints,
                    |count| {
                        insert::values_query(
                            &entity.history_write,
                            self.schema(),
                            &SET_CHANGE,
                            count,
                        )
                    },
                )
                .map_err(fail)?
            }
        };
        self.run_all(Some(transaction), statements)
            .await
            .map_err(fail)
    }

    async fn run_all(
        &self,
        transaction: Option<&Transaction>,
        statements: Vec<(String, Vec<Param>, Shape)>,
    ) -> Result<()> {
        let outcomes = join_all(statements.iter().map(|(sql, params, shape)| async move {
            match (transaction, shape) {
                (Some(transaction), Shape::Recurring) => transaction.execute(sql, params).await,
                (Some(transaction), Shape::Once) => transaction.execute_once(sql, params).await,
                (None, Shape::Recurring) => self.client.execute(sql, params).await,
                (None, Shape::Once) => self.client.execute_once(sql, params).await,
            }
        }))
        .await;
        match first_cause(outcomes.into_iter().filter_map(Result::err), |error| error) {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }
}

impl Backend for Storage {
    fn name(&self) -> &'static str {
        "postgres"
    }

    fn check_for_initialize(&self) -> Op<'_, ()> {
        Box::pin(async move { self.check_schema_for_initialize().await.map(|_| ()) })
    }

    fn initialize<'a>(&'a self, input: &'a Initialize) -> Op<'a, ()> {
        Box::pin(Storage::initialize(self, input))
    }

    fn add_chain<'a>(&'a self, input: &'a AddChain) -> Op<'a, ()> {
        Box::pin(Storage::add_chain(self, input))
    }

    fn read_stored_config(&self) -> Op<'_, StoredConfigRead> {
        Box::pin(Storage::read_stored_config(self))
    }

    fn resume<'a>(&'a self, _input: &'a Resume) -> Op<'a, Resumed> {
        Box::pin(Storage::resume(self))
    }

    fn load_where<'a>(
        &'a self,
        table: &'a composite::Table,
        conditions: Vec<Condition>,
    ) -> Op<'a, ResultSet> {
        Box::pin(async move {
            let table = table.postgres()?;
            Storage::load_where(self, table.name(), conditions).await
        })
    }

    fn set_chain_meta<'a>(&'a self, chains: &'a [ChainMeta]) -> Op<'a, ()> {
        Box::pin(Storage::set_chain_meta(self, chains))
    }

    fn finalize_backfill<'a>(
        &'a self,
        indexes: Vec<IndexDefinition>,
        chain_ids: &'a [i64],
        ready_at: f64,
    ) -> Op<'a, ()> {
        Box::pin(Storage::finalize_backfill(
            self, indexes, chain_ids, ready_at,
        ))
    }

    fn prune_checkpoints<'a>(&'a self, bounds: &'a Bounds) -> Op<'a, ()> {
        Box::pin(Storage::prune_checkpoints(self, bounds))
    }

    fn prune_history<'a>(&'a self, table: &'a composite::Table, bounds: &'a Bounds) -> Op<'a, ()> {
        Box::pin(async move { Storage::prune_history(self, table.postgres()?, bounds).await })
    }

    fn rollback_target_checkpoint(&self, chain_id: i64, block_number: i32) -> Op<'_, Option<i64>> {
        Box::pin(Storage::rollback_target_checkpoint(
            self,
            chain_id,
            block_number,
        ))
    }

    fn rollback_progress_diff<'a>(&'a self, bounds: &'a Bounds) -> Op<'a, Vec<ProgressDiff>> {
        Box::pin(Storage::rollback_progress_diff(self, bounds))
    }

    fn rollback_data<'a>(
        &'a self,
        table: &'a composite::Table,
        bounds: &'a Bounds,
    ) -> Op<'a, (ResultSet, ResultSet)> {
        Box::pin(async move { Storage::rollback_data(self, table.postgres()?, bounds).await })
    }

    fn effect_cache_tables(&self) -> Op<'_, Vec<CacheTable>> {
        Box::pin(Storage::effect_cache_tables(self))
    }

    fn upload_effect_cache<'a>(&'a self, files: &'a [CacheFile]) -> Op<'a, ()> {
        Box::pin(Storage::upload_effect_cache(self, files))
    }

    fn dump_effect_cache<'a>(&'a self, files: &'a [CacheDump]) -> Op<'a, ()> {
        Box::pin(Storage::dump_effect_cache(self, files))
    }

    fn reset(&self) -> Op<'_, ()> {
        Box::pin(Storage::reset(self))
    }

    fn write_batch(
        &self,
        batch: Batch,
        gate: Option<Gate>,
    ) -> BoxFuture<'_, std::result::Result<(), WriteError>> {
        Box::pin(Storage::write_batch(self, batch, gate))
    }

    fn close(&self) {
        self.client.close();
    }
}

/// A cell as the type its reader expects, or an error naming the column. A
/// schema holding something else would otherwise panic, which reaches
/// JavaScript as "Panic in async function" and nothing more.
pub(super) fn cell<'a, T: tokio_postgres::types::FromSql<'a>>(
    row: &'a Row,
    index: usize,
) -> Result<T> {
    row.try_get(index).with_context(|| {
        let column = row.columns().get(index).map_or("?", |column| column.name());
        format!("Failed reading the stored \"{column}\" column")
    })
}

fn insert_context(table_name: &str) -> String {
    format!("Failed to insert items into table \"{table_name}\"")
}

/// Whether a statement's text recurs. One that does is kept prepared on its
/// connection; one that doesn't is sent unnamed, so the server keeps no plan for
/// a shape it won't see again.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Shape {
    Recurring,
    Once,
}

/// The statements for rows bound a parameter per cell, as many rows to each
/// as its parameters allow. `cells` holds every row's first column, then every
/// row's second; `extra` is one more column, appended after them.
///
/// Only a full chunk recurs: a short last one spells out however many rows the
/// batch had left, and there are as many such statements as chunk lengths.
fn chunked_cells(
    cells: &[Param],
    rows: usize,
    columns: usize,
    extra: &[Param],
    query: impl Fn(usize) -> String,
) -> Result<Vec<(String, Vec<Param>, Shape)>> {
    if cells.len() != rows * columns {
        bail!(
            "{} cells came for {rows} rows of {columns} columns",
            cells.len()
        );
    }
    let all_columns = columns + usize::from(!extra.is_empty());
    let per_statement = insert::values_rows_per_statement(all_columns);
    Ok((0..rows)
        .step_by(per_statement)
        .map(|start| {
            let end = (start + per_statement).min(rows);
            let mut params = Vec::with_capacity((end - start) * all_columns);
            for column in 0..columns {
                params.extend_from_slice(&cells[column * rows + start..column * rows + end]);
            }
            if !extra.is_empty() {
                params.extend_from_slice(&extra[start..end]);
            }
            let shape = if end - start == per_statement {
                Shape::Recurring
            } else {
                Shape::Once
            };
            (query(end - start), params, shape)
        })
        .collect::<Vec<_>>())
}

fn progress_params(progress: &Progress) -> Vec<Param> {
    vec![
        Param::Text(progress.chain_id.to_string()),
        Param::Text(progress.progress_block.to_string()),
        progress
            .progress_block_time
            .map_or(Param::Null, |time| Param::Text(time.to_string())),
        Param::Text(progress.events_processed.to_string()),
        Param::Text(progress.source_block.to_string()),
    ]
}

fn meta_params(meta: &ChainMeta) -> Vec<Param> {
    vec![
        Param::Text(meta.chain_id.to_string()),
        Param::Text(meta.buffer_block.to_string()),
        meta.first_event_block
            .map_or(Param::Null, |block| Param::Text(block.to_string())),
        meta.ready_at
            .map_or(Param::Null, |time| Param::Text(time.to_string())),
        Param::Text(meta.is_hyper_sync.to_string()),
    ]
}

/// Commits a transaction whose statements all succeeded, and otherwise rolls
/// it back and reports what failed.
async fn finish(transaction: Transaction, outcome: Result<()>) -> Result<()> {
    match outcome {
        Ok(()) => transaction.commit().await,
        Err(error) => {
            let _ = transaction.rollback().await;
            Err(error)
        }
    }
}

/// What a read gets from a schema an older envio initialized without the
/// table.
async fn missing_as_none<T>(read: impl Future<Output = Result<T>>) -> Result<Option<T>> {
    match read.await {
        Ok(value) => Ok(Some(value)),
        Err(error) if sql_state(&error) == Some("42P01") => Ok(None),
        Err(error) => Err(error),
    }
}

/// An array literal of already-rendered elements, each quoted: inside quotes
/// only the quote and the backslash mean anything, so this doesn't have to
/// know what the element type treats as special.
pub fn array_literal<S: AsRef<str>>(elements: impl IntoIterator<Item = Option<S>>) -> Param {
    let mut literal = String::from("{");
    for (index, element) in elements.into_iter().enumerate() {
        if index > 0 {
            literal.push(',');
        }
        match element {
            None => literal.push_str("NULL"),
            Some(element) => {
                literal.push('"');
                for character in element.as_ref().chars() {
                    if character == '"' || character == '\\' {
                        literal.push('\\');
                    }
                    literal.push(character);
                }
                literal.push('"');
            }
        }
    }
    literal.push('}');
    Param::Text(literal)
}

fn bytea(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(2 + bytes.len() * 2);
    text.push_str("\\x");
    for byte in bytes {
        text.push_str(&format!("{byte:02x}"));
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    fn counter(chain_id_column: Option<&str>) -> Table {
        let column = |name: &str, field_type: FieldType, is_primary_key: bool| ColumnSpec {
            name: name.to_string(),
            field_type,
            is_array: false,
            is_nullable: false,
            is_primary_key,
            default_value: None,
        };
        let mut columns = vec![
            column("id", FieldType::String, true),
            column("count", FieldType::BigInt { precision: None }, false),
        ];
        if let Some(chain_id) = chain_id_column {
            columns.push(column(chain_id, FieldType::ChainId, true));
        }
        Table::new(
            TableRegistration {
                write_columns: columns.iter().map(|c| c.name.clone()).collect(),
                spec: TableSpec {
                    table_name: "Counter".to_string(),
                    columns,
                    partition_by_column: chain_id_column.map(str::to_string),
                },
                append_only: false,
                history: Some(HistoryRegistration {
                    table_name: "envio_history_Counter".to_string(),
                    chain_id_column: chain_id_column.map(str::to_string),
                }),
            },
            &Settings {
                pg_schema: "public".to_string(),
                pg_user: "postgres".to_string(),
                chain_id_mode: ChainIdMode::Int32,
                numeric_array_as_text: false,
            },
        )
        .unwrap()
    }

    /// A per-chain entity's rows are only comparable within a chain, so its
    /// history is keyed by the chain too, which a delete row never nulls.
    #[test]
    fn history_is_keyed_by_the_entitys_chain_and_the_checkpoint() {
        let history_ddl = |table: Table| {
            create_table_query(
                &table.entity.unwrap().history_spec,
                "public",
                false,
                ChainIdMode::Int32,
            )
            .unwrap()
        };
        assert_eq!(
            (
                history_ddl(counter(Some("chainId"))),
                history_ddl(counter(None)),
            ),
            (
                "CREATE TABLE IF NOT EXISTS \"public\".\"envio_history_Counter\"(\"id\" TEXT NOT \
                 NULL, \"count\" NUMERIC, \"chainId\" INTEGER NOT NULL, \"envio_checkpoint_id\" \
                 BIGINT NOT NULL, \"envio_change\" \"public\".ENVIO_HISTORY_CHANGE NOT NULL, \
                 PRIMARY KEY(\"id\", \"chainId\", \"envio_checkpoint_id\"));"
                    .to_string(),
                "CREATE TABLE IF NOT EXISTS \"public\".\"envio_history_Counter\"(\"id\" TEXT NOT \
                 NULL, \"count\" NUMERIC, \"envio_checkpoint_id\" BIGINT NOT NULL, \
                 \"envio_change\" \"public\".ENVIO_HISTORY_CHANGE NOT NULL, PRIMARY KEY(\"id\", \
                 \"envio_checkpoint_id\"));"
                    .to_string(),
            )
        );
    }

    #[test]
    fn an_element_is_quoted_and_a_missing_one_is_null() {
        assert_eq!(
            array_literal([Some("a\"b\\c"), None, Some("")]),
            Param::Text("{\"a\\\"b\\\\c\",NULL,\"\"}".to_string())
        );
    }

    #[test]
    fn bytes_are_written_as_a_hex_bytea() {
        assert_eq!(
            array_literal([Some(bytea(&[0, 255, 16]))]),
            Param::Text("{\"\\\\x00ff10\"}".to_string())
        );
    }

    /// Cells come column by column for the whole batch, and each statement
    /// takes its rows' slice of every column, the extra one last.
    #[test]
    fn cells_are_cut_into_statements_column_by_column() {
        let text = |value: &str| Param::Text(value.to_string());
        let cells = ["a1", "a2", "a3", "b1", "b2", "b3"].map(text).to_vec();
        let extra = ["c1", "c2", "c3"].map(text).to_vec();
        let statements = chunked_cells(&cells, 3, 2, &extra, |rows| rows.to_string()).unwrap();
        assert_eq!(
            statements,
            vec![(
                "3".to_string(),
                ["a1", "a2", "a3", "b1", "b2", "b3", "c1", "c2", "c3"]
                    .map(text)
                    .to_vec(),
                Shape::Once,
            )]
        );
    }

    #[test]
    fn only_a_full_chunk_is_kept_prepared() {
        let rows = insert::values_rows_per_statement(2) + 1;
        let cells = vec![Param::Null; rows * 2];
        let shapes = chunked_cells(&cells, rows, 2, &[], |rows| rows.to_string())
            .unwrap()
            .into_iter()
            .map(|(_, _, shape)| shape)
            .collect::<Vec<_>>();
        assert_eq!(shapes, vec![Shape::Recurring, Shape::Once]);
    }

    fn bounds(sequence: Sequence) -> Bounds {
        Bounds {
            sequence,
            chain_ids: vec![1, 137],
            checkpoint_ids: vec![9, 2],
        }
    }

    /// The two arrays are read positionally by the unnest relation, so a chain
    /// paired with another chain's bound would narrow the wrong rows.
    #[test]
    fn per_chain_bounds_pair_each_chain_with_its_own_id() {
        assert_eq!(
            bound_params(&bounds(Sequence::PerChain)),
            vec![
                Param::Text("{\"1\",\"137\"}".to_string()),
                Param::Text("{\"9\",\"2\"}".to_string()),
            ]
        );
    }

    /// Every chain is held to one id under a shared sequence, and it has to be
    /// the lowest: a higher one would leave another chain's rows above its own
    /// bound.
    #[test]
    fn shared_bounds_collapse_to_the_lowest_id() {
        assert_eq!(
            bound_params(&bounds(Sequence::SharedAcrossChains)),
            vec![Param::Text("2".to_string())]
        );
    }

    /// Rows whose cells don't fill every column would be bound out of place,
    /// so they are refused rather than sliced.
    #[test]
    fn cells_that_dont_fill_the_columns_are_refused() {
        let cells = vec![Param::Null; 5];
        assert_eq!(
            chunked_cells(&cells, 3, 2, &[], |rows| rows.to_string())
                .unwrap_err()
                .to_string(),
            "5 cells came for 3 rows of 2 columns"
        );
    }

    #[test]
    fn the_cascade_is_never_the_failure_reported() {
        let cascade = Failure::new(
            "second",
            anyhow::Error::new(super::super::error::Aborted("aborted")),
        );
        let cause = Failure::new("first", anyhow!("value out of range"));
        assert_eq!(
            first_cause(vec![cascade, cause], |failure| &failure.error)
                .map(|failure| failure.context),
            Some("first".to_string())
        );
    }
}
