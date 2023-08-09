use tokio::time::{timeout, Duration};

// NOTE: This assumes the hasura graphql availability means the postgres database is also available
const MAXIMUM_BACKOFF: Duration = Duration::from_secs(120); // Likely the user will kill this before it gets here but wanted to make it quite large to allow for users with slow computers
const BACKOFF_INCREMENT: Duration = Duration::from_secs(1);
const HASURA_ENDPOINT: &str = "http://localhost:8080/"; // todo: is this available somewhere

// Function to fetch the health of the Hasura service
pub async fn fetch_hasura_healthz() -> Result<bool, reqwest::Error> {
    let client = reqwest::Client::new();
    let url = format!("{}/hasura/healthz?strict=true", HASURA_ENDPOINT);
    let response = client.get(&url).send().await?;
    let is_success = response.status().is_success();
    Ok(is_success)
}

fn delete_last_println() {
    const ERASE_ANSI_ESCAPE_CODE: &str = "\x1B[1A\x1B[2K";
    print!("{ERASE_ANSI_ESCAPE_CODE}");
}

pub enum HasuraHealth {
    Healthy,
    Unhealthy(String),
}

pub async fn fetch_hasura_healthz_with_retry() -> HasuraHealth {
    let mut refetch_delay = BACKOFF_INCREMENT;

    let mut first_run = true;

    loop {
        match timeout(refetch_delay, fetch_hasura_healthz()).await {
            Ok(Ok(success)) => {
                if success {
                    break HasuraHealth::Healthy;
                } else {
                    if refetch_delay >= MAXIMUM_BACKOFF {
                        return HasuraHealth::Unhealthy(
                            "Maximum backoff timeout exceeded".to_string(),
                        );
                    }
                }
            }
            Ok(Err(err)) => {
                if refetch_delay >= MAXIMUM_BACKOFF {
                    return HasuraHealth::Unhealthy(format!(
                        "Maximum backoff timeout exceeded: Error: {}",
                        err
                    ));
                }
                if !first_run {
                    delete_last_println();
                } else {
                    first_run = false;
                }
                println!(
                    "Waiting for the docker services to become available. {} seconds.",
                    refetch_delay.as_secs()
                );
            }
            Err(err) => {
                if refetch_delay >= MAXIMUM_BACKOFF {
                    return HasuraHealth::Unhealthy(format!(
                        "Maximum backoff timeout exceeded: Error: {}",
                        err
                    ));
                }
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
