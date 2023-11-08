use anyhow::{Context, Error, Result};
use ethers::{
    types::H160,
    utils::{
        hex::{encode_prefixed, encode_upper_prefixed},
        to_checksum,
    },
};
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

//Allowing dead code for these implementations since they function as library methods
#[allow(dead_code)]
impl Address {
    pub fn new(address: &str) -> Result<Self> {
        address.parse()
    }

    pub fn to_checksum_hex_string(&self) -> String {
        to_checksum(&self.0, None)
    }

    pub fn to_upper_hex_string(&self) -> String {
        encode_upper_prefixed(self.0)
    }

    pub fn to_lower_hex_string(&self) -> String {
        encode_prefixed(self.0)
    }

    pub fn as_h160(&self) -> &H160 {
        &self.0
    }
}

impl FromStr for Address {
    type Err = Error;
    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        let address = s
            .parse()
            .context("Failed parsing address string {} as H160")?;
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
        let address_str = "0x6B175474E89094C44Da98b954EedeAC495271d0F";
        let address: Address = address_str.parse().unwrap();
        assert_eq!(address_str, address.to_string());
        assert_eq!(address_str, address.to_checksum_hex_string()); //same as above
        assert_eq!(address_str.to_lowercase(), address.to_lower_hex_string());
        assert_eq!(
            //remove the 0x for this test because x statys lower in the upper hex string
            address_str.to_uppercase()[2..],
            address.to_upper_hex_string()[2..]
        );
    }

    #[test]
    fn deserialize_address() {
        let address_json = r#"{"test_field": "0x6B175474E89094C44Da98b954EedeAC495271d0F"}"#;
        let deserialized_map: HashMap<&str, Address> = serde_json::from_str(address_json).unwrap();
        let deserialized = deserialized_map.get("test_field").unwrap();

        let expected_address: Address = "0x6B175474E89094C44Da98b954EedeAC495271d0F"
            .parse()
            .unwrap();

        assert_eq!(&expected_address, deserialized);
    }
}
