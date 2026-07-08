//! Environment configuration for `envio serve`, mirroring the exact
//! semantics of packages/envio/src/Env.res: process env wins over the
//! project-root `.env` file, `devFallback` defaults apply only when
//! NODE_ENV != "production", plain fallbacks always apply.
//!
//! TLS (`ENVIO_PG_SSL_MODE`): when enabled, the Postgres connection is
//! always encrypted and the server certificate is always verified against
//! the platform's trusted root CA store -- equivalent to `sslmode=verify-full`.
//! There is no toggle to accept an unverified/self-signed certificate.
//! Connecting to a Postgres instance behind a private CA (common for
//! self-hosted deployments) isn't supported yet; that would need a new env
//! var (e.g. `ENVIO_PG_SSL_CA_CERT_PATH`) to add a CA to the trust store,
//! not a "trust everything" escape hatch.

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
    pub pg_ssl: bool,
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
    /// Postgres isn't reachable yet at boot. 0 disables retrying (fail
    /// immediately, the pre-existing behavior).
    pub startup_retry_budget_ms: u64,
    /// ENVIO_SERVE_HEALTHZ_TIMEOUT_MS. Bounds the /healthz DB probe.
    pub healthz_timeout_ms: u64,
    /// ENVIO_SERVE_WS_PING_INTERVAL_MS. How often idle WebSocket connections
    /// are pinged; a connection that sends no pong/traffic within 2x this
    /// interval is treated as dead and closed.
    pub ws_ping_interval_ms: u64,
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
        match self.var(name) {
            Some(v) => Ok(v),
            None if !self.is_production => Ok(fallback.to_string()),
            None => Err(anyhow!(
                "Missing required environment variable {name} (required when NODE_ENV=production)"
            )),
        }
    }
}

/// The `postgres` npm package (used by the JS-side indexer for this same
/// env var) treats `require`/`allow`/`prefer` as "encrypt but don't verify
/// the certificate" and reserves verification for `verify-full`. `envio
/// serve` does not replicate that distinction: any non-`false` value here
/// gets the same fully-verified connection described on
/// `ServeEnv::make_pg_pool`.
fn parse_pg_ssl(raw: Option<&str>) -> bool {
    raw.map(|v| v != "false").unwrap_or(false)
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
            pool_max_size: match r.var("ENVIO_SERVE_POOL_MAX_SIZE") {
                None => default_pool_max_size(),
                Some(v) => v
                    .parse::<usize>()
                    .ok()
                    .filter(|n| *n > 0)
                    .ok_or_else(|| anyhow!("Invalid ENVIO_SERVE_POOL_MAX_SIZE"))?,
            },
            startup_retry_budget_ms: match r.var("ENVIO_SERVE_STARTUP_RETRY_BUDGET_MS") {
                None => 60_000,
                Some(v) => v
                    .parse::<u64>()
                    .context("Invalid ENVIO_SERVE_STARTUP_RETRY_BUDGET_MS")?,
            },
            healthz_timeout_ms: match r.var("ENVIO_SERVE_HEALTHZ_TIMEOUT_MS") {
                None => 2_000,
                Some(v) => v
                    .parse::<u64>()
                    .context("Invalid ENVIO_SERVE_HEALTHZ_TIMEOUT_MS")?,
            },
            ws_ping_interval_ms: match r.var("ENVIO_SERVE_WS_PING_INTERVAL_MS") {
                None => 10_000,
                Some(v) => v
                    .parse::<u64>()
                    .context("Invalid ENVIO_SERVE_WS_PING_INTERVAL_MS")?,
            },
        })
    }

    /// The config.yaml `schema` field default and resolution live in
    /// project_schema.rs; this reader is only env vars.
    ///
    /// When `pg_ssl` is set, the connection is encrypted and the server
    /// certificate is verified against the platform's trusted root CA store
    /// (see `native_root_certs`) -- there is no way to opt out of
    /// verification, matching Postgres's `sslmode=verify-full`.
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

        if self.pg_ssl {
            // deadpool_postgres::Config defaults to SslMode::Prefer, which
            // silently falls back to plaintext if the server refuses TLS.
            // Require makes that fallback a hard connection error instead.
            cfg.ssl_mode = Some(deadpool_postgres::SslMode::Require);
            let roots = native_root_certs()?;
            return make_tls_pool(&cfg, roots);
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

/// Builds a pool whose connections are verified against `roots`. Split out
/// from `make_pg_pool` so tests can exercise a real TLS handshake against a
/// throwaway CA instead of the machine's real trust store.
fn make_tls_pool(
    cfg: &deadpool_postgres::Config,
    roots: rustls::RootCertStore,
) -> anyhow::Result<deadpool_postgres::Pool> {
    // rustls 0.23 needs a process-wide crypto provider installed before any
    // ClientConfig can be built. install_default() errors if one is already
    // installed (e.g. by another TLS client sharing this process) -- that's
    // fine, we only need *a* provider present, not necessarily this call's.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let tls_config = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
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
        assert_eq!(
            [
                parse_pg_ssl(None),
                parse_pg_ssl(Some("false")),
                parse_pg_ssl(Some("true")),
                parse_pg_ssl(Some("require")),
                parse_pg_ssl(Some("verify-full")),
                parse_pg_ssl(Some("")),
            ],
            [false, false, true, true, true, true],
        );
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
        if !docker_available() {
            eprintln!(
                "skipping tls_connection_verifies_server_certificate: docker is not available"
            );
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
            let pool = make_tls_pool(&cfg, trusted_roots).expect("pool construction");
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
            let pool = make_tls_pool(&cfg, system_roots).expect("pool construction");
            let connect_result = pool.get().await;
            assert!(
                connect_result.is_err(),
                "connecting to a self-signed cert absent from the system trust store must fail"
            );
        });
    }

    fn docker_available() -> bool {
        Command::new("docker")
            .arg("info")
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
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
