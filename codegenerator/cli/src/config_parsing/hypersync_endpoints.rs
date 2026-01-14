use anyhow::{anyhow, Context};

use super::chain_helpers::{HypersyncNetwork, Network};

pub fn network_to_hypersync_url(network: &HypersyncNetwork) -> String {
    format!("https://{}.hypersync.xyz", *network as u64)
}

/// Validates a custom HyperSync URL provided by the user.
///
/// If the URL matches the pattern `https://{subdomain}.hypersync.xyz`, validates that
/// the subdomain is a numeric chain ID of a supported HyperSync network.
///
/// URLs that don't match this pattern are allowed (for custom HyperSync servers).
pub fn validate_hypersync_url(url: &str) -> anyhow::Result<()> {
    // Check if URL matches the hypersync.xyz pattern
    let Some(subdomain) = extract_hypersync_subdomain(url) else {
        // Not a hypersync.xyz URL - allow custom servers
        return Ok(());
    };

    // Try to parse subdomain as chain ID
    let chain_id: u64 = subdomain.parse().map_err(|_| {
        anyhow!(
            "EE112: Invalid HyperSync URL \"{}\". The subdomain \"{}\" is not a valid chain ID. \
             HyperSync URLs must use numeric chain IDs (e.g., https://1.hypersync.xyz for Ethereum). \
             Check https://docs.envio.dev/docs/HyperSync/hypersync-supported-networks for supported networks.",
            url,
            subdomain
        )
    })?;

    // Validate that the chain ID is supported
    let network_name = Network::from_network_id(chain_id).map_err(|_| {
        anyhow!(
            "EE112: Invalid HyperSync URL \"{}\". Chain ID {} is not a recognized network.",
            url,
            chain_id
        )
    })?;

    HypersyncNetwork::try_from(network_name).map_err(|_| {
        anyhow!(
            "EE112: Invalid HyperSync URL \"{}\". Network \"{}\" (chain ID {}) does not support HyperSync. \
             Check https://docs.envio.dev/docs/HyperSync/hypersync-supported-networks for supported networks, \
             or provide an RPC URL instead.",
            url,
            network_name,
            chain_id
        )
    })?;

    Ok(())
}

/// Extracts the subdomain from a hypersync.xyz URL.
/// Returns None if the URL is not a hypersync.xyz URL.
fn extract_hypersync_subdomain(url: &str) -> Option<&str> {
    // Remove protocol prefix
    let without_protocol = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))?;

    // Check if it ends with hypersync.xyz (with optional trailing slash/path)
    let host = without_protocol.split('/').next()?;
    let subdomain = host.strip_suffix(".hypersync.xyz")?;

    // Ensure subdomain is not empty and doesn't contain dots (no nested subdomains)
    if subdomain.is_empty() || subdomain.contains('.') {
        return None;
    }

    Some(subdomain)
}

pub fn get_default_hypersync_endpoint(chain_id: u64) -> anyhow::Result<String> {
    let network_name = Network::from_network_id(chain_id)
        .context(format!("Getting network name from id ({})", chain_id))?;

    let network = HypersyncNetwork::try_from(network_name).context(format!(
        "Unsupported network (name: {}, id: {}) provided for hypersync",
        network_name, chain_id
    ))?;

    Ok(network_to_hypersync_url(&network))
}

#[cfg(test)]
mod test {

    use crate::config_parsing::hypersync_endpoints::{
        extract_hypersync_subdomain, get_default_hypersync_endpoint, validate_hypersync_url,
    };

    use super::HypersyncNetwork;
    use strum::IntoEnumIterator;

    #[test]
    fn all_supported_chain_ids_return_a_hypersync_endpoint() {
        for network in HypersyncNetwork::iter() {
            let _ = get_default_hypersync_endpoint(network as u64).unwrap();
        }
    }

    #[test]
    fn extract_subdomain_from_hypersync_url() {
        // Valid hypersync.xyz URLs
        assert_eq!(
            extract_hypersync_subdomain("https://1.hypersync.xyz"),
            Some("1")
        );
        assert_eq!(
            extract_hypersync_subdomain("https://137.hypersync.xyz"),
            Some("137")
        );
        assert_eq!(
            extract_hypersync_subdomain("https://lightlink.hypersync.xyz"),
            Some("lightlink")
        );
        assert_eq!(
            extract_hypersync_subdomain("http://1.hypersync.xyz"),
            Some("1")
        );
        assert_eq!(
            extract_hypersync_subdomain("https://1.hypersync.xyz/"),
            Some("1")
        );
        assert_eq!(
            extract_hypersync_subdomain("https://1.hypersync.xyz/some/path"),
            Some("1")
        );

        // Non-hypersync.xyz URLs (returns None)
        assert_eq!(extract_hypersync_subdomain("https://myskar.com"), None);
        assert_eq!(
            extract_hypersync_subdomain("https://custom.server.io"),
            None
        );
        assert_eq!(extract_hypersync_subdomain("https://hypersync.xyz"), None);

        // Nested subdomains (returns None)
        assert_eq!(
            extract_hypersync_subdomain("https://foo.bar.hypersync.xyz"),
            None
        );
    }

    #[test]
    fn validate_supported_hypersync_urls() {
        // Valid supported HyperSync URLs
        assert!(validate_hypersync_url("https://1.hypersync.xyz").is_ok()); // Ethereum
        assert!(validate_hypersync_url("https://137.hypersync.xyz").is_ok()); // Polygon
        assert!(validate_hypersync_url("https://42161.hypersync.xyz").is_ok()); // Arbitrum

        // Custom servers (non hypersync.xyz) are allowed
        assert!(validate_hypersync_url("https://myskar.com").is_ok());
        assert!(validate_hypersync_url("https://custom.server.io").is_ok());
    }

    #[test]
    fn validate_rejects_invalid_hypersync_subdomain() {
        // Non-numeric subdomain on hypersync.xyz
        let err = validate_hypersync_url("https://lightlink.hypersync.xyz").unwrap_err();
        assert!(err.to_string().contains("EE112"));
        assert!(err.to_string().contains("lightlink"));
        assert!(err.to_string().contains("not a valid chain ID"));
    }

    #[test]
    fn validate_rejects_unrecognized_chain_id() {
        // Chain ID that doesn't exist in Network enum
        let err = validate_hypersync_url("https://999999.hypersync.xyz").unwrap_err();
        assert!(err.to_string().contains("EE112"));
        assert!(err.to_string().contains("999999"));
        assert!(err.to_string().contains("not a recognized network"));
    }

    #[test]
    fn validate_rejects_unsupported_hypersync_network() {
        // Chain ID 80084 is BerachainBartio - in Network enum but NOT in HypersyncNetwork
        let err = validate_hypersync_url("https://80084.hypersync.xyz").unwrap_err();
        assert!(err.to_string().contains("EE112"));
        assert!(err.to_string().contains("80084"));
        assert!(err.to_string().contains("does not support HyperSync"));
    }
}
