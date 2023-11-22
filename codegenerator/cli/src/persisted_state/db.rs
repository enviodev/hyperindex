use super::PersistedState;
use sqlx::postgres::{PgPool, PgQueryResult};

impl PersistedState {
    async fn upsert_to_db(&self, pool: &PgPool) -> Result<PgQueryResult, sqlx::Error> {
        sqlx::query(
            "INSERT INTO public.persisted_state (
            id, 
            envio_version,
            has_run_db_migrations,
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
            $6, 
            $7 
        ) ON CONFLICT (id) DO UPDATE SET (
            envio_version,
            has_run_db_migrations,
            config_hash,
            schema_hash,
            handler_files_hash,
            abi_files_hash
        ) = (
            $2, 
            $3, 
            $4, 
            $5, 
            $6, 
            $7 
        )",
        )
        .bind(1) //Always only 1 id to update
        .bind(&self.envio_version)
        .bind(&self.has_run_db_migrations)
        .bind(&self.config_hash)
        .bind(&self.schema_hash)
        .bind(&self.handler_files_hash)
        .bind(&self.abi_files_hash)
        .execute(pool)
        .await
    }

    async fn read_from_db(pool: &PgPool) -> Result<Option<Self>, sqlx::Error> {
        sqlx::query_as::<_, PersistedState>(
            "SELECT 
            envio_version,
            has_run_db_migrations,
            config_hash,
            schema_hash,
            handler_files_hash,
            abi_files_hash
         from public.persisted_state WHERE id = 1",
        )
        .fetch_optional(pool)
        .await
    }
}
#[cfg(test)]
mod test {
    use super::*;
    use crate::{
        config_parsing::{entity_parsing::Schema, human_config, system_config::SystemConfig},
        project_paths::ParsedProjectPaths,
    };
    use anyhow::{Context, Result};
    use sqlx::postgres::PgPoolOptions;
    use std::path::PathBuf;

    #[tokio::test]
    #[ignore]
    async fn writes_to_db() -> Result<()> {
        println!("This test only works if the db migrations have been run and the db config is 100% correct");
        let pool = PgPoolOptions::new()
            .max_connections(1)
            .connect("postgres://postgres:testing@localhost:5433/envio-dev")
            .await
            .context("creating pool")?;
        let root = format!("{}/test/configs", env!("CARGO_MANIFEST_DIR"));
        let path = format!("{}/config1.yaml", &root);
        let config_path = PathBuf::from(path);

        let human_cfg =
            human_config::deserialize_config_from_yaml(&config_path).context("human cfg")?;
        let system_cfg = SystemConfig::parse_from_human_cfg_with_schema(
            &human_cfg,
            Schema::empty(),
            &ParsedProjectPaths::new(&root, "generated", "config1.yaml")?,
        )
        .context("system_cfg")?;
        let persisted_state =
            PersistedState::try_default(&system_cfg).context("persisted_state")?;

        persisted_state
            .upsert_to_db(&pool)
            .await
            .context("write_to_db")?;

        Ok(())
    }

    #[tokio::test]
    #[ignore]
    async fn reads_from_db() -> Result<()> {
        println!("This test only works if the db migrations have been run and the db config is 100% correct");
        let pool = PgPoolOptions::new()
            .max_connections(1)
            .connect("postgres://postgres:testing@localhost:5433/envio-dev")
            .await
            .context("creating pool")?;

        let val = PersistedState::read_from_db(&pool)
            .await
            .context("read from db")?;

        println!("{:?}", val);

        assert!(val.is_some());

        Ok(())
    }
}
