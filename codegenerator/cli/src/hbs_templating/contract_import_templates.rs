use anyhow::{anyhow, Context};

use crate::capitalization::{Capitalize, CapitalizedOptions};
use crate::config_parsing::entity_parsing::ethabi_type_to_scalar;
use crate::config_parsing::{Config, EventNameOrSig};

struct AutoSchemaHandlerTemplate {
    contracts: Vec<Contract>,
}

struct Contract {
    name: CapitalizedOptions,
    events: Vec<Event>,
}

struct Event {
    name: CapitalizedOptions,
    params: Vec<Param>,
}

struct Param {
    key: CapitalizedOptions,
    graphql_type: String,
}

impl AutoSchemaHandlerTemplate {
    pub fn try_from(config: Config) -> anyhow::Result<Self> {
        let mut contracts = Vec::new();
        // what about the scenario where there is the same contract that is defined for multiple chains?
        for network in config.networks.iter() {
            for contract in network.contracts.iter() {
                let contract_name = contract.name.to_capitalized_options();
                let mut events = Vec::new();

                for config_event in contract.events.iter() {
                    match &config_event.event {
                        EventNameOrSig::Name(_) => Err(anyhow!(
                            "Currently only handling config defined events (not external abi file)"
                        ))?,
                        EventNameOrSig::Event(event) => {
                            let event_name = event.name.to_capitalized_options();

                            let params: Vec<_> = event
                                .inputs
                                .iter()
                                .map(|param| {
                                    let graphql_type = ethabi_type_to_scalar(&param.kind)
                                        .context("converting eth event param to gql scalar")?
                                        .to_string();
                                    let param_name = param.name.to_capitalized_options();
                                    Ok(Param {
                                        key: param_name,
                                        graphql_type,
                                    })
                                })
                                .collect::<anyhow::Result<_>>()?;

                            events.push(Event {
                                name: event_name,
                                params,
                            });
                        }
                    };
                }
                contracts.push(Contract {
                    name: contract_name,
                    events,
                });
            }
        }
        Ok(AutoSchemaHandlerTemplate { contracts })
    }
}
