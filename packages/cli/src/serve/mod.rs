//! `envio serve` — a Hasura-compatible GraphQL server over the indexer's
//! Postgres database.
//!
//! The GraphQL surface mirrors what Hasura exposes after the indexer's
//! `Hasura.res` `trackDatabase` metadata setup: user entity tables plus
//! `raw_events`, `_meta` and `chain_metadata`, a `public` role for
//! unauthenticated requests (row limit + per-table aggregate gating from the
//! same env vars the indexer reads) and an admin role selected by the
//! `X-Hasura-Admin-Secret` header.
//!
//! Column shapes come from live Postgres catalog introspection (like Hasura's
//! own source introspection) so projects created by older envio versions are
//! served faithfully; only the table list and relationships come from
//! `schema.graphql`, resolved through a deliberately minimal `config.yaml`
//! reader that tolerates configs from any envio version >= 2.21.5.

mod env_config;
mod exec;
mod gql;
mod http;
mod model;
mod pg_catalog;
mod project_schema;
mod ws;

use crate::cli_args::clap_definitions::ServeArgs;
use crate::project_paths::ParsedProjectPaths;
use anyhow::Context;
use std::sync::Arc;

#[cfg(test)]
mod robustness_tests;
#[cfg(test)]
mod test_support;

pub struct ServeState {
    pub model: model::ServerModel,
    pub pool: deadpool_postgres::Pool,
    pub admin_secret: String,
    /// Client-side bound on a whole operation's execution (every root
    /// field's pool wait + prepare + query). The server-side
    /// statement_timeout normally fires first; this is the backstop for a
    /// Postgres that stopped responding entirely.
    pub query_timeout: Option<std::time::Duration>,
    /// Bounds the /healthz Postgres probe.
    pub healthz_timeout: std::time::Duration,
    /// How often idle WebSocket connections get a protocol-level ping; a
    /// connection that sends no pong/traffic within 2x this gets closed.
    pub ws_ping_interval: std::time::Duration,
    /// Maximum time an upgraded socket may wait for connection_init.
    pub ws_connection_init_timeout: std::time::Duration,
    pub ws_max_connections: usize,
    pub ws_max_operations_per_connection: usize,
    pub ws_max_operations: usize,
    pub ws_max_concurrent_polls: usize,
    pub ws_poll_interval: std::time::Duration,
    pub ws_max_message_bytes: usize,
}

pub async fn run(args: &ServeArgs, project_paths: &ParsedProjectPaths) -> anyhow::Result<()> {
    init_tracing();
    let env = env_config::ServeEnv::load(project_paths)?;
    tracing::info!(
        pg_host = %env.pg_host,
        pg_port = env.pg_port,
        pg_database = %env.pg_database,
        pg_schema = %env.pg_schema,
        pg_ssl_mode = env.pg_ssl.as_str(),
        pool_max_size = env.pool_max_size,
        ws_ping_interval_ms = env.ws_ping_interval_ms,
        ws_connection_init_timeout_ms = env.ws_connection_init_timeout_ms,
        ws_max_connections = env.ws_max_connections,
        ws_max_operations_per_connection = env.ws_max_operations_per_connection,
        ws_max_operations = env.ws_max_operations,
        ws_max_concurrent_polls = env.ws_max_concurrent_polls,
        ws_poll_interval_ms = env.ws_poll_interval_ms,
        ws_max_message_bytes = env.ws_max_message_bytes,
        healthz_timeout_ms = env.healthz_timeout_ms,
        startup_retry_budget_ms = env.startup_retry_budget_ms,
        query_timeout_ms = env.query_timeout_ms,
        "envio serve starting"
    );

    let project_schema = project_schema::ProjectSchema::load(project_paths, &env)
        .context("Failed loading schema.graphql")?;

    let pool = env
        .make_pg_pool()
        .context("Failed creating Postgres pool")?;

    let catalog = wait_for_pg(&pool, &env.pg_schema, env.startup_retry_budget_ms)
        .await
        .context("Failed introspecting the Postgres schema")?;

    let model = model::ServerModel::build(project_schema, catalog, &env)?;

    let state = Arc::new(ServeState {
        model,
        pool,
        admin_secret: env.admin_secret.clone(),
        // +5s slack so the server-side statement_timeout (clean SQLSTATE
        // 57014 cancellation) wins whenever Postgres is still responsive.
        query_timeout: env
            .query_timeout_ms
            .map(|ms| std::time::Duration::from_millis(ms + 5_000)),
        healthz_timeout: std::time::Duration::from_millis(env.healthz_timeout_ms),
        ws_ping_interval: std::time::Duration::from_millis(env.ws_ping_interval_ms),
        ws_connection_init_timeout: std::time::Duration::from_millis(
            env.ws_connection_init_timeout_ms,
        ),
        ws_max_connections: env.ws_max_connections,
        ws_max_operations_per_connection: env.ws_max_operations_per_connection,
        ws_max_operations: env.ws_max_operations,
        ws_max_concurrent_polls: env.ws_max_concurrent_polls,
        ws_poll_interval: std::time::Duration::from_millis(env.ws_poll_interval_ms),
        ws_max_message_bytes: env.ws_max_message_bytes,
    });

    http::serve(state, &args.host, args.port, shutdown_signal()).await
}

/// Structured logging for the serve path only. The rest of the CLI logs via
/// env_logger; that's initialized lazily on the indexing path
/// (evm_hypersync_source), which `envio serve` never reaches, so the two
/// never contend for the global `log` logger. Filtered by RUST_LOG,
/// defaulting to `info` (per-connection/per-operation events are `debug`).
fn init_tracing() {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
    let _ = tracing_subscriber::fmt().with_env_filter(filter).try_init();
}

/// Longest single backoff sleep between startup retry attempts, regardless
/// of how large the total budget is.
const STARTUP_RETRY_MAX_BACKOFF: std::time::Duration = std::time::Duration::from_secs(5);

/// Retries catalog introspection (the first real Postgres round-trip) with
/// bounded exponential backoff for `budget_ms` total, so a deploy that
/// starts `envio serve` before Postgres is accepting connections doesn't
/// crash-loop -- it just waits. Only retries connectivity failures
/// (connection refused, DNS, timeout); a Postgres that responds with a real
/// error (bad credentials, missing database) fails immediately instead of
/// burning the whole budget on an error retrying can't fix. `budget_ms ==
/// 0` disables retrying entirely (fail on the first attempt).
async fn wait_for_pg(
    pool: &deadpool_postgres::Pool,
    pg_schema: &str,
    budget_ms: u64,
) -> anyhow::Result<pg_catalog::Catalog> {
    let start = std::time::Instant::now();
    let budget = std::time::Duration::from_millis(budget_ms);
    let mut backoff = std::time::Duration::from_millis(500);
    let mut attempt: u32 = 0;
    loop {
        match pg_catalog::introspect(pool, pg_schema).await {
            Ok(catalog) => return Ok(catalog),
            Err(e)
                if budget_ms > 0 && is_pg_unreachable(&e) && start.elapsed() + backoff < budget =>
            {
                attempt += 1;
                tracing::warn!(
                    "Postgres not reachable yet (attempt {attempt}): {e:#}. Retrying in {:.1}s...",
                    backoff.as_secs_f32()
                );
                tokio::time::sleep(backoff).await;
                backoff = std::cmp::min(backoff * 2, STARTUP_RETRY_MAX_BACKOFF);
            }
            Err(e) => return Err(e),
        }
    }
}

/// True for connection-level failures (refused/reset/DNS/timeout) where
/// Postgres never actually answered. False once Postgres has responded
/// with a backend error (auth failure, unknown database, ...) -- those are
/// real config problems that retrying the same connection attempt cannot
/// fix.
fn is_pg_unreachable(err: &anyhow::Error) -> bool {
    for cause in err.chain() {
        if let Some(pool_err) = cause.downcast_ref::<deadpool_postgres::PoolError>() {
            return match pool_err {
                deadpool_postgres::PoolError::Backend(e) => e.as_db_error().is_none(),
                deadpool_postgres::PoolError::Timeout(_) => true,
                _ => false,
            };
        }
        if let Some(e) = cause.downcast_ref::<tokio_postgres::Error>() {
            return e.as_db_error().is_none();
        }
    }
    false
}

/// Resolves on SIGTERM or Ctrl-C so deploys drain in-flight requests
/// instead of hard-dropping them.
async fn shutdown_signal() {
    let ctrl_c = tokio::signal::ctrl_c();
    #[cfg(unix)]
    {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed installing SIGTERM handler");
        tokio::select! {
            _ = ctrl_c => {}
            _ = term.recv() => {}
        }
    }
    #[cfg(not(unix))]
    {
        let _ = ctrl_c.await;
    }
    tracing::info!("shutdown signal received, draining connections");
}
