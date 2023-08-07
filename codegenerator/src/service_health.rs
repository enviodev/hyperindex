use anyhow::anyhow;
use tokio::time::{timeout, Duration};

// NOTE: This assumes the hasura graphql availability means the postgres database is also available
const MAXIMUM_BACKOFF: Duration = Duration::from_secs(120); // Likely the user will kill this before it gets here but wanted to make it quite large to allow for users with slow computers
const BACKOFF_INCREMENT: Duration = Duration::from_secs(1);
const HASURA_ENDPOINT: &str = "http://localhost:8080/"; // todo: is this available somewhere

// Function to fetch the health of the Hasura service
pub async fn fetch_hasura_healthz() -> Result<String, reqwest::Error> {
    let client = reqwest::Client::new();
    let url = format!("{}healthz", HASURA_ENDPOINT);
    let response = client.get(&url).send().await?;
    let content_raw = response.text().await?;
    Ok(content_raw)
}

pub async fn fetch_hasura_healthz_with_retry() -> anyhow::Result<bool> {
    let mut refetch_delay = BACKOFF_INCREMENT;

    let fail_if_maximum_is_exceeded = |current_refetch_delay, err: &str| -> anyhow::Result<()> {
        if current_refetch_delay >= MAXIMUM_BACKOFF {
            eprintln!("Failed to fetch the health of the Hasura service: {}", err);
            return Err(anyhow!("Maximum backoff timeout exceeded"));
        }
        Ok(())
    };

    let mut first_run = true;

    loop {
        match timeout(refetch_delay, fetch_hasura_healthz()).await {
            Ok(Ok(success)) => {
                break Ok(success.contains("OK"));
            }
            Ok(Err(err)) => {
                fail_if_maximum_is_exceeded(refetch_delay, &err.to_string())?;
                if !first_run {
                    print!("\x1B[1A\x1B[2K");
                } else {
                    first_run = false;
                }
                println!(
                    "Waiting for the docker services to become available. {} seconds.",
                    refetch_delay.as_secs()
                );
            }
            Err(err) => {
                fail_if_maximum_is_exceeded(refetch_delay, &err.to_string())?;
                println!(
                    "Fetching the services health timed out. Retrying in {} seconds...",
                    refetch_delay.as_secs()
                );
            }
        }
        tokio::time::sleep(refetch_delay).await;
        refetch_delay += BACKOFF_INCREMENT;
    }
}
