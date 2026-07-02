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

pub struct ServeState {
    pub model: model::ServerModel,
    pub pool: deadpool_postgres::Pool,
    pub admin_secret: String,
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
    });

    http::serve(state, &args.host, args.port).await
}
