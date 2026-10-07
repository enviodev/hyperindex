//! The connection pool and the statements run against it.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use bytes::Bytes;
use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use futures_util::{pin_mut, SinkExt, StreamExt};
use openssl::ssl::{SslConnector, SslMethod, SslVerifyMode};
use postgres_openssl::MakeTlsConnector;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_postgres::config::SslMode;
use tokio_postgres::types::{ToSql, Type};
use tokio_postgres::{Config, NoTls, Row, Statement};

use super::error::Aborted;
use super::param::Param;

/// What `ENVIO_PG_SSL_MODE` asks for.
///
/// Not libpq's meanings: `require`, `allow` and `prefer` all encrypt without
/// checking the server's certificate, and only `prefer` falls back to a
/// plaintext connection when the server refuses TLS. Existing deployments rely
/// on this.
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
    /// How long opening a connection may take, handshake included.
    pub connect_timeout: std::time::Duration,
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
/// Cloning one shares that connection. A batch write issues its statements at
/// once, so they are pipelined on it rather than serialised.
#[derive(Clone)]
pub struct Transaction {
    connection: Arc<Pinned>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Stage {
    Open,
    /// `COMMIT` or `ROLLBACK` has been sent. Anything issued after it would run
    /// on the same connection outside the transaction, and commit on its own.
    Ending,
    /// The server answered the `COMMIT` or `ROLLBACK`.
    Ended,
}

/// The connection a transaction runs on, and how far the transaction has got.
///
/// Statements hold the stage shared, so they still pipeline; ending it takes
/// it exclusively, which waits for the statements already in flight and turns
/// away the rest.
///
/// Only a transaction seen to end hands its connection back. Any other way of
/// letting go leaves it possibly still inside the transaction, and the next
/// caller to be handed it would run inside a stranger's: a failed commit, a
/// clone still holding it when the ending statement failed, or a transaction
/// dropped with nothing sent. Those detach it from the pool instead. Deciding
/// when the last holder lets go, rather than when `finish` runs, is what covers
/// the clones.
struct Pinned {
    object: Option<deadpool_postgres::Object>,
    stage: tokio::sync::RwLock<Stage>,
    /// A statement in the transaction failed. The server then answers a
    /// `COMMIT` by rolling back, without an error.
    failed: AtomicBool,
}

impl Pinned {
    fn client(&self) -> &deadpool_postgres::Object {
        self.object
            .as_ref()
            .expect("the connection is only taken out on drop")
    }

    async fn open(&self) -> Result<tokio::sync::RwLockReadGuard<'_, Stage>> {
        let stage = self.stage.read().await;
        if *stage != Stage::Open {
            return Err(Aborted("The transaction has already ended").into());
        }
        Ok(stage)
    }

    fn note<T>(&self, outcome: Result<T>) -> Result<T> {
        if outcome.is_err() {
            self.failed.store(true, Ordering::Relaxed);
        }
        outcome
    }
}

impl Drop for Pinned {
    fn drop(&mut self) {
        if *self.stage.get_mut() != Stage::Ended {
            if let Some(object) = self.object.take() {
                let _ = deadpool_postgres::Object::take(object);
            }
        }
    }
}

impl Transaction {
    fn on(connection: deadpool_postgres::Object) -> Self {
        Self {
            connection: Arc::new(Pinned {
                object: Some(connection),
                stage: tokio::sync::RwLock::new(Stage::Open),
                failed: AtomicBool::new(false),
            }),
        }
    }

    pub async fn execute(&self, sql: &str, params: &[Param]) -> Result<u64> {
        let _open = self.connection.open().await?;
        self.connection
            .note(execute_on(self.connection.client(), sql, params).await)
    }

    pub async fn query(&self, sql: &str, params: &[Param]) -> Result<(Vec<Row>, Vec<Column>)> {
        let _open = self.connection.open().await?;
        self.connection
            .note(query_on(self.connection.client(), sql, params).await)
    }

    pub async fn batch(&self, sql: &str) -> Result<()> {
        let _open = self.connection.open().await?;
        let outcome = self.connection.client().batch_execute(sql).await;
        self.connection.note(outcome.map_err(Into::into))
    }

    pub async fn commit(self) -> Result<()> {
        self.finish(true).await
    }

    /// Undoes everything the transaction did. Safe to send after a statement
    /// has already failed: the server has aborted the transaction by then and
    /// is waiting for exactly this.
    pub async fn rollback(self) -> Result<()> {
        self.finish(false).await
    }

    /// Read only once the stage is held exclusively: a statement still in
    /// flight records its failure before letting go of it.
    async fn finish(self, commit: bool) -> Result<()> {
        let mut stage = self.connection.stage.write().await;
        if *stage != Stage::Open {
            return Err(Aborted("The transaction has already ended").into());
        }
        *stage = Stage::Ending;
        let failed = self.connection.failed.load(Ordering::Relaxed);
        let statement = if commit && !failed {
            "COMMIT"
        } else {
            "ROLLBACK"
        };
        self.connection.client().batch_execute(statement).await?;
        *stage = Stage::Ended;
        if commit && failed {
            return Err(
                Aborted("The transaction was rolled back: a statement in it failed").into(),
            );
        }
        Ok(())
    }
}

/// How many statement shapes a connection keeps prepared. The indexer has a
/// handful that repeat forever and one that does not: an insert binding a cell
/// at a time spells out a row per placeholder, so a batch whose last chunk is
/// short is a statement of its own, and there are as many of those as there are
/// chunk lengths. Past this the cache is dropped rather than grown without
/// bound; the shapes that repeat are prepared again on their next use.
pub(super) const MAX_PREPARED_STATEMENTS: usize = 256;

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

        // Only opening a connection is bounded. Waiting for a free slot when
        // every connection is busy is the pool doing its job, and how long that
        // takes is how long the statements ahead take.
        let pool = Pool::builder(manager)
            .max_size(options.max_connections.max(1))
            .runtime(deadpool_postgres::Runtime::Tokio1)
            .create_timeout(Some(options.connect_timeout))
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
        Ok(Transaction::on(connection))
    }

    /// Runs a `COPY ... TO STDOUT` and writes what it produces to `path`.
    ///
    /// The rows never pass through JavaScript: the server streams them and this
    /// writes them out as they arrive, so a cache of any size costs one buffer
    /// rather than its own length in memory.
    ///
    /// They go to a file of their own beside `path`, which replaces it only once
    /// the copy has finished: a copy the server gives up on part way would
    /// otherwise leave a file holding its first rows, and the next start would
    /// load that as the cache. The name is unique per call, so two dumps of the
    /// same table cannot write into each other's.
    pub async fn copy_out(&self, sql: &str, path: &str) -> Result<()> {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let partial = format!(
            "{path}.{}.{}.partial",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        let outcome = self.copy_out_into(sql, &partial).await;
        let outcome = match outcome {
            Ok(()) => tokio::fs::rename(&partial, path)
                .await
                .with_context(|| format!("Failed replacing {path}")),
            Err(error) => Err(error),
        };
        if outcome.is_err() {
            let _ = tokio::fs::remove_file(&partial).await;
        }
        outcome
    }

    async fn copy_out_into(&self, sql: &str, path: &str) -> Result<()> {
        let client = self.client().await?;
        let mut file = tokio::fs::File::create(path)
            .await
            .with_context(|| format!("Failed creating {path}"))?;
        let stream = client.copy_out(sql).await?;
        pin_mut!(stream);
        while let Some(chunk) = stream.next().await {
            file.write_all(&chunk?).await?;
        }
        file.flush().await?;
        Ok(())
    }

    /// Feeds `path` to a `COPY ... FROM STDIN`, returning the rows it took.
    pub async fn copy_in(&self, sql: &str, path: &str) -> Result<u64> {
        let client = self.client().await?;
        let mut file = tokio::fs::File::open(path)
            .await
            .with_context(|| format!("Failed opening {path}"))?;
        let sink = client.copy_in(sql).await?;
        pin_mut!(sink);
        let mut buffer = vec![0u8; 64 * 1024];
        loop {
            let read = file.read(&mut buffer).await?;
            if read == 0 {
                break;
            }
            sink.send(Bytes::copy_from_slice(&buffer[..read])).await?;
        }
        Ok(sink.finish().await?)
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

    pub fn close(&self) {
        self.pool.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_ssl_spelling_maps_to_a_setting() {
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

    /// A server that takes the connection and never answers it — a firewall
    /// swallowing the handshake, a proxy with nothing behind it — has to end
    /// in an error rather than an indexer waiting on it forever.
    #[tokio::test]
    async fn a_connection_that_never_opens_is_given_up_on() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let held = tokio::spawn(async move {
            let mut accepted = Vec::new();
            loop {
                if let Ok((socket, _)) = listener.accept().await {
                    accepted.push(socket);
                }
            }
        });

        let client = PgClient::connect(PgConnectionOptions {
            host: "127.0.0.1".to_string(),
            port,
            user: "postgres".to_string(),
            password: "unused".to_string(),
            database: "unused".to_string(),
            ssl: SslSetting::Disable,
            max_connections: 1,
            application_name: None,
            connect_timeout: std::time::Duration::from_millis(300),
        })
        .unwrap();
        let outcome = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            client.query("SELECT 1", &[]),
        )
        .await;
        held.abort();

        let reported = match outcome {
            Err(_) => "still waiting after five seconds".to_string(),
            Ok(Ok(_)) => "answered".to_string(),
            Ok(Err(error)) => super::super::error::message_of(&error),
        };
        assert_eq!(
            reported,
            "Failed taking a Postgres connection from the pool: Timeout occurred while creating a new object"
        );
    }
}
