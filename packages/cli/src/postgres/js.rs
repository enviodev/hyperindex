//! The addon surface for the Postgres backend.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Mutex;

use napi::bindgen_prelude::ArrayBuffer;
use napi::Env;
use napi_derive::napi;

use crate::columnar::{self, Arena};

use super::client::{self, PgConnectionOptions, SslSetting};
use super::ddl::{self, ColumnSpec, TableSpec};
use super::index_definition::{self, Direction, IndexColumn, IndexDefinition};
use super::param::Param;
use super::pg_type::{self, ChainIdMode, FieldType};
use super::rows;

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

fn to_napi(err: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{err:#}"))
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
            next_handle: AtomicU32::new(0),
        })
    }

    /// Runs statements that take no parameters, discarding any rows. More than
    /// one may be given at once, which is what the initialization relies on.
    #[napi]
    pub async fn batch(&self, sql: String) -> napi::Result<()> {
        self.inner.batch(&sql).await.map_err(to_napi)
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
        let params = to_params(params);
        let (rows, columns) = self.inner.query(&sql, &params).await.map_err(to_napi)?;
        let types = columns
            .iter()
            .map(|column| column.ty.clone())
            .collect::<Vec<_>>();
        let arena = rows::into_arena(&rows, &types).map_err(to_napi)?;

        let result = PgQueryResult {
            handle: self.next_handle.fetch_add(1, Ordering::Relaxed),
            names: columns.into_iter().map(|column| column.name).collect(),
            kinds: types.iter().map(|ty| rows::slot_kind(ty) as u8).collect(),
            rows: arena.rows() as u32,
        };
        self.results.lock().unwrap().insert(result.handle, arena);
        Ok(result)
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

    #[napi]
    pub async fn close(&self) {
        self.inner.close().await;
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
