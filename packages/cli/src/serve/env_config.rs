//! Environment configuration for `envio serve`, mirroring the exact
//! semantics of packages/envio/src/Env.res: process env wins over the
//! project-root `.env` file, `devFallback` defaults apply only when
//! NODE_ENV != "production", plain fallbacks always apply.
//!
//! TLS (`ENVIO_PG_SSL_MODE`) follows libpq's sslmode values:
//! - `disable` (or `false`, or unset): plaintext, no TLS.
//! - `allow`/`prefer`: TLS if the server supports it, falling back to
//!   plaintext otherwise; the server certificate is NOT verified.
//! - `require`: TLS mandatory, but the server certificate is NOT verified
//!   (libpq's semantic — works with self-signed certificates).
//! - `verify-ca`/`verify-full` (or `true`, or any other value, for backward
//!   compatibility): TLS mandatory and the server certificate is verified
//!   against the platform's trusted root CA store. Note `verify-ca` is
//!   served as `verify-full` (chain AND hostname verification): rustls's
//!   verifier doesn't offer chain-only verification, so `verify-ca` is
//!   strictly stricter here than libpq's.

use crate::project_paths::ParsedProjectPaths;
use crate::utils::dotenv::{self, EnvMap};
use anyhow::{anyhow, Context};
use std::time::Duration;

pub struct ServeEnv {
    pub pg_host: String,
    pub pg_port: u16,
    pub pg_user: String,
    pub pg_password: String,
    pub pg_database: String,
    pub pg_schema: String,
    pub pg_ssl: PgSslMode,
    pub admin_secret: String,
    pub response_limit: Option<u32>,
    pub aggregate_entities: Vec<String>,
    /// ENVIO_SERVE_QUERY_TIMEOUT_MS. Bounds every query both server-side
    /// (statement_timeout) and client-side (tokio timeout with slack, so a
    /// frozen/unreachable Postgres can't hang requests forever). 0 disables.
    pub query_timeout_ms: Option<u64>,
    /// ENVIO_SERVE_POOL_WAIT_TIMEOUT_MS. Bounds how long a request waits for
    /// a free pooled connection before erroring instead of queuing without
    /// limit. 0 disables.
    pub pool_wait_timeout_ms: Option<u64>,
    /// ENVIO_SERVE_CONNECT_TIMEOUT_MS. Bounds TCP connect + handshake when
    /// the pool opens a new connection. 0 disables.
    pub connect_timeout_ms: Option<u64>,
    /// ENVIO_SERVE_POOL_MAX_SIZE. Defaults to min(cpu_count * 2, 10).
    pub pool_max_size: usize,
    /// ENVIO_SERVE_STARTUP_RETRY_BUDGET_MS. Total wall-clock budget for
    /// retrying pool creation/introspection with exponential backoff when
    /// Postgres isn't reachable yet at boot. 0 disables retries.
    pub startup_retry_budget_ms: u64,
    /// ENVIO_SERVE_HEALTHZ_TIMEOUT_MS. Bounds the /healthz DB probe.
    pub healthz_timeout_ms: u64,
    /// ENVIO_SERVE_WS_PING_INTERVAL_MS. How often idle WebSocket connections
    /// are pinged; a connection that sends no pong/traffic within 2x this
    /// interval is treated as dead and closed. Hasura's seconds-based
    /// HASURA_GRAPHQL_WEBSOCKET_KEEPALIVE is accepted as a fallback.
    pub ws_ping_interval_ms: u64,
    /// ENVIO_SERVE_WS_CONNECTION_INIT_TIMEOUT_MS. Maximum time between the
    /// WebSocket upgrade and a valid connection_init message. Hasura's
    /// seconds-based HASURA_GRAPHQL_WEBSOCKET_CONNECTION_INIT_TIMEOUT is
    /// accepted as a fallback.
    pub ws_connection_init_timeout_ms: u64,
    /// ENVIO_SERVE_WS_MAX_CONNECTIONS. Hard process-wide cap on upgraded
    /// WebSocket connections, including connections still waiting for init.
    pub ws_max_connections: usize,
    /// ENVIO_SERVE_WS_MAX_OPERATIONS_PER_CONNECTION. Active GraphQL
    /// operations allowed on one socket.
    pub ws_max_operations_per_connection: usize,
    /// ENVIO_SERVE_WS_MAX_OPERATIONS. Process-wide active WebSocket operation
    /// cap. This bounds work even when an attacker spreads it across sockets.
    pub ws_max_operations: usize,
    /// ENVIO_SERVE_WS_MAX_CONCURRENT_POLLS. Maximum subscription polls that
    /// may use the shared Postgres pool at once.
    pub ws_max_concurrent_polls: usize,
    /// ENVIO_SERVE_WS_POLL_INTERVAL_MS. Refetch interval for live and
    /// streaming subscriptions. Also accepts Hasura's live-query interval
    /// setting as a compatibility fallback.
    pub ws_poll_interval_ms: u64,
    /// ENVIO_SERVE_WS_MAX_MESSAGE_BYTES. Applied explicitly as both the axum
    /// WebSocket message and frame limit.
    pub ws_max_message_bytes: usize,
}

/// deadpool_postgres::Config defaults to `cpu_core_count * 2` with no upper
/// bound; on a many-core host that lets that many full-response-buffered
/// queries (see exec/sql.rs) run concurrently, each holding its own copy of
/// the response in memory. Capping it keeps the default reasonable while
/// still scaling down on small hosts (e.g. a 2-core box gets 4, not 10).
const DEFAULT_POOL_MAX_SIZE_CAP: usize = 10;

fn default_pool_max_size() -> usize {
    let cpus = std::thread::available_parallelism().map_or(1, |n| n.get());
    std::cmp::min(cpus * 2, DEFAULT_POOL_MAX_SIZE_CAP)
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
        self.resolved_dev_fallback(self.var(name), name, fallback)
    }

    /// `var_dev_fallback` for a value already resolved from several env-var
    /// aliases: outside production the fallback applies, but a missing value
    /// in production is a hard error rather than a silent insecure default.
    fn resolved_dev_fallback(
        &self,
        resolved: Option<String>,
        name: &str,
        fallback: &str,
    ) -> anyhow::Result<String> {
        match resolved {
            Some(v) => Ok(v),
            None if !self.is_production => Ok(fallback.to_string()),
            None => Err(anyhow!(
                "Missing required environment variable {name} (required when NODE_ENV=production)"
            )),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PgSslMode {
    Disable,
    /// libpq `allow`/`prefer`: TLS if offered, plaintext fallback, no
    /// certificate verification.
    Prefer,
    /// libpq `require`: TLS mandatory, no certificate verification.
    Require,
    /// libpq `verify-full` (also serving `verify-ca`, strictly — see the
    /// module doc): TLS mandatory, chain + hostname verification against
    /// the platform root CA store.
    VerifyFull,
}

impl PgSslMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            PgSslMode::Disable => "disable",
            PgSslMode::Prefer => "prefer",
            PgSslMode::Require => "require",
            PgSslMode::VerifyFull => "verify-full",
        }
    }
}

/// Unrecognized non-`false` values fall through to `VerifyFull`, preserving
/// the historical "any non-false value enables verified TLS" behavior for
/// configs written before the libpq mode names were supported.
fn parse_pg_ssl(raw: Option<&str>) -> PgSslMode {
    match raw {
        None | Some("false") | Some("disable") => PgSslMode::Disable,
        Some("allow") | Some("prefer") => PgSslMode::Prefer,
        Some("require") => PgSslMode::Require,
        Some(_) => PgSslMode::VerifyFull,
    }
}

/// Millisecond-duration env vars share one convention: unset uses the
/// default, an explicit "0" disables the bound entirely.
fn parse_timeout_ms(
    raw: Option<String>,
    name: &str,
    default: Option<u64>,
) -> anyhow::Result<Option<u64>> {
    match raw {
        None => Ok(default),
        Some(v) => match v.parse::<u64>() {
            Ok(0) => Ok(None),
            Ok(n) => Ok(Some(n)),
            Err(_) => Err(anyhow!(
                "Invalid {name}: expected milliseconds as an integer"
            )),
        },
    }
}

/// For bounds where 0 has no meaningful interpretation (a 0ms WS ping
/// interval would dead-check-close every connection instantly; a 0ms healthz
/// probe always fails): unset uses the default, 0 is a config error.
fn parse_positive_ms(raw: Option<String>, name: &str, default: u64) -> anyhow::Result<u64> {
    match raw {
        None => Ok(default),
        Some(v) => match v.parse::<u64>() {
            Ok(0) => Err(anyhow!(
                "Invalid {name}: must be greater than 0 milliseconds"
            )),
            Ok(n) => Ok(n),
            Err(_) => Err(anyhow!(
                "Invalid {name}: expected milliseconds as an integer"
            )),
        },
    }
}

fn parse_startup_retry_budget_ms(raw: Option<String>) -> anyhow::Result<u64> {
    Ok(parse_timeout_ms(raw, "ENVIO_SERVE_STARTUP_RETRY_BUDGET_MS", Some(60_000))?.unwrap_or(0))
}

fn parse_positive_usize(raw: Option<String>, name: &str, default: usize) -> anyhow::Result<usize> {
    match raw {
        None => Ok(default),
        Some(v) => v
            .parse::<usize>()
            .ok()
            .filter(|n| *n > 0)
            .ok_or_else(|| anyhow!("Invalid {name}: must be a positive integer")),
    }
}

fn parse_ms_with_seconds_fallback(
    milliseconds: Option<String>,
    seconds: Option<String>,
    milliseconds_name: &str,
    seconds_name: &str,
    default_ms: u64,
) -> anyhow::Result<u64> {
    if milliseconds.is_some() {
        return parse_positive_ms(milliseconds, milliseconds_name, default_ms);
    }
    let Some(value) = seconds else {
        return Ok(default_ms);
    };
    let seconds = value
        .parse::<u64>()
        .map_err(|_| anyhow!("Invalid {seconds_name}: expected seconds as an integer"))?;
    if seconds == 0 {
        return Err(anyhow!(
            "Invalid {seconds_name}: must be greater than 0 seconds"
        ));
    }
    seconds
        .checked_mul(1_000)
        .ok_or_else(|| anyhow!("Invalid {seconds_name}: duration is too large"))
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

        let pool_max_size = parse_positive_usize(
            r.var("ENVIO_SERVE_POOL_MAX_SIZE"),
            "ENVIO_SERVE_POOL_MAX_SIZE",
            default_pool_max_size(),
        )?;
        let ws_max_operations_per_connection = parse_positive_usize(
            r.var("ENVIO_SERVE_WS_MAX_OPERATIONS_PER_CONNECTION"),
            "ENVIO_SERVE_WS_MAX_OPERATIONS_PER_CONNECTION",
            50,
        )?;
        let ws_max_operations = parse_positive_usize(
            r.var("ENVIO_SERVE_WS_MAX_OPERATIONS"),
            "ENVIO_SERVE_WS_MAX_OPERATIONS",
            1_000,
        )?;
        if ws_max_operations_per_connection > ws_max_operations {
            return Err(anyhow!(
                "ENVIO_SERVE_WS_MAX_OPERATIONS_PER_CONNECTION cannot exceed ENVIO_SERVE_WS_MAX_OPERATIONS"
            ));
        }
        let ws_max_concurrent_polls = parse_positive_usize(
            r.var("ENVIO_SERVE_WS_MAX_CONCURRENT_POLLS"),
            "ENVIO_SERVE_WS_MAX_CONCURRENT_POLLS",
            pool_max_size.saturating_sub(2).max(1),
        )?;
        if pool_max_size > 1 && ws_max_concurrent_polls >= pool_max_size {
            return Err(anyhow!(
                "ENVIO_SERVE_WS_MAX_CONCURRENT_POLLS must be smaller than ENVIO_SERVE_POOL_MAX_SIZE so HTTP retains database capacity"
            ));
        }

        Ok(ServeEnv {
            pg_host: r.var_dev_fallback("ENVIO_PG_HOST", "localhost")?,
            pg_port,
            pg_user: r.var_dev_fallback("ENVIO_PG_USER", "postgres")?,
            pg_password: r.resolved_dev_fallback(
                r.var("ENVIO_PG_PASSWORD")
                    .or_else(|| r.var("ENVIO_POSTGRES_PASSWORD")),
                "ENVIO_PG_PASSWORD",
                "testing",
            )?,
            pg_database: r.var_dev_fallback("ENVIO_PG_DATABASE", "envio-dev")?,
            pg_schema: r
                .var("ENVIO_PG_SCHEMA")
                .or_else(|| r.var("ENVIO_PG_PUBLIC_SCHEMA"))
                .unwrap_or_else(|| "public".to_string()),
            pg_ssl: parse_pg_ssl(r.var("ENVIO_PG_SSL_MODE").as_deref()),
            admin_secret: r.var_dev_fallback("HASURA_GRAPHQL_ADMIN_SECRET", "testing")?,
            response_limit,
            aggregate_entities: parse_aggregate_entities(
                r.var("ENVIO_HASURA_PUBLIC_AGGREGATE").as_deref(),
            )?,
            query_timeout_ms: parse_timeout_ms(
                r.var("ENVIO_SERVE_QUERY_TIMEOUT_MS"),
                "ENVIO_SERVE_QUERY_TIMEOUT_MS",
                Some(120_000),
            )?,
            pool_wait_timeout_ms: parse_timeout_ms(
                r.var("ENVIO_SERVE_POOL_WAIT_TIMEOUT_MS"),
                "ENVIO_SERVE_POOL_WAIT_TIMEOUT_MS",
                Some(15_000),
            )?,
            connect_timeout_ms: parse_timeout_ms(
                r.var("ENVIO_SERVE_CONNECT_TIMEOUT_MS"),
                "ENVIO_SERVE_CONNECT_TIMEOUT_MS",
                Some(10_000),
            )?,
            pool_max_size,
            startup_retry_budget_ms: parse_startup_retry_budget_ms(
                r.var("ENVIO_SERVE_STARTUP_RETRY_BUDGET_MS"),
            )?,
            healthz_timeout_ms: parse_positive_ms(
                r.var("ENVIO_SERVE_HEALTHZ_TIMEOUT_MS"),
                "ENVIO_SERVE_HEALTHZ_TIMEOUT_MS",
                2_000,
            )?,
            ws_ping_interval_ms: parse_ms_with_seconds_fallback(
                r.var("ENVIO_SERVE_WS_PING_INTERVAL_MS"),
                r.var("HASURA_GRAPHQL_WEBSOCKET_KEEPALIVE"),
                "ENVIO_SERVE_WS_PING_INTERVAL_MS",
                "HASURA_GRAPHQL_WEBSOCKET_KEEPALIVE",
                10_000,
            )?,
            ws_connection_init_timeout_ms: parse_ms_with_seconds_fallback(
                r.var("ENVIO_SERVE_WS_CONNECTION_INIT_TIMEOUT_MS"),
                r.var("HASURA_GRAPHQL_WEBSOCKET_CONNECTION_INIT_TIMEOUT"),
                "ENVIO_SERVE_WS_CONNECTION_INIT_TIMEOUT_MS",
                "HASURA_GRAPHQL_WEBSOCKET_CONNECTION_INIT_TIMEOUT",
                3_000,
            )?,
            ws_max_connections: parse_positive_usize(
                r.var("ENVIO_SERVE_WS_MAX_CONNECTIONS"),
                "ENVIO_SERVE_WS_MAX_CONNECTIONS",
                1_000,
            )?,
            ws_max_operations_per_connection,
            ws_max_operations,
            ws_max_concurrent_polls,
            ws_poll_interval_ms: parse_positive_ms(
                r.var("ENVIO_SERVE_WS_POLL_INTERVAL_MS")
                    .or_else(|| r.var("HASURA_GRAPHQL_LIVE_QUERIES_MULTIPLEXED_REFETCH_INTERVAL")),
                "ENVIO_SERVE_WS_POLL_INTERVAL_MS",
                1_000,
            )?,
            ws_max_message_bytes: parse_positive_usize(
                r.var("ENVIO_SERVE_WS_MAX_MESSAGE_BYTES"),
                "ENVIO_SERVE_WS_MAX_MESSAGE_BYTES",
                1024 * 1024,
            )?,
        })
    }

    /// The config.yaml `schema` field default and resolution live in
    /// project_schema.rs; this reader is only env vars.
    ///
    /// TLS behavior per `pg_ssl` mode is described on the module doc and
    /// `PgSslMode`.
    pub fn make_pg_pool(&self) -> anyhow::Result<deadpool_postgres::Pool> {
        let mut cfg = deadpool_postgres::Config::new();
        cfg.host = Some(self.pg_host.clone());
        cfg.port = Some(self.pg_port);
        cfg.user = Some(self.pg_user.clone());
        cfg.password = Some(self.pg_password.clone());
        cfg.dbname = Some(self.pg_database.clone());
        // Serialization parity depends on ISO datestyle and UTC output for
        // timestamptz values; pin them per connection. statement_timeout
        // makes Postgres itself cancel over-budget queries (SQLSTATE 57014)
        // — the client-side wrap in exec::sql only fires when the server
        // can't respond at all (frozen/unreachable).
        let mut options = "-c TimeZone=UTC -c DateStyle=ISO".to_string();
        if let Some(ms) = self.query_timeout_ms {
            options.push_str(&format!(" -c statement_timeout={ms}"));
        }
        cfg.options = Some(options);
        cfg.connect_timeout = self.connect_timeout_ms.map(Duration::from_millis);
        // Unbounded pool waits turn a wedged Postgres into a permanently
        // hung server: once every connection is checked out by a stuck
        // query, all later requests queue forever. A wait timeout converts
        // that into a clean per-request error instead.
        let mut pool_cfg = deadpool_postgres::PoolConfig::new(self.pool_max_size);
        pool_cfg.timeouts.wait = self.pool_wait_timeout_ms.map(Duration::from_millis);
        pool_cfg.timeouts.create = self.connect_timeout_ms.map(Duration::from_millis);
        cfg.pool = Some(pool_cfg);

        match self.pg_ssl {
            PgSslMode::Disable => {
                let pool = cfg
                    .create_pool(
                        Some(deadpool_postgres::Runtime::Tokio1),
                        tokio_postgres::NoTls,
                    )
                    .context("Failed creating Postgres connection pool")?;
                Ok(pool)
            }
            PgSslMode::Prefer => {
                cfg.ssl_mode = Some(deadpool_postgres::SslMode::Prefer);
                make_tls_pool(&cfg, no_verify_tls_config())
            }
            PgSslMode::Require => {
                cfg.ssl_mode = Some(deadpool_postgres::SslMode::Require);
                make_tls_pool(&cfg, no_verify_tls_config())
            }
            PgSslMode::VerifyFull => {
                cfg.ssl_mode = Some(deadpool_postgres::SslMode::Require);
                make_tls_pool(&cfg, verified_tls_config(native_root_certs()?))
            }
        }
    }
}

/// Loads the platform's trusted root CA store (e.g. `/etc/ssl/certs` on
/// Linux, the Keychain on macOS, the Windows certificate store) for
/// verifying the Postgres server certificate.
fn native_root_certs() -> anyhow::Result<rustls::RootCertStore> {
    let result = rustls_native_certs::load_native_certs();
    let mut roots = rustls::RootCertStore::empty();
    let (added, _skipped) = roots.add_parsable_certificates(result.certs);
    if added == 0 {
        return Err(anyhow!(
            "Failed loading the system's trusted root CA store for Postgres TLS: {:?}",
            result.errors
        ));
    }
    Ok(roots)
}

// rustls 0.23 needs a process-wide crypto provider installed before any
// ClientConfig can be built. install_default() errors if one is already
// installed (e.g. by another TLS client sharing this process) -- that's
// fine, we only need *a* provider present, not necessarily this call's.
fn ensure_crypto_provider() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

fn verified_tls_config(roots: rustls::RootCertStore) -> rustls::ClientConfig {
    ensure_crypto_provider();
    rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth()
}

/// Encryption-without-authentication, for the libpq `allow`/`prefer`/
/// `require` modes: any server certificate (self-signed, expired, wrong
/// hostname) is accepted, but the TLS record layer -- including handshake
/// signature checks binding the session to the presented key -- still runs
/// normally. Never used for `verify-ca`/`verify-full`.
fn no_verify_tls_config() -> rustls::ClientConfig {
    ensure_crypto_provider();
    let provider = rustls::crypto::CryptoProvider::get_default()
        .expect("crypto provider installed above")
        .clone();
    rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(std::sync::Arc::new(AcceptAnyServerCert { provider }))
        .with_no_client_auth()
}

#[derive(Debug)]
struct AcceptAnyServerCert {
    provider: std::sync::Arc<rustls::crypto::CryptoProvider>,
}

impl rustls::client::danger::ServerCertVerifier for AcceptAnyServerCert {
    fn verify_server_cert(
        &self,
        _end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    // Handshake signatures are still verified against the presented
    // certificate's key: skipping *identity* verification must not also
    // skip proof that the peer holds the key it presented.
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

/// Split out from `make_pg_pool` so tests can exercise a real TLS handshake
/// against a throwaway CA instead of the machine's real trust store.
fn make_tls_pool(
    cfg: &deadpool_postgres::Config,
    tls_config: rustls::ClientConfig,
) -> anyhow::Result<deadpool_postgres::Pool> {
    let tls = tokio_postgres_rustls::MakeRustlsConnect::new(tls_config);
    cfg.create_pool(Some(deadpool_postgres::Runtime::Tokio1), tls)
        .context("Failed creating Postgres TLS connection pool")
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::BufReader;
    use std::process::Command;

    #[test]
    fn parse_pg_ssl_env_var() {
        use PgSslMode::*;
        assert_eq!(
            [
                parse_pg_ssl(None),
                parse_pg_ssl(Some("false")),
                parse_pg_ssl(Some("disable")),
                parse_pg_ssl(Some("allow")),
                parse_pg_ssl(Some("prefer")),
                parse_pg_ssl(Some("require")),
                parse_pg_ssl(Some("verify-ca")),
                parse_pg_ssl(Some("verify-full")),
                parse_pg_ssl(Some("true")),
                parse_pg_ssl(Some("")),
                parse_pg_ssl(Some("bogus")),
            ],
            [
                Disable, Disable, Disable, Prefer, Prefer, Require, VerifyFull, VerifyFull,
                VerifyFull, VerifyFull, VerifyFull,
            ],
        );
    }

    #[test]
    fn credentials_require_explicit_value_in_production() {
        let dev = EnvReader {
            dotenv: None,
            is_production: false,
        };
        let prod = EnvReader {
            dotenv: None,
            is_production: true,
        };
        // Outside production a missing password falls back; in production it
        // is a hard error rather than a silent "testing" default.
        assert_eq!(
            dev.resolved_dev_fallback(None, "ENVIO_PG_PASSWORD", "testing")
                .unwrap(),
            "testing"
        );
        assert_eq!(
            prod.resolved_dev_fallback(Some("secret".to_string()), "ENVIO_PG_PASSWORD", "testing")
                .unwrap(),
            "secret"
        );
        assert_eq!(
            prod.resolved_dev_fallback(None, "ENVIO_PG_PASSWORD", "testing")
                .unwrap_err()
                .to_string(),
            "Missing required environment variable ENVIO_PG_PASSWORD (required when NODE_ENV=production)"
        );
    }

    #[test]
    fn parse_positive_ms_rejects_zero() {
        assert_eq!(
            [
                parse_positive_ms(None, "X", 7).ok(),
                parse_positive_ms(Some("42".to_string()), "X", 7).ok(),
                parse_positive_ms(Some("0".to_string()), "X", 7).ok(),
                parse_positive_ms(Some("nope".to_string()), "X", 7).ok(),
            ],
            [Some(7), Some(42), None, None],
        );
        assert_eq!(
            parse_positive_ms(Some("0".to_string()), "ENVIO_SERVE_WS_PING_INTERVAL_MS", 7)
                .unwrap_err()
                .to_string(),
            "Invalid ENVIO_SERVE_WS_PING_INTERVAL_MS: must be greater than 0 milliseconds"
        );
    }

    #[test]
    fn startup_retry_budget_accepts_zero_as_fail_fast() {
        assert_eq!(
            [
                parse_startup_retry_budget_ms(None).ok(),
                parse_startup_retry_budget_ms(Some("42".to_string())).ok(),
                parse_startup_retry_budget_ms(Some("0".to_string())).ok(),
                parse_startup_retry_budget_ms(Some("nope".to_string())).ok(),
            ],
            [Some(60_000), Some(42), Some(0), None],
        );
    }

    #[test]
    fn parse_positive_usize_rejects_zero_and_invalid_values() {
        assert_eq!(
            [
                parse_positive_usize(None, "X", 7).ok(),
                parse_positive_usize(Some("42".to_string()), "X", 7).ok(),
                parse_positive_usize(Some("0".to_string()), "X", 7).ok(),
                parse_positive_usize(Some("-1".to_string()), "X", 7).ok(),
                parse_positive_usize(Some("nope".to_string()), "X", 7).ok(),
            ],
            [Some(7), Some(42), None, None, None],
        );
    }

    #[test]
    fn hasura_websocket_seconds_fallback_converts_to_milliseconds() {
        assert_eq!(
            parse_ms_with_seconds_fallback(
                None,
                Some("3".to_string()),
                "ENVIO_MS",
                "HASURA_SECONDS",
                7,
            )
            .unwrap(),
            3_000
        );
        assert_eq!(
            parse_ms_with_seconds_fallback(
                Some("25".to_string()),
                Some("3".to_string()),
                "ENVIO_MS",
                "HASURA_SECONDS",
                7,
            )
            .unwrap(),
            25,
            "Envio's millisecond setting has precedence"
        );
        assert!(parse_ms_with_seconds_fallback(
            None,
            Some("0".to_string()),
            "ENVIO_MS",
            "HASURA_SECONDS",
            7,
        )
        .is_err());
    }

    #[test]
    fn loads_system_root_ca_store() {
        // Exercises the exact cert-loading call `make_pg_pool` makes for
        // `pg_ssl`, without a live handshake: every dev machine and CI
        // runner has *some* trusted root CAs installed, so this should
        // always succeed.
        let roots = native_root_certs().expect("system CA store should load");
        assert!(!roots.is_empty());
    }

    /// Full round-trip against a real, throwaway, SSL-enabled Postgres
    /// container: a client trusting the test CA completes the handshake and
    /// queries the server, while the same server is rejected when verified
    /// against the *real* system CA store -- proving TLS verification is
    /// actually enforced rather than silently skipped.
    ///
    /// Spins up its own `postgres:16` container on a Docker-assigned port
    /// (never the shared dev instance on 5433) and always tears it down.
    /// Skips (doesn't fail) if Docker isn't available in this environment.
    #[test]
    fn tls_connection_verifies_server_certificate() {
        if super::super::test_support::skip_without_docker() {
            return;
        }

        let container = TestTlsPostgres::start();

        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let mut cfg = deadpool_postgres::Config::new();
            cfg.host = Some("localhost".to_string());
            cfg.port = Some(container.port);
            cfg.user = Some("postgres".to_string());
            cfg.password = Some("testing".to_string());
            cfg.dbname = Some("envio-dev".to_string());
            cfg.ssl_mode = Some(deadpool_postgres::SslMode::Require);

            let trusted_roots = load_pem_roots(&container.ca_cert_pem);
            let pool =
                make_tls_pool(&cfg, verified_tls_config(trusted_roots)).expect("pool construction");
            // pg_isready accepting TCP doesn't guarantee the TLS listener
            // is immediately ready to complete a handshake under load; a
            // couple of retries absorbs that startup race without masking
            // a real connectivity failure.
            let mut client = None;
            for attempt in 0..5 {
                match pool.get().await {
                    Ok(c) => {
                        client = Some(c);
                        break;
                    }
                    Err(_) if attempt < 4 => {
                        std::thread::sleep(std::time::Duration::from_millis(500))
                    }
                    Err(e) => {
                        panic!("connecting with the issuing test CA trusted should succeed: {e}")
                    }
                }
            }
            let client = client.unwrap();
            let row = client.query_one("select 1", &[]).await.expect("query");
            assert_eq!(row.get::<_, i32>(0), 1);

            let system_roots = native_root_certs().expect("system CA store should load");
            let pool =
                make_tls_pool(&cfg, verified_tls_config(system_roots)).expect("pool construction");
            let connect_result = pool.get().await;
            assert!(
                connect_result.is_err(),
                "connecting to a self-signed cert absent from the system trust store must fail"
            );

            // `require` semantics: TLS is used but the untrusted certificate
            // is accepted, so the same server that verify-full just rejected
            // is reachable.
            let pool = make_tls_pool(&cfg, no_verify_tls_config()).expect("pool construction");
            let client = pool
                .get()
                .await
                .expect("sslmode=require must accept a self-signed certificate");
            let row = client.query_one("select 1", &[]).await.expect("query");
            assert_eq!(row.get::<_, i32>(0), 1);
        });
    }

    fn load_pem_roots(pem: &str) -> rustls::RootCertStore {
        let mut reader = BufReader::new(pem.as_bytes());
        let der = rustls_pemfile::certs(&mut reader).expect("parse test CA PEM");
        let mut roots = rustls::RootCertStore::empty();
        let (added, _skipped) = roots.add_parsable_certificates(
            der.into_iter().map(rustls::pki_types::CertificateDer::from),
        );
        assert_eq!(added, 1);
        roots
    }

    /// A throwaway `postgres:16` container with SSL enabled behind a
    /// self-signed test CA, torn down on drop (including on test panic).
    struct TestTlsPostgres {
        name: String,
        volume: String,
        port: u16,
        ca_cert_pem: String,
    }

    impl TestTlsPostgres {
        fn start() -> Self {
            let id = format!(
                "{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            );
            let name = format!("envio-serve-tls-test-{id}");
            let volume = format!("envio-serve-tls-test-certs-{id}");

            let dir = tempdir::TempDir::new("envio-serve-tls-test").unwrap();
            let (ca_cert_pem, server_crt, server_key) = generate_self_signed_cert(dir.path());

            run(Command::new("docker").args(["volume", "create", &volume]));
            run(Command::new("docker").args([
                "run",
                "--rm",
                "-v",
                &format!("{volume}:/certs"),
                "-v",
                &format!("{}:/src:ro", dir.path().display()),
                "alpine",
                "sh",
                "-c",
                &format!(
                    "cp /src/{} /src/{} /certs/ && chown 999:999 /certs/{} /certs/{} && chmod 600 /certs/{}",
                    server_crt, server_key, server_crt, server_key, server_key
                ),
            ]));

            run(Command::new("docker").args([
                "run",
                "-d",
                "--name",
                &name,
                "-e",
                "POSTGRES_PASSWORD=testing",
                "-e",
                "POSTGRES_USER=postgres",
                "-e",
                "POSTGRES_DB=envio-dev",
                "-p",
                "127.0.0.1::5432",
                "-v",
                &format!("{volume}:/certs:ro"),
                "postgres:16",
                "-c",
                "ssl=on",
                "-c",
                &format!("ssl_cert_file=/certs/{server_crt}"),
                "-c",
                &format!("ssl_key_file=/certs/{server_key}"),
            ]));

            let port_output = run(Command::new("docker").args(["port", &name, "5432"]));
            let port = String::from_utf8_lossy(&port_output.stdout)
                .lines()
                .next()
                .and_then(|line| line.rsplit(':').next())
                .and_then(|p| p.trim().parse::<u16>().ok())
                .expect("docker port output should contain the mapped host port");

            let container = TestTlsPostgres {
                name: name.clone(),
                volume,
                port,
                ca_cert_pem,
            };

            for _ in 0..30 {
                let ready = Command::new("docker")
                    .args(["exec", &name, "pg_isready", "-U", "postgres"])
                    .output()
                    .map(|o| o.status.success())
                    .unwrap_or(false);
                if ready {
                    return container;
                }
                std::thread::sleep(std::time::Duration::from_millis(500));
            }
            panic!("test Postgres container did not become ready in time");
        }
    }

    impl Drop for TestTlsPostgres {
        fn drop(&mut self) {
            let _ = Command::new("docker")
                .args(["rm", "-f", &self.name])
                .output();
            let _ = Command::new("docker")
                .args(["volume", "rm", "-f", &self.volume])
                .output();
        }
    }

    fn run(cmd: &mut Command) -> std::process::Output {
        let output = cmd.output().expect("failed to run docker");
        assert!(
            output.status.success(),
            "docker command failed: {} {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        output
    }

    /// Generates a throwaway CA + server cert/key pair via the system
    /// `openssl` CLI, returning (ca_cert_pem, server_crt_filename,
    /// server_key_filename) with the cert/key files written into `dir`.
    fn generate_self_signed_cert(dir: &std::path::Path) -> (String, String, String) {
        let openssl = |args: &[&str]| {
            let output = Command::new("openssl")
                .args(args)
                .current_dir(dir)
                .output()
                .expect("failed to run openssl");
            assert!(
                output.status.success(),
                "openssl {:?} failed: {}",
                args,
                String::from_utf8_lossy(&output.stderr)
            );
        };

        openssl(&["genrsa", "-out", "ca.key", "2048"]);
        openssl(&[
            "req",
            "-x509",
            "-new",
            "-nodes",
            "-key",
            "ca.key",
            "-sha256",
            "-days",
            "2",
            "-out",
            "ca.crt",
            "-subj",
            "/CN=envio-serve-test-ca",
        ]);
        openssl(&["genrsa", "-out", "server.key", "2048"]);
        openssl(&[
            "req",
            "-new",
            "-key",
            "server.key",
            "-out",
            "server.csr",
            "-subj",
            "/CN=localhost",
        ]);
        // Plain `openssl x509 -req` with no extensions emits an X.509v1
        // certificate, which rustls-webpki rejects outright
        // (UnsupportedCertVersion) regardless of trust — v3 with a SAN is
        // required both to pass that check and for hostname verification.
        std::fs::write(
            dir.join("server.ext"),
            "basicConstraints=CA:FALSE\nsubjectAltName=DNS:localhost\n",
        )
        .unwrap();
        openssl(&[
            "x509",
            "-req",
            "-in",
            "server.csr",
            "-CA",
            "ca.crt",
            "-CAkey",
            "ca.key",
            "-CAcreateserial",
            "-out",
            "server.crt",
            "-days",
            "2",
            "-sha256",
            "-extfile",
            "server.ext",
        ]);

        let ca_cert_pem = std::fs::read_to_string(dir.join("ca.crt")).unwrap();
        (
            ca_cert_pem,
            "server.crt".to_string(),
            "server.key".to_string(),
        )
    }
}
