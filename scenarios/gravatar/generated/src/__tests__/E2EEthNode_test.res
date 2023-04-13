open Jest
/* open Expect */

describe("E2E Mock Event Batch", () => {
  beforeAllPromise(() => {
    SetupRpcNode.setupNodeAndContracts()
  }, ~timeout=60000)

  testPromise("Complete E2E", async () => {
    let localChainConfig: Config.chainConfig = {
      provider: Hardhat.hardhatProvider,
      startBlock: 0,
      contracts: [
        {
          name: "GravatarRegistry",
          abi: Abis.gravatarAbi->Ethers.makeAbi,
          address: "0x5FbDB2315678afecb367f032d93F642f64180aa3"->Ethers.getAddressFromStringUnsafe,
          events: ["NewGravatar, UpdateGravatar"],
        },
      ],
    }

    await localChainConfig->EventSyncing.processAllEvents
    pass
  })
})
