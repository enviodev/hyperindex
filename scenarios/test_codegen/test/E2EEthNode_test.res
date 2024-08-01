open RescriptMocha

describe("E2E Integration Test", () => {
  Async.before(() => {
    DbHelpers.runUpDownMigration()
  })

  Async.after(() => {
    // It is probably overkill that we are running these 'after' also
    DbHelpers.runUpDownMigration()
  })

  Async.it("Complete E2E", async () => {
    This.timeout(5 * 1000)

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
      chain: MockConfig.chain1337,
      contracts: [
        {
          name: "GravatarRegistry",
          abi: Abis.gravatarAbi->Ethers.makeAbi,
          addresses: [
            "0x5FbDB2315678afecb367f032d93F642f64180aa3"->Ethers.getAddressFromStringUnsafe,
          ],
          events: [module(Types.Gravatar.NewGravatar), module(Types.Gravatar.UpdatedGravatar)],
        },
      ],
    }

    let config = RegisterHandlers.registerAllHandlers()

    let chainManager = Integration_ts_helpers.makeChainManager(localChainConfig)
    let loadLayer = LoadLayer.makeWithDbConnection()

    let globalState = GlobalState.make(~config, ~chainManager, ~loadLayer)

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
