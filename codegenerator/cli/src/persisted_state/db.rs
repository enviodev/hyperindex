use super::PersistedState;
use anyhow::Result;
use sqlx::{
    postgres::{PgPool, PgRow},
    Row,
};

async fn upsert_persisted_state_to_db(state: &PersistedState, pool: &PgPool) -> Result<()> {
    let serialized = serde_json::to_value(state)?;
    sqlx::query("INSERT INTO public.persisted_state (id, state) VALUES ($1, $2) ON CONFLICT (id) DO UPDATE SET state = $2")
        .bind(1)
        .bind(serialized)
        .execute(pool)
        .await?;
    Ok(())
}

async fn read_persisted_state_from_db(pool: &PgPool) -> Result<Option<PersistedState>> {
    let res = sqlx::query("SELECT state from public.persisted_state WHERE id = 1")
        .map(|row: PgRow| {
            let state_json: serde_json::Value = row.try_get("state").unwrap();
            let state: PersistedState = serde_json::from_value(state_json).unwrap();
            state
        })
        .fetch_optional(pool)
        .await?;
    Ok(res)
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
        let pg_password = std::env::var("PG_PASSWORD").unwrap_or("testing".to_string());
        let pool = PgPoolOptions::new()
            .max_connections(1)
            .connect(
                "postgres://postgres:testing@localhost:5433/envio-dev", // format!(
                                                                        //     "postgres://postgres:{}@envio-postgres:5433/envio-dev",
                                                                        //     pg_password
                                                                        // )
                                                                        // .as_str(),
            )
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

        upsert_persisted_state_to_db(&persisted_state, &pool)
            .await
            .context("write_to_db")?;

        Ok(())
    }

    #[tokio::test]
    #[ignore]
    async fn reads_from_db() -> Result<()> {
        let pg_password = std::env::var("PG_PASSWORD").unwrap_or("testing".to_string());
        let pool = PgPoolOptions::new()
            .max_connections(1)
            .connect(
                "postgres://postgres:testing@localhost:5433/envio-dev", // format!(
                                                                        //     "postgres://postgres:{}@envio-postgres:5433/envio-dev",
                                                                        //     pg_password
                                                                        // )
                                                                        // .as_str(),
            )
            .await
            .context("creating pool")?;

        let val = read_persisted_state_from_db(&pool)
            .await
            .context("read from db")?;

        println!("{:?}", val);

        assert!(val.is_some());

        Ok(())
    }
}
