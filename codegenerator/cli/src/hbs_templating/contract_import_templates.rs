use anyhow::Context;

use crate::capitalization::CapitalizedOptions;
use crate::config_parsing::Config;

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
                    let abi_event = match &config_event.event {
                        EventNameOrSig::Name(name) => {
                            
                        }
                        EventNameOrSig::Event(event) => {
                            let event_name = event.name.to_capitalized_options();
                            let mut params = Vec::new();
                            for param in event.inputs.iter() {
                                let param_name = param.name.to_capitalized_options();
                                let graphql_type = param.kind.to_string();
                                params.push(Param{
                                    key: param_name,
                                    graphql_type
                                });
                            }
                            events.push(Event{
                                name: event_name,
                                params
                            });
                        }
                    };
                }
                contracts.push(Contract{
                    name: contract_name,
                    events
                });
            }
        }
        Ok(AutoSchemaHandlerTemplate{
            contracts
        })
    }
}