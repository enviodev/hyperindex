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

pub struct ServeState {
    pub model: model::ServerModel,
    pub pool: deadpool_postgres::Pool,
    pub admin_secret: String,
    /// Client-side bound on a whole operation's execution (every root
    /// field's pool wait + prepare + query). The server-side
    /// statement_timeout normally fires first; this is the backstop for a
    /// Postgres that stopped responding entirely.
    pub query_timeout: Option<std::time::Duration>,
}

pub async fn run(args: &ServeArgs, project_paths: &ParsedProjectPaths) -> anyhow::Result<()> {
    let env = env_config::ServeEnv::load(project_paths)?;

    let project_schema = project_schema::ProjectSchema::load(project_paths, &env)
        .context("Failed loading schema.graphql")?;

    let pool = env
        .make_pg_pool()
        .context("Failed creating Postgres pool")?;

    let catalog = pg_catalog::introspect(&pool, &env.pg_schema)
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
    });

    http::serve(state, &args.host, args.port, shutdown_signal()).await
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
    println!("envio serve: shutdown signal received, draining connections");
}
