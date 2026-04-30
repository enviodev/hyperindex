use anyhow::{anyhow, Result};

const DEFAULT_PORT: u16 = 9898;

fn resolve_port() -> u16 {
    for var in ["ENVIO_INDEXER_PORT", "METRICS_PORT"] {
        if let Ok(raw) = std::env::var(var) {
            if let Ok(parsed) = raw.parse::<u16>() {
                return parsed;
            }
        }
    }
    DEFAULT_PORT
}

pub async fn run() -> Result<()> {
    let port = resolve_port();
    let url = format!("http://127.0.0.1:{port}/metrics");

    let response = reqwest::get(&url).await.map_err(|e| {
        anyhow!(
            "Failed to fetch metrics from {url}: {e}. Is the indexer running? \
             Set ENVIO_INDEXER_PORT if it's listening on a different port."
        )
    })?;

    let status = response.status();
    let body = response
        .text()
        .await
        .map_err(|e| anyhow!("Failed to read metrics response body from {url}: {e}"))?;

    if !status.is_success() {
        return Err(anyhow!("Metrics endpoint {url} returned {status}: {body}"));
    }

    print!("{body}");
    Ok(())
}
