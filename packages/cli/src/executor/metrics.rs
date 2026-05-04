use anyhow::{anyhow, Context, Result};
use std::time::Duration;

const DEFAULT_PORT: u16 = 9898;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

fn resolve_port() -> Result<u16> {
    match std::env::var("ENVIO_INDEXER_PORT") {
        Ok(raw) => raw.parse::<u16>().with_context(|| {
            format!("Invalid ENVIO_INDEXER_PORT={raw:?}: expected a port number 0-65535")
        }),
        Err(_) => Ok(DEFAULT_PORT),
    }
}

pub async fn run() -> Result<()> {
    let port = resolve_port()?;
    let url = format!("http://127.0.0.1:{port}/metrics");

    let client = reqwest::Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .build()
        .context("Failed building HTTP client")?;

    let response = client.get(&url).send().await.map_err(|e| {
        anyhow!(
            "Failed to fetch metrics from {url}: {e}. Is the indexer running? \
             Set ENVIO_INDEXER_PORT if it's listening on a different port."
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
