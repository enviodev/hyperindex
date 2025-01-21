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
      let contracts = [
        {
          Config.name: "GravatarRegistry",
          abi: Types.Gravatar.abi,
          addresses: ["0x5FbDB2315678afecb367f032d93F642f64180aa3"->Address.Evm.fromStringOrThrow],
          events: [module(Types.Gravatar.NewGravatar), module(Types.Gravatar.UpdatedGravatar)],
        },
      ]
      let chain = MockConfig.chain1337
      {
        confirmedBlockThreshold: 200,
        syncSource: Rpc,
        startBlock: 0,
        endBlock: None,
        chain,
        contracts,
        source: module(
          RpcWorker.Make({
            let chain = chain
            let contracts = contracts
            let syncConfig: Config.syncConfig = {
              initialBlockInterval: 10000,
              backoffMultiplicative: 10000.0,
              accelerationAdditive: 10000,
              intervalCeiling: 10000,
              backoffMillis: 10000,
              queryTimeoutMillis: 10000,
            }
            let provider = provider
            let eventRouter =
              contracts
              ->Belt.Array.flatMap(contract => contract.events)
              ->EventRouter.fromEvmEventModsOrThrow(~chain)
          })
        ),
      }
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
