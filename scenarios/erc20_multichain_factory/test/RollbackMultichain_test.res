open Belt
open RescriptMocha

let config = Config.getGenerated()

module Mock = {
  /*
  Chain 1 has 6 blocks in 25s intervals and getting batches of 2 blocks at a time
  Chain 2 has 9 blocks at 16s intervals and getting bathes of 3 blocks at a time
  Chain 1 fetches all the way up to 5c
  A reorg occurs on chain1 affecting blocks 4 and onwards.
  on query for block range d a reorg is detected and should rollback to the end of query b (block 3 the nearest known valid block) 
  and start query c again.
  Chain 2 should follow suit and rollback to nearest known endOfRange block (2a), actioning query b again
  Chain 2 blocks 3 and 4 would not have been affeced by rollback so we should not be double processing those events
  | time | c1  | c2
  | 0    |  0a | 0a
  | 16   |     | 1a
  | 25   |  1a |
  | 32   |     | 2a
  | 48   |     | 3b
  | 50   |  2b |
  | 64   |     | 4b
  | 75   |  3b | 
  | 80   |     | 5b
  | 96   |     | 6c
  | 100  |  4c |
  | 112  |     | 7c
  | 125  |  5c |
  | 128  |     | 8c
  | 144  |     | 9d
  | 150  |  6d |
 */

  let makeTransferMock = (~from, ~to, ~value): Types.ERC20.Transfer.eventArgs => {
    from,
    to,
    value: value->BigInt.fromInt,
  }

  let mintAddress = Ethers.Constants.zeroAddress
  let userAddress1 = Ethers.Addresses.mockAddresses[1]->Option.getExn
  let userAddress2 = Ethers.Addresses.mockAddresses[2]->Option.getExn

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
    let chain = ChainMap.Chain.makeUnsafe(~chainId=1)
    let mockChainDataEmpty = MockChainData.make(
      ~chainConfig=config.chainMap->ChainMap.get(chain),
      ~maxBlocksReturned=2,
      ~blockTimestampInterval=25,
    )

    let defaultTokenAddress = ChainDataHelpers.getDefaultAddress(
      chain,
      ChainDataHelpers.ERC20.contractName,
    )

    open ChainDataHelpers.ERC20
    let mkTransferEventConstr = Transfer.mkEventConstr(~chain, ...)

    let b0 = []
    //balances: u1=0 | u2=0
    let b1 = [mint50ToUser1]
    //balances: u1=50 | u2=0
    let b2 = [mint100ToUser2]
    //balances: u1=50 | u2=100
    let b3 = []
    let b4 = [transfer30FromU2ToU1] //<-- blockhash should change from here after reorg
    //balances before rollback: u1=80 | u2=70
    let rollbackB4 = [transfer19FromU2ToU1]
    //balances after rollback: u1=69 | u2=81
    let b5 = [transfer20FromU2ToU1]
    //balances before rollback: u1=100 | u2=50
    //balances after rollback: u1=89 | u2=61
    let b6 = [transfer15FromU1ToU2]
    //balances: u1=85 | u2=65
    //balances after rollback: u1=74 | u2=76

    let blocksBase = [b0, b1, b2, b3]
    let blocksInitial = blocksBase->Array.concat([b4, b5, b6])
    let blocksReorg = blocksBase->Array.concat([rollbackB4, b5, b6])

    let applyBlocks =
      addBlocksOfTransferEvents(~mockChainData=mockChainDataEmpty, ~mkTransferEventConstr, ...)

    let mockChainDataInitial = blocksInitial->applyBlocks
    let mockChainDataReorg = blocksReorg->applyBlocks
  }
  module Chain2 = {
    let chain = ChainMap.Chain.makeUnsafe(~chainId=137)
    let defaultTokenAddress = ChainDataHelpers.getDefaultAddress(
      chain,
      ChainDataHelpers.ERC20.contractName,
    )
    let mockChainDataEmpty = MockChainData.make(
      ~chainConfig=config.chainMap->ChainMap.get(chain),
      ~maxBlocksReturned=3,
      ~blockTimestampInterval=16,
    )
    open ChainDataHelpers.ERC20
    let mkTransferEventConstr = Transfer.mkEventConstr(~chain, ...)
    let b0 = []
    //balances: u1=0 | u2=0
    let b1 = [mint50ToUser1]
    //balances: u1=50 | u2=0
    let b2 = [mint100ToUser2] //<-- will rollback to here when chain 1 reorgs
    //balances: u1=50 | u2=100
    let b3 = []
    let b4 = [transfer30FromU2ToU1]
    //balances: u1=80 | u2=70
    let b5 = [transfer20FromU2ToU1] //<-- only events from b5 onwards should be reprocessed
    //balances: u1=100 | u2=50
    let b6 = [transfer15FromU1ToU2]
    //balances: u1=85 | u2=65
    let b7 = [transfer6FromU1ToU2, transfer19FromU2ToU1]
    //balances: u1=79 | u2=71 -> u1=98 | u2=52
    let b8 = []
    let b9 = [transfer8FromU1ToU2]
    //balances: u1=90 | u2=60

    let blocks = [b0, b1, b2, b3, b4, b5, b6, b7, b8, b9]

    let applyBlocks =
      addBlocksOfTransferEvents(~mockChainData=mockChainDataEmpty, ~mkTransferEventConstr, ...)

    let mockChainData = blocks->applyBlocks
  }

  let mockChainDataMapInitial = config.chainMap->ChainMap.mapWithKey((chain, _) =>
    switch chain->ChainMap.Chain.toChainId {
    | 1 => Chain1.mockChainDataInitial
    | 137 => Chain2.mockChainData
    | _ => Js.Exn.raiseError("Unexpected chain")
    }
  )

  let mockChainDataMapReorg = config.chainMap->ChainMap.mapWithKey((chain, _) =>
    switch chain->ChainMap.Chain.toChainId {
    | 1 => Chain1.mockChainDataReorg
    | 137 => Chain2.mockChainData
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

module Sql = {
  @send
  external unsafe: (Postgres.sql, string) => promise<'a> = "unsafe"

  let query = unsafe(DbFunctions.sql, _)

  let getAllRowsInTable = tableName => query(`SELECT * FROM public."${tableName}";`)

  let getAccountTokenBalance = async (~tokenAddress, ~accountAddress) => {
    let tokenAddress = tokenAddress->Ethers.ethAddressToString
    let account_id = accountAddress->Ethers.ethAddressToString
    let accountTokenId = EventHandlers.makeAccountTokenId(~tokenAddress, ~account_id)
    let res = await query(
      `
    SELECT * FROM public."AccountToken"
    WHERE id = '${accountTokenId}';
    `,
    )

    res[0]
    ->Option.map(v => v->S.parseWith(Entities.AccountToken.schema)->Result.getExn)
    ->Option.map(a => a.balance)
  }
}
let setupDb = async () => {
  open Migrations
  Logging.info("Provisioning Database")
  let _exitCodeDown = await runDownMigrations(~shouldExit=false)
  let _exitCodeUp = await runUpMigrations(~shouldExit=false)
}

describe("Multichain rollback test", () => {
  Async.before(() => {
    //Provision the db
    DbHelpers.runUpDownMigration()
  })
  Async.it("Multichain indexer should rollback and not reprocess any events", async () => {
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

    //helpers
    let getState = () => {
      gsManager->GlobalStateManager.getState
    }
    let getChainFetcher = chain => {
      let state = gsManager->GlobalStateManager.getState
      state.chainManager.chainFetchers->ChainMap.get(chain)
    }

    let getFetchState = chain => {
      let cf = chain->getChainFetcher
      cf.fetchState
    }

    let getLatestFetchedBlock = chain => {
      chain->getFetchState->PartitionedFetchState.getLatestFullyFetchedBlock
    }

    let getTokenBalance = (~accountAddress) => chain => {
      Sql.getAccountTokenBalance(
        ~tokenAddress=ChainDataHelpers.ERC20.getDefaultAddress(chain),
        ~accountAddress,
      )
    }

    let getUser1Balance = getTokenBalance(~accountAddress=Mock.userAddress1)
    let getUser2Balance = getTokenBalance(~accountAddress=Mock.userAddress2)

    let getTotalQueueSize = () => {
      let state = gsManager->GlobalStateManager.getState
      state.chainManager.chainFetchers
      ->ChainMap.values
      ->Array.reduce(
        0,
        (accum, chainFetcher) => accum + chainFetcher.fetchState->PartitionedFetchState.queueSize,
      )
    }

    open ChainDataHelpers
    //Stub specifically for using data from then initial chain data and functions
    let stubDataInitial = makeStub(~mockChainDataMap=Mock.mockChainDataMapInitial)
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
        chain1LatestFetchBlock,
        getLatestFetchedBlock(Mock.Chain1.chain).blockNumber,
        ~message=`Chain 1 should have fetched up to block ${chain1LatestFetchBlock->Int.toString} on query ${queryName}`,
      )
      Assert.equal(
        chain2LatestFetchBlock,
        getLatestFetchedBlock(Mock.Chain2.chain).blockNumber,
        ~message=`Chain 2 should have fetched up to block ${chain2LatestFetchBlock->Int.toString} on query ${queryName}`,
      )
      Assert.equal(
        totalQueueSize,
        getTotalQueueSize(),
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
          expectedBalance->Option.map(toBigInt),
          balance,
          ~message=`Chain ${chain->ChainMap.Chain.toString} after processing blocks in batch ${batchName}, User ${user->Int.toString} should have a balance of ${expectedBalance->optIntToString} but has ${balance
            ->Option.flatMap(BigInt.toInt)
            ->optIntToString}`,
        )
      }
      //Chain 1 balances
      await assertBalance(~chain=Mock.Chain1.chain, ~user=1, ~expectedBalance=chain1User1Balance)
      await assertBalance(~chain=Mock.Chain1.chain, ~user=2, ~expectedBalance=chain1User2Balance)
      await assertBalance(~chain=Mock.Chain2.chain, ~user=1, ~expectedBalance=chain2User1Balance)
      await assertBalance(~chain=Mock.Chain2.chain, ~user=2, ~expectedBalance=chain2User2Balance)
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
          Mock.mockChainDataMapInitial,
          ~chain=Mock.Chain1.chain,
          ~blockNumberThreshold=-199,
          ~blockTimestampThreshold=25,
          ~blockNumber=1,
        ),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(Chain(Mock.Chain1.chain)),
        Mock.getUpdateEndofBlockRangeScannedData(
          Mock.mockChainDataMapInitial,
          ~chain=Mock.Chain2.chain,
          ~blockNumberThreshold=-198,
          ~blockTimestampThreshold=25,
          ~blockNumber=2,
        ),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(Chain(Mock.Chain2.chain)),
      ],
      stubDataInitial->Stubs.getTasks,
      ~message="Should have received a response and next tasks will be to process batch and next query",
    )

    await makeAssertions(
      ~queryName="A",
      ~chain1LatestFetchBlock=1,
      ~chain2LatestFetchBlock=2,
      ~totalQueueSize=3,
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
      ~chain1User1Balance=Some(50),
      ~chain1User2Balance=None,
      ~chain2User1Balance=Some(50),
      ~chain2User2Balance=Some(100),
    )
    Assert.deepEqual(
      [
        GlobalState.NextQuery(CheckAllChains),
        Mock.getUpdateEndofBlockRangeScannedData(
          Mock.mockChainDataMapInitial,
          ~chain=Mock.Chain1.chain,
          ~blockNumberThreshold=-197,
          ~blockTimestampThreshold=25,
          ~blockNumber=3,
        ),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(Chain(Mock.Chain1.chain)),
        Mock.getUpdateEndofBlockRangeScannedData(
          Mock.mockChainDataMapInitial,
          ~chain=Mock.Chain2.chain,
          ~blockNumberThreshold=-195,
          ~blockTimestampThreshold=25,
          ~blockNumber=5,
        ),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(Chain(Mock.Chain2.chain)),
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
    //Process batch 2 of events
    //And make queries (C)
    await dispatchAllTasks()

    Assert.deepEqual(
      [
        GlobalState.NextQuery(CheckAllChains),
        Mock.getUpdateEndofBlockRangeScannedData(
          Mock.mockChainDataMapInitial,
          ~chain=Mock.Chain1.chain,
          ~blockNumberThreshold=-195,
          ~blockTimestampThreshold=25,
          ~blockNumber=5,
        ),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(Chain(Mock.Chain1.chain)),
        Mock.getUpdateEndofBlockRangeScannedData(
          Mock.mockChainDataMapInitial,
          ~chain=Mock.Chain2.chain,
          ~blockNumberThreshold=-192,
          ~blockTimestampThreshold=25,
          ~blockNumber=8,
        ),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(Chain(Mock.Chain2.chain)),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
      ],
      stubDataInitial->Stubs.getTasks,
      ~message="Should have detected rollback on chain 1",
    )
    await makeAssertions(
      ~queryName="C",
      ~chain1LatestFetchBlock=5,
      ~chain2LatestFetchBlock=8,
      ~totalQueueSize=5,
      ~batchName="B",
      ~chain1User1Balance=Some(50),
      ~chain1User2Balance=Some(100),
      ~chain2User1Balance=Some(100),
      ~chain2User2Balance=Some(50),
    )

    //Chain1 reorgs at block 4
    let stubDataReorg = makeStub(~mockChainDataMap=Mock.mockChainDataMapReorg)
    let dispatchAllTasks = () => stubDataReorg->Stubs.dispatchAllTasks

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
        Rollback,
        Mock.getUpdateEndofBlockRangeScannedData(
          Mock.mockChainDataMapInitial,
          ~chain=Mock.Chain2.chain,
          ~blockNumberThreshold=-191,
          ~blockTimestampThreshold=25,
          ~blockNumber=9,
        ),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(Chain(Mock.Chain2.chain)),
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
      ],
      stubDataReorg->Stubs.getTasks,
      ~message="Should have detected rollback on chain 1",
    )
    await makeAssertions(
      ~queryName="D",
      ~chain1LatestFetchBlock=5,
      ~chain2LatestFetchBlock=9,
      ~totalQueueSize=1,
      ~batchName="C",
      ~chain1User1Balance=Some(100),
      ~chain1User2Balance=Some(50),
      ~chain2User1Balance=Some(98),
      ~chain2User2Balance=Some(52),
    )

    //Action reorg
    await dispatchAllTasks()
    Assert.deepEqual(
      [GlobalState.NextQuery(CheckAllChains), ProcessEventBatch],
      stubDataReorg->Stubs.getTasks,
      ~message="Rollback should have actioned and next tasks are query and process batch",
    )
    await makeAssertions(
      ~queryName="After Rollback Action",
      ~chain1LatestFetchBlock=3,
      ~chain2LatestFetchBlock=2,
      ~totalQueueSize=0,
      ~batchName="After Rollback Action",
      //balances have not yet been changed
      ~chain1User1Balance=Some(100),
      ~chain1User2Balance=Some(50),
      ~chain2User1Balance=Some(98),
      ~chain2User2Balance=Some(52),
    )

    Assert.equal(
      true,
      switch getState().rollbackState {
      | RollbackInMemStore(_) => true
      | _ => false
      },
      ~message="Rollback in memory store should be set in state",
    )
    //Make new queries (C for Chain 1, B for Chain 2)
    //Artificially cut the tasks to only do one round of queries and batch processing
    tasks := [NextQuery(CheckAllChains)]
    await dispatchAllTasks()
    await makeAssertions(
      ~queryName="After Rollback Action",
      ~chain1LatestFetchBlock=5,
      ~chain2LatestFetchBlock=5,
      ~totalQueueSize=3,
      ~batchName="After Rollback Action",
      //balances have not yet been changed
      ~chain1User1Balance=Some(100),
      ~chain1User2Balance=Some(50),
      ~chain2User1Balance=Some(98),
      ~chain2User2Balance=Some(52),
    )

    // Artificially cut the tasks to only do one round of queries and batch processing
    tasks := [ProcessEventBatch]
    // Process event batch with reorg in mem store and action next queries
    await dispatchAllTasks()
    await makeAssertions(
      ~queryName="After Rollback EventProcess",
      ~chain1LatestFetchBlock=5,
      ~chain2LatestFetchBlock=5,
      ~totalQueueSize=0,
      ~batchName="After Rollback EventProcess",
      //balances have not yet been changed
      ~chain1User1Balance=Some(89),
      ~chain1User2Balance=Some(61),
      ~chain2User1Balance=Some(100),
      ~chain2User2Balance=Some(50),
    )
    //Todo assertions
    //Assert new balances

    await setupDb()
  })
})
