open RescriptMocha
module MochaPromise = RescriptMocha.Promise
open Mocha

describe("E2E Integration Test", () => {
  MochaPromise.before(async () => {
    await DbHelpers.runUpDownMigration()
  })

  MochaPromise.after(async () => {
    // It is probably overkill that we are running these 'after' also
    await DbHelpers.runUpDownMigration()
  })

  MochaPromise.it("Complete E2E", ~timeout=5 * 1000, async () => {
    let contracts = await SetupRpcNode.deployContracts()
    await SetupRpcNode.runBasicGravatarTransactions(contracts.gravatar)
    let provider = Hardhat.hardhatProvider
    let localChainConfig: Config.chainConfig = {
      confirmedBlockThreshold: 200,
      syncSource: Rpc({
        provider,
        syncConfig: {
          initialBlockInterval: 10000,
          backoffMultiplicative: 10000.0,
          accelerationAdditive: 10000,
          intervalCeiling: 10000,
          backoffMillis: 10000,
          queryTimeoutMillis: 10000,
        },
      }),
      startBlock: 0,
      endBlock: None,
      chain: Chain_1337,
      contracts: [
        {
          name: "GravatarRegistry",
          abi: Abis.gravatarAbi->Ethers.makeAbi,
          addresses: [
            "0x5FbDB2315678afecb367f032d93F642f64180aa3"->Ethers.getAddressFromStringUnsafe,
          ],
          events: [Gravatar_NewGravatar, Gravatar_UpdatedGravatar],
        },
      ],
    }

    RegisterHandlers.registerAllHandlers()

    let chainManager = Integration_ts_helpers.makeChainManager(localChainConfig)

    let globalState: GlobalState.t = {
      currentlyProcessingBatch: false,
      chainManager,
      maxBatchSize: Env.maxProcessBatchSize,
      maxPerChainQueueSize: {
        let numChains = Config.config->ChainMap.size
        Env.maxEventFetchedQueueSize / numChains
      },
      indexerStartTime: Js.Date.make(),
      rollbackState: NoRollback,
      id: 0,
    }

    let gsManager = globalState->GlobalStateManager.make

    gsManager->GlobalStateManager.dispatchTask(NextQuery(CheckAllChains))
    gsManager->GlobalStateManager.dispatchTask(ProcessEventBatch)

    //Note this isn't working. Something to do with the polling on hardhat eth node
    //Would be better to spin up a local node with ganache
    Js.log("starting events subscription, (This is not yet working)")
    // let _ = EventSubscription.startWatchingEventsOnRpc(~chainConfig=localChainConfig, ~provider)
    Js.log("submitting transactions")
    await LiveGravatarTask.liveGravatarTxs(contracts.gravatar)
    Js.log("finish transactions")
    // await Time.resolvePromiseAfterDelay(~delayMilliseconds=5000)
    Js.log("finished")
  })
})
