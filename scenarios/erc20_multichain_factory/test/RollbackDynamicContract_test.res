open Belt
open RescriptMocha

module Mock = {
  /*

  blocks of 3 queried

0a
1a nothing just to get block hashes (adds end of range A block hash)

2b 
3b register contract (dynamic query should action from 3, where parent hash is block 2 not 3)
ensure that this doesn't trigger a reorg
*/
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
  let userAddress2 = Ethers.Addresses.mockAddresses[2]->Option.getExn

  let mockDyamicToken1 = Ethers.Addresses.mockAddresses[3]->Option.getExn
  let factoryAddress1 = ChainDataHelpers.ERC20Factory.getDefaultAddress(Chain_1)

  let deployToken1 = makeTokenCreatedMock(~token=mockDyamicToken1)

  let mint50ToUser1 = makeTransferMock(~from=mintAddress, ~to=userAddress1, ~value=50)
  let mint100ToUser2 = makeTransferMock(~from=mintAddress, ~to=userAddress2, ~value=100)
  //mock transfers from user 2 to user 1
  let transfer20FromU2ToU1 = makeTransferMock(~from=userAddress2, ~to=userAddress1, ~value=20)
  let transfer30FromU2ToU1 = makeTransferMock(~from=userAddress2, ~to=userAddress1, ~value=30)
  let transfer19FromU2ToU1 = makeTransferMock(~from=userAddress2, ~to=userAddress1, ~value=19)

  //mock transfers from user 1 to user 2
  let transfer15FromU1ToU2 = makeTransferMock(~from=userAddress1, ~to=userAddress2, ~value=15)
  let transfer8FromU1ToU2 = makeTransferMock(~from=userAddress1, ~to=userAddress2, ~value=8)
  let transfer6FromU1ToU2 = makeTransferMock(~from=userAddress1, ~to=userAddress2, ~value=6)

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

    open ChainDataHelpers.ERC20
    open ChainDataHelpers.ERC20Factory
    let mkTransferEventConstr = Transfer.mkEventConstrWithParamsAndAddress(
      ~srcAddress=mockDyamicToken1,
      ~params=_,
      ...
    )
    let mkTokenCreatedEventConstr = TokenCreated.mkEventConstrWithParamsAndAddress(
      ~srcAddress=factoryAddress1,
      ~params=_,
      ...
    )

    let b0 = []
    let b1 = []
    let b2 = []
    let b3 = [deployToken1->mkTokenCreatedEventConstr]
    let b4 = [mint50ToUser1->mkTransferEventConstr]
    let b5 = []
    let b6 = []

    let blocks = [b0, b1, b2, b3, b4, b5, b6]

    let mockChainData = blocks->Array.reduce(mockChainDataEmpty, (accum, makeLogConstructors) => {
      accum->MockChainData.addBlock(~makeLogConstructors)
    })
  }
  module Chain2 = RollbackMultichain_test.Mock.Chain2

  let mockChainDataMap = ChainMap.make(chain =>
    switch chain {
    | Chain_1 => Chain1.mockChainData
    | Chain_137 => Chain2.mockChainData
    }
  )

  let getUpdateEndofBlockRangeScannedData = (
    mcdMap,
    ~chain,
    ~blockNumber,
    ~blockNumberThreshold,
    ~blockTimestampThreshold,
  ) => {
    let {blockNumber, blockTimestamp, blockHash} =
      mcdMap->ChainMap.get(chain)->MockChainData.getBlock(~blockNumber)->Option.getUnsafe

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

describe("Dynamic contract rollback test", () => {
  Async.before(() => {
    //Provision the db
    DbHelpers.runUpDownMigration()
  })

  Async.it("Dynamic contract should not trigger reorg", async () => {
    //Setup a chainManager with unordered multichain mode to make processing happen
    //without blocking for the purposes of this test
    let chainManager = {
      ...ChainManager.makeFromConfig(~configs=Config.config),
      isUnorderedMultichainMode: true,
    }

    //Setup initial state stub that will be used for both
    //initial chain data and reorg chain data
    let initState = GlobalState.make(~chainManager)
    let gsManager = initState->GlobalStateManager.make
    let tasks = ref([])
    let makeStub = ChainDataHelpers.Stubs.make(~gsManager, ~tasks, ...)

    //helpers
    let getChainFetcher = chain => {
      let state = gsManager->GlobalStateManager.getState
      state.chainManager.chainFetchers->ChainMap.get(chain)
    }

    let getFetchState = chain => {
      let cf = chain->getChainFetcher
      cf.fetchState
    }

    let getQueueSize = chain => {
      chain->getFetchState->FetchState.queueSize
    }

    let getLatestFetchedBlock = chain => {
      chain->getFetchState->FetchState.getLatestFullyFetchedBlock
    }

    let getTokenBalance = (~accountAddress) => chain => {
      Sql.getAccountTokenBalance(
        ~tokenAddress=ChainDataHelpers.ERC20.getDefaultAddress(chain),
        ~accountAddress,
      )
    }

    let getUser1Balance = getTokenBalance(~accountAddress=Mock.userAddress1)
    let getUser2Balance = getTokenBalance(~accountAddress=Mock.userAddress2)

    let getTotalQueueSize = () =>
      ChainMap.Chain.all->Array.reduce(0, (accum, next) => accum + next->getQueueSize)
    open ChainDataHelpers
    //Stub specifically for using data from then initial chain data and functions
    let stubDataInitial = makeStub(~mockChainDataMap=Mock.mockChainDataMap)
    let dispatchTask = Stubs.makeDispatchTask(stubDataInitial, _)
    let dispatchAllTasks = () => stubDataInitial->Stubs.dispatchAllTasks

    //Dispatch first task of next query all chains
    //First query will just get the height
    await dispatchTask(NextQuery(CheckAllChains))

    Assert.deepEqual(
      [GlobalState.NextQuery(Chain(Chain_1)), NextQuery(Chain(Chain_137))],
      stubDataInitial->Stubs.getTasks,
      ~message="Should have completed query to get height, next tasks would be to execute block range query",
    )

    let makeAssertions = async (
      ~queryName,
      ~chain1LatestFetchBlock,
      ~chain2LatestFetchBlock,
      ~totalQueueSize,
      ~batchName,
      ~chain1User1Balance,
      ~chain1User2Balance,
      ~chain2User1Balance,
      ~chain2User2Balance,
    ) => {
      Assert.equal(
        getLatestFetchedBlock(Chain_1).blockNumber,
        chain1LatestFetchBlock,
        ~message=`Chain 1 should have fetched up to block ${chain1LatestFetchBlock->Int.toString} on query ${queryName}`,
      )
      Assert.equal(
        getLatestFetchedBlock(Chain_137).blockNumber,
        chain2LatestFetchBlock,
        ~message=`Chain 2 should have fetched up to block ${chain2LatestFetchBlock->Int.toString} on query ${queryName}`,
      )
      Assert.equal(
        getTotalQueueSize(),
        totalQueueSize,
        ~message=`Query ${queryName} should have returned ${totalQueueSize->Int.toString} events`,
      )

      let toBigInt = BigInt.fromInt
      let optIntToString = optInt =>
        switch optInt {
        | Some(n) => `Some(${n->Int.toString})`
        | None => "None"
        }

      let getBalanceFn = (chain, user) =>
        switch user {
        | 1 => chain->getUser1Balance
        | 2 => chain->getUser2Balance
        | user => Js.Exn.raiseError(`Invalid user num ${user->Int.toString}`)
        }

      let assertBalance = async (~chain, ~expectedBalance, ~user) => {
        let balance = await getBalanceFn(chain, user)
        Assert.deepEqual(
          balance,
          expectedBalance->Option.map(toBigInt),
          ~message=`Chain ${chain->ChainMap.Chain.toString} after processing blocks in batch ${batchName}, User ${user->Int.toString} should have a balance of ${expectedBalance->optIntToString} but has ${balance
            ->Option.flatMap(BigInt.toInt)
            ->optIntToString}`,
        )
      }
      //Chain 1 balances
      await assertBalance(~chain=Chain_1, ~user=1, ~expectedBalance=chain1User1Balance)
      await assertBalance(~chain=Chain_1, ~user=2, ~expectedBalance=chain1User2Balance)
      await assertBalance(~chain=Chain_137, ~user=1, ~expectedBalance=chain2User1Balance)
      await assertBalance(~chain=Chain_137, ~user=2, ~expectedBalance=chain2User2Balance)
    }

    await makeAssertions(
      ~queryName="No Query",
      ~chain1LatestFetchBlock=0,
      ~chain2LatestFetchBlock=0,
      ~totalQueueSize=0,
      ~batchName="No Batch",
      ~chain1User1Balance=None,
      ~chain1User2Balance=None,
      ~chain2User1Balance=None,
      ~chain2User2Balance=None,
    )

    //Make the first queries (A)
    await dispatchAllTasks()
    Assert.deepEqual(
      [
        Mock.getUpdateEndofBlockRangeScannedData(
          Mock.mockChainDataMap,
          ~chain=Chain_1,
          ~blockNumberThreshold=-199,
          ~blockTimestampThreshold=25,
          ~blockNumber=1,
        ),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(Chain(Chain_1)),
        Mock.getUpdateEndofBlockRangeScannedData(
          Mock.mockChainDataMap,
          ~chain=Chain_137,
          ~blockNumberThreshold=-198,
          ~blockTimestampThreshold=25,
          ~blockNumber=2,
        ),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(Chain(Chain_137)),
      ],
      stubDataInitial->Stubs.getTasks,
      ~message="Should have received a response and next tasks will be to process batch and next query",
    )

    await makeAssertions(
      ~queryName="A",
      ~chain1LatestFetchBlock=1,
      ~chain2LatestFetchBlock=2,
      ~totalQueueSize=2,
      ~batchName="No Batch",
      ~chain1User1Balance=None,
      ~chain1User2Balance=None,
      ~chain2User1Balance=None,
      ~chain2User2Balance=None,
    )

    //Process the events in the queues
    //And make queries (B)
    await dispatchAllTasks()
    await makeAssertions(
      ~queryName="B",
      ~chain1LatestFetchBlock=3,
      ~chain2LatestFetchBlock=5,
      ~totalQueueSize=3,
      ~batchName="A",
      ~chain1User1Balance=None,
      ~chain1User2Balance=None,
      ~chain2User1Balance=Some(50),
      ~chain2User2Balance=Some(100),
    )
    Assert.deepEqual(
      [
        GlobalState.NextQuery(CheckAllChains),
        Mock.getUpdateEndofBlockRangeScannedData(
          Mock.mockChainDataMap,
          ~chain=Chain_1,
          ~blockNumberThreshold=-197,
          ~blockTimestampThreshold=25,
          ~blockNumber=3,
        ),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(Chain(Chain_1)),
        Mock.getUpdateEndofBlockRangeScannedData(
          Mock.mockChainDataMap,
          ~chain=Chain_137,
          ~blockNumberThreshold=-195,
          ~blockTimestampThreshold=25,
          ~blockNumber=5,
        ),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(Chain(Chain_137)),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
      ],
      stubDataInitial->Stubs.getTasks,
      ~message="Should have processed a batch and run next queries on all chains",
    )

    //Artificially cut the tasks to only do one round of queries and batch processing
    tasks := [
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(CheckAllChains),
      ]

    let getFetchStateRegisterId = () =>
      switch getFetchState(Chain_1)
      ->FetchState.getNextQuery(~currentBlockHeight=6)
      ->Result.getExn {
      | (FetchState.NextQuery(q), _) => q.fetchStateRegisterId
      | _ => raise(Not_found)
      }

    Assert.deepEqual(FetchState.Root, getFetchStateRegisterId())
    //Process batch 2 of events
    //And make queries (C)
    await dispatchAllTasks()

    Assert.deepEqual(
      [
        GlobalState.NextQuery(CheckAllChains),
        Mock.getUpdateEndofBlockRangeScannedData(
          Mock.mockChainDataMap,
          ~chain=Chain_1,
          ~blockNumberThreshold=-195,
          ~blockTimestampThreshold=25,
          ~blockNumber=5,
        ),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(Chain(Chain_1)),
        Mock.getUpdateEndofBlockRangeScannedData(
          Mock.mockChainDataMap,
          ~chain=Chain_137,
          ~blockNumberThreshold=-192,
          ~blockTimestampThreshold=25,
          ~blockNumber=8,
        ),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(Chain(Chain_137)),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(CheckAllChains),
      ],
      stubDataInitial->Stubs.getTasks,
      ~message="Next round of tasks after query C",
    )

    Assert.deepEqual(
      FetchState.DynamicContract({blockNumber: 3, logIndex: 0}),
      getFetchStateRegisterId(),
    )
    await makeAssertions(
      ~queryName="C",
      ~chain1LatestFetchBlock=2, //dynamic contract registered and fetchState set to block before registration (dyn contract query not yet made)
      ~chain2LatestFetchBlock=8,
      ~totalQueueSize=3,
      ~batchName="B",
      ~chain1User1Balance=None,
      ~chain1User2Balance=None,
      ~chain2User1Balance=Some(80),
      ~chain2User2Balance=Some(70),
    )

    //Artificially cut the tasks to only do one round of queries and batch processing
    tasks := [
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(CheckAllChains),
      ]
    //Process batch 3 of events and make queries
    //Execute queries(D)
    await dispatchAllTasks()
    Assert.deepEqual(
      [
        GlobalState.NextQuery(CheckAllChains),
        Mock.getUpdateEndofBlockRangeScannedData(
          Mock.mockChainDataMap,
          ~chain=Chain_1,
          ~blockNumberThreshold=-196,
          ~blockTimestampThreshold=25,
          ~blockNumber=4,
        ),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(Chain(Chain_1)),
        Mock.getUpdateEndofBlockRangeScannedData(
          Mock.mockChainDataMap,
          ~chain=Chain_137,
          ~blockNumberThreshold=-191,
          ~blockTimestampThreshold=25,
          ~blockNumber=9,
        ),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(Chain(Chain_137)),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
      ],
      stubDataInitial->Stubs.getTasks,
      ~message="Next round of tasks after query D",
    )

    await makeAssertions(
      ~queryName="D",
      ~chain1LatestFetchBlock=4,
      ~chain2LatestFetchBlock=9,
      ~totalQueueSize=2, //One from dynamic contract, one from 137
      ~batchName="C",
      ~chain1User1Balance=None,
      ~chain1User2Balance=None,
      ~chain2User1Balance=Some(98),
      ~chain2User2Balance=Some(52),
    )

    //Artificially cut the tasks to only do one round of queries and batch processing
    tasks := [
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(CheckAllChains),
      ]
    //Process batch 2 of events and make queries
    //Execute queries(E)
    await dispatchAllTasks()
    Assert.equal(
      stubDataInitial->Stubs.getTasks->Js.Array2.includes(Rollback),
      false,
      ~message="dynamic contract query should not action rollback",
    )
  })
})
