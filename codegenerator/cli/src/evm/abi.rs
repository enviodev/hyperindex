use serde::Deserialize;

#[derive(Deserialize)]
#[serde(untagged)]
pub enum AbiOrNestedAbi {
    Abi(ethers::abi::Abi),
    // This is a case for Hardhat or Foundry generated ABI files
    NestedAbi { abi: ethers::abi::Abi },
}
