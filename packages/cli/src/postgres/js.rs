//! The addon surface for the Postgres backend.

use napi_derive::napi;

use super::ddl::{self, ColumnSpec, TableSpec};
use super::index_definition::{self, Direction, IndexColumn, IndexDefinition};
use super::pg_type::{self, ChainIdMode, FieldType};

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
