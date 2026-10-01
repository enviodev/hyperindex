//! HyperSync endpoint health checks that require network access.
//! Run with: cargo test --features hypersync_health --test hypersync_health
#![cfg(feature = "hypersync_health")]

use envio::config_parsing::chain_helpers::HypersyncChain;
use envio::config_parsing::hypersync_endpoints::network_to_hypersync_url;
use envio::scripts::print_missing_networks::{format_extra_chain, Diff};
use strum::IntoEnumIterator;

async fn fetch_hypersync_health(hypersync_endpoint: &str) -> anyhow::Result<bool> {
    let client = reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(5))
        .timeout(std::time::Duration::from_secs(10))
        .build()?;
    let url = format!("{hypersync_endpoint}/height");
    let response = client.get(&url).send().await?;
    Ok(response.status().is_success())
}

const MAX_RETRIES: u32 = 3;

#[tokio::test]
async fn all_supported_endpoints_are_healthy() {
    // Iterating HypersyncChain::iter() alone only covers chains already in
    // the enum, so chains added to the HyperSync API but missing from the
    // enum slip through, and chains the API dropped stay in the enum until
    // their endpoint dies. Report either kind of drift alongside the probe
    // results.
    let diff = Diff::get()
        .await
        .expect("Failed to fetch chain diff from HyperSync API");
    let mut drift = Vec::new();
    if !diff.missing_chains.is_empty() {
        drift.push(format!(
            "HyperSync API has chains absent from the Network enum:\n{}",
            diff.missing_chains.join("\n")
        ));
    }
    if !diff.extra_chains.is_empty() {
        drift.push(format!(
            "Network enum has HypersyncChain entries the API no longer lists \
             (drop their HypersyncChain subenum):\n{}",
            diff.extra_chains
                .iter()
                .map(format_extra_chain)
                .collect::<Vec<_>>()
                .join("\n")
        ));
    }
    // Probe every endpoint before reporting, so neither drift nor one dead
    // chain masks the rest.
    let mut failures = Vec::new();
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
            failures.push(format!(
                "Failed to fetch health for {} after {} retries: {:#}",
                url, MAX_RETRIES, e
            ));
        }
    }
    if !failures.is_empty() {
        drift.push(format!(
            "Unhealthy endpoints ({}):\n{}",
            failures.len(),
            failures.join("\n")
        ));
    }
    if !drift.is_empty() {
        panic!("{}", drift.join("\n\n"));
    }
}
