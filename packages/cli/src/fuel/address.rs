use alloy_primitives::B256;
use anyhow::{Context, Error, Result};
use serde::{Deserialize, Serialize};
use std::{fmt::Display, str::FromStr};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Address(B256);

impl<'de> Deserialize<'de> for Address {
    fn deserialize<D>(deserializer: D) -> Result<Address, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        // Deserialize the inner B256 type and wrap it in the Address struct
        let b256 = B256::deserialize(deserializer)?;
        Ok(Address(b256))
    }
}

impl Serialize for Address {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        // Serialize as a checksummed string
        self.to_string().serialize(serializer)
    }
}

impl Address {
    pub fn new(address: &str) -> Result<Self> {
        address.parse()
    }

    pub fn as_b256(&self) -> &B256 {
        &self.0
    }
}

impl FromStr for Address {
    type Err = Error;
    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        let address = s.parse().context(format!(
            "Failed parsing {} as hexidecimal address string. Please provide a valid address",
            s
        ))?;
        Ok(Self(address))
    }
}

impl From<B256> for Address {
    fn from(address: B256) -> Self {
        Self(address)
    }
}

impl Display for Address {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // B256 Display outputs as 0x-prefixed lowercase hex
        write!(f, "{}", self.0)
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn convert_address_to_string() {
        let address_str = "0xb9bc445e5696c966dcf7e5d1237bd03c04e3ba6929bdaedfeebc7aae784c3a0b";
        let address = Address::new(address_str).unwrap();
        assert_eq!(address_str, address.to_string());
    }

    #[test]
    fn deserialize_address() {
        let address_json = r#"{"test_field": "0xb9bc445e5696c966dcf7e5d1237bd03c04e3ba6929bdaedfeebc7aae784c3a0b"}"#;
        let deserialized_map: HashMap<&str, Address> = serde_json::from_str(address_json).unwrap();
        let deserialized = deserialized_map.get("test_field").unwrap();

        let expected_address =
            Address::new("0xb9bc445e5696c966dcf7e5d1237bd03c04e3ba6929bdaedfeebc7aae784c3a0b")
                .unwrap();

        assert_eq!(&expected_address, deserialized);
    }
}
