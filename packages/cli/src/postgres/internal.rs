//! The tables the indexer keeps for itself, and every statement against them.

use super::ddl::{ColumnSpec, TableSpec};
use super::history::{bounds, Sequence};
use super::pg_type::{pg_field_type, ChainIdMode, FieldType};

pub const CHAINS: &str = "envio_chains";
pub const INFO: &str = "envio_info";
pub const CONTRACTS: &str = "envio_contracts";
pub const ADDRESSES: &str = "envio_addresses";
pub const CHECKPOINTS: &str = "envio_checkpoints";
pub const META_VIEW: &str = "_meta";
pub const CHAIN_METADATA_VIEW: &str = "chain_metadata";

/// The registration block a config-declared address is stored with, which
/// tells it apart from one a handler registered.
pub const CONFIG_REGISTRATION_BLOCK: i32 = -1;

fn column(name: &str, field_type: FieldType) -> ColumnSpec {
    ColumnSpec {
        name: name.to_string(),
        field_type,
        is_array: false,
        is_nullable: false,
        is_primary_key: false,
        default_value: None,
    }
}

fn key(name: &str, field_type: FieldType) -> ColumnSpec {
    ColumnSpec {
        is_primary_key: true,
        ..column(name, field_type)
    }
}

fn nullable(name: &str, field_type: FieldType) -> ColumnSpec {
    ColumnSpec {
        is_nullable: true,
        ..column(name, field_type)
    }
}

fn table(table_name: &str, columns: Vec<ColumnSpec>) -> TableSpec {
    TableSpec {
        table_name: table_name.to_string(),
        columns,
        partition_by_column: None,
    }
}

/// Every table the indexer keeps outside the entities', for a schema counting
/// checkpoints the way `sequence` says.
pub fn tables(sequence: Sequence) -> Vec<TableSpec> {
    vec![
        table(
            CHAINS,
            vec![
                key("id", FieldType::ChainId),
                // Chain ids are only unique within an ecosystem (HOS-1880: Svm
                // ids are Envio-assigned), so consumers treat (ecosystem, id)
                // as the chain's identity.
                column("ecosystem", FieldType::String),
                column("start_block", FieldType::Int32),
                nullable("end_block", FieldType::Int32),
                column("max_reorg_depth", FieldType::Int32),
                // The latest block fetched from the source.
                column("buffer_block", FieldType::Int32),
                // The height of the source in use.
                column("source_block", FieldType::Int32),
                nullable("first_event_block", FieldType::Int32),
                // When the chain caught up, which the TUI and the Hosted
                // Service read as how long historical sync took.
                nullable("ready_at", FieldType::Date),
                column("events_processed", FieldType::UInt52),
                column("_is_hyper_sync", FieldType::Boolean),
                // The block every event up to and including has been processed.
                column("progress_block", FieldType::Int32),
                // When that block was produced, so `now() - progress_block_time`
                // is how far behind chain time the indexer is.
                nullable("progress_block_time", FieldType::Date),
                // The last checkpoint the chain committed. Kept here rather than
                // read off the checkpoints: their rows are only kept while a
                // rollback could reach them, but an append-only sink resolves
                // current state through every id ever handed out, so a resume
                // has to continue the sequence where no row backs it.
                column("checkpoint_id", FieldType::UInt64),
            ],
        ),
        // A singleton, which the fixed default and the key on it make sure of.
        // The config is TEXT rather than JSONB so it reads back byte for byte:
        // jsonb re-spells numbers and escapes, which the resume compat check
        // would report as changes.
        table(
            INFO,
            vec![
                ColumnSpec {
                    default_value: Some("1".to_string()),
                    ..key("id", FieldType::Int32)
                },
                column("config", FieldType::String),
            ],
        ),
        // The canonical contract ids: a name's position in the list written at
        // initialize, so an id names the same contract on every chain and
        // across restarts.
        table(
            CONTRACTS,
            vec![
                key("id", FieldType::SmallInt),
                column("name", FieldType::String),
            ],
        ),
        table(
            ADDRESSES,
            vec![
                key("chain_id", FieldType::ChainId),
                key("address", FieldType::Bytea),
                key("contract_id", FieldType::SmallInt),
                column("registration_block", FieldType::Int32),
            ],
        ),
        // Per chain, the chain leads the key: ids are only unique within it,
        // and every bound a rollback or a prune applies names it. Under one
        // shared sequence the id is unique by itself and the bounds are id
        // ranges with no chain in them, which a key led by the chain can't
        // serve.
        table(
            CHECKPOINTS,
            vec![
                ColumnSpec {
                    is_primary_key: sequence == Sequence::PerChain,
                    ..column("chain_id", FieldType::ChainId)
                },
                key("id", FieldType::UInt64),
                column("block_number", FieldType::Int32),
                nullable("block_hash", FieldType::String),
                column("events_processed", FieldType::Int32),
            ],
        ),
    ]
}

pub fn chain_id_array(pg_schema: &str, chain_id_mode: ChainIdMode) -> String {
    pg_field_type(
        &FieldType::ChainId,
        pg_schema,
        true,
        false,
        false,
        chain_id_mode,
    )
}

/// What a chain starts out as.
pub struct ChainConfig {
    pub id: i64,
    pub ecosystem: String,
    pub start_block: i32,
    pub end_block: Option<i32>,
    pub max_reorg_depth: i32,
}

/// One `INSERT` for the chains' first rows, values written in: it runs inside
/// the initialization's multi-statement text, which binds nothing.
pub fn insert_chains(pg_schema: &str, chains: &[ChainConfig]) -> Option<String> {
    if chains.is_empty() {
        return None;
    }
    let rows = chains
        .iter()
        .map(|chain| {
            format!(
                "({}, '{}', {}, {}, {}, 0, NULL, -1, -1, NULL, NULL, 0, false, 0)",
                chain.id,
                chain.ecosystem.replace('\'', "''"),
                chain.start_block,
                chain
                    .end_block
                    .map_or("NULL".to_string(), |block| block.to_string()),
                chain.max_reorg_depth,
            )
        })
        .collect::<Vec<_>>();
    Some(format!(
        "INSERT INTO \"{pg_schema}\".\"{CHAINS}\" (\"id\", \"ecosystem\", \"start_block\", \
         \"end_block\", \"max_reorg_depth\", \"source_block\", \"first_event_block\", \
         \"buffer_block\", \"progress_block\", \"progress_block_time\", \"ready_at\", \
         \"events_processed\", \"_is_hyper_sync\", \"checkpoint_id\")\nVALUES {};",
        rows.join(",\n       ")
    ))
}

pub fn views(pg_schema: &str) -> String {
    format!(
        "CREATE VIEW \"{pg_schema}\".\"{META_VIEW}\" AS \n\
         SELECT \n  \
         \"id\" AS \"chainId\",\n  \
         \"ecosystem\" AS \"ecosystem\",\n  \
         \"start_block\" AS \"startBlock\", \n  \
         \"end_block\" AS \"endBlock\",\n  \
         \"progress_block\" AS \"progressBlock\",\n  \
         \"progress_block_time\" AS \"progressBlockTime\",\n  \
         \"buffer_block\" AS \"bufferBlock\",\n  \
         \"first_event_block\" AS \"firstEventBlock\",\n  \
         \"events_processed\"::float4 AS \"eventsProcessed\",\n  \
         \"source_block\" AS \"sourceBlock\",\n  \
         \"ready_at\" AS \"readyAt\",\n  \
         (\"ready_at\" IS NOT NULL) AS \"isReady\"\n\
         FROM \"{pg_schema}\".\"{CHAINS}\"\n\
         ORDER BY \"id\";\n\
         CREATE VIEW \"{pg_schema}\".\"{CHAIN_METADATA_VIEW}\" AS \n\
         SELECT \n  \
         \"source_block\" AS \"block_height\",\n  \
         \"id\" AS \"chain_id\",\n  \
         \"ecosystem\" AS \"ecosystem\",\n  \
         \"end_block\" AS \"end_block\", \n  \
         \"first_event_block\" AS \"first_event_block_number\",\n  \
         \"_is_hyper_sync\" AS \"is_hyper_sync\",\n  \
         \"buffer_block\" AS \"latest_fetched_block_number\",\n  \
         \"progress_block\" AS \"latest_processed_block\",\n  \
         0 AS \"num_batches_fetched\",\n  \
         \"events_processed\"::float4 AS \"num_events_processed\",\n  \
         \"start_block\" AS \"start_block\",\n  \
         \"ready_at\" AS \"timestamp_caught_up_to_head_or_endblock\"\n\
         FROM \"{pg_schema}\".\"{CHAINS}\";"
    )
}

pub fn write_info(pg_schema: &str) -> String {
    format!(
        "INSERT INTO \"{pg_schema}\".\"{INFO}\" (\"id\", \"config\") VALUES (1, $1) ON CONFLICT \
         (\"id\") DO UPDATE SET \"config\" = EXCLUDED.\"config\";"
    )
}

pub fn read_info(pg_schema: &str) -> String {
    format!("SELECT \"config\" FROM \"{pg_schema}\".\"{INFO}\" LIMIT 1;")
}

pub fn insert_contracts(pg_schema: &str) -> String {
    format!(
        "INSERT INTO \"{pg_schema}\".\"{CONTRACTS}\" (\"id\", \"name\")\nSELECT * FROM \
         unnest($1::SMALLINT[],$2::TEXT[]);"
    )
}

pub fn read_contracts(pg_schema: &str) -> String {
    format!("SELECT \"name\" FROM \"{pg_schema}\".\"{CONTRACTS}\" ORDER BY \"id\";")
}

/// A registration already stored is one a reorg replayed, so it is kept rather
/// than refused.
pub fn insert_addresses(pg_schema: &str, chain_id_mode: ChainIdMode) -> String {
    format!(
        "INSERT INTO \"{pg_schema}\".\"{ADDRESSES}\" (\"chain_id\", \"address\", \
         \"contract_id\", \"registration_block\")\nSELECT * FROM \
         unnest($1::{},$2::BYTEA[],$3::SMALLINT[],$4::INTEGER[])\nON CONFLICT (\"chain_id\", \
         \"address\", \"contract_id\") DO NOTHING;",
        chain_id_array(pg_schema, chain_id_mode)
    )
}

pub fn delete_addresses(pg_schema: &str, chain_id_mode: ChainIdMode) -> String {
    format!(
        "DELETE FROM \"{pg_schema}\".\"{ADDRESSES}\"\nUSING unnest($1::{},$2::BYTEA[],\
         $3::SMALLINT[]) AS dead(chain_id, address, contract_id)\nWHERE \
         \"{ADDRESSES}\".\"chain_id\" = dead.chain_id\n  AND \"{ADDRESSES}\".\"address\" = \
         dead.address\n  AND \"{ADDRESSES}\".\"contract_id\" = dead.contract_id;",
        chain_id_array(pg_schema, chain_id_mode)
    )
}

/// Plain rows rather than an aggregate per chain: one chain's `json_agg` can
/// outgrow the longest string V8 will hold.
pub fn read_addresses(pg_schema: &str, only_config: bool) -> String {
    let filter = if only_config {
        format!(" WHERE \"registration_block\" = {CONFIG_REGISTRATION_BLOCK}")
    } else {
        String::new()
    };
    format!(
        "SELECT \"chain_id\" as \"chainId\",\n\"address\" as \"address\",\n\"contract_id\" as \
         \"contractId\",\n\"registration_block\" as \"registrationBlock\"\nFROM \
         \"{pg_schema}\".\"{ADDRESSES}\"{filter};"
    )
}

pub fn read_stored_chains(pg_schema: &str) -> String {
    format!(
        "SELECT \"id\"::float8, \"ecosystem\", \"start_block\", \"end_block\", \
         \"max_reorg_depth\" FROM \"{pg_schema}\".\"{CHAINS}\";"
    )
}

pub fn read_resumed_chains(pg_schema: &str) -> String {
    format!(
        "SELECT \"id\"::float8, \"start_block\", \"end_block\", \"max_reorg_depth\", \
         \"first_event_block\", (extract(epoch from \"ready_at\") * 1000)::float8, \
         \"events_processed\"::float8, \"progress_block\", \
         extract(epoch from \"progress_block_time\")::float8, \"source_block\", \
         \"checkpoint_id\"::TEXT FROM \"{pg_schema}\".\"{CHAINS}\";"
    )
}

pub fn set_progress(pg_schema: &str) -> String {
    format!(
        "UPDATE \"{pg_schema}\".\"{CHAINS}\"\nSET \"progress_block\" = $2,\n    \
         \"progress_block_time\" = to_timestamp($3::float8),\n    \
         \"events_processed\" = $4,\n    \"source_block\" = $5\nWHERE \"id\" = $1;"
    )
}

/// A chain that caught up never un-catches up, so a null `ready_at` keeps the
/// stamp: metadata is written on a throttle of its own, and a write staged
/// before the stamp can land after it.
pub fn set_meta(pg_schema: &str) -> String {
    format!(
        "UPDATE \"{pg_schema}\".\"{CHAINS}\"\nSET \"buffer_block\" = $2,\n    \
         \"first_event_block\" = $3,\n    \
         \"ready_at\" = COALESCE(to_timestamp($4::float8 / 1000), \"ready_at\"),\n    \
         \"_is_hyper_sync\" = $5\nWHERE \"id\" = $1;"
    )
}

/// `IS NULL` so a chain keeps the time it first caught up at, as the in-memory
/// state does: a partial recovery (a chain added to an indexer already synced)
/// would otherwise restamp the chains already ready, and the next metadata
/// write would push the stale in-memory value back over it.
pub fn set_ready_at(pg_schema: &str) -> String {
    format!(
        "UPDATE \"{pg_schema}\".\"{CHAINS}\"\nSET \"ready_at\" = to_timestamp($1::float8 / \
         1000)\nWHERE \"id\" = $2\n  AND \"ready_at\" IS NULL;"
    )
}

pub fn set_frontier(pg_schema: &str, chain_id_mode: ChainIdMode) -> String {
    format!(
        "UPDATE \"{pg_schema}\".\"{CHAINS}\"\nSET \"checkpoint_id\" = \
         envio_frontier.checkpoint_id\nFROM unnest($1::{},$2::BIGINT[]) AS \
         envio_frontier(chain_id, checkpoint_id)\nWHERE \"{CHAINS}\".\"id\" = \
         envio_frontier.chain_id;",
        chain_id_array(pg_schema, chain_id_mode)
    )
}

pub fn insert_checkpoints(pg_schema: &str, chain_id_mode: ChainIdMode) -> String {
    format!(
        "INSERT INTO \"{pg_schema}\".\"{CHECKPOINTS}\" (\"id\", \"chain_id\", \"block_number\", \
         \"block_hash\", \"events_processed\")\nSELECT * FROM unnest($1::BIGINT[],$2::{},\
         $3::INTEGER[],$4::TEXT[],$5::INTEGER[]);",
        chain_id_array(pg_schema, chain_id_mode)
    )
}

/// The checkpoints a reorg could still roll back to, the safe block's own
/// included so the safe checkpoint can be tracked from it.
///
/// Ordered by id, which within a chain is block order: both consumers read
/// them ascending, and physical order can't stand in for it, since a rollback
/// frees space later checkpoints are written back into.
pub fn read_reorg_checkpoints(pg_schema: &str) -> String {
    format!(
        "WITH reorg_chains AS (\n  \
         SELECT \"id\" as id, \"source_block\" - \"max_reorg_depth\" AS safe_block\n  \
         FROM \"{pg_schema}\".\"{CHAINS}\"\n  \
         WHERE \"max_reorg_depth\" > 0\n    \
         AND \"progress_block\" > \"source_block\" - \"max_reorg_depth\"\n\
         )\n\
         SELECT cp.\"id\"::TEXT, cp.\"chain_id\"::float8, cp.\"block_number\", cp.\"block_hash\"\n\
         FROM \"{pg_schema}\".\"{CHECKPOINTS}\" cp\n\
         INNER JOIN reorg_chains rc ON cp.\"chain_id\" = rc.id\n\
         WHERE cp.\"block_hash\" IS NOT NULL\n  \
         AND cp.\"block_number\" >= rc.safe_block\n\
         ORDER BY cp.\"id\";"
    )
}

fn checkpoints_ref(pg_schema: &str) -> String {
    format!("\"{pg_schema}\".\"{CHECKPOINTS}\"")
}

pub fn rollback_checkpoints(pg_schema: &str, sequence: Sequence) -> anyhow::Result<String> {
    let table_ref = checkpoints_ref(pg_schema);
    let bounds = bounds(sequence, Some("chain_id"), &table_ref)?;
    Ok(format!(
        "DELETE FROM {table_ref}{} WHERE \"id\" > {}{};",
        bounds.using, bounds.checkpoint_id, bounds.using_match
    ))
}

pub fn prune_checkpoints(pg_schema: &str, sequence: Sequence) -> anyhow::Result<String> {
    let table_ref = checkpoints_ref(pg_schema);
    let bounds = bounds(sequence, Some("chain_id"), &table_ref)?;
    Ok(format!(
        "DELETE FROM {table_ref}{} WHERE \"id\" < {}{};",
        bounds.using, bounds.checkpoint_id, bounds.using_match
    ))
}

pub fn rollback_target_checkpoint(pg_schema: &str) -> String {
    format!(
        "SELECT \"id\"::TEXT FROM \"{pg_schema}\".\"{CHECKPOINTS}\"\nWHERE \"chain_id\" = $1 \
         AND \"block_number\" <= $2\nORDER BY \"id\" DESC\nLIMIT 1;"
    )
}

pub fn rollback_progress_diff(pg_schema: &str, sequence: Sequence) -> anyhow::Result<String> {
    let bounds = bounds(sequence, Some("chain_id"), "t")?;
    Ok(format!(
        "SELECT t.\"chain_id\"::float8, SUM(t.\"events_processed\")::TEXT, \
         MIN(t.\"block_number\") - 1\nFROM \"{pg_schema}\".\"{CHECKPOINTS}\" t{}\nWHERE \
         t.\"id\" > {}\nGROUP BY t.\"chain_id\";",
        bounds.join, bounds.checkpoint_id
    ))
}

/// The effect caches in the schema: tables named like one whose columns are
/// exactly an `id` and an `output`, so a user entity matching the name pattern
/// is never mistaken for a cache.
pub fn effect_cache_tables(pg_schema: &str) -> String {
    format!(
        "SELECT t.table_name::TEXT\nFROM information_schema.tables t\nWHERE t.table_schema = \
         '{pg_schema}'\nAND t.table_name ~ '^envio_([0-9]+_)?effect_.+'\nAND (\n  SELECT \
         array_agg(c.column_name::text ORDER BY c.column_name::text)\n  FROM \
         information_schema.columns c\n  WHERE c.table_schema = t.table_schema AND c.table_name \
         = t.table_name\n) = ARRAY['id', 'output'];"
    )
}

/// The name comes from the catalog, so anything cache-shaped created out of
/// band reaches here; both identifiers are quoted with embedded quotes doubled.
pub fn count_rows(pg_schema: &str, table_name: &str) -> String {
    format!(
        "SELECT COUNT(*)::int FROM {}.{};",
        quote_ident(pg_schema),
        quote_ident(table_name)
    )
}

pub fn quote_ident(ident: &str) -> String {
    format!("\"{}\"", ident.replace('"', "\"\""))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::postgres::ddl::create_table_query;

    fn ddl(sequence: Sequence) -> Vec<String> {
        tables(sequence)
            .iter()
            .map(|table| create_table_query(table, "s", false, ChainIdMode::Int32).unwrap())
            .collect()
    }

    /// Only a per-chain sequence keys the checkpoints by chain.
    #[test]
    fn the_checkpoints_key_follows_the_sequence() {
        assert_eq!(
            (
                ddl(Sequence::PerChain).last().cloned(),
                ddl(Sequence::SharedAcrossChains).last().cloned(),
            ),
            (
                Some(
                    "CREATE TABLE IF NOT EXISTS \"s\".\"envio_checkpoints\"(\"chain_id\" INTEGER \
                     NOT NULL, \"id\" BIGINT NOT NULL, \"block_number\" INTEGER NOT NULL, \
                     \"block_hash\" TEXT, \"events_processed\" INTEGER NOT NULL, PRIMARY \
                     KEY(\"chain_id\", \"id\"));"
                        .to_string()
                ),
                Some(
                    "CREATE TABLE IF NOT EXISTS \"s\".\"envio_checkpoints\"(\"chain_id\" INTEGER \
                     NOT NULL, \"id\" BIGINT NOT NULL, \"block_number\" INTEGER NOT NULL, \
                     \"block_hash\" TEXT, \"events_processed\" INTEGER NOT NULL, PRIMARY \
                     KEY(\"id\"));"
                        .to_string()
                ),
            )
        );
    }

    fn ddl_in(mode: ChainIdMode, table_name: &str) -> String {
        let table = tables(Sequence::PerChain)
            .into_iter()
            .find(|table| table.table_name == table_name)
            .unwrap();
        create_table_query(&table, "test_schema", false, mode).unwrap()
    }

    #[test]
    fn small_chain_ids_keep_integer_columns() {
        assert_eq!(
            (
                ddl_in(ChainIdMode::Int32, CHAINS),
                ddl_in(ChainIdMode::Int32, ADDRESSES),
            ),
            (
                "CREATE TABLE IF NOT EXISTS \"test_schema\".\"envio_chains\"(\"id\" INTEGER NOT \
                 NULL, \"ecosystem\" TEXT NOT NULL, \"start_block\" INTEGER NOT NULL, \
                 \"end_block\" INTEGER, \"max_reorg_depth\" INTEGER NOT NULL, \"buffer_block\" \
                 INTEGER NOT NULL, \"source_block\" INTEGER NOT NULL, \"first_event_block\" \
                 INTEGER, \"ready_at\" TIMESTAMP WITH TIME ZONE NULL, \"events_processed\" BIGINT \
                 NOT NULL, \"_is_hyper_sync\" BOOLEAN NOT NULL, \"progress_block\" INTEGER NOT \
                 NULL, \"progress_block_time\" TIMESTAMP WITH TIME ZONE NULL, \"checkpoint_id\" \
                 BIGINT NOT NULL, PRIMARY KEY(\"id\"));"
                    .to_string(),
                "CREATE TABLE IF NOT EXISTS \"test_schema\".\"envio_addresses\"(\"chain_id\" \
                 INTEGER NOT NULL, \"address\" BYTEA NOT NULL, \"contract_id\" SMALLINT NOT NULL, \
                 \"registration_block\" INTEGER NOT NULL, PRIMARY KEY(\"chain_id\", \"address\", \
                 \"contract_id\"));"
                    .to_string(),
            )
        );
    }

    /// Every chain-id column and every parameter cast for one widens together,
    /// or a wide id would be refused by the one that didn't.
    #[test]
    fn wide_chain_ids_widen_every_column_and_cast() {
        assert_eq!(
            (
                ddl_in(ChainIdMode::Int64, CHAINS),
                ddl_in(ChainIdMode::Int64, ADDRESSES),
                ddl_in(ChainIdMode::Int64, CHECKPOINTS),
                insert_checkpoints("s", ChainIdMode::Int64).contains("$2::BIGINT[]"),
                insert_addresses("s", ChainIdMode::Int64).contains("$1::BIGINT[]"),
                delete_addresses("s", ChainIdMode::Int64).contains("$1::BIGINT[]"),
                set_frontier("s", ChainIdMode::Int64).contains("$1::BIGINT[]"),
            ),
            (
                ddl_in(ChainIdMode::Int32, CHAINS).replace("\"id\" INTEGER", "\"id\" BIGINT"),
                ddl_in(ChainIdMode::Int32, ADDRESSES)
                    .replace("\"chain_id\" INTEGER", "\"chain_id\" BIGINT"),
                ddl_in(ChainIdMode::Int32, CHECKPOINTS)
                    .replace("\"chain_id\" INTEGER", "\"chain_id\" BIGINT"),
                true,
                true,
                true,
                true,
            )
        );
    }

    #[test]
    fn a_chain_starts_with_nothing_processed() {
        assert_eq!(
            insert_chains(
                "s",
                &[
                    ChainConfig {
                        id: 1,
                        ecosystem: "evm".to_string(),
                        start_block: 10,
                        end_block: None,
                        max_reorg_depth: 200,
                    },
                    ChainConfig {
                        id: 2,
                        ecosystem: "fuel".to_string(),
                        start_block: 0,
                        end_block: Some(5),
                        max_reorg_depth: 0,
                    },
                ]
            ),
            Some(
                "INSERT INTO \"s\".\"envio_chains\" (\"id\", \"ecosystem\", \"start_block\", \
                 \"end_block\", \"max_reorg_depth\", \"source_block\", \"first_event_block\", \
                 \"buffer_block\", \"progress_block\", \"progress_block_time\", \"ready_at\", \
                 \"events_processed\", \"_is_hyper_sync\", \"checkpoint_id\")\nVALUES (1, 'evm', \
                 10, NULL, 200, 0, NULL, -1, -1, NULL, NULL, 0, false, 0),\n       (2, 'fuel', 0, \
                 5, 0, 0, NULL, -1, -1, NULL, NULL, 0, false, 0);"
                    .to_string()
            )
        );
    }

    #[test]
    fn a_name_from_the_catalog_cannot_break_out_of_its_quotes() {
        assert_eq!(
            count_rows("s", "envio_effect_a\"; DROP TABLE x; --"),
            "SELECT COUNT(*)::int FROM \"s\".\"envio_effect_a\"\"; DROP TABLE x; --\";"
        );
    }
}
