//! The addon surface for the Postgres backend.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Mutex;

use napi::bindgen_prelude::{ArrayBuffer, Object};
use napi::Env;
use napi_derive::napi;

use crate::columnar::{self, Arena, ColumnKind, ColumnSpec as ArenaColumn};

use super::client::{self, PgConnectionOptions, SslSetting};
use super::ddl::{self, ColumnSpec, TableSpec};
use super::error::to_napi;
use super::index_definition::{self, Direction, IndexColumn, IndexDefinition};
use super::insert;
use super::internal;
use super::param::Param;
use super::pg_type::{self, ChainIdMode, FieldType};
use super::rollback::{self, HistoryQuery, Sequence};
use super::rows;
use super::write;

/// One column, flattened for the boundary: napi carries no tagged union, so the
/// variant arrives as `fieldType` plus whichever of the modifiers it takes.
#[napi(object)]
pub struct PgColumnInput {
    /// The database column name, renames already resolved.
    pub name: String,
    pub field_type: String,
    pub is_array: Option<bool>,
    pub is_nullable: Option<bool>,
    pub is_primary_key: Option<bool>,
    pub default_value: Option<String>,
    /// `BigInt` and `BigDecimal` only.
    pub precision: Option<u32>,
    /// `BigDecimal` only.
    pub scale: Option<u32>,
    /// `Enum` only: the name of its Postgres type.
    pub enum_name: Option<String>,
}

#[napi(object)]
pub struct PgTableInput {
    pub table_name: String,
    pub columns: Vec<PgColumnInput>,
    pub partition_by_column: Option<String>,
}

impl TryFrom<PgColumnInput> for ColumnSpec {
    type Error = anyhow::Error;

    fn try_from(input: PgColumnInput) -> anyhow::Result<Self> {
        Ok(ColumnSpec {
            field_type: FieldType::parse(
                &input.field_type,
                input.precision,
                input.scale,
                input.enum_name.as_deref(),
            )?,
            name: input.name,
            is_array: input.is_array.unwrap_or(false),
            is_nullable: input.is_nullable.unwrap_or(false),
            is_primary_key: input.is_primary_key.unwrap_or(false),
            default_value: input.default_value,
        })
    }
}

impl TryFrom<PgTableInput> for TableSpec {
    type Error = anyhow::Error;

    fn try_from(input: PgTableInput) -> anyhow::Result<Self> {
        Ok(TableSpec {
            table_name: input.table_name,
            columns: input
                .columns
                .into_iter()
                .map(ColumnSpec::try_from)
                .collect::<anyhow::Result<Vec<_>>>()?,
            partition_by_column: input.partition_by_column,
        })
    }
}

#[napi]
pub fn pg_field_type(
    field_type: String,
    pg_schema: String,
    is_array: bool,
    is_nullable: bool,
    is_numeric_array_as_text: bool,
    chain_id_mode: String,
    precision: Option<u32>,
    scale: Option<u32>,
    enum_name: Option<String>,
) -> napi::Result<String> {
    let field_type =
        FieldType::parse(&field_type, precision, scale, enum_name.as_deref()).map_err(to_napi)?;
    let chain_id_mode = ChainIdMode::parse(&chain_id_mode).map_err(to_napi)?;
    Ok(pg_type::pg_field_type(
        &field_type,
        &pg_schema,
        is_array,
        is_nullable,
        is_numeric_array_as_text,
        chain_id_mode,
    ))
}

#[napi]
pub fn pg_create_table_query(
    table: PgTableInput,
    pg_schema: String,
    is_numeric_array_as_text: bool,
    chain_id_mode: String,
) -> napi::Result<String> {
    let spec = TableSpec::try_from(table).map_err(to_napi)?;
    let chain_id_mode = ChainIdMode::parse(&chain_id_mode).map_err(to_napi)?;
    ddl::create_table_query(&spec, &pg_schema, is_numeric_array_as_text, chain_id_mode)
        .map_err(to_napi)
}

#[napi]
pub fn pg_insert_unnest_query(
    table: PgTableInput,
    pg_schema: String,
    append_only: bool,
    chain_id_mode: String,
) -> napi::Result<String> {
    let spec = TableSpec::try_from(table).map_err(to_napi)?;
    let chain_id_mode = ChainIdMode::parse(&chain_id_mode).map_err(to_napi)?;
    Ok(insert::unnest_query(
        &spec,
        &pg_schema,
        append_only,
        chain_id_mode,
    ))
}

#[napi]
pub fn pg_insert_values_query(
    table: PgTableInput,
    pg_schema: String,
    rows: u32,
) -> napi::Result<String> {
    let spec = TableSpec::try_from(table).map_err(to_napi)?;
    Ok(insert::values_query(&spec, &pg_schema, rows as usize))
}

#[napi(object)]
pub struct PgIndexColumnInput {
    pub name: String,
    pub direction: String,
}

#[napi(object)]
pub struct PgIndexInput {
    pub table_name: String,
    pub columns: Vec<PgIndexColumnInput>,
    pub method: String,
}

impl TryFrom<PgIndexColumnInput> for IndexColumn {
    type Error = anyhow::Error;

    fn try_from(input: PgIndexColumnInput) -> anyhow::Result<Self> {
        Ok(IndexColumn {
            name: input.name,
            direction: match input.direction.as_str() {
                "Asc" => Direction::Asc,
                "Desc" => Direction::Desc,
                other => anyhow::bail!("`{other}` is not an index column direction"),
            },
        })
    }
}

impl TryFrom<PgIndexInput> for IndexDefinition {
    type Error = anyhow::Error;

    fn try_from(input: PgIndexInput) -> anyhow::Result<Self> {
        Ok(IndexDefinition {
            table_name: input.table_name,
            columns: input
                .columns
                .into_iter()
                .map(IndexColumn::try_from)
                .collect::<anyhow::Result<Vec<_>>>()?,
            method: input.method,
        })
    }
}

#[napi]
pub fn pg_index_key(definition: PgIndexInput) -> napi::Result<String> {
    Ok(IndexDefinition::try_from(definition)
        .map_err(to_napi)?
        .key())
}

#[napi]
pub fn pg_index_name(definition: PgIndexInput) -> napi::Result<String> {
    Ok(IndexDefinition::try_from(definition)
        .map_err(to_napi)?
        .name())
}

#[napi]
pub fn pg_index_readable_prefix(definition: PgIndexInput) -> napi::Result<String> {
    Ok(IndexDefinition::try_from(definition)
        .map_err(to_napi)?
        .readable_prefix())
}

#[napi]
pub fn pg_index_column_key(column: PgIndexColumnInput) -> napi::Result<String> {
    Ok(IndexDefinition::column_key(
        &IndexColumn::try_from(column).map_err(to_napi)?,
    ))
}

#[napi]
pub fn pg_index_create_query(definition: PgIndexInput, pg_schema: String) -> napi::Result<String> {
    Ok(IndexDefinition::try_from(definition)
        .map_err(to_napi)?
        .create_query(&pg_schema))
}

#[napi]
pub fn pg_index_drop_query(pg_schema: String, index_name: String) -> String {
    index_definition::drop_query(&pg_schema, &index_name)
}

/// A result set laid out in the arena, waiting to be read.
///
/// The rows are not in this object: they are in arena memory, and
/// `lendResult` hands JavaScript the buffers to read them from. Only the shape
/// crosses here.
#[napi(object)]
pub struct PgQueryResult {
    pub handle: u32,
    pub names: Vec<String>,
    /// One per column, as `columnar`'s ordinals. JavaScript picks the view to
    /// build over each buffer from these.
    pub kinds: Vec<u8>,
    /// What a list column's elements are, and `-1` for a column that is not a
    /// list. A list's own ordinal says nothing about what it holds, and the
    /// element column is read exactly as a top-level one of that kind.
    pub element_kinds: Vec<i32>,
    pub rows: u32,
}

#[napi(object)]
pub struct PgClientOptions {
    pub host: String,
    pub port: u32,
    pub user: String,
    pub password: String,
    pub database: String,
    /// As `ENVIO_PG_SSL_MODE` spells it.
    pub ssl: String,
    pub max_connections: u32,
    pub application_name: Option<String>,
}

#[napi]
pub struct PgClient {
    inner: client::PgClient,
    /// Result sets handed out but not yet read and released. An entry lives
    /// only between `query` and `releaseResult`.
    results: Mutex<HashMap<u32, Arena>>,
    /// Transactions between their `begin` and their commit or rollback. Each
    /// holds a connection out of the pool for as long as it is open.
    transactions: Mutex<HashMap<u32, client::Transaction>>,
    /// Batches laid out but not yet bound to a statement.
    staged: Mutex<HashMap<u32, StagedBatch>>,
    /// The shape of each table a batch can be staged for.
    write_tables: Mutex<HashMap<u32, WriteSchema>>,
    next_handle: AtomicU32,
}

#[napi]
impl PgClient {
    #[napi(factory)]
    pub fn create(options: PgClientOptions) -> napi::Result<Self> {
        let port = u16::try_from(options.port)
            .map_err(|_| napi::Error::from_reason(format!("`{}` is not a port", options.port)))?;
        let inner = client::PgClient::connect(PgConnectionOptions {
            host: options.host,
            port,
            user: options.user,
            password: options.password,
            database: options.database,
            ssl: SslSetting::parse(&options.ssl).map_err(to_napi)?,
            max_connections: options.max_connections as usize,
            application_name: options.application_name,
        })
        .map_err(to_napi)?;
        Ok(Self {
            inner,
            results: Mutex::new(HashMap::new()),
            transactions: Mutex::new(HashMap::new()),
            staged: Mutex::new(HashMap::new()),
            write_tables: Mutex::new(HashMap::new()),
            next_handle: AtomicU32::new(0),
        })
    }

    /// Runs statements that take no parameters, discarding any rows. More than
    /// one may be given at once, which is what the initialization relies on.
    #[napi]
    pub async fn batch(&self, sql: String) -> napi::Result<()> {
        self.inner.batch(&sql).await.map_err(to_napi)
    }

    /// Writes what a `COPY ... TO STDOUT` produces into a file, and reads a
    /// file back into a `COPY ... FROM STDIN`. The effect cache travels this
    /// way, and the rows never cross this boundary.
    #[napi]
    pub async fn copy_out(&self, sql: String, path: String) -> napi::Result<()> {
        self.inner.copy_out(&sql, &path).await.map_err(to_napi)
    }

    #[napi]
    pub async fn copy_in(&self, sql: String, path: String) -> napi::Result<u32> {
        let rows = self.inner.copy_in(&sql, &path).await.map_err(to_napi)?;
        Ok(rows as u32)
    }

    /// Forgets what the connections have prepared, which the schema being
    /// dropped and built again makes necessary.
    #[napi]
    pub fn forget_prepared(&self) {
        self.inner.forget_prepared();
    }

    #[napi]
    pub async fn execute(&self, sql: String, params: Vec<Option<String>>) -> napi::Result<u32> {
        let params = to_params(params);
        let affected = self.inner.execute(&sql, &params).await.map_err(to_napi)?;
        Ok(affected as u32)
    }

    #[napi]
    pub async fn query(
        &self,
        sql: String,
        params: Vec<Option<String>>,
    ) -> napi::Result<PgQueryResult> {
        let (rows, columns) = self
            .inner
            .query(&sql, &to_params(params))
            .await
            .map_err(to_napi)?;
        self.hold(rows, columns)
    }

    /// The buffers a result's columns live in. They stay valid until
    /// `releaseResult` takes them back, and reading through one after that is
    /// what detaching prevents.
    #[napi]
    pub fn lend_result<'env>(
        &self,
        env: &'env Env,
        handle: u32,
    ) -> napi::Result<Vec<ArrayBuffer<'env>>> {
        let mut results = self.results.lock().unwrap();
        let arena = results
            .get_mut(&handle)
            .ok_or_else(|| napi::Error::from_reason(format!("Unknown result {handle}")))?;
        columnar::js::lend_for_reading(env, arena)
    }

    /// Detaches a result's buffers and frees it. A result that cannot hand them
    /// all back still has a JavaScript view into its memory, so that memory is
    /// abandoned rather than freed.
    #[napi]
    pub fn release_result(&self, handle: u32, buffers: Vec<ArrayBuffer>) -> napi::Result<()> {
        let mut results = self.results.lock().unwrap();
        let Some(arena) = results.get_mut(&handle) else {
            return Ok(());
        };
        match columnar::js::detach_all(arena, buffers) {
            Ok(()) => {
                results.remove(&handle);
                Ok(())
            }
            Err(failed) => {
                std::mem::forget(results.remove(&handle));
                Err(failed)
            }
        }
    }

    /// Opens a transaction and returns the handle every statement in it is
    /// given. It holds a connection until `commit` or `rollback`.
    #[napi]
    pub async fn begin(&self) -> napi::Result<u32> {
        let transaction = self.inner.begin().await.map_err(to_napi)?;
        let handle = self.next_handle.fetch_add(1, Ordering::Relaxed);
        self.transactions
            .lock()
            .unwrap()
            .insert(handle, transaction);
        Ok(handle)
    }

    #[napi]
    pub async fn transaction_batch(&self, transaction: u32, sql: String) -> napi::Result<()> {
        self.transaction(transaction)?
            .batch(&sql)
            .await
            .map_err(to_napi)
    }

    #[napi]
    pub async fn transaction_execute(
        &self,
        transaction: u32,
        sql: String,
        params: Vec<Option<String>>,
    ) -> napi::Result<u32> {
        let affected = self
            .transaction(transaction)?
            .execute(&sql, &to_params(params))
            .await
            .map_err(to_napi)?;
        Ok(affected as u32)
    }

    #[napi]
    pub async fn transaction_query(
        &self,
        transaction: u32,
        sql: String,
        params: Vec<Option<String>>,
    ) -> napi::Result<PgQueryResult> {
        let transaction = self.transaction(transaction)?;
        let (rows, columns) = transaction
            .query(&sql, &to_params(params))
            .await
            .map_err(to_napi)?;
        self.hold(rows, columns)
    }

    #[napi]
    pub async fn commit(&self, transaction: u32) -> napi::Result<()> {
        let held = self.take_transaction(transaction)?;
        held.commit().await.map_err(to_napi)
    }

    #[napi]
    pub async fn rollback(&self, transaction: u32) -> napi::Result<()> {
        let held = self.take_transaction(transaction)?;
        held.rollback().await.map_err(to_napi)
    }

    #[napi]
    pub async fn close(&self) {
        self.inner.close().await;
    }
}

impl PgClient {
    /// A transaction's connection, taken out of the map rather than held under
    /// its lock: statements issued at the same time have to reach the server
    /// together, and waiting on a lock would put them in a queue instead.
    fn transaction(&self, handle: u32) -> napi::Result<client::Transaction> {
        self.transactions
            .lock()
            .unwrap()
            .get(&handle)
            .cloned()
            .ok_or_else(|| napi::Error::from_reason(format!("Unknown transaction {handle}")))
    }

    fn take_transaction(&self, handle: u32) -> napi::Result<client::Transaction> {
        self.transactions
            .lock()
            .unwrap()
            .remove(&handle)
            .ok_or_else(|| napi::Error::from_reason(format!("Unknown transaction {handle}")))
    }

    fn hold(
        &self,
        rows: Vec<tokio_postgres::Row>,
        columns: Vec<client::Column>,
    ) -> napi::Result<PgQueryResult> {
        let types = columns
            .iter()
            .map(|column| column.ty.clone())
            .collect::<Vec<_>>();
        let arena = rows::into_arena(&rows, &types).map_err(to_napi)?;
        let result = PgQueryResult {
            handle: self.next_handle.fetch_add(1, Ordering::Relaxed),
            names: columns.into_iter().map(|column| column.name).collect(),
            kinds: types
                .iter()
                .map(|ty| rows::column_read_kind(ty) as u8)
                .collect(),
            element_kinds: types.iter().map(rows::element_read_kind).collect(),
            rows: arena.rows() as u32,
        };
        self.results.lock().unwrap().insert(result.handle, arena);
        Ok(result)
    }
}

fn to_params(params: Vec<Option<String>>) -> Vec<Param> {
    params
        .into_iter()
        .map(|param| match param {
            None => Param::Null,
            Some(text) => Param::Text(text),
        })
        .collect()
}

/// What a history table is asked about, for the two statements a rollback runs.
#[napi(object)]
pub struct PgHistoryQueryInput {
    pub pg_schema: String,
    pub history_table: String,
    pub data_columns: Vec<String>,
    pub key_columns: Vec<String>,
    pub chain_id_column: Option<String>,
    pub checkpoint_column: String,
    pub change_column: String,
    /// `SharedAcrossChains` or `PerChain`.
    pub sequence: String,
}

impl From<PgHistoryQueryInput> for HistoryQuery {
    fn from(input: PgHistoryQueryInput) -> Self {
        HistoryQuery {
            pg_schema: input.pg_schema,
            history_table: input.history_table,
            data_columns: input.data_columns,
            key_columns: input.key_columns,
            chain_id_column: input.chain_id_column,
            checkpoint_column: input.checkpoint_column,
            change_column: input.change_column,
        }
    }
}

#[napi]
pub fn pg_rollback_pre_target_rows_query(input: PgHistoryQueryInput) -> napi::Result<String> {
    let sequence = Sequence::parse(&input.sequence).map_err(to_napi)?;
    HistoryQuery::from(input)
        .pre_target_rows(sequence)
        .map_err(to_napi)
}

#[napi]
pub fn pg_rollback_removed_ids_query(input: PgHistoryQueryInput) -> napi::Result<String> {
    let sequence = Sequence::parse(&input.sequence).map_err(to_napi)?;
    HistoryQuery::from(input)
        .removed_ids(sequence)
        .map_err(to_napi)
}

/// What a delete needs recorded in an entity's history.
#[napi(object)]
pub struct PgDeleteRowsInput {
    pub pg_schema: String,
    pub history_table: String,
    /// The entity's own columns, in the order the table declares them.
    pub columns: Vec<String>,
    pub id_column: String,
    pub checkpoint_column: String,
    pub change_column: String,
    pub delete_variant: String,
    /// Set only when the flush group names a chain and the entity has a column
    /// for one.
    pub chain_id_column: Option<String>,
    pub id_pg_type: String,
    pub checkpoint_pg_type: String,
}

#[napi]
pub fn pg_insert_delete_rows_query(input: PgDeleteRowsInput) -> String {
    rollback::insert_delete_rows_query(
        &input.pg_schema,
        &input.history_table,
        &input.columns,
        &input.id_column,
        &input.checkpoint_column,
        &input.change_column,
        &input.delete_variant,
        input.chain_id_column.as_deref(),
        &input.id_pg_type,
        &input.checkpoint_pg_type,
    )
}

#[napi]
pub fn pg_update_by_id_query(
    pg_schema: String,
    table: String,
    id_column: String,
    columns: Vec<String>,
) -> String {
    internal::update_by_id_query(&pg_schema, &table, &id_column, &columns)
}

#[napi]
pub fn pg_set_by_unnest_query(
    pg_schema: String,
    table: String,
    id_column: String,
    set_column: String,
    id_array_type: String,
    value_array_type: String,
    relation: String,
) -> String {
    internal::set_by_unnest_query(
        &pg_schema,
        &table,
        &id_column,
        &set_column,
        &id_array_type,
        &value_array_type,
        &relation,
    )
}

/// A batch on its way in, held between `beginStage` and the statement that
/// binds it.
struct StagedBatch {
    arena: Arena,
    names: Vec<String>,
}

/// A table's shape, registered once so a batch for it only has to say how many
/// rows it holds.
struct WriteSchema {
    names: Vec<String>,
    kinds: Vec<ColumnKind>,
}

fn column_kind(ordinal: u8) -> napi::Result<ColumnKind> {
    Ok(match ordinal {
        0 => ColumnKind::F64,
        1 => ColumnKind::U64,
        2 => ColumnKind::I64,
        3 => ColumnKind::Text,
        4 => ColumnKind::Bytes,
        5 => ColumnKind::List,
        unknown => {
            return Err(napi::Error::from_reason(format!(
                "Unknown staged column kind {unknown}"
            )))
        }
    })
}

#[napi]
impl PgClient {
    /// Registers a table's shape. A batch for it then only has to say how many
    /// rows it holds.
    ///
    /// No column of arrays: unnesting one spreads it across the rows instead of
    /// keeping it as a value, so a table holding one takes the statement that
    /// binds every cell on its own and never reaches here.
    #[napi]
    pub fn register_write_table(&self, names: Vec<String>, kinds: Vec<u8>) -> napi::Result<u32> {
        let kinds = kinds
            .into_iter()
            .map(|ordinal| match column_kind(ordinal)? {
                ColumnKind::List => Err(napi::Error::from_reason(
                    "a table with an array column is written one row at a time, not staged",
                )),
                kind => Ok(kind),
            })
            .collect::<napi::Result<Vec<_>>>()?;
        let handle = self.next_handle.fetch_add(1, Ordering::Relaxed);
        self.write_tables
            .lock()
            .unwrap()
            .insert(handle, WriteSchema { names, kinds });
        Ok(handle)
    }

    /// Lays out a batch and lends JavaScript the memory to fill it in. Nothing
    /// may await between here and `commitStage` — see the phase rules in
    /// `columnar`.
    #[napi]
    pub fn begin_stage<'env>(
        &self,
        env: &'env Env,
        table: u32,
        rows: u32,
    ) -> napi::Result<Object<'env>> {
        let (names, specs) = {
            let tables = self.write_tables.lock().unwrap();
            let schema = tables
                .get(&table)
                .ok_or_else(|| napi::Error::from_reason(format!("Unknown write table {table}")))?;
            (
                schema.names.clone(),
                schema
                    .kinds
                    .iter()
                    .map(|&kind| ArenaColumn::Scalar(kind))
                    .collect::<Vec<_>>(),
            )
        };

        let mut arena = Arena::new_filled(rows as usize, &specs);
        arena.reopen_for_filling();
        let buffers = columnar::js::expose(env, &mut arena)?;
        let handle = self.next_handle.fetch_add(1, Ordering::Relaxed);
        // Storing the arena moves its `Vec` headers, not the allocations the
        // buffers above point into, so the lending survives the move.
        self.staged
            .lock()
            .unwrap()
            .insert(handle, StagedBatch { arena, names });
        let mut result = Object::new(env)?;
        result.set("handle", handle)?;
        result.set("buffers", buffers)?;
        Ok(result)
    }

    #[napi]
    pub fn grow_stage<'env>(
        &self,
        env: &'env Env,
        handle: u32,
        column: u32,
        needed: u32,
        stale: ArrayBuffer,
    ) -> napi::Result<ArrayBuffer<'env>> {
        let mut staged = self.staged.lock().unwrap();
        let staged = staged
            .get_mut(&handle)
            .ok_or_else(|| napi::Error::from_reason(format!("Unknown staged batch {handle}")))?;
        columnar::js::grow(env, &mut staged.arena, column, needed, stale)
    }

    #[napi]
    pub fn commit_stage(&self, handle: u32, buffers: Vec<ArrayBuffer>) -> napi::Result<()> {
        let mut staged = self.staged.lock().unwrap();
        Self::detach_or_abandon(&mut staged, handle, buffers)?;
        let staged = staged
            .get_mut(&handle)
            .ok_or_else(|| napi::Error::from_reason(format!("Unknown staged batch {handle}")))?;
        let names = staged.names.clone();
        staged.arena.seal(&names).map_err(to_napi)
    }

    /// Gives up on a batch. Whatever sent the caller here is the error worth
    /// reading, so a batch that cannot be handed back is abandoned rather than
    /// reported over the top of it.
    #[napi]
    pub fn abort_stage(&self, handle: u32, buffers: Vec<ArrayBuffer>) -> napi::Result<()> {
        let mut staged = self.staged.lock().unwrap();
        if !staged.contains_key(&handle) {
            return Ok(());
        }
        let _ = Self::detach_or_abandon(&mut staged, handle, buffers);
        staged.remove(&handle);
        Ok(())
    }

    /// Runs `sql` with the staged batch bound, and frees the batch either way.
    #[napi]
    pub async fn execute_staged(
        &self,
        transaction: Option<u32>,
        sql: String,
        handle: u32,
    ) -> napi::Result<()> {
        let staged =
            self.staged.lock().unwrap().remove(&handle).ok_or_else(|| {
                napi::Error::from_reason(format!("Unknown staged batch {handle}"))
            })?;
        let params = write::unnest_params(&staged.arena).map_err(to_napi)?;
        match transaction {
            Some(transaction) => self.transaction(transaction)?.execute(&sql, &params).await,
            None => self.inner.execute(&sql, &params).await,
        }
        .map(|_| ())
        .map_err(to_napi)
    }
}

impl PgClient {
    /// Detaches a staged batch's buffers. A batch that cannot hand them all back
    /// still has a JavaScript view into its memory, so that allocation is
    /// abandoned rather than freed.
    fn detach_or_abandon(
        staged: &mut HashMap<u32, StagedBatch>,
        handle: u32,
        buffers: Vec<ArrayBuffer>,
    ) -> napi::Result<()> {
        let Some(entry) = staged.get_mut(&handle) else {
            return Err(napi::Error::from_reason(format!(
                "Unknown staged batch {handle}"
            )));
        };
        let detached = columnar::js::detach_all(&mut entry.arena, buffers);
        if detached.is_err() {
            std::mem::forget(staged.remove(&handle));
        }
        detached
    }
}
