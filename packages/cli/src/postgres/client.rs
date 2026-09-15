//! The connection pool and the statements run against it.

use anyhow::{anyhow, bail, Context, Result};
use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use openssl::ssl::{SslConnector, SslMethod, SslVerifyMode};
use postgres_openssl::MakeTlsConnector;
use tokio_postgres::config::SslMode;
use tokio_postgres::types::{ToSql, Type};
use tokio_postgres::{Config, NoTls, Row};

use super::param::Param;

/// What `ENVIO_PG_SSL_MODE` asks for.
///
/// These are the driver's spellings, not libpq's, and two of them do not mean
/// what the libpq names suggest: `require`, `allow` and `prefer` all encrypt
/// without checking the server's certificate, and only `prefer` falls back to a
/// plaintext connection when the server refuses TLS. Reproduced as they were
/// rather than corrected, so an existing deployment keeps connecting.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SslSetting {
    /// `false` — never TLS.
    Disable,
    /// `true` or `verify-full` — TLS, certificate and hostname checked.
    Verify,
    /// `require` or `allow` — TLS, nothing checked.
    NoVerify,
    /// `prefer` — TLS if the server offers it, plaintext if not, nothing checked.
    PreferNoVerify,
}

impl SslSetting {
    pub fn parse(value: &str) -> Result<Self> {
        Ok(match value {
            "false" => SslSetting::Disable,
            "true" | "verify-full" => SslSetting::Verify,
            "require" | "allow" => SslSetting::NoVerify,
            "prefer" => SslSetting::PreferNoVerify,
            other => bail!(
                "`{other}` is not an SSL mode. Use one of false, true, require, allow, prefer, \
                 verify-full."
            ),
        })
    }

    fn ssl_mode(self) -> SslMode {
        match self {
            SslSetting::Disable => SslMode::Disable,
            SslSetting::Verify | SslSetting::NoVerify => SslMode::Require,
            SslSetting::PreferNoVerify => SslMode::Prefer,
        }
    }

    fn verifies(self) -> bool {
        self == SslSetting::Verify
    }
}

pub struct PgConnectionOptions {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub database: String,
    pub ssl: SslSetting,
    pub max_connections: usize,
    pub application_name: Option<String>,
}

/// One column of a result, as the statement describes it.
pub struct Column {
    pub name: String,
    pub ty: Type,
}

pub struct PgClient {
    pool: Pool,
}

fn build_config(options: &PgConnectionOptions) -> Config {
    let mut config = Config::new();
    config
        .host(&options.host)
        .port(options.port)
        .user(&options.user)
        .password(&options.password)
        .dbname(&options.database)
        .ssl_mode(options.ssl.ssl_mode());
    if let Some(application_name) = &options.application_name {
        config.application_name(application_name);
    }
    config
}

impl PgClient {
    pub fn connect(options: PgConnectionOptions) -> Result<Self> {
        let config = build_config(&options);
        // Every connection is handed back to the pool ready to reuse, so a
        // session setting left behind by one caller would leak into the next.
        let manager_config = ManagerConfig {
            recycling_method: RecyclingMethod::Fast,
        };
        let manager = if options.ssl == SslSetting::Disable {
            Manager::from_config(config, NoTls, manager_config)
        } else {
            let mut builder = SslConnector::builder(SslMethod::tls())
                .context("Failed preparing the TLS connector")?;
            if !options.ssl.verifies() {
                builder.set_verify(SslVerifyMode::NONE);
            }
            let mut connector = MakeTlsConnector::new(builder.build());
            if !options.ssl.verifies() {
                // Without this the hostname is still checked even though the
                // certificate is not, which is not what not-verifying means.
                connector.set_callback(|config, _| {
                    config.set_verify_hostname(false);
                    Ok(())
                });
            }
            Manager::from_config(config, connector, manager_config)
        };

        let pool = Pool::builder(manager)
            .max_size(options.max_connections.max(1))
            .build()
            .context("Failed building the Postgres connection pool")?;

        Ok(Self { pool })
    }

    async fn client(&self) -> Result<deadpool_postgres::Object> {
        self.pool
            .get()
            .await
            .map_err(|error| anyhow!("Failed taking a Postgres connection from the pool: {error}"))
    }

    /// Runs one or more statements with no parameters, discarding any rows.
    ///
    /// This is the path for DDL and for the multi-statement text the
    /// initialization builds; `simple_query` is what allows more than one
    /// statement in a single round trip.
    pub async fn batch(&self, sql: &str) -> Result<()> {
        self.client().await?.batch_execute(sql).await?;
        Ok(())
    }

    pub async fn execute(&self, sql: &str, params: &[Param]) -> Result<u64> {
        let client = self.client().await?;
        let params = params.iter().map(|p| p as &(dyn ToSql + Sync));
        Ok(client.execute_raw(sql, params).await?)
    }

    /// The rows, and what the statement says its columns are.
    ///
    /// The types come from the prepared statement rather than from a row, so a
    /// result with no rows in it still describes its shape and the caller lays
    /// out the same columns either way.
    pub async fn query(&self, sql: &str, params: &[Param]) -> Result<(Vec<Row>, Vec<Column>)> {
        let client = self.client().await?;
        let statement = client.prepare(sql).await?;
        let columns = statement
            .columns()
            .iter()
            .map(|column| Column {
                name: column.name().to_string(),
                ty: column.type_().clone(),
            })
            .collect();
        let params: Vec<&(dyn ToSql + Sync)> =
            params.iter().map(|p| p as &(dyn ToSql + Sync)).collect();
        Ok((client.query(&statement, &params).await?, columns))
    }

    pub async fn close(&self) {
        self.pool.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_ssl_spelling_maps_to_what_the_driver_did() {
        let parsed = ["false", "true", "verify-full", "require", "allow", "prefer"]
            .map(|value| SslSetting::parse(value).unwrap());
        assert_eq!(
            parsed,
            [
                SslSetting::Disable,
                SslSetting::Verify,
                SslSetting::Verify,
                SslSetting::NoVerify,
                SslSetting::NoVerify,
                SslSetting::PreferNoVerify,
            ]
        );
    }

    /// Only `prefer` may end up on a plaintext connection; the rest either
    /// refuse TLS outright or require it.
    #[test]
    fn only_prefer_falls_back_to_plaintext() {
        assert_eq!(
            (
                SslSetting::Disable.ssl_mode(),
                SslSetting::Verify.ssl_mode(),
                SslSetting::NoVerify.ssl_mode(),
                SslSetting::PreferNoVerify.ssl_mode(),
            ),
            (
                SslMode::Disable,
                SslMode::Require,
                SslMode::Require,
                SslMode::Prefer,
            )
        );
    }

    /// The three that encrypt without checking anything are the ones the driver
    /// this replaces gave `rejectUnauthorized: false`.
    #[test]
    fn only_the_verifying_spellings_check_the_certificate() {
        assert_eq!(
            (
                SslSetting::Disable.verifies(),
                SslSetting::Verify.verifies(),
                SslSetting::NoVerify.verifies(),
                SslSetting::PreferNoVerify.verifies(),
            ),
            (false, true, false, false)
        );
    }

    #[test]
    fn an_unknown_ssl_mode_says_what_is_accepted() {
        assert_eq!(
            SslSetting::parse("verify-ca").unwrap_err().to_string(),
            "`verify-ca` is not an SSL mode. Use one of false, true, require, allow, prefer, \
             verify-full."
        );
    }
}
