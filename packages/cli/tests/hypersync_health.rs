//! HyperSync endpoint health checks that require network access.
//! Run with: cargo test --features hypersync_health --test hypersync_health
#![cfg(feature = "hypersync_health")]

use envio::config_parsing::chain_helpers::HypersyncChain;
use envio::config_parsing::hypersync_endpoints::network_to_hypersync_url;
use envio::scripts::print_missing_networks::Diff;
use strum::IntoEnumIterator;

async fn fetch_hypersync_health(hypersync_endpoint: &str) -> anyhow::Result<bool> {
    let client = reqwest::Client::new();
    let url = format!("{hypersync_endpoint}/height");
    let response = client.get(&url).send().await?;
    Ok(response.status().is_success())
}

const MAX_RETRIES: u32 = 3;

#[tokio::test]
async fn all_supported_endpoints_are_healthy() {
    // Iterating HypersyncChain::iter() alone only covers chains already in
    // the enum, so chains added to the HyperSync API but missing from the
    // enum slip through. Fail the test in that case before probing
    // endpoints.
    let diff = Diff::get()
        .await
        .expect("Failed to fetch chain diff from HyperSync API");
    if !diff.missing_chains.is_empty() {
        panic!(
            "HyperSync API has chains absent from the Network enum:\n{}",
            diff.missing_chains.join("\n")
        );
    }

    for network in HypersyncChain::iter() {
        let url = network_to_hypersync_url(&network);
        let mut last_err = None;
        for attempt in 0..=MAX_RETRIES {
            if attempt > 0 {
                tokio::time::sleep(std::time::Duration::from_secs(2u64.pow(attempt))).await;
            }
            match fetch_hypersync_health(&url).await {
                Ok(true) => {
                    last_err = None;
                    break;
                }
                Ok(false) => {
                    last_err = Some(anyhow::anyhow!(
                        "Endpoint for {} returned unhealthy status",
                        url
                    ));
                }
                Err(e) => {
                    last_err = Some(e);
                }
            }
        }
        if let Some(e) = last_err {
            panic!(
                "Failed to fetch health for {} after {} retries: {:?}",
                url, MAX_RETRIES, e
            );
        }
    }
}
