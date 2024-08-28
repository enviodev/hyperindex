use anyhow::{Context, Error, Result};
use ethers::{types::H160, utils::to_checksum};
use serde::{Deserialize, Serialize};
use std::{fmt::Display, str::FromStr};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Address(H160);

impl<'de> Deserialize<'de> for Address {
    fn deserialize<D>(deserializer: D) -> Result<Address, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        // Deserialize the inner H160 type and wrap it in the Address struct
        let h160 = H160::deserialize(deserializer)?;
        Ok(Address(h160))
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

    pub fn to_checksum_hex_string(&self) -> String {
        to_checksum(&self.0, None)
    }

    pub fn as_h160(&self) -> &H160 {
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

impl From<H160> for Address {
    fn from(address: H160) -> Self {
        Self(address)
    }
}

impl Display for Address {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.to_checksum_hex_string())
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn convert_address_to_checksum_string() {
        let address_str = "0x85149247691df622eaf1a8bd0cafd40bc45154a9";
        let address = Address::new(address_str).unwrap();
        assert_eq!(
            address.to_string(),
            "0x85149247691df622eaF1a8Bd0CaFd40BC45154a9"
        );
        assert_eq!(
            address.to_checksum_hex_string(),
            "0x85149247691df622eaF1a8Bd0CaFd40BC45154a9"
        ); //same as to_string
    }

    #[test]
    fn deserialize_address() {
        let address_json = r#"{"test_field": "0x6B175474E89094C44Da98b954EedeAC495271d0F"}"#;
        let deserialized_map: HashMap<&str, Address> = serde_json::from_str(address_json).unwrap();
        let deserialized = deserialized_map.get("test_field").unwrap();

        let expected_address = Address::new("0x6B175474E89094C44Da98b954EedeAC495271d0F").unwrap();

        assert_eq!(&expected_address, deserialized);
    }
}
