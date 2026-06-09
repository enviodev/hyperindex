use anyhow::Context;

use super::chain_helpers::{HypersyncChain, Network};

pub fn network_to_hypersync_url(network: &HypersyncChain) -> String {
    format!("https://{}.hypersync.xyz", *network as u64)
}

pub fn get_default_hypersync_endpoint(chain_id: u64) -> anyhow::Result<String> {
    let network_name = Network::from_network_id(chain_id)
        .context(format!("Getting network name from id ({})", chain_id))?;

    let network = HypersyncChain::try_from(network_name).context(format!(
        "Unsupported network (name: {}, id: {}) provided for hypersync",
        network_name, chain_id
    ))?;

    Ok(network_to_hypersync_url(&network))
}

#[cfg(test)]
mod test {

    use crate::config_parsing::hypersync_endpoints::get_default_hypersync_endpoint;

    use super::HypersyncChain;
    use strum::IntoEnumIterator;

    #[test]
    fn all_supported_chain_ids_return_a_hypersync_endpoint() {
        for network in HypersyncChain::iter() {
            let _ = get_default_hypersync_endpoint(network as u64).unwrap();
        }
    }
}
