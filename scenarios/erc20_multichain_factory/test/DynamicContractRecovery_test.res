open Belt
open RescriptMocha

let config = RegisterHandlers.getConfig()

module Mock = {
  let makeTransferMock = (~from, ~to, ~value): Types.ERC20.Transfer.eventArgs => {
    from,
    to,
    value: value->BigInt.fromInt,
  }

  let makeTokenCreatedMock = (~token): Types.ERC20Factory.TokenCreated.eventArgs => {
    token: token,
  }

  let mintAddress = Ethers.Constants.zeroAddress
  let userAddress1 = Ethers.Addresses.mockAddresses[1]->Option.getExn

  let mockDynamicToken1 = Ethers.Addresses.mockAddresses[3]->Option.getExn
  let mockDynamicToken2 = Ethers.Addresses.mockAddresses[4]->Option.getExn

  let deployToken1 = makeTokenCreatedMock(~token=mockDynamicToken1)
  let deployToken2 = makeTokenCreatedMock(~token=mockDynamicToken2)

  let mint50ToUser1 = makeTransferMock(~from=mintAddress, ~to=userAddress1, ~value=50)

  //mock transfers from user 2 to user 1
  let addBlocksOfTransferEvents = (
    blocksOfTransferEventParams,
    ~mockChainData,
    ~mkTransferEventConstr,
  ) =>
    blocksOfTransferEventParams->Array.reduce(mockChainData, (accum, next) => {
      let makeLogConstructors = next->Array.map(mkTransferEventConstr)
      accum->MockChainData.addBlock(~makeLogConstructors)
    })

  module Chain1 = {
    include RollbackMultichain_test.Mock.Chain1

    let factoryAddress = ChainDataHelpers.ERC20Factory.getDefaultAddress(chain)

    open ChainDataHelpers.ERC20
    open ChainDataHelpers.ERC20Factory
    let mkTransferToken1EventConstr = params =>
      Transfer.mkEventConstrWithParamsAndAddress(
        ~srcAddress=mockDynamicToken1,
        ~params=params->(Utils.magic: Types.ERC20.Transfer.eventArgs => Internal.eventParams),
        ...
      )
    let mkTransferToken2EventConstr = params =>
      Transfer.mkEventConstrWithParamsAndAddress(
        ~srcAddress=mockDynamicToken2,
        ~params=params->(Utils.magic: Types.ERC20.Transfer.eventArgs => Internal.eventParams),
        ...
      )
    let mkTokenCreatedEventConstr = params =>
      TokenCreated.mkEventConstrWithParamsAndAddress(
        ~srcAddress=factoryAddress,
        ~params=params->(
          Utils.magic: Types.ERC20Factory.TokenCreated.eventArgs => Internal.eventParams
        ),
        ...
      )

    let b0 = [deployToken1->mkTokenCreatedEventConstr]
    let b1 = [mint50ToUser1->mkTransferToken1EventConstr, deployToken2->mkTokenCreatedEventConstr]
    let b2 = []
    let b3 = []
    let b4 = []
    let b5 = []
    let b6 = []

    let blocks = [b0, b1, b2, b3, b4, b5, b6]

    let mockChainData = blocks->Array.reduce(mockChainDataEmpty, (accum, makeLogConstructors) => {
      accum->MockChainData.addBlock(~makeLogConstructors)
    })
  }
  module Chain2 = RollbackMultichain_test.Mock.Chain2

  let mockChainDataMap = config.chainMap->ChainMap.mapWithKey((chain, _) =>
    switch chain->ChainMap.Chain.toChainId {
    | 1 => Chain1.mockChainData
    | 137 =>
      let empty = MockChainData.make(
        ~chainConfig=config.chainMap->ChainMap.get(chain),
        ~maxBlocksReturned=2,
        ~blockTimestampInterval=25,
      )
      empty
    | _ => Js.Exn.raiseError("Unexpected chain")
    }
  )

  let getUpdateEndofBlockRangeScannedData = (
    mcdMap,
    ~chain,
    ~blockNumber,
    ~blockNumberThreshold,
  ) => {
    let (blockNumber, blockHash) =
      mcdMap
      ->ChainMap.get(chain)
      ->MockChainData.getBlock(~blockNumber)
      ->Option.mapWithDefault((0, "0xstub"), ({blockNumber, blockHash}) => (blockNumber, blockHash))

    GlobalState.UpdateEndOfBlockRangeScannedData({
      blockNumberThreshold,
      chain,
      nextEndOfBlockRangeScannedData: {
        blockNumber,
        blockHash,
        chainId: chain->ChainMap.Chain.toChainId,
      },
    })
  }
}

module Sql = RollbackMultichain_test.Sql

exception RollbackTransaction

describe("Dynamic contract restart resistance test", () => {
  Async.before(() => {
    //Provision the db
    DbHelpers.runUpDownMigration()
  })

  let getChainFetcherDcs = (chainFetcher: ChainFetcher.t) => {
    chainFetcher.fetchState.indexingContracts
    ->Js.Dict.values
    ->Belt.Array.keepMap(indexingContract =>
      switch indexingContract {
      | {register: Config} => None
      | {register: DC(_), address} => Some(address)
      }
    )
  }

  let getFetchingDcAddressesFromDbState = async (~chainId=1, ~sql=?) => {
    let chainFetcher = await ChainFetcher.makeFromDbState(
      config.chainMap->ChainMap.get(ChainMap.Chain.makeUnsafe(~chainId)),
      ~maxAddrInPartition=Env.maxAddrInPartition,
      ~enableRawEvents=config.enableRawEvents,
      ~sql?,
    )

    chainFetcher->getChainFetcherDcs
  }

  Async.it(
    "Indexer should restart with only the dynamic contracts up to the block that was processed",
    async () => {
      //Setup a chainManager with unordered multichain mode to make processing happen
      //without blocking for the purposes of this test
      let chainManager = {
        ...ChainManager.makeFromConfig(~config),
        isUnorderedMultichainMode: true,
        isInReorgThreshold: true,
      }
      let loadLayer = LoadLayer.makeWithDbConnection()

      //Setup initial state stub that will be used for both
      //initial chain data and reorg chain data
      let initState = GlobalState.make(~config, ~chainManager, ~loadLayer)
      let gsManager = initState->GlobalStateManager.make
      let tasks = ref([])
      let makeStub = ChainDataHelpers.Stubs.make(~gsManager, ~tasks, ...)

      open ChainDataHelpers
      //Stub specifically for using data from then initial chain data and functions
      let stubDataInitial = makeStub(~mockChainDataMap=Mock.mockChainDataMap)
      let dispatchTask = Stubs.makeDispatchTask(stubDataInitial, _)
      let dispatchAllTasks = () => {
        stubDataInitial->Stubs.dispatchAllTasks
      }

      //Dispatch first task of next query all chains
      //First query will just get the height
      await dispatchTask(NextQuery(CheckAllChains))

      Assert.deepEqual(
        [GlobalState.NextQuery(Chain(Mock.Chain1.chain)), NextQuery(Chain(Mock.Chain2.chain))],
        stubDataInitial->Stubs.getTasks,
        ~message="Should have completed query to get height, next tasks would be to execute block range query",
      )

      //Make the first queries (A)
      await dispatchAllTasks()
      await dispatchAllTasks()
      Assert.deepEqual(
        stubDataInitial->Stubs.getTasks,
        [
          UpdateChainMetaDataAndCheckForExit(NoExit),
          ProcessEventBatch,
          NextQuery(Chain(Mock.Chain1.chain)),
          NextQuery(Chain(Mock.Chain2.chain)),
        ],
        ~message="Should have received a response and next tasks will be to process batch and next query",
      )

      await dispatchAllTasks()

      Assert.deepEqual(
        (await Db.sql
        ->Postgres.unsafe(`SELECT * FROM public.dynamic_contract_registry;`))
        ->Array.length,
        0,
        ~message="Should have 0 dynamic contracts in db. Since the batch is not created yet and dcsToStore aren't commited",
      )

      await dispatchAllTasks()
      await dispatchAllTasks()

      //After this step, the dynamic contracts should be in the database but on restart
      //Only the the first dynamic contract should be registered since we haven't processed
      //up to the second one yet

      let dcsBeforeRestart =
        await Db.sql->Postgres.unsafe(`SELECT * FROM public.dynamic_contract_registry;`)
      let dcsHistoryBeforeRestart =
        await Db.sql->Postgres.unsafe(`SELECT * FROM public.dynamic_contract_registry_history;`)
      Assert.equal(
        dcsBeforeRestart->Array.length,
        2,
        ~message="Should have 2 dynamic contracts in db",
      )
      Assert.equal(
        dcsHistoryBeforeRestart->Array.length,
        2,
        ~message="Should have 2 dynamic contract history items in db",
      )

      try await Db.sql->Postgres.beginSql(
        sql => [
          (
            async () => {
              Assert.deepEqual(
                await getFetchingDcAddressesFromDbState(~sql),
                dcsBeforeRestart->Js.Array2.map(dc => dc["contract_address"]),
                ~message="Should get all addresses on restart",
              )

              // But let's say the indexer crashed before
              // the processing of events catch up to the dcs we stored in the db
              // In this case on restart we should prune contracts after event_sync_state
              let _ =
                await sql->Postgres.unsafe(`UPDATE public.event_sync_state SET block_number = 0 WHERE chain_id = 1;`)

              Assert.deepEqual(
                await getFetchingDcAddressesFromDbState(~sql),
                // This one has
                // registering_event_block_number: 0
                // registering_event_log_index: 0
                // So it's not pruned
                [Mock.mockDynamicToken1],
                ~message="Should keep only the dc up to the event_sync_state",
              )

              Assert.equal(
                (await sql
                ->Postgres.unsafe(`SELECT * FROM public.dynamic_contract_registry;`))
                ->Array.length,
                1,
                ~message="Should clean up pruned dc from db on restart",
              )
              Assert.equal(
                (await sql
                ->Postgres.unsafe(`SELECT * FROM public.dynamic_contract_registry_history;`))
                ->Array.length,
                1,
                ~message=`Should clean up pruned dc history from db on restart.
              Note: Without it there's a case when the indexer might crash because of a conflict`,
              )

              raise(RollbackTransaction)
            }
          )(),
        ],
      ) catch {
      | RollbackTransaction => ()
      }

      Assert.deepEqual(
        await Db.sql->Postgres.unsafe(`SELECT * FROM public.dynamic_contract_registry;`),
        dcsBeforeRestart,
        ~message="Dcs should rollback after restart tests",
      )
      Assert.deepEqual(
        await Db.sql->Postgres.unsafe(`SELECT * FROM public.dynamic_contract_registry_history;`),
        dcsHistoryBeforeRestart,
        ~message="Dcs history should rollback after restart tests",
      )
    },
  )
})
