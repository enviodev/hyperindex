@module("hardhat") @scope("ethers")
external hardhatProvider: Ethers.JsonRpcProvider.t = "provider"

@set external setPollingInterval: (Ethers.JsonRpcProvider.t, int) => unit = "pollingInterval"
