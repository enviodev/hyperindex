//! The connection pool and the statements run against it.

use std::sync::Arc;

use anyhow::{bail, Context, Result};
use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use openssl::ssl::{SslConnector, SslMethod, SslVerifyMode};
use postgres_openssl::MakeTlsConnector;
use tokio_postgres::config::SslMode;
use tokio_postgres::types::{ToSql, Type};
use tokio_postgres::{Config, NoTls, Row, Statement};

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

/// A transaction, pinned to the connection it was opened on.
///
/// Cloning one shares that connection. Statements issued on it at the same time
/// are pipelined rather than serialised — which is what the driver being
/// replaced did for the concurrent statements a batch write issues — so the
/// connection is behind an `Arc` and never a lock.
#[derive(Clone)]
pub struct Transaction {
    connection: Arc<deadpool_postgres::Object>,
}

impl Transaction {
    pub async fn execute(&self, sql: &str, params: &[Param]) -> Result<u64> {
        execute_on(&self.connection, sql, params).await
    }

    pub async fn query(&self, sql: &str, params: &[Param]) -> Result<(Vec<Row>, Vec<Column>)> {
        query_on(&self.connection, sql, params).await
    }

    pub async fn batch(&self, sql: &str) -> Result<()> {
        self.connection.batch_execute(sql).await?;
        Ok(())
    }

    pub async fn commit(self) -> Result<()> {
        self.finish("COMMIT").await
    }

    /// Undoes everything the transaction did. Safe to send after a statement
    /// has already failed: the server has aborted the transaction by then and
    /// is waiting for exactly this.
    pub async fn rollback(self) -> Result<()> {
        self.finish("ROLLBACK").await
    }

    /// Ends the transaction and lets the connection go.
    ///
    /// If ending it fails, the transaction may still be open on that connection
    /// and nothing downstream would know: the next caller to be handed it would
    /// run inside a stranger's transaction. So the connection is detached
    /// instead of returned — one lost from the pool against statements landing
    /// somewhere they were never meant to.
    async fn finish(self, statement: &str) -> Result<()> {
        let outcome = self.connection.batch_execute(statement).await;
        if outcome.is_err() {
            if let Ok(connection) = Arc::try_unwrap(self.connection) {
                let _ = deadpool_postgres::Object::take(connection);
            }
        }
        outcome?;
        Ok(())
    }
}

/// How many statement shapes a connection keeps prepared. The indexer has a
/// handful that repeat forever and one that does not: an insert binding a cell
/// at a time spells out a row per placeholder, so a batch whose last chunk is
/// short is a statement of its own, and there are as many of those as there are
/// chunk lengths. Past this the cache is dropped rather than grown without
/// bound; the shapes that repeat are prepared again on their next use.
const MAX_PREPARED_STATEMENTS: usize = 256;

/// The statement, prepared once per connection rather than once per call.
///
/// A statement given as text is parsed, described and planned by the server
/// every time it is sent — a round trip and a plan for a statement the
/// connection has already run a thousand times.
async fn prepared(client: &deadpool_postgres::Object, sql: &str) -> Result<Statement> {
    if client.statement_cache.size() > MAX_PREPARED_STATEMENTS {
        client.statement_cache.clear();
    }
    Ok(client.prepare_cached(sql).await?)
}

async fn execute_on(
    client: &deadpool_postgres::Object,
    sql: &str,
    params: &[Param],
) -> Result<u64> {
    let statement = prepared(client, sql).await?;
    let params = params.iter().map(|param| param as &(dyn ToSql + Sync));
    Ok(client.execute_raw(&statement, params).await?)
}

/// The rows, and what the statement says its columns are.
///
/// The types come from the prepared statement rather than from a row, so a
/// result with no rows in it still describes its shape and the caller lays out
/// the same columns either way.
async fn query_on(
    client: &deadpool_postgres::Object,
    sql: &str,
    params: &[Param],
) -> Result<(Vec<Row>, Vec<Column>)> {
    let statement = prepared(client, sql).await?;
    let columns = statement
        .columns()
        .iter()
        .map(|column| Column {
            name: column.name().to_string(),
            ty: column.type_().clone(),
        })
        .collect();
    let params: Vec<&(dyn ToSql + Sync)> = params
        .iter()
        .map(|param| param as &(dyn ToSql + Sync))
        .collect();
    Ok((client.query(&statement, &params).await?, columns))
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
        // A returned connection is checked for being closed and nothing more.
        // Nothing here leaves session state behind to reset — the one thing
        // that would, an unfinished transaction, is kept out of the pool by
        // `Transaction::finish` rather than cleaned up after.
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
        // Built from the error rather than its text: a connection that would
        // not open says why in its source chain — a name that does not
        // resolve, a certificate the trust store does not vouch for — and
        // formatting it away leaves the caller with "error performing TLS
        // handshake" and nothing to act on.
        self.pool
            .get()
            .await
            .map_err(anyhow::Error::new)
            .context("Failed taking a Postgres connection from the pool")
    }

    /// Runs one or more statements with no parameters, discarding any rows.
    ///
    /// This is the path for DDL and for the multi-statement text the
    /// initialization builds; a simple query is what allows more than one
    /// statement in a single round trip.
    pub async fn batch(&self, sql: &str) -> Result<()> {
        self.client().await?.batch_execute(sql).await?;
        Ok(())
    }

    pub async fn execute(&self, sql: &str, params: &[Param]) -> Result<u64> {
        let client = self.client().await?;
        execute_on(&client, sql, params).await
    }

    pub async fn query(&self, sql: &str, params: &[Param]) -> Result<(Vec<Row>, Vec<Column>)> {
        let client = self.client().await?;
        query_on(&client, sql, params).await
    }

    /// Opens a transaction on a connection of its own and keeps it there.
    ///
    /// `BEGIN` is sent as a statement rather than taken from the driver's own
    /// transaction type, which borrows the connection it runs on and so could
    /// not be held in a map across calls. What matters is the same either way:
    /// every statement until the commit runs on this one connection.
    pub async fn begin(&self) -> Result<Transaction> {
        let connection = self.client().await?;
        connection.batch_execute("BEGIN").await?;
        Ok(Transaction {
            connection: Arc::new(connection),
        })
    }

    /// Drops every connection's prepared statements.
    ///
    /// A prepared statement holds the plan's idea of the types it returns, and
    /// a reset gives the schema's enums new ones. Executing a statement
    /// prepared before it is then refused with "cached plan must not change
    /// result type", mid-statement, aborting whatever transaction the caller
    /// was in — so the caches are dropped rather than recovered from.
    pub fn forget_prepared(&self) {
        self.pool.manager().statement_caches.clear();
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
