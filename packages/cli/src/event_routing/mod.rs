//! Ecosystem-agnostic event routing, ported from the ReScript `EventRouter`.
//!
//! A fetched item is routed to a registered handler in two steps: first by an
//! ecosystem-specific dispatch `tag` (EVM `sighash_topicCount`, SVM
//! `programId_discriminator`, Fuel `logId`/receipt-kind), then by ownership of
//! the item's source address. The address step resolves the owning contract
//! from the partition's reverse index and falls back to a wildcard
//! registration. The router carries only the dense per-chain subscription `id`
//! it resolves to; the heavy handler/config stays on the ReScript side, indexed
//! by that id.

use anyhow::{bail, Result};
use std::collections::HashMap;

/// One subscription's routing descriptor — the lean entity shared across the
/// napi boundary. `tag` is the ecosystem-specific dispatch key the source
/// computes from a fetched item; `id` is the dense per-chain handle the router
/// returns.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Subscription {
    pub id: u32,
    pub tag: String,
    pub contract_name: String,
    pub is_wildcard: bool,
}

/// All subscriptions that share one dispatch `tag`. At most one wildcard
/// subscription per tag; the rest are keyed by owning contract name.
#[derive(Debug, Default)]
struct Group {
    wildcard: Option<u32>,
    by_contract_name: HashMap<String, u32>,
}

impl Group {
    /// Mirror of `EventRouter.Group.addOrThrow`: reject a second subscription
    /// for the same (tag, contract), and a second wildcard for the same tag.
    fn add(&mut self, sub: &Subscription) -> Result<()> {
        if self.by_contract_name.contains_key(&sub.contract_name) {
            bail!(
                "Duplicate event detected: tag {} for contract {}",
                sub.tag,
                sub.contract_name
            );
        }
        if sub.is_wildcard {
            if self.wildcard.is_some() {
                bail!(
                    "Another event is already registered with the same signature that would \
                     interfere with wildcard filtering: tag {} for contract {}",
                    sub.tag,
                    sub.contract_name
                );
            }
            self.wildcard = Some(sub.id);
        }
        self.by_contract_name
            .insert(sub.contract_name.clone(), sub.id);
        Ok(())
    }

    /// Mirror of `EventRouter.Group.get`: resolve the owning contract from the
    /// partition's reverse index, falling back to the wildcard when the address
    /// is unregistered or its contract has no subscription for this tag.
    fn resolve(
        &self,
        owner_address: &str,
        contract_name_by_address: &HashMap<String, String>,
    ) -> Option<u32> {
        match contract_name_by_address.get(owner_address) {
            Some(contract_name) => self
                .by_contract_name
                .get(contract_name)
                .copied()
                .or(self.wildcard),
            None => self.wildcard,
        }
    }
}

/// Per-chain routing table. Built once from the chain's subscriptions; queried
/// per fetched item with the partition's address→contract reverse index.
#[derive(Debug, Default)]
pub struct Router {
    by_tag: HashMap<String, Group>,
}

impl Router {
    pub fn build(subscriptions: impl IntoIterator<Item = Subscription>) -> Result<Self> {
        let mut by_tag: HashMap<String, Group> = HashMap::new();
        for sub in subscriptions {
            by_tag.entry(sub.tag.clone()).or_default().add(&sub)?;
        }
        Ok(Self { by_tag })
    }

    /// Resolve a fetched item to its subscription id, or `None` when nothing is
    /// registered for the (tag, owner) pair. `owner_address` is the item's
    /// source identity: EVM/Fuel source address, SVM program id.
    pub fn resolve(
        &self,
        tag: &str,
        owner_address: &str,
        contract_name_by_address: &HashMap<String, String>,
    ) -> Option<u32> {
        self.by_tag
            .get(tag)?
            .resolve(owner_address, contract_name_by_address)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sub(id: u32, tag: &str, contract: &str, is_wildcard: bool) -> Subscription {
        Subscription {
            id,
            tag: tag.to_string(),
            contract_name: contract.to_string(),
            is_wildcard,
        }
    }

    fn owners(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(a, c)| (a.to_string(), c.to_string()))
            .collect()
    }

    #[test]
    fn resolves_owned_address_to_its_contract_subscription() {
        let router = Router::build([sub(7, "t", "ERC20", false)]).unwrap();
        let owners = owners(&[("0xabc", "ERC20")]);
        assert_eq!(router.resolve("t", "0xabc", &owners), Some(7));
    }

    #[test]
    fn unregistered_address_falls_back_to_wildcard() {
        let router =
            Router::build([sub(1, "t", "ERC20", false), sub(2, "t", "Any", true)]).unwrap();
        // 0xzzz is not in the reverse index → wildcard wins.
        assert_eq!(router.resolve("t", "0xzzz", &owners(&[])), Some(2));
    }

    #[test]
    fn owned_address_without_matching_tag_falls_back_to_wildcard() {
        let router =
            Router::build([sub(1, "t", "ERC20", false), sub(2, "t", "Any", true)]).unwrap();
        // Address owned by a contract that has no subscription for this tag.
        let owners = owners(&[("0xabc", "OtherContract")]);
        assert_eq!(router.resolve("t", "0xabc", &owners), Some(2));
    }

    #[test]
    fn no_wildcard_and_unowned_address_resolves_to_none() {
        let router = Router::build([sub(1, "t", "ERC20", false)]).unwrap();
        assert_eq!(router.resolve("t", "0xzzz", &owners(&[])), None);
    }

    #[test]
    fn unknown_tag_resolves_to_none() {
        let router = Router::build([sub(1, "t", "ERC20", false)]).unwrap();
        assert_eq!(
            router.resolve("other", "0xabc", &owners(&[("0xabc", "ERC20")])),
            None
        );
    }

    #[test]
    fn duplicate_contract_for_same_tag_is_rejected() {
        let err = Router::build([sub(1, "t", "ERC20", false), sub(2, "t", "ERC20", false)])
            .unwrap_err()
            .to_string();
        assert!(err.contains("Duplicate event detected"), "{err}");
    }

    #[test]
    fn second_wildcard_for_same_tag_is_rejected() {
        let err = Router::build([sub(1, "t", "A", true), sub(2, "t", "B", true)])
            .unwrap_err()
            .to_string();
        assert!(err.contains("interfere with wildcard filtering"), "{err}");
    }
}
