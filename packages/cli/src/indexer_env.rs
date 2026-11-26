//! Every environment variable the indexer runtime reads, parsed and validated
//! in one pass. The runtime gets this as config and never reads the
//! environment itself.

use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexerEnv {
    pub indexing_max_buffer_size: u32,
    pub max_partition_size: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_filter_address_threshold: Option<u32>,
    pub in_memory_objects_target: u32,
    pub server_port: u16,
    pub tui: bool,
    pub envio_app_url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub envio_api_token: Option<String>,
    pub hyper_sync: HyperSyncEnv,
    pub rpc_sync: RpcSyncEnv,
    pub logger: LoggerEnv,
    pub db: DbEnv,
    pub click_house: ClickHouseEnv,
    pub hasura: HasuraEnv,
    pub throttle: ThrottleEnv,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub internal_worker: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HyperSyncEnv {
    pub client_timeout_millis: u32,
    pub serialization_format: &'static str,
    pub enable_query_caching: bool,
    pub log_filter: String,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RpcSyncEnv {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub initial_block_interval: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub backoff_multiplicative: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub acceleration_additive: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub interval_ceiling: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LoggerEnv {
    pub strategy: String,
    pub file: String,
    /// Unset means the entry point's own default: info for a run, silent for a
    /// test indexer.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub level: Option<&'static str>,
    pub file_level: &'static str,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DbEnv {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub database: String,
    pub schema: String,
    pub ssl_mode: &'static str,
    /// The budget for the whole run, not for one process: a run that splits
    /// across workers divides it among them, and each caps its own pool to its
    /// share. Splitting takes two workers and a worker takes two connections, so
    /// a budget under 4 (the default among them) keeps the run in one process.
    pub max_connections: u32,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClickHouseEnv {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub database: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    /// Empty is a valid, passwordless ClickHouse user, so only unset is `None`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub password: Option<String>,
    pub replicated: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub database_engine: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HasuraEnv {
    pub enabled: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub response_limit: Option<u32>,
    pub graphql_endpoint: String,
    pub url: String,
    pub role: String,
    pub secret: String,
    pub aggregate_entities: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ThrottleEnv {
    pub chain_metadata_interval_millis: u32,
    pub prune_stale_data_interval_millis: u32,
}

/// What the process can tell about its terminal, which the environment alone
/// doesn't say.
pub struct Terminal {
    pub stdout_is_tty: bool,
}

const LOG_LEVELS: [&str; 11] = [
    "trace", "debug", "info", "warn", "error", "fatal", "udebug", "uinfo", "uwarn", "uerror",
    "silent",
];
const HYPERSYNC_LOG_LEVELS: [&str; 5] = ["trace", "debug", "info", "warn", "error"];
const SSL_MODES: [&str; 4] = ["require", "allow", "prefer", "verify-full"];

/// Collects every problem before failing, so one start names all of them.
struct Reader<'a> {
    lookup: &'a dyn Fn(&str) -> Option<String>,
    is_production: bool,
    invalid: Vec<String>,
    missing: Vec<String>,
}

impl Reader<'_> {
    /// An empty value counts as unset.
    fn raw(&self, name: &str) -> Option<String> {
        (self.lookup)(name).filter(|value| !value.is_empty())
    }

    fn parsed<T>(&mut self, name: &str, parse: impl Fn(&str) -> Result<T, String>) -> Option<T> {
        let value = self.raw(name)?;
        match parse(&value) {
            Ok(parsed) => Some(parsed),
            Err(expected) => {
                self.invalid.push(format!(
                    "    {name}: Expected {expected}, received \"{value}\""
                ));
                None
            }
        }
    }

    /// For a value with a default only outside production: a production run has
    /// to say it.
    fn dev_default<T>(&mut self, name: &str, value: Option<T>, dev_default: T) -> T {
        match value {
            Some(value) => value,
            None => {
                // A value that is set but failed to parse is already invalid.
                if self.is_production && self.raw(name).is_none() {
                    self.missing.push(format!(
                        "    {name}: {}",
                        if (self.lookup)(name).is_some() {
                            "Disallowed empty string"
                        } else {
                            "Missing value"
                        }
                    ));
                }
                dev_default
            }
        }
    }

    fn string(&self, name: &str) -> Option<String> {
        self.raw(name)
    }

    fn u32(&mut self, name: &str) -> Option<u32> {
        self.parsed(name, |value| {
            javascript_integer(value)
                .and_then(|number| u32::try_from(number).ok())
                .ok_or_else(|| "a non-negative integer".to_string())
        })
    }

    fn f64(&mut self, name: &str) -> Option<f64> {
        self.parsed(name, |value| {
            value
                .parse::<f64>()
                .ok()
                .filter(|number| number.is_finite())
                .ok_or_else(|| "a number".to_string())
        })
    }

    fn port(&mut self, name: &str) -> Option<u16> {
        self.parsed(name, |value| {
            javascript_integer(value)
                .and_then(|number| u16::try_from(number).ok())
                .filter(|port| *port > 0)
                .ok_or_else(|| "a port between 1 and 65535".to_string())
        })
    }

    fn bool(&mut self, name: &str) -> Option<bool> {
        self.parsed(name, |value| {
            parse_bool(value).ok_or_else(|| "true or false".to_string())
        })
    }

    fn one_of(&mut self, name: &str, allowed: &'static [&'static str]) -> Option<&'static str> {
        self.parsed(name, |value| {
            allowed
                .iter()
                .find(|candidate| **candidate == value)
                .copied()
                .ok_or_else(|| format!("one of {}", allowed.join(", ")))
        })
    }

    fn finish<T>(self, value: T) -> Result<T, String> {
        if self.invalid.is_empty() && self.missing.is_empty() {
            return Ok(value);
        }
        let line = "========================================";
        let mut output = vec![line.to_string()];
        if !self.invalid.is_empty() {
            output.push("❌ Invalid environment variables:".to_string());
            output.extend(self.invalid);
        }
        if !self.missing.is_empty() {
            output.push("💨 Missing environment variables:".to_string());
            output.extend(self.missing);
        }
        output.push(line.to_string());
        Err(output.join("\n"))
    }
}

/// An integer as JavaScript's `+value` reads one: surrounding whitespace,
/// `5000.0` and `1e3` included.
fn javascript_integer(value: &str) -> Option<i64> {
    let number = value.trim().parse::<f64>().ok()?;
    (number.is_finite() && number.fract() == 0.0 && number.abs() < 2f64.powi(53))
        .then_some(number as i64)
}

pub fn parse_bool(value: &str) -> Option<bool> {
    match value {
        "true" | "t" | "1" => Some(true),
        "false" | "f" | "0" => Some(false),
        _ => None,
    }
}

/// Whether a process draws the progress display: `ENVIO_TUI` when it says,
/// else only when someone is watching. Piped output, CI, coding agents
/// (`CLAUDECODE`) and terminals without ANSI support (`TERM=dumb`) aren't.
pub fn shows_progress_display(
    explicit: Option<bool>,
    lookup: &dyn Fn(&str) -> Option<String>,
    terminal: &Terminal,
) -> bool {
    explicit.unwrap_or_else(|| {
        terminal.stdout_is_tty
            && lookup("CLAUDECODE").is_none()
            && lookup("CI").is_none()
            && lookup("TERM").as_deref() != Some("dumb")
    })
}

fn aggregate_entities(value: &str) -> Result<Vec<String>, String> {
    const EXPECTED: &str = "an array of entities in the JSON format";
    if let Ok(entities) = serde_json::from_str::<Vec<String>>(value) {
        return Ok(entities);
    }
    // Hosted Service can't put commas in an environment variable, so it joins
    // the entities with `&` instead.
    let entities: Vec<String> = value.split('&').map(str::to_string).collect();
    if entities.len() < 2 {
        return Err(EXPECTED.to_string());
    }
    Ok(entities)
}

impl IndexerEnv {
    pub fn read(
        lookup: &dyn Fn(&str) -> Option<String>,
        terminal: Terminal,
    ) -> Result<Self, String> {
        let mut env = Reader {
            lookup,
            is_production: lookup("NODE_ENV").as_deref() == Some("production"),
            invalid: vec![],
            missing: vec![],
        };

        let max_partition_size = env.u32("MAX_PARTITION_SIZE").unwrap_or(5_000);

        let metrics_port = env.port("METRICS_PORT").unwrap_or(9898);
        let server_port = env.port("ENVIO_INDEXER_PORT").unwrap_or(metrics_port);

        let tui = shows_progress_display(env.bool("ENVIO_TUI"), lookup, &terminal);

        let hyper_sync = HyperSyncEnv {
            client_timeout_millis: env
                .u32("ENVIO_HYPERSYNC_CLIENT_TIMEOUT_MILLIS")
                .unwrap_or(120_000),
            serialization_format: env
                .one_of(
                    "ENVIO_HYPERSYNC_CLIENT_SERIALIZATION_FORMAT",
                    &["Json", "CapnProto"],
                )
                .unwrap_or("CapnProto"),
            enable_query_caching: env
                .bool("ENVIO_HYPERSYNC_CLIENT_ENABLE_QUERY_CACHING")
                .unwrap_or(true),
            log_filter: {
                let level = env
                    .one_of("ENVIO_HYPERSYNC_LOG_LEVEL", &HYPERSYNC_LOG_LEVELS)
                    .unwrap_or("info");
                env.string("RUST_LOG").unwrap_or_else(|| level.to_string())
            },
        };

        let rpc_sync = RpcSyncEnv {
            initial_block_interval: env.u32("ENVIO_RPC_INITIAL_BLOCK_INTERVAL"),
            backoff_multiplicative: env.f64("ENVIO_RPC_BACKOFF_MULTIPLICATIVE"),
            acceleration_additive: env.u32("ENVIO_RPC_ACCELERATION_ADDITIVE"),
            interval_ceiling: env.u32("ENVIO_RPC_INTERVAL_CEILING"),
        };

        let logger = LoggerEnv {
            // Checked by the Rust logger, which knows what each value means.
            strategy: env
                .string("LOG_STRATEGY")
                .unwrap_or_else(|| "console-pretty".to_string()),
            file: env
                .string("LOG_FILE")
                .unwrap_or_else(|| "logs/envio.log".to_string()),
            level: env.one_of("LOG_LEVEL", &LOG_LEVELS),
            file_level: env.one_of("FILE_LOG_LEVEL", &LOG_LEVELS).unwrap_or("trace"),
        };

        let db = {
            let host = env.string("ENVIO_PG_HOST");
            let port = env.port("ENVIO_PG_PORT");
            let user = env.string("ENVIO_PG_USER");
            let database = env.string("ENVIO_PG_DATABASE");
            let ssl_mode = env.parsed("ENVIO_PG_SSL_MODE", |value| match parse_bool(value) {
                Some(true) => Ok("true"),
                Some(false) => Ok("false"),
                None => SSL_MODES
                    .iter()
                    .find(|mode| **mode == value)
                    .copied()
                    .ok_or_else(|| format!("true, false or one of {}", SSL_MODES.join(", "))),
            });
            DbEnv {
                host: env.dev_default("ENVIO_PG_HOST", host, "localhost".to_string()),
                port: env.dev_default("ENVIO_PG_PORT", port, 5433),
                user: env.dev_default("ENVIO_PG_USER", user, "postgres".to_string()),
                password: env
                    .string("ENVIO_PG_PASSWORD")
                    .or_else(|| env.string("ENVIO_POSTGRES_PASSWORD"))
                    .unwrap_or_else(|| "testing".to_string()),
                database: env.dev_default("ENVIO_PG_DATABASE", database, "envio-dev".to_string()),
                schema: env
                    .string("ENVIO_PG_SCHEMA")
                    .or_else(|| env.string("ENVIO_PG_PUBLIC_SCHEMA"))
                    .unwrap_or_else(|| "public".to_string()),
                ssl_mode: env.dev_default("ENVIO_PG_SSL_MODE", ssl_mode, "false"),
                max_connections: env.u32("ENVIO_PG_MAX_CONNECTIONS").unwrap_or(2),
            }
        };

        let click_house = ClickHouseEnv {
            host: env.string("ENVIO_CLICKHOUSE_HOST"),
            database: env.string("ENVIO_CLICKHOUSE_DATABASE"),
            username: env.string("ENVIO_CLICKHOUSE_USERNAME"),
            password: lookup("ENVIO_CLICKHOUSE_PASSWORD"),
            replicated: env
                .parsed("ENVIO_CLICKHOUSE_REPLICATED", |value| match value {
                    "true" => Ok(true),
                    _ => Err("\"true\", the only accepted value".to_string()),
                })
                .unwrap_or(false),
            database_engine: env.string("ENVIO_CLICKHOUSE_DATABASE_ENGINE"),
        };

        let hasura = {
            // An indexer run without Hasura credentials, like the Hosted
            // Service's, turns it off.
            let enabled = env.bool("ENVIO_HASURA").unwrap_or(true);
            let response_limit = match env.u32("ENVIO_HASURA_RESPONSE_LIMIT") {
                Some(limit) => Some(limit),
                None => env.u32("HASURA_RESPONSE_LIMIT"),
            };
            let graphql_endpoint = env.string("HASURA_GRAPHQL_ENDPOINT");
            let graphql_endpoint = env.dev_default(
                "HASURA_GRAPHQL_ENDPOINT",
                graphql_endpoint,
                "http://localhost:8080/v1/metadata".to_string(),
            );
            let role = env.string("HASURA_GRAPHQL_ROLE");
            let secret = env.string("HASURA_GRAPHQL_ADMIN_SECRET");
            HasuraEnv {
                enabled,
                response_limit,
                url: graphql_endpoint
                    .strip_suffix("/v1/metadata")
                    .unwrap_or(&graphql_endpoint)
                    .to_string(),
                graphql_endpoint,
                role: env.dev_default("HASURA_GRAPHQL_ROLE", role, "admin".to_string()),
                secret: env.dev_default(
                    "HASURA_GRAPHQL_ADMIN_SECRET",
                    secret,
                    "testing".to_string(),
                ),
                aggregate_entities: env
                    .parsed("ENVIO_HASURA_PUBLIC_AGGREGATE", aggregate_entities)
                    .unwrap_or_default(),
            }
        };

        let throttle = {
            let chain_metadata = env.u32("ENVIO_THROTTLE_CHAIN_METADATA_INTERVAL_MILLIS");
            let prune_stale_data = env.u32("ENVIO_THROTTLE_PRUNE_STALE_DATA_INTERVAL_MILLIS");
            ThrottleEnv {
                chain_metadata_interval_millis: env.dev_default(
                    "ENVIO_THROTTLE_CHAIN_METADATA_INTERVAL_MILLIS",
                    chain_metadata,
                    500,
                ),
                prune_stale_data_interval_millis: env.dev_default(
                    "ENVIO_THROTTLE_PRUNE_STALE_DATA_INTERVAL_MILLIS",
                    prune_stale_data,
                    30_000,
                ),
            }
        };

        let value = IndexerEnv {
            indexing_max_buffer_size: env.u32("ENVIO_INDEXING_MAX_BUFFER_SIZE").unwrap_or(300_000),
            max_partition_size,
            client_filter_address_threshold: env.u32("ENVIO_CLIENT_FILTER_ADDRESS_THRESHOLD"),
            in_memory_objects_target: env.u32("ENVIO_IN_MEMORY_OBJECTS_TARGET").unwrap_or(100_000),
            server_port,
            tui,
            envio_app_url: env
                .string("ENVIO_APP")
                .unwrap_or_else(|| "https://envio.dev".to_string()),
            envio_api_token: env.string("ENVIO_API_TOKEN"),
            hyper_sync,
            rpc_sync,
            logger,
            db,
            click_house,
            hasura,
            throttle,
            internal_worker: env.string("ENVIO_INTERNAL_WORKER"),
        };
        env.finish(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn read(vars: &[(&str, &str)]) -> Result<IndexerEnv, String> {
        let vars: HashMap<String, String> = vars
            .iter()
            .map(|(name, value)| (name.to_string(), value.to_string()))
            .collect();
        IndexerEnv::read(
            &|name| vars.get(name).cloned(),
            Terminal {
                stdout_is_tty: true,
            },
        )
    }

    #[test]
    fn an_empty_environment_reads_as_the_dev_defaults() {
        assert_eq!(
            read(&[]).unwrap(),
            IndexerEnv {
                indexing_max_buffer_size: 300_000,
                max_partition_size: 5_000,
                client_filter_address_threshold: None,
                in_memory_objects_target: 100_000,
                server_port: 9898,
                tui: true,
                envio_app_url: "https://envio.dev".to_string(),
                envio_api_token: None,
                hyper_sync: HyperSyncEnv {
                    client_timeout_millis: 120_000,
                    serialization_format: "CapnProto",
                    enable_query_caching: true,
                    log_filter: "info".to_string(),
                },
                rpc_sync: RpcSyncEnv::default(),
                logger: LoggerEnv {
                    strategy: "console-pretty".to_string(),
                    file: "logs/envio.log".to_string(),
                    level: None,
                    file_level: "trace",
                },
                db: DbEnv {
                    host: "localhost".to_string(),
                    port: 5433,
                    user: "postgres".to_string(),
                    password: "testing".to_string(),
                    database: "envio-dev".to_string(),
                    schema: "public".to_string(),
                    ssl_mode: "false",
                    max_connections: 2,
                },
                click_house: ClickHouseEnv::default(),
                hasura: HasuraEnv {
                    enabled: true,
                    response_limit: None,
                    graphql_endpoint: "http://localhost:8080/v1/metadata".to_string(),
                    url: "http://localhost:8080".to_string(),
                    role: "admin".to_string(),
                    secret: "testing".to_string(),
                    aggregate_entities: vec![],
                },
                throttle: ThrottleEnv {
                    chain_metadata_interval_millis: 500,
                    prune_stale_data_interval_millis: 30_000,
                },
                internal_worker: None,
            }
        );
    }

    #[test]
    fn a_variable_falls_back_to_its_older_name() {
        let env = read(&[
            ("METRICS_PORT", "9000"),
            ("ENVIO_POSTGRES_PASSWORD", "old"),
            ("ENVIO_PG_PUBLIC_SCHEMA", "indexer"),
            ("HASURA_RESPONSE_LIMIT", "50"),
            ("ENVIO_PG_PASSWORD", ""),
        ])
        .unwrap();
        assert_eq!(
            (
                env.server_port,
                env.db.password,
                env.db.schema,
                env.hasura.response_limit
            ),
            (9000, "old".to_string(), "indexer".to_string(), Some(50))
        );
    }

    // The values the JavaScript reader this replaced took: a number is anything
    // `+value` reads as an integer, and the SSL mode's booleans take the same
    // spellings as every other boolean.
    #[test]
    fn a_number_reads_as_javascript_reads_it() {
        let env = read(&[
            ("MAX_PARTITION_SIZE", " 2000 "),
            ("ENVIO_IN_MEMORY_OBJECTS_TARGET", "5000.0"),
            ("ENVIO_INDEXING_MAX_BUFFER_SIZE", "1e3"),
            ("ENVIO_PG_PORT", "5432.0"),
            ("ENVIO_PG_SSL_MODE", "1"),
        ])
        .unwrap();
        assert_eq!(
            (
                env.max_partition_size,
                env.in_memory_objects_target,
                env.indexing_max_buffer_size,
                env.db.port,
                env.db.ssl_mode,
            ),
            (2000, 5000, 1000, 5432, "true")
        );
    }

    #[test]
    fn a_fraction_or_a_negative_is_not_a_count() {
        assert_eq!(
            read(&[
                ("MAX_PARTITION_SIZE", "1.5"),
                ("ENVIO_PG_MAX_CONNECTIONS", "-1")
            ])
            .unwrap_err(),
            "========================================
❌ Invalid environment variables:
    MAX_PARTITION_SIZE: Expected a non-negative integer, received \"1.5\"
    ENVIO_PG_MAX_CONNECTIONS: Expected a non-negative integer, received \"-1\"
========================================"
        );
    }

    #[test]
    fn a_production_run_names_every_setting_it_has_no_default_for() {
        assert_eq!(
            read(&[
                ("NODE_ENV", "production"),
                ("ENVIO_PG_HOST", ""),
                ("ENVIO_PG_PORT", "70000"),
                ("ENVIO_TUI", "maybe"),
            ])
            .unwrap_err(),
            "========================================
❌ Invalid environment variables:
    ENVIO_TUI: Expected true or false, received \"maybe\"
    ENVIO_PG_PORT: Expected a port between 1 and 65535, received \"70000\"
💨 Missing environment variables:
    ENVIO_PG_HOST: Disallowed empty string
    ENVIO_PG_USER: Missing value
    ENVIO_PG_DATABASE: Missing value
    ENVIO_PG_SSL_MODE: Missing value
    HASURA_GRAPHQL_ENDPOINT: Missing value
    HASURA_GRAPHQL_ROLE: Missing value
    HASURA_GRAPHQL_ADMIN_SECRET: Missing value
    ENVIO_THROTTLE_CHAIN_METADATA_INTERVAL_MILLIS: Missing value
    ENVIO_THROTTLE_PRUNE_STALE_DATA_INTERVAL_MILLIS: Missing value
========================================"
        );
    }

    #[test]
    fn the_progress_display_follows_the_terminal_unless_asked() {
        let tui = |vars: &[(&str, &str)], stdout_is_tty| {
            let vars: HashMap<String, String> = vars
                .iter()
                .map(|(name, value)| (name.to_string(), value.to_string()))
                .collect();
            IndexerEnv::read(&|name| vars.get(name).cloned(), Terminal { stdout_is_tty })
                .unwrap()
                .tui
        };
        assert_eq!(
            [
                tui(&[], true),
                tui(&[], false),
                tui(&[("CI", "1")], true),
                tui(&[("TERM", "dumb")], true),
                tui(&[("CI", "1"), ("ENVIO_TUI", "true")], false),
                tui(&[("ENVIO_TUI", "0")], true),
            ],
            [true, false, false, false, true, false]
        );
    }

    #[test]
    fn hasura_aggregate_entities_take_json_or_an_ampersand_list() {
        assert_eq!(
            [
                aggregate_entities(r#"["A","B"]"#),
                aggregate_entities("A&B"),
                aggregate_entities("A"),
            ],
            [
                Ok(vec!["A".to_string(), "B".to_string()]),
                Ok(vec!["A".to_string(), "B".to_string()]),
                Err("an array of entities in the JSON format".to_string()),
            ]
        );
    }
}
