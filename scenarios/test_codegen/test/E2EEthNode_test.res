open RescriptMocha
module MochaPromise = RescriptMocha.Promise
open Mocha

@@warning("-21")
let resetPostgresClient: unit => unit = () => {
  // This is a hack to reset the postgres client between tests. postgres.js seems to cache some types, and if tests clear the DB you need to also reset sql.

  %raw(
    "require('../generated/src/DbFunctions.bs.js').sql = require('postgres')(require('../generated/src/Config.bs.js').db)"
  )
}

describe("E2E Integration Test", () => {
  MochaPromise.before(async () => {
    resetPostgresClient()
    (await Migrations.runDownMigrations(~shouldExit=false, ~shouldDropRawEvents=true))->ignore
    (await Migrations.runUpMigrations(~shouldExit=false))->ignore
  })

  MochaPromise.after(async () => {
    (await Migrations.runDownMigrations(~shouldExit=false, ~shouldDropRawEvents=true))->ignore
    (await Migrations.runUpMigrations(~shouldExit=false))->ignore
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
      chainId: 1337,
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

    let chainManager = ChainManager.make(
      ~configs=[(localChainConfig.chainId->Belt.Int.toString, localChainConfig)]->Js.Dict.fromArray,
      ~maxQueueSize=100,
      ~shouldSyncFromRawEvents=false,
    )

    chainManager->ChainManager.startFetchers

    EventSyncing.startSyncingAllEvents(~shouldSyncFromRawEvents=false)

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
