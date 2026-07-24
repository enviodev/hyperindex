use super::{
    chain_helpers::get_max_reorg_depth_from_id,
    entity_parsing::{Entity, GraphQLEnum, Schema},
    env_interpolation::interpolate_config_variables,
    human_config::{
        self,
        evm::{
            Chain as EvmChain, EventConfig as EvmEventConfig, For, HumanConfig as EvmConfig, Rpc,
            RpcSelection,
        },
        fuel::{EventConfig as FuelEventConfig, HumanConfig as FuelConfig},
        HumanConfig,
    },
    hypersync_endpoints,
    validation::{self, validate_names_valid_rescript},
};
use crate::utils::dotenv::{self, EnvMap};
use crate::{
    config_parsing::human_config::evm::{RpcBlockField, RpcTransactionField},
    constants::{links, project_paths::DEFAULT_SCHEMA_PATH},
    evm::abi::AbiOrNestedAbi,
    fuel::abi::{FuelAbi, BURN_EVENT_NAME, CALL_EVENT_NAME, MINT_EVENT_NAME, TRANSFER_EVENT_NAME},
    project_paths::{path_utils, ParsedProjectPaths},
    type_schema::TypeIdent,
    utils::unique_hashmap,
};
use alloy_json_abi::{Event as AlloyEvent, JsonAbi};
use anyhow::{anyhow, Context, Result};
use itertools::Itertools;

use super::abi_compat::EventParam;
use regex::Regex;
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    env, fs,
    path::{Path, PathBuf},
};

use hypersync_client_solana::decode::{
    metaplex_token_metadata, schema_from_anchor_idl_json, EnumVariant as SvmEnumVariant,
    FieldType as SvmFieldType, InstructionSchema as SvmInstructionSchema,
    NamedField as SvmNamedField, ProgramSchema as SvmProgramSchema,
};

type ContractNameKey = String;
type NetworkIdKey = u64;
type EntityKey = String;
type GraphqlEnumKey = String;
type ChainMap = HashMap<NetworkIdKey, Chain>;
type ContractMap = HashMap<ContractNameKey, Contract>;
pub type EntityMap = HashMap<EntityKey, Entity>;
pub type GraphQlEnumMap = HashMap<GraphqlEnumKey, GraphQLEnum>;

#[derive(Debug, PartialEq)]
pub enum Ecosystem {
    Evm,
    Fuel,
    Svm,
}

// Allows to get an env var with a lazy loading of .env file
#[derive(Debug)]
pub struct EnvState {
    // Lazy loading of .env file
    maybe_dotenv: Option<EnvMap>,
    project_root: PathBuf,
}

impl EnvState {
    pub fn new(project_root: &Path) -> Self {
        EnvState {
            maybe_dotenv: None,
            project_root: PathBuf::from(project_root),
        }
    }

    pub fn var(&mut self, name: &str) -> Option<String> {
        match std::env::var(name) {
            Ok(val) => Some(val),
            Err(_) => {
                let result = match &self.maybe_dotenv {
                    Some(env_map) => env_map.var(name),
                    None => match dotenv::from_path(self.project_root.join(".env")) {
                        Ok(env_map) => {
                            self.maybe_dotenv = Some(env_map.clone());
                            env_map.var(name)
                        }
                        Err(err) => {
                            match err {
                                dotenv::Error::Io(_, _) => (),
                                _ => println!(
                                    "Warning: Failed loading .env file with unexpected error: \
                                         {err}"
                                ),
                            };
                            self.maybe_dotenv = Some(EnvMap::new());
                            Err(err)
                        }
                    },
                };
                result.ok()
            }
        }
    }
}

#[derive(Debug)]
struct ResolvedConfigFile {
    path: PathBuf,
    raw: String,
}

/// Supplies the inputs surrounding config.yaml without coupling the parser to
/// a filesystem project. Production uses `FilesystemConfigSource`; the NAPI
/// string entry point uses `MemoryConfigSource`.
trait ConfigSource {
    fn project_paths(&self) -> &ParsedProjectPaths;
    fn is_rescript(&self) -> bool;
    fn env_var(&mut self, name: &str) -> Option<String>;
    fn load_schema(&self, configured_path: &Option<String>) -> Result<Schema>;
    fn read_config_relative_file(&self, path: &str) -> Result<ResolvedConfigFile>;
    fn read_project_relative_file(&self, path: &str) -> Result<ResolvedConfigFile>;
}

struct FilesystemConfigSource<'a> {
    project_paths: &'a ParsedProjectPaths,
    env: EnvState,
}

impl<'a> FilesystemConfigSource<'a> {
    fn new(project_paths: &'a ParsedProjectPaths) -> Self {
        Self {
            project_paths,
            env: EnvState::new(&project_paths.project_root),
        }
    }
}

impl ConfigSource for FilesystemConfigSource<'_> {
    fn project_paths(&self) -> &ParsedProjectPaths {
        self.project_paths
    }

    fn is_rescript(&self) -> bool {
        self.project_paths
            .project_root
            .join("rescript.json")
            .exists()
    }

    fn env_var(&mut self, name: &str) -> Option<String> {
        self.env.var(name)
    }

    fn load_schema(&self, configured_path: &Option<String>) -> Result<Schema> {
        Schema::parse_from_file(self.project_paths, configured_path)
            .context("Parsing schema file for config")
    }

    fn read_config_relative_file(&self, path: &str) -> Result<ResolvedConfigFile> {
        let resolved_path =
            path_utils::get_config_path_relative_to_root(self.project_paths, PathBuf::from(path))
                .context("Failed to resolve file relative to config")?;
        let raw = fs::read_to_string(&resolved_path)
            .with_context(|| format!("Failed to read file at \"{path}\""))?;
        Ok(ResolvedConfigFile {
            path: resolved_path,
            raw,
        })
    }

    fn read_project_relative_file(&self, path: &str) -> Result<ResolvedConfigFile> {
        let resolved_path = self.project_paths.project_root.join(path);
        let raw = fs::read_to_string(&resolved_path)
            .with_context(|| format!("Failed to read file at \"{path}\""))?;
        Ok(ResolvedConfigFile {
            path: resolved_path,
            raw,
        })
    }
}

struct MemoryConfigSource<'a> {
    project_paths: ParsedProjectPaths,
    schema: Option<&'a str>,
    env: &'a HashMap<String, String>,
    files: &'a HashMap<String, String>,
    is_rescript: bool,
}

impl<'a> MemoryConfigSource<'a> {
    fn new(
        schema: Option<&'a str>,
        env: &'a HashMap<String, String>,
        files: &'a HashMap<String, String>,
        is_rescript: bool,
    ) -> Self {
        Self {
            project_paths: ParsedProjectPaths::default(),
            schema,
            env,
            files,
            is_rescript,
        }
    }

    fn read_virtual_file(&self, path: &str) -> Result<ResolvedConfigFile> {
        let normalized = path_utils::normalize_path(PathBuf::from(path));
        let raw = self
            .files
            .get(path)
            .or_else(|| {
                self.files.iter().find_map(|(candidate, raw)| {
                    (path_utils::normalize_path(PathBuf::from(candidate)) == normalized)
                        .then_some(raw)
                })
            })
            .cloned()
            .ok_or_else(|| anyhow!("Virtual config file \"{path}\" was not provided"))?;
        Ok(ResolvedConfigFile {
            path: normalized,
            raw,
        })
    }
}

impl ConfigSource for MemoryConfigSource<'_> {
    fn project_paths(&self) -> &ParsedProjectPaths {
        &self.project_paths
    }

    fn is_rescript(&self) -> bool {
        self.is_rescript
    }

    fn env_var(&mut self, name: &str) -> Option<String> {
        self.env.get(name).cloned()
    }

    fn load_schema(&self, _configured_path: &Option<String>) -> Result<Schema> {
        match self.schema.map(str::trim) {
            None | Some("") => Ok(Schema::empty()),
            Some(schema) => Schema::from_string(schema),
        }
    }

    fn read_config_relative_file(&self, path: &str) -> Result<ResolvedConfigFile> {
        self.read_virtual_file(path)
    }

    fn read_project_relative_file(&self, path: &str) -> Result<ResolvedConfigFile> {
        self.read_virtual_file(path)
    }
}

//Validates version name (3 digits separated by period ".")
//Returns false if there are any additional chars as this should imply
//it is a dev release version or an unstable release
fn is_valid_release_version_number(version: &str) -> bool {
    let re_version_pattern = Regex::new(r"^\d+\.\d+\.\d+(-(rc|alpha)\.\d+)?$")
        .expect("version regex pattern should be valid regex");
    re_version_pattern.is_match(version) || version.contains("-main-")
}

/// Version baked into the binary at compile time from Cargo.toml.
/// CI patches Cargo.toml with the release version before building.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Returns the envio npm package specifier for codegen.
/// - Release builds (valid semver `VERSION`) → that version, for npm.
/// - Dev builds → `file:{envio_package_dir}`, where the caller (NAPI host
///   or a test) supplies the absolute path to `packages/envio`.
///
/// A dev build without an `envio_package_dir` is a configuration error —
/// there's no reliable way to locate the JS package from inside Rust alone.
pub fn get_envio_version(envio_package_dir: Option<&str>) -> Result<String> {
    if is_valid_release_version_number(VERSION) {
        return Ok(VERSION.to_string());
    }

    let pkg_dir = envio_package_dir.ok_or_else(|| {
        anyhow!(
            "envio version is not a release ({VERSION}) and no envio_package_dir was supplied. \
             Run via the NAPI host (which resolves it from import.meta.url) or pass an explicit path."
        )
    })?;

    // Format as `file:{dir}` so the generated `package.json` resolves to
    // the SAME envio instance as the parent, avoiding duplicate module
    // instances that break shared registries (HandlerRegister, Prometheus
    // metrics).
    let pkg = PathBuf::from(pkg_dir);
    if !pkg.is_dir() {
        return Err(anyhow!(
            "envio_package_dir does not exist or is not a directory: {}",
            pkg.display()
        ));
    }
    Ok(format!("file:{}", pkg.to_string_lossy()))
}

#[derive(Debug)]
pub struct SystemConfig {
    pub name: String,
    pub schema_path: String,
    pub parsed_project_paths: ParsedProjectPaths,
    pub chains: ChainMap,
    pub contracts: ContractMap,
    pub rollback_on_reorg: bool,
    pub save_full_history: bool,
    pub schema: Schema,
    pub field_selection: FieldSelection,
    pub enable_raw_events: bool,
    pub storage: Storage,
    pub human_config: HumanConfig,
    pub lowercase_addresses: bool,
    pub handlers: Option<String>,
    // Project uses ReScript when a rescript.json sits at the project root —
    // file existence is the source of truth; no explicit flag in config.yaml.
    pub is_rescript: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StorageBackend {
    // Whether entities without an @storage directive are stored in the
    // backend. A single enabled backend is implicitly the default; with
    // multiple backends none is, unless opted in via `default: true`.
    pub entity_default: bool,
    pub column_name_format: human_config::ColumnNameFormat,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Storage {
    pub postgres: Option<StorageBackend>,
    pub clickhouse: Option<StorageBackend>,
}

impl Storage {
    pub fn resolve(config: Option<&human_config::StorageConfig>) -> Result<Self> {
        let (postgres_config, clickhouse_config) = match config {
            None => (None, None),
            Some(s) => (s.postgres.as_ref(), s.clickhouse.as_ref()),
        };
        let clickhouse_enabled = clickhouse_config.is_some_and(|c| c.is_enabled());
        // When clickhouse is enabled, postgres must be set explicitly
        // so that the validation below catches a clickhouse-only config
        // instead of silently defaulting postgres to true.
        let postgres_enabled = postgres_config.map_or(!clickhouse_enabled, |c| c.is_enabled());
        if clickhouse_enabled && !postgres_enabled {
            return Err(anyhow!(
                "ClickHouse is not supported as a single storage yet. Please enable Postgres \
                 alongside ClickHouse in the `storage` config."
            ));
        }
        if !postgres_enabled && !clickhouse_enabled {
            return Err(anyhow!(
                "At least one storage backend must be enabled. Please set `postgres: true` \
                 in the `storage` config (or omit the `storage` section entirely to use the \
                 default)."
            ));
        }
        Ok(Self {
            postgres: postgres_enabled.then(|| StorageBackend {
                entity_default: postgres_config
                    .and_then(|c| c.entity_default())
                    .unwrap_or(!clickhouse_enabled),
                column_name_format: postgres_config
                    .and_then(|c| c.column_name_format())
                    .unwrap_or(human_config::ColumnNameFormat::Original),
            }),
            clickhouse: clickhouse_enabled.then(|| StorageBackend {
                entity_default: clickhouse_config
                    .and_then(|c| c.entity_default())
                    .unwrap_or(false),
                column_name_format: clickhouse_config
                    .and_then(|c| c.column_name_format())
                    .unwrap_or(human_config::ColumnNameFormat::Original),
            }),
        })
    }
}

/// Check per-entity `@storage` directives against the resolved global storage.
/// Malformed directives are raised earlier, during schema parsing.
pub fn validate_entity_storage(storage: &Storage, schema: &Schema) -> anyhow::Result<()> {
    let mut entities: Vec<&Entity> = schema.entities.values().collect();
    entities.sort_by(|a, b| a.name.cmp(&b.name));

    // Entities without @storage fall back to the backends marked `default`
    // in config.yaml. When no backend is a default, such entities would end
    // up with no storage at all.
    let postgres_default = storage.postgres.is_some_and(|b| b.entity_default);
    let clickhouse_default = storage.clickhouse.is_some_and(|b| b.entity_default);
    if !postgres_default && !clickhouse_default {
        let missing: Vec<&str> = entities
            .iter()
            .filter(|e| !e.has_storage_directive())
            .map(|e| e.name.as_str())
            .collect();
        if !missing.is_empty() {
            let example = missing[0];
            let listed = missing
                .iter()
                .map(|n| format!("  - {n}"))
                .collect::<Vec<_>>()
                .join("\n");
            return Err(anyhow!(
                "Schema validation failed:\n\
                 \n\
                 Entities with no storage backend (no @storage directive, and no backend is marked `default: true` in config.yaml):\n\
                 {listed}\n\
                 \n\
                 Fixes:\n  \
                 - Set `default: true` on a backend under `storage:` in config.yaml to include these entities automatically. Example:\n      \
                 storage:\n        \
                 postgres:\n          \
                 default: true\n  \
                 - Or add @storage(postgres: true) and/or @storage(clickhouse: true) to the entities listed above. Example:\n      \
                 type {example} @storage(postgres: true) {{ ... }}"
            ));
        }
    }

    let unsupported: Vec<(&str, &'static str)> = entities
        .iter()
        .flat_map(|e| {
            let mut out: Vec<(&str, &'static str)> = Vec::new();
            if e.postgres == Some(true) && storage.postgres.is_none() {
                out.push((e.name.as_str(), "postgres"));
            }
            if e.clickhouse.as_ref().is_some_and(|c| c.is_enabled()) && storage.clickhouse.is_none()
            {
                out.push((e.name.as_str(), "clickhouse"));
            }
            out
        })
        .collect();
    if unsupported.is_empty() {
        return Ok(());
    }
    let listed = unsupported
        .iter()
        .map(|(name, backend)| {
            format!("  - `{name}` uses `{backend}`, but `{backend}` is not enabled.")
        })
        .collect::<Vec<_>>()
        .join("\n");
    Err(anyhow!(
        "Schema validation failed:\n\
         \n\
         Entities using storages not enabled in config.yaml:\n\
         {listed}\n\
         \n\
         Fixes:\n  \
         - Remove the unsupported storage from @storage on these entities, or enable it under `storage:` in config.yaml."
    ))
}

// Postgres truncates longer identifiers silently, which can collide two
// distinct columns and breaks the Hasura custom_name mapping (it is keyed
// by the untruncated name).
const MAX_PG_IDENTIFIER_LENGTH: usize = 63;

/// Resolved column names can break table creation in ways schema.graphql
/// validation can't see: distinct fields may collide on the same column
/// (`tokenId` and an entity reference `token` both become `token_id`), shadow
/// the reserved `envio_*` columns added to entity history tables, or exceed
/// Postgres's identifier length limit. Catch all of these at codegen time
/// instead of failing on table creation.
pub fn validate_db_column_names(storage: &Storage, schema: &Schema) -> anyhow::Result<()> {
    let mut formats: Vec<human_config::ColumnNameFormat> = vec![];
    for backend in [storage.postgres, storage.clickhouse].iter().flatten() {
        if !formats.contains(&backend.column_name_format) {
            formats.push(backend.column_name_format);
        }
    }

    let mut entities: Vec<&Entity> = schema.entities.values().collect();
    entities.sort_by(|a, b| a.name.cmp(&b.name));

    // The identifier length limit is Postgres-specific (ClickHouse has no
    // comparable limit), so only names that become Postgres columns are
    // checked against it.
    let pg_format = storage.postgres.map(|b| b.column_name_format);

    let mut empty: Vec<String> = vec![];
    let mut reserved: Vec<String> = vec![];
    let mut too_long: Vec<String> = vec![];
    let mut collisions: Vec<String> = vec![];
    for format in &formats {
        for entity in &entities {
            let mut field_names_by_column: BTreeMap<String, Vec<String>> = BTreeMap::new();
            for gql_field in entity.get_fields() {
                if let Some(pg_field) = gql_field.get_postgres_field(schema, entity)? {
                    let column = pg_field.db_column_name(*format);
                    // Unreachable for any name the conversion produces today,
                    // but an empty identifier would silently break CREATE
                    // TABLE, so guard against future boundary changes.
                    if column.is_empty() {
                        let line = format!("  - `{}.{}`", entity.name, pg_field.field_name);
                        if !empty.contains(&line) {
                            empty.push(line);
                        }
                    }
                    if column.starts_with("envio_") {
                        let line = format!(
                            "  - `{}.{}` maps to the \"{column}\" column.",
                            entity.name, pg_field.field_name
                        );
                        // The same field can resolve identically under both
                        // configured formats; report it once.
                        if !reserved.contains(&line) {
                            reserved.push(line);
                        }
                    }
                    if Some(*format) == pg_format && column.len() > MAX_PG_IDENTIFIER_LENGTH {
                        let line = format!(
                            "  - `{}.{}` maps to the \"{column}\" column ({} characters).",
                            entity.name,
                            pg_field.field_name,
                            column.len()
                        );
                        if !too_long.contains(&line) {
                            too_long.push(line);
                        }
                    }
                    field_names_by_column
                        .entry(column)
                        .or_default()
                        .push(pg_field.field_name.clone());
                }
            }
            for (column, field_names) in field_names_by_column {
                if field_names.len() > 1 {
                    let fields = field_names
                        .iter()
                        .map(|f| format!("`{f}`"))
                        .collect::<Vec<_>>()
                        .join(", ");
                    let line = format!(
                        "  - `{}`: fields {fields} all map to the \"{column}\" column.",
                        entity.name
                    );
                    if !collisions.contains(&line) {
                        collisions.push(line);
                    }
                }
            }
        }
    }

    if !empty.is_empty() {
        return Err(anyhow!(
            "Schema validation failed:\n\
             \n\
             Entity fields that would create an empty database column name:\n\
             {}\n\
             \n\
             Fixes:\n  \
             - Rename the listed fields in schema.graphql.",
            empty.join("\n")
        ));
    }
    if !reserved.is_empty() {
        return Err(anyhow!(
            "Schema validation failed:\n\
             \n\
             Entity fields that would create database columns with the reserved `envio_` prefix:\n\
             {}\n\
             \n\
             Fixes:\n  \
             - Rename the listed fields in schema.graphql. Column names starting with `envio_` \
             are reserved for internal indexer columns (eg `envio_change` in entity history \
             tables).",
            reserved.join("\n")
        ));
    }
    if !too_long.is_empty() {
        return Err(anyhow!(
            "Schema validation failed:\n\
             \n\
             Entity fields that would create database column names longer than {MAX_PG_IDENTIFIER_LENGTH} \
             characters (Postgres truncates longer identifiers, which can cause collisions and \
             broken GraphQL field mappings):\n\
             {}\n\
             \n\
             Fixes:\n  \
             - Shorten the listed fields in schema.graphql so the resulting column names fit \
             within {MAX_PG_IDENTIFIER_LENGTH} characters.",
            too_long.join("\n")
        ));
    }
    if !collisions.is_empty() {
        return Err(anyhow!(
            "Schema validation failed:\n\
             \n\
             Multiple entity fields map to the same database column:\n\
             {}\n\
             \n\
             Fixes:\n  \
             - Rename the conflicting fields in schema.graphql so they map to distinct columns. \
             Note that entity reference fields get an `_id` suffix, and `column_name_format: \
             snake_case` converts field names to snake_case.",
            collisions.join("\n")
        ));
    }
    Ok(())
}

// ClickHouse has no `Nullable(Array(T))` type, so a nullable array column on a
// ClickHouse-backed entity is rejected when its history table is created.
// Catch it during validation with an actionable message instead.
pub fn validate_clickhouse_nullable_arrays(
    storage: &Storage,
    schema: &Schema,
) -> anyhow::Result<()> {
    let Some(clickhouse) = storage.clickhouse else {
        return Ok(());
    };

    let mut entities: Vec<&Entity> = schema.entities.values().collect();
    entities.sort_by(|a, b| a.name.cmp(&b.name));

    let mut offending: Vec<String> = vec![];
    for entity in &entities {
        // A storage directive's omitted backend resolves to false at runtime
        // (Config.res `Option.getOr(false)`), so a directive routes to
        // ClickHouse only when it enables the backend (boolean `true` or the
        // table options object form). Without a directive the entity follows
        // the backend's `default`.
        let uses_clickhouse = if entity.has_storage_directive() {
            entity.clickhouse.as_ref().is_some_and(|c| c.is_enabled())
        } else {
            clickhouse.entity_default
        };
        if !uses_clickhouse {
            continue;
        }
        for field in entity.get_fields() {
            if field.field_type.is_array() && field.field_type.is_optional() {
                offending.push(format!(
                    "  - `{}.{}` has type `{}`",
                    entity.name, field.name, field.field_type
                ));
            }
        }
    }

    if offending.is_empty() {
        return Ok(());
    }

    Err(anyhow!(
        "Schema validation failed:\n\
         \n\
         Nullable array fields are not supported by ClickHouse storage:\n\
         {}\n\
         \n\
         Fixes:\n  \
         - Make the field required and explicitly set an empty array instead of null. For \
         example, change the type from `[String!]` to `[String!]!` in schema.graphql, and \
         assign `[]` instead of `null`/`undefined` in your handlers.",
        offending.join("\n")
    ))
}

//Getter methods for system config
impl SystemConfig {
    pub fn get_contracts(&self) -> Vec<&Contract> {
        let mut contracts: Vec<&Contract> = self.contracts.values().collect();
        contracts.sort_by_key(|c| c.name.clone());
        contracts
    }

    pub fn get_ecosystem(&self) -> Ecosystem {
        match &self.human_config {
            HumanConfig::Evm(_) => Ecosystem::Evm,
            HumanConfig::Fuel(_) => Ecosystem::Fuel,
            HumanConfig::Svm(_) => Ecosystem::Svm,
        }
    }

    pub fn get_contract(&self, name: &ContractNameKey) -> Option<&Contract> {
        self.contracts.get(name)
    }

    pub fn get_entity_names(&self) -> Vec<EntityKey> {
        let mut entity_names: Vec<EntityKey> = self
            .schema
            .entities
            .values()
            .map(|v| v.name.clone())
            .collect();
        //For consistent templating in alphabetical order
        entity_names.sort();
        entity_names
    }

    pub fn get_entity(&self, entity_name: &EntityKey) -> Option<&Entity> {
        self.schema.entities.get(entity_name)
    }

    pub fn get_entities(&self) -> Vec<&Entity> {
        let mut entities: Vec<&Entity> = self.schema.entities.values().collect();
        //For consistent templating in alphabetical order
        entities.sort_by_key(|e| e.name.clone());
        entities
    }

    pub fn get_entity_map(&self) -> &EntityMap {
        &self.schema.entities
    }

    pub fn get_gql_enum(&self, enum_name: &GraphqlEnumKey) -> Option<&GraphQLEnum> {
        self.schema.enums.get(enum_name)
    }

    pub fn get_gql_enum_map(&self) -> &GraphQlEnumMap {
        &self.schema.enums
    }

    pub fn get_gql_enums(&self) -> Vec<&GraphQLEnum> {
        let mut enums: Vec<&GraphQLEnum> = self.schema.enums.values().collect();
        //For consistent templating in alphabetical order
        enums.sort_by_key(|e| e.name.clone());
        enums
    }

    pub fn get_gql_enum_names_set(&self) -> HashSet<EntityKey> {
        self.schema.enums.keys().cloned().collect()
    }

    pub fn get_chains(&self) -> Vec<&Chain> {
        let mut chains: Vec<&Chain> = self.chains.values().collect();
        chains.sort_by_key(|n| n.id);
        chains
    }

    pub fn get_path_to_schema(&self) -> Result<PathBuf> {
        let schema_path = path_utils::get_config_path_relative_to_root(
            &self.parsed_project_paths,
            PathBuf::from(&self.schema_path),
        )
        .context("Failed creating a relative path to schema")?;

        Ok(schema_path)
    }

    pub fn get_all_paths_to_abi_files(&self) -> Result<Vec<PathBuf>> {
        let mut filtered_unique_abi_files = self
            .get_contracts()
            .into_iter()
            .filter_map(|c| c.abi.get_path())
            .collect::<HashSet<_>>()
            .into_iter()
            .collect::<Vec<_>>();

        filtered_unique_abi_files.sort();
        Ok(filtered_unique_abi_files)
    }

    pub fn from_human_config(
        human_config: HumanConfig,
        schema: Schema,
        project_paths: &ParsedProjectPaths,
    ) -> Result<Self> {
        let source = FilesystemConfigSource::new(project_paths);
        Self::from_human_config_with_source(human_config, schema, &source)
    }

    fn from_human_config_with_source(
        human_config: HumanConfig,
        schema: Schema,
        source: &dyn ConfigSource,
    ) -> Result<Self> {
        let mut chains: ChainMap = HashMap::new();
        let mut contracts: ContractMap = HashMap::new();

        let base_config = human_config.get_base_config();
        let storage = Storage::resolve(base_config.storage.as_ref())?;
        validate_entity_storage(&storage, &schema)?;
        validate_db_column_names(&storage, &schema)?;
        validate_clickhouse_nullable_arrays(&storage, &schema)?;

        let final_project_paths = source.project_paths().clone();
        let is_rescript = source.is_rescript();

        match human_config {
            HumanConfig::Evm(ref evm_config) => {
                // TODO: Add similar validation for Fuel
                validation::validate_deserialized_config_yaml(evm_config)?;

                let has_rpc_sync_src = evm_config.chains.iter().any(evm_chain_has_rpc_sync_src);

                //Add all global contracts
                if let Some(global_contracts) = &evm_config.contracts {
                    for g_contract in global_contracts {
                        let contract_has_rpc_sync_src = evm_config.chains.iter().any(|chain| {
                            evm_chain_has_rpc_sync_src(chain)
                                && chain.contracts.as_ref().is_some_and(|contracts| {
                                    contracts
                                        .iter()
                                        .any(|contract| contract.name == g_contract.name)
                                })
                        });
                        let (events, evm_abi) = Event::from_evm_events_config(
                            g_contract.config.events.clone(),
                            &g_contract.config.abi_file_path,
                            source,
                            contract_has_rpc_sync_src,
                        )
                        .context(format!(
                            "Failed parsing abi types for events in global contract {}",
                            g_contract.name,
                        ))?;

                        let contract = Contract::new(
                            g_contract.name.clone(),
                            g_contract.config.handler.clone(),
                            events,
                            Abi::Evm(evm_abi),
                        )
                        .context("Failed parsing globally defined contract")?;

                        //Check if contract exists
                        unique_hashmap::try_insert(&mut contracts, contract.name.clone(), contract)
                            .context("Failed inserting globally defined contract")?;
                    }
                }

                for network in &evm_config.chains {
                    let network_has_rpc_sync_src = evm_chain_has_rpc_sync_src(network);
                    for contract in network.contracts.clone().unwrap_or_default() {
                        //Add values for local contract
                        match contract.config {
                            Some(l_contract) => {
                                let (events, evm_abi) = Event::from_evm_events_config(
                                    l_contract.events,
                                    &l_contract.abi_file_path,
                                    source,
                                    network_has_rpc_sync_src,
                                )
                                .context(format!(
                                    "Failed parsing abi types for events in contract {} on \
                                     network {}",
                                    contract.name, network.id,
                                ))?;

                                let contract = Contract::new(
                                    contract.name,
                                    l_contract.handler,
                                    events,
                                    Abi::Evm(evm_abi),
                                )
                                .context(format!(
                                    "Failed parsing locally defined network contract at network \
                                     id {}",
                                    network.id
                                ))?;

                                //Check if contract exists
                                unique_hashmap::try_insert(
                                    &mut contracts,
                                    contract.name.clone(),
                                    contract,
                                )
                                .context(format!(
                                    "Failed inserting locally defined network contract at network \
                                     id {}",
                                    network.id,
                                ))?;
                            }
                            None => {
                                //Validate that there is a global contract for the given contract if
                                //there is no config
                                if !contracts.contains_key(&contract.name) {
                                    Err(anyhow!(
                                        "Failed to parse contract '{}' for the network '{}'. If \
                                         you use a global contract definition, please verify that \
                                         the name reference is correct.",
                                        contract.name,
                                        network.id
                                    ))?;
                                }
                            }
                        }
                    }

                    let sync_source = DataSource::from_evm_network_config(network.clone())?;

                    let contracts: Vec<ChainContract> = network
                        .contracts
                        .as_ref()
                        .unwrap_or(&vec![])
                        .iter()
                        .cloned()
                        .map(|c| ChainContract {
                            name: c.name,
                            addresses: c.address.into(),
                            start_block: c.start_block,
                        })
                        .collect();

                    let chain = Chain {
                        id: network.id,
                        skip: network.skip.unwrap_or(false),
                        max_reorg_depth: network
                            .max_reorg_depth
                            .or_else(|| get_max_reorg_depth_from_id(network.id)),
                        block_lag: network.block_lag,
                        start_block: network.start_block,
                        end_block: network.end_block,
                        sync_source,
                        contracts,
                    };

                    unique_hashmap::try_insert(&mut chains, chain.id, chain)
                        .context("Failed inserting chain at chains map")?;
                }

                let field_selection = FieldSelection::try_from_config_field_selection(
                    evm_config.field_selection.clone().unwrap_or(
                        human_config::evm::FieldSelection {
                            transaction_fields: None,
                            block_fields: None,
                        },
                    ),
                    has_rpc_sync_src,
                )?;

                Ok(SystemConfig {
                    name: base_config.name.clone(),
                    parsed_project_paths: final_project_paths,
                    schema_path: base_config
                        .schema
                        .clone()
                        .unwrap_or_else(|| DEFAULT_SCHEMA_PATH.to_string()),
                    chains,
                    contracts,
                    rollback_on_reorg: evm_config.rollback_on_reorg.unwrap_or(true),
                    save_full_history: evm_config.save_full_history.unwrap_or(false),
                    schema,
                    field_selection,
                    enable_raw_events: evm_config.raw_events.unwrap_or(false),
                    storage,
                    lowercase_addresses: matches!(
                        evm_config.address_format,
                        Some(super::human_config::evm::AddressFormat::Lowercase)
                    ),
                    handlers: base_config.handlers.clone(),
                    human_config,
                    is_rescript,
                })
            }
            HumanConfig::Fuel(ref fuel_config) => {
                //Add all global contracts
                if let Some(global_contracts) = &fuel_config.contracts {
                    for g_contract in global_contracts {
                        let (events, fuel_abi) = Event::from_fuel_events_config(
                            &g_contract.config.events,
                            &g_contract.config.abi_file_path,
                            source,
                        )
                        .context(format!(
                            "Failed parsing abi types for events in global contract {}",
                            g_contract.name,
                        ))?;

                        let contract = Contract::new(
                            g_contract.name.clone(),
                            g_contract.config.handler.clone(),
                            events,
                            Abi::fuel(fuel_abi),
                        )?;

                        //Check if contract exists
                        unique_hashmap::try_insert(&mut contracts, contract.name.clone(), contract)
                            .context("Failed inserting globally defined contract")?;
                    }
                }

                for network in &fuel_config.chains {
                    for contract in network.contracts.clone().unwrap_or_default() {
                        //Add values for local contract
                        match contract.config {
                            Some(l_contract) => {
                                let (events, fuel_abi) = Event::from_fuel_events_config(
                                    &l_contract.events,
                                    &l_contract.abi_file_path,
                                    source,
                                )
                                .context(format!(
                                    "Failed parsing abi types for events in contract {} on \
                                     network {}",
                                    contract.name, network.id,
                                ))?;

                                let contract = Contract::new(
                                    contract.name.clone(),
                                    l_contract.handler,
                                    events,
                                    Abi::fuel(fuel_abi),
                                )?;

                                //Check if contract exists
                                unique_hashmap::try_insert(
                                    &mut contracts,
                                    contract.name.clone(),
                                    contract,
                                )
                                .context(format!(
                                    "Failed inserting locally defined network contract at network \
                                     id {}",
                                    network.id,
                                ))?;
                            }
                            None => {
                                //Validate that there is a global contract for the given contract if
                                //there is no local_contract_config
                                if !contracts.contains_key(&contract.name) {
                                    Err(anyhow!(
                                        "Failed to parse contract '{}' for the network '{}'. If \
                                         you use a global contract definition, please verify that \
                                         the name reference is correct.",
                                        contract.name,
                                        network.id
                                    ))?;
                                }
                            }
                        }
                    }

                    let sync_source = DataSource::Fuel {
                        hypersync_endpoint_url: match &network.hyperfuel_config {
                            Some(config) => config.url.clone(),
                            None => match network.id {
                                0 => "https://fuel-testnet.hypersync.xyz".to_string(),
                                9889 => "https://fuel.hypersync.xyz".to_string(),
                                _ => {
                                    return Err(anyhow!(
                                        "Fuel network id {} is not supported",
                                        network.id
                                    ))
                                }
                            },
                        },
                    };

                    let contracts: Vec<ChainContract> = network
                        .contracts
                        .as_ref()
                        .unwrap_or(&vec![])
                        .iter()
                        .cloned()
                        .map(|c| ChainContract {
                            name: c.name,
                            addresses: c.address.into(),
                            start_block: c.start_block,
                        })
                        .collect();

                    let chain = Chain {
                        id: network.id,
                        skip: network.skip.unwrap_or(false),
                        start_block: network.start_block,
                        end_block: network.end_block,
                        max_reorg_depth: network.max_reorg_depth,
                        block_lag: network.block_lag,
                        sync_source,
                        contracts,
                    };

                    unique_hashmap::try_insert(&mut chains, chain.id, chain)
                        .context("Failed inserting chain at chains map")?;
                }

                Ok(SystemConfig {
                    name: base_config.name.clone(),
                    parsed_project_paths: final_project_paths,
                    schema_path: base_config
                        .schema
                        .clone()
                        .unwrap_or_else(|| DEFAULT_SCHEMA_PATH.to_string()),
                    chains,
                    contracts,
                    rollback_on_reorg: false,
                    save_full_history: false,
                    schema,
                    field_selection: FieldSelection::fuel(),
                    enable_raw_events: fuel_config.raw_events.unwrap_or(false),
                    storage,
                    lowercase_addresses: false,
                    handlers: base_config.handlers.clone(),
                    human_config,
                    is_rescript,
                })
            }
            HumanConfig::Svm(ref svm_config) => {
                validation::validate_deserialized_svm_config_yaml(svm_config)?;
                for network in &svm_config.chains {
                    let sync_source = DataSource::Svm {
                        rpc: network.rpc.clone(),
                        hypersync_endpoint_url: network
                            .experimental
                            .as_ref()
                            .map(|e| e.hypersync_config.url.clone()),
                    };

                    let programs = network
                        .experimental
                        .as_ref()
                        .map(|e| e.programs.as_slice())
                        .unwrap_or(&[]);
                    let mut chain_contracts = Vec::new();
                    for program in programs {
                        let svm_abi =
                            resolve_program_schema(program, source).with_context(|| {
                                format!(
                                    "Resolving Borsh schema for program '{}' ({})",
                                    program.name, program.program_id
                                )
                            })?;
                        let events = program
                            .instructions
                            .iter()
                            .map(|instr| -> Result<Event> {
                                let (normalized_discriminator, byte_len) =
                                    match &instr.discriminator {
                                        Some(d) => {
                                            let hex = d.strip_prefix("0x").unwrap_or(d);
                                            let byte_len = (hex.len() / 2) as u8;
                                            (Some(format!("0x{hex}")), byte_len)
                                        }
                                        None => (None, 0u8),
                                    };
                                let (accounts, args) = resolve_instruction_layout(instr, &svm_abi)
                                    .with_context(|| {
                                        format!("Layout for instruction '{}'", instr.name)
                                    })?;
                                let fs = instr.field_selection.as_ref();
                                let selected_transaction_fields =
                                    resolve_svm_transaction_fields(fs);
                                let selected_block_fields = resolve_svm_block_fields(fs);
                                let include_logs = fs.and_then(|f| f.log_fields).unwrap_or(false);
                                let svm_kind = SvmEventKind {
                                    discriminator: normalized_discriminator.clone(),
                                    discriminator_byte_len: byte_len,
                                    selected_transaction_fields,
                                    selected_block_fields,
                                    include_logs,
                                    account_filters: instr
                                        .account_filters
                                        .as_ref()
                                        .map(|filters| {
                                            filters
                                                .groups()
                                                .into_iter()
                                                .map(|group| {
                                                    group
                                                        .iter()
                                                        .map(|af| SvmAccountFilter {
                                                            position: af.position,
                                                            values: af.values.clone(),
                                                        })
                                                        .collect()
                                                })
                                                .collect()
                                        })
                                        .unwrap_or_default(),
                                    is_inner: instr.is_inner,
                                    accounts,
                                    args,
                                };
                                Ok(Event {
                                    name: instr.name.clone(),
                                    kind: EventKind::Svm(svm_kind),
                                    sighash: normalized_discriminator.clone().unwrap_or_default(),
                                    event_signature: String::new(),
                                    field_selection: None,
                                })
                            })
                            .collect::<Result<Vec<_>>>()?;

                        let contract = Contract::new(
                            program.name.clone(),
                            program.handler.clone(),
                            events,
                            Abi::Svm(svm_abi),
                        )?;
                        contracts.insert(contract.name.clone(), contract.clone());
                        chain_contracts.push(ChainContract {
                            name: program.name.clone(),
                            addresses: vec![program.program_id.clone()],
                            start_block: None,
                        });
                    }

                    let chain = Chain {
                        id: 0, //network.id,
                        skip: network.skip.unwrap_or(false),
                        start_block: network.start_block,
                        end_block: network.end_block,
                        max_reorg_depth: None,
                        block_lag: network.block_lag,
                        sync_source,
                        contracts: chain_contracts,
                    };

                    unique_hashmap::try_insert(&mut chains, chain.id, chain)
                        .context("Failed inserting chain at chains map")?;
                }

                // Reorg rollback is only meaningful for the experimental
                // HyperSync source (it surfaces block hashes); RPC-only chains
                // keep it off for now.
                let uses_hypersync = svm_config.chains.iter().any(|n| n.experimental.is_some());

                Ok(SystemConfig {
                    name: svm_config.base.name.clone(),
                    parsed_project_paths: final_project_paths,
                    schema_path: svm_config
                        .base
                        .schema
                        .clone()
                        .unwrap_or_else(|| DEFAULT_SCHEMA_PATH.to_string()),
                    chains,
                    contracts,
                    rollback_on_reorg: uses_hypersync,
                    save_full_history: false,
                    schema,
                    field_selection: FieldSelection::svm(),
                    enable_raw_events: false,
                    storage,
                    lowercase_addresses: false,
                    handlers: None,
                    human_config,
                    is_rescript,
                })
            }
        }
    }

    pub fn parse_from_project_files(project_paths: &ParsedProjectPaths) -> Result<Self> {
        let human_config_string =
            std::fs::read_to_string(&project_paths.config).context(format!(
                "Failed to resolve config path {0} (--config {1} resolved relative to \
                 --directory {2}). Make sure the file exists. Note that --config and \
                 ENVIO_CONFIG are interpreted relative to --directory.",
                project_paths.config.to_str().unwrap_or("{unknown}"),
                project_paths.config_relative_to_root().display(),
                project_paths.project_root.display(),
            ))?;

        let mut source = FilesystemConfigSource::new(project_paths);
        Self::parse_yaml_with_source(human_config_string, &mut source)
    }

    /// Parse config YAML without reading project state. The supplied environment
    /// is authoritative, an absent/blank schema means `Schema::empty()`, and
    /// ABI/IDL paths resolve against the in-memory `files` map.
    pub(crate) fn parse_yaml(
        yaml: &str,
        schema: Option<&str>,
        env: &HashMap<String, String>,
        files: &HashMap<String, String>,
        is_rescript: bool,
    ) -> Result<Self> {
        let mut source = MemoryConfigSource::new(schema, env, files, is_rescript);
        Self::parse_yaml_with_source(yaml.to_string(), &mut source)
    }

    fn parse_yaml_with_source(
        human_config_string: String,
        source: &mut dyn ConfigSource,
    ) -> Result<Self> {
        let human_config_string =
            interpolate_config_variables(human_config_string, |name| source.env_var(name))?;

        let config_discriminant: human_config::ConfigDiscriminant =
            serde_yaml::from_str(&human_config_string).context(
                "Failed to deserialize config. The config.yaml file is either not a valid \
                 yaml or the \"ecosystem\" field is not a string.",
            )?;

        let ecosystem = match config_discriminant.ecosystem.as_deref() {
            Some("evm") => Ecosystem::Evm,
            Some("fuel") => Ecosystem::Fuel,
            Some("svm") => Ecosystem::Svm,
            Some(ecosystem) => {
                return Err(anyhow!(
                    "Failed to deserialize config. The ecosystem \"{}\" is not supported.",
                    ecosystem
                ))
            }
            None => Ecosystem::Evm,
        };

        let human_config = match ecosystem {
            Ecosystem::Evm => {
                let evm_config: EvmConfig =
                    serde_yaml::from_str(&human_config_string).context(format!(
                        "Failed to deserialize config. Visit the docs for more information \
                         {}",
                        links::DOC_CONFIGURATION_FILE
                    ))?;
                HumanConfig::Evm(evm_config)
            }
            Ecosystem::Fuel => {
                let fuel_config: FuelConfig =
                    serde_yaml::from_str(&human_config_string).context(format!(
                        "Failed to deserialize config. Visit the docs for more information \
                         {}",
                        links::DOC_CONFIGURATION_FILE
                    ))?;
                HumanConfig::Fuel(fuel_config)
            }
            Ecosystem::Svm => {
                let svm_config: human_config::svm::HumanConfig =
                    serde_yaml::from_str(&human_config_string).context(format!(
                        "Failed to deserialize config. Visit the docs for more information \
                         {}",
                        links::DOC_CONFIGURATION_FILE
                    ))?;
                HumanConfig::Svm(svm_config)
            }
        };

        let schema = source.load_schema(&human_config.get_base_config().schema)?;
        Self::from_human_config_with_source(human_config, schema, source)
    }
}

type ServerUrl = String;

/// This data structure mainly needed to conviniently prepare data
/// for ConfigYAML, so we don't break backward compatibility
#[derive(Debug, Clone, PartialEq)]
pub enum MainEvmDataSource {
    HyperSync { hypersync_endpoint_url: ServerUrl },
    Rpc(Rpc),
}

#[derive(Debug, Clone, PartialEq)]
pub enum DataSource {
    Evm {
        main: MainEvmDataSource,
        rpcs: Vec<Rpc>,
    },
    Fuel {
        hypersync_endpoint_url: ServerUrl,
    },
    Svm {
        rpc: Option<ServerUrl>,
        hypersync_endpoint_url: Option<ServerUrl>,
    },
}

// Check if the given URL is valid in terms of formatting
fn parse_url(url: &str) -> Option<String> {
    // Check URL format
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return None;
    }
    // Trim any trailing slashes from the URL
    let trimmed_url = url.trim_end_matches('/').to_string();
    Some(trimmed_url)
}

/// Returns the default `For` value for an RPC on a chain:
/// `Fallback` if HyperSync is available, `Sync` otherwise.
fn default_rpc_for(chain: &EvmChain) -> For {
    let has_hypersync = chain.hypersync_config.is_some()
        || hypersync_endpoints::get_default_hypersync_endpoint(chain.id).is_ok();
    if has_hypersync {
        For::Fallback
    } else {
        For::Sync
    }
}

fn evm_chain_has_rpc_sync_src(chain: &EvmChain) -> bool {
    let default_for = default_rpc_for(chain);
    let is_sync =
        |source_for: &Option<For>| matches!(source_for.as_ref().unwrap_or(&default_for), For::Sync);

    match &chain.rpc {
        Some(RpcSelection::Single(rpc)) => is_sync(&rpc.source_for),
        Some(RpcSelection::List(rpcs)) => rpcs.iter().any(|rpc| is_sync(&rpc.source_for)),
        Some(RpcSelection::Url(_)) => default_for == For::Sync,
        None => false,
    }
}

impl DataSource {
    fn from_evm_network_config(network: EvmChain) -> Result<Self> {
        let default_for = default_rpc_for(&network);
        let hypersync_endpoint_url = match &network.hypersync_config {
            Some(config) => Some(config.url.to_string()),
            None => hypersync_endpoints::get_default_hypersync_endpoint(network.id).ok(),
        };
        let resolve_for = |rpc: Rpc| Rpc {
            source_for: Some(rpc.source_for.unwrap_or(default_for.clone())),
            ..rpc
        };
        let raw_rpcs = match network.rpc {
            Some(RpcSelection::Url(url)) => vec![Rpc {
                url: url.to_string(),
                source_for: Some(default_for.clone()),
                ws: None,
                headers: None,
                initial_block_interval: None,
                backoff_multiplicative: None,
                acceleration_additive: None,
                interval_ceiling: None,
                backoff_millis: None,
                fallback_stall_timeout: None,
                query_timeout_millis: None,
                polling_interval: None,
            }],
            Some(RpcSelection::Single(rpc)) => vec![resolve_for(rpc)],
            Some(RpcSelection::List(list)) => list.into_iter().map(resolve_for).collect(),
            None => vec![],
        };

        let mut rpcs = vec![];
        for rpc in raw_rpcs.iter() {
            match parse_url(rpc.url.as_str()) {
              None => return Err(anyhow!("The RPC url \"{}\" is incorrect format. The RPC url needs to start with either http:// or https://", rpc.url)),
              Some(url) => {
                // Validate ws URL protocol if provided
                let ws = match &rpc.ws {
                    Some(ws_url) => {
                        if ws_url.starts_with("wss://") || ws_url.starts_with("ws://") {
                            Some(ws_url.trim_end_matches('/').to_string())
                        } else {
                            return Err(anyhow!(
                                "The WebSocket URL \"{}\" is in incorrect format. \
                                 Expected wss:// or ws:// protocol.",
                                ws_url
                            ));
                        }
                    }
                    None => None,
                };
                rpcs.push(Rpc {
                    url,
                    ws,
                    ..rpc.clone()
                })
              }
            }
        }

        let rpc_for_sync = rpcs.iter().find(|rpc| rpc.source_for == Some(For::Sync));

        let main = match rpc_for_sync {
            Some(rpc) => {
                if network.hypersync_config.is_some() {
                    Err(anyhow!(
                        "Cannot define both hypersync_config and rpc as a data-source for \
                         historical sync at the same time, please choose only one option or set \
                         RPC to be a fallback. Read more in our docs {}",
                        links::DOC_CONFIGURATION_FILE
                    ))?
                };

                MainEvmDataSource::Rpc(rpc.clone())
            }
            None => {
                let url = hypersync_endpoint_url.ok_or(anyhow!(
                    "Failed to automatically find HyperSync endpoint for the chain {chain_id}. \
                     If the chain is supported by HyperSync, provide the endpoint manually:\n\n\
                     chains:\n  - id: {chain_id}\n    hypersync_config:\n      \
                     url: https://{chain_id}.hypersync.xyz\n\n\
                     Or use an RPC endpoint for historical sync:\n\n\
                     chains:\n  - id: {chain_id}\n    rpc:\n      \
                     url: https://your-rpc-endpoint\n      for: sync\n\n\
                     Read more: {docs_url}",
                    chain_id = network.id,
                    docs_url = links::DOC_CONFIGURATION_SCHEMA_HYPERSYNC_CONFIG
                ))?;

                let parsed_url = parse_url(&url).ok_or(anyhow!(
                  "The HyperSync URL \"{}\" is in incorrect format. The URL needs to start with either http:// or https://",
                  url
                ))?;

                MainEvmDataSource::HyperSync {
                    hypersync_endpoint_url: parsed_url,
                }
            }
        };

        Ok(Self::Evm { main, rpcs })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Chain {
    pub id: u64,
    pub skip: bool,
    pub sync_source: DataSource,
    pub start_block: u64,
    pub end_block: Option<u64>,
    pub max_reorg_depth: Option<u32>,
    pub block_lag: Option<u32>,
    pub contracts: Vec<ChainContract>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ChainContract {
    pub name: ContractNameKey,
    pub addresses: Vec<String>,
    pub start_block: Option<u64>,
}

impl ChainContract {
    pub fn get_contract<'a>(&self, config: &'a SystemConfig) -> Result<&'a Contract> {
        config.get_contract(&self.name).ok_or_else(|| {
            anyhow!(
                "Unexpected, network contract {} should have a contract in mapping",
                self.name
            )
        })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct EvmAbi {
    // The path is not always present since we allow to get ABI from events
    pub path: Option<PathBuf>,
    pub raw: String,
    typed: JsonAbi,
}

impl EvmAbi {
    pub fn event_signature_from_abi_event(abi_event: &AlloyEvent) -> String {
        format!(
            "{}({}){}",
            abi_event.name,
            abi_event
                .inputs
                .iter()
                .map(|input| {
                    let param_type = input.selector_type();
                    let indexed_keyword = if input.indexed { " indexed " } else { " " };
                    let param_name = &input.name;

                    format!("{}{}{}", param_type, indexed_keyword, param_name)
                })
                .collect::<Vec<_>>()
                .join(", "),
            if abi_event.anonymous {
                " anonymous"
            } else {
                ""
            },
        )
    }

    pub fn get_event_signatures(&self) -> Vec<String> {
        self.typed
            .events()
            .map(Self::event_signature_from_abi_event)
            .collect()
    }

    fn from_source(
        abi_file_path: &Option<String>,
        source: &dyn ConfigSource,
    ) -> Result<Option<Self>> {
        match &abi_file_path {
            None => Ok(None),
            Some(abi_file_path) => {
                let resolved = source
                    .read_config_relative_file(abi_file_path)
                    .context("Failed to get ABI relative to the config")?;
                let path = resolved.path;
                let mut raw = resolved.raw;

                // Abi files generated by the hardhat plugin can contain a nested abi field. This code to support that.
                let typed = match serde_json::from_str::<AbiOrNestedAbi>(&raw).context(format!(
                    "Failed to decode ABI file at \"{}\"",
                    abi_file_path
                ))? {
                    AbiOrNestedAbi::Abi(abi) => abi,
                    AbiOrNestedAbi::NestedAbi { abi } => {
                        raw = serde_json::to_string(&abi)
                            .context("Failed serializing ABI from nested field")?;
                        abi
                    }
                };
                Ok(Some(Self {
                    path: Some(path),
                    raw,
                    typed,
                }))
            }
        }
    }
}

/// Base58 program id for the bundled Metaplex Token Metadata schema. Kept
/// here (rather than imported from the upstream crate) so a future bundled
/// schema can be added by appending a row to the `bundled_program_schemas`
/// table without leaking strings across the module boundary.
const METAPLEX_TOKEN_METADATA_PROGRAM_ID: &str = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s";

/// One row in the bundled-programs table: `(program_id, source_name,
/// accessor returning the upstream `ProgramSchema`)`.
type BundledProgramRow = (
    &'static str,
    &'static str,
    fn() -> &'static SvmProgramSchema,
);

/// Table of bundled programs. Lookup by base58 `program_id`. To add a
/// program: ship a `ProgramSchema` constant in `hypersync_client_solana`,
/// expose a public accessor, then add a row here.
fn bundled_program_schemas() -> Vec<BundledProgramRow> {
    vec![(
        METAPLEX_TOKEN_METADATA_PROGRAM_ID,
        "metaplex_token_metadata",
        metaplex_token_metadata,
    )]
}

fn resolve_program_schema(
    program: &human_config::svm::Program,
    source: &dyn ConfigSource,
) -> Result<SvmAbi> {
    let any_instruction_carries_schema = program
        .instructions
        .iter()
        .any(|i| i.accounts.is_some() || i.args.is_some());

    if let Some(idl_path) = program.idl.as_deref() {
        if any_instruction_carries_schema {
            return Err(anyhow!(
                "Program '{}': `idl` is mutually exclusive with per-instruction \
                 `accounts`/`args` overrides. Use one or the other.",
                program.name
            ));
        }
        let resolved = source
            .read_project_relative_file(idl_path)
            .with_context(|| format!("reading IDL at '{idl_path}'"))?;
        let schema = schema_from_anchor_idl_json(&resolved.raw)
            .with_context(|| format!("parsing IDL at '{}'", resolved.path.display()))?;
        return Ok(SvmAbi {
            program_id: program.program_id.clone(),
            instructions: schema.instructions,
            defined_types: schema.defined_types,
            source: SvmSchemaSource::AnchorIdl {
                path: idl_path.to_string(),
            },
        });
    }

    if !any_instruction_carries_schema {
        if let Some((_, name, getter)) = bundled_program_schemas()
            .into_iter()
            .find(|(pid, _, _)| *pid == program.program_id.as_str())
        {
            let schema = getter();
            return Ok(SvmAbi {
                program_id: program.program_id.clone(),
                instructions: schema.instructions.clone(),
                defined_types: schema.defined_types.clone(),
                source: SvmSchemaSource::Bundled { name },
            });
        }
    }

    Ok(SvmAbi {
        program_id: program.program_id.clone(),
        instructions: BTreeMap::new(),
        defined_types: BTreeMap::new(),
        source: SvmSchemaSource::Inline,
    })
}

/// Resolve per-instruction `(accounts, args)` from one of:
/// 1. YAML per-instruction `accounts`/`args` overrides (highest priority).
/// 2. The matching `InstructionSchema` on the program's resolved schema
///    (bundled OR Anchor IDL), keyed by the YAML `discriminator` bytes.
/// 3. An empty pair (`accounts: []`, `args: []`) so existing untyped
///    handlers keep working.
fn resolve_instruction_layout(
    instr: &human_config::svm::Instruction,
    abi: &SvmAbi,
) -> Result<(Vec<String>, Vec<SvmNamedField>)> {
    if let (Some(accounts_yaml), Some(args_yaml)) = (&instr.accounts, &instr.args) {
        let args = args_yaml
            .iter()
            .map(yaml_arg_to_named_field)
            .collect::<Result<Vec<_>>>()?;
        return Ok((accounts_yaml.clone(), args));
    }
    if instr.accounts.is_some() != instr.args.is_some() {
        return Err(anyhow!(
            "Instruction '{}': `accounts` and `args` must be provided together \
             (or both omitted to fall back to a bundled/IDL schema).",
            instr.name
        ));
    }

    if let Some(disc_bytes) = disc_to_bytes(instr.discriminator.as_deref())? {
        if let Some(ix_schema) = abi.instructions.get(&disc_bytes) {
            let accounts = ix_schema.accounts.iter().map(|a| a.name.clone()).collect();
            let args = ix_schema.args.clone();
            return Ok((accounts, args));
        }
    }

    Ok((Vec::new(), Vec::new()))
}

fn disc_to_bytes(disc: Option<&str>) -> Result<Option<Vec<u8>>> {
    let Some(s) = disc else { return Ok(None) };
    let hex = s.strip_prefix("0x").unwrap_or(s);
    let bytes = (0..hex.len())
        .step_by(2)
        .map(|i| {
            u8::from_str_radix(&hex[i..i + 2], 16)
                .with_context(|| format!("invalid hex byte at offset {i} in discriminator '{s}'"))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(Some(bytes))
}

fn yaml_arg_to_named_field(arg: &human_config::svm::ArgDef) -> Result<SvmNamedField> {
    Ok(SvmNamedField {
        name: arg.name.clone(),
        ty: yaml_type_to_field_type(&arg.ty)
            .with_context(|| format!("translating type for arg '{}'", arg.name))?,
    })
}

/// Convert an upstream `FieldType` into the YAML/wire-format `ArgType`. Used
/// when serializing `SvmEventKind.args` / `SvmAbi.defined_types` into
/// `internal_config.json` for the runtime to consume.
pub fn field_type_to_arg_type(ty: &SvmFieldType) -> human_config::svm::ArgType {
    use human_config::svm::{ArgComposite as C, ArgPrimitive as P, ArgType as T};
    match ty {
        SvmFieldType::Bool => T::Primitive(P::Bool),
        SvmFieldType::U8 => T::Primitive(P::U8),
        SvmFieldType::U16 => T::Primitive(P::U16),
        SvmFieldType::U32 => T::Primitive(P::U32),
        SvmFieldType::U64 => T::Primitive(P::U64),
        SvmFieldType::U128 => T::Primitive(P::U128),
        SvmFieldType::I8 => T::Primitive(P::I8),
        SvmFieldType::I16 => T::Primitive(P::I16),
        SvmFieldType::I32 => T::Primitive(P::I32),
        SvmFieldType::I64 => T::Primitive(P::I64),
        SvmFieldType::I128 => T::Primitive(P::I128),
        SvmFieldType::F32 => T::Primitive(P::F32),
        SvmFieldType::F64 => T::Primitive(P::F64),
        SvmFieldType::String => T::Primitive(P::String),
        SvmFieldType::Bytes => T::Primitive(P::Bytes),
        SvmFieldType::Pubkey => T::Primitive(P::Pubkey),
        SvmFieldType::Option(inner) => {
            T::Composite(C::Option(Box::new(field_type_to_arg_type(inner))))
        }
        SvmFieldType::Vec(inner) => T::Composite(C::Vec(Box::new(field_type_to_arg_type(inner)))),
        SvmFieldType::Array { ty, len } => {
            T::Composite(C::Array(Box::new(field_type_to_arg_type(ty)), *len))
        }
        SvmFieldType::Defined(name) => T::Composite(C::Defined(name.clone())),
        SvmFieldType::Struct(fields) => T::Composite(C::Struct(
            fields.iter().map(named_field_to_arg_def).collect(),
        )),
        SvmFieldType::Enum(variants) => T::Composite(C::Enum(
            variants
                .iter()
                .map(|v| human_config::svm::ArgEnumVariant {
                    name: v.name.clone(),
                    fields: v
                        .fields
                        .as_ref()
                        .map(|fs| fs.iter().map(named_field_to_arg_def).collect()),
                })
                .collect(),
        )),
    }
}

pub fn named_field_to_arg_def(nf: &SvmNamedField) -> human_config::svm::ArgDef {
    human_config::svm::ArgDef {
        name: nf.name.clone(),
        ty: field_type_to_arg_type(&nf.ty),
    }
}

fn yaml_type_to_field_type(ty: &human_config::svm::ArgType) -> Result<SvmFieldType> {
    use human_config::svm::{ArgComposite as C, ArgPrimitive as P, ArgType as T};
    Ok(match ty {
        T::Primitive(p) => match p {
            P::Bool => SvmFieldType::Bool,
            P::U8 => SvmFieldType::U8,
            P::U16 => SvmFieldType::U16,
            P::U32 => SvmFieldType::U32,
            P::U64 => SvmFieldType::U64,
            P::U128 => SvmFieldType::U128,
            P::I8 => SvmFieldType::I8,
            P::I16 => SvmFieldType::I16,
            P::I32 => SvmFieldType::I32,
            P::I64 => SvmFieldType::I64,
            P::I128 => SvmFieldType::I128,
            P::F32 => SvmFieldType::F32,
            P::F64 => SvmFieldType::F64,
            P::String => SvmFieldType::String,
            P::Bytes => SvmFieldType::Bytes,
            P::Pubkey | P::PublicKey => SvmFieldType::Pubkey,
        },
        T::Composite(c) => match c {
            C::Option(inner) => SvmFieldType::Option(Box::new(yaml_type_to_field_type(inner)?)),
            C::Vec(inner) => SvmFieldType::Vec(Box::new(yaml_type_to_field_type(inner)?)),
            C::Array(inner, len) => SvmFieldType::Array {
                ty: Box::new(yaml_type_to_field_type(inner)?),
                len: *len,
            },
            C::Defined(name) => SvmFieldType::Defined(name.clone()),
            C::Struct(fields) => SvmFieldType::Struct(
                fields
                    .iter()
                    .map(yaml_arg_to_named_field)
                    .collect::<Result<_>>()?,
            ),
            C::Enum(variants) => SvmFieldType::Enum(
                variants
                    .iter()
                    .map(|v| {
                        let fields = v
                            .fields
                            .as_ref()
                            .map(|fs| {
                                fs.iter()
                                    .map(yaml_arg_to_named_field)
                                    .collect::<Result<_>>()
                            })
                            .transpose()?;
                        Ok(SvmEnumVariant {
                            name: v.name.clone(),
                            fields,
                        })
                    })
                    .collect::<Result<_>>()?,
            ),
        },
    })
}

// Suppress unused warnings on imports only referenced via paths above when
// the enum-variant constructor isn't reached at compile time.
#[allow(dead_code)]
const _UNUSED_ENUM_VARIANT: Option<SvmEnumVariant> = None;

#[derive(Debug, Clone, PartialEq)]
pub enum Abi {
    Evm(EvmAbi),
    Fuel(Box<FuelAbi>),
    /// Solana programs ship no on-chain ABI artifact. The `SvmAbi` payload
    /// holds the program-level Borsh schema (defined-types registry, source
    /// origin) shared across all of the program's instructions. The
    /// per-instruction Borsh layout lives on each `SvmEventKind`.
    Svm(SvmAbi),
}

#[derive(Debug, Clone, PartialEq)]
pub struct SvmAbi {
    /// Base58 program id this schema describes.
    pub program_id: String,
    /// Per-instruction Borsh layout (accounts + args), keyed by full
    /// discriminator bytes. Populated from an Anchor IDL's `instructions` or the
    /// bundled-schema registry; empty for inline (per-instruction YAML) schemas.
    pub instructions: BTreeMap<Vec<u8>, SvmInstructionSchema>,
    /// Nominal-type registry referenced by `SvmFieldType::Defined`. Populated
    /// from an Anchor IDL's `types:` block, the bundled-schema registry, or
    /// empty for hand-written ad-hoc schemas.
    pub defined_types: BTreeMap<String, SvmFieldType>,
    pub source: SvmSchemaSource,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SvmSchemaSource {
    /// User-supplied `idl: <path>` parsed at codegen time.
    AnchorIdl { path: String },
    /// `program_id` matched a bundled `ProgramSchema` (e.g. Metaplex).
    Bundled { name: &'static str },
    /// Hand-written per-instruction `accounts`/`args` in YAML.
    Inline,
}

impl Abi {
    fn get_path(&self) -> Option<PathBuf> {
        match self {
            Abi::Evm(abi) => abi.path.clone(),
            Abi::Fuel(abi) => Some(abi.path_buf.clone()),
            Abi::Svm(_) => None,
        }
    }

    fn fuel(fuel_abi: FuelAbi) -> Self {
        Abi::Fuel(Box::new(fuel_abi))
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Contract {
    pub name: ContractNameKey,
    pub handler_path: Option<String>,
    pub abi: Abi,
    pub events: Vec<Event>,
}

impl Contract {
    pub fn new(
        name: String,
        handler_path: Option<String>,
        events: Vec<Event>,
        abi: Abi,
    ) -> Result<Self> {
        validate_names_valid_rescript(
            &events.iter().map(|e| e.name.clone()).collect(),
            "event".to_string(),
        )?;

        // Codegen keys the generated event modules by name and routing looks
        // events up by name, so two events on one contract can't share a name.
        // Overloads (same name, different signature) are the usual cause — point
        // at the `name` alias as the fix; a byte-identical copy just needs
        // removing.
        let mut seen_by_name: HashMap<&str, &Event> = HashMap::new();
        for event in &events {
            if let Some(existing) = seen_by_name.insert(&event.name, event) {
                if existing.sighash == event.sighash {
                    return Err(anyhow!(
                        "Contract {name} defines the event \"{}\" more than once. \
                         Please remove the duplicate.",
                        event.name,
                    ));
                }
                return Err(anyhow!(
                    "Contract {name} has two events named \"{}\". Give one of them a \
                     unique name with the \"name\" field so the generated code and \
                     the indexer's routing can tell them apart.",
                    event.name,
                ));
            }
        }

        // Two events on one contract that share a dispatch key are
        // indistinguishable at routing time — one log/instruction would decode
        // to both — so reject them here. The key mirrors the runtime `eventId`:
        // sighash plus indexed-topic count for EVM, the discriminator for SVM
        // (already program-scoped, since these are one program's instructions),
        // the sighash for Fuel (a `LogData` logId or a fixed `mint`/`burn`/…).
        // Names are unique by the check above, so a collision here is always
        // between two differently-named events.
        let mut seen_by_dispatch_key: HashMap<String, String> = HashMap::new();
        for event in &events {
            let dispatch_key = match &event.kind {
                EventKind::Params(params) => {
                    let indexed_count = params.iter().filter(|p| p.indexed).count();
                    Some(format!("{}_{}", event.sighash, indexed_count))
                }
                // The router decodes the discriminator to bytes before matching,
                // so `0x0f` and `0x0F` collide — lowercase before keying.
                EventKind::Svm(svm) => Some(
                    svm.discriminator
                        .as_ref()
                        .map(|d| d.to_lowercase())
                        .unwrap_or_else(|| "none".to_string()),
                ),
                EventKind::Fuel(_) => Some(event.sighash.clone()),
            };
            if let Some(dispatch_key) = dispatch_key {
                if let Some(existing) =
                    seen_by_dispatch_key.insert(dispatch_key, event.name.clone())
                {
                    return Err(anyhow!(
                        "Contract {name} has two events the indexer can't tell apart: \
                         \"{existing}\" and \"{}\". They match the same on-chain data, so \
                         the indexer can't decide which one a log belongs to. Please remove \
                         one of them.",
                        event.name,
                    ));
                }
            }
        }

        Ok(Self {
            name,
            events,
            handler_path,
            abi,
        })
    }

    pub fn get_chain_ids(&self, system_config: &SystemConfig) -> Vec<u64> {
        system_config
            .get_chains()
            .iter()
            .filter_map(|network| {
                if network.contracts.iter().any(|c| c.name == self.name) {
                    Some(network.id)
                } else {
                    None
                }
            })
            .collect()
    }
}

#[derive(Debug, PartialEq, Clone)]
pub enum FuelEventKind {
    LogData(TypeIdent),
    Mint,
    Burn,
    Transfer,
    Call,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SvmAccountFilter {
    pub position: u8,
    pub values: Vec<String>,
}

/// Resolve an instruction's field selection into the selected transaction-field
/// names (camelCase). The listed `transaction_fields` are deduplicated in
/// declared order, then `token_balance_fields` appends `tokenBalances`.
fn resolve_svm_transaction_fields(
    fs: Option<&human_config::svm::SvmFieldSelection>,
) -> Vec<String> {
    let mut selected: Vec<String> = Vec::new();
    let Some(fs) = fs else {
        return selected;
    };
    for field in fs.transaction_fields.iter().flatten() {
        let name = field.to_string();
        if !selected.contains(&name) {
            selected.push(name);
        }
    }
    if fs.token_balance_fields == Some(true) {
        selected.push("tokenBalances".to_string());
    }
    selected
}

/// Resolve an instruction's selected block fields (camelCase), in declared
/// order. `slot`/`time`/`hash` are always included by the runtime, so they're
/// not returned here (they aren't even selectable — see `SvmBlockField`).
fn resolve_svm_block_fields(fs: Option<&human_config::svm::SvmFieldSelection>) -> Vec<String> {
    let mut selected: Vec<String> = Vec::new();
    let Some(fs) = fs else {
        return selected;
    };
    for field in fs.block_fields.iter().flatten() {
        let name = field.to_string();
        if !selected.contains(&name) {
            selected.push(name);
        }
    }
    selected
}

#[derive(Debug, Clone, PartialEq)]
pub struct SvmEventKind {
    /// Hex-encoded discriminator (`0x`-prefixed), or `None` to match every
    /// instruction in the program.
    pub discriminator: Option<String>,
    /// Length of the decoded discriminator in bytes (0 / 1 / 2 / 4 / 8). The
    /// router precomputes a per-program ordering on this so dispatch tries
    /// longest first.
    pub discriminator_byte_len: u8,
    /// Selected parent-transaction fields (camelCase names matching the public
    /// `svmTransaction` shape, incl. `tokenBalances`). Empty = no transaction.
    pub selected_transaction_fields: Vec<String>,
    /// Selected block fields (camelCase, matching `instruction.block`), excluding
    /// the always-included `slot`. Empty = only `slot`.
    pub selected_block_fields: Vec<String>,
    pub include_logs: bool,
    /// Disjunctive normal form: outer list is OR of AND-groups, inner list is
    /// AND across positions. An empty outer list means "no account filter".
    pub account_filters: Vec<Vec<SvmAccountFilter>>,
    /// `None` matches both outer and inner (CPI-invoked) instructions.
    pub is_inner: Option<bool>,
    /// Positional account names. Empty when the user supplied no schema and
    /// no bundled/IDL schema applies; in that case `decoded.accounts` is `{}`.
    pub accounts: Vec<String>,
    /// Borsh argument layout in declared order. Empty for unknown
    /// instructions; the raw `instruction.data` is still available.
    pub args: Vec<SvmNamedField>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum EventKind {
    Params(Vec<EventParam>),
    Fuel(FuelEventKind),
    Svm(SvmEventKind),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    pub kind: EventKind,
    pub name: String,
    pub sighash: String,
    /// Full event signature (e.g. "Transfer(address indexed from, address indexed to, uint256 value)")
    /// Only set for EVM events; empty for Fuel events.
    pub event_signature: String,
    pub field_selection: Option<FieldSelection>,
}

impl Event {
    /// Normalize an event signature string to handle common formatting variations:
    /// - Strip trailing semicolons
    /// - Remove spaces before commas (`uint128 ,uint16` -> `uint128,uint16`)
    /// - Collapse multiple spaces into one (`uint128,  uint16` -> `uint128, uint16`)
    fn normalize_event_signature(sig: &str) -> String {
        let sig = sig.trim();
        let sig = sig.strip_suffix(';').unwrap_or(sig).trim_end();

        let mut result = String::with_capacity(sig.len());
        let mut chars = sig.chars().peekable();

        while let Some(ch) = chars.next() {
            if ch == ',' {
                // Remove any trailing spaces before this comma that we already added
                while result.ends_with(' ') {
                    result.pop();
                }
                result.push(',');
                // Skip any whitespace after comma, then add exactly one space
                while chars.peek() == Some(&' ') {
                    chars.next();
                }
                // Add a space after comma if the next char isn't ')' or ']'
                // (to handle cases like trailing commas)
                if chars.peek().is_some()
                    && chars.peek() != Some(&')')
                    && chars.peek() != Some(&']')
                {
                    result.push(' ');
                }
            } else {
                result.push(ch);
            }
        }

        result
    }

    fn get_abi_event(event_string: &str, opt_abi: &Option<EvmAbi>) -> Result<AlloyEvent> {
        let parse_event_sig = |sig: &str| -> Result<AlloyEvent> {
            crate::config_parsing::abi_compat::parse_event_signature_to_alloy(sig).map_err(|err| {
                anyhow!(
                    "Unable to parse event signature {} due to the following error: {}. \
                     Please refer to our docs on how to correctly define a human readable ABI.",
                    sig,
                    err
                )
            })
        };

        let event_string = &Self::normalize_event_signature(event_string);

        if event_string.starts_with("event ") {
            parse_event_sig(event_string)
        } else if event_string.contains('(') {
            let signature = format!("event {}", event_string);
            parse_event_sig(&signature)
        } else {
            match opt_abi {
                Some(abi) => {
                    let events = abi
                        .typed
                        .event(event_string)
                        .ok_or_else(|| anyhow!("Event {} not found in ABI file", event_string))?;
                    // Return the first event with that name (events can be overloaded)
                    events
                        .first()
                        .cloned()
                        .ok_or_else(|| anyhow!("Event {} not found in ABI file", event_string))
                }
                None => Err(anyhow!("No abi file provided for event {}", event_string)),
            }
        }
    }

    /// Convert alloy EventParam to our abi_compat EventParam
    fn convert_event_params(alloy_event: &AlloyEvent) -> Result<Vec<EventParam>> {
        alloy_event
            .inputs
            .iter()
            .enumerate()
            .map(|(i, param)| {
                let param_name = param.name.clone();
                let name = if param_name.is_empty() {
                    format!("_{}", i)
                } else {
                    param_name
                };
                EventParam::try_from_alloy(param).map(|mut ep| {
                    ep.name = name;
                    ep
                })
            })
            .collect()
    }

    fn from_evm_events_config(
        events_config: Vec<EvmEventConfig>,
        abi_file_path: &Option<String>,
        source: &dyn ConfigSource,
        has_rpc_sync_src: bool,
    ) -> Result<(Vec<Self>, EvmAbi)> {
        let abi_from_file = EvmAbi::from_source(abi_file_path, source)?;

        let mut events = vec![];
        let mut events_abi = JsonAbi::new();

        for event_config in events_config.iter() {
            let alloy_event = Event::get_abi_event(&event_config.event, &abi_from_file)?;
            // Use alloy's selector() method which computes keccak256 of the signature
            // Note: selector() returns B256 which formats as lowercase hex with 0x prefix
            let sighash = alloy_event.selector().to_string();

            let abi_name = alloy_event.name.clone();
            let name = event_config.name.clone().unwrap_or(abi_name.clone());
            let event_signature = EvmAbi::event_signature_from_abi_event(&alloy_event);

            // Convert alloy params to our abi_compat EventParam
            let normalized_unnamed_params: Vec<EventParam> =
                Event::convert_event_params(&alloy_event)?;

            // Add the event to the ABI (alloy_event is already properly formatted)
            events_abi
                .events
                .entry(abi_name)
                .or_default()
                .push(alloy_event);
            events.push(Event {
                name,
                kind: EventKind::Params(normalized_unnamed_params),
                sighash,
                event_signature,
                field_selection: match event_config.field_selection {
                    Some(ref selection_config) => {
                        Some(FieldSelection::try_from_config_field_selection(
                            selection_config.clone(),
                            has_rpc_sync_src,
                        )?)
                    }
                    None => None,
                },
            })
        }

        let events_abi_raw = serde_json::to_string(&events_abi)
            .context("Failed serializing ABI from filtered events")?;

        Ok((
            events,
            EvmAbi {
                path: match abi_from_file {
                    Some(abi) => abi.path.clone(),
                    None => None,
                },
                raw: events_abi_raw,
                typed: events_abi,
            },
        ))
    }

    fn from_fuel_events_config(
        events_config: &[FuelEventConfig],
        abi_file_path: &str,
        source: &dyn ConfigSource,
    ) -> Result<(Vec<Self>, FuelAbi)> {
        use human_config::fuel::EventType;

        let resolved = source
            .read_config_relative_file(abi_file_path)
            .context("Failed to get ABI relative to the config")?;
        let fuel_abi = FuelAbi::parse_raw(resolved.path, abi_file_path.to_string(), resolved.raw)
            .context("Failed to parse ABI".to_string())?;

        let mut events = vec![];

        for event_config in events_config.iter() {
            let event_type = match &event_config.type_ {
                Some(event_type) => event_type.clone(),
                None => {
                    if event_config.log_id.is_some() {
                        EventType::LogData
                    } else {
                        match event_config.name.as_str() {
                            MINT_EVENT_NAME => EventType::Mint,
                            BURN_EVENT_NAME => EventType::Burn,
                            TRANSFER_EVENT_NAME => EventType::Transfer,
                            CALL_EVENT_NAME => EventType::Call,
                            _ => EventType::LogData,
                        }
                    }
                }
            };
            if event_config.log_id.is_some() && event_type != EventType::LogData {
                return Err(anyhow!(
                    "Event '{}' has both 'logId' and '{}' type set. Only one of them can be used \
                     at once.",
                    event_config.name,
                    event_type
                ));
            }
            let event = match event_type {
                EventType::LogData => {
                    let log = match &event_config.log_id {
                        None => {
                            let logged_type = fuel_abi
                                .get_type_by_struct_name(event_config.name.clone())
                                .context(
                                    "Failed to derive the event configuration from the name. Use \
                                     the logId, mint, or burn options to set it explicitly.",
                                )?;
                            fuel_abi.get_log_by_type(logged_type.id)?
                        }
                        Some(log_id) => fuel_abi.get_log(log_id)?,
                    };
                    Event {
                        name: event_config.name.clone(),
                        kind: EventKind::Fuel(FuelEventKind::LogData(log.data_type)),
                        sighash: log.id,
                        event_signature: String::new(),
                        field_selection: None,
                    }
                }
                EventType::Mint => Event {
                    name: event_config.name.clone(),
                    kind: EventKind::Fuel(FuelEventKind::Mint),
                    sighash: "mint".to_string(),
                    event_signature: String::new(),
                    field_selection: None,
                },
                EventType::Burn => Event {
                    name: event_config.name.clone(),
                    kind: EventKind::Fuel(FuelEventKind::Burn),
                    sighash: "burn".to_string(),
                    event_signature: String::new(),
                    field_selection: None,
                },
                EventType::Transfer => Event {
                    name: event_config.name.clone(),
                    kind: EventKind::Fuel(FuelEventKind::Transfer),
                    sighash: "transfer".to_string(),
                    event_signature: String::new(),
                    field_selection: None,
                },
                EventType::Call => Event {
                    name: event_config.name.clone(),
                    kind: EventKind::Fuel(FuelEventKind::Call),
                    sighash: "call".to_string(),
                    event_signature: String::new(),
                    field_selection: None,
                },
            };

            events.push(event)
        }

        // TODO: Clean up fuel_abi to include only relevant events
        Ok((events, fuel_abi))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SelectedField {
    pub name: String,
    pub data_type: TypeIdent,
}

impl PartialOrd for SelectedField {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for SelectedField {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.name.cmp(&other.name)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct FieldSelection {
    pub transaction_fields: Vec<SelectedField>,
    pub block_fields: Vec<SelectedField>,
}

impl FieldSelection {
    fn new(transaction_fields: Vec<SelectedField>, block_fields: Vec<SelectedField>) -> Self {
        Self {
            transaction_fields,
            block_fields,
        }
    }

    pub fn empty() -> Self {
        Self::new(vec![], vec![])
    }

    pub fn fuel() -> Self {
        Self::new(
            vec![SelectedField {
                name: "id".to_string(),
                data_type: TypeIdent::String,
            }],
            vec![
                SelectedField {
                    name: "id".to_string(),
                    data_type: TypeIdent::String,
                },
                SelectedField {
                    name: "height".to_string(),
                    data_type: TypeIdent::Int,
                },
                SelectedField {
                    name: "time".to_string(),
                    data_type: TypeIdent::Int,
                },
            ],
        )
    }

    pub fn svm() -> Self {
        Self::new(
            vec![SelectedField {
                name: "id".to_string(),
                data_type: TypeIdent::String,
            }],
            vec![
                SelectedField {
                    name: "slot".to_string(),
                    data_type: TypeIdent::Int,
                },
                SelectedField {
                    name: "hash".to_string(),
                    data_type: TypeIdent::String,
                },
                SelectedField {
                    name: "time".to_string(),
                    data_type: TypeIdent::Int,
                },
            ],
        )
    }

    /// Returns a FieldSelection containing ALL available EVM block and transaction fields.
    /// Used for generating complete TypeScript types where unselected fields are typed as `never`.
    pub fn all_evm() -> Self {
        use human_config::evm::{BlockField, TransactionField};
        use strum::IntoEnumIterator;

        let block_fields: Vec<SelectedField> = BlockField::iter()
            .map(|field| {
                let data_type = match field {
                    BlockField::ParentHash => TypeIdent::String,
                    BlockField::Nonce => TypeIdent::option(TypeIdent::BigInt),
                    BlockField::Sha3Uncles => TypeIdent::String,
                    BlockField::LogsBloom => TypeIdent::String,
                    BlockField::TransactionsRoot => TypeIdent::String,
                    BlockField::StateRoot => TypeIdent::String,
                    BlockField::ReceiptsRoot => TypeIdent::String,
                    BlockField::Miner => TypeIdent::Address,
                    BlockField::Difficulty => TypeIdent::option(TypeIdent::BigInt),
                    BlockField::TotalDifficulty => TypeIdent::option(TypeIdent::BigInt),
                    BlockField::ExtraData => TypeIdent::String,
                    BlockField::Size => TypeIdent::BigInt,
                    BlockField::GasLimit => TypeIdent::BigInt,
                    BlockField::GasUsed => TypeIdent::BigInt,
                    BlockField::Uncles => TypeIdent::option(TypeIdent::array(TypeIdent::String)),
                    BlockField::BaseFeePerGas => TypeIdent::option(TypeIdent::BigInt),
                    BlockField::BlobGasUsed => TypeIdent::option(TypeIdent::BigInt),
                    BlockField::ExcessBlobGas => TypeIdent::option(TypeIdent::BigInt),
                    BlockField::ParentBeaconBlockRoot => TypeIdent::option(TypeIdent::String),
                    BlockField::WithdrawalsRoot => TypeIdent::option(TypeIdent::String),
                    BlockField::L1BlockNumber => TypeIdent::option(TypeIdent::Int),
                    BlockField::SendCount => TypeIdent::option(TypeIdent::String),
                    BlockField::SendRoot => TypeIdent::option(TypeIdent::String),
                    BlockField::MixHash => TypeIdent::option(TypeIdent::String),
                };
                SelectedField {
                    name: field.to_string(),
                    data_type,
                }
            })
            .collect();

        let transaction_fields: Vec<SelectedField> = TransactionField::iter()
            .map(|field| {
                let data_type = match field {
                    TransactionField::TransactionIndex => TypeIdent::Int,
                    TransactionField::Hash => TypeIdent::String,
                    TransactionField::From => TypeIdent::option(TypeIdent::Address),
                    TransactionField::To => TypeIdent::option(TypeIdent::Address),
                    TransactionField::Gas => TypeIdent::BigInt,
                    TransactionField::GasPrice => TypeIdent::option(TypeIdent::BigInt),
                    TransactionField::MaxPriorityFeePerGas => TypeIdent::option(TypeIdent::BigInt),
                    TransactionField::MaxFeePerGas => TypeIdent::option(TypeIdent::BigInt),
                    TransactionField::CumulativeGasUsed => TypeIdent::BigInt,
                    TransactionField::EffectiveGasPrice => TypeIdent::BigInt,
                    TransactionField::GasUsed => TypeIdent::BigInt,
                    TransactionField::Input => TypeIdent::String,
                    TransactionField::Nonce => TypeIdent::BigInt,
                    TransactionField::Value => TypeIdent::BigInt,
                    TransactionField::V => TypeIdent::option(TypeIdent::String),
                    TransactionField::R => TypeIdent::option(TypeIdent::String),
                    TransactionField::S => TypeIdent::option(TypeIdent::String),
                    TransactionField::ContractAddress => TypeIdent::option(TypeIdent::Address),
                    TransactionField::LogsBloom => TypeIdent::String,
                    TransactionField::Root => TypeIdent::option(TypeIdent::String),
                    TransactionField::Status => TypeIdent::option(TypeIdent::Int),
                    TransactionField::YParity => TypeIdent::option(TypeIdent::String),
                    TransactionField::MaxFeePerBlobGas => TypeIdent::option(TypeIdent::BigInt),
                    TransactionField::BlobVersionedHashes => {
                        TypeIdent::option(TypeIdent::array(TypeIdent::String))
                    }
                    TransactionField::Type => TypeIdent::option(TypeIdent::Int),
                    TransactionField::L1Fee => TypeIdent::option(TypeIdent::BigInt),
                    TransactionField::L1GasPrice => TypeIdent::option(TypeIdent::BigInt),
                    TransactionField::L1GasUsed => TypeIdent::option(TypeIdent::BigInt),
                    TransactionField::L1FeeScalar => TypeIdent::option(TypeIdent::Float),
                    TransactionField::GasUsedForL1 => TypeIdent::option(TypeIdent::BigInt),
                    TransactionField::AccessList => {
                        TypeIdent::option(TypeIdent::array(TypeIdent::Unknown))
                    }
                    TransactionField::AuthorizationList => {
                        TypeIdent::option(TypeIdent::array(TypeIdent::Unknown))
                    }
                };
                SelectedField {
                    name: field.to_string(),
                    data_type,
                }
            })
            .collect();

        Self::new(transaction_fields, block_fields)
    }

    pub fn try_from_config_field_selection(
        field_selection_cfg: human_config::evm::FieldSelection,
        // For validating transaction field selection with rpc
        has_rpc_sync_src: bool,
    ) -> Result<Self> {
        use human_config::evm::BlockField;
        use human_config::evm::TransactionField;

        let transaction_fields = field_selection_cfg.transaction_fields.unwrap_or_default();
        let block_fields = field_selection_cfg.block_fields.unwrap_or_default();

        //Validate no duplicates in field selection
        let tx_duplicates: Vec<_> = transaction_fields.iter().duplicates().collect();

        if !tx_duplicates.is_empty() {
            return Err(anyhow!(
                "transaction_fields selection contains the following duplicates: {}",
                tx_duplicates.iter().join(", ")
            ));
        }

        let block_duplicates: Vec<_> = block_fields.iter().duplicates().collect();

        if !block_duplicates.is_empty() {
            return Err(anyhow!(
                "block_fields selection contains the following duplicates: {}",
                block_duplicates.iter().join(", ")
            ));
        }

        if has_rpc_sync_src {
            let invalid_rpc_tx_fields: Vec<_> = transaction_fields
                .iter()
                .filter(|&field| RpcTransactionField::try_from(field.clone()).is_err())
                .cloned()
                .collect();

            if !invalid_rpc_tx_fields.is_empty() {
                return Err(anyhow!(
                    "The following selected transaction_fields are unavailable for indexing via \
                     RPC: {}",
                    invalid_rpc_tx_fields.iter().join(", ")
                ));
            }

            let invalid_rpc_block_fields: Vec<_> = block_fields
                .iter()
                .filter(|&field| RpcBlockField::try_from(field.clone()).is_err())
                .cloned()
                .collect();

            if !invalid_rpc_block_fields.is_empty() {
                return Err(anyhow!(
                    "The following selected block_fields are unavailable for indexing via RPC: {}",
                    invalid_rpc_block_fields.iter().join(", ")
                ));
            }
        }

        let mut selected_block_fields = vec![];

        type Res = TypeIdent;
        type Block = BlockField;
        type Tx = TransactionField;

        for block_field in block_fields {
            let data_type = match block_field {
                Block::ParentHash => Res::String,
                Block::Nonce => Res::option(Res::BigInt),
                Block::Sha3Uncles => Res::String,
                Block::LogsBloom => Res::String,
                Block::TransactionsRoot => Res::String,
                Block::StateRoot => Res::String,
                Block::ReceiptsRoot => Res::String,
                Block::Miner => Res::Address,
                Block::Difficulty => Res::option(Res::BigInt),
                Block::TotalDifficulty => Res::option(Res::BigInt),
                Block::ExtraData => Res::String,
                Block::Size => Res::BigInt,
                Block::GasLimit => Res::BigInt,
                Block::GasUsed => Res::BigInt,
                Block::Uncles => Res::option(Res::array(Res::String)),
                Block::BaseFeePerGas => Res::option(Res::BigInt),
                Block::BlobGasUsed => Res::option(Res::BigInt),
                Block::ExcessBlobGas => Res::option(Res::BigInt),
                Block::ParentBeaconBlockRoot => Res::option(Res::String),
                Block::WithdrawalsRoot => Res::option(Res::String),
                // Block::Withdrawals => todo!(), //should be array of withdrawal record
                Block::L1BlockNumber => Res::option(Res::Int),
                Block::SendCount => Res::option(Res::String),
                Block::SendRoot => Res::option(Res::String),
                Block::MixHash => Res::option(Res::String),
            };
            selected_block_fields.push(SelectedField {
                name: block_field.to_string(),
                data_type,
            })
        }

        let mut selected_transaction_fields = vec![];

        for transaction_field in transaction_fields {
            let data_type = match transaction_field {
                Tx::TransactionIndex => Res::Int,
                Tx::Hash => Res::String,
                Tx::From => Res::option(Res::Address),
                Tx::To => Res::option(Res::Address),
                Tx::Gas => Res::BigInt,
                Tx::GasPrice => Res::option(Res::BigInt),
                Tx::MaxPriorityFeePerGas => Res::option(Res::BigInt),
                Tx::MaxFeePerGas => Res::option(Res::BigInt),
                Tx::CumulativeGasUsed => Res::BigInt,
                Tx::EffectiveGasPrice => Res::BigInt,
                Tx::GasUsed => Res::BigInt,
                Tx::Input => Res::String,
                Tx::Nonce => Res::BigInt,
                Tx::Value => Res::BigInt,
                Tx::V => Res::option(Res::String),
                Tx::R => Res::option(Res::String),
                Tx::S => Res::option(Res::String),
                Tx::ContractAddress => Res::option(Res::Address),
                Tx::LogsBloom => Res::String,
                Tx::Root => Res::option(Res::String),
                Tx::Status => Res::option(Res::Int),
                Tx::YParity => Res::option(Res::String),
                Tx::MaxFeePerBlobGas => Res::option(Res::BigInt),
                Tx::BlobVersionedHashes => Res::option(Res::array(Res::String)),
                Tx::Type => Res::option(Res::Int),
                Tx::L1Fee => Res::option(Res::BigInt),
                Tx::L1GasPrice => Res::option(Res::BigInt),
                Tx::L1GasUsed => Res::option(Res::BigInt),
                Tx::L1FeeScalar => Res::option(Res::Float),
                Tx::GasUsedForL1 => Res::option(Res::BigInt),
                Tx::AccessList => Res::option(Res::Array(Box::new(Res::TypeApplication {
                    name: "HyperSyncClient.ResponseTypes.accessList".to_string(),
                    type_params: vec![],
                }))),
                Tx::AuthorizationList => Res::option(Res::Array(Box::new(Res::TypeApplication {
                    name: "HyperSyncClient.ResponseTypes.authorizationList".to_string(),
                    type_params: vec![],
                }))),
            };
            selected_transaction_fields.push(SelectedField {
                name: transaction_field.to_string(),
                data_type,
            })
        }

        Ok(Self::new(
            selected_transaction_fields,
            selected_block_fields,
        ))
    }
}

#[cfg(test)]
mod test {
    use std::{collections::HashMap, path::PathBuf};

    use super::SystemConfig;
    use crate::{config_parsing::system_config::Event, project_paths::ParsedProjectPaths};
    use pretty_assertions::assert_eq;

    #[test]
    fn in_memory_yaml_matches_filesystem_public_config() {
        let test_dir = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
        let project_paths = ParsedProjectPaths::new(&test_dir, "configs/unquoted-hex-address.yaml")
            .expect("project paths");
        let filesystem =
            SystemConfig::parse_from_project_files(&project_paths).expect("filesystem config");

        let yaml = std::fs::read_to_string(&project_paths.config).expect("config YAML");
        let schema =
            std::fs::read_to_string(PathBuf::from(&test_dir).join("schemas/schema.graphql"))
                .expect("schema");
        let abi = std::fs::read_to_string(PathBuf::from(&test_dir).join("abis/Contract1.json"))
            .expect("ABI");
        let files = HashMap::from([("../abis/Contract1.json".to_string(), abi)]);
        let memory = SystemConfig::parse_yaml(&yaml, Some(&schema), &HashMap::new(), &files, false)
            .expect("in-memory config");

        assert_eq!(
            filesystem.to_public_config_json(false).unwrap(),
            memory.to_public_config_json(false).unwrap(),
        );
    }

    #[test]
    fn in_memory_fuel_abi_matches_filesystem_public_config() {
        let test_dir = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
        let project_paths =
            ParsedProjectPaths::new(&test_dir, "configs/fuel-config.yaml").expect("project paths");
        let filesystem =
            SystemConfig::parse_from_project_files(&project_paths).expect("filesystem config");

        let yaml = std::fs::read_to_string(&project_paths.config).expect("config YAML");
        let schema =
            std::fs::read_to_string(PathBuf::from(&test_dir).join("configs/schema.graphql"))
                .expect("schema");
        let abi = std::fs::read_to_string(PathBuf::from(&test_dir).join("abis/greeter-abi.json"))
            .expect("Fuel ABI");
        let files = HashMap::from([("../abis/greeter-abi.json".to_string(), abi)]);
        let memory = SystemConfig::parse_yaml(&yaml, Some(&schema), &HashMap::new(), &files, false)
            .expect("in-memory config");

        assert_eq!(
            filesystem.to_public_config_json(false).unwrap(),
            memory.to_public_config_json(false).unwrap(),
        );
    }

    #[test]
    fn test_get_contract_abi() {
        let test_dir = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
        let project_root = test_dir.as_str();
        let config_dir = "configs/config1.yaml";
        let project_paths = ParsedProjectPaths::new(project_root, config_dir)
            .expect("Failed creating parsed_paths");

        let config =
            SystemConfig::parse_from_project_files(&project_paths).expect("Failed parsing config");

        let contract_name = "Contract1".to_string();

        let contract_abi = match &config
            .get_contract(&contract_name)
            .expect("Failed getting contract")
            .abi
        {
            super::Abi::Evm(abi) => abi.typed.clone(),
            super::Abi::Fuel(_) => panic!("Fuel abi should not be parsed"),
            super::Abi::Svm(_) => panic!("Svm abi should not be parsed"),
        };

        let expected_abi_string = r#"
                [
                {
                    "anonymous": false,
                    "inputs": [
                    {
                        "indexed": false,
                        "name": "id",
                        "type": "uint256"
                    },
                    {
                        "indexed": false,
                        "name": "owner",
                        "type": "address"
                    },
                    {
                        "indexed": false,
                        "name": "displayName",
                        "type": "string"
                    },
                    {
                        "indexed": false,
                        "name": "imageUrl",
                        "type": "string"
                    }
                    ],
                    "name": "NewGravatar",
                    "type": "event"
                },
                {
                    "anonymous": false,
                    "inputs": [
                    {
                        "indexed": false,
                        "name": "id",
                        "type": "uint256"
                    },
                    {
                        "indexed": false,
                        "name": "owner",
                        "type": "address"
                    },
                    {
                        "indexed": false,
                        "name": "displayName",
                        "type": "string"
                    },
                    {
                        "indexed": false,
                        "name": "imageUrl",
                        "type": "string"
                    }
                    ],
                    "name": "UpdatedGravatar",
                    "type": "event"
                }
                ]
    "#;

        let expected_abi: alloy_json_abi::JsonAbi =
            serde_json::from_str(expected_abi_string).unwrap();

        assert_eq!(expected_abi, contract_abi);
    }

    #[test]
    fn normalize_event_signature_handles_formatting_issues() {
        // Trailing semicolon
        assert_eq!(
            Event::normalize_event_signature("Transfer(address from);"),
            "Transfer(address from)"
        );
        // Space before comma
        assert_eq!(
            Event::normalize_event_signature("Foo(uint128 ,uint16)"),
            "Foo(uint128, uint16)"
        );
        // Multiple spaces after comma
        assert_eq!(
            Event::normalize_event_signature("Foo(uint128,  uint16)"),
            "Foo(uint128, uint16)"
        );
        // No space after comma (should add one)
        assert_eq!(
            Event::normalize_event_signature("Foo(uint128,uint16)"),
            "Foo(uint128, uint16)"
        );
        // Already well-formatted
        assert_eq!(
            Event::normalize_event_signature("Foo(uint128, uint16)"),
            "Foo(uint128, uint16)"
        );
        // Leading/trailing whitespace
        assert_eq!(
            Event::normalize_event_signature("  Foo(uint128, uint16)  "),
            "Foo(uint128, uint16)"
        );
    }

    #[test]
    fn parse_event_sig_with_named_tuple_components_issue_1206() {
        // Regression for https://github.com/enviodev/hyperindex/issues/1206.
        // A custom event signature whose tuple components are named must not
        // require an ABI file. Selector should match the canonical tuple-only
        // signature (component names stripped per ABI spec).
        let event_string = "ConsumeBoostVial(address from, uint256 playerId, (uint40 a, uint24 b, uint16 c, uint16 d, uint8 e) playerBoostInfo)";
        let parsed = Event::get_abi_event(event_string, &None).unwrap();

        let canonical = "ConsumeBoostVial(address from, uint256 playerId, (uint40,uint24,uint16,uint16,uint8) playerBoostInfo)";
        let canonical_parsed = Event::get_abi_event(canonical, &None).unwrap();

        // Selector is computed from the canonical (unnamed) signature so the
        // two forms must match.
        assert_eq!(
            parsed.selector().to_string(),
            canonical_parsed.selector().to_string(),
        );

        // Component names must survive into our converted EventParam tree so
        // codegen can emit named record fields.
        let params = Event::convert_event_params(&parsed).unwrap();
        let tuple_param = params
            .iter()
            .find(|p| p.name == "playerBoostInfo")
            .expect("playerBoostInfo");
        let names: Vec<Option<&str>> = match &tuple_param.kind {
            crate::config_parsing::abi_compat::AbiType::Tuple(fields) => {
                fields.iter().map(|f| f.name.as_deref()).collect()
            }
            other => panic!("expected Tuple, got {:?}", other),
        };
        assert_eq!(
            names,
            vec![Some("a"), Some("b"), Some("c"), Some("d"), Some("e")]
        );
    }

    #[test]
    fn test_parse_url() {
        let valid_url_1 = "https://eth-mainnet.g.alchemy.com/v2/T7uPV59s7knYTOUardPPX0hq7n7_rQwv";
        let valid_url_2 = "http://api.example.org:8080";
        let valid_url_3 = "https://eth.com/rpc-endpoint";
        assert_eq!(super::parse_url(valid_url_1), Some(valid_url_1.to_string()));
        assert_eq!(super::parse_url(valid_url_2), Some(valid_url_2.to_string()));
        assert_eq!(super::parse_url(valid_url_3), Some(valid_url_3.to_string()));

        let invalid_url_missing_slash = "http:/example.com";
        let invalid_url_other_protocol = "ftp://example.com";
        assert_eq!(super::parse_url(invalid_url_missing_slash), None);
        assert_eq!(super::parse_url(invalid_url_other_protocol), None);

        // With trailing slashes
        assert_eq!(
            super::parse_url("https://somechain.hypersync.xyz/"),
            Some("https://somechain.hypersync.xyz".to_string())
        );
        assert_eq!(
            super::parse_url("https://somechain.hypersync.xyz//"),
            Some("https://somechain.hypersync.xyz".to_string())
        );
    }

    #[test]
    fn test_valid_version_numbers() {
        let valid_version_numbers = vec![
            "0.0.0",
            "999.999.999",
            "0.0.1",
            "10.2.3",
            "2.0.0-rc.1",
            "2.26.0-alpha.0",
            "2.26.0-alpha.10",
            "0.0.0-main-20241001144237-a236a894",
        ];

        for vn in valid_version_numbers {
            assert!(super::is_valid_release_version_number(vn));
        }
    }

    #[test]
    fn test_invalid_version_numbers() {
        let invalid_version_numbers = vec![
            "v10.1.0",
            "0.1",
            "0.0.1-dev",
            "0.1.*",
            "^0.1.2",
            "0.0.1.2",
            "1..1",
            "1.1.",
            ".1.1",
            "1.1.1.",
        ];
        for vn in invalid_version_numbers {
            assert!(!super::is_valid_release_version_number(vn));
        }
    }

    #[test]
    fn test_storage_resolve() {
        use super::human_config::{
            ColumnNameFormat, StorageBackendConfig, StorageBackendOptions, StorageConfig,
        };

        let enabled = |b: bool| Some(StorageBackendConfig::Enabled(b));
        let options = |default: Option<bool>| {
            Some(StorageBackendConfig::Options(StorageBackendOptions {
                default,
                column_name_format: None,
            }))
        };
        let with_format = |column_name_format: Option<ColumnNameFormat>| {
            Some(StorageBackendConfig::Options(StorageBackendOptions {
                default: None,
                column_name_format,
            }))
        };
        let backend = |entity_default: bool, column_name_format: ColumnNameFormat| {
            Some(super::StorageBackend {
                entity_default,
                column_name_format,
            })
        };

        // Default (None) -> postgres only, postgres is the entity default
        assert_eq!(
            super::Storage::resolve(None).unwrap(),
            super::Storage {
                postgres: backend(true, ColumnNameFormat::Original),
                clickhouse: None,
            }
        );

        // Empty struct -> defaults
        assert_eq!(
            super::Storage::resolve(Some(&StorageConfig {
                postgres: None,
                clickhouse: None,
            }))
            .unwrap(),
            super::Storage {
                postgres: backend(true, ColumnNameFormat::Original),
                clickhouse: None,
            }
        );

        // Both enabled -> ok; with multiple backends none is an implicit
        // entity default
        assert_eq!(
            super::Storage::resolve(Some(&StorageConfig {
                postgres: enabled(true),
                clickhouse: enabled(true),
            }))
            .unwrap(),
            super::Storage {
                postgres: backend(false, ColumnNameFormat::Original),
                clickhouse: backend(false, ColumnNameFormat::Original),
            }
        );

        // Object form implies enabled; `default: true` opts clickhouse in
        // as an entity default
        assert_eq!(
            super::Storage::resolve(Some(&StorageConfig {
                postgres: enabled(true),
                clickhouse: options(Some(true)),
            }))
            .unwrap(),
            super::Storage {
                postgres: backend(false, ColumnNameFormat::Original),
                clickhouse: backend(true, ColumnNameFormat::Original),
            }
        );

        // Both backends can be entity defaults when opted in explicitly
        assert_eq!(
            super::Storage::resolve(Some(&StorageConfig {
                postgres: options(Some(true)),
                clickhouse: options(Some(true)),
            }))
            .unwrap(),
            super::Storage {
                postgres: backend(true, ColumnNameFormat::Original),
                clickhouse: backend(true, ColumnNameFormat::Original),
            }
        );

        // Postgres as a single storage can opt out of being the entity
        // default (entities then must carry @storage)
        assert_eq!(
            super::Storage::resolve(Some(&StorageConfig {
                postgres: options(Some(false)),
                clickhouse: None,
            }))
            .unwrap(),
            super::Storage {
                postgres: backend(false, ColumnNameFormat::Original),
                clickhouse: None,
            }
        );

        // An options object enables the backend and resolves its options
        assert_eq!(
            super::Storage::resolve(Some(&StorageConfig {
                postgres: with_format(Some(ColumnNameFormat::SnakeCase)),
                clickhouse: None,
            }))
            .unwrap(),
            super::Storage {
                postgres: backend(true, ColumnNameFormat::SnakeCase),
                clickhouse: None,
            }
        );

        // An empty options object keeps the defaults
        assert_eq!(
            super::Storage::resolve(Some(&StorageConfig {
                postgres: with_format(None),
                clickhouse: None,
            }))
            .unwrap(),
            super::Storage {
                postgres: backend(true, ColumnNameFormat::Original),
                clickhouse: None,
            }
        );

        // column_name_format is resolved per backend: only clickhouse opts in
        assert_eq!(
            super::Storage::resolve(Some(&StorageConfig {
                postgres: enabled(true),
                clickhouse: with_format(Some(ColumnNameFormat::SnakeCase)),
            }))
            .unwrap(),
            super::Storage {
                postgres: backend(false, ColumnNameFormat::Original),
                clickhouse: backend(false, ColumnNameFormat::SnakeCase),
            }
        );

        // Backends can diverge in both directions
        assert_eq!(
            super::Storage::resolve(Some(&StorageConfig {
                postgres: with_format(Some(ColumnNameFormat::SnakeCase)),
                clickhouse: with_format(Some(ColumnNameFormat::Original)),
            }))
            .unwrap(),
            super::Storage {
                postgres: backend(false, ColumnNameFormat::SnakeCase),
                clickhouse: backend(false, ColumnNameFormat::Original),
            }
        );
    }

    // --- validate_entity_storage: per-entity storage routing checks ---

    mod entity_storage_validation {
        use super::super::{validate_entity_storage, Storage};
        use crate::config_parsing::entity_parsing::{
            ClickHouseEntityStorage, ClickHouseTableOptions, Entity, Schema,
        };
        use crate::config_parsing::human_config::ColumnNameFormat;

        // Bypass `Schema::new` validation: only storage routing matters here.
        fn make_schema(entities: Vec<Entity>) -> Schema {
            let mut schema = Schema::empty();
            for entity in entities {
                schema.entities.insert(entity.name.clone(), entity);
            }
            schema
        }

        fn entity(name: &str, postgres: Option<bool>, clickhouse: Option<bool>) -> Entity {
            Entity {
                name: name.to_string(),
                fields: Vec::new(),
                multi_field_indexes: Vec::new(),
                description: None,
                postgres,
                clickhouse: clickhouse.map(ClickHouseEntityStorage::Enabled),
            }
        }

        fn backend(entity_default: bool) -> Option<super::super::StorageBackend> {
            Some(super::super::StorageBackend {
                entity_default,
                column_name_format: ColumnNameFormat::Original,
            })
        }

        fn postgres_only() -> Storage {
            Storage {
                postgres: backend(true),
                clickhouse: None,
            }
        }

        fn multi(postgres_default: bool, clickhouse_default: bool) -> Storage {
            Storage {
                postgres: backend(postgres_default),
                clickhouse: backend(clickhouse_default),
            }
        }

        #[test]
        fn single_storage_no_directive_ok() {
            let schema = make_schema(vec![entity("Transfer", None, None)]);
            assert!(validate_entity_storage(&postgres_only(), &schema).is_ok());
        }

        #[test]
        fn single_storage_matching_directive_ok() {
            let schema = make_schema(vec![entity("Transfer", Some(true), None)]);
            assert!(validate_entity_storage(&postgres_only(), &schema).is_ok());
        }

        #[test]
        fn multi_storage_all_annotated_ok() {
            let schema = make_schema(vec![
                entity("Transfer", Some(true), None),
                entity("Snapshot", None, Some(true)),
                entity("Audit", Some(true), Some(true)),
            ]);
            assert!(validate_entity_storage(&multi(false, false), &schema).is_ok());
        }

        #[test]
        fn multi_storage_no_directive_falls_back_to_defaults_ok() {
            let schema = make_schema(vec![
                entity("Transfer", None, None),
                entity("Snapshot", None, Some(true)),
            ]);
            assert!(validate_entity_storage(&multi(true, false), &schema).is_ok());
            assert!(validate_entity_storage(&multi(false, true), &schema).is_ok());
        }

        // The table options object form opts the entity into ClickHouse, so
        // it must be rejected when ClickHouse isn't enabled globally.
        #[test]
        fn clickhouse_table_options_require_enabled_backend() {
            let schema = make_schema(vec![Entity {
                clickhouse: Some(ClickHouseEntityStorage::Options(ClickHouseTableOptions {
                    partition_by: Some("toYYYYMM(timestamp)".to_string()),
                    ..ClickHouseTableOptions::default()
                })),
                ..entity("Transfer", Some(true), None)
            }]);
            assert!(validate_entity_storage(&postgres_only(), &schema).is_err());
            assert!(validate_entity_storage(&multi(false, false), &schema).is_ok());
        }
    }

    // --- validate_db_column_names: snake_case column collision checks ---

    mod db_column_name_validation {
        use super::super::{validate_db_column_names, Storage};
        use crate::config_parsing::{entity_parsing::Schema, human_config::ColumnNameFormat};

        fn storage(column_name_format: ColumnNameFormat) -> Storage {
            Storage {
                postgres: Some(super::super::StorageBackend {
                    entity_default: true,
                    column_name_format,
                }),
                clickhouse: None,
            }
        }

        #[test]
        fn snake_case_unique_columns_ok() {
            let schema = Schema::from_string(
                r#"
type Token {
  id: ID!
  tokenId: BigInt!
  transactionIndex: Int!
}"#,
            )
            .unwrap();
            assert!(
                validate_db_column_names(&storage(ColumnNameFormat::SnakeCase), &schema).is_ok()
            );
        }

        // ClickHouse has no 63-character identifier limit, so a name that
        // only becomes too long under ClickHouse's snake_case is accepted
        // as long as the Postgres column stays within the limit.
        #[test]
        fn length_limit_not_applied_to_clickhouse_columns() {
            let long_field = "a".repeat(30) + "B" + &"b".repeat(29) + "Cc";
            let schema = Schema::from_string(&format!(
                r#"
type Token {{
  id: ID!
  {long_field}: BigInt!
}}"#,
            ))
            .unwrap();
            // 62 characters as written, 64 once snake_case inserts separators
            assert_eq!(long_field.len(), 62);
            let pg_original_ch_snake = Storage {
                postgres: Some(super::super::StorageBackend {
                    entity_default: true,
                    column_name_format: ColumnNameFormat::Original,
                }),
                clickhouse: Some(super::super::StorageBackend {
                    entity_default: false,
                    column_name_format: ColumnNameFormat::SnakeCase,
                }),
            };
            assert!(validate_db_column_names(&pg_original_ch_snake, &schema).is_ok());
            assert!(
                validate_db_column_names(&storage(ColumnNameFormat::SnakeCase), &schema).is_err()
            );
        }

        // The same schema is valid with the default naming, where the
        // reference column is `token_id` but the scalar stays `tokenId`.
        #[test]
        fn graphql_naming_skips_the_check() {
            let schema = Schema::from_string(
                r#"
type Token {
  id: ID!
}

type Transfer {
  id: ID!
  token: Token!
  tokenId: BigInt!
}"#,
            )
            .unwrap();
            assert!(
                validate_db_column_names(&storage(ColumnNameFormat::Original), &schema).is_ok()
            );
        }
    }

    // --- validate_clickhouse_nullable_arrays: nullable array fields rejected
    // on ClickHouse-backed entities ---

    mod clickhouse_nullable_array_validation {
        use super::super::{validate_clickhouse_nullable_arrays, Storage, StorageBackend};
        use crate::config_parsing::{entity_parsing::Schema, human_config::ColumnNameFormat};

        fn backend(entity_default: bool) -> Option<StorageBackend> {
            Some(StorageBackend {
                entity_default,
                column_name_format: ColumnNameFormat::Original,
            })
        }

        fn multi(postgres_default: bool, clickhouse_default: bool) -> Storage {
            Storage {
                postgres: backend(postgres_default),
                clickhouse: backend(clickhouse_default),
            }
        }

        #[test]
        fn required_array_on_clickhouse_entity_ok() {
            let schema = Schema::from_string(
                r#"
type Foo @storage(postgres: true, clickhouse: true) {
  id: ID!
  tags: [String!]!
}"#,
            )
            .unwrap();
            assert!(validate_clickhouse_nullable_arrays(&multi(false, false), &schema).is_ok());
        }

        // A nullable array is valid on Postgres, so an entity routed only to
        // Postgres must pass even when ClickHouse is enabled and default.
        #[test]
        fn nullable_array_on_postgres_only_entity_ok() {
            let schema = Schema::from_string(
                r#"
type Foo @storage(postgres: true) {
  id: ID!
  tags: [String!]
}"#,
            )
            .unwrap();
            assert!(validate_clickhouse_nullable_arrays(&multi(false, true), &schema).is_ok());
        }

        // Without a storage directive the entity follows the backend `default`:
        // a ClickHouse default routes it there and the nullable array is rejected,
        // while a Postgres-only default keeps it valid.
        #[test]
        fn nullable_array_routed_by_default() {
            let schema = Schema::from_string(
                r#"
type Foo {
  id: ID!
  tags: [String!]
}"#,
            )
            .unwrap();
            assert!(validate_clickhouse_nullable_arrays(&multi(false, true), &schema).is_err());
            assert!(validate_clickhouse_nullable_arrays(&multi(true, false), &schema).is_ok());
        }

        #[test]
        fn validation_skipped_when_clickhouse_disabled() {
            let schema = Schema::from_string(
                r#"
type Foo {
  id: ID!
  tags: [String!]
}"#,
            )
            .unwrap();
            let storage = Storage {
                postgres: backend(true),
                clickhouse: None,
            };
            assert!(validate_clickhouse_nullable_arrays(&storage, &schema).is_ok());
        }
    }

    mod svm_translation {
        use super::SystemConfig;
        use crate::config_parsing::system_config::{Abi, DataSource, EventKind};
        use crate::project_paths::ParsedProjectPaths;
        use pretty_assertions::assert_eq;

        /// End-to-end: the Metaplex YAML fixture deserializes, validates, and
        /// translates into a single Contract whose two Events carry the
        /// expected discriminator + flags. Guards Stage 3 + Stage 4 plumbing
        /// from drifting out of sync.
        #[test]
        fn translates_metaplex_yaml_into_contract_events() {
            let test_dir = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
            let project_paths =
                ParsedProjectPaths::new(&test_dir, "configs/svm-metaplex-config.yaml")
                    .expect("paths");
            let config = SystemConfig::parse_from_project_files(&project_paths).expect("parse");

            // Single chain, single program -> one contract with two events.
            let contracts = config.contracts.values().collect::<Vec<_>>();
            assert_eq!(contracts.len(), 1);
            let token_metadata = contracts[0];
            assert_eq!(token_metadata.name, "TokenMetadata");
            assert!(matches!(token_metadata.abi, Abi::Svm(_)));
            assert_eq!(token_metadata.events.len(), 2);

            let to_strings = |fields: &[&str]| {
                fields
                    .iter()
                    .map(|s| s.to_string())
                    .collect::<Vec<String>>()
            };
            let kinds: Vec<_> = token_metadata
                .events
                .iter()
                .map(|e| match &e.kind {
                    EventKind::Svm(k) => (
                        e.name.as_str(),
                        k.discriminator.as_deref(),
                        k.discriminator_byte_len,
                        k.selected_transaction_fields.clone(),
                        k.include_logs,
                        k.account_filters.len(),
                    ),
                    _ => panic!("expected Svm event kind, got {:?}", e.kind),
                })
                .collect();
            assert_eq!(
                kinds,
                vec![
                    (
                        "CreateMetadataAccountV3",
                        Some("0x21"),
                        1,
                        to_strings(&[]),
                        false,
                        0
                    ),
                    (
                        "UpdateMetadataAccountV2",
                        Some("0x0f"),
                        1,
                        to_strings(&["signatures"]),
                        false,
                        1
                    ),
                ],
            );

            // Chain data carries the program_id on the contract-side address,
            // and the HyperSync URL flows through to the source config.
            let chains = config.get_chains();
            assert_eq!(chains.len(), 1);
            let chain = chains[0];
            assert_eq!(chain.contracts.len(), 1);
            assert_eq!(
                chain.contracts[0].addresses,
                vec!["metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s".to_string()],
            );
            assert!(matches!(
                &chain.sync_source,
                DataSource::Svm {
                    hypersync_endpoint_url: Some(url),
                    ..
                } if url == "https://solana.hypersync.xyz"
            ));
        }
    }
}
