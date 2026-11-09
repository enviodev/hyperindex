use crate::utils::project_env::ProjectEnv;
use anyhow::{anyhow, Context, Result};
use std::{path::Path, time::Duration};

const DEFAULT_PORT: u16 = 9898;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

fn resolve_port(project_root: &Path) -> Result<u16> {
    match ProjectEnv::new(project_root).var("ENVIO_INDEXER_PORT") {
        Some(raw) => raw.parse::<u16>().with_context(|| {
            format!("Invalid ENVIO_INDEXER_PORT={raw:?}: expected a port number 0-65535")
        }),
        None => Ok(DEFAULT_PORT),
    }
}

pub async fn run(runtime: bool, project_root: &Path) -> Result<()> {
    let port = resolve_port(project_root)?;
    let path = if runtime {
        "/metrics/runtime"
    } else {
        "/metrics"
    };
    let url = format!("http://127.0.0.1:{port}{path}");

    let client = reqwest::Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .build()
        .context("Failed building HTTP client")?;

    let response = client.get(&url).send().await.map_err(|e| {
        anyhow!(
            "Failed to fetch metrics from {url}: {e}. Is the indexer running? Set \
             ENVIO_INDEXER_PORT if it's listening on a different port."
        )
    })?;

    let status = response.status();
    let body = response
        .text()
        .await
        .map_err(|e| anyhow!("Failed to read metrics response body from {url} ({status}): {e}"))?;

    if !status.is_success() {
        return Err(anyhow!("Metrics endpoint {url} returned {status}: {body}"));
    }

    print!("{body}");
    Ok(())
}

#[cfg(test)]
mod test {
    use super::*;
    use std::fs;
    use tempdir::TempDir;

    fn project_with_env(contents: &str) -> TempDir {
        let tmp = TempDir::new("envio_metrics_port").expect("tempdir");
        fs::write(tmp.path().join(".env"), contents).expect("write .env");
        tmp
    }

    #[test]
    fn reads_the_port_from_the_project_dotenv() {
        if std::env::var_os("ENVIO_METRICS_PORT_TEST_CHILD").is_none() {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "executor::metrics::test::reads_the_port_from_the_project_dotenv",
                    "--nocapture",
                ])
                .env("ENVIO_METRICS_PORT_TEST_CHILD", "1")
                .env_remove("ENVIO_INDEXER_PORT")
                .output()
                .unwrap();
            assert_eq!(
                (
                    output.status.success(),
                    String::from_utf8_lossy(&output.stdout).contains("test result: ok. 1 passed;"),
                ),
                (true, true),
                "{}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr),
            );
            return;
        }
        for contents in [
            "ENVIO_INDEXER_PORT=9899\n",
            "INVALID LINE\nENVIO_INDEXER_PORT=9899\n",
            "ENVIO_INDEXER_PORT=9899\nINVALID LINE\n",
        ] {
            let project = project_with_env(contents);
            assert_eq!(resolve_port(project.path()).unwrap(), 9899);
        }
    }

    #[test]
    fn falls_back_to_the_default_port_without_a_dotenv() {
        let project = TempDir::new("envio_metrics_port").expect("tempdir");
        assert_eq!(resolve_port(project.path()).unwrap(), DEFAULT_PORT);
    }

    #[test]
    fn rejects_a_dotenv_port_that_is_not_a_port() {
        let project = project_with_env("ENVIO_INDEXER_PORT=not-a-port\n");
        assert_eq!(
            resolve_port(project.path()).unwrap_err().to_string(),
            "Invalid ENVIO_INDEXER_PORT=\"not-a-port\": expected a port number 0-65535"
        );
    }
}
