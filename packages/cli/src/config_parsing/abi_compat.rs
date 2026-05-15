//! Compatibility layer for ABI types.
//!
//! This module provides types and functions to work with Ethereum ABI data
//! using the alloy crates, while maintaining an API similar to the previous
//! ethers-based implementation.

use alloy_dyn_abi::DynSolType;
use alloy_json_abi::{Event as AlloyEvent, EventParam as AlloyEventParam, Param as AlloyParam};
use anyhow::{anyhow, Context, Result};
use std::str::FromStr;

/// Recursive representation of an ABI type that preserves named struct components.
///
/// Unlike `DynSolType` (which only knows positional tuples), `AbiType::Tuple` carries
/// the component names from the JSON ABI, so struct params can be rendered as records
/// with named fields.
#[derive(Debug, Clone, PartialEq)]
pub enum AbiType {
    Bool,
    Uint(usize),
    Int(usize),
    Address,
    String,
    Bytes,
    FixedBytes(usize),
    Function,
    Array(Box<AbiType>),
    FixedArray(Box<AbiType>, usize),
    Tuple(Vec<AbiTupleField>),
}

/// A named (or unnamed) field of a tuple/struct ABI type.
#[derive(Debug, Clone, PartialEq)]
pub struct AbiTupleField {
    /// The component name from the JSON ABI. `None` if the ABI did not provide one
    /// (e.g. when parsing a bare event signature string).
    pub name: Option<String>,
    pub kind: AbiType,
}

impl AbiType {
    /// Build an `AbiType` from an `alloy_json_abi::Param`, walking components to
    /// preserve named struct fields.
    pub fn from_alloy_param(param: &AlloyParam) -> Result<Self> {
        Self::from_ty_and_components(&param.ty, &param.components).with_context(|| {
            format!(
                "Failed to parse ABI type '{}' for parameter '{}'",
                param.ty, param.name
            )
        })
    }

    /// Build an `AbiType` from an `alloy_json_abi::EventParam`.
    pub fn from_alloy_event_param(param: &AlloyEventParam) -> Result<Self> {
        Self::from_ty_and_components(&param.ty, &param.components).with_context(|| {
            format!(
                "Failed to parse ABI type '{}' for event parameter '{}'",
                param.ty, param.name
            )
        })
    }

    fn from_ty_and_components(ty: &str, components: &[AlloyParam]) -> Result<Self> {
        // Strip any trailing array suffixes (e.g. `tuple[]`, `tuple[3]`, `uint256[][2]`)
        // and wrap the inner type in Array/FixedArray accordingly.
        let trimmed = ty.trim();
        if trimmed.ends_with(']') {
            let open = trimmed
                .rfind('[')
                .ok_or_else(|| anyhow!("Malformed array type '{}'", ty))?;
            let base = &trimmed[..open];
            let size_str = &trimmed[open + 1..trimmed.len() - 1];
            let inner = Self::from_ty_and_components(base, components)?;
            if size_str.is_empty() {
                return Ok(AbiType::Array(Box::new(inner)));
            } else {
                let size: usize = size_str
                    .parse()
                    .with_context(|| format!("Invalid fixed-array size in '{}'", ty))?;
                return Ok(AbiType::FixedArray(Box::new(inner), size));
            }
        }

        if trimmed == "tuple" {
            let fields = components
                .iter()
                .map(|c| {
                    Ok(AbiTupleField {
                        name: if c.name.is_empty() {
                            None
                        } else {
                            Some(c.name.clone())
                        },
                        kind: Self::from_alloy_param(c)?,
                    })
                })
                .collect::<Result<Vec<_>>>()?;
            return Ok(AbiType::Tuple(fields));
        }

        // Leaf: parse via DynSolType and convert.
        let dyn_ty = DynSolType::parse(trimmed)
            .with_context(|| format!("Failed to parse leaf ABI type '{}'", ty))?;
        Self::from_dyn_sol_type(&dyn_ty)
    }

    /// Convert a `DynSolType` (no component names) into an `AbiType` with all tuple
    /// fields unnamed. Used as a fallback for bare signature strings.
    pub fn from_dyn_sol_type(ty: &DynSolType) -> Result<Self> {
        Ok(match ty {
            DynSolType::Bool => AbiType::Bool,
            DynSolType::Uint(n) => AbiType::Uint(*n),
            DynSolType::Int(n) => AbiType::Int(*n),
            DynSolType::Address => AbiType::Address,
            DynSolType::String => AbiType::String,
            DynSolType::Bytes => AbiType::Bytes,
            DynSolType::FixedBytes(n) => AbiType::FixedBytes(*n),
            DynSolType::Function => AbiType::Function,
            DynSolType::Array(inner) => AbiType::Array(Box::new(Self::from_dyn_sol_type(inner)?)),
            DynSolType::FixedArray(inner, n) => {
                AbiType::FixedArray(Box::new(Self::from_dyn_sol_type(inner)?), *n)
            }
            DynSolType::Tuple(items) => AbiType::Tuple(
                items
                    .iter()
                    .map(|t| {
                        Ok(AbiTupleField {
                            name: None,
                            kind: Self::from_dyn_sol_type(t)?,
                        })
                    })
                    .collect::<Result<Vec<_>>>()?,
            ),
        })
    }

    /// Drop tuple component names. Used by call sites that still operate on
    /// `DynSolType` (topic encoding, contract-import flattening).
    pub fn to_dyn_sol_type(&self) -> DynSolType {
        match self {
            AbiType::Bool => DynSolType::Bool,
            AbiType::Uint(n) => DynSolType::Uint(*n),
            AbiType::Int(n) => DynSolType::Int(*n),
            AbiType::Address => DynSolType::Address,
            AbiType::String => DynSolType::String,
            AbiType::Bytes => DynSolType::Bytes,
            AbiType::FixedBytes(n) => DynSolType::FixedBytes(*n),
            AbiType::Function => DynSolType::Function,
            AbiType::Array(inner) => DynSolType::Array(Box::new(inner.to_dyn_sol_type())),
            AbiType::FixedArray(inner, n) => {
                DynSolType::FixedArray(Box::new(inner.to_dyn_sol_type()), *n)
            }
            AbiType::Tuple(fields) => {
                DynSolType::Tuple(fields.iter().map(|f| f.kind.to_dyn_sol_type()).collect())
            }
        }
    }

    /// Canonical Solidity signature string for this type (tuple components expanded).
    /// E.g. `(address,uint256,(bool,string)[])`.
    pub fn to_signature_string(&self) -> String {
        self.to_dyn_sol_type().to_string()
    }
}

/// A wrapper around an event parameter that provides a similar API to the old ethers EventParam.
#[derive(Debug, Clone, PartialEq)]
pub struct EventParam {
    /// The parameter's name
    pub name: String,
    /// The parameter's type (preserves struct component names)
    pub kind: AbiType,
    /// Whether the parameter is indexed
    pub indexed: bool,
}

impl EventParam {
    /// Create a new EventParam from alloy's EventParam, preserving component names.
    pub fn try_from_alloy(param: &AlloyEventParam) -> Result<Self> {
        Ok(EventParam {
            name: param.name.clone(),
            kind: AbiType::from_alloy_event_param(param)?,
            indexed: param.indexed,
        })
    }
}

/// Parse an event signature string (e.g., "event Transfer(address indexed from, address indexed to, uint256 value)")
/// into an Event struct.
pub fn parse_event(sig: &str) -> Result<Event> {
    let alloy_event = parse_event_signature_to_alloy(sig)?;
    Event::try_from_alloy(&alloy_event)
        .with_context(|| format!("Failed to convert event '{}'", alloy_event.name))
}

/// Parse a human-readable event signature into an `AlloyEvent`.
///
/// Accepts component names inside tuple types (`event E((uint a, uint b) data)`),
/// which alloy's own signature parser rejects. `components` are populated so
/// downstream selector and ABI consumers see the named fields.
pub fn parse_event_signature_to_alloy(sig: &str) -> Result<AlloyEvent> {
    sig_parser::parse(sig)
}

/// Human-readable event signature parser.
///
/// Grammar: `[event] Name(param,*)[ anonymous]` where each param is
/// `type [indexed] [name]` and `type` is either a leaf identifier, a tuple
/// `(component,*)`, or any of those followed by array suffixes.
/// Tuple components allow names; top-level params allow `indexed`.
mod sig_parser {
    use super::{AlloyEvent, AlloyEventParam, AlloyParam};
    use anyhow::{anyhow, bail, Context, Result};

    pub fn parse(sig: &str) -> Result<AlloyEvent> {
        let mut p = Cursor::new(sig);
        p.skip_ws();
        if p.try_keyword("event") {
            p.skip_ws();
        }
        let name = p
            .ident()
            .ok_or_else(|| anyhow!("expected event name in '{}'", sig))?
            .to_string();
        p.skip_ws();
        p.expect('(', sig)?;
        let mut inputs = Vec::new();
        p.skip_ws();
        if !p.peek_is(')') {
            loop {
                inputs.push(parse_event_param(&mut p, sig)?);
                p.skip_ws();
                if p.peek_is(',') {
                    p.bump();
                    p.skip_ws();
                    continue;
                }
                break;
            }
        }
        p.expect(')', sig)?;
        p.skip_ws();
        let anonymous = p.try_keyword("anonymous");
        p.skip_ws();
        if !p.eof() {
            bail!(
                "unexpected trailing input '{}' in event signature '{}'",
                p.rest(),
                sig
            );
        }
        Ok(AlloyEvent {
            name,
            inputs,
            anonymous,
        })
    }

    fn parse_event_param(p: &mut Cursor, sig: &str) -> Result<AlloyEventParam> {
        p.skip_ws();
        let (ty, components) = parse_type(p, sig)?;
        p.skip_ws();
        let indexed = p.try_keyword("indexed");
        if indexed {
            p.skip_ws();
        }
        let name = p.ident().unwrap_or("").to_string();
        Ok(AlloyEventParam {
            name,
            ty,
            indexed,
            components,
            internal_type: None,
        })
    }

    fn parse_param(p: &mut Cursor, sig: &str) -> Result<AlloyParam> {
        p.skip_ws();
        let (ty, components) = parse_type(p, sig)?;
        p.skip_ws();
        let name = p.ident().unwrap_or("").to_string();
        Ok(AlloyParam {
            name,
            ty,
            components,
            internal_type: None,
        })
    }

    fn parse_type(p: &mut Cursor, sig: &str) -> Result<(String, Vec<AlloyParam>)> {
        p.skip_ws();
        let (mut base_ty, components) = if p.peek_is('(') {
            p.bump();
            let mut comps = Vec::new();
            p.skip_ws();
            if !p.peek_is(')') {
                loop {
                    comps.push(parse_param(p, sig)?);
                    p.skip_ws();
                    if p.peek_is(',') {
                        p.bump();
                        p.skip_ws();
                        continue;
                    }
                    break;
                }
            }
            p.expect(')', sig)?;
            ("tuple".to_string(), comps)
        } else {
            let leaf = p
                .ident()
                .ok_or_else(|| anyhow!("expected type in event signature '{}'", sig))?
                .to_string();
            (leaf, Vec::new())
        };
        loop {
            p.skip_ws();
            if !p.peek_is('[') {
                break;
            }
            p.bump();
            p.skip_ws();
            if p.peek_is(']') {
                p.bump();
                base_ty.push_str("[]");
            } else {
                let n = p
                    .digits()
                    .ok_or_else(|| anyhow!("expected array size or ']' in '{}'", sig))?;
                let size: usize = n
                    .parse()
                    .with_context(|| format!("invalid array size '{}' in '{}'", n, sig))?;
                p.skip_ws();
                p.expect(']', sig)?;
                base_ty.push('[');
                base_ty.push_str(&size.to_string());
                base_ty.push(']');
            }
        }
        Ok((base_ty, components))
    }

    struct Cursor<'a> {
        src: &'a str,
        pos: usize,
    }

    impl<'a> Cursor<'a> {
        fn new(src: &'a str) -> Self {
            Self { src, pos: 0 }
        }
        fn rest(&self) -> &'a str {
            &self.src[self.pos..]
        }
        fn eof(&self) -> bool {
            self.pos >= self.src.len()
        }
        fn peek(&self) -> Option<char> {
            self.rest().chars().next()
        }
        fn peek_is(&self, c: char) -> bool {
            self.peek() == Some(c)
        }
        fn bump(&mut self) -> Option<char> {
            let c = self.peek()?;
            self.pos += c.len_utf8();
            Some(c)
        }
        fn skip_ws(&mut self) {
            while matches!(self.peek(), Some(c) if c.is_whitespace()) {
                self.bump();
            }
        }
        fn expect(&mut self, c: char, sig: &str) -> Result<()> {
            match self.peek() {
                Some(actual) if actual == c => {
                    self.bump();
                    Ok(())
                }
                Some(actual) => bail!(
                    "expected '{}' but found '{}' in event signature '{}'",
                    c,
                    actual,
                    sig
                ),
                None => bail!(
                    "expected '{}' but reached end of event signature '{}'",
                    c,
                    sig
                ),
            }
        }
        fn ident(&mut self) -> Option<&'a str> {
            let s = self.rest();
            let mut iter = s.char_indices();
            let (_, first) = iter.next()?;
            if !(first.is_ascii_alphabetic() || first == '_' || first == '$') {
                return None;
            }
            let mut end = first.len_utf8();
            for (_, c) in iter {
                if c.is_ascii_alphanumeric() || c == '_' || c == '$' {
                    end += c.len_utf8();
                } else {
                    break;
                }
            }
            let out = &s[..end];
            self.pos += end;
            Some(out)
        }
        fn try_keyword(&mut self, kw: &str) -> bool {
            let mark = self.pos;
            if let Some(id) = self.ident() {
                if id == kw {
                    return true;
                }
            }
            self.pos = mark;
            false
        }
        fn digits(&mut self) -> Option<&'a str> {
            let s = self.rest();
            let mut end = 0;
            for c in s.chars() {
                if c.is_ascii_digit() {
                    end += c.len_utf8();
                } else {
                    break;
                }
            }
            if end == 0 {
                return None;
            }
            let out = &s[..end];
            self.pos += end;
            Some(out)
        }
    }
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
        assert!(matches!(event.inputs[0].kind, AbiType::Address));
        assert!(event.inputs[0].indexed);
        assert_eq!(event.inputs[2].name, "value");
        assert!(matches!(event.inputs[2].kind, AbiType::Uint(256)));
        assert!(!event.inputs[2].indexed);
    }

    #[test]
    fn test_parse_event_with_tuple() {
        // Bare signatures have no component names, so tuple fields are unnamed.
        let event = parse_event("event MyEvent((uint256, bool) data)").unwrap();
        assert_eq!(event.name, "MyEvent");
        assert_eq!(event.inputs.len(), 1);
        match &event.inputs[0].kind {
            AbiType::Tuple(fields) => {
                assert_eq!(fields.len(), 2);
                assert!(fields.iter().all(|f| f.name.is_none()));
                assert!(matches!(fields[0].kind, AbiType::Uint(256)));
                assert!(matches!(fields[1].kind, AbiType::Bool));
            }
            _ => panic!("expected tuple"),
        }
    }

    #[test]
    fn test_json_abi_struct_preserves_component_names() {
        // Build a JSON ABI event with a named struct param and verify component
        // names survive into AbiType.
        let abi_json = r#"[{
            "type": "event",
            "name": "CreateStream",
            "anonymous": false,
            "inputs": [
                {
                    "name": "commonParams",
                    "type": "tuple",
                    "indexed": false,
                    "components": [
                        { "name": "funder", "type": "address", "components": [] },
                        { "name": "recipient", "type": "address", "components": [] },
                        {
                            "name": "timestamps",
                            "type": "tuple",
                            "components": [
                                { "name": "start", "type": "uint256", "components": [] },
                                { "name": "end", "type": "uint256", "components": [] }
                            ]
                        }
                    ]
                },
                {
                    "name": "tranches",
                    "type": "tuple[]",
                    "indexed": false,
                    "components": [
                        { "name": "amount", "type": "uint256", "components": [] },
                        { "name": "timestamp", "type": "uint256", "components": [] }
                    ]
                }
            ]
        }]"#;
        let abi: alloy_json_abi::JsonAbi = serde_json::from_str(abi_json).unwrap();
        let alloy_event = abi.events().next().unwrap();
        let event = Event::try_from_alloy(alloy_event).unwrap();
        assert_eq!(event.inputs.len(), 2);

        match &event.inputs[0].kind {
            AbiType::Tuple(fields) => {
                assert_eq!(
                    fields.iter().map(|f| f.name.as_deref()).collect::<Vec<_>>(),
                    vec![Some("funder"), Some("recipient"), Some("timestamps")]
                );
                match &fields[2].kind {
                    AbiType::Tuple(inner) => {
                        assert_eq!(
                            inner.iter().map(|f| f.name.as_deref()).collect::<Vec<_>>(),
                            vec![Some("start"), Some("end")]
                        );
                    }
                    _ => panic!("expected nested tuple"),
                }
            }
            _ => panic!("expected tuple for commonParams"),
        }

        match &event.inputs[1].kind {
            AbiType::Array(inner) => match inner.as_ref() {
                AbiType::Tuple(fields) => {
                    assert_eq!(
                        fields.iter().map(|f| f.name.as_deref()).collect::<Vec<_>>(),
                        vec![Some("amount"), Some("timestamp")]
                    );
                }
                _ => panic!("expected array of tuple"),
            },
            _ => panic!("expected array for tranches"),
        }
    }

    #[test]
    fn sablier_real_abi_shape() {
        // End-to-end check that the real Sablier V2 LockupTranched ABI parses
        // into the expected `AbiType::Tuple` tree with component names preserved
        // (including the `tuple[]` array-of-struct for `tranches`). Guards
        // against regressions in the alloy ABI integration and the `tuple[]`
        // branch of `AbiType::from_alloy_param`.
        let abi_json = include_str!("../../test/abis/sablier-lockup-tranched.json");
        let parsed: serde_json::Value = serde_json::from_str(abi_json).unwrap();
        let abi_array = parsed.get("abi").unwrap().clone();
        let abi: alloy_json_abi::JsonAbi = serde_json::from_value(abi_array).unwrap();
        let alloy_event = abi
            .events()
            .find(|e| e.name == "CreateLockupTranchedStream")
            .expect("CreateLockupTranchedStream event");
        let event = Event::try_from_alloy(alloy_event).unwrap();

        let param_names: Vec<&str> = event.inputs.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(
            param_names,
            vec![
                "streamId",
                "funder",
                "sender",
                "recipient",
                "amounts",
                "asset",
                "cancelable",
                "transferable",
                "tranches",
                "timestamps",
                "broker"
            ]
        );

        // `amounts` is a named struct `(uint128 deposit, uint128 brokerFee)`.
        let amounts = &event.inputs[4];
        assert_eq!(amounts.name, "amounts");
        match &amounts.kind {
            AbiType::Tuple(fields) => {
                assert_eq!(
                    fields
                        .iter()
                        .map(|f| (f.name.as_deref(), &f.kind))
                        .collect::<Vec<_>>(),
                    vec![
                        (Some("deposit"), &AbiType::Uint(128)),
                        (Some("brokerFee"), &AbiType::Uint(128)),
                    ]
                );
            }
            _ => panic!("expected tuple for amounts"),
        }

        // `tranches` is `tuple[]` — `Array(Box<Tuple>)` with component names
        // preserved on the inner tuple.
        let tranches = &event.inputs[8];
        assert_eq!(tranches.name, "tranches");
        match &tranches.kind {
            AbiType::Array(inner) => match inner.as_ref() {
                AbiType::Tuple(fields) => {
                    assert_eq!(
                        fields
                            .iter()
                            .map(|f| (f.name.as_deref(), &f.kind))
                            .collect::<Vec<_>>(),
                        vec![
                            (Some("amount"), &AbiType::Uint(128)),
                            (Some("timestamp"), &AbiType::Uint(40)),
                        ]
                    );
                }
                _ => panic!("expected array of tuple"),
            },
            _ => panic!("expected array for tranches"),
        }

        // `timestamps` is a named struct `(uint40 start, uint40 end)`.
        let timestamps = &event.inputs[9];
        assert_eq!(timestamps.name, "timestamps");
        match &timestamps.kind {
            AbiType::Tuple(fields) => {
                assert_eq!(
                    fields
                        .iter()
                        .map(|f| (f.name.as_deref(), &f.kind))
                        .collect::<Vec<_>>(),
                    vec![
                        (Some("start"), &AbiType::Uint(40)),
                        (Some("end"), &AbiType::Uint(40)),
                    ]
                );
            }
            _ => panic!("expected tuple for timestamps"),
        }
    }

    #[test]
    fn test_parse_event_with_named_nested_tuple_from_issue_1206() {
        // Regression test for https://github.com/enviodev/hyperindex/issues/1206.
        // Custom event signatures with named tuple components were rejected by
        // alloy's signature parser, so codegen failed when no `abi_file_path`
        // was provided. The fallback parser in `parse_event_signature_to_alloy`
        // accepts these and propagates the field names.
        let sig = "event ConsumeBoostVial(address from, uint256 playerId, (uint40 a, uint24 b, uint16 c, uint16 d, uint8 e) playerBoostInfo)";
        let event = parse_event(sig).expect("custom event signature with named tuple should parse");
        let tuple_field = event
            .inputs
            .iter()
            .find(|p| p.name == "playerBoostInfo")
            .expect("playerBoostInfo input");
        let tuple_fields = match &tuple_field.kind {
            AbiType::Tuple(fields) => fields,
            other => panic!("expected Tuple, got {:?}", other),
        };
        assert_eq!(
            tuple_fields
                .iter()
                .map(|f| (f.name.as_deref(), f.kind.clone()))
                .collect::<Vec<_>>(),
            vec![
                (Some("a"), AbiType::Uint(40)),
                (Some("b"), AbiType::Uint(24)),
                (Some("c"), AbiType::Uint(16)),
                (Some("d"), AbiType::Uint(16)),
                (Some("e"), AbiType::Uint(8)),
            ]
        );
    }

    #[test]
    fn test_parse_event_with_named_tuple_array_and_indexed() {
        // Mixed: tuple[] with named components, plus indexed scalar.
        let sig = "event Trade((uint128 amount, uint16 fee)[] items, address indexed trader)";
        let event = parse_event(sig).expect("named tuple[] should parse");
        assert_eq!(event.name, "Trade");
        assert_eq!(event.inputs.len(), 2);
        match &event.inputs[0].kind {
            AbiType::Array(inner) => match inner.as_ref() {
                AbiType::Tuple(fields) => assert_eq!(
                    fields
                        .iter()
                        .map(|f| (f.name.as_deref(), f.kind.clone()))
                        .collect::<Vec<_>>(),
                    vec![
                        (Some("amount"), AbiType::Uint(128)),
                        (Some("fee"), AbiType::Uint(16)),
                    ]
                ),
                other => panic!("expected tuple inside array, got {:?}", other),
            },
            other => panic!("expected array, got {:?}", other),
        }
        assert_eq!(event.inputs[1].name, "trader");
        assert!(event.inputs[1].indexed);
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
