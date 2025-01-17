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
    let mkTransferToken1EventConstr = Transfer.mkEventConstrWithParamsAndAddress(
      ~srcAddress=mockDynamicToken1,
      ~params=_,
      ...
    )
    let mkTransferToken2EventConstr = Transfer.mkEventConstrWithParamsAndAddress(
      ~srcAddress=mockDynamicToken2,
      ~params=_,
      ...
    )
    let mkTokenCreatedEventConstr = TokenCreated.mkEventConstrWithParamsAndAddress(
      ~srcAddress=factoryAddress,
      ~params=_,
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
    ~blockTimestampThreshold,
  ) => {
    let (blockNumber, blockTimestamp, blockHash) =
      mcdMap
      ->ChainMap.get(chain)
      ->MockChainData.getBlock(~blockNumber)
      ->Option.mapWithDefault((0, 0, "0xstub"), ({blockNumber, blockTimestamp, blockHash}) => (
        blockNumber,
        blockTimestamp,
        blockHash,
      ))

    GlobalState.UpdateEndOfBlockRangeScannedData({
      blockNumberThreshold,
      blockTimestampThreshold,
      chain,
      nextEndOfBlockRangeScannedData: {
        blockNumber,
        blockHash,
        blockTimestamp,
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
    chainFetcher.fetchState.partitions->Array.flatMap(p =>
      p.dynamicContracts->Array.map(dc => dc.contractAddress)
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

  //Test the preRegistration restart function getting all the dynamic contracts
  let setRegisterPreRegistration: (
    Types.HandlerTypes.Register.t,
    bool,
  ) => unit => unit = %raw(`(register, bool)=> {
    const eventOptions = register.eventOptions;
    if (!eventOptions) {
      register.eventOptions = {};
    }
    register.eventOptions.preRegisterDynamicContracts=bool;
    return () => register.eventOptions = eventOptions;
  }`)

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
      let chainConfig = config.chainMap->ChainMap.get(ChainMap.Chain.makeUnsafe(~chainId=1))
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
      let dispatchAllTasks = () => stubDataInitial->Stubs.dispatchAllTasks

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
      Assert.deepEqual(
        stubDataInitial->Stubs.getTasks,
        [
          Mock.getUpdateEndofBlockRangeScannedData(
            Mock.mockChainDataMap,
            ~chain=Mock.Chain1.chain,
            ~blockNumberThreshold=-199,
            ~blockTimestampThreshold=25,
            ~blockNumber=1,
          ),
          UpdateChainMetaDataAndCheckForExit(NoExit),
          ProcessEventBatch,
          NextQuery(Chain(Mock.Chain1.chain)),
          NextQuery(Chain(Mock.Chain2.chain)),
        ],
        ~message="Should have received a response and next tasks will be to process batch and next query",
      )

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
                [Mock.mockDynamicToken1],
                ~message="Should have registered only the dynamic contract up to the block that was processed",
              )

              Assert.equal(
                (await sql
                ->Postgres.unsafe(`SELECT * FROM public.dynamic_contract_registry;`))
                ->Array.length,
                1,
                ~message="Should clean up invalid dc from db on restart",
              )
              Assert.equal(
                (await sql
                ->Postgres.unsafe(`SELECT * FROM public.dynamic_contract_registry_history;`))
                ->Array.length,
                1,
                ~message=`Should clean up invalid dc history from db on restart.
            Note: Without it there's a case when the indexer might crash because of a conflict`,
              )

              raise(RollbackTransaction)
            }
          )(),
        ],
      ) catch {
      | RollbackTransaction => ()
      }

      try await Db.sql->Postgres.beginSql(
        sql => [
          (
            async () => {
              let resetEventOptionsToOriginal =
                Types.ERC20Factory.TokenCreated.handlerRegister->setRegisterPreRegistration(true)

              let restartedChainFetcher = await ChainFetcher.makeFromDbState(
                chainConfig,
                ~maxAddrInPartition=Env.maxAddrInPartition,
                ~enableRawEvents=false,
                ~sql,
              )

              Assert.deepEqual(
                restartedChainFetcher.dynamicContractPreRegistration->Option.getExn->Js.Dict.keys,
                [Mock.mockDynamicToken1->Address.toString],
                ~message=`Should recover with only dc1 since it was registered at the restart start block.
                The dc2 wasn't registered during preRegistration phase, so it's not recovered
                even though the eventOptions says that preRegistration enabled.
                This might happen when a preRegistered contract, registers itself on the actual indexer run`,
              )

              Assert.deepEqual(
                restartedChainFetcher->getChainFetcherDcs,
                [],
                ~message="Should have no dynamic contracts yet since this tests the case starting in preregistration",
              )

              Assert.equal(
                (await sql
                ->Postgres.unsafe(`SELECT * FROM public.dynamic_contract_registry;`))
                ->Array.length,
                1,
                ~message="Should clean up invalid dc from db on restart",
              )
              Assert.equal(
                (await sql
                ->Postgres.unsafe(`SELECT * FROM public.dynamic_contract_registry_history;`))
                ->Array.length,
                1,
                ~message=`Should clean up invalid dc history from db on restart.
            Note: Without it there's a case when the indexer might crash because of a conflict`,
              )

              resetEventOptionsToOriginal()

              raise(RollbackTransaction)
            }
          )(),
        ],
      ) catch {
      | RollbackTransaction => ()
      | Js.Exn.Error(e) => raise(e->Obj.magic)
      }

      try await Db.sql->Postgres.beginSql(
        sql => [
          (
            async () => {
              let resetEventOptionsToOriginal =
                Types.ERC20Factory.TokenCreated.handlerRegister->setRegisterPreRegistration(true)

              // Manualy update the second dc in db to make it look as if it was pre registered
              let () = await sql->Postgres.unsafe(`UPDATE public.dynamic_contract_registry
                SET is_pre_registered = true
                WHERE registering_event_block_number = 1;`)

              let restartedChainFetcher = await ChainFetcher.makeFromDbState(
                chainConfig,
                ~maxAddrInPartition=Env.maxAddrInPartition,
                ~enableRawEvents=false,
                ~sql,
              )

              Assert.deepEqual(
                restartedChainFetcher.dynamicContractPreRegistration->Option.getExn->Js.Dict.keys,
                [
                  Mock.mockDynamicToken1->Address.toString,
                  Mock.mockDynamicToken2->Address.toString,
                ],
                ~message=`Should include both dc1 which is not pre registered, but registered at the restart start block
                and dc2 which is after restart start block, but was pre registered`,
              )

              Assert.deepEqual(
                restartedChainFetcher->getChainFetcherDcs,
                [],
                ~message="Should have no dynamic contracts yet since this tests the case starting in preregistration",
              )

              Assert.deepEqual(
                await sql->Postgres.unsafe(`SELECT * FROM public.dynamic_contract_registry;`),
                switch dcsBeforeRestart {
                | [dc1, dc2] => [
                    dc1,
                    (
                      {
                        ...dc2,
                        isPreRegistered: true,
                      }: TablesStatic.DynamicContractRegistry.t
                    ),
                  ]
                | _ => Assert.fail("Should have 2 dcs")
                },
                ~message="Should keep both dcs after restart in db",
              )
              Assert.equal(
                (await sql
                ->Postgres.unsafe(`SELECT * FROM public.dynamic_contract_registry_history;`))
                ->Array.length,
                1,
                ~message=`But it'll still remove the dc history for pre-registered one,
                this case is not possible in real life, since pre-registration never happens in reorg threshold`,
              )

              resetEventOptionsToOriginal()

              raise(RollbackTransaction)
            }
          )(),
        ],
      ) catch {
      | RollbackTransaction => ()
      | Js.Exn.Error(e) => raise(e->Obj.magic)
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

      Assert.deepEqual(
        stubDataInitial->Stubs.getTasks,
        [
          NextQuery(CheckAllChains),
          Mock.getUpdateEndofBlockRangeScannedData(
            Mock.mockChainDataMap,
            ~chain=Mock.Chain1.chain,
            ~blockNumberThreshold=-197,
            ~blockTimestampThreshold=25,
            ~blockNumber=3,
          ),
          UpdateChainMetaDataAndCheckForExit(NoExit),
          ProcessEventBatch,
          NextQuery(Chain(Mock.Chain1.chain)),
          NextQuery(Chain(Mock.Chain2.chain)),
          UpdateChainMetaDataAndCheckForExit(NoExit),
          ProcessEventBatch,
          NextQuery(CheckAllChains),
          PruneStaleEntityHistory,
        ],
        ~message="This looks wrong, but snapshot to track how it changes with time",
      )
    },
  )
})
