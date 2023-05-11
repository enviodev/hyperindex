open RescriptMocha
module MochaPromise = RescriptMocha.Promise
open Mocha

describe("E2E Mock Event Batch", () => {
  MochaPromise.before(async () => {
    await Migrations.runDownMigrations()
    await Migrations.runUpMigrations()
  })

  MochaPromise.after(async () => {
    await Migrations.runDownMigrations()
    await Migrations.runUpMigrations()
  })

  MochaPromise.it("Complete E2E", ~timeout=10000, async () => {
    let gravatar = await SetupRpcNode.deployContract()
    await SetupRpcNode.setupNodeAndContracts(gravatar)
    let provider = Hardhat.hardhatProvider
    let localChainConfig: Config.chainConfig = {
      provider,
      startBlock: 0,
      chainId: 1337,
      contracts: [
        {
          name: "GravatarRegistry",
          abi: Abis.gravatarAbi->Ethers.makeAbi,
          address: "0x5FbDB2315678afecb367f032d93F642f64180aa3"->Ethers.getAddressFromStringUnsafe,
          events: [GravatarContract_NewGravatarEvent, GravatarContract_UpdatedGravatarEvent],
        },
      ],
    }

    RegisterHandlers.registerAllHandlers()
    await localChainConfig->EventSyncing.processAllEvents

    Js.log("starting events subscription")
    let _ = EventSubscription.startWatchingEventsOnRpc(~chainConfig=localChainConfig, ~provider)
    Js.log("submitting transactions")
    await LiveGravatarTask.liveGravatarTxs(gravatar)
    Js.log("finish transactions")
    await Time.resolvePromiseAfterDelay(~delayMilliseconds=5000)
    Js.log("finished")
  })
})
