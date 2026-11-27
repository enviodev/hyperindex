use alloy_primitives::hex;
use anyhow::{Context, Result};
use hypersync_client::format::{Hex, LogArgument};
use napi_derive::napi;

use crate::ecosystems::evm::registration::OnEventRegistrationInput;

/// One alternative of a registration's resolved `where`, a constraint per topic
/// position: `Some([])` matches any value, `Some(values)` one of `values`, and
/// `None` is the "currently registered addresses of this contract" marker. Each
/// position is spelled as `Option<...>` directly (not an alias) so the napi
/// macro sees the field as optional.
#[napi(object)]
#[derive(Clone)]
pub struct TopicFilterInput {
    pub topic0: Option<Vec<String>>,
    pub topic1: Option<Vec<String>>,
    pub topic2: Option<Vec<String>>,
    pub topic3: Option<Vec<String>>,
}

enum TopicConstraint {
    Any,
    /// Never empty: an empty value list crosses the boundary as `Any`.
    Values(Vec<[u8; 32]>),
    /// The topic must be the padded form of an address the request holds for
    /// the registration's own contract, at or before the log's block. A query
    /// expands it to those addresses' topics. In matching, ownership is the
    /// request set's answer — the query materialised this position from that
    /// same set, so a sibling selection's log carrying another request's
    /// address must not fan out here. The store answers only the temporal
    /// half, dropping a value registered after the log's block that a request
    /// over-fetched.
    ContractAddresses,
}

impl TopicConstraint {
    fn parse(input: Option<&Vec<String>>) -> Result<Self> {
        Ok(match input {
            None => TopicConstraint::ContractAddresses,
            Some(values) if values.is_empty() => TopicConstraint::Any,
            Some(values) => TopicConstraint::Values(
                values
                    .iter()
                    .map(|v| {
                        LogArgument::decode_hex(v)
                            .map(|arg| **arg)
                            .with_context(|| format!("decode topic filter value {v}"))
                    })
                    .collect::<Result<_>>()?,
            ),
        })
    }

    /// The position's values in a query, empty matching any.
    fn materialize(&self, address_topics: &[String]) -> Vec<String> {
        match self {
            TopicConstraint::Any => Vec::new(),
            TopicConstraint::Values(values) => values.iter().map(hex::encode_prefixed).collect(),
            TopicConstraint::ContractAddresses => address_topics.to_vec(),
        }
    }
}

/// One DNF alternative: a constraint for each of the four topic positions.
pub(crate) struct TopicFilter([TopicConstraint; 4]);

impl TopicFilter {
    pub(crate) fn materialize(&self, address_topics: &[String]) -> [Vec<String>; 4] {
        self.0.each_ref().map(|c| c.materialize(address_topics))
    }
}

/// A registration's resolved `where` in DNF: the outer Vec is an OR of
/// alternatives. A registration with no `where` carries one alternative
/// pinning topic0 to its signature. An empty DNF (`where: false`) matches
/// nothing; such a registration is dropped before it reaches a source (see
/// `HandlerRegister`).
pub(crate) struct TopicFilters(Vec<TopicFilter>);

impl TopicFilters {
    pub(crate) fn parse(registration: &OnEventRegistrationInput) -> Result<Self> {
        let alternatives = registration
            .topic_filters
            .iter()
            .map(|input| {
                Ok(TopicFilter([
                    TopicConstraint::parse(input.topic0.as_ref())?,
                    TopicConstraint::parse(input.topic1.as_ref())?,
                    TopicConstraint::parse(input.topic2.as_ref())?,
                    TopicConstraint::parse(input.topic3.as_ref())?,
                ]))
            })
            .collect::<Result<Vec<_>>>()
            .context("parse topic filters")?;
        // Without a signature (an anonymous event) an unconstrained topic0
        // would fetch every log of the address — or of the chain, for a
        // wildcard.
        anyhow::ensure!(
            registration.sighash.is_some()
                || alternatives
                    .iter()
                    .all(|alternative| matches!(alternative.0[0], TopicConstraint::Values(_))),
            "Registration {} of the anonymous event {} must filter topic0 by values in every \
             alternative",
            registration.index,
            registration.event_name,
        );
        Ok(Self(alternatives))
    }

    pub(crate) fn alternatives(&self) -> &[TopicFilter] {
        &self.0
    }
}
