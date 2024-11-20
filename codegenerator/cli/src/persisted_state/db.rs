use super::{PersistedState, PersistedStateExists};
use sqlx::postgres::{PgPool, PgPoolOptions, PgQueryResult};
use std::env;

fn get_env_with_default(var: &str, default: &str) -> String {
    env::var(var).unwrap_or_else(|_| default.to_string())
}

async fn get_pg_pool() -> Result<PgPool, sqlx::Error> {
    let host = get_env_with_default("ENVIO_PG_HOST", "localhost");
    let port = get_env_with_default("ENVIO_PG_PORT", "5433");
    let user = get_env_with_default("ENVIO_PG_USER", "postgres");
    let password = get_env_with_default("ENVIO_POSTGRES_PASSWORD", "testing");
    let database = get_env_with_default("ENVIO_PG_DATABASE", "envio-dev");

    let connection_url = format!("postgres://{user}:{password}@{host}:{port}/{database}");

    PgPoolOptions::new().connect(&connection_url).await
}

impl PersistedState {
    pub async fn upsert_to_db(&self) -> Result<PgQueryResult, sqlx::Error> {
        let pool = get_pg_pool().await?;
        self.upsert_to_db_with_pool(&pool).await
    }

    async fn upsert_to_db_with_pool(&self, pool: &PgPool) -> Result<PgQueryResult, sqlx::Error> {
        sqlx::query(
            "INSERT INTO public.persisted_state (
            id, 
            envio_version,
            config_hash,
            schema_hash,
            handler_files_hash,
            abi_files_hash
        ) VALUES (
            $1, 
            $2, 
            $3, 
            $4, 
            $5, 
            $6 
        ) ON CONFLICT (id) DO UPDATE SET (
            envio_version,
            config_hash,
            schema_hash,
            handler_files_hash,
            abi_files_hash
        ) = (
            $2, 
            $3, 
            $4, 
            $5, 
            $6 
        )",
        )
        .bind(1) //Always only 1 id to update
        .bind(&self.envio_version)
        .bind(&self.config_hash)
        .bind(&self.schema_hash)
        .bind(&self.handler_files_hash)
        .bind(&self.abi_files_hash)
        .execute(pool)
        .await
    }
}

impl PersistedStateExists {
    pub async fn read_from_db() -> Result<PersistedStateExists, sqlx::Error> {
        let pool = get_pg_pool().await?;
        Self::read_from_db_with_pool(&pool).await
    }
    pub async fn read_from_db_with_pool(
        pool: &PgPool,
    ) -> Result<PersistedStateExists, sqlx::Error> {
        let val = sqlx::query_as::<_, PersistedState>(
            "SELECT 
            envio_version,
            config_hash,
            schema_hash,
            handler_files_hash,
            abi_files_hash
         from public.persisted_state WHERE id = 1",
        )
        .fetch_optional(pool)
        .await;

        match val {
            Err(e) => match e {
                //In the following cases treat it as a corrupt persisted state
                sqlx::Error::Decode(_)
                | sqlx::Error::ColumnNotFound(_)
                | sqlx::Error::Database(_)
                | sqlx::Error::ColumnDecode { .. }
                | sqlx::Error::TypeNotFound { .. } => Ok(PersistedStateExists::Corrupted),
                _ => Err(e),
            },
            Ok(opt_state) => match opt_state {
                None => Ok(PersistedStateExists::NotExists),
                Some(p) => Ok(PersistedStateExists::Exists(p)),
            },
        }
    }
}
#[cfg(test)]
mod test {
    use super::*;
    use crate::{config_parsing::system_config::SystemConfig, project_paths::ParsedProjectPaths};
    use anyhow::{Context, Result};

    #[tokio::test]
    #[ignore]
    async fn writes_to_db() -> Result<()> {
        println!(
            "This test only works if the db migrations have been run and the db is up and running"
        );
        let root = format!("{}/test/configs", env!("CARGO_MANIFEST_DIR"));

        let system_cfg = SystemConfig::parse_from_project_files(&ParsedProjectPaths::new(
            &root,
            "generated",
            "config1.yaml",
        )?)
        .context("system_cfg")?;
        let persisted_state =
            PersistedState::get_current_state(&system_cfg).context("persisted_state")?;

        persisted_state
            .upsert_to_db()
            .await
            .context("write_to_db")?;

        Ok(())
    }

    #[tokio::test]
    #[ignore]
    async fn reads_from_db() -> Result<()> {
        println!(
            "This test only works if the db migrations have been run and the db is up and running"
        );
        let val = PersistedStateExists::read_from_db()
            .await
            .context("read from db")?;

        println!("{:?}", val);

        assert!(matches!(val, PersistedStateExists::Exists(_)));

        Ok(())
    }
}
