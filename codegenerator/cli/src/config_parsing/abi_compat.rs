//! Compatibility layer for ABI types.
//!
//! This module provides types and functions to work with Ethereum ABI data
//! using the alloy crates, while maintaining an API similar to the previous
//! ethers-based implementation.

use alloy_dyn_abi::DynSolType;
use alloy_json_abi::{
    Event as AlloyEvent, EventParam as AlloyEventParam, Param as AlloyParam,
};
use anyhow::{anyhow, Context, Result};
use std::str::FromStr;

/// A wrapper around an event parameter that provides a similar API to the old ethers EventParam.
///
/// This struct stores the parsed `DynSolType` directly, unlike alloy's `EventParam`
/// which stores the type as a string. It also preserves component names from struct
/// types, enabling generation of named object types instead of unnamed tuples.
#[derive(Debug, Clone, PartialEq)]
pub struct EventParam {
    /// The parameter's name
    pub name: String,
    /// The parameter's type
    pub kind: DynSolType,
    /// Whether the parameter is indexed
    pub indexed: bool,
    /// Named components for struct (tuple) types.
    /// When a Solidity struct is ABI-encoded, it becomes a tuple with named components.
    /// Preserving these names allows generating object types with named fields
    /// instead of positional tuple types.
    pub components: Vec<EventParam>,
}

impl EventParam {
    /// Create a new EventParam from alloy's EventParam.
    ///
    /// This parses the type string into a DynSolType and preserves component names.
    pub fn try_from_alloy(param: &AlloyEventParam) -> Result<Self> {
        let type_str = param.selector_type();
        let kind = DynSolType::parse(&type_str).with_context(|| {
            format!(
                "Failed to parse type '{}' for parameter '{}'",
                type_str, param.name
            )
        })?;
        let components = param
            .components
            .iter()
            .map(Self::try_from_alloy_param)
            .collect::<Result<Vec<_>>>()?;
        Ok(EventParam {
            name: param.name.clone(),
            kind,
            indexed: param.indexed,
            components,
        })
    }

    /// Create a new EventParam from alloy's Param (used for nested components).
    fn try_from_alloy_param(param: &AlloyParam) -> Result<Self> {
        let type_str = param.selector_type();
        let kind = DynSolType::parse(&type_str).with_context(|| {
            format!(
                "Failed to parse type '{}' for parameter '{}'",
                type_str, param.name
            )
        })?;
        let components = param
            .components
            .iter()
            .map(Self::try_from_alloy_param)
            .collect::<Result<Vec<_>>>()?;
        Ok(EventParam {
            name: param.name.clone(),
            kind,
            indexed: false,
            components,
        })
    }

    /// Create a new EventParam with the given name, type, and indexed flag.
    pub fn new(name: String, kind: DynSolType, indexed: bool) -> Self {
        Self {
            name,
            kind,
            indexed,
            components: vec![],
        }
    }
}

/// Parse an event signature string (e.g., "event Transfer(address indexed from, address indexed to, uint256 value)")
/// into an Event struct.
pub fn parse_event(sig: &str) -> Result<Event> {
    let alloy_event =
        AlloyEvent::parse(sig).map_err(|e| anyhow!("Failed to parse event signature: {}", e))?;
    Event::try_from_alloy(&alloy_event)
        .with_context(|| format!("Failed to convert event '{}'", alloy_event.name))
}

/// An event with parsed parameters.
#[derive(Debug, Clone)]
pub struct Event {
    /// The event's name
    pub name: String,
    /// The event's parameters with parsed types
    pub inputs: Vec<EventParam>,
    /// Whether the event is anonymous
    pub anonymous: bool,
}

impl Event {
    /// Create an Event from alloy's Event, returning an error if any parameter fails to parse.
    pub fn try_from_alloy(event: &AlloyEvent) -> Result<Self> {
        let inputs: Result<Vec<EventParam>> = event
            .inputs
            .iter()
            .map(|param| {
                EventParam::try_from_alloy(param)
                    .with_context(|| format!("in event '{}'", event.name))
            })
            .collect();

        Ok(Event {
            name: event.name.clone(),
            inputs: inputs?,
            anonymous: event.anonymous,
        })
    }
}

/// Parse an event parameter from a type string.
///
/// Example: "uint256" -> DynSolType::Uint(256)
pub fn parse_param_type(type_str: &str) -> Result<DynSolType> {
    DynSolType::from_str(type_str)
        .with_context(|| format!("Failed to parse parameter type '{}'", type_str))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_event() {
        let event =
            parse_event("event Transfer(address indexed from, address indexed to, uint256 value)")
                .unwrap();
        assert_eq!(event.name, "Transfer");
        assert_eq!(event.inputs.len(), 3);
        assert_eq!(event.inputs[0].name, "from");
        assert!(matches!(event.inputs[0].kind, DynSolType::Address));
        assert!(event.inputs[0].indexed);
        assert_eq!(event.inputs[2].name, "value");
        assert!(matches!(event.inputs[2].kind, DynSolType::Uint(256)));
        assert!(!event.inputs[2].indexed);
    }

    #[test]
    fn test_parse_event_with_tuple() {
        let event = parse_event("event MyEvent((uint256, bool) data)").unwrap();
        assert_eq!(event.name, "MyEvent");
        assert_eq!(event.inputs.len(), 1);
        assert!(matches!(event.inputs[0].kind, DynSolType::Tuple(_)));
        // Unnamed tuple components should have empty names
        assert_eq!(event.inputs[0].components.len(), 2);
        assert_eq!(event.inputs[0].components[0].name, "");
        assert_eq!(event.inputs[0].components[1].name, "");
    }

    #[test]
    fn test_parse_event_with_named_tuple_components() {
        // Simulates a struct with named fields parsed from JSON ABI
        use alloy_json_abi::{Event as AlloyEvent, EventParam as AlloyEventParam, Param};

        let alloy_event = AlloyEvent {
            name: "MyEvent".to_string(),
            inputs: vec![AlloyEventParam {
                ty: "tuple".to_string(),
                name: "data".to_string(),
                indexed: false,
                components: vec![
                    Param {
                        ty: "address".to_string(),
                        name: "funder".to_string(),
                        components: vec![],
                        internal_type: None,
                    },
                    Param {
                        ty: "uint256".to_string(),
                        name: "amount".to_string(),
                        components: vec![],
                        internal_type: None,
                    },
                ],
                internal_type: None,
            }],
            anonymous: false,
        };

        let event = Event::try_from_alloy(&alloy_event).unwrap();
        assert_eq!(event.inputs.len(), 1);
        assert_eq!(event.inputs[0].components.len(), 2);
        assert_eq!(event.inputs[0].components[0].name, "funder");
        assert_eq!(event.inputs[0].components[1].name, "amount");
    }

    #[test]
    fn test_parse_param_type() {
        let uint_type = parse_param_type("uint256").unwrap();
        assert!(matches!(uint_type, DynSolType::Uint(256)));

        let address_type = parse_param_type("address").unwrap();
        assert!(matches!(address_type, DynSolType::Address));

        let tuple_type = parse_param_type("(uint256,bool)").unwrap();
        assert!(matches!(tuple_type, DynSolType::Tuple(_)));
    }
}
