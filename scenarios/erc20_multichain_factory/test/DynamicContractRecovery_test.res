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

describe("Dynamic contract restart resistance test", () => {
  Async.before(() => {
    //Provision the db
    DbHelpers.runUpDownMigration()
  })

  Async.it(
    "Indexer should restart with only the dynamic contracts up to the block that was processed",
    async () => {
      //Setup a chainManager with unordered multichain mode to make processing happen
      //without blocking for the purposes of this test
      let chainManager = {
        ...ChainManager.makeFromConfig(~config),
        isUnorderedMultichainMode: true,
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

      let dynamicContractsInTable =
        await Db.sql->Postgres.unsafe(`SELECT * FROM dynamic_contract_registry;`)

      Assert.equal(
        dynamicContractsInTable->Array.length,
        2,
        ~message="Should have 2 dynamic contracts in table",
      )

      let chainConfig = config.chainMap->ChainMap.get(ChainMap.Chain.makeUnsafe(~chainId=1))

      let restartedChainFetcher = await ChainFetcher.makeFromDbState(
        chainConfig,
        ~maxAddrInPartition=Env.maxAddrInPartition,
      )

      let restartedFetchState = switch restartedChainFetcher.partitionedFetchState.partitions {
      | [partition] => partition
      | _ => failwith("No partitions found in restarted chain fetcher")
      }

      let dynamicContracts =
        restartedFetchState.baseRegister.dynamicContracts
        ->Belt.Map.valuesToArray
        ->Array.flatMap(set => set->Belt.Set.String.toArray)

      Assert.deepEqual(
        dynamicContracts,
        [Mock.mockDynamicToken1->Address.toString],
        ~message="Should have registered only the dynamic contract up to the block that was processed",
      )

      {
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

        let resetEventOptionsToOriginal =
          Types.ERC20Factory.TokenCreated.handlerRegister->setRegisterPreRegistration(true)

        let restartedChainFetcher = await ChainFetcher.makeFromDbState(
          chainConfig,
          ~maxAddrInPartition=Env.maxAddrInPartition,
        )

        let restartedFetchState = switch restartedChainFetcher.partitionedFetchState.partitions {
        | [partition] => partition
        | _ => failwith("No partitions found in restarted chain fetcher with")
        }

        let dynamicContracts =
          restartedFetchState.baseRegister.dynamicContracts
          ->Belt.Map.valuesToArray
          ->Array.flatMap(set => set->Belt.Set.String.toArray)

        Assert.deepEqual(
          restartedChainFetcher.dynamicContractPreRegistration->Option.getExn->Js.Dict.keys,
          [Mock.mockDynamicToken1->Address.toString, Mock.mockDynamicToken2->Address.toString],
          ~message="Should return all the dynamic contracts related to handler that uses preRegistration",
        )

        Assert.deepEqual(
          dynamicContracts,
          [],
          ~message="Should have no dynamic contracts yet since this tests the case starting in preregistration",
        )
        resetEventOptionsToOriginal()
      }

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
        ],
        ~message="This looks wrong, but snapshot to track how it changes with time",
      )
      // DynamicContract
      // fromBlock: 0
      // toBlock: 0
      await dispatchAllTasks()
      // DynamicContract
      // fromBlock: 0
      // toBlock: 3
      await dispatchAllTasks()
      // DynamicContract
      // fromBlock: 2
      // toBlock: 3
      await dispatchAllTasks()

      let restartedChainFetcher = await ChainFetcher.makeFromDbState(
        chainConfig,
        ~maxAddrInPartition=Env.maxAddrInPartition,
      )

      let restartedFetchState =
        restartedChainFetcher.partitionedFetchState.partitions->Array.get(0)->Option.getExn

      let dynamicContracts =
        restartedFetchState.baseRegister.dynamicContracts
        ->Belt.Map.valuesToArray
        ->Array.flatMap(set => set->Belt.Set.String.toArray)

      Assert.deepEqual(
        dynamicContracts,
        [Mock.mockDynamicToken1->Address.toString, Mock.mockDynamicToken2->Address.toString],
        ~message="Should have registered both dynamic contracts up to the block that was processed",
      )
    },
  )
})
