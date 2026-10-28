//! The indexer's Postgres storage: every statement it runs, and the
//! transactions they run in.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, bail, Context, Result};
use futures_util::future::join_all;
use tokio_postgres::Row;

use super::client::{PgClient, Transaction};
use super::ddl::{create_partition_query, create_table_query, ColumnSpec, TableSpec};
use super::error::sql_state;
use super::history::{History, CHANGE_TYPE};
use super::index_definition::{Direction, IndexColumn, IndexDefinition, BTREE};
use super::index_row;
use super::indexes::{IndexEvent, Indexes, Report};
use super::insert;
use super::internal;
use super::param::Param;
use super::pg_type::{pg_field_type, ChainIdMode, FieldType};
use super::rows::into_result;
use super::schema_indexes;
use super::select;
use super::write::{self, Render, Source};
use crate::columnar::{Arena, Column, ColumnKind};
use crate::entity_filter::Condition;
use crate::storage::changes::ChangeSet;
use crate::storage::rows::ResultSet;
use crate::storage::schema::{
    self, effect_cache_fields, raw_event_fields, raw_events_key, Entity, Field, Schema,
    RAW_EVENTS_TABLE,
};
use crate::storage::types::{
    Addresses, Bounds, CacheTable, ChainConfig, ChainMeta, Checkpoints, Progress, ProgressDiff,
    ReorgCheckpoint, ResumedChain, Sequence, StoredConfig, CHAINS_TABLE, CHANGE_COLUMN,
    CHECKPOINT_ID_COLUMN, DELETE, SET,
};
use crate::storage::{
    AddChain, Batch, CacheDump, CacheFile, Failure, Handoff, Initialize, Resumed, RollbackWrite,
    StoredConfigRead, WriteError,
};

pub struct Settings {
    pub pg_schema: String,
    /// Only for the GRANT the schema is created with.
    pub pg_user: String,
    /// Hasura cannot read a `numeric[]`, so a schema it tracks stores those as
    /// `text[]` (issue #788).
    pub numeric_array_as_text: bool,
    /// An `envio start --chain` process: builds and looks for a per-chain
    /// entity's indexes on its own chains' partitions, never on the parent
    /// table, so no build reaches into the rows a sibling process drives.
    pub isolated: bool,
}

impl ColumnSpec {
    fn of(field: &Field) -> Self {
        ColumnSpec {
            name: field.pg_column.clone(),
            field_type: field.field_type.clone(),
            is_array: field.is_array,
            is_nullable: field.is_nullable,
            is_primary_key: field.is_primary_key,
            default_value: field.default_value.clone(),
        }
    }
}

/// A table the storage writes, and how a staged batch's columns reach it.
pub struct Table {
    pub spec: TableSpec,
    /// The staged fields, in the order a batch lays them out.
    fields: Vec<Field>,
    /// The insert's columns: the staged fields, and for a per-chain entity its
    /// chain last.
    insert: TableSpec,
    /// Raw events are only ever appended, so a row already there is one the
    /// batch has seen before rather than one to overwrite.
    append_only: bool,
    entity: Option<EntityHistory>,
}

struct EntityHistory {
    history: History,
    spec: TableSpec,
    /// The staged fields as history declares them, then the checkpoint, the
    /// change and the chain.
    insert: TableSpec,
}

impl Table {
    fn internal(name: &str, fields: Vec<Field>, own: Vec<Field>, append_only: bool) -> Self {
        let insert = TableSpec {
            table_name: name.to_string(),
            columns: fields.iter().map(ColumnSpec::of).collect(),
            partition_by_column: None,
        };
        Self {
            spec: TableSpec {
                columns: insert
                    .columns
                    .iter()
                    .cloned()
                    .chain(own.iter().map(ColumnSpec::of))
                    .collect(),
                ..insert.clone()
            },
            fields,
            insert,
            append_only,
            entity: None,
        }
    }

    pub fn raw_events() -> Self {
        Self::internal(
            RAW_EVENTS_TABLE,
            raw_event_fields(),
            vec![raw_events_key()],
            true,
        )
    }

    pub fn effect_cache(name: &str) -> Self {
        Self::internal(name, effect_cache_fields(), Vec::new(), false)
    }

    fn entity(entity: &Entity, settings: &Settings, chain_id_mode: ChainIdMode) -> Result<Self> {
        let chain_id = entity
            .chain_id
            .as_ref()
            .map(|chain_id| ColumnSpec::of(&chain_id.field()));
        let staged = entity.fields.iter().map(ColumnSpec::of).collect::<Vec<_>>();
        let insert = TableSpec {
            table_name: entity.name.clone(),
            columns: staged.iter().cloned().chain(chain_id.clone()).collect(),
            partition_by_column: None,
        };
        let spec = TableSpec {
            partition_by_column: chain_id.as_ref().map(|column| column.name.clone()),
            ..insert.clone()
        };

        let chain_id_column = chain_id.as_ref().map(|column| column.name.clone());
        let is_key = |column: &ColumnSpec| {
            column.name == schema::ID_FIELD || chain_id_column.as_deref() == Some(&column.name)
        };
        // Every data column takes NULL, which is what a delete row holds;
        // the key is what identifies the row, so it never does.
        let as_history = |column: &ColumnSpec| ColumnSpec {
            is_nullable: !is_key(column),
            is_primary_key: is_key(column),
            ..column.clone()
        };
        let checkpoint = ColumnSpec {
            name: CHECKPOINT_ID_COLUMN.to_string(),
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
                variants: vec![SET.to_string(), DELETE.to_string()],
            },
            is_primary_key: false,
            ..checkpoint.clone()
        };
        let (_, id) = entity.id()?;
        let history_table = entity.history_table.clone();
        let history = EntityHistory {
            history: History {
                entity_table: entity.name.clone(),
                history_table: history_table.clone(),
                data_columns: spec.columns.iter().map(|c| c.name.clone()).collect(),
                chain_id_column: chain_id_column.clone(),
                id_pg_type: pg_field_type(
                    &id.field_type,
                    &settings.pg_schema,
                    false,
                    false,
                    false,
                    chain_id_mode,
                ),
            },
            spec: TableSpec {
                table_name: history_table.clone(),
                columns: spec
                    .columns
                    .iter()
                    .map(as_history)
                    .chain([checkpoint.clone(), change.clone()])
                    .collect(),
                partition_by_column: None,
            },
            insert: TableSpec {
                table_name: history_table,
                columns: staged
                    .iter()
                    .map(as_history)
                    .chain([checkpoint, change])
                    .chain(chain_id.as_ref().map(as_history))
                    .collect(),
                partition_by_column: None,
            },
        };
        Ok(Self {
            spec,
            fields: entity.fields.clone(),
            insert,
            append_only: false,
            entity: Some(history),
        })
    }

    pub fn name(&self) -> &str {
        &self.spec.table_name
    }

    fn entity_history(&self) -> Result<&EntityHistory> {
        self.entity
            .as_ref()
            .ok_or_else(|| anyhow!("\"{}\" is not an entity table", self.spec.table_name))
    }

    /// The staged columns, rendered as their fields say.
    fn sources<'a>(&self, columns: &'a [Column]) -> Vec<Source<'a>> {
        self.fields
            .iter()
            .zip(columns)
            .map(|(field, column)| Source::Staged {
                column,
                render: Render::of(field.encoding(), field.field_type.encoding()),
            })
            .collect()
    }
}

/// Under one shared sequence the single id is bound as `$1`; per chain, the
/// chains and their ids are the two arrays the joined relation unnests.
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

fn execute<'a>(
    transaction: &'a Transaction,
    context: impl Into<String>,
    sql: String,
    params: Vec<Param>,
) -> Statement<'a> {
    let context = context.into();
    Box::pin(async move {
        transaction
            .execute(&sql, &params)
            .await
            .map(|_| ())
            .map_err(|error| Failure::new(context, error))
    })
}

pub struct Storage {
    pub client: PgClient,
    settings: Settings,
    schema: Arc<Schema>,
    pub indexes: Arc<Indexes<PgClient>>,
    /// By entity index: None for an entity Postgres doesn't keep.
    entities: Vec<Option<Arc<Table>>>,
    raw_events: Table,
    /// An effect's cache is written and read before anything else names it.
    caches: Mutex<HashMap<String, Arc<Table>>>,
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
    pub fn new(
        client: PgClient,
        settings: Settings,
        schema: Arc<Schema>,
        report: Report,
    ) -> Result<Self> {
        let entities = schema
            .entities
            .iter()
            .map(|entity| {
                entity
                    .postgres
                    .then(|| Table::entity(entity, &settings, schema.chain_id_mode).map(Arc::new))
                    .transpose()
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(Self {
            indexes: Arc::new(Indexes::new(
                client.clone(),
                settings.pg_schema.clone(),
                report,
            )),
            client,
            settings,
            schema,
            entities,
            raw_events: Table::raw_events(),
            caches: Mutex::new(HashMap::new()),
        })
    }

    fn schema(&self) -> &str {
        &self.settings.pg_schema
    }

    fn chain_id_mode(&self) -> ChainIdMode {
        self.schema.chain_id_mode
    }

    pub fn entity_table(&self, index: usize) -> Option<&Arc<Table>> {
        self.entities.get(index).and_then(Option::as_ref)
    }

    fn entity_table_or_err(&self, entity: &Entity) -> Result<&Arc<Table>> {
        self.entity_table(entity.index)
            .ok_or_else(|| anyhow!("\"{}\" is not stored in Postgres", entity.name))
    }

    pub fn effect_cache_table(&self, name: &str) -> Arc<Table> {
        self.caches
            .lock()
            .unwrap()
            .entry(name.to_string())
            .or_insert_with(|| Arc::new(Table::effect_cache(name)))
            .clone()
    }

    fn create_table(&self, spec: &TableSpec) -> Result<String> {
        create_table_query(
            spec,
            self.schema(),
            self.settings.numeric_array_as_text,
            self.chain_id_mode(),
        )
    }

    /// One partition per chain of every per-chain entity Postgres keeps.
    fn create_partitions(&self, chain_ids: &[i64]) -> Vec<String> {
        self.schema
            .entities
            .iter()
            .filter(|entity| entity.postgres && entity.chain_id.is_some())
            .flat_map(|entity| {
                chain_ids.iter().map(|&chain_id| {
                    create_partition_query(
                        self.schema(),
                        &entity.name,
                        &entity.partition_table_name(chain_id),
                        chain_id,
                    )
                })
            })
            .collect()
    }

    async fn table_names(&self) -> Result<Vec<String>> {
        let (rows, _) = self
            .client
            .query(
                "SELECT table_name::TEXT FROM information_schema.tables WHERE table_schema = $1;",
                &[Param::Text(self.schema().to_string())],
            )
            .await?;
        rows.iter().map(|row| cell::<String>(row, 0)).collect()
    }

    /// Whether the schema holds an indexer's tables. `event_sync_state` is what
    /// an envio before 2.28 created.
    fn has_indexer_tables(names: &[String]) -> bool {
        names
            .iter()
            .any(|name| name == CHAINS_TABLE || name == "event_sync_state")
    }

    pub async fn is_initialized(&self) -> Result<bool> {
        Ok(Self::has_indexer_tables(&self.table_names().await?))
    }

    /// Whether the schema is empty, refusing one that holds anything but an
    /// indexer's tables: initializing drops it.
    pub async fn check_schema_for_initialize(&self) -> Result<bool> {
        let names = self.table_names().await?;
        if !names.is_empty() && !Self::has_indexer_tables(&names) {
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
    pub async fn initialize(
        &self,
        input: &Initialize,
        instance: &str,
        is_empty_schema: bool,
    ) -> Result<()> {
        let schema = self.schema();
        let tables = std::iter::once(&self.raw_events)
            .chain(self.entities.iter().flatten().map(Arc::as_ref))
            .collect::<Vec<_>>();
        let chain_ids = input
            .chains
            .iter()
            .map(|chain| chain.id)
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
        for (name, variants) in &self.schema.enums {
            ddl.push(format!(
                "CREATE TYPE \"{schema}\".{} AS ENUM({});",
                name,
                variants
                    .iter()
                    .map(|variant| format!("'{variant}'"))
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
        ddl.push(format!(
            "CREATE TYPE \"{schema}\".{CHANGE_TYPE} AS ENUM('{SET}', '{DELETE}');"
        ));
        for spec in internal::tables(self.schema.sequence) {
            ddl.push(self.create_table(&spec)?);
        }
        for table in &tables {
            ddl.push(self.create_table(&table.spec)?);
        }
        ddl.extend(self.create_partitions(&chain_ids));
        // History stays unpartitioned: it is only ever read by checkpoint,
        // never by chain, so partitioning it would route every write and prune
        // nothing.
        for table in &tables {
            if let Some(entity) = &table.entity {
                ddl.push(self.create_table(&entity.spec)?);
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
                    &[
                        Param::Text(input.envio_info.clone()),
                        Param::Text(instance.to_string()),
                    ],
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
                &internal::insert_addresses(self.schema(), self.chain_id_mode()),
                &address_params(addresses, true),
            )
            .await?;
        Ok(())
    }

    /// Brings a chain the schema doesn't have yet: its partitions, its config
    /// addresses and its row. Only one process ever adds a given chain.
    pub async fn add_chain(&self, input: &AddChain) -> Result<()> {
        let transaction = self.client.begin().await?;
        let outcome = async {
            for partition in self.create_partitions(&[input.chain.id]) {
                transaction.batch(&partition).await?;
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

    /// None for a schema an older envio built, which keeps none.
    pub async fn instance(&self) -> Result<Option<String>> {
        match self
            .client
            .query(&internal::read_instance(self.schema()), &[])
            .await
        {
            Ok((rows, _)) => rows.first().map(|row| cell(row, 0)).transpose(),
            // The table, or the column, an older envio didn't create.
            Err(error) if matches!(sql_state(&error), Some("42P01" | "42703")) => Ok(None),
            Err(error) => Err(error),
        }
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
                        Ok(ChainConfig {
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
    async fn set_ready_at(&self, chain_ids: &[i64], ready_at: f64) -> Result<()> {
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
    pub async fn finalize_backfill(&self, chain_ids: &[i64], ready_at: f64) -> Result<()> {
        let start = std::time::Instant::now();
        let built = self
            .indexes
            .finalize(self.schema_indexes(chain_ids))
            .await?;
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

    /// Every index the schema promises for the given chains.
    pub fn schema_indexes(&self, chain_ids: &[i64]) -> Vec<IndexDefinition> {
        schema_indexes::schema_indexes(&self.schema, self.settings.isolated.then_some(chain_ids))
    }

    /// The single-column indexes a getWhere on `columns` of the entity wants,
    /// on the table its query for `chain_id`'s scope is planned against: a
    /// per-chain entity's query carries the chain, so it is planned against
    /// that chain's partition, which an index on the parent covers by
    /// cascading.
    pub fn query_indexes(
        &self,
        entity: &Entity,
        chain_id: Option<i64>,
        columns: Vec<String>,
    ) -> Vec<IndexDefinition> {
        let table_name = match chain_id {
            Some(chain_id) if self.settings.isolated => {
                schema_indexes::index_tables(entity, Some(&[chain_id])).remove(0)
            }
            _ => entity.name.clone(),
        };
        columns
            .into_iter()
            .map(|name| IndexDefinition {
                table_name: table_name.clone(),
                columns: vec![IndexColumn {
                    name,
                    direction: Direction::Asc,
                }],
                method: BTREE.to_string(),
            })
            .collect()
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

    pub async fn prune_history(&self, entity: &Entity, bounds: &Bounds) -> Result<()> {
        let entity = self.entity_table_or_err(entity)?.entity_history()?;
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
        rows.first().map(|row| cell(row, 0)).transpose()
    }

    pub async fn lowest_checkpoint(&self, chain_id: Option<i64>) -> Result<Option<i64>> {
        let params = chain_id
            .map(|chain_id| Param::Text(chain_id.to_string()))
            .into_iter()
            .collect::<Vec<_>>();
        let (rows, _) = self
            .client
            .query(
                &internal::lowest_checkpoint(self.schema(), chain_id.is_some()),
                &params,
            )
            .await?;
        rows.first().map(|row| cell(row, 0)).transpose()
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
        entity: &Entity,
        bounds: &Bounds,
    ) -> Result<(ResultSet, ResultSet)> {
        let history = &self.entity_table_or_err(entity)?.entity_history()?.history;
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
            let table = self.effect_cache_table(&file.table);
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

    pub async fn dump_effect_cache(&self, files: &[CacheDump]) -> Result<()> {
        let schema = self.schema();
        let dumps = files.iter().map(|dump| {
            let sql = format!(
                "COPY {}.{} TO STDOUT WITH (FORMAT text, HEADER)",
                internal::quote_ident(schema),
                internal::quote_ident(&dump.table_name)
            );
            async move {
                dump.replace_with(async |file| self.client.copy_out(&sql, file).await)
                    .await
            }
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
    /// Nothing commits unless every statement succeeded and the handoff says
    /// to.
    pub async fn write_batch(
        &self,
        batch: &Batch,
        mut handoff: Handoff,
    ) -> std::result::Result<(), WriteError> {
        // Moved in, so the handoff goes as soon as the transaction is done and a
        // store waiting on its word never waits on the caches too.
        let transactional = async move {
            let transaction =
                self.client.begin().await.map_err(|error| {
                    Failure::new("Failed opening the batch's transaction", error)
                })?;
            let outcome = async {
                if let Some(rollback) = &batch.rollback {
                    self.write_rollback(&transaction, rollback).await?;
                }
                self.write_changes(&transaction, batch).await?;
                if !handoff.ready_to_commit().await {
                    return Err(WriteError::Gated);
                }
                Ok(())
            }
            .await;
            match outcome {
                Ok(()) => {
                    let committed = transaction.commit().await;
                    handoff.report_commit(committed.is_ok());
                    committed
                        .map_err(|error| Failure::new("Failed committing the batch", error).into())
                }
                Err(error) => {
                    // The statement that failed is what to report; a rollback
                    // failing after it would only say the connection is gone.
                    let _ = transaction.rollback().await;
                    Err(error)
                }
            }
        };
        let caches = async {
            let writes = batch.effect_caches.iter().map(|write| async move {
                let table = self.effect_cache_table(&write.table);
                if write.create {
                    let fail = |error| Failure::new(insert_context(table.name()), error);
                    let create = self.create_table(&table.spec).map_err(fail)?;
                    self.client.batch(&create).await.map_err(fail)?;
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
        for table in self.entities.iter().flatten() {
            let sql = table
                .entity_history()
                .and_then(|entity| entity.history.rollback(schema, rollback.bounds.sequence))
                .map_err(|error| Failure::new("Failed rolling back the history", error))?;
            statements.push(execute(
                transaction,
                format!("Failed rolling back the history of \"{}\"", table.name()),
                sql,
                params.clone(),
            ));
        }
        statements.push(execute(
            transaction,
            "Failed rolling back the checkpoints",
            internal::rollback_checkpoints(schema, rollback.bounds.sequence)
                .map_err(|error| Failure::new("Failed rolling back the checkpoints", error))?,
            params,
        ));
        // Before the batch's own progress write, so a chain the batch also
        // progressed keeps the batch's later value.
        let progress_sql = internal::set_progress(schema);
        for progress in &rollback.progress {
            statements.push(execute(
                transaction,
                "Failed rolling back the chains' progress",
                progress_sql.clone(),
                progress_params(progress),
            ));
        }
        // Before the batch's own inserts, so an address registered again lands
        // after its old row is gone.
        if !rollback.removed_addresses.chain_ids.is_empty() {
            statements.push(execute(
                transaction,
                "Failed rolling back the registered addresses",
                internal::delete_addresses(schema, self.chain_id_mode()),
                address_params(&rollback.removed_addresses, false),
            ));
        }
        settle(join_all(statements).await)
    }

    async fn write_changes(
        &self,
        transaction: &Transaction,
        batch: &Batch,
    ) -> std::result::Result<(), Failure> {
        let schema = self.schema();
        let chain_id_mode = self.chain_id_mode();
        let mut statements: Vec<Statement<'_>> = Vec::new();

        let progress_sql = internal::set_progress(schema);
        for progress in &batch.progress {
            statements.push(execute(
                transaction,
                "Failed writing the chains' progress",
                progress_sql.clone(),
                progress_params(progress),
            ));
        }
        if let Some(rows) = &batch.raw_events {
            statements.push(Box::pin(self.insert(
                Some(transaction),
                &self.raw_events,
                rows,
            )));
        }
        for changes in &batch.changes {
            if changes.entity.postgres {
                statements.push(Box::pin(self.write_entity(
                    transaction,
                    changes,
                    batch.diff_checkpoint(changes.chain_id),
                )));
            }
        }
        let meta_sql = internal::set_meta(schema);
        for meta in &batch.chain_meta {
            statements.push(execute(
                transaction,
                "Failed writing the chains' metadata",
                meta_sql.clone(),
                meta_params(meta),
            ));
        }
        if !batch.addresses.chain_ids.is_empty() {
            statements.push(execute(
                transaction,
                "Failed writing the registered addresses",
                internal::insert_addresses(schema, chain_id_mode),
                address_params(&batch.addresses, true),
            ));
        }
        let frontier = &batch.frontier;
        if !frontier.chain_ids.is_empty() {
            statements.push(execute(
                transaction,
                "Failed writing the chains' checkpoint",
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
        let checkpoints = batch.checkpoints.keeping_history();
        if !checkpoints.ids.is_empty() {
            statements.push(execute(
                transaction,
                "Failed writing the checkpoints",
                internal::insert_checkpoints(schema, chain_id_mode),
                checkpoint_params(&checkpoints),
            ));
        }

        settle(join_all(statements).await)
    }

    /// One entity's share of the batch: the latest state of every id it
    /// changed, and when its scope keeps history, every change leading to it.
    /// The backfill runs first: it copies the rows the other statements are
    /// about to change.
    async fn write_entity(
        &self,
        transaction: &Transaction,
        changes: &ChangeSet,
        diff: Option<i64>,
    ) -> std::result::Result<(), Failure> {
        let schema = self.schema();
        let entity = &changes.entity;
        let history_context = || format!("Failed writing the history of \"{}\"", entity.name);
        let insert_failure = |error| Failure::new(insert_context(&entity.name), error);
        let table = self.entity_table_or_err(entity).map_err(insert_failure)?;
        let history = table.entity_history().map_err(insert_failure)?;
        let projection = changes.project(diff);
        let ids = |rows: &[usize]| {
            rows.iter()
                .map(|&row| changes.id_text(row).map(Some))
                .collect::<Result<Vec<_>>>()
        };
        let chain_id = changes.chain_id.map(|chain_id| chain_id.to_string());

        if !projection.backfill.is_empty() {
            let backfill = ids(&projection.backfill)
                .map_err(|error| Failure::new(history_context(), error))?;
            transaction
                .execute(
                    &history.history.backfill(schema, changes.chain_id),
                    &[array_literal(backfill)],
                )
                .await
                .map_err(|error| Failure::new(history_context(), error))?;
        }
        let mut statements: Vec<Statement<'_>> = Vec::new();
        if !projection.history_deletes.is_empty() {
            let mut params = vec![
                array_literal(
                    ids(&projection.history_deletes)
                        .map_err(|error| Failure::new(history_context(), error))?,
                ),
                array_literal(
                    projection
                        .history_deletes
                        .iter()
                        .map(|&row| Some(changes.checkpoint(row).to_string())),
                ),
            ];
            let with_chain = history.history.chain_id_column.is_some() && chain_id.is_some();
            if let (true, Some(chain_id)) = (with_chain, &chain_id) {
                params.push(Param::Text(chain_id.clone()));
            }
            statements.push(execute(
                transaction,
                history_context(),
                history.history.insert_delete_rows(schema, with_chain),
                params,
            ));
        }
        if !projection.history_sets.is_empty() {
            let columns = changes.rows.columns();
            let mut sources = table.sources(columns);
            sources.push(Source::Staged {
                column: changes.checkpoints(),
                render: Render::Plain,
            });
            sources.push(Source::Repeated(SET));
            sources.extend(chain_id.as_deref().map(Source::Repeated));
            statements.push(Box::pin(self.run_insert(
                Some(transaction),
                &history.insert,
                false,
                sources,
                &projection.history_sets,
                &entity.history_table,
                table,
                changes.fields(),
            )));
        }
        if !projection.sets.is_empty() {
            let mut sources = table.sources(changes.rows.columns());
            sources.extend(chain_id.as_deref().map(Source::Repeated));
            statements.push(Box::pin(self.run_insert(
                Some(transaction),
                &table.insert,
                false,
                sources,
                &projection.sets,
                &entity.name,
                table,
                changes.fields(),
            )));
        }
        if !projection.deletes.is_empty() {
            let deletes = ids(&projection.deletes).map_err(insert_failure)?;
            statements.push(execute(
                transaction,
                format!("Failed deleting \"{}\" from storage by ids", entity.name),
                history.history.delete_entities(schema, changes.chain_id),
                vec![array_literal(deletes)],
            ));
        }
        settle(join_all(statements).await)
    }

    /// Inserts every staged row into a table, in the transaction when there
    /// is one.
    async fn insert(
        &self,
        transaction: Option<&Transaction>,
        table: &Table,
        rows: &Arena,
    ) -> std::result::Result<(), Failure> {
        let all = (0..rows.rows()).collect::<Vec<_>>();
        self.run_insert(
            transaction,
            &table.insert,
            table.append_only,
            table.sources(rows.columns()),
            &all,
            table.name(),
            table,
            rows.columns(),
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    async fn run_insert(
        &self,
        transaction: Option<&Transaction>,
        spec: &TableSpec,
        append_only: bool,
        sources: Vec<Source<'_>>,
        rows: &[usize],
        target: &str,
        table: &Table,
        staged: &[Column],
    ) -> std::result::Result<(), Failure> {
        let fail = |error| Failure::new(insert_context(target), error);
        let sql = insert::unnest_query(
            spec,
            self.schema(),
            append_only,
            self.settings.numeric_array_as_text,
            self.chain_id_mode(),
        );
        let params = write::unnest_params(&sources, rows).map_err(fail)?;
        let outcome = match transaction {
            Some(transaction) => transaction.execute(&sql, &params).await,
            None => self.client.execute(&sql, &params).await,
        };
        outcome.map(|_| ()).map_err(|error| {
            if sql_state(&error) == Some(index_row::PROGRAM_LIMIT_EXCEEDED) {
                let oversized = self.oversized_value(table, staged, rows);
                Failure::new(index_row::explain_insert(target, oversized), error)
            } else {
                fail(error)
            }
        })
    }

    /// The first indexed value among the rows over the btree limit.
    fn oversized_value(
        &self,
        table: &Table,
        staged: &[Column],
        rows: &[usize],
    ) -> Option<index_row::Oversized> {
        let indexed = self.indexes.btree_columns(table.name());
        let id = table
            .fields
            .iter()
            .position(|field| field.name == schema::ID_FIELD)?;
        rows.iter().find_map(|&row| {
            table.fields.iter().zip(staged).find_map(|(field, column)| {
                // A fixed-width or null cell has no bytes to count.
                let value = column.bytes_at(row);
                (value.len() > index_row::BTREE_MAX_ITEM_BYTES
                    && indexed.contains(&field.pg_column))
                .then(|| index_row::Oversized {
                    column: field.pg_column.clone(),
                    id: String::from_utf8_lossy(staged[id].bytes_at(row)).into_owned(),
                    value: match column.kind() {
                        ColumnKind::Bytes => value
                            .iter()
                            .fold("0x".to_string(), |hex, byte| hex + &format!("{byte:02x}")),
                        _ => String::from_utf8_lossy(value).into_owned(),
                    },
                    bytes: value.len(),
                })
            })
        })
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

fn checkpoint_params(checkpoints: &Checkpoints) -> Vec<Param> {
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
    ]
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
    use crate::storage::schema::test_support;

    fn counter(chain_id_column: Option<&str>) -> Table {
        let entity = test_support::entity(
            "Counter",
            vec![
                test_support::id(),
                Field::new("count", FieldType::BigInt { precision: None }),
            ],
            chain_id_column,
        );
        Table::entity(
            &entity,
            &Settings {
                pg_schema: "public".to_string(),
                pg_user: "postgres".to_string(),
                numeric_array_as_text: false,
                isolated: false,
            },
            ChainIdMode::Int32,
        )
        .unwrap()
    }

    /// A per-chain entity's rows are only comparable within a chain, so its
    /// history is keyed by the chain too, which a delete row never nulls.
    #[test]
    fn history_is_keyed_by_the_entitys_chain_and_the_checkpoint() {
        let history_ddl = |table: Table| {
            create_table_query(
                &table.entity.unwrap().spec,
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
