use anyhow::Context;
use async_graphql::http::GraphiQLSource;
use async_graphql_axum::{GraphQLRequest, GraphQLResponse};
use axum::{
    extract::State,
    response::{Html, IntoResponse},
    routing::get,
    Router,
};
use sqlx::postgres::PgPoolOptions;
use std::env;
use std::sync::Arc;
use tower_http::cors::CorsLayer;

use crate::config_parsing::system_config::SystemConfig;

use super::schema::build_schema;

fn get_env_with_default(var: &str, default: &str) -> String {
    env::var(var).unwrap_or_else(|_| default.to_string())
}

pub async fn start_server(config: &SystemConfig, port: u16) -> anyhow::Result<()> {
    let host = get_env_with_default("ENVIO_PG_HOST", "localhost");
    let pg_port = get_env_with_default("ENVIO_PG_PORT", "5433");
    let user = get_env_with_default("ENVIO_PG_USER", "postgres");
    let password = get_env_with_default("ENVIO_POSTGRES_PASSWORD", "testing");
    let database = get_env_with_default("ENVIO_PG_DATABASE", "envio-dev");

    let mut env_state = crate::config_parsing::system_config::EnvState::new(
        &std::env::current_dir().unwrap_or_default(),
    );
    let pg_schema = env_state
        .var("ENVIO_PG_SCHEMA")
        .or_else(|| env_state.var("ENVIO_PG_PUBLIC_SCHEMA"))
        .unwrap_or_else(|| "public".to_string());

    let connection_url = format!("postgres://{user}:{password}@{host}:{pg_port}/{database}");

    let pool = PgPoolOptions::new()
        .max_connections(10)
        .connect(&connection_url)
        .await
        .context("Failed to connect to PostgreSQL")?;

    let parsed_schema = &config.schema;

    let schema = build_schema(parsed_schema, pool, pg_schema)
        .context("Failed to build GraphQL schema")?;

    let schema = Arc::new(schema);

    let app = Router::new()
        .route("/graphql", get(graphiql_handler).post(graphql_handler))
        .route("/healthz", get(health_handler))
        .layer(CorsLayer::permissive())
        .with_state(schema);

    let addr = format!("0.0.0.0:{}", port);
    println!("GraphQL server started at http://localhost:{}/graphql", port);
    println!("GraphiQL IDE available at http://localhost:{}/graphql", port);

    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .context(format!("Failed to bind to {}", addr))?;

    axum::serve(listener, app)
        .await
        .context("Server error")?;

    Ok(())
}

async fn graphql_handler(
    State(schema): State<Arc<async_graphql::dynamic::Schema>>,
    req: GraphQLRequest,
) -> GraphQLResponse {
    schema.execute(req.into_inner()).await.into()
}

async fn graphiql_handler() -> impl IntoResponse {
    Html(GraphiQLSource::build().endpoint("/graphql").finish())
}

async fn health_handler() -> &'static str {
    "ok"
}
