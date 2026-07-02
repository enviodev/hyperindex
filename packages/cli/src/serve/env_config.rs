//! Environment configuration for `envio serve`, mirroring the exact
//! semantics of packages/envio/src/Env.res: process env wins over the
//! project-root `.env` file, `devFallback` defaults apply only when
//! NODE_ENV != "production", plain fallbacks always apply.

use crate::project_paths::ParsedProjectPaths;
use crate::utils::dotenv::{self, EnvMap};
use anyhow::{anyhow, Context};

pub struct ServeEnv {
    pub pg_host: String,
    pub pg_port: u16,
    pub pg_user: String,
    pub pg_password: String,
    pub pg_database: String,
    pub pg_schema: String,
    pub pg_ssl: bool,
    pub admin_secret: String,
    pub response_limit: Option<u32>,
    pub aggregate_entities: Vec<String>,
}

pub struct EnvReader {
    dotenv: Option<EnvMap>,
    is_production: bool,
}

impl EnvReader {
    pub fn var(&self, name: &str) -> Option<String> {
        std::env::var(name)
            .ok()
            .filter(|v| !v.is_empty())
            .or_else(|| {
                self.dotenv
                    .as_ref()
                    .and_then(|m| m.var(name).ok())
                    .filter(|v| !v.is_empty())
            })
    }

    /// Env.res `devFallback`: the default only applies outside production.
    fn var_dev_fallback(&self, name: &str, fallback: &str) -> anyhow::Result<String> {
        match self.var(name) {
            Some(v) => Ok(v),
            None if !self.is_production => Ok(fallback.to_string()),
            None => Err(anyhow!(
                "Missing required environment variable {name} (required when NODE_ENV=production)"
            )),
        }
    }
}

impl ServeEnv {
    pub fn load(project_paths: &ParsedProjectPaths) -> anyhow::Result<ServeEnv> {
        let dotenv = match dotenv::from_path(project_paths.project_root.join(".env")) {
            Ok(map) => Some(map),
            Err(dotenv::Error::Io(_, _)) => None,
            Err(e) => return Err(e).context("Failed reading project .env file"),
        };
        let is_production = std::env::var("NODE_ENV")
            .map(|v| v == "production")
            .unwrap_or(false);
        let r = EnvReader {
            dotenv,
            is_production,
        };

        let pg_port = r
            .var_dev_fallback("ENVIO_PG_PORT", "5433")?
            .parse::<u16>()
            .context("Invalid ENVIO_PG_PORT")?;

        let response_limit = match r
            .var("ENVIO_HASURA_RESPONSE_LIMIT")
            .or_else(|| r.var("HASURA_RESPONSE_LIMIT"))
        {
            Some(v) => Some(
                v.parse::<u32>()
                    .context("Invalid ENVIO_HASURA_RESPONSE_LIMIT")?,
            ),
            None => None,
        };

        Ok(ServeEnv {
            pg_host: r.var_dev_fallback("ENVIO_PG_HOST", "localhost")?,
            pg_port,
            pg_user: r.var_dev_fallback("ENVIO_PG_USER", "postgres")?,
            pg_password: r
                .var("ENVIO_PG_PASSWORD")
                .or_else(|| r.var("ENVIO_POSTGRES_PASSWORD"))
                .unwrap_or_else(|| "testing".to_string()),
            pg_database: r.var_dev_fallback("ENVIO_PG_DATABASE", "envio-dev")?,
            pg_schema: r
                .var("ENVIO_PG_SCHEMA")
                .or_else(|| r.var("ENVIO_PG_PUBLIC_SCHEMA"))
                .unwrap_or_else(|| "public".to_string()),
            pg_ssl: r
                .var("ENVIO_PG_SSL_MODE")
                .map(|v| v != "false")
                .unwrap_or(false),
            admin_secret: r.var_dev_fallback("HASURA_GRAPHQL_ADMIN_SECRET", "testing")?,
            response_limit,
            aggregate_entities: parse_aggregate_entities(
                r.var("ENVIO_HASURA_PUBLIC_AGGREGATE").as_deref(),
            )?,
        })
    }

    /// The config.yaml `schema` field default and resolution live in
    /// project_schema.rs; this reader is only env vars.
    pub fn make_pg_pool(&self) -> anyhow::Result<deadpool_postgres::Pool> {
        let mut cfg = deadpool_postgres::Config::new();
        cfg.host = Some(self.pg_host.clone());
        cfg.port = Some(self.pg_port);
        cfg.user = Some(self.pg_user.clone());
        cfg.password = Some(self.pg_password.clone());
        cfg.dbname = Some(self.pg_database.clone());
        // Serialization parity depends on ISO datestyle and UTC output for
        // timestamptz values; pin them per connection.
        cfg.options = Some("-c TimeZone=UTC -c DateStyle=ISO".to_string());
        if self.pg_ssl {
            return Err(anyhow!(
                "ENVIO_PG_SSL_MODE is not supported by `envio serve` yet"
            ));
        }
        let pool = cfg
            .create_pool(
                Some(deadpool_postgres::Runtime::Tokio1),
                tokio_postgres::NoTls,
            )
            .context("Failed creating Postgres connection pool")?;
        Ok(pool)
    }
}

/// Mirrors Env.res ENVIO_HASURA_PUBLIC_AGGREGATE: a JSON array of entity
/// names, with a legacy `a&b&c` string form.
fn parse_aggregate_entities(raw: Option<&str>) -> anyhow::Result<Vec<String>> {
    let Some(raw) = raw else {
        return Ok(vec![]);
    };
    if let Ok(list) = serde_json::from_str::<Vec<String>>(raw) {
        return Ok(list);
    }
    let parts: Vec<&str> = raw.split('&').collect();
    if parts.len() >= 2 {
        return Ok(parts.into_iter().map(|s| s.to_string()).collect());
    }
    Err(anyhow!(
        "Invalid ENVIO_HASURA_PUBLIC_AGGREGATE: provide an array of entities in the JSON format"
    ))
}
